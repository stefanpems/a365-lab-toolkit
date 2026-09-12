<#
.SYNOPSIS
  Create ONE Microsoft Copilot Studio (MCS) agent from a base solution zip and import it into a target
  Copilot Studio environment.
.DESCRIPTION
  Pipeline: transform the shipped base solution (assets/base-solutions/AgentOHSol.zip | AgentNHSol.zip)
  into a uniquely named unmanaged solution (rename display name + solution name, optional schema-name
  isolation), then `pac solution import --publish-changes` into the target Dataverse environment.

  MCS-OH = legacy standard harness (no special prerequisites). MCS-NH = GitHub Copilot harness (needs a
  PAYG-linked / credit-allocated environment, verified up-front unless -SkipPrereqCheck).

  This is the durable engine behind the Lab Builder / Agent Creator MCS variants: it does NOT regenerate
  the base solution each run — it reuses the committed base zips captured this session.
.PARAMETER Harness            MCS-OH / MCS-NH (or OH / NH).
.PARAMETER DisplayName        Agent display name in Copilot Studio (Lab Builder: <lab>-MCS-OH / <lab>-MCS-NH).
.PARAMETER Tenant             Target tenant id (interactive browser sign-in if no matching pac profile).
.PARAMETER EnvironmentId      Target environment GUID (resolved to its org URL via pac env list).
.PARAMETER EnvironmentUrl     Target Dataverse org URL (alternative to -EnvironmentId).
.PARAMETER SolutionUniqueName Optional; default derived from DisplayName.
.PARAMETER IsolateSchemaName  Rewrite the bot schema token too (multiple same-harness agents in ONE env).
.PARAMETER OutDir             Where to write the renamed solution zip. Default: generated/copilot-studio.
.PARAMETER InstallPac         Install the Power Platform CLI if missing.
.PARAMETER SkipPrereqCheck    Skip the NH PAYG/Dataverse verification (not recommended).
.PARAMETER ScaffoldOnly       Produce the renamed zip only; do NOT auth/import (dry run).
.PARAMETER Publish            After import, print the guided publication step (Availability options ->
                              Show to everyone in my org) — the actual toggle is a maker-portal action.
.EXAMPLE
  .\New-McsAgent.ps1 -Harness MCS-OH -DisplayName contoso-MCS-OH -Tenant <tid> -EnvironmentId <envId>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('MCS-OH', 'MCS-NH', 'OH', 'NH')][string]$Harness,
    [Parameter(Mandatory)][string]$DisplayName,
    [string]$Tenant,
    [string]$EnvironmentId,
    [string]$EnvironmentUrl,
    [string]$SolutionUniqueName,
    [switch]$IsolateSchemaName,
    [string]$OutDir,
    [switch]$InstallPac,
    [switch]$SkipPrereqCheck,
    [switch]$ScaffoldOnly,
    [switch]$Publish
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_mcs-common.ps1')

$pac = Assert-PacCli -Install:$InstallPac
$key = ($Harness -replace '(?i)^MCS-', '').ToUpper()
if (-not $OutDir) { $OutDir = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path 'generated\copilot-studio' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# 1) Transform the base zip -> renamed, ready-to-import solution.
$outZip = Join-Path $OutDir ((ConvertTo-SolutionUniqueName $DisplayName) + '.zip')
$built  = New-RenamedMcsSolution -Harness $key -DisplayName $DisplayName -OutZip $outZip `
    -SolutionUniqueName $SolutionUniqueName -IsolateSchemaName:$IsolateSchemaName
Write-Host "  Built solution '$($built.solutionUniqueName)' (agent '$($built.displayName)', schema '$($built.botSchemaName)') -> $($built.zip)" -ForegroundColor Green

if ($ScaffoldOnly) {
    Write-Host "ScaffoldOnly: skipping auth/import. Import later with:" -ForegroundColor Yellow
    Write-Host "  pac solution import --path `"$($built.zip)`" --environment <orgUrl> --publish-changes"
    return $built
}

# 2) Authenticate pac to the target tenant (idempotent).
if ($Tenant) {
    $active = (& $pac auth list) 2>$null
    if (-not ($active -match $Tenant)) {
        Write-Host "A browser sign-in will open — sign in as an admin of tenant $Tenant." -ForegroundColor Yellow
        & $pac auth create --name "mcs-target" --tenant $Tenant | Out-Null
    }
}

# 3) Resolve the target org URL.
if (-not $EnvironmentUrl) {
    if (-not $EnvironmentId) { throw "Provide -EnvironmentUrl or -EnvironmentId (target Dataverse environment)." }
    $row = (& $pac env list) 2>&1 | Select-String -SimpleMatch $EnvironmentId
    if ($row -and $row.Line -match 'https://\S+') { $EnvironmentUrl = $matches[0].TrimEnd('/') + '/' }
    else { throw "Environment $EnvironmentId not found by 'pac env list'. It likely has no Dataverse — add it in PPAC ('+ Add Dataverse'), wait until Ready, then retry." }
}

# 4) NH prerequisite gate (Dataverse + PAYG/credits) unless skipped.
if ($key -eq 'NH' -and -not $SkipPrereqCheck) {
    $envIdForCheck = $EnvironmentId
    if (-not $envIdForCheck) {
        $envIdForCheck = ((& $pac env list) 2>&1 | Select-String -SimpleMatch ($EnvironmentUrl.TrimEnd('/')) | ForEach-Object { if ($_.Line -match '([0-9a-fA-F-]{36})') { $matches[1] } } | Select-Object -First 1)
    }
    if ($envIdForCheck) {
        $chk = & (Join-Path $PSScriptRoot 'Test-McsPrereqs.ps1') -EnvironmentId $envIdForCheck -Harness 'MCS-NH'
        if (-not $chk.ok) { throw "MCS-NH prerequisites not met for $envIdForCheck. Fix the items above (Dataverse and/or PAYG/Copilot Credits), then retry. Use -SkipPrereqCheck to override." }
    }
    else {
        Write-Host "  WARN: could not resolve the environment GUID to run the NH prerequisite check; ensure PAYG/credits are in place, else preview fails with EnforcementUsageCredits." -ForegroundColor Yellow
    }
}

# 5) Import + publish customizations.
Write-Host "  Importing '$($built.solutionUniqueName)' into $EnvironmentUrl ..." -ForegroundColor Cyan
& $pac solution import --path $built.zip --environment $EnvironmentUrl --publish-changes
Write-Host "  Imported + published: agent '$DisplayName' is now in the target Copilot Studio environment." -ForegroundColor Green

$built.environmentUrl = $EnvironmentUrl

# 6) Guided publication (Availability options -> Show to everyone in my org) — maker-portal action.
if ($Publish) {
    Write-Host ""
    Write-Host "PUBLICATION (guided, maker portal):" -ForegroundColor Yellow
    Write-Host "  1. Open Copilot Studio -> the target environment -> agent '$DisplayName'."
    Write-Host "  2. Reconfigure user authentication if prompted, then Publish."
    Write-Host "  3. Channels -> Teams and Microsoft 365 Copilot -> Availability options -> 'Show to everyone in my org'."
    Write-Host "  (Solution import already ran Publish All Customizations; org-wide availability is a portal toggle.)"
}

$built
