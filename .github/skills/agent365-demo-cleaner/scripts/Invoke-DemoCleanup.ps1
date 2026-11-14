#requires -Version 7.0
<#
.SYNOPSIS
  Deletes the elements of a confirmed Demo Cleaner plan in deletion order, hard (nothing left in a recycle bin), updating
  cleanup-plan.json and the live HTML report after every element; ends with statistics, problems, solutions and the
  notes for rebuilding a lab in the same tenant, subscription and language.
.DESCRIPTION
  -Apply requires the second gate (Set-DemoCleanupSelection.ps1 -Confirm); -WhatIf also works on the previewed selection,
  before the confirmation. Without -Apply or -WhatIf it only prints the status.
  Azure/Entra components and agents are deleted by the Lab Cleaner's Remove-CleanupResources.ps1 (one element per call,
  unchanged), Copilot Studio agents by Remove-McsAgent.ps1 -UseDataverseApi, Purview policies through Security &
  Compliance PowerShell and soft-deleted mailboxes through Exchange Online PowerShell when the module is installed.
  Manual portal actions pause the run (exit code 10, pending-manual.json) or, with -ManualMode defer, are recorded as
  "could not delete - manual action pending" and the run goes on. The operator's answer is given back with -Done,
  -Absent or -Defer; -Retry tries again what could not be deleted. Resource-group deletions run in parallel and are
  awaited (default 60 minutes) before the final checks.
.EXAMPLE
  pwsh -File .\Invoke-DemoCleanup.ps1 -RunDir <run folder> -WhatIf
.EXAMPLE
  pwsh -File .\Invoke-DemoCleanup.ps1 -RunDir <run folder> -Apply
.EXAMPLE
  pwsh -File .\Invoke-DemoCleanup.ps1 -RunDir <run folder> -Apply -Done 3,4 -Absent 5
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)][string]$RunDir,
    [switch]$Apply,
    [switch]$WhatIf,
    [string]$Done = '',
    [string]$Absent = '',
    [string]$Defer = '',
    [switch]$Retry,
    [string]$Only = '',
    [ValidateSet('pause', 'defer')][string]$ManualMode,
    [int]$RgTimeoutMinutes = 60,
    [switch]$NoWait
)
$ErrorActionPreference = 'Stop'
$builder = Join-Path $PSScriptRoot '..\..\agent365-demo-builder\scripts'
. (Join-Path $builder '_demo-common.ps1')
. (Join-Path $builder '_demo-entra.ps1')
. (Join-Path $PSScriptRoot '..\..\agent365-demo-reset\scripts\_demo-registry.ps1')
. (Join-Path $PSScriptRoot '_demo-cleaner.ps1')
$cp = Read-CleanupPlan $RunDir
$RunDir = $cp.runDir
$ctx = $cp.context
$G = 'https://graph.microsoft.com/v1.0'
$script:LcRemove = Join-Path $script:DemoRepoRoot '.github\skills\agent365-cleanup\scripts\Remove-CleanupResources.ps1'
$script:LcFolders = Join-Path $script:DemoRepoRoot '.github\skills\agent365-cleanup\scripts\Remove-GeneratedFolders.ps1'
$script:McsRemove = Join-Path $script:DemoRepoRoot '.github\skills\agent365-copilot-studio\scripts\Remove-McsAgent.ps1'
function Log([string]$m, [string]$l = 'INFO') { Write-CleanupLog $RunDir $m $l }
function Result([string]$Status, [string]$Reason = '', [string]$Notes = '') { [pscustomobject]@{ status = $Status; reason = $Reason; notes = $Notes } }
function Get-Indexes([string]$Spec) { @(ConvertFrom-CleanupSpec $cp $Spec) }

# ------------------------------------------------------------------------------------------------- status only
if (-not $Apply -and -not $WhatIf) {
    $s = Get-CleanupStats $cp
    Write-Host ("Phase {0}: {1} element(s) · to be deleted {2} · deleted {3} · could not delete {4} · excluded {5}" -f $cp.phase, $s.total, $s.toDelete, $s.deleted, $s.failed, $s.excluded)
    foreach ($it in @($cp.items | Where-Object { $_.status -eq 'failed' })) { Write-Host ("  #{0} {1} [{2}] {3}" -f $it.index, $it.name, $it.reason, $it.notes) }
    Write-Host "Report: $(Get-CleanupReportUri $RunDir)"
    return
}
if ($cp.mode -eq 'snapshot') { throw 'This run is a snapshot preview: run a live discovery first.' }
if ($ManualMode) { $cp['manualMode'] = $ManualMode }

# ------------------------------------------------------------------------------------------------- dry run (local only)
# On the confirmed selection or on the one previewed by Set-DemoCleanupSelection.ps1 without -Confirm.
if ($WhatIf) {
    if ($cp.phase -eq 'discovery') { throw 'The discovery has not finished yet: wait for it (phase review), then run the dry run.' }
    $lines = @(foreach ($it in @($cp.items | Where-Object { $_.status -eq 'toDelete' } | Sort-Object { [int]$_.index })) {
        $what = switch ($it.executor) {
            'manual' { "MANUAL: $($it.manual.where) - $(@($it.manual.steps) -join ' ')" }
            'lab-cleaner' { "Lab Cleaner $($it.action) ($($it.data.labItem.kind) $($it.data.labItem.id))" }
            'covered' { "removed with $($it.coveredBy)" }
            default { "$($it.executor) $($it.action)" }
        }
        "WHATIF #{0} [{1}] {2}: {3}" -f $it.index, $it.type, $it.name, $what
    })
    $lines | Set-Content -LiteralPath (Join-Path $RunDir 'whatif.log') -Encoding utf8
    $lines | ForEach-Object { Write-Host $_ }
    $cp.selection.whatIfAt = (Get-Date).ToString('o')
    Save-CleanupPlan $cp
    Write-Host "Dry run: nothing deleted. $($lines.Count) element(s) would be processed. Log: $(Join-Path $RunDir 'whatif.log')"
    return
}
if (-not $cp.selection.confirmedAt) { throw 'The second gate is not confirmed: run Set-DemoCleanupSelection.ps1 -RunDir <run> [-Exclude ...] -Confirm first.' }

# ------------------------------------------------------------------------------------------------- authentication
if ($ctx.auth.mode -eq 'lab') {
    $abs = if ([IO.Path]::IsPathRooted([string]$ctx.auth.azConfigDir)) { [string]$ctx.auth.azConfigDir } else { Join-Path $script:DemoRepoRoot $ctx.auth.azConfigDir }
    if (-not (Test-Path -LiteralPath $abs)) {
        $ctx.auth.mode = 'session'
        if (-not $ctx.auth.sessionDir) { $ctx.auth.sessionDir = Join-Path $RunDir 'auth' }
        Log "The lab-private az profile is gone (local folder deleted): switching to the session authentication directory $($ctx.auth.sessionDir)" 'WARN'
    }
}
$cfg = Use-CleanupAuth $ctx
$tid = ([string](az account show --query tenantId -o tsv 2>$null)).Trim()
if ($tid -ne $ctx.tenantId) { throw "The isolated az context is not signed in to tenant $($ctx.tenantId) (current: '$tid'). Sign in interactively (browser, never device code): $(Get-CleanupLoginCommand $ctx)" }
az account set --subscription $ctx.subscriptionId 2>$null | Out-Null

# ------------------------------------------------------------------------------------------------- helpers
function Test-DirectoryObjectGone([string]$Id) {
    if (-not $Id) { return $true }
    for ($i = 0; $i -lt 6; $i++) {
        $live = Get-CleanupObject "$G/directoryObjects/$Id`?`$select=id"
        $bin = if (-not $live) { Get-CleanupObject "$G/directory/deletedItems/$Id`?`$select=id" } else { $null }
        if (-not $live -and -not $bin) { return $true }
        if (-not $live -and $bin) { $null = Invoke-DemoGraph DELETE "$G/directory/deletedItems/$Id" -NoThrow -MaxRetries 1 }
        Start-Sleep -Seconds 10
    }
    return $false
}

function Invoke-LabCleanerItem($Item) {
    $li = $Item.data.labItem
    $lcDir = Join-Path $RunDir 'lab-cleaner'
    New-Item -ItemType Directory -Force -Path $lcDir | Out-Null
    if ($Item.data.skipIfAbsent -and $li.objectId) {
        if (-not (Get-CleanupObject "$G/directoryObjects/$($li.objectId)?`$select=id")) {
            $bin = Get-CleanupObject "$G/directory/deletedItems/$($li.objectId)?`$select=id"
            if (-not $bin) { return Result 'deleted' '' 'Already removed by the platform together with the object it belongs to.' }
            $li.action = 'purge-deleted-item'
        }
    }
    if ($li.action -eq 'purge-deleted-item') {
        $binObj = Get-CleanupObject "$G/directory/deletedItems/$(if ($li.objectId) { $li.objectId } else { $li.id })"
        if (Test-CleanupManagedIdentity $binObj) { return Result 'failed' 'limitation' (Get-CleanupManagedIdentityNote @($binObj)) }
    }
    $sel = Join-Path $lcDir ('selection-{0:000}.json' -f [int]$Item.index)
    Set-Content -LiteralPath $sel -Value ('[' + ($li | ConvertTo-Json -Depth 12) + ']') -Encoding utf8
    $resultPath = Join-Path $lcDir 'result.json'
    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
    $lcLog = Join-Path $lcDir 'deletion.log'
    $lcLines = if (Test-Path -LiteralPath $lcLog) { @(Get-Content -LiteralPath $lcLog).Count } else { 0 }
    $out = & pwsh -NoProfile -File $script:LcRemove -SelectionPath $sel -Subscription $ctx.subscriptionId -TenantId $ctx.tenantId -LogPath $lcLog -Force 2>&1
    $res = if (Test-Path -LiteralPath $resultPath) { @(Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json) | Select-Object -First 1 } else { $null }
    if (-not $res) { return Result 'failed' 'error' "The Lab Cleaner produced no result (exit $LASTEXITCODE): $((@($out) | Select-Object -Last 3) -join ' '). See lab-cleaner\deletion.log, fix the cause and run again with -Retry." }
    if ($res.status -eq 'ERROR') {
        $logText = (@(Get-Content -LiteralPath $lcLog -ErrorAction SilentlyContinue) | Select-Object -Skip $lcLines) -join "`n"
        if (Test-CleanupConnectorRefusal $li $logText) { return Remove-ManagedConnector $li }
        return Result 'failed' 'error' "Lab Cleaner: $($res.message). Details in lab-cleaner\deletion.log; fix the cause (permissions, locks, dependencies) and run again with -Retry."
    }
    if ($res.status -eq 'SKIP' -and $res.message -eq 'unknown action') { return Result 'failed' 'error' "The Lab Cleaner does not support the action '$($li.action)' (older scripts?): update the Lab Cleaner, then run again with -Retry." }
    switch ($li.action) {
        'delete-rg' {
            if ($res.status -eq 'SKIP') { return Result 'deleted' '' 'Already absent.' }
            $Item.data['asyncStartedAt'] = (Get-Date).ToString('o')
            return Result 'async' '' "Deletion started at $(Get-Date -Format 'HH:mm') (asynchronous: the status changes when Azure has finished)."
        }
        { $_ -in 'remove-licenses-and-delete-user', 'delete-app', 'delete-sp', 'purge-deleted-item' } {
            $oid = if ($li.objectId) { $li.objectId } else { $li.id }
            if (Test-DirectoryObjectGone $oid) {
                $n = if ($li.action -eq 'remove-licenses-and-delete-user') { 'Licenses removed, user deleted and purged: no soft-deleted copy left.' } else { 'Deleted and purged from the Entra recycle bin.' }
                return Result 'deleted' '' $n
            }
            return Result 'failed' 'error' "Still present or still in the Entra recycle bin after the deletion. Purge it from Entra > Deleted items (or wait for replication) and run again with -Retry."
        }
        'purge-cognitiveservices' {
            # An account the Lab Cleaner could not delete (one with Foundry projects) is still live: it is soft-deleted with its
            # resource group and purged after the resource-group wait (Complete-CognitiveServicesPurges).
            $live = az cognitiveservices account show -n $li.id -g $li.resourceGroup --subscription $ctx.subscriptionId --query id -o tsv 2>$null
            if ($live) { $Item.data['purgeAfterRg'] = $true; return Result 'failed' 'pending' 'Still live after the delete attempt (an account with Foundry projects goes with its resource group): purged after the resource-group deletion.' }
            $left = @(az cognitiveservices account list-deleted --subscription $ctx.subscriptionId -o json 2>$null | ConvertFrom-Json | Where-Object { $_.name -eq $li.id })
            if ($left.Count) { return Result 'failed' 'error' "Still soft-deleted: az cognitiveservices account purge --location $($li.location) --resource-group $($li.resourceGroup) --name $($li.id), then -Retry." }
            return Result 'deleted' '' 'Deleted and purged (name and regional quota released).'
        }
        'purge-loganalytics' { return Result 'deleted' '' $(if ($res.status -eq 'SKIP') { 'Already absent.' } else { 'Force-deleted (no soft-deleted copy left).' }) }
        default { return Result 'deleted' '' $(if ($res.status -eq 'SKIP') { 'Already absent.' } else { [string]$res.message }) }
    }
}

# Platform-managed tool connector (shared_tc-) of an ext_ MCP server, refused by the maker API even to the admin: the
# Power Apps admin API is tried, then the connector is read back; when it stays, it is a platform limitation.
function Remove-ManagedConnector($LabItem) {
    $t = Get-DemoAzToken -Resource 'https://service.powerapps.com/' -TenantId $ctx.tenantId
    $api = 'https://api.powerapps.com/providers/Microsoft.PowerApps'
    $del = Invoke-DemoGraph DELETE "$api/scopes/admin/environments/$($LabItem.environment)/apis/$($LabItem.id)?api-version=2016-11-01" -Token $t -NoThrow -MaxRetries 2
    $left = Invoke-DemoGraph GET "$api/apis/$($LabItem.id)?api-version=2016-11-01&`$filter=$([uri]::EscapeDataString("environment eq '$($LabItem.environment)'"))" -Token $t -NoThrow -MaxRetries 2
    if ($left -and $left.PSObject.Properties['error'] -and $left.status -eq 404) { return Result 'deleted' '' 'Platform-managed tool connector deleted through the Power Apps admin API (the maker API refused it).' }
    $why = if ($del -and $del.PSObject.Properties['error']) { "admin API: HTTP $($del.status)" } else { 'still listed after the admin API delete' }
    return Result 'failed' 'limitation' "Platform-managed tool connector of the ext_ MCP server: the platform refuses its deletion, also to the admin (maker API: ApiAuthorizationFailed; $why). It stays with the blocked server, whose name is never reused."
}

# Registry packages still in the registry. The detail of a package whose agent is gone can answer 424 for a while: such a
# package counts as gone when the registry lists (agents and skills) no longer contain it.
$script:RegistryListedIds = $null
function Get-RegistryListedIds {
    if ($null -eq $script:RegistryListedIds) {
        $tok = Get-DemoRegToken $cfg
        $agents = @(Invoke-DemoGraph GET "$script:DemoG/beta/copilot/admin/catalog/packages" -Token $tok -All)
        $skills = @(Invoke-DemoGraph GET "$script:DemoG/beta/copilot/admin/catalog/packages?`$filter=$([uri]::EscapeDataString("elementTypes/any(e:e eq 'AgentSkills')"))" -Token $tok -All)
        $script:RegistryListedIds = @(@($agents) + @($skills) | ForEach-Object { [string]$_.id } | Where-Object { $_ })
    }
    return $script:RegistryListedIds
}
function Get-RemainingPackages([string[]]$Ids) {
    @(foreach ($id in @($Ids | Where-Object { $_ })) {
        $r = Invoke-DemoReg $cfg GET "$script:DemoG/beta/copilot/admin/catalog/packages/$id"
        if ($r.ok) { $id; continue }
        if ($r.status -eq 404) { continue }
        # 424 while still listed: the in-between state right after the deletion of its agent (still remaining).
        if ($r.status -eq 424) { if (@(Get-RegistryListedIds) -contains $id) { $id }; continue }
        throw "Registry package $id could not be read ($($r.status)): $($r.error)"
    })
}

# Agent registrations (Agent 365) of the code agents outlive their Entra identity and keep their registry entry listed.
# No list API exists: the id is the agentRegistrationId that the Lab Builder records in the lab folder
# (a365.generated.config.json, matched on agenticAppId); the registration is deleted only when its display name and agent
# identity match the registry package. Returns the deleted registration ids.
$script:LabRegistrationConfigs = $null
function Remove-PackageRegistration([string]$PackageId) {
    $pk = Invoke-DemoReg $cfg GET "$script:DemoG/beta/copilot/admin/catalog/packages/$PackageId"
    if (-not $pk.ok -or -not [string]$pk.body.agentIdentityId) { return }
    if ($null -eq $script:LabRegistrationConfigs) {
        $script:LabRegistrationConfigs = @(if ($ctx.labRoot -and (Test-Path -LiteralPath $ctx.labRoot)) {
                Get-ChildItem -LiteralPath $ctx.labRoot -Recurse -File -Filter 'a365.generated.config.json' -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -notmatch '\\secrets\\' } |
                    ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch { } }
            })
    }
    foreach ($regId in @(Get-CleanupRegistrationIds $script:LabRegistrationConfigs ([string]$pk.body.agentIdentityId))) {
        $reg = Invoke-DemoReg $cfg GET "$script:DemoG/beta/copilot/agentRegistrations/$regId"
        if (-not $reg.ok -or [string]$reg.body.agentIdentityId -ne [string]$pk.body.agentIdentityId -or [string]$reg.body.displayName -ne [string]$pk.body.displayName) { continue }
        $del = Invoke-DemoReg $cfg DELETE "$script:DemoG/beta/copilot/agentRegistrations/$regId"
        if ($del.ok -or $del.status -eq 404) { $regId }
    }
}

function Invoke-GraphItem($Item) {
    $d = $Item.data
    switch ($Item.action) {
        'delete-ca-policy' {
            $t = Get-CleanupGraphToken $cfg
            $id = [string]$d.id
            if (-not $id) { $id = [string](@((Get-CleanupObject "$G/identity/conditionalAccess/policies?`$filter=$([uri]::EscapeDataString("displayName eq '$($d.name.Replace("'", "''"))'"))" $t).value) | Select-Object -First 1).id }
            if (-not $id -or -not (Get-CleanupObject "$G/identity/conditionalAccess/policies/$id" $t)) { return Result 'deleted' '' 'Already absent.' }
            Invoke-DemoGraph DELETE "$G/identity/conditionalAccess/policies/$id" -Token $t | Out-Null
            if (Get-CleanupObject "$G/identity/conditionalAccess/policies/$id" $t) { return Result 'failed' 'error' 'Still present after the deletion: delete it in Entra > Conditional Access, then -Retry.' }
            return Result 'deleted' '' 'Deleted (Conditional Access policies have no recycle bin).'
        }
        'delete-access-package' {
            $t = Get-CleanupGraphToken $cfg
            $em = "$G/identityGovernance/entitlementManagement"
            $ap = Get-CleanupObject "$em/accessPackages/$($d.id)?`$expand=assignmentPolicies" $t
            if (-not $ap) { return Result 'deleted' '' 'Already absent.' }
            foreach ($rq in @(Invoke-DemoGraph GET "$em/assignmentRequests?`$expand=accessPackage" -Token $t -All | Where-Object { $_.accessPackage.id -eq $d.id -and $_.state -notin 'delivered', 'canceled', 'denied', 'failed', 'partiallyDelivered' })) {
                $null = Invoke-DemoGraph POST "$em/assignmentRequests/$($rq.id)/cancel" -Token $t -NoThrow
            }
            $flt = [uri]::EscapeDataString("accessPackage/id eq '$($d.id)'")
            $delivered = @(Invoke-DemoGraph GET "$em/assignments?`$filter=$flt" -Token $t -All | Where-Object { $_.state -eq 'delivered' })
            foreach ($as in $delivered) { $null = Invoke-DemoGraph POST "$em/assignmentRequests" -Token $t -Body @{ requestType = 'adminRemove'; assignment = @{ id = $as.id } } }
            for ($i = 0; $i -lt 20 -and @(Invoke-DemoGraph GET "$em/assignments?`$filter=$flt" -Token $t -All | Where-Object { $_.state -in 'delivered', 'delivering' }).Count; $i++) { Start-Sleep -Seconds 30 }
            foreach ($pol in @($ap.assignmentPolicies)) { $null = Invoke-DemoGraph DELETE "$em/assignmentPolicies/$($pol.id)" -Token $t -NoThrow }
            $r = Invoke-DemoGraph DELETE "$em/accessPackages/$($d.id)" -Token $t -NoThrow
            if ($r -and $r.PSObject.Properties['error']) { return Result 'failed' 'error' "Delete refused: $($r.error). Remove the remaining assignments in Entra > ID Governance > Access packages, then -Retry." }
            return Result 'deleted' '' "Deleted after removing $($delivered.Count) assignment(s) and $(@($ap.assignmentPolicies).Count) policy(ies)."
        }
        'delete-catalog' {
            $t = Get-CleanupGraphToken $cfg
            $em = "$G/identityGovernance/entitlementManagement"
            if (-not (Get-CleanupObject "$em/catalogs/$($d.id)" $t)) { return Result 'deleted' '' 'Already absent.' }
            $left = @(Invoke-DemoGraph GET "$em/accessPackages?`$filter=$([uri]::EscapeDataString("catalog/id eq '$($d.id)'"))" -Token $t -All)
            if ($left.Count) { return Result 'failed' 'dependency' "It still contains access packages ($(@($left.displayName) -join ', ')): delete them first, then -Retry." }
            foreach ($res in @(Invoke-DemoGraph GET "$em/catalogs/$($d.id)/resources" -Token $t -All)) {
                $null = Invoke-DemoGraph POST "$em/resourceRequests" -Token $t -NoThrow -Body @{ requestType = 'adminRemove'; resource = @{ originId = $res.originId; originSystem = $res.originSystem }; catalog = @{ id = $d.id } }
            }
            for ($i = 0; $i -lt 10 -and @(Invoke-DemoGraph GET "$em/catalogs/$($d.id)/resources" -Token $t -All).Count; $i++) { Start-Sleep -Seconds 15 }
            $r = Invoke-DemoGraph DELETE "$em/catalogs/$($d.id)" -Token $t -NoThrow
            if ($r -and $r.PSObject.Properties['error']) { return Result 'failed' 'error' "Delete refused: $($r.error). Remove its resources in Entra > ID Governance > Catalogs, then -Retry." }
            return Result 'deleted' '' 'Deleted (its resources removed first).'
        }
        'delete-ediscovery-case' {
            $t = Get-CleanupGraphToken $cfg
            $base = "$G/security/cases/ediscoveryCases"
            $id = [string]$d.id
            if (-not $id -and $d.name) { $id = [string](@((Get-CleanupObject "$base`?`$filter=$([uri]::EscapeDataString("displayName eq '$($d.name.Replace("'", "''"))'"))" $t).value) | Select-Object -First 1).id }
            $case = if ($id) { Get-CleanupObject "$base/$id" $t } else { $null }
            if (-not $case) { return Result 'deleted' '' 'Already absent.' }
            foreach ($h in @(Invoke-DemoGraph GET "$base/$id/legalHolds" -Token $t -All)) { $null = Invoke-DemoGraph DELETE "$base/$id/legalHolds/$($h.id)" -Token $t -NoThrow }
            if ([string]$case.status -notlike 'closed*') {
                $null = Invoke-DemoGraph POST "$base/$id/close" -Token $t -NoThrow
                for ($i = 0; $i -lt 20; $i++) { $c = Get-CleanupObject "$base/$id" $t; if (-not $c -or [string]$c.status -like 'closed*') { break }; Start-Sleep -Seconds 15 }
            }
            $r = Invoke-DemoGraph DELETE "$base/$id" -Token $t -NoThrow
            if ($r -and $r.PSObject.Properties['error']) { return Result 'failed' 'error' "Delete refused: $($r.error). In Purview > eDiscovery > Cases close the case (release its holds), delete it, then -Retry." }
            return Result 'deleted' '' 'Holds removed, case closed and deleted.'
        }
        'delete-group' {
            $id = [string]$d.id
            if (Get-CleanupObject "$G/groups/$id`?`$select=id") { Invoke-DemoGraph DELETE "$G/groups/$id" | Out-Null }
            if ($d.kind -eq 'm365') { for ($i = 0; $i -lt 12 -and -not (Get-CleanupObject "$G/directory/deletedItems/$id`?`$select=id"); $i++) { Start-Sleep -Seconds 5 } }
            if (Test-DirectoryObjectGone $id) { return Result 'deleted' '' $(if ($d.kind -eq 'm365') { 'Deleted and purged from the recycle bin (its site and mailbox go with it).' } else { 'Deleted (security groups have no recycle bin).' }) }
            return Result 'failed' 'error' 'Still present or still in Entra > Deleted groups: delete it permanently there, then -Retry.'
        }
        'deactivate-csa-values' {
            $t = Get-CleanupGraphToken $cfg
            $base = "$G/directory/customSecurityAttributeDefinitions/$($d.definition)"
            if (-not (Get-CleanupObject $base $t)) { return Result 'deleted' '' 'Definition not found: nothing to deactivate.' }
            $done = @()
            foreach ($v in @((Invoke-DemoGraph GET "$base/allowedValues" -Token $t).value)) {
                if ($v.isActive) { Invoke-DemoGraph PATCH "$base/allowedValues/$([uri]::EscapeDataString([string]$v.id))" -Token $t -Body @{ isActive = $false } | Out-Null; $done += $v.id }
            }
            return Result 'failed' 'limitation' "Custom security attribute values cannot be deleted: deactivated ($(if ($done.Count) { $done -join ', ' } else { 'already inactive' })). The next build in this tenant reactivates them (Set-DemoGovernance.ps1)."
        }
        'deactivate-csa-definition' {
            $t = Get-CleanupGraphToken $cfg
            $base = "$G/directory/customSecurityAttributeDefinitions/$($d.definition)"
            $def = Get-CleanupObject $base $t
            if (-not $def) { return Result 'deleted' '' 'Not found: nothing to deactivate.' }
            if ($def.status -ne 'Deprecated') { Invoke-DemoGraph PATCH $base -Token $t -Body @{ status = 'Deprecated' } | Out-Null }
            return Result 'failed' 'limitation' 'Custom security attribute definitions cannot be deleted: deactivated (status Deprecated). The next build in this tenant reactivates it (Set-DemoGovernance.ps1).'
        }
        'delete-role-assignment' {
            $t = Get-CleanupGraphToken $cfg
            if (-not (Get-CleanupObject "$G/roleManagement/directory/roleAssignments/$($d.id)" $t)) { return Result 'deleted' '' 'Already absent.' }
            Invoke-DemoGraph DELETE "$G/roleManagement/directory/roleAssignments/$($d.id)" -Token $t | Out-Null
            return Result 'deleted' '' 'Role assignment removed. Sign out and in again to refresh the role claims.'
        }
        'entra-sweep' {
            $purged = 0
            # Also the lab-prefixed objects that Azure soft-deletes by itself with the resource groups (managed identities of
            # the container apps and of the Foundry account and projects): their ids are not known at discovery time.
            $extra = @(foreach ($t in 'microsoft.graph.servicePrincipal', 'microsoft.graph.application') {
                    Select-CleanupPrefixedIds @(Invoke-DemoGraph GET "$G/directory/deletedItems/$t`?`$select=id,displayName" -All -NoThrow -MaxRetries 2) $cp.prefix
                })
            $msi = [System.Collections.Generic.List[object]]::new(); $left = [System.Collections.Generic.List[string]]::new()
            foreach ($id in @(@($d.ids) + $extra | Where-Object { $_ } | Select-Object -Unique)) {
                $obj = Get-CleanupObject "$G/directory/deletedItems/$id"
                if (-not $obj) { continue }
                if (Test-CleanupManagedIdentity $obj) { $msi.Add($obj); continue }
                $r = Invoke-DemoGraph DELETE "$G/directory/deletedItems/$id" -NoThrow -MaxRetries 2
                if ($r -and $r.PSObject.Properties['error'] -and (Get-CleanupObject "$G/directory/deletedItems/$id`?`$select=id")) { $left.Add("$($obj.displayName) ($id)") } else { $purged++ }
            }
            $msiNote = Get-CleanupManagedIdentityNote @($msi)
            if ($left.Count) { return Result 'failed' 'error' "Still in the Entra recycle bin after the purge: $($left -join ', '). Purge them in Entra > Deleted items (or wait for replication), then -Retry. $msiNote".Trim() }
            $done = if ($purged) { "$purged object(s) of the lab were still soft-deleted (deleted by the platforms themselves) and are now purged." } elseif (-not $msi.Count) { 'Nothing of the lab is left in the Entra recycle bin.' } else { 'Nothing purgeable is left in the Entra recycle bin.' }
            return Result 'deleted' '' "$done $msiNote".Trim()
        }
        default { return Result 'failed' 'error' "Unknown action '$($Item.action)'." }
    }
}

function Invoke-McsItem($Item) {
    $d = $Item.data
    $a = @('-NoProfile', '-File', $script:McsRemove, '-Tenant', $ctx.tenantId, '-EnvironmentId', $d.environmentId, '-UseDataverseApi')
    if ($d.orgUrl) { $a += @('-EnvironmentUrl', $d.orgUrl) }
    if ($d.botId) { $a += @('-BotId', $d.botId) } elseif ($d.displayName) { $a += @('-DisplayName', $d.displayName) }
    if ($d.solution) { $a += @('-SolutionUniqueName', $d.solution) }
    $out = & pwsh @a 2>&1
    if ($LASTEXITCODE -ne 0) {
        $msg = (@($out) | ForEach-Object { ("$_" -replace '\x1b\[[0-9;]*[A-Za-z]', '').Trim() } | Where-Object { $_ } | Select-Object -Last 2) -join ' '
        return Result 'failed' 'error' "Remove-McsAgent.ps1 failed: $msg. Delete it in Copilot Studio (Agents > ... > Delete) or check the environment permissions, then -Retry."
    }
    if ($d.botId -and $d.orgUrl) {
        $tok = Get-DemoAzToken -Resource $d.orgUrl -TenantId $ctx.tenantId
        for ($i = 0; $i -lt 20; $i++) { if (-not (Get-CleanupObject "$($d.orgUrl)/api/data/v9.2/bots($($d.botId))?`$select=botid" $tok)) { break }; Start-Sleep -Seconds 15 }
        if (Get-CleanupObject "$($d.orgUrl)/api/data/v9.2/bots($($d.botId))?`$select=botid" $tok) { return Result 'failed' 'error' 'The agent still exists after 5 minutes: check it in Copilot Studio, then -Retry.' }
    }
    return Result 'deleted' '' "Agent deleted through the Dataverse action PvaDeleteBot and solution through the Dataverse Web API$(if ($d.solution) { " (solution $($d.solution))" })."
}

function Invoke-PowerAppsItem($Item) {
    $d = $Item.data
    $t = Get-DemoAzToken -Resource 'https://service.powerapps.com/' -TenantId $ctx.tenantId
    $url = "https://api.powerapps.com/providers/Microsoft.PowerApps/scopes/admin/environments/$($d.environment)/apis/$($d.api)/connections/$($d.connection)?api-version=2016-11-01"
    $r = Invoke-DemoGraph DELETE $url -Token $t -NoThrow
    if ($r -and $r.PSObject.Properties['error'] -and $r.status -ne 404) { return Result 'failed' 'error' "Delete refused ($($r.status)): Power Platform admin center > Environments > the environment > Connections, delete it, then -Retry." }
    return Result 'deleted' '' $(if ($r -and $r.status -eq 404) { 'Already absent.' } else { 'Connection deleted.' })
}

function Invoke-FoundryItem($Item) {
    $d = $Item.data
    $t = Get-DemoAzToken -Resource 'https://ai.azure.com' -TenantId $ctx.tenantId
    $url = "$(([string]$d.endpoint).TrimEnd('/'))/agents/$([uri]::EscapeDataString($d.agent))?api-version=v1"
    if (-not (Get-CleanupObject $url $t)) { return Result 'deleted' '' 'Already absent.' }
    Invoke-DemoGraph DELETE $url -Token $t | Out-Null
    if (Get-CleanupObject $url $t) { return Result 'failed' 'error' 'Still present: delete it in the Foundry portal (project > Agents), then -Retry.' }
    return Result 'deleted' '' 'Foundry agent deleted. Its knowledge files and vector stores in the reused project are checked by hand (see the notes).'
}

function Invoke-ArmItem($Item) {
    $d = $Item.data
    $t = Get-DemoAzToken -Resource 'https://management.azure.com/' -TenantId $ctx.tenantId
    $base = "https://management.azure.com/subscriptions/$($ctx.subscriptionId)/resourceGroups/$($d.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($d.account)"
    $v = 'api-version=2024-10-01'
    $dep = Get-CleanupObject "$base/deployments/$($d.deployment)?$v" $t
    if ($dep -and [string]$dep.properties.raiPolicyName -eq $d.policy) {
        $body = @{ sku = $dep.sku; properties = @{ model = $dep.properties.model; raiPolicyName = 'Microsoft.DefaultV2'; versionUpgradeOption = $dep.properties.versionUpgradeOption } }
        Invoke-DemoGraph PUT "$base/deployments/$($d.deployment)?$v" -Token $t -Body $body | Out-Null
        for ($i = 0; $i -lt 20; $i++) { $x = Get-CleanupObject "$base/deployments/$($d.deployment)?$v" $t; if ($x.properties.provisioningState -in 'Succeeded', 'Failed') { break }; Start-Sleep -Seconds 15 }
    }
    if (Get-CleanupObject "$base/raiPolicies/$($d.policy)?$v" $t) { Invoke-DemoGraph DELETE "$base/raiPolicies/$($d.policy)?$v" -Token $t | Out-Null }
    if (Get-CleanupObject "$base/raiPolicies/$($d.policy)?$v" $t) { return Result 'failed' 'error' 'The custom content filter still exists: delete it in the Foundry portal (Guardrails + controls), then -Retry.' }
    return Result 'deleted' '' 'Deployment back to Microsoft.DefaultV2 and the custom content filter deleted.'
}

# Security & Compliance and Exchange Online sessions: one interactive sign-in each per run, in-memory token cache, no WAM.
$script:SccReady = $null; $script:ExoReady = $null; $script:SoftDeleted = $null
function Connect-CleanupScc {
    if ($null -ne $script:SccReady) { return $script:SccReady }
    $script:SccReady = $false
    if (-not (Get-Module -ListAvailable ExchangeOnlineManagement)) { Log 'ExchangeOnlineManagement is not installed: the Purview policies become manual actions.' 'WARN'; return $false }
    try {
        Import-Module ExchangeOnlineManagement -ErrorAction Stop
        Log "Security & Compliance PowerShell: interactive browser sign-in as $($ctx.adminUpn) (a browser window opens)."
        Connect-IPPSSession -UserPrincipalName $ctx.adminUpn -DisableWAM -ShowBanner:$false -ErrorAction Stop
        $script:SccReady = $true
    }
    catch { Log "Security & Compliance PowerShell sign-in failed: $($_.Exception.Message). The Purview policies become manual actions." 'WARN' }
    return $script:SccReady
}
function Connect-CleanupExo {
    if ($null -ne $script:ExoReady) { return $script:ExoReady }
    $script:ExoReady = $false
    if (-not (Get-Module -ListAvailable ExchangeOnlineManagement)) { Log 'ExchangeOnlineManagement is not installed: the soft-deleted mailboxes become manual actions.' 'WARN'; return $false }
    try {
        Import-Module ExchangeOnlineManagement -ErrorAction Stop
        Log "Exchange Online PowerShell: interactive browser sign-in as $($ctx.adminUpn) (a browser window opens)."
        Connect-ExchangeOnline -UserPrincipalName $ctx.adminUpn -DisableWAM -ShowBanner:$false -ErrorAction Stop
        $script:ExoReady = $true
    }
    catch { Log "Exchange Online PowerShell sign-in failed: $($_.Exception.Message). The soft-deleted mailboxes become manual actions." 'WARN' }
    return $script:ExoReady
}

function Invoke-SccItem($Item) {
    if (-not (Connect-CleanupScc)) { return Result 'manual' '' 'Security & Compliance PowerShell is not available: do it in the portal.' }
    $n = [string]$Item.data.name
    $get = { param([scriptblock]$Read) try { & $Read } catch { $null } }
    switch ($Item.action) {
        'remove-cc-policy' {
            if (-not (& $get { Get-SupervisoryReviewPolicyV2 -Identity $n -ErrorAction Stop })) { return Result 'deleted' '' 'Already absent.' }
            Remove-SupervisoryReviewPolicyV2 -Identity $n -Confirm:$false -ErrorAction Stop
            return Result 'deleted' '' 'Deleted (the service can take a while to remove it completely).'
        }
        'remove-dlp-policy' {
            if (-not (& $get { Get-DlpCompliancePolicy -Identity $n -ErrorAction Stop })) { return Result 'deleted' '' 'Already absent.' }
            Remove-DlpCompliancePolicy -Identity $n -Confirm:$false -ErrorAction Stop
            return Result 'deleted' '' 'Deleted (pending deletion on the service side for a few minutes).'
        }
        'remove-label-policy' {
            $label = @(& $get { Get-Label -ErrorAction Stop } | Where-Object { $_.DisplayName -eq $Item.data.label -or $_.Name -eq $Item.data.label }) | Select-Object -First 1
            if (-not $label) { return Result 'deleted' '' 'The label does not exist: no publishing policy to change.' }
            $keys = @([string]$label.Name, [string]$label.Guid, [string]$label.ImmutableId) | Where-Object { $_ }
            $done = @()
            foreach ($p in @(& $get { Get-LabelPolicy -ErrorAction Stop } | Where-Object { @($_.Labels | Where-Object { $keys -contains [string]$_ }).Count -or @($_.ScopedLabels | Where-Object { $keys -contains [string]$_ }).Count })) {
                if (@($p.Labels).Count -le 1) { Remove-LabelPolicy -Identity $p.Name -Confirm:$false -ErrorAction Stop; $done += "policy '$($p.Name)' deleted" }
                else { Set-LabelPolicy -Identity $p.Name -RemoveLabels $label.Name -ErrorAction Stop; $done += "label removed from policy '$($p.Name)'" }
            }
            return Result 'deleted' '' $(if ($done.Count) { $done -join '; ' } else { 'No publishing policy contains the label.' })
        }
        'remove-label' {
            $label = @(& $get { Get-Label -ErrorAction Stop } | Where-Object { $_.DisplayName -eq $n -or $_.Name -eq $n }) | Select-Object -First 1
            if (-not $label) { return Result 'deleted' '' 'Already absent.' }
            Remove-Label -Identity ([string]$label.Guid) -Confirm:$false -ErrorAction Stop
            return Result 'deleted' '' 'Deleted; the service removes it asynchronously and its name can stay reserved for a while.'
        }
        'remove-audit-retention' {
            if (-not @(& $get { Get-UnifiedAuditLogRetentionPolicy -ErrorAction Stop } | Where-Object { $_.Name -eq $n }).Count) { return Result 'deleted' '' 'Already absent.' }
            Remove-UnifiedAuditLogRetentionPolicy -Identity $n -Confirm:$false -ErrorAction Stop
            return Result 'deleted' '' 'Deleted (the audit records already kept are not affected).'
        }
        default { return Result 'failed' 'error' "Unknown Purview action '$($Item.action)'." }
    }
}

function Invoke-ExoItem($Item) {
    if (-not (Connect-CleanupExo)) { return Result 'manual' '' 'Exchange Online PowerShell is not available: run the steps by hand.' }
    $upn = [string]$Item.data.upn
    $match = { param($m) $m.UserPrincipalName -eq $upn -or [string]$m.PrimarySmtpAddress -eq $upn }
    for ($i = 0; $i -lt 5; $i++) {
        $mb = @(try { Get-Mailbox -SoftDeletedMailbox -ResultSize Unlimited -ErrorAction Stop } catch { @() }) | Where-Object { & $match $_ }
        if ($mb.Count) {
            foreach ($m in $mb) { $m | Remove-Mailbox -PermanentlyDelete -Confirm:$false -ErrorAction Stop }
            return Result 'deleted' '' 'Soft-deleted mailbox permanently deleted.'
        }
        $inactive = @(try { Get-Mailbox -InactiveMailboxOnly -ResultSize Unlimited -ErrorAction Stop } catch { @() }) | Where-Object { & $match $_ }
        if ($inactive.Count) { return Result 'failed' 'limitation' 'It became an inactive mailbox because a hold applies (retention policy, litigation or eDiscovery hold): remove the hold, then -Retry.' }
        if (-not $Item.data.hasMailbox) { break }
        Start-Sleep -Seconds 60
    }
    if ($Item.data.hasMailbox) { return Result 'failed' 'pending' "The soft-deleted mailbox of $upn is not visible yet (Exchange can take a while after the user deletion). Check with Get-Mailbox -SoftDeletedMailbox -Identity $upn, then run -Retry (or answer -Absent $($Item.index) if it does not exist)." }
    return Result 'deleted' '' 'No soft-deleted or inactive mailbox left for this address.'
}

function Invoke-SpoItem($Item) {
    $url = [string]$Item.data.url
    $hostName = ([uri]$url).Host
    $tenantName = ($hostName.Split('.')[0]) -replace '-my$', ''
    $admin = "https://$tenantName-admin.sharepoint.com"
    $t = $null
    try { $t = Get-DemoAzToken -Resource $admin -TenantId $ctx.tenantId } catch { return Result 'manual' '' "No token for $admin ($($_.Exception.Message)): run the steps by hand." }
    $h = @{ Accept = 'application/json;odata=nometadata' }
    $call = { param([string]$Op) Invoke-DemoGraph POST "$admin/_api/SPO.Tenant/$Op" -Token $t -Headers $h -Body @{ siteUrl = $url } -NoThrow -MaxRetries 1 }
    if ($Item.action -eq 'purge-onedrive') {
        $r = & $call 'RemoveSite'
        if ($r -and $r.PSObject.Properties['error'] -and $r.status -in 401, 403) { return Result 'manual' '' 'The SharePoint admin API refused the token: run the steps by hand.' }
        Start-Sleep -Seconds 20
    }
    for ($i = 0; $i -lt 5; $i++) {
        $r = & $call 'RemoveDeletedSite'
        if (-not ($r -and $r.PSObject.Properties['error'])) { return Result 'deleted' '' 'Permanently deleted from the SharePoint recycle bin (the URL can take up to 24 hours to become free).' }
        if ($r.status -in 401, 403) { return Result 'manual' '' 'The SharePoint admin API refused the token: run the steps by hand.' }
        Start-Sleep -Seconds 60
    }
    return Result 'manual' '' "The automatic purge did not succeed ($($r.status)): run the steps by hand."
}

# The neutralization of an ext_ MCP server: Block (approved) through the registry API, Reject (pending) by hand.
function Invoke-McpItem($Item) {
    $d = $Item.data
    $id = [string]$d.packageId
    if (-not $id) {
        $list = @(Invoke-DemoGraph GET "$script:DemoG/beta/copilot/admin/catalog/packages?`$filter=$([uri]::EscapeDataString("elementTypes/any(e:e eq 'MCPServers')"))" -Token (Get-DemoRegToken $cfg) -All)
        $id = [string](@($list | Where-Object { $_.displayName -eq $d.name }) | Select-Object -First 1).id
        $d['packageId'] = $id
    }
    if (-not $id) { return Result 'manual' '' 'Not visible through the registry API: block it (approved) or reject it (pending) in the admin center.' }
    $r = Invoke-DemoReg $cfg GET "$script:DemoG/beta/copilot/admin/catalog/packages/$id"
    if (-not $r.ok -and $r.status -eq 404) {
        Set-DemoReservedMcpState -TenantId $ctx.tenantId -Prefix $cp.prefix -Name $d.name -State 'gone'
        return Result 'failed' 'limitation' "No longer listed. $($Item.limitation)"
    }
    if (-not $r.ok) { return Result 'failed' 'error' "Registry read failed ($($r.status)): $($r.error)" }
    if ([string]$r.body.requestStatus -eq 'pending') { return Result 'manual' '' 'It is a pending request: Reject it in the admin center (no API).' }
    if (-not $r.body.isBlocked) {
        $b = Invoke-DemoReg $cfg POST "$script:DemoG/beta/copilot/admin/catalog/packages/$id/block"
        if (-not $b.ok) { return Result 'manual' '' "The registry API refused the block ($($b.status)): block it in the admin center." }
    }
    Set-DemoReservedMcpState -TenantId $ctx.tenantId -Prefix $cp.prefix -Name $d.name -State 'blocked'
    return Result 'failed' 'limitation' "Blocked (its tools are no longer usable). $($Item.limitation) It is recorded in generated\cleanup\tenant-$($ctx.tenantId)\reserved-ext-mcp-names.json so that no future build reuses it."
}

function Invoke-RegistryVerify($Item) {
    $script:RegistryListedIds = $null
    $left = @(Get-RemainingPackages @($Item.data.packageIds))
    if (-not $left.Count) { return Result 'deleted' '' 'No longer in the registry: removed together with the agent.' }
    $regs = @(foreach ($id in $left) { Remove-PackageRegistration $id })
    if ($regs.Count) {
        for ($i = 0; $i -lt 12 -and $left.Count; $i++) { Start-Sleep -Seconds 10; $script:RegistryListedIds = $null; $left = @(Get-RemainingPackages $left) }
        if (-not $left.Count) { return Result 'deleted' '' "Agent registration $($regs -join ', ') deleted through the Agent 365 API: no longer in the registry." }
    }
    $Item.data['remaining'] = $left
    return Result 'manual' '' "Still listed in the registry ($($left -join ', '))$(if ($regs.Count) { " after the deletion of its agent registration $($regs -join ', ')" }): delete it in the admin center."
}

function Invoke-LocalItem($Item) {
    $path = [string]$Item.data.path
    if (Test-Path -LiteralPath $path) {
        $out = & pwsh -NoProfile -File $script:LcFolders -Path $path -GeneratedRoot (Join-Path $script:DemoRepoRoot 'generated') -LogPath (Join-Path $RunDir 'lab-cleaner\deletion.log') -Force 2>&1
        if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $path)) { return Result 'failed' 'error' "Not deleted: $((@($out) | Select-Object -Last 2) -join ' '). Close any program using it, then delete it by hand." }
    }
    foreach ($f in @($Item.data.extraFiles)) { if ($f -and (Test-Path -LiteralPath $f)) { Remove-Item -LiteralPath $f -Force } }
    return Result 'deleted' '' 'Local folder deleted (state, scaffolding, passwords, caches, operator slots). The cleanup audit folder is kept.'
}

function Invoke-CleanupItem($Item) {
    switch ($Item.executor) {
        'lab-cleaner' { return Invoke-LabCleanerItem $Item }
        'graph' { return Invoke-GraphItem $Item }
        'mcs' { return Invoke-McsItem $Item }
        'powerapps' { return Invoke-PowerAppsItem $Item }
        'foundry' { return Invoke-FoundryItem $Item }
        'arm' { return Invoke-ArmItem $Item }
        'scc' { return Invoke-SccItem $Item }
        'exo' { return Invoke-ExoItem $Item }
        'spo' { return Invoke-SpoItem $Item }
        'mcp-neutralize' { return Invoke-McpItem $Item }
        'registry-verify' { return Invoke-RegistryVerify $Item }
        'record-only' { return Result 'failed' 'limitation' ([string]$Item.limitation) }
        'local' { return Invoke-LocalItem $Item }
        'manual' { return Result 'manual' }
        default { return Result 'failed' 'error' "Unknown executor '$($Item.executor)'." }
    }
}

# ------------------------------------------------------------------------------------------------- manual answers
function Test-ManualVerified($Item) {
    if ($Item.kind -in 'agent-builder-agent', 'agent-skill', 'third-party-agent', 'registry-package' -and @($Item.data.packageIds).Count) {
        $script:RegistryListedIds = $null
        $left = try { @(Get-RemainingPackages @($Item.data.packageIds)) } catch { return "it could not be verified ($($_.Exception.Message))" }
        if ($left.Count) { return "still listed in the registry ($($left -join ', '))" }
        return ''
    }
    if ($Item.kind -eq 'mcp-server' -and $Item.data.packageId) {
        $r = Invoke-DemoReg $cfg GET "$script:DemoG/beta/copilot/admin/catalog/packages/$($Item.data.packageId)"
        if ($r.ok -or $r.status -eq 404) { $Item.data['neutralizedState'] = Get-McpNeutralizedState $(if ($r.ok) { $r.body } else { $null }) }
        if ($r.ok) { return (Get-McpNeutralizeGap $r.body) }
    }
    return ''
}
# Operator answers apply to manual actions only: automatic deletions are verified by running them again (-Retry).
function Get-AnsweredItems([string]$Spec, [string]$Flag) {
    foreach ($n in @(Get-Indexes $Spec)) {
        $it = Get-CleanupItemByIndex $cp $n
        if ($it.status -in 'deleted', 'excluded') { continue }
        if (-not $it.manual) { Write-Warning "#$n $($it.name) is deleted automatically, not by hand: $Flag ignored. Use -Retry to run its deletion again."; continue }
        $it
    }
}
foreach ($it in @(Get-AnsweredItems $Done '-Done')) {
    $gap = Test-ManualVerified $it
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
    if ($gap) { Set-CleanupItemStatus $cp $it 'failed' 'manual' -Notes "Reported done at $stamp, but $gap. Check it, then answer again." ; continue }
    $it.data['manualPending'] = $false
    if ($it.kind -eq 'mcp-server' -and $it.data.neutralizedState) { Set-DemoReservedMcpState -TenantId $ctx.tenantId -Prefix $cp.prefix -Name $it.data.name -State $it.data.neutralizedState }
    if ($it.kind -eq 'mcp-server' -or ($it.manual -and $it.manual.confirmAs -eq 'limitation')) {
        Set-CleanupItemStatus $cp $it 'failed' 'limitation' -Notes "Done by the operator at $stamp. $(if ($it.limitation) { $it.limitation } else { 'It cannot be deleted, only neutralized as described.' })"
    }
    else { Set-CleanupItemStatus $cp $it 'deleted' -Notes "Done by the operator at $stamp$(if ($it.kind -in 'agent-builder-agent', 'agent-skill', 'third-party-agent', 'registry-package') { '; verified through the registry API' })." }
}
foreach ($it in @(Get-AnsweredItems $Absent '-Absent')) {
    $it.data['manualPending'] = $false
    Set-CleanupItemStatus $cp $it 'deleted' -Notes "Not present (confirmed by the operator at $(Get-Date -Format 'yyyy-MM-dd HH:mm'))."
}
foreach ($it in @(Get-AnsweredItems $Defer '-Defer')) {
    Set-CleanupItemStatus $cp $it 'failed' 'manual' -Notes "Manual action left for later: $($it.manual.where). When done: Invoke-DemoCleanup.ps1 -RunDir `"$RunDir`" -Apply -Done $($it.index) (or -Absent $($it.index))."
}
# With -Only, -Retry reopens only the listed elements (deferred manual actions elsewhere stay deferred).
$onlySet = @(Get-Indexes $Only)
if ($Retry) {
    foreach ($it in @($cp.items | Where-Object { $_.status -eq 'failed' -and $_.reason -in 'error', 'dependency', 'pending', 'manual' -and (-not $onlySet.Count -or $onlySet -contains [int]$_.index) })) {
        Set-CleanupItemStatus $cp $it 'toDelete' -Notes "Retry requested at $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Previous result: $($it.notes)"
    }
}

# ------------------------------------------------------------------------------------------------- main loop
$cp['phase'] = 'deleting'
Save-CleanupPlan $cp
Log "Deletion run (manual mode $($cp.manualMode)) in tenant $($ctx.tenantId), subscription $($ctx.subscriptionId)"

function Get-OpenItems([scriptblock]$Where) {
    @($cp.items | Where-Object { $_.status -eq 'toDelete' -and -not $_.data.asyncStartedAt -and $_.executor -ne 'covered' -and $_.kind -ne 'local-folder' -and (& $Where $_) -and (-not $onlySet.Count -or $onlySet -contains [int]$_.index) } | Sort-Object { [int]$_.index })
}
function Stop-AtManual($Item) {
    $checkpoint = @($Item)
    foreach ($n in @($cp.items | Where-Object { [int]$_.index -gt [int]$Item.index } | Sort-Object { [int]$_.index })) {
        if ($n.status -ne 'toDelete' -or $n.executor -eq 'covered') { continue }
        if ($n.executor -eq 'manual') { $checkpoint += $n } else { break }
    }
    $pending = @(foreach ($m in $checkpoint) {
        [ordered]@{ index = [int]$m.index; name = $m.name; type = $m.type; where = $m.manual.where; steps = @($m.manual.steps); verify = $m.manual.verify; notes = $m.notes }
    })
    Set-CleanupFileAtomic (Join-Path $RunDir 'pending-manual.json') ($pending | ConvertTo-Json -Depth 8 -AsArray)
    foreach ($m in $checkpoint) { $m.lastUpdated = (Get-Date).ToString('o') }
    $cp['phase'] = 'paused'
    $null = Update-CleanupSummary $cp
    Save-CleanupPlan $cp
    Write-Host ''
    Write-Host "PAUSED at a manual checkpoint ($($checkpoint.Count) action(s)); details in pending-manual.json:" -ForegroundColor Yellow
    foreach ($m in $pending) {
        Write-Host "  #$($m.index) $($m.name) - $($m.where)"
        foreach ($s in $m.steps) { Write-Host "      - $s" }
    }
    Write-Host "Answer with: Invoke-DemoCleanup.ps1 -RunDir `"$RunDir`" -Apply -Done <indexes> [-Absent <indexes>] [-Defer <indexes>]"
    exit 10
}
function Invoke-Pass([scriptblock]$Where) {
    while ($true) {
        $next = @(Get-OpenItems $Where) | Select-Object -First 1
        if (-not $next) { return }
        $blocking = @(@($next.dependsOn) | ForEach-Object { Get-CleanupItem $cp $_ } | Where-Object { $_ -and $_.status -in 'toDelete', 'failed' -and -not ($_.status -eq 'failed' -and $_.reason -eq 'limitation') })
        if ($blocking.Count) {
            $b = $blocking[0]
            Set-CleanupItemStatus $cp $next 'failed' 'dependency' -Notes "Waits for #$($b.index) $($b.name) ($($script:CleanerStatusLabels[[string]$b.status])), which must go first. Resolve it, then run again with -Retry."
            Save-CleanupPlan $cp; continue
        }
        Log "#$($next.index) [$($next.type)] $($next.name): $($next.executor) $($next.action)"
        $r = $null
        try { $r = Invoke-CleanupItem $next }
        catch { $r = Result 'failed' 'error' "$($_.Exception.Message) - fix the cause and run again with -Retry." }
        if (-not $r) { $r = Result 'failed' 'error' 'The handler returned no result: run again with -Retry.' }
        if ($r.status -eq 'manual') {
            $next.data['manualPending'] = $true
            if ($r.notes) { $next.notes = $r.notes }
            if ($cp.manualMode -eq 'pause') { Stop-AtManual $next }
            Set-CleanupItemStatus $cp $next 'failed' 'manual' -Notes "$(if ($r.notes) { "$($r.notes) " })Manual action pending: $($next.manual.where). When done: Invoke-DemoCleanup.ps1 -RunDir `"$RunDir`" -Apply -Done $($next.index) (or -Absent $($next.index))."
        }
        elseif ($r.status -eq 'async') { $next.notes = $r.notes; $next.lastUpdated = (Get-Date).ToString('o') }
        else { Set-CleanupItemStatus $cp $next $r.status $r.reason -Notes $r.notes }
        Log "#$($next.index) -> $($r.status)$(if ($r.reason) { " ($($r.reason))" }) $($r.notes)" $(if ($r.status -eq 'deleted') { 'OK' } elseif ($r.status -eq 'failed' -and $r.reason -ne 'limitation') { 'ERROR' } else { 'INFO' })
        Save-CleanupPlan $cp
    }
}
function Wait-ResourceGroups {
    $pending = @($cp.items | Where-Object { $_.status -eq 'toDelete' -and $_.data.asyncStartedAt })
    if (-not $pending.Count) { return }
    if ($NoWait) { Log "$($pending.Count) resource group deletion(s) still running: not awaited (-NoWait). Run again with -Retry to check them." 'WARN'; return }
    $cp['phase'] = 'waiting'; Save-CleanupPlan $cp
    $deadline = (Get-Date).AddMinutes($RgTimeoutMinutes)
    while ($pending.Count -and (Get-Date) -lt $deadline) {
        foreach ($it in $pending) {
            $exists = az group exists -n $it.data.labItem.id --subscription $ctx.subscriptionId 2>$null
            if ($exists -eq 'false') {
                $started = [datetime]$it.data.asyncStartedAt
                $it.data.asyncStartedAt = $null
                Set-CleanupItemStatus $cp $it 'deleted' -Notes ("Deleted (asynchronous deletion finished after {0:N0} min)." -f ((Get-Date) - $started).TotalMinutes)
                Save-CleanupPlan $cp
            }
        }
        $pending = @($cp.items | Where-Object { $_.status -eq 'toDelete' -and $_.data.asyncStartedAt })
        if ($pending.Count) { Start-Sleep -Seconds 30 }
    }
    foreach ($it in $pending) {
        $it.data.asyncStartedAt = $null
        Set-CleanupItemStatus $cp $it 'failed' 'pending' -Notes "Deletion still running after $RgTimeoutMinutes minutes (Container Apps environments can take long). Check with: az group exists -n $($it.data.labItem.id); then Invoke-DemoCleanup.ps1 -RunDir `"$RunDir`" -Apply -Retry."
    }
    $cp['phase'] = 'deleting'; Save-CleanupPlan $cp
}
# Cognitive Services accounts that went with their resource group: purged once the resource groups are gone, so that no
# soft-deleted account keeps the name and the regional model quota.
function Complete-CognitiveServicesPurges {
    foreach ($it in @($cp.items | Where-Object { $_.status -eq 'failed' -and $_.reason -eq 'pending' -and $_.data.purgeAfterRg -and (-not $onlySet.Count -or $onlySet -contains [int]$_.index) } | Sort-Object { [int]$_.index })) {
        $li = $it.data.labItem
        Log "#$($it.index) [$($it.type)] $($it.name): purge after the resource-group deletion"
        $soft = { @(az cognitiveservices account list-deleted --subscription $ctx.subscriptionId -o json 2>$null | ConvertFrom-Json | Where-Object { $_.name -eq $li.id }) }
        if (@(& $soft).Count) { $null = az cognitiveservices account purge --location $li.location --resource-group $li.resourceGroup --name $li.id --subscription $ctx.subscriptionId 2>&1 }
        $live = az cognitiveservices account show -n $li.id -g $li.resourceGroup --subscription $ctx.subscriptionId --query id -o tsv 2>$null
        if ($live -or @(& $soft).Count) {
            Set-CleanupItemStatus $cp $it 'failed' 'pending' -Notes "Not purged yet ($(if ($live) { 'still live' } else { 'still soft-deleted' })): when its resource group is gone, az cognitiveservices account purge --location $($li.location) --resource-group $($li.resourceGroup) --name $($li.id), or Invoke-DemoCleanup.ps1 -Apply -Retry."
        }
        else {
            $it.data['purgeAfterRg'] = $false
            Set-CleanupItemStatus $cp $it 'deleted' -Notes 'Deleted with its resource group, then purged (name and regional quota released).'
        }
        Log "#$($it.index) -> $($it.status)$(if ($it.reason) { " ($($it.reason))" }) $($it.notes)" $(if ($it.status -eq 'deleted') { 'OK' } else { 'WARN' })
        Save-CleanupPlan $cp
    }
}

try {
    Invoke-Pass { param($i) [int]$i.order -lt $script:CleanerPostWaitOrder }
    Wait-ResourceGroups
    Complete-CognitiveServicesPurges
    Invoke-Pass { param($i) [int]$i.order -ge $script:CleanerPostWaitOrder }
    # The local lab folder goes last, and only when nothing else is left to retry (the retries need its state and caches).
    $local = @($cp.items | Where-Object { $_.kind -eq 'local-folder' -and $_.status -eq 'toDelete' -and (-not $onlySet.Count -or $onlySet -contains [int]$_.index) }) | Select-Object -First 1
    if ($local) {
        $open = @($cp.items | Where-Object { $_.id -ne $local.id -and ($_.status -eq 'toDelete' -or ($_.status -eq 'failed' -and $_.reason -ne 'limitation')) })
        if ($open.Count) {
            $local.notes = "Kept for now: $($open.Count) element(s) still need a retry (it holds their state and caches). It is deleted by the run that completes them."
            $local.lastUpdated = (Get-Date).ToString('o')
        }
        else {
            Log "#$($local.index) [Resource] $($local.name): local folder"
            $r = Invoke-LocalItem $local
            Set-CleanupItemStatus $cp $local $r.status $r.reason -Notes $r.notes
        }
    }
}
finally {
    if ($script:SccReady -or $script:ExoReady) { try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue } catch { } }
}

# ------------------------------------------------------------------------------------------------- summary
$cp['phase'] = 'finished'
$summary = Update-CleanupSummary $cp
Save-CleanupPlan $cp
$s = $summary.stats
$md = [System.Collections.Generic.List[string]]::new()
$md.Add("# Demo Cleaner - lab $($cp.prefix) - summary")
$md.Add('')
$md.Add("Tenant $($ctx.tenantId), subscription $($ctx.subscriptionId). Report: $(Get-CleanupReportUri $RunDir)")
$md.Add('')
$md.Add("Elements: $($s.total) | deleted successfully: $($s.deleted) | could not delete: $($s.failed) (errors $($s.errors), platform limitations $($s.limitations), manual actions pending $($s.manualPending), blocked by a dependency $($s.dependency), still in progress $($s.stillRunning)) | still to be deleted: $($s.toDelete) | excluded (kept): $($s.excluded)")
$md.Add('')
$md.Add('| Type | Total | Deleted successfully | Could not delete | To be deleted | Excluded (kept) |')
$md.Add('|---|---|---|---|---|---|')
foreach ($t in $script:CleanerTypes) { $x = $s.byType[$t]; $md.Add("| $t | $($x.total) | $($x.deleted) | $($x.failed) | $($x.toDelete) | $($x.excluded) |") }
if (@($summary.problems).Count) {
    $md.Add(''); $md.Add('## Problems that prevented a deletion'); $md.Add('')
    foreach ($p in $summary.problems) { $md.Add("- #$($p.index) $($p.name) [$($p.type), $($p.reasonLabel)]: $($p.notes)") }
}
$openManual = @($cp.items | Where-Object { $_.manual -and ($_.status -eq 'toDelete' -or ($_.status -eq 'failed' -and $_.reason -ne 'limitation')) } | Sort-Object { [int]$_.index })
if ($openManual.Count) {
    $md.Add(''); $md.Add('## Manual rollback still to do'); $md.Add('')
    foreach ($m in $openManual) {
        $md.Add("- #$($m.index) $($m.name) [$($m.type)] - $($m.manual.where): $(@($m.manual.steps) -join ' ') Then: Invoke-DemoCleanup.ps1 -RunDir `"$RunDir`" -Apply -Done $($m.index) (or -Absent $($m.index)).")
    }
}
if (@($cp.rebuild).Count) {
    $md.Add(''); $md.Add('## Rebuilding a lab in the same tenant, subscription and language'); $md.Add('')
    foreach ($r in $cp.rebuild) { $md.Add("- **$($r.topic)** ($($r.severity)): $($r.problem) Fix: $($r.fix)") }
}
$md | Set-Content -LiteralPath (Join-Path $RunDir 'summary.md') -Encoding utf8
$md | ForEach-Object { Write-Host $_ }
$retryable = @($cp.items | Where-Object { $_.status -eq 'toDelete' -or ($_.status -eq 'failed' -and $_.reason -ne 'limitation') })
if ($ctx.auth.mode -eq 'session' -and -not $retryable.Count -and (Test-Path -LiteralPath $ctx.auth.sessionDir)) {
    Remove-Item -LiteralPath $ctx.auth.sessionDir -Recurse -Force -ErrorAction SilentlyContinue
    Log 'Session authentication directory of this cleanup removed (nothing left to retry).'
}
Log "Run finished: $($s.deleted) deleted, $($s.failed) could not delete ($($s.errors) error(s)), $($s.toDelete) still to delete, $($s.excluded) kept." 'OK'
