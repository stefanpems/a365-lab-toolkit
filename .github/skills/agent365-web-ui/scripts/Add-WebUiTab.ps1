#requires -Version 7.0
<#
.SYNOPSIS
  Surgically ASSOCIATE one agent with a (possibly shared) web UI: merge exactly ONE tab into the
  deployed config.js, reveal it (enabled:true), redeploy the SPA, tag the SWA, and (ACA only) wire CORS.

.DESCRIPTION
  This is the durable, scriptable form of the "attach an agent to an existing web UI" step. It is used
  by the Lab Builder (attach mode) and the Web UI Creator flow. It NEVER regenerates
  config.js: it fetches the LIVE config.js from the SWA (the source of truth — other runs may have added
  tabs), merges one entry by unique id (`<typeShortId>-<labPrefix>`), preserving every other tab and the
  msal block, validates with `node --check`, and redeploys via StaticSitesClient.exe.

  Association means two things, both handled here:
    1. Visibility  — the tab is added with enabled:true so its left-sidebar link shows.
    2. Function     — the tab carries the correct endpoint(s)/scopes (+ customScopes/customInputs for a
                      custom MCP), and for an ACA agent the SWA origin is appended to the container's
                      UI_ALLOWED_ORIGINS (and UI_AUDIENCE for S2S) so the browser call is not blocked.

  On a SHARED UI it also stamps the SWA with `a365ref_<labPrefix>=<yyyyMMdd>` so the Lab Cleaner can
  find which shared UIs host a lab's agents and DEREGISTER (not delete) them later.

.PARAMETER SwaName            Static Web App name of the target UI.
.PARAMETER ResourceGroup      (Optional) SWA resource group; auto-discovered if omitted.
.PARAMETER Subscription       Target subscription id (pinned on every az call).
.PARAMETER TenantId           Expected tenant id (asserted; abort on mismatch).
.PARAMETER AgentType          ACA-OBO | ACA-S2S | FH-OBO | FH-S2S | FD-OBO | FD-S2S (DW/MCS never exposed).
.PARAMETER Name               Free-form tab label shown in the sidebar.
.PARAMETER LabPrefix          Owning lab prefix (or single-agent slug) — drives the tab id + labPrefix + tag.
.PARAMETER ApiBase            ACA FQDN base (https://<fqdn>) for ACA-OBO/ACA-S2S.
.PARAMETER S2sAppId           ACA-S2S app id (builds api://<id>/access_agent_as_user).
.PARAMETER Endpoint           Full Foundry endpoint for FH/FD.
.PARAMETER AgentName          FD agent name (agent_reference).
.PARAMETER AnonAudience       Custom MCP anon BYO app id (OBO only).
.PARAMETER AuthAudience       Custom MCP auth BYO app id (OBO only).
.PARAMETER AcaApp             (ACA only) container app name, to wire UI_ALLOWED_ORIGINS/UI_AUDIENCE.
.PARAMETER AcaResourceGroup   (ACA only) container app RG.
.PARAMETER WorkFolder         Local UI folder to stage config.js in before deploy. Default: the repo's ui/.
.PARAMETER NoDeploy           Build + validate the merged config.js but do not redeploy (dry preview).

.EXAMPLE
  pwsh -File Add-WebUiTab.ps1 -SwaName sharedui-ui -Subscription <sub> -TenantId <t> `
      -AgentType ACA-OBO -Name "Sales triage (ACA, OBO)" -LabPrefix a09091 -ApiBase https://a09091-aca-obo.<region>.azurecontainerapps.io `
      -AcaApp a09091-aca-obo -AcaResourceGroup a09091-MAF-ACA-OBO-rg
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SwaName,
    [string]$ResourceGroup,
    [Parameter(Mandatory)][string]$Subscription,
    [string]$TenantId,
    [Parameter(Mandatory)][ValidateSet('ACA-OBO', 'ACA-S2S', 'FH-OBO', 'FH-S2S', 'FD-OBO', 'FD-S2S')][string]$AgentType,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$LabPrefix,
    [string]$InstanceSuffix,
    [string]$ApiBase,
    [string]$S2sAppId,
    [string]$Endpoint,
    [string]$AgentName,
    [string]$AnonAudience,
    [string]$AuthAudience,
    [string]$AcaApp,
    [string]$AcaResourceGroup,
    [string]$WorkFolder,
    [switch]$NoDeploy
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot '_webui-config.ps1')
. (Join-Path $PSScriptRoot '_webui-cloud.ps1')

# --- Context: pin the subscription, assert the tenant (az ad / Graph ignore --subscription) ---
az account set --subscription $Subscription | Out-Null
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' first." }
if ($TenantId -and $ctx.tenantId -ne $TenantId) { throw "az context tenant '$($ctx.tenantId)' != -TenantId '$TenantId'. Re-pin and retry." }

# --- Per-type argument validation (fail early, before any cloud edit) ---
switch ($AgentType) {
    'ACA-OBO' { if (-not $ApiBase) { throw "ACA-OBO requires -ApiBase." } }
    'ACA-S2S' { if (-not $ApiBase -or -not $S2sAppId) { throw "ACA-S2S requires -ApiBase and -S2sAppId." } }
    'FH-OBO'  { if (-not $Endpoint) { throw "FH-OBO requires -Endpoint." } }
    'FH-S2S'  { if (-not $Endpoint) { throw "FH-S2S requires -Endpoint." } }
    'FD-OBO'  { if (-not $Endpoint -or -not $AgentName) { throw "FD-OBO requires -Endpoint and -AgentName." } }
    'FD-S2S'  { if (-not $Endpoint -or -not $AgentName) { throw "FD-S2S requires -Endpoint and -AgentName." } }
}

$swa = Resolve-Swa -SwaName $SwaName -Subscription $Subscription -ResourceGroup $ResourceGroup
Write-Host "Target SWA: $($swa.name) (RG $($swa.resourceGroup)) — $($swa.origin)" -ForegroundColor Cyan

# --- Get the authoritative config.js (LIVE from the SWA), else seed an empty shell ---
$text = Get-DeployedConfigText -Origin $swa.origin
if ($text) {
    Write-Host "Fetched live config.js from the SWA." -ForegroundColor DarkGray
    $cfg = Read-AppConfig -Text $text
}
else {
    Write-Host "No live config.js yet — seeding an empty shell (fresh UI)." -ForegroundColor DarkYellow
    $spaAppId = az staticwebapp show -n $swa.name -g $swa.resourceGroup --subscription $Subscription --query 'null' -o tsv 2>$null
    $cfg = [pscustomobject]@{ msal = [pscustomobject]@{ clientId = '<YOUR_SPA_APP_ID>'; authority = "https://login.microsoftonline.com/$($ctx.tenantId)" }; agents = @() }
}

# --- Build + merge the ONE tab ---
# InstanceSuffix (e.g. '-2') disambiguates one of N instances of the same type in a SHARED config.js; the
# tab id becomes '<shortId><suffix>-<labPrefix>' and still ends '-<labPrefix>' so Remove-TabsByLab finds it.
$tabIdOverride = if ($InstanceSuffix) { "$(Get-TabShortId -AgentType $AgentType)$InstanceSuffix-$LabPrefix" } else { $null }
$entry = New-TabEntry -AgentType $AgentType -Name $Name -LabPrefix $LabPrefix -TabId $tabIdOverride -ApiBase $ApiBase -S2sAppId $S2sAppId `
    -Endpoint $Endpoint -AgentName $AgentName -AnonAudience $AnonAudience -AuthAudience $AuthAudience
# Multi-instance: keep the FH Invocations session prefix unique per instance too (mirrors scaffold.ui.ps1).
if ($InstanceSuffix -and ($entry.Contains('sessionPrefix'))) { $entry['sessionPrefix'] = "$($entry['sessionPrefix'])$InstanceSuffix" }
$tabId = $entry['id']
$before = @($cfg.agents).Count
$cfg = Add-OrReplaceTab -Config $cfg -Entry $entry
$after = @($cfg.agents).Count
$verb = if ($after -gt $before) { 'added' } else { 'replaced' }
Write-Host "Tab '$tabId' $verb ($after tab(s) total)." -ForegroundColor Green

# --- Stage config.js in a work folder + validate ---
if (-not $WorkFolder) { $WorkFolder = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\ui')).Path }
if (-not (Test-Path -LiteralPath $WorkFolder)) { throw "WorkFolder not found: $WorkFolder" }
$cfgPath = Join-Path $WorkFolder 'config.js'
Write-AppConfig -Config $cfg | Set-Content -LiteralPath $cfgPath -Encoding utf8
node --check $cfgPath 2>$null
if ($LASTEXITCODE -ne 0) { throw "node --check failed on the merged config.js — NOT deploying." }
Write-Host "config.js validated (node --check)." -ForegroundColor Green

if ($NoDeploy) { Write-Host "-NoDeploy: staged $cfgPath, skipping SWA deploy + tagging." -ForegroundColor Yellow; return }

# --- Redeploy the SPA (build-free static re-upload) ---
Deploy-SwaContent -SwaName $swa.name -ResourceGroup $swa.resourceGroup -AppFolder $WorkFolder -Subscription $Subscription
Write-Host "SPA redeployed to $($swa.origin)." -ForegroundColor Green

# --- Tag the SWA: component marker + this lab's back-reference (for the Lab Cleaner) ---
$today = (Get-Date).ToString('yyyyMMdd')
[void](Set-ResourceTags -ResourceId $swa.id -Tags @{ 'a365component' = 'web-ui'; "a365ref_$LabPrefix" = $today } -Subscription $Subscription)
Write-Host "SWA tagged a365component=web-ui, a365ref_$LabPrefix=$today." -ForegroundColor DarkGray

# --- CORS (ACA only): append the SWA origin to the container, set UI_AUDIENCE for S2S ---
if ($AgentType -like 'ACA-*') {
    if ($AcaApp -and $AcaResourceGroup) {
        $aud = if ($AgentType -eq 'ACA-S2S') { $S2sAppId } else { $null }
        if (Add-AcaCorsOrigin -App $AcaApp -ResourceGroup $AcaResourceGroup -Origin $swa.origin -S2sAudience $aud -Subscription $Subscription) {
            Write-Host "CORS wired on $AcaApp (UI_ALLOWED_ORIGINS += $($swa.origin)$(if($aud){"; UI_AUDIENCE=$aud"}))." -ForegroundColor Green
        } else { Write-Host "WARN: could not update CORS on $AcaApp — set UI_ALLOWED_ORIGINS manually." -ForegroundColor Yellow }
    }
    else {
        Write-Host "NOTE: pass -AcaApp/-AcaResourceGroup to auto-wire CORS, or set UI_ALLOWED_ORIGINS=$($swa.origin) on the container yourself." -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Associated '$Name' with $($swa.name). Open $($swa.origin) and hard-reload (Ctrl+F5)." -ForegroundColor Cyan
