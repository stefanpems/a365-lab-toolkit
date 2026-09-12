<#
.SYNOPSIS
  RE-EXTRACT the MCS base solution zips from an origin (source) Copilot Studio environment.
.DESCRIPTION
  The two base solutions (AgentOHSol = legacy harness, AgentNHSol = GitHub Copilot harness) shipped in
  assets/base-solutions/ are the creation base for every MCS agent. Use this script to refresh them from
  a source tenant where the reference agents live (each already placed in an unmanaged custom solution).

  It reuses the exact, validated path from the session that produced them:
    pac auth create --tenant <source> --environment <url>   (interactive sign-in)
    pac solution export --name <UNIQUE> --managed false --overwrite

  NOTE: `pac solution export` uses the SYNCHRONOUS export path, so it works even when the maker portal
  fails with "Async operations are currently disabled for this organization".
  IMPORTANT: --name takes the solution UNIQUE name (e.g. AgentOHSol), NOT the friendly name (AgentOH-Sol).

  After a successful re-extract, review and COMMIT the updated zips under assets/base-solutions/.
.PARAMETER Tenant          Source tenant id (interactive browser sign-in).
.PARAMETER EnvironmentUrl  Source Dataverse org URL (e.g. https://orgXXXX.crm4.dynamics.com/).
.PARAMETER EnvironmentId   Alternative to -EnvironmentUrl (resolved via pac env list).
.PARAMETER OhSolutionName  Unique name of the legacy-harness solution in the source. Default AgentOHSol.
.PARAMETER NhSolutionName  Unique name of the GHCP-harness solution in the source. Default AgentNHSol.
.PARAMETER Only            'OH' or 'NH' to re-extract just one; default both.
.PARAMETER OutDir          Destination for the base zips. Default: <skill>/assets/base-solutions.
.PARAMETER InstallPac      Install the Power Platform CLI if missing.
.EXAMPLE
  .\Export-McsBaseSolution.ps1 -Tenant <sid> -EnvironmentUrl https://org9d2c4159.crm4.dynamics.com/
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Tenant,
    [string]$EnvironmentUrl,
    [string]$EnvironmentId,
    [string]$OhSolutionName = 'AgentOHSol',
    [string]$NhSolutionName = 'AgentNHSol',
    [ValidateSet('OH', 'NH')][string]$Only,
    [string]$OutDir,
    [switch]$InstallPac
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_mcs-common.ps1')
$pac = Assert-PacCli -Install:$InstallPac
if (-not $OutDir) { $OutDir = $script:McsBaseDir }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Auth to the source tenant (idempotent). --tenant is explicit so a non-default source tenant is honored.
$active = (& $pac auth list) 2>$null
if (-not ($active -match $Tenant)) {
    Write-Host "A browser sign-in will open — sign in as an admin of the SOURCE tenant $Tenant." -ForegroundColor Yellow
    if ($EnvironmentUrl) { & $pac auth create --name "mcs-source" --tenant $Tenant --environment $EnvironmentUrl | Out-Null }
    else { & $pac auth create --name "mcs-source" --tenant $Tenant | Out-Null }
}

if (-not $EnvironmentUrl) {
    if (-not $EnvironmentId) { throw "Provide -EnvironmentUrl or -EnvironmentId (source environment)." }
    $row = (& $pac env list) 2>&1 | Select-String -SimpleMatch $EnvironmentId
    if ($row -and $row.Line -match 'https://\S+') { $EnvironmentUrl = $matches[0].TrimEnd('/') + '/' }
    else { throw "Environment $EnvironmentId not found by 'pac env list'." }
}

$targets = @()
if (-not $Only -or $Only -eq 'OH') { $targets += @{ key = 'OH'; name = $OhSolutionName; out = 'AgentOHSol.zip' } }
if (-not $Only -or $Only -eq 'NH') { $targets += @{ key = 'NH'; name = $NhSolutionName; out = 'AgentNHSol.zip' } }

foreach ($t in $targets) {
    $dest = Join-Path $OutDir $t.out
    Write-Host "=== Exporting $($t.name) ($($t.key)) -> $dest ===" -ForegroundColor Cyan
    & $pac solution export --name $t.name --path $dest --managed false --environment $EnvironmentUrl --overwrite
}

Write-Host ""
Write-Host "Re-extract complete. Review and COMMIT the updated base zips under $OutDir." -ForegroundColor Green
Get-ChildItem $OutDir -Filter *.zip | Select-Object Name, Length, LastWriteTime
