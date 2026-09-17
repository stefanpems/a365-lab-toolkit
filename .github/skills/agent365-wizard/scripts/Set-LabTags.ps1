#requires -Version 7.0
<#
.SYNOPSIS
  Stamp a durable lab tag on every LAB-OWNED cloud resource of an Agent 365 lab, so the Lab Cleaner /
  Lab Reporter can find a lab whose agents were given CUSTOM names (not the default
  <prefix>-<framework>-<hosting>-<identity>).

.DESCRIPTION
  The Lab Cleaner discovers a lab by matching the solution PREFIX against resource NAMES. That works for
  default-named agents but breaks the moment an agent is given a custom name that does not contain the
  prefix. This script writes a stable, cloud-side association that survives renames and does not depend
  on the local generated/<prefix>/ folder:

    * Azure resource groups    -> tag  a365lab=<prefix>   (az group update --set tags.a365lab)
    * Entra app registrations  -> tag  a365lab:<prefix>   (the multi-valued 'tags' collection)
      + their service principals (same tag)

  Only LAB-OWNED resources are tagged. A 'reuse-existing' / user-owned shared Foundry or Azure OpenAI
  account is NEVER tagged (the Lab Cleaner must never delete it). The tag is applied idempotently — a
  second run adds nothing — so this is safe to run after every deploy AND on resume after an interrupted
  run (the earliest a resource can be tagged is right after it exists; re-running closes any gap left by
  an interruption between "resource created" and "resource tagged").

  It reads the archived plan generated/<prefix>/a365-deployment-plan.json (or -PlanPath) to learn the
  EXACT resource names — including custom ones — then tags each that actually exists. It performs no
  deletes and no deploys.

  Entra tags are written with a Microsoft Graph token + Invoke-RestMethod (NOT `az rest --body @file`,
  which corrupts the JSON body on some Windows hosts — see repo notes). Graph filters are URL-encoded as
  a single query parameter (no '&') for the same reason.

.PARAMETER Prefix        The solution prefix (lab name), e.g. zzrigel.
.PARAMETER Subscription  Target subscription id (pins the az context).
.PARAMETER TenantId      Expected tenant id (the script aborts on a mismatch — az ad / Graph ignore
                         --subscription and use the active account, which a parallel session can flip).
.PARAMETER PlanPath      Optional path to the plan JSON. Default: generated/<prefix>/a365-deployment-plan.json.
.PARAMETER WhatIf        Show what would be tagged without writing anything.

.EXAMPLE
  pwsh -File .\Set-LabTags.ps1 -Prefix zzrigel -Subscription <sub> -TenantId <tenant>
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Prefix,
    [Parameter(Mandatory)][string]$Subscription,
    [string]$TenantId,
    [string]$PlanPath
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$LabTagKey   = 'a365lab'
$AzureTagVal = $Prefix                  # Azure tag: a365lab=<prefix>
$EntraTag    = "$LabTagKey`:$Prefix"    # Entra tag: a365lab:<prefix>

# ---------------------------------------------------------------------------
# Locate the plan (archived per-run copy under generated/<prefix>/).
# ---------------------------------------------------------------------------
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
if (-not $PlanPath) { $PlanPath = Join-Path $repoRoot "generated\$Prefix\a365-deployment-plan.json" }
$plan = $null
if (Test-Path -LiteralPath $PlanPath) {
    try { $plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json } catch { $plan = $null }
}
if (-not $plan) {
    Write-Host "No plan found at $PlanPath — falling back to convention-derived names for prefix '$Prefix'." -ForegroundColor DarkYellow
}

# STANDALONE guard. A lab always has >=1 agent (the Lab Builder refuses to proceed without one); a
# STANDALONE instance created by the Web UI Creator / Custom MCP Creator has agents == 0. Its resources
# must carry a365component ONLY and NEVER a365lab (that tag is the lab-ownership discriminator used by the
# Lab Cleaner / Web UI & MCP Remover / Prompts Sender). So if the plan has no agents this is NOT a lab —
# refuse to stamp a365lab (use Set-ComponentTags.ps1 for the a365component tag instead).
if ($plan -and (@($plan.agents).Count -eq 0)) {
    Write-Host "Plan '$PlanPath' has no agents -> STANDALONE instance (web UI / custom MCP). Set-LabTags stamps the lab-ownership tag a365lab, which must NEVER be applied to a standalone instance. Nothing tagged (use Set-ComponentTags.ps1 for a365component)." -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------------------
# Context: pin the subscription and verify the tenant.
# ---------------------------------------------------------------------------
az account set --subscription $Subscription | Out-Null
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' first." }
if ($TenantId -and $ctx.tenantId -ne $TenantId) {
    throw "az context tenant '$($ctx.tenantId)' != -TenantId '$TenantId'. Re-pin the context and retry."
}
$sub = $ctx.id
Write-Host "Tagging lab '$Prefix' — tenant $($ctx.tenantId), subscription $sub" -ForegroundColor Cyan
Write-Host "  Azure tag: $LabTagKey=$AzureTagVal   |   Entra tag: $EntraTag" -ForegroundColor DarkGray

$graphToken = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($graphToken)) { throw "Could not acquire a Microsoft Graph token (az account get-access-token)." }
$graphHeaders = @{ Authorization = "Bearer $graphToken"; 'Content-Type' = 'application/json'; ConsistencyLevel = 'eventual' }

$summary = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------------------
# Azure resource-group tagging (idempotent, merges a single tag key).
# ---------------------------------------------------------------------------
function Set-RgTag {
    param([string]$Rg)
    if ([string]::IsNullOrWhiteSpace($Rg)) { return }
    $exists = (az group exists -n $Rg --subscription $sub 2>$null)
    if ($exists -ne 'true') { $summary.Add("RG   skip   $Rg (not found)"); return }
    $cur = az group show -n $Rg --subscription $sub --query "tags.$LabTagKey" -o tsv 2>$null
    if ($cur -eq $AzureTagVal) { $summary.Add("RG   ok     $Rg (already tagged)"); return }
    if ($PSCmdlet.ShouldProcess($Rg, "tag $LabTagKey=$AzureTagVal")) {
        az group update -n $Rg --subscription $sub --set "tags.$LabTagKey=$AzureTagVal" -o none 2>$null
        if ($LASTEXITCODE -eq 0) { $summary.Add("RG   TAGGED $Rg") } else { $summary.Add("RG   ERROR  $Rg (az group update failed)") }
    }
}

# ---------------------------------------------------------------------------
# Entra tagging (idempotent). Finds the object, appends the tag if missing, PATCHes.
# ---------------------------------------------------------------------------
function Add-EntraTagPatch {
    param([string]$Entity, [string]$ObjectId, [object]$CurrentTags, [string]$Label)
    $tags = @($CurrentTags | Where-Object { $_ })
    if ($tags -contains $EntraTag) { $summary.Add("$Label ok     (already tagged)"); return }
    $new = @($tags) + $EntraTag
    if ($PSCmdlet.ShouldProcess($Label, "tag $EntraTag")) {
        try {
            # -AsArray forces a JSON array even for a single tag (Graph rejects a scalar 'tags').
            $body = '{"tags":' + (@($new) | ConvertTo-Json -AsArray) + '}'
            Invoke-RestMethod -Method Patch -Uri "https://graph.microsoft.com/v1.0/$Entity/$ObjectId" `
                -Headers $graphHeaders -Body $body | Out-Null
            $summary.Add("$Label TAGGED")
        }
        catch { $summary.Add("$Label ERROR ($($_.Exception.Message))") }
    }
}

# Tag an application (by exact display name or appId) AND its service principal.
function Set-AppTagByName {
    param([string]$DisplayName)
    if ([string]::IsNullOrWhiteSpace($DisplayName)) { return }
    $flt = [uri]::EscapeDataString("displayName eq '$($DisplayName.Replace("'", "''"))'")
    $apps = $null
    try { $apps = (Invoke-RestMethod -Method Get -Uri ("https://graph.microsoft.com/v1.0/applications?`$filter=$flt") -Headers $graphHeaders).value } catch { $apps = $null }
    if (-not $apps) { $summary.Add("app  skip   '$DisplayName' (not found)"); return }
    foreach ($app in $apps) {
        Add-EntraTagPatch -Entity 'applications' -ObjectId $app.id -CurrentTags $app.tags -Label "app  '$DisplayName'"
        Set-SpTagByAppId -AppId $app.appId -Label "sp   '$DisplayName'"
    }
}

function Set-SpTagByAppId {
    param([string]$AppId, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($AppId)) { return }
    $flt = [uri]::EscapeDataString("appId eq '$AppId'")
    $sps = $null
    try { $sps = (Invoke-RestMethod -Method Get -Uri ("https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$flt") -Headers $graphHeaders).value } catch { $sps = $null }
    if (-not $sps) { return }
    foreach ($sp in $sps) { Add-EntraTagPatch -Entity 'servicePrincipals' -ObjectId $sp.id -CurrentTags $sp.tags -Label $Label }
}

# Tag every Entra app whose display name STARTS WITH a value (for the ext_<prefix>* MCP proxy/resource apps).
function Set-AppTagByPrefix {
    param([string]$NamePrefix)
    if ([string]::IsNullOrWhiteSpace($NamePrefix)) { return }
    $flt = [uri]::EscapeDataString("startswith(displayName,'$($NamePrefix.Replace("'", "''"))')")
    $apps = $null
    try { $apps = (Invoke-RestMethod -Method Get -Uri ("https://graph.microsoft.com/v1.0/applications?`$filter=$flt") -Headers $graphHeaders).value } catch { $apps = $null }
    foreach ($app in @($apps)) {
        Add-EntraTagPatch -Entity 'applications' -ObjectId $app.id -CurrentTags $app.tags -Label "app  '$($app.displayName)'"
        Set-SpTagByAppId -AppId $app.appId -Label "sp   '$($app.displayName)'"
    }
}

# ---------------------------------------------------------------------------
# Build the lab-owned inventory from the plan (or conventions) and tag it.
# ---------------------------------------------------------------------------
$sharedRgStrategy = if ($plan) { $plan.solution.resourceGroupStrategy } else { 'isolated' }
$sharedRg = if ($plan -and $plan.solution.sharedResourceGroup) { $plan.solution.sharedResourceGroup } else { "$Prefix-rg" }

# Agents: their own RG + (ACA only) blueprint/identity Entra apps.
$agents = if ($plan) { @($plan.agents) } else { @() }
foreach ($a in $agents) {
    if ($a.type -like 'MCS-*') { continue }  # MCS = Dataverse solution, not Azure/Entra; cleaned by prefix uniquename.
    $rg = if ($sharedRgStrategy -eq 'shared') { $sharedRg } elseif ($a.resourceGroup) { $a.resourceGroup } else { "$($a.name)-rg" }
    Set-RgTag -Rg $rg
    # Only ACA agents expose blueprint/identity app registrations we own by name. FH/FD blueprints are
    # Foundry-generated (not lab-named) — their lab-owned Azure footprint is the shared foundry RG below.
    if ($a.type -like 'ACA-*') {
        $bp = if ($a.displayNames.blueprint) { $a.displayNames.blueprint } else { "$($a.name) Blueprint" }
        $id = if ($a.displayNames.identity) { $a.displayNames.identity } else { "$($a.name) Identity" }
        Set-AppTagByName -DisplayName $bp
        Set-AppTagByName -DisplayName $id
    }
}
# When no plan is available, fall back to tagging any RG that already carries the prefix in its name.
if (-not $plan) {
    foreach ($rg in @(az group list --subscription $sub --query "[?contains(name,'$Prefix')].name" -o tsv 2>$null)) { Set-RgTag -Rg $rg }
}

# Shared Foundry (create-shared only — reuse-existing is user-owned, never tag).
if ($plan -and $plan.solution.foundry -and $plan.solution.foundry.mode -eq 'create-shared') {
    Set-RgTag -Rg $(if ($plan.solution.foundry.resourceGroup) { $plan.solution.foundry.resourceGroup } else { "$Prefix-foundry-rg" })
}
# Shared Azure OpenAI (create-shared only).
if ($plan -and $plan.solution.azureOpenAI -and $plan.solution.azureOpenAI.mode -eq 'create-shared') {
    Set-RgTag -Rg $(if ($plan.solution.azureOpenAI.resourceGroup) { $plan.solution.azureOpenAI.resourceGroup } else { "$Prefix-aoai-rg" })
}
# Shared App Insights (create-shared only — reuse-existing is user-owned, never tag).
if ($plan -and $plan.solution.observability -and $plan.solution.observability.appInsights -and $plan.solution.observability.appInsights.mode -eq 'create-shared') {
    Set-RgTag -Rg $(if ($plan.solution.observability.appInsights.resourceGroup) { $plan.solution.observability.appInsights.resourceGroup } else { "$Prefix-appinsights-rg" })
}

# Web UI (create mode): the UI RG + the SPA app registration.
if ($plan -and $plan.ui -and $plan.ui.mode -eq 'create') {
    Set-RgTag -Rg "$Prefix-ui-rg"
    Set-AppTagByName -DisplayName "$Prefix-ui-spa"
}

# Custom MCP: the MCP RG + every ext_<prefix>* registration/proxy/resource app.
# ONLY in CREATE mode. In ATTACH mode (customMcp.mode = 'attach') the ext_<name>Anon/Auth pair is
# REUSED — owned by another lab or a standalone Custom MCP Creator instance — so it must NEVER be
# tagged as this lab's, or the Lab Cleaner would later delete a shared / other-lab MCP.
if ($plan -and $plan.customMcp -and $plan.customMcp.enabled -and ($plan.customMcp.mode -ne 'attach')) {
    $mcpRg = if ($plan.customMcp.resourceGroup) { $plan.customMcp.resourceGroup } else { "$Prefix-mcp-rg" }
    Set-RgTag -Rg $mcpRg
    Set-AppTagByPrefix -NamePrefix "ext_$Prefix"
}

# ---------------------------------------------------------------------------
# Report.
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Tagging summary for lab '$Prefix':" -ForegroundColor Green
foreach ($line in $summary) { Write-Host "  $line" }
$tagged = @($summary | Where-Object { $_ -match 'TAGGED' }).Count
$errs   = @($summary | Where-Object { $_ -match 'ERROR' }).Count
Write-Host ""
Write-Host "  $tagged newly tagged, $errs error(s). Re-run any time — tagging is idempotent." -ForegroundColor DarkGray
if ($errs -gt 0) { exit 1 }
