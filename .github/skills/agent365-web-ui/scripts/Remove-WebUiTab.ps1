#requires -Version 7.0
<#
.SYNOPSIS
  Surgically DEREGISTER agents from a (possibly shared) web UI: remove the tab(s) of a whole lab
  (-LabPrefix) or a single agent (-TabId) from the deployed config.js, redeploy the SPA, and clear the
  lab's SWA back-reference tag. NEVER regenerates config.js and NEVER deletes the SWA.

.DESCRIPTION
  The scriptable inverse of Add-WebUiTab.ps1, used by the Lab Cleaner (deregister a whole lab's agents
  from a shared UI it did not create) and single-agent detach via the -TabId form. It fetches the
  LIVE config.js (source of truth), removes exactly the matching entries (preserving every other tab and
  the msal block), validates with `node --check`, and redeploys via StaticSitesClient.exe.

  Selection:
    -LabPrefix <p>  removes every tab whose labPrefix == p (or, for older tabs without the field, whose
                    id ends in "-<p>"), then, if the SWA has no remaining tab for that lab, removes the
                    `a365ref_<p>` tag from the SWA.
    -TabId <id>     removes exactly one tab by id (single-agent detach).

  It does NOT touch other labs' tabs, the msal block, or the SWA resource itself.

.PARAMETER SwaName        Static Web App name of the shared/target UI.
.PARAMETER ResourceGroup  (Optional) SWA resource group; auto-discovered if omitted.
.PARAMETER Subscription   Target subscription id (pinned on every az call).
.PARAMETER TenantId       Expected tenant id (asserted; abort on mismatch).
.PARAMETER LabPrefix      Remove every tab owned by this lab.
.PARAMETER TabId          Remove exactly one tab by id.
.PARAMETER WorkFolder     Local UI folder to stage config.js in before deploy. Default: the repo's ui/.
.PARAMETER NoDeploy       Build + validate the edited config.js but do not redeploy (dry preview).

.EXAMPLE
  pwsh -File Remove-WebUiTab.ps1 -SwaName sharedui-ui -Subscription <sub> -TenantId <t> -LabPrefix a09091
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SwaName,
    [string]$ResourceGroup,
    [Parameter(Mandatory)][string]$Subscription,
    [string]$TenantId,
    [string]$LabPrefix,
    [string]$TabId,
    [string]$WorkFolder,
    [switch]$NoDeploy
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
if (-not $LabPrefix -and -not $TabId) { throw "Provide -LabPrefix (deregister a whole lab) or -TabId (detach one agent)." }
. (Join-Path $PSScriptRoot '_webui-config.ps1')
. (Join-Path $PSScriptRoot '_webui-cloud.ps1')

az account set --subscription $Subscription | Out-Null
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' first." }
if ($TenantId -and $ctx.tenantId -ne $TenantId) { throw "az context tenant '$($ctx.tenantId)' != -TenantId '$TenantId'. Re-pin and retry." }

$swa = Resolve-Swa -SwaName $SwaName -Subscription $Subscription -ResourceGroup $ResourceGroup
Write-Host "Target SWA: $($swa.name) (RG $($swa.resourceGroup)) — $($swa.origin)" -ForegroundColor Cyan

$text = Get-DeployedConfigText -Origin $swa.origin
if (-not $text) { Write-Host "No live config.js on the SWA — nothing to deregister." -ForegroundColor Yellow; return }
$cfg = Read-AppConfig -Text $text

$removed = 0
if ($TabId) { $removed = Remove-TabById -Config $cfg -TabId $TabId }
else { $removed = Remove-TabsByLab -Config $cfg -LabPrefix $LabPrefix }
if ($removed -eq 0) {
    $what = if ($TabId) { "tab id '$TabId'" } else { "lab '$LabPrefix'" }
    Write-Host "No tab matched $what — config.js unchanged." -ForegroundColor Yellow
    return
}
Write-Host "Removed $removed tab(s). $(@($cfg.agents).Count) remain." -ForegroundColor Green

if (-not $WorkFolder) { $WorkFolder = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\ui')).Path }
if (-not (Test-Path -LiteralPath $WorkFolder)) { throw "WorkFolder not found: $WorkFolder" }
$cfgPath = Join-Path $WorkFolder 'config.js'
Write-AppConfig -Config $cfg | Set-Content -LiteralPath $cfgPath -Encoding utf8
node --check $cfgPath 2>$null
if ($LASTEXITCODE -ne 0) { throw "node --check failed on the edited config.js — NOT deploying." }
Write-Host "config.js validated (node --check)." -ForegroundColor Green

if ($NoDeploy) { Write-Host "-NoDeploy: staged $cfgPath, skipping SWA deploy + tag cleanup." -ForegroundColor Yellow; return }

Deploy-SwaContent -SwaName $swa.name -ResourceGroup $swa.resourceGroup -AppFolder $WorkFolder -Subscription $Subscription
Write-Host "SPA redeployed to $($swa.origin)." -ForegroundColor Green

# Clear the lab back-reference tag when no tab of that lab remains on the SWA.
if ($LabPrefix) {
    $stillHasLab = @($cfg.agents | Where-Object {
            (($_.PSObject.Properties.Name -contains 'labPrefix') -and $_.labPrefix -eq $LabPrefix) -or ("$($_.id)".EndsWith("-$LabPrefix"))
        }).Count -gt 0
    if (-not $stillHasLab) {
        [void](Remove-ResourceTagKeys -ResourceId $swa.id -Keys @("a365ref_$LabPrefix") -Subscription $Subscription)
        Write-Host "Cleared SWA tag a365ref_$LabPrefix (no more tabs of that lab)." -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "Deregistration complete on $($swa.name). The shared UI and other labs' tabs are untouched." -ForegroundColor Cyan
