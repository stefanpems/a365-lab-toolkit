<#
.SYNOPSIS
  Verify the prerequisites of a target Copilot Studio environment for an MCS agent.
.DESCRIPTION
  MCS-OH (legacy harness) has NO special prerequisites beyond a Dataverse-enabled environment.
  MCS-NH (GitHub Copilot harness) additionally needs Copilot Credits, i.e. the environment must be
  linked to a pay-as-you-go billing plan (or have allocated credits), otherwise preview/runtime fails
  with EnforcementUsageCredits ("environment is out of credits").

  This script checks, for a given environment:
    1. Dataverse present  (hard blocker for solution import) — the env must appear in `pac env list`.
    2. Billing policy / PAYG  (NH only, best-effort) — via `pac licensing get-environment-billing-policy`.
    3. Copilot Studio  (best-effort note) — practically implied by Dataverse + a supported region.

  Requires the Power Platform CLI (pac) authenticated to the TARGET tenant (pac auth create --tenant ...).
.PARAMETER EnvironmentId
  The target environment GUID (as shown in the Power Platform admin center).
.PARAMETER Harness
  MCS-OH or MCS-NH. Determines whether the PAYG/credits check is enforced.
.PARAMETER Tenant
  Optional target tenant id; when supplied and no matching pac profile is active, the script creates one
  (interactive browser sign-in).
.OUTPUTS
  A result object; also sets $LASTEXITCODE 0 when all REQUIRED prerequisites are met, 1 otherwise.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentId,
    [Parameter(Mandatory)][ValidateSet('MCS-OH', 'MCS-NH', 'OH', 'NH')][string]$Harness,
    [string]$Tenant
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_mcs-common.ps1')
$pac = Assert-PacCli

if ($Tenant) {
    $active = (& $pac auth list) 2>$null
    # Create a target profile only if none is active for this tenant (idempotent; interactive sign-in).
    if (-not ($active -match $Tenant)) {
        Write-Host "A browser sign-in will open — sign in as an admin of tenant $Tenant." -ForegroundColor Yellow
        & $pac auth create --name "mcs-target" --tenant $Tenant | Out-Null
    }
}

$key = ($Harness -replace '(?i)^MCS-', '').ToUpper()
$result = [ordered]@{
    environmentId = $EnvironmentId
    harness       = "MCS-$key"
    dataverse     = $false
    orgUrl        = $null
    paygLinked    = $null   # $true/$false for NH, $null (not required) for OH
    ok            = $false
    messages      = @()
}

# 1) Dataverse — the env must be listed by `pac env list` (which shows Dataverse-enabled envs only).
$envs = (& $pac env list) 2>&1
$row  = $envs | Select-String -SimpleMatch $EnvironmentId
if ($row) {
    $result.dataverse = $true
    if ($row.Line -match 'https://\S+') { $result.orgUrl = $matches[0].TrimEnd('/') + '/' }
    $result.messages += "Dataverse: OK ($($result.orgUrl))"
}
else {
    $result.messages += "Dataverse: MISSING — environment $EnvironmentId is not listed by 'pac env list'. In the Power Platform admin center open the environment and choose '+ Add Dataverse', wait until Ready, then rerun. Solution import cannot proceed without Dataverse."
}

# 2) PAYG / billing policy — required for NH only (best-effort; preview command).
if ($key -eq 'NH') {
    try {
        $bp = (& $pac licensing get-environment-billing-policy --environment $EnvironmentId) 2>&1
        $bpText = ($bp | Out-String)
        if ($bpText -match '(?i)billingPolicyId|policyName|"id"\s*:' -and $bpText -notmatch '(?i)not found|no billing') {
            $result.paygLinked = $true
            $result.messages += "PAYG: a billing policy is linked to this environment (Copilot Credits overage will bill to its Azure subscription)."
        }
        else {
            $result.paygLinked = $false
            $result.messages += "PAYG: no billing policy detected. MCS-NH (GitHub Copilot harness) needs Copilot Credits — link this env to a pay-as-you-go billing plan (PPAC -> Licensing -> Billing plans -> <plan> -> Edit -> Select environments, meter 'Copilot Studio') or allocate credits, else preview fails with EnforcementUsageCredits."
        }
    }
    catch {
        $result.paygLinked = $null
        $result.messages += "PAYG: could not query the billing policy automatically ($($_.Exception.Message)). Confirm MANUALLY that this env is linked to a PAYG plan / has Copilot Credits — MCS-NH cannot run without them."
    }
    $result.messages += "Copilot Studio: not strictly verifiable via pac; it is available when the env has Dataverse and a supported region. Confirm the env shows under Copilot Studio in PPAC."
}
else {
    $result.messages += "MCS-OH (legacy harness) has no Copilot Credits / PAYG prerequisite."
}

# Required = Dataverse always; PAYG for NH must not be explicitly false.
$result.ok = $result.dataverse -and (($key -eq 'OH') -or ($result.paygLinked -ne $false))

Write-Host ""
Write-Host "=== MCS prerequisites for $EnvironmentId (MCS-$key) ===" -ForegroundColor Cyan
$result.messages | ForEach-Object { Write-Host "  - $_" }
Write-Host ("  RESULT: {0}" -f ($(if ($result.ok) { 'OK' } else { 'BLOCKED' }))) -ForegroundColor ($(if ($result.ok) { 'Green' } else { 'Red' }))

$result
if (-not $result.ok) { $global:LASTEXITCODE = 1 } else { $global:LASTEXITCODE = 0 }
