#requires -Version 7.0
<#
.SYNOPSIS
  Remove the selected license assignments from the selected users, honouring dependent add-on licenses,
  writing a persistent removal log. Frees seats; it does NOT delete users.

.DESCRIPTION
  Consumes a JSON selection (the subset the operator confirmed in the checkbox review) and, for each
  user, removes the target SKUs via Microsoft Graph `POST /users/{id}/assignLicense`. It re-reads each
  user's live licenses first, so a stale discovery never removes the wrong thing.

  Dependency handling (Microsoft enforces license prerequisites at the API — you cannot remove a base
  license while a dependent add-on that requires it is still assigned):
    1. Attempt to remove ONLY the target SKUs.
    2. On success: done.
    3. On a prerequisite/dependency error:
         - if allowDependents is true  -> also remove the user's dependent add-on SKUs and retry once;
         - if allowDependents is false -> leave the base in place and log which add-ons blocked it.
    4. Any other error is logged; the run continues to the next user (never aborts the whole batch).

  This removes add-ons ONLY when they actually block a target removal and the operator granted
  permission — never pre-emptively. Every action (success, skip, error) is appended to a human-readable
  log. Graph calls use a token from `az account get-access-token` via Invoke-RestMethod.

.PARAMETER SelectionPath
  Path to the JSON selection:
    {
      "tenantId": "...",
      "allowDependents": true,
      "targetSkuIds": ["<guid>", ...],
      "users": [
        { "id":"<oid>", "userPrincipalName":"...", "removeSkuIds":["<guid>",...], "dependentSkuIds":["<guid>",...] }
      ]
    }

.PARAMETER Subscription
  Target subscription id. Pinned before every operation (Graph uses the active az account).

.PARAMETER TenantId
  Expected tenant id. The script aborts if the signed-in az context is a different tenant, and if it
  differs from the selection's tenantId.

.PARAMETER LogPath
  Path to the persistent removal log (appended). Defaults next to the selection file.

.PARAMETER WhatIf
  List what would be removed (WHATIF lines) without changing anything.

.PARAMETER Force
  Skip the final "type RECLAIM to proceed" confirmation.

.EXAMPLE
  pwsh -File .\Remove-TenantLicenses.ps1 -SelectionPath .\selection.json -Subscription <sub> -TenantId <tenant>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SelectionPath,
    [Parameter(Mandatory)][string]$Subscription,
    [string]$TenantId,
    [string]$LogPath,
    [switch]$WhatIf,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Test-Path -LiteralPath $SelectionPath)) { throw "Selection file not found: $SelectionPath" }
$selection = Get-Content -LiteralPath $SelectionPath -Raw | ConvertFrom-Json
$users = @($selection.users)
if (-not $users -or $users.Count -eq 0) { Write-Host "Selection has no users — nothing to do." -ForegroundColor Yellow; return }
$allowDependents = [bool]$selection.allowDependents

if (-not $LogPath) { $LogPath = Join-Path (Split-Path -Parent $SelectionPath) 'removal.log' }
$logDir = Split-Path -Parent $LogPath
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$resultPath = Join-Path $logDir 'result.json'
$results = New-Object System.Collections.Generic.List[object]

function Write-Log {
    param([string]$Status, [string]$Message)
    $line = "[{0}] [{1}] {2}" -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $Status, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
    $color = switch ($Status) { 'OK' { 'Green' } 'ERROR' { 'Red' } 'WHATIF' { 'Yellow' } 'SKIP' { 'DarkYellow' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# Context: pin subscription + verify tenant (Graph uses the active account).
# ---------------------------------------------------------------------------
az account set --subscription $Subscription | Out-Null
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' first." }
if ($TenantId -and $ctx.tenantId -ne $TenantId) {
    throw "az context tenant '$($ctx.tenantId)' != -TenantId '$TenantId'. Re-pin the context and retry."
}
if ($selection.tenantId -and $ctx.tenantId -ne $selection.tenantId) {
    throw "az context tenant '$($ctx.tenantId)' != selection tenant '$($selection.tenantId)'. Aborting to avoid touching the wrong directory."
}
$graphToken = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($graphToken)) {
    throw "Failed to acquire a Microsoft Graph token. Run: az login --tenant $($ctx.tenantId) --scope https://graph.microsoft.com/.default"
}
$signedIn = $ctx.user.name

Write-Log 'INFO' "=== License reclaim started by '$signedIn' — tenant $($ctx.tenantId), subscription $($ctx.id), $($users.Count) user(s), allowDependents=$allowDependents$(if($WhatIf){' [WHATIF]'}) ==="

# ---------------------------------------------------------------------------
# Final confirmation (unless -Force / -WhatIf).
# ---------------------------------------------------------------------------
if (-not $WhatIf -and -not $Force) {
    Write-Host ""
    Write-Host "About to remove license assignments from $($users.Count) user(s) in tenant $($ctx.tenantId)." -ForegroundColor Red
    $users | ForEach-Object { Write-Host ("  {0} — {1} target sku(s){2}" -f $_.userPrincipalName, @($_.removeSkuIds).Count, $(if ($allowDependents -and @($_.dependentSkuIds).Count) { " (+ up to $(@($_.dependentSkuIds).Count) dependent add-on(s) if needed)" } else { '' })) -ForegroundColor Gray }
    $answer = Read-Host "Type RECLAIM to proceed (anything else cancels)"
    if ($answer -ne 'RECLAIM') { Write-Log 'INFO' 'Cancelled at final confirmation.'; return }
}

# ---------------------------------------------------------------------------
# Graph helpers.
# ---------------------------------------------------------------------------
function Get-UserSkuIds {
    param([string]$UserId)
    try {
        $r = Invoke-RestMethod -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$UserId/licenseDetails" -Headers @{ Authorization = "Bearer $graphToken" }
        return @($r.value | ForEach-Object { $_.skuId } | Where-Object { $_ })
    }
    catch { return @() }
}

function Invoke-RemoveLicenses {
    param([string]$UserId, [string[]]$RemoveSkuIds)
    $body = @{ addLicenses = @(); removeLicenses = @($RemoveSkuIds) } | ConvertTo-Json -Depth 4 -Compress
    try {
        Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/v1.0/users/$UserId/assignLicense" `
            -Headers @{ Authorization = "Bearer $graphToken"; 'Content-Type' = 'application/json' } -Body $body | Out-Null
        return @{ ok = $true; message = 'removed' }
    }
    catch {
        $msg = $_.ErrorDetails.Message
        if (-not $msg) { $msg = $_.Exception.Message }
        return @{ ok = $false; message = ($msg | Out-String).Trim() }
    }
}

function Test-DependencyError {
    param([string]$Message)
    return [bool]($Message -match '(?i)(depend|prerequisit|cannot be removed|is required|required for|because.*licens)')
}

# Same add-on classifier as Find-LicenseTargets.ps1 (kept in sync): products that require a base plan.
function Test-IsAddOnPart {
    param([string]$Part)
    return [bool]($Part -match '(?i)(project|visio|MCOEV|PHONESYSTEM|MCOPSTN|MCOMEETADV|MCOCAP|AUDIO[_ ]?CONFERENC|POWER[_ ]?BI|FLOW_|POWERAUTOMATE|POWER[_ ]?AUTOMATE|POWERAPPS|POWER[_ ]?APPS|TEAMS[_ ]?PHONE|CALLING)')
}

# Build a skuId -> partNumber map so add-on SKUs held live can be named/resolved for the fallback,
# plus service-plan maps so a hard dependency conflict can be explained instead of dumped as raw JSON.
$skuMap = @{}      # skuId  -> skuPartNumber
$skuPlans = @{}    # skuId  -> @(servicePlanId, ...)
$planName = @{}    # planId -> servicePlanName
try {
    foreach ($s in (Invoke-RestMethod -Method GET -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus' -Headers @{ Authorization = "Bearer $graphToken" }).value) {
        $skuMap[$s.skuId] = $s.skuPartNumber
        $skuPlans[$s.skuId] = @($s.servicePlans | ForEach-Object { $_.servicePlanId })
        foreach ($p in $s.servicePlans) { $planName[$p.servicePlanId] = $p.servicePlanName }
    }
}
catch { }

# A `servicePlanDependencyConflict` means an UNSELECTED, retained license still needs a service plan the
# removal would strip (e.g. a Dynamics/Power Platform bundle needing Calling/Power BI plans). Removing
# add-ons cannot fix it — the base is left in place. Parse the error so the log names the culprit.
function Get-ServicePlanConflict {
    param([string]$Message, [string[]]$LiveSkuIds, [string[]]$RemoveSkuIds)
    $out = [pscustomobject]@{ isConflict = $false; planNames = @(); blockingSkus = @() }
    if ($Message -notmatch '(?i)servicePlanDependencyConflict') { return $out }
    $ids = @()
    try { $ids = @(($Message | ConvertFrom-Json).error.innerError.properties.dependsOnServicePlanIds) } catch { }
    if (-not $ids -or $ids.Count -eq 0) { $ids = @([regex]::Matches($Message, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') | ForEach-Object { $_.Value }) }
    $ids = @($ids | Where-Object { $_ } | Select-Object -Unique)
    $retained = @($LiveSkuIds | Where-Object { $RemoveSkuIds -notcontains $_ })
    $out.isConflict = $true
    $out.planNames = @($ids | ForEach-Object { if ($planName[$_]) { $planName[$_] } else { $_ } } | Select-Object -Unique)
    $out.blockingSkus = @($retained | Where-Object { $skuPlans[$_] -and (@($skuPlans[$_] | Where-Object { $ids -contains $_ }).Count -gt 0) } | ForEach-Object { if ($skuMap[$_]) { $skuMap[$_] } else { $_ } } | Select-Object -Unique)
    return $out
}

# ---------------------------------------------------------------------------
# Remove per user.
# ---------------------------------------------------------------------------
foreach ($u in $users) {
    $uid = $u.id
    $upn = $u.userPrincipalName
    $live = Get-UserSkuIds -UserId $uid
    $toRemove = @($u.removeSkuIds | Where-Object { $live -contains $_ })

    if ($toRemove.Count -eq 0) {
        Write-Log 'INFO' "user $upn ($uid) holds none of the requested target SKUs (already released)"
        $results.Add([pscustomobject]@{ id = $uid; upn = $upn; status = 'SKIP'; removed = @(); message = 'no target sku held' })
        continue
    }

    $namesOf = { param($ids) @($ids | ForEach-Object { if ($skuMap[$_]) { $skuMap[$_] } else { $_ } }) }

    if ($WhatIf) {
        Write-Log 'WHATIF' "would remove [$(( & $namesOf $toRemove) -join ', ')] from $upn ($uid)$(if($allowDependents -and @($u.dependentSkuIds).Count){ ' (+ dependents if the base is blocked)' })"
        $results.Add([pscustomobject]@{ id = $uid; upn = $upn; status = 'WHATIF'; removed = @($toRemove); message = 'dry run' })
        continue
    }

    # Attempt 1: targets only.
    $r = Invoke-RemoveLicenses -UserId $uid -RemoveSkuIds $toRemove
    if ($r.ok) {
        Write-Log 'OK' "removed [$(( & $namesOf $toRemove) -join ', ')] from $upn ($uid)"
        $results.Add([pscustomobject]@{ id = $uid; upn = $upn; status = 'OK'; removed = @($toRemove); message = 'targets removed' })
        continue
    }

    # A hard service-plan dependency from an UNSELECTED retained license cannot be fixed by removing
    # add-ons — leave the base in place with a readable reason (never a raw error blob).
    $conf = Get-ServicePlanConflict -Message $r.message -LiveSkuIds $live -RemoveSkuIds $toRemove
    if ($conf.isConflict) {
        $reason = "blocked by retained license(s) [$($conf.blockingSkus -join ', ')] that still require service plan(s) [$($conf.planNames -join ', ')] — outside the reclaim scope"
        Write-Log 'SKIP' "left [$(( & $namesOf $toRemove) -join ', ')] in place for $upn ($uid): $reason"
        $results.Add([pscustomobject]@{ id = $uid; upn = $upn; status = 'SKIP'; removed = @(); message = $reason })
        continue
    }

    if (Test-DependencyError $r.message) {
        # Dependent add-ons block the base removal.
        $liveAddOns = @($live | Where-Object { ($toRemove -notcontains $_) -and $skuMap[$_] -and (Test-IsAddOnPart $skuMap[$_]) })
        if (-not $allowDependents) {
            Write-Log 'SKIP' "base removal for $upn ($uid) is blocked by dependent add-on(s) [$(( & $namesOf $liveAddOns) -join ', ')]; permission to remove dependents was not granted — leaving licenses in place"
            $results.Add([pscustomobject]@{ id = $uid; upn = $upn; status = 'SKIP'; removed = @(); message = "blocked by dependents: $(( & $namesOf $liveAddOns) -join ', ')" })
            continue
        }
        $set2 = @(@($toRemove) + @($liveAddOns) | Select-Object -Unique)
        $r2 = Invoke-RemoveLicenses -UserId $uid -RemoveSkuIds $set2
        if ($r2.ok) {
            Write-Log 'OK' "removed targets + dependents [$(( & $namesOf $set2) -join ', ')] from $upn ($uid)"
            $results.Add([pscustomobject]@{ id = $uid; upn = $upn; status = 'OK'; removed = @($set2); message = 'targets + dependents removed' })
            continue
        }
        $conf2 = Get-ServicePlanConflict -Message $r2.message -LiveSkuIds $live -RemoveSkuIds $set2
        if ($conf2.isConflict) {
            $reason2 = "blocked by retained license(s) [$($conf2.blockingSkus -join ', ')] that still require service plan(s) [$($conf2.planNames -join ', ')] — outside the reclaim scope"
            Write-Log 'SKIP' "left [$(( & $namesOf $set2) -join ', ')] in place for $upn ($uid): $reason2"
            $results.Add([pscustomobject]@{ id = $uid; upn = $upn; status = 'SKIP'; removed = @(); message = $reason2 })
            continue
        }
        Write-Log 'ERROR' "removal still failed for $upn ($uid) after including dependents: $($r2.message)"
        $results.Add([pscustomobject]@{ id = $uid; upn = $upn; status = 'ERROR'; removed = @(); message = $r2.message })
        continue
    }

    Write-Log 'ERROR' "removal failed for $upn ($uid): $($r.message)"
    $results.Add([pscustomobject]@{ id = $uid; upn = $upn; status = 'ERROR'; removed = @(); message = $r.message })
}

# ---------------------------------------------------------------------------
# Verify + report.
# ---------------------------------------------------------------------------
if (-not $WhatIf) {
    foreach ($u in $users) {
        $still = @(Get-UserSkuIds -UserId $u.id | Where-Object { $u.removeSkuIds -contains $_ })
        if ($still.Count -gt 0) { Write-Log 'INFO' "post-check: $($u.userPrincipalName) still holds $($still.Count) target sku(s)" }
    }
}
$results | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding utf8
$ok = @($results | Where-Object { $_.status -eq 'OK' }).Count
$skip = @($results | Where-Object { $_.status -eq 'SKIP' }).Count
$err = @($results | Where-Object { $_.status -eq 'ERROR' }).Count
Write-Log 'INFO' "=== Done. removed=$ok skipped=$skip errors=$err — result: $resultPath ==="

# ---------------------------------------------------------------------------
# Concise, human-readable final report (always produced): which licenses were removed from which users.
# ---------------------------------------------------------------------------
$nameList = { param($ids) (@($ids | ForEach-Object { if ($skuMap[$_]) { $skuMap[$_] } else { $_ } }) -join ', ') }
$reportPath = Join-Path $logDir 'report.txt'
$rep = New-Object System.Collections.Generic.List[string]
$verb = if ($WhatIf) { 'WOULD REMOVE (dry run)' } else { 'REMOVED' }
$rep.Add("License reclaim report — tenant $($ctx.tenantId) — operator $signedIn — $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))")
$rep.Add("Summary: removed=$ok  skipped/left-in-place=$skip  errors=$err  (users in plan: $($results.Count))")
$rep.Add('')
$rep.Add("== $verb ==")
$done = @($results | Where-Object { $_.status -in @('OK', 'WHATIF') })
if ($done.Count) { foreach ($x in $done) { $rep.Add(("  {0,-45} {1}" -f $x.upn, (& $nameList $x.removed))) } } else { $rep.Add('  (none)') }
$left = @($results | Where-Object { $_.status -eq 'SKIP' })
if ($left.Count) {
    $rep.Add('')
    $rep.Add('== LEFT IN PLACE (not removed) ==')
    foreach ($x in $left) { $rep.Add(("  {0,-45} {1}" -f $x.upn, $x.message)) }
}
$bad = @($results | Where-Object { $_.status -eq 'ERROR' })
if ($bad.Count) {
    $rep.Add('')
    $rep.Add('== ERRORS ==')
    foreach ($x in $bad) { $firstLine = ($x.message -split "`n")[0]; $rep.Add(("  {0,-45} {1}" -f $x.upn, $firstLine)) }
}
$reportText = $rep -join [Environment]::NewLine
Set-Content -LiteralPath $reportPath -Value $reportText -Encoding utf8
Write-Host ''
Write-Host $reportText -ForegroundColor Cyan
Write-Host ''
Write-Host "Report: $reportPath" -ForegroundColor Cyan
Write-Output (Get-Content -LiteralPath $resultPath -Raw)
