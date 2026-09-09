#requires -Version 7.0
<#
.SYNOPSIS
  READ-ONLY. Turn a discovery result (users.json from Find-LicenseTargets.ps1) plus the operator's
  checkbox selection into the exact removal plan (selection.json) that Remove-TenantLicenses.ps1 consumes,
  and flag high-impact ("critical") accounts. Performs NO mutations.

.DESCRIPTION
  This replaces ad-hoc, hand-built selection JSON (which is fragile and tenant-specific). It is universal:
  it resolves everything from the discovery file and Microsoft Graph at run time, with no hard-coded ids.

  For every selected user it records:
    - removeSkuIds     : the target SKUs the user actually holds (from discovery).
    - dependentSkuIds  : the user's dependent add-on SKUs (only when -AllowDependents; these MAY be removed
                         at runtime if — and only if — they block a target removal). Pre-computed here from
                         the user's OWN held SKUs, not from error messages.
    - isCritical       : $true when the user is the signed-in operator or holds a privileged directory role
                         (Global Administrator, Privileged Role Administrator, User Administrator).
    - criticalReason   : why it was flagged.

  It writes selection.json (for the removal script) and, when -SummaryFile is given, a human-readable
  summary the wizard shows in the final confirmation. Microsoft does not publish a machine-readable
  service-plan dependency graph (see licensing-service-plan-reference); deeper prerequisites surface only
  at runtime and are handled/reported by Remove-TenantLicenses.ps1.

.PARAMETER UsersPath
  Path to users.json produced by Find-LicenseTargets.ps1 -Action FindUsers.

.PARAMETER SelectedObjectIds
  The object ids of the users the operator selected in the checkbox review (the boundary of the action).

.PARAMETER AllowDependents
  Include each selected user's dependent add-on SKUs in the plan (they are removed at runtime only if they
  block a target removal, and only because the operator approved dependents in the wizard).

.PARAMETER Subscription
  Target subscription id. Pins the az context (Graph uses the active account, not --subscription).

.PARAMETER TenantId
  Expected tenant id. Aborts if the signed-in az context is a different tenant.

.PARAMETER OutFile
  Path to write selection.json.

.PARAMETER SummaryFile
  Optional path to write a human-readable plan summary (one line per user).

.EXAMPLE
  pwsh -File .\Resolve-RemovalPlan.ps1 -UsersPath .\users.json -SelectedObjectIds <id1>,<id2> `
      -AllowDependents -Subscription <sub> -TenantId <tenant> -OutFile .\selection.json -SummaryFile .\plan-summary.txt
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UsersPath,
    [Parameter(Mandatory)][string[]]$SelectedObjectIds,
    [switch]$AllowDependents,
    [Parameter(Mandatory)][string]$Subscription,
    [string]$TenantId,
    [Parameter(Mandatory)][string]$OutFile,
    [string]$SummaryFile
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# `pwsh -File` passes comma-joined values as one literal string; split them back into a real array.
$SelectedObjectIds = @($SelectedObjectIds | ForEach-Object { $_ -split '[,\s]+' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($SelectedObjectIds.Count -eq 0) { throw "No -SelectedObjectIds supplied." }
if (-not (Test-Path -LiteralPath $UsersPath)) { throw "Users file not found: $UsersPath" }
$disc = Get-Content -LiteralPath $UsersPath -Raw | ConvertFrom-Json

# ---------------------------------------------------------------------------
# Context: pin subscription + verify tenant (Graph uses the active account).
# ---------------------------------------------------------------------------
az account set --subscription $Subscription | Out-Null
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' first." }
if ($TenantId -and $ctx.tenantId -ne $TenantId) {
    throw "az context tenant '$($ctx.tenantId)' != -TenantId '$TenantId'. Re-pin the context and retry."
}
$graphToken = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($graphToken)) {
    throw "Failed to acquire a Microsoft Graph token. Run: az login --tenant $($ctx.tenantId) --scope https://graph.microsoft.com/.default"
}
function Invoke-GraphGet { param([string]$Url) Invoke-RestMethod -Method GET -Uri $Url -Headers @{ Authorization = "Bearer $graphToken" } }

# ---------------------------------------------------------------------------
# Critical accounts: the signed-in operator + members of privileged directory roles.
# Role template ids are global constants (tenant-independent).
# ---------------------------------------------------------------------------
$privilegedRoleTemplates = @{
    '62e90394-69f5-4237-9190-012177145e10' = 'Global Administrator'
    'e8611ab8-c189-46e8-94e1-60213ab1f814' = 'Privileged Role Administrator'
    'fe930be7-5e62-47db-91af-98c3a49a38b1' = 'User Administrator'
}
$criticalById = @{}   # userId -> reason
$operatorUpn = $ctx.user.name
try {
    $me = Invoke-GraphGet -Url 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName'
    if ($me.id) { $criticalById[$me.id] = "signed-in operator ($($me.userPrincipalName))" }
}
catch { }
try {
    foreach ($role in (Invoke-GraphGet -Url 'https://graph.microsoft.com/v1.0/directoryRoles?$select=id,roleTemplateId').value) {
        if (-not $privilegedRoleTemplates.ContainsKey($role.roleTemplateId)) { continue }
        $roleName = $privilegedRoleTemplates[$role.roleTemplateId]
        $next = "https://graph.microsoft.com/v1.0/directoryRoles/$($role.id)/members?`$select=id"
        while ($next) {
            $page = Invoke-GraphGet -Url $next
            foreach ($m in $page.value) {
                if ($m.id) {
                    if ($criticalById.ContainsKey($m.id)) { if ($criticalById[$m.id] -notmatch [regex]::Escape($roleName)) { $criticalById[$m.id] += "; $roleName" } }
                    else { $criticalById[$m.id] = $roleName }
                }
            }
            $next = $page.'@odata.nextLink'
        }
    }
}
catch { }

# ---------------------------------------------------------------------------
# Build the plan for the selected users only (the action boundary).
# ---------------------------------------------------------------------------
$wanted = @{}; foreach ($id in $SelectedObjectIds) { $wanted[$id] = $true }
$planUsers = New-Object System.Collections.Generic.List[object]
foreach ($u in $disc.users) {
    if (-not $wanted.ContainsKey($u.id)) { continue }
    $reason = if ($criticalById.ContainsKey($u.id)) { $criticalById[$u.id] } else { $null }
    $planUsers.Add([pscustomobject]@{
            id                = $u.id
            userPrincipalName = $u.userPrincipalName
            displayName       = $u.displayName
            removeSkuIds      = @($u.targetSkus.skuId)
            removeSkuNames    = @($u.targetSkus.skuPartNumber)
            dependentSkuIds   = if ($AllowDependents) { @($u.dependentSkus.skuId) } else { @() }
            dependentSkuNames = if ($AllowDependents) { @($u.dependentSkus.skuPartNumber) } else { @() }
            isCritical        = [bool]$reason
            criticalReason    = $reason
        })
}

$plan = [pscustomobject]@{
    tenantId        = $disc.tenantId
    allowDependents = [bool]$AllowDependents
    operator        = $operatorUpn
    targetSkuIds    = @($disc.targetSkuIds)
    users           = @($planUsers.ToArray())
}
$outDir = Split-Path -Parent $OutFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$plan | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutFile -Encoding utf8

# ---------------------------------------------------------------------------
# Human-readable summary (one line per user) for the final confirmation.
# ---------------------------------------------------------------------------
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("Removal plan — tenant $($plan.tenantId) — operator $operatorUpn — allowDependents=$([bool]$AllowDependents)")
$lines.Add("Selected users: $($planUsers.Count)")
$lines.Add('')
foreach ($p in $planUsers) {
    $flag = if ($p.isCritical) { "  ⚠ CRITICAL: $($p.criticalReason)" } else { '' }
    $dep = if ($AllowDependents -and @($p.dependentSkuNames).Count) { "  (+ if blocking: $(@($p.dependentSkuNames) -join ', '))" } else { '' }
    $lines.Add(("{0,-45} remove: [{1}]{2}{3}" -f $p.userPrincipalName, (@($p.removeSkuNames) -join ', '), $dep, $flag))
}
$critical = @($planUsers | Where-Object { $_.isCritical })
$lines.Add('')
if ($critical.Count) {
    $lines.Add("⚠ $($critical.Count) CRITICAL account(s) in this plan — review before approving:")
    foreach ($c in $critical) { $lines.Add("   - $($c.userPrincipalName): $($c.criticalReason)") }
}
else { $lines.Add('No critical accounts detected in this plan.') }

if ($SummaryFile) {
    $sumDir = Split-Path -Parent $SummaryFile
    if ($sumDir -and -not (Test-Path -LiteralPath $sumDir)) { New-Item -ItemType Directory -Force -Path $sumDir | Out-Null }
    $lines -join [Environment]::NewLine | Set-Content -LiteralPath $SummaryFile -Encoding utf8
}
$lines -join [Environment]::NewLine | Write-Output
