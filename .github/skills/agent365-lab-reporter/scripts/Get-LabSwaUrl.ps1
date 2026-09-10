#requires -Version 7.0
<#
.SYNOPSIS
  READ-ONLY. Resolve the Static Web App (web UI) URL of a lab identified by its name/prefix.

.DESCRIPTION
  The Lab Builder names the web UI Static Web App `<prefix>-ui` in resource group `<prefix>-ui-rg`.
  Given a lab name (the solution prefix, e.g. `a09091`), this script finds the matching Static Web App
  in the target subscription and prints its public URL (`https://<defaultHostname>`). It performs NO
  mutations — only `az staticwebapp list/show`.

  Primary source is the cloud (authoritative, reflects the live deployment). If the cloud lookup finds
  nothing and a scaffolded run exists locally, the script falls back to the generated wizard progress
  log for a recorded host, purely as a hint.

.PARAMETER LabName
  The lab name / solution prefix (e.g. `a09091`). Matched case-insensitively against Static Web App
  names.

.PARAMETER Subscription
  Target subscription id. Pins the az context.

.PARAMETER TenantId
  Optional expected tenant id. If supplied, the script aborts when the signed-in az context is a
  different tenant (guards the shared, concurrently-flipping az context).

.PARAMETER OutFile
  Optional path to write the result JSON to.

.EXAMPLE
  pwsh -File .\Get-LabSwaUrl.ps1 -LabName a09091 -Subscription <sub> -TenantId <tenant>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LabName,
    [Parameter(Mandatory)][string]$Subscription,
    [string]$TenantId,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$safeName = ($LabName -replace "['`"]", '').Trim()
if ([string]::IsNullOrWhiteSpace($safeName)) { throw "LabName is required." }

# Pin the subscription and (optionally) verify the tenant.
az account set --subscription $Subscription | Out-Null
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' first." }
if ($TenantId -and $ctx.tenantId -ne $TenantId) {
    throw "az context tenant '$($ctx.tenantId)' != -TenantId '$TenantId'. Re-pin the context and retry."
}
$sub = $ctx.id
Write-Host "Resolving web UI for lab '$safeName' — tenant $($ctx.tenantId), subscription $sub" -ForegroundColor Cyan

# Cloud lookup: Static Web Apps whose name contains the lab prefix.
$swaMatches = New-Object System.Collections.Generic.List[object]
$swaRaw = az staticwebapp list --subscription $sub -o json 2>$null
$swa = $null
if ($swaRaw) { try { $swa = $swaRaw | ConvertFrom-Json } catch { $swa = $null } }
foreach ($s in @($swa)) {
    if ($s.name -notmatch [regex]::Escape($safeName)) { continue }
    $swaHost = $s.defaultHostname
    $url = if ($swaHost) { "https://$swaHost" } else { $null }
    $swaMatches.Add([pscustomobject]@{
            name          = $s.name
            resourceGroup = $s.resourceGroup
            defaultHost   = $swaHost
            url           = $url
            location      = $s.location
        })
}

$result = [ordered]@{
    labName       = $safeName
    tenantId      = $ctx.tenantId
    subscription  = $sub
    found         = ($swaMatches.Count -gt 0)
    staticWebApps = @($swaMatches.ToArray())
}

if ($swaMatches.Count -gt 0) {
    Write-Host ""
    Write-Host "Web UI URL(s) for lab '$safeName':" -ForegroundColor Green
    foreach ($m in $swaMatches) {
        Write-Host ("  {0}" -f $m.url) -ForegroundColor White
        Write-Host ("      (Static Web App '{0}' in RG '{1}')" -f $m.name, $m.resourceGroup) -ForegroundColor DarkGray
    }
}
else {
    Write-Host "No Static Web App matching '$safeName' found in this subscription." -ForegroundColor Yellow
    # Best-effort local hint from a scaffolded run's progress log (never authoritative).
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $progress = Join-Path $repoRoot 'generated' 'wizard-progress.log'
    if (Test-Path -LiteralPath $progress) {
        $hostHint = Select-String -LiteralPath $progress -Pattern "$([regex]::Escape($safeName)).*(azurestaticapps\.net)" -AllMatches |
        ForEach-Object { $_.Matches.Value } | Select-Object -First 1
        if ($hostHint) {
            Write-Host "  Hint from generated/wizard-progress.log: $hostHint" -ForegroundColor DarkYellow
            $result.progressLogHint = $hostHint
        }
    }
}

$json = ($result | ConvertTo-Json -Depth 6)
if ($OutFile) {
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Set-Content -LiteralPath $OutFile -Value $json -Encoding utf8
    Write-Host "Wrote result to $OutFile" -ForegroundColor Cyan
}
else {
    Write-Output $json
}
