# Shared helpers of the Demo Cleaner (dot-source AFTER the Demo Builder's _demo-common.ps1): the cleanup run folder under
# generated/cleanup/, the cleanup plan (one item per object, in deletion order), its live HTML report, the exception
# parser of the review gate, dependency closure, status transitions and the final summary.
$ErrorActionPreference = 'Stop'
$script:CleanerSkillDir = Split-Path -Parent $PSScriptRoot
$script:CleanerTypes = @('User', 'Group', 'Resource', 'Configuration', 'Component', 'Agent')
$script:CleanerStatusLabels = [ordered]@{ toDelete = 'To be deleted'; deleted = 'Deleted successfully'; failed = 'Could not delete'; excluded = 'Excluded (kept)' }
$script:CleanerReasonLabels = [ordered]@{
    error = 'error'; limitation = 'platform limitation'; manual = 'manual action pending'; dependency = 'blocked by a dependency'
    pending = 'deletion still in progress'; user = 'kept at the review gate'; default = 'kept by default'; shared = 'shared with another lab'
    closure = 'kept because a prerequisite is kept'
}
# Items from this order on run after the asynchronous resource-group deletions have completed.
$script:CleanerPostWaitOrder = 8000

# ------------------------------------------------------------------------------------------------------ run folder
function Get-CleanupRoot { Join-Path $script:DemoRepoRoot 'generated\cleanup' }

function New-CleanupRunDir([Parameter(Mandatory)][string]$Prefix) {
    $dir = Join-Path (Get-CleanupRoot) ("demo-{0}-{1}" -f $Prefix, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

function Write-CleanupLog([Parameter(Mandatory)][string]$RunDir, [Parameter(Mandatory)][string]$Message, [string]$Level = 'INFO') {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = switch ($Level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } 'OK' { 'Green' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
    Add-Content -LiteralPath (Join-Path $RunDir 'cleanup.log') -Value $line -Encoding utf8
}

# Atomic write: the browser (or a concurrent reader) never sees a half-written file.
function Set-CleanupFileAtomic([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Content) {
    $tmp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText($tmp, $Content, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# ------------------------------------------------------------------------------------------------------ plan
function New-CleanupPlan([Parameter(Mandatory)][string]$Prefix, [Parameter(Mandatory)][string]$RunDir, $Context) {
    $now = (Get-Date).ToString('o')
    [ordered]@{
        schemaVersion = '1.0'; tool = 'Demo Cleaner'; runId = (Split-Path -Leaf $RunDir); prefix = $Prefix
        runDir = $RunDir; context = $Context; phase = 'discovery'; mode = 'live'; manualMode = 'pause'
        createdAt = $now; updatedAt = $now
        discovery = [ordered]@{ section = 'starting'; sections = @(); startedAt = $now; finishedAt = $null }
        selection = [ordered]@{ excludeSpec = ''; includeSpec = ''; confirmedAt = $null; whatIfAt = $null }
        warnings = @(); items = @(); summary = $null; manualGuide = @(); rebuild = @(); runbook = @()
    }
}

function Read-CleanupPlan([Parameter(Mandatory)][string]$RunDir) {
    $f = Join-Path $RunDir 'cleanup-plan.json'
    if (-not (Test-Path -LiteralPath $f)) { throw "Cleanup plan not found: $f. Run Get-DemoCleanupPlan.ps1 first." }
    $p = Get-Content -LiteralPath $f -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $p['items'] = @($p.items | Where-Object { $_ })
    $p['warnings'] = @($p.warnings | Where-Object { $_ })
    $p['runDir'] = (Resolve-Path -LiteralPath $RunDir).Path
    return $p
}

function Save-CleanupPlan([Parameter(Mandatory)]$Plan) {
    $Plan['updatedAt'] = (Get-Date).ToString('o')
    Set-CleanupFileAtomic (Join-Path ([string]$Plan.runDir) 'cleanup-plan.json') ($Plan | ConvertTo-Json -Depth 40)
    Write-CleanupReport $Plan
}

function Add-CleanupWarning([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$Topic, [Parameter(Mandatory)][string]$Detail) {
    $Plan['warnings'] = @($Plan.warnings) + @([ordered]@{ topic = $Topic; detail = $Detail; at = (Get-Date).ToString('o') })
}

function New-CleanupItem {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Name,
          [Parameter(Mandatory)][ValidateSet('User', 'Group', 'Resource', 'Configuration', 'Component', 'Agent')][string]$Type,
          [Parameter(Mandatory)][int]$Order, [Parameter(Mandatory)][string]$Executor, [string]$Action = '', [string]$Detail = '',
          [System.Collections.IDictionary]$Data, [string[]]$DependsOn = @(), [string]$CoveredBy = '', [System.Collections.IDictionary]$Manual,
          [string]$Notes = '', [string]$Origin = 'state', [string]$Kind = '', [switch]$DefaultExcluded,
          [ValidateSet('default', 'shared')][string]$ExcludedReason = 'default', [string]$Limitation = '')
    if (-not $Data) { $Data = [ordered]@{} }
    $now = (Get-Date).ToString('o')
    $item = [ordered]@{
        index = 0; id = $Id; name = $Name; detail = $Detail; type = $Type; kind = $(if ($Kind) { $Kind } else { $Action })
        status = 'toDelete'; reason = ''; lastUpdated = $now; notes = $Notes; order = $Order; executor = $Executor; action = $Action
        dependsOn = @($DependsOn | Where-Object { $_ }); coveredBy = $CoveredBy; manual = $Manual; origin = $Origin
        defaultExcluded = [bool]$DefaultExcluded; defaultExcludedReason = $(if ($DefaultExcluded) { $ExcludedReason } else { '' })
        keptNote = $(if ($DefaultExcluded) { $Notes } else { '' }); limitation = $Limitation; data = $Data; history = @()
    }
    if ($DefaultExcluded) { $item.status = 'excluded'; $item.reason = $ExcludedReason }
    return $item
}

# Adds an item unless one with the same id exists (the first discovery path wins); returns the item kept.
function Add-CleanupItem([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Item) {
    $existing = @($Plan.items | Where-Object { $_.id -eq $Item.id }) | Select-Object -First 1
    if ($existing) {
        if ($Item.origin -and ([string]$existing.origin -notmatch [regex]::Escape([string]$Item.origin))) { $existing.origin = "$($existing.origin), $($Item.origin)" }
        return $existing
    }
    $Item['seq'] = @($Plan.items).Count
    $Plan['items'] = @($Plan.items) + @($Item)
    return $Item
}

function Get-CleanupItem([Parameter(Mandatory)]$Plan, [string]$Id) { @($Plan.items | Where-Object { $_.id -eq $Id }) | Select-Object -First 1 }
function Get-CleanupItemByIndex([Parameter(Mandatory)]$Plan, [int]$Index) { @($Plan.items | Where-Object { [int]$_.index -eq $Index }) | Select-Object -First 1 }

# Deletion order = display order. Indexes are frozen once the discovery has finished (the review gate refers to them).
function Update-CleanupIndexes([Parameter(Mandatory)]$Plan) {
    $sorted = @($Plan.items | Sort-Object { [int]$_.order }, { [int]$_.seq })
    for ($i = 0; $i -lt $sorted.Count; $i++) { $sorted[$i].index = $i + 1 }
    $Plan['items'] = $sorted
}

function Set-CleanupItemStatus {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Item, [Parameter(Mandatory)][ValidateSet('toDelete', 'deleted', 'failed', 'excluded')][string]$Status,
          [string]$Reason = '', [AllowEmptyString()][string]$Notes, [switch]$AppendNotes)
    $Item.status = $Status
    $Item.reason = $Reason
    if ($PSBoundParameters.ContainsKey('Notes')) {
        $Item.notes = if ($AppendNotes -and $Item.notes) { "$($Item.notes) $Notes".Trim() } else { $Notes }
    }
    $Item.lastUpdated = (Get-Date).ToString('o')
    $Item.history = @($Item.history) + @([ordered]@{ at = $Item.lastUpdated; status = $Status; reason = $Reason })
    foreach ($child in @($Plan.items | Where-Object { $_.coveredBy -eq $Item.id -and $_.status -ne 'excluded' })) {
        if ($Status -eq 'deleted') { Set-CleanupItemStatus $Plan $child 'deleted' -Notes "Removed together with #$($Item.index) $($Item.name)." }
        elseif ($Status -eq 'failed') { Set-CleanupItemStatus $Plan $child 'failed' 'dependency' -Notes "Not removed: it goes with #$($Item.index) $($Item.name), which could not be deleted. Delete #$($Item.index) first." }
    }
}

# ------------------------------------------------------------------------------------------------------ review gate
# Exception specs of the review gate: '3, 7-9, #12, type:Configuration' (indexes, ranges, whole types). A leading
# 'exclude:' / 'keep:' / 'include:' label (the HTML "Copy exceptions" button adds one) is ignored; 'none' means none.
function ConvertFrom-CleanupSpec([Parameter(Mandatory)]$Plan, [AllowEmptyString()][string]$Spec) {
    $set = [System.Collections.Generic.SortedSet[int]]::new()
    if ([string]::IsNullOrWhiteSpace($Spec)) { return @() }
    $text = ($Spec -replace '(?i)\b(exclude|keep|include|except)\s*:', ' ').Trim()
    if ($text -match '^(?i)none$') { return @() }
    $max = @($Plan.items).Count
    foreach ($tok in @($text -split '[,;\s]+' | Where-Object { $_ })) {
        if ($tok -match '^#?(\d+)$') {
            $n = [int]$Matches[1]
            if ($n -lt 1 -or $n -gt $max) { throw "Index $n is out of range (1-$max)." }
            [void]$set.Add($n); continue
        }
        if ($tok -match '^#?(\d+)-#?(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b) { $a, $b = $b, $a }
            if ($a -lt 1 -or $b -gt $max) { throw "Range $tok is out of range (1-$max)." }
            for ($n = $a; $n -le $b; $n++) { [void]$set.Add($n) }
            continue
        }
        if ($tok -match '^(?i)type:(\w+)$') {
            $want = $Matches[1]
            $t = @($script:CleanerTypes | Where-Object { $want -match "^(?i)$($_)s?$" }) | Select-Object -First 1
            if (-not $t) { throw "Unknown type '$want' (types: $($script:CleanerTypes -join ', '))." }
            foreach ($it in @($Plan.items | Where-Object { $_.type -eq $t })) { [void]$set.Add([int]$it.index) }
            continue
        }
        throw "Cannot read '$tok': use indexes (3), ranges (7-9) or types (type:User)."
    }
    return @($set)
}

# Excluded prerequisites keep their dependents; a kept covering item keeps what it covers. Repeated until stable.
function Resolve-CleanupClosure([Parameter(Mandatory)]$Plan) {
    $added = [System.Collections.Generic.List[object]]::new()
    do {
        $changed = $false
        foreach ($it in @($Plan.items | Where-Object { $_.status -ne 'excluded' })) {
            $kept = @(@($it.dependsOn) + @($it.coveredBy) | Where-Object { $_ } | ForEach-Object { Get-CleanupItem $Plan $_ } |
                Where-Object { $_ -and $_.status -eq 'excluded' }) | Select-Object -First 1
            if ($kept) {
                Set-CleanupItemStatus $Plan $it 'excluded' 'closure' -Notes "Kept because #$($kept.index) $($kept.name) is kept (it must be deleted first)."
                $added.Add($it); $changed = $true
            }
        }
    } while ($changed)
    return @($added)
}

# Applies the review-gate exceptions: resets earlier gate decisions, includes the listed default-kept items, keeps the
# listed items, then applies the closure. Returns the effective selection.
function Set-CleanupSelection([Parameter(Mandatory)]$Plan, [string]$Exclude, [string]$Include) {
    $exc = @(ConvertFrom-CleanupSpec $Plan $Exclude)
    $inc = @(ConvertFrom-CleanupSpec $Plan $Include)
    foreach ($it in @($Plan.items | Where-Object { $_.status -eq 'excluded' -and $_.reason -in 'user', 'closure' })) {
        Set-CleanupItemStatus $Plan $it 'toDelete' -Notes ''
    }
    foreach ($it in @($Plan.items | Where-Object { $_.status -eq 'toDelete' -and $_.defaultExcluded })) {
        Set-CleanupItemStatus $Plan $it 'excluded' ([string]$it.defaultExcludedReason) -Notes ([string]$it.keptNote)
    }
    foreach ($n in $inc) {
        $it = Get-CleanupItemByIndex $Plan $n
        if ($it.status -eq 'excluded' -and $it.reason -in 'default', 'shared') {
            Set-CleanupItemStatus $Plan $it 'toDelete' -Notes ("Included at the review gate (it was $($script:CleanerReasonLabels[[string]$it.reason])). $($it.keptNote)".Trim())
        }
    }
    foreach ($n in $exc) {
        $it = Get-CleanupItemByIndex $Plan $n
        if ($it.status -eq 'toDelete') { Set-CleanupItemStatus $Plan $it 'excluded' 'user' -Notes 'Kept at the review gate (exception requested by the operator).' }
    }
    # The local lab folder holds the state, the persona passwords and the caches still needed for what is kept.
    $local = @($Plan.items | Where-Object { $_.kind -eq 'local-folder' -and $_.status -eq 'toDelete' }) | Select-Object -First 1
    $userKept = @($Plan.items | Where-Object { $_.status -eq 'excluded' -and $_.reason -in 'user', 'shared' })
    if ($local -and $userKept.Count -and -not ($inc -contains [int]$local.index)) {
        Set-CleanupItemStatus $Plan $local 'excluded' 'closure' -Notes "Kept because $($userKept.Count) lab object(s) are kept: it holds their state, passwords and caches. Include it explicitly to delete it anyway."
    }
    $closure = @(Resolve-CleanupClosure $Plan)
    $Plan.selection.excludeSpec = [string]$Exclude
    $Plan.selection.includeSpec = [string]$Include
    [pscustomobject]@{
        excludedByUser = @($Plan.items | Where-Object { $_.status -eq 'excluded' -and $_.reason -eq 'user' } | ForEach-Object { [int]$_.index })
        keptByDefault = @($Plan.items | Where-Object { $_.status -eq 'excluded' -and $_.reason -in 'default', 'shared' } | ForEach-Object { [int]$_.index })
        keptByClosure = @($Plan.items | Where-Object { $_.status -eq 'excluded' -and $_.reason -eq 'closure' } | ForEach-Object { [int]$_.index })
        closureAdded = @($closure | ForEach-Object { [int]$_.index })
        toDelete = @($Plan.items | Where-Object { $_.status -eq 'toDelete' }).Count
        manual = @($Plan.items | Where-Object { $_.status -eq 'toDelete' -and $_.executor -eq 'manual' }).Count
    }
}

# ------------------------------------------------------------------------------------------------------ answer checks
# Neutralized state of an ext_ MCP server from its registry package ($null when the registry no longer lists it):
# 'blocked', 'rejected', 'gone', or '' while it is still active (approved and not blocked, or a pending request).
function Get-McpNeutralizedState($Package) {
    if (-not $Package) { return 'gone' }
    if ($Package.isBlocked) { return 'blocked' }
    if ([string]$Package.requestStatus -in 'rejected', 'declined', 'denied') { return 'rejected' }
    return ''
}
# What still keeps an ext_ MCP server active after the operator answered 'Done' ('' when it is neutralized): an approved
# server must be Blocked, a pending request Rejected.
function Get-McpNeutralizeGap($Package) {
    if (Get-McpNeutralizedState $Package) { return '' }
    if ([string]$Package.requestStatus -eq 'pending') { return 'the request is still pending: Reject it in the admin center (Tools > Requests)' }
    return 'it is still available, not blocked: Block it in the admin center (Tools)'
}

# A platform-managed tool connector (shared_tc-...) of an ext_ MCP server that the maker API refuses to delete, even to
# the admin: handled as a possible platform limitation, never as a plain error.
function Test-CleanupConnectorRefusal($LabItem, [string]$LogText) {
    return ([string]$LabItem.action -eq 'delete-connector' -and [string]$LabItem.id -like 'shared_tc-*' -and $LogText -match 'ApiAuthorizationFailed')
}

# Agent registration ids recorded by the Lab Builder (a365.generated.config.json: agentRegistrationId) for an agent
# identity (agenticAppId).
function Get-CleanupRegistrationIds([object[]]$Configs, [string]$AgentIdentityId) {
    if (-not $AgentIdentityId) { return @() }
    @($Configs | Where-Object { $_ -and [string]$_.agenticAppId -eq $AgentIdentityId -and [string]$_.agentRegistrationId } | ForEach-Object { [string]$_.agentRegistrationId } | Select-Object -Unique)
}

# Managed identities of deleted Azure resources stay in the Entra recycle bin for 30 days: customers can neither restore
# nor purge them (Microsoft Entra FAQ, "Are managed identities soft-deleted?"); Entra purges them by itself.
function Test-CleanupManagedIdentity($Object) { [bool]($Object -and [string]$Object.servicePrincipalType -eq 'ManagedIdentity') }
function Get-CleanupManagedIdentityNote([object[]]$Objects) {
    $o = @($Objects | Where-Object { $_ })
    if (-not $o.Count) { return '' }
    $last = @($o | ForEach-Object { try { ([datetime]$_.deletedDateTime).AddDays(30) } catch { } } | Sort-Object) | Select-Object -Last 1
    $names = @($o | ForEach-Object { [string]$_.displayName }) -join ', '
    $what = if ($o.Count -eq 1) { "Managed identity of a deleted Azure resource ($names)" } else { "$($o.Count) managed identities of deleted Azure resources ($names)" }
    $pr = if ($o.Count -eq 1) { 'it' } else { 'them' }
    "${what}: Entra keeps $pr in the recycle bin and purges $pr by itself 30 days after the deletion$(if ($last) { " (by $($last.ToString('yyyy-MM-dd')))" }); customers can neither restore nor purge $pr. No conflict for a new lab: new resources get new identities."
}

# Ids of directory objects named '<prefix>-...' (the lab's Azure resource names), from a Graph list; an error object of
# Invoke-DemoGraph -NoThrow yields nothing.
function Select-CleanupPrefixedIds([object[]]$Objects, [Parameter(Mandatory)][string]$Prefix) {
    @($Objects | Where-Object { $_ -and $_.PSObject.Properties['displayName'] -and [string]$_.displayName -like "$Prefix-*" -and [string]$_.id } | ForEach-Object { [string]$_.id })
}

# ------------------------------------------------------------------------------------------------------ statistics
function Get-CleanupStats([Parameter(Mandatory)]$Plan) {
    $items = @($Plan.items)
    $byType = [ordered]@{}
    foreach ($t in $script:CleanerTypes) {
        $of = @($items | Where-Object { $_.type -eq $t })
        $byType[$t] = [ordered]@{ total = $of.Count; deleted = @($of | Where-Object status -eq 'deleted').Count
            failed = @($of | Where-Object status -eq 'failed').Count; toDelete = @($of | Where-Object status -eq 'toDelete').Count
            excluded = @($of | Where-Object status -eq 'excluded').Count }
    }
    $failed = @($items | Where-Object status -eq 'failed')
    [ordered]@{
        total = $items.Count
        deleted = @($items | Where-Object status -eq 'deleted').Count
        failed = $failed.Count
        toDelete = @($items | Where-Object status -eq 'toDelete').Count
        excluded = @($items | Where-Object status -eq 'excluded').Count
        errors = @($failed | Where-Object reason -eq 'error').Count
        limitations = @($failed | Where-Object reason -eq 'limitation').Count
        manualPending = @($failed | Where-Object reason -eq 'manual').Count
        dependency = @($failed | Where-Object reason -eq 'dependency').Count
        stillRunning = @($failed | Where-Object reason -eq 'pending').Count
        byType = $byType
    }
}

# Position of a manual item in the deletion order, for the "when" of the manual rollback guide.
function Get-CleanupWhen([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Item) {
    $before = @($Plan.items | Where-Object { [int]$_.index -lt [int]$Item.index -and $_.executor -ne 'manual' -and $_.status -ne 'excluded' }) | Select-Object -Last 1
    $after = @($Plan.items | Where-Object { [int]$_.index -gt [int]$Item.index -and $_.executor -ne 'manual' -and $_.status -ne 'excluded' }) | Select-Object -First 1
    $parts = @()
    if ($before) { $parts += "after #$($before.index) $($before.name)" }
    if ($after) { $parts += "before #$($after.index) $($after.name)" }
    if (-not $parts.Count) { return "When the run reaches #$($Item.index)" }
    return "When the run reaches #$($Item.index) ($($parts -join ', '))"
}

function Update-CleanupSummary([Parameter(Mandatory)]$Plan) {
    $stats = Get-CleanupStats $Plan
    $problems = @(foreach ($it in @($Plan.items | Where-Object status -eq 'failed')) {
        [ordered]@{ index = [int]$it.index; name = $it.name; type = $it.type; reason = $it.reason
            reasonLabel = [string]$script:CleanerReasonLabels[[string]$it.reason]; notes = $it.notes }
    })
    $manual = @(foreach ($it in @($Plan.items | Where-Object { $_.manual })) {
        [ordered]@{ index = [int]$it.index; name = $it.name; type = $it.type; status = $it.status
            when = $(if ($it.manual.when) { [string]$it.manual.when } else { Get-CleanupWhen $Plan $it })
            how = @($it.manual.steps); where = [string]$it.manual.where; verify = [string]$it.manual.verify; source = [string]$it.manual.source }
    })
    $Plan['summary'] = [ordered]@{ generatedAt = (Get-Date).ToString('o'); stats = $stats; problems = $problems; manual = $manual }
    $Plan['manualGuide'] = $manual
    $Plan['rebuild'] = @(Get-CleanupRebuildNotes $Plan)
    return $Plan.summary
}

# Expected conflicts when a new lab is built in the same language, tenant and subscription, from what this run left.
function Get-CleanupRebuildNotes([Parameter(Mandatory)]$Plan) {
    $items = @($Plan.items)
    $open = { param([string[]]$Kinds) @($items | Where-Object { $_.kind -in $Kinds -and $_.status -ne 'deleted' }) }
    $names = { param($List) (@($List | ForEach-Object { "#$($_.index) $($_.name)" }) -join ', ') }
    $notes = [System.Collections.Generic.List[object]]::new()
    $mcp = @($items | Where-Object { $_.kind -eq 'mcp-server' })
    if ($mcp.Count) {
        $notes.Add([ordered]@{ topic = 'Demo MCP server names (ext_)'; severity = 'blocker'
            problem = "No platform API deletes an ext_ registration: $(& $names $mcp) stay reserved in the tenant forever, and the same tool names must never be active on two servers."
            fix = 'The names are recorded in generated/cleanup/tenant-<tenant id>/reserved-ext-mcp-names.json: New-DemoMcpRegistration.ps1 refuses them and the pool takes the next free number. A long-lived server (records, companies) whose old servers this run verified as Blocked or Rejected (state blocked/rejected/gone in that file) is registered automatically as its successor <name><n>, when the tenant''s ext_ servers can be read (Compliant Container environment cached on this machine, or -EnvironmentId) and no other lab of this machine still has the same tools registered; otherwise pass -ServerName <new ext_ name> (on another machine always pass it). Every old server must be Blocked (approved) or Rejected (pending) first.' })
    }
    if (@($items | Where-Object { $_.status -in 'deleted', 'failed' }).Count) {
        $notes.Add([ordered]@{ topic = 'Lab name (prefix)'; severity = 'info'
            problem = "The removal of lab '$($Plan.prefix)' started: its local state describes objects that no longer exist, so the name is retired. New-DemoConfig.ps1 and the build phases of Invoke-DemoPhase.ps1 refuse it."
            fix = 'Build the new lab under another name (prefix). The localized names (personas, groups, agents, MCP servers, knowledge site) are the same in the same language, so the cleanup is what frees them, not a new prefix.' })
    }
    $csa = @($items | Where-Object { $_.kind -in 'csa-definition', 'csa-values', 'csa-set' })
    if ($csa.Count) {
        $notes.Add([ordered]@{ topic = 'Custom security attribute'; severity = 'warning'
            problem = 'Attribute sets and definitions cannot be deleted: the definition and its values are only deactivated, and a new build in the same language uses the same names.'
            fix = 'Set-DemoGovernance.ps1 reactivates a deactivated definition and its values automatically. By hand: PATCH /directory/customSecurityAttributeDefinitions/<set>_<name> {"status":"Available"} and every allowed value {"isActive":true}.' })
    }
    $reg = & $open @('registry-package', 'agent-builder-agent', 'agent-skill', 'third-party-agent')
    if ($reg.Count) {
        $notes.Add([ordered]@{ topic = 'Agent registry entries'; severity = 'blocker'
            problem = "Still listed, or only soft-deleted for 30 days (Agents > All agents > Deleted): $(& $names $reg). The new lab uses the same localized names: the Demo Builder's exact-name resolution finds two objects and stops as ambiguous."
            fix = 'Microsoft 365 admin center > Agents > All agents > select the agent > Delete agent, then All agents > Deleted > select it > Permanently delete. Then Invoke-DemoCleanup.ps1 -Retry verifies it.' })
    }
    $people = & $open @('persona-user', 'tagged-user', 'deleted-user', 'group', 'deleted-group')
    if ($people.Count) {
        $notes.Add([ordered]@{ topic = 'Persona users and groups'; severity = 'blocker'
            problem = "Not permanently deleted: $(& $names $people). UPNs (alias@domain) and group mail nicknames do not depend on the lab prefix: the new build cannot create them while the old objects exist, also in the Entra recycle bin."
            fix = 'Delete and purge them (Entra > Deleted users / Deleted groups > Delete permanently), then re-run with -Retry.' })
    }
    $mbx = & $open @('mailbox')
    if ($mbx.Count) {
        $notes.Add([ordered]@{ topic = 'Soft-deleted mailboxes'; severity = 'warning'
            problem = "Exchange keeps a soft-deleted mailbox for 30 days after the user purge ($(& $names $mbx)): a new persona with the same address can hit a proxy-address conflict and get no mailbox."
            fix = 'Exchange Online PowerShell: Get-Mailbox -SoftDeletedMailbox -Identity <upn> | Remove-Mailbox -PermanentlyDelete -Confirm:$false (a mailbox on hold becomes inactive: remove the hold first).' })
    }
    $sites = & $open @('sharepoint-deleted-site', 'onedrive')
    if ($sites.Count) {
        $notes.Add([ordered]@{ topic = 'SharePoint and OneDrive'; severity = 'warning'
            problem = "Deleted sites stay in the SharePoint recycle bin for 93 days and the OneDrive of a deleted user is retained ($(& $names $sites)). The new knowledge site gets another URL (a numeric suffix) until the old one is permanently deleted."
            fix = 'SharePoint Online Management Shell: Remove-SPODeletedSite -Identity <url> (group-connected sites cannot be purged from the admin center UI); for a OneDrive Remove-SPOSite -Identity <url>, then Remove-SPODeletedSite. A URL can take up to 24 hours to become free.' })
    }
    $rg = @($items | Where-Object { $_.data.labItem.kind -eq 'azure-rg' -and $_.status -ne 'deleted' })
    if ($rg.Count) {
        $notes.Add([ordered]@{ topic = 'Azure resource groups'; severity = 'blocker'
            problem = "Not deleted yet: $(& $names $rg). The agent resource groups are named <agent code name>-rg from the locale, not from the prefix: the same language reuses the same names."
            fix = 'Wait until az group exists -n <rg> returns false (Invoke-DemoCleanup.ps1 -Retry checks it again), then rebuild.' })
    }
    $gov = & $open @('ca-policy', 'access-package', 'catalog', 'scc-policy', 'sensitivity-label', 'label-policy', 'ediscovery-case', 'admin-center-object', 'audit-search', 'hunting-query')
    if ($gov.Count) {
        $notes.Add([ordered]@{ topic = 'Governance objects with localized names'; severity = 'warning'
            problem = "Still present: $(& $names $gov). Labels, DLP, retention and Communication Compliance policies, eDiscovery cases and admin-center templates, tags and rules need unique names; the catalog is reused by name (Set-DemoGovernance.ps1 takes the first one found)."
            fix = 'Delete them as described in their Notes, then re-run with -Retry. A deleted sensitivity label can keep its name reserved for a while: wait before creating it again.' })
    }
    $notes.Add([ordered]@{ topic = 'What remains by design'; severity = 'info'
        problem = 'Audit records, Defender incidents and alerts, Insider Risk and Communication Compliance alerts of the old lab stay visible; disabled Dataverse user records of the deleted personas stay in the Copilot Studio environments.'
        fix = 'Resolve the old incidents and alerts before the new rehearsals and filter the evidence by date. The Dataverse records need no action.' })
    $notes.Add([ordered]@{ topic = 'Licenses and prerequisites'; severity = 'info'
        problem = 'Licenses are released only by the permanent deletion of users and agent users. The pay-as-you-go Copilot Studio environment, the Defender connectors and the per-tenant compliant-environment cache are prerequisites, not lab objects.'
        fix = 'Run the license gate of the new build (Test-DemoPrereqs.ps1). Keep %LOCALAPPDATA%\a365-lab\pp-compliant-env.<tenant id>.txt: it stays valid for the tenant.' })
    return @($notes)
}

# ------------------------------------------------------------------------------------------------------ HTML report
function ConvertTo-CleanupViewModel([Parameter(Mandatory)]$Plan) {
    $ctx = $Plan.context
    [ordered]@{
        schemaVersion = $Plan.schemaVersion; runId = $Plan.runId; prefix = $Plan.prefix; phase = $Plan.phase; mode = $Plan.mode
        manualMode = $Plan.manualMode; updatedAt = $Plan.updatedAt; createdAt = $Plan.createdAt
        tenantId = $ctx.tenantId; subscriptionId = $ctx.subscriptionId; locale = $ctx.locale; pack = $ctx.pack; domain = $ctx.domain
        discovery = $Plan.discovery; selection = $Plan.selection; warnings = @($Plan.warnings)
        statusLabels = $script:CleanerStatusLabels; reasonLabels = $script:CleanerReasonLabels; types = $script:CleanerTypes
        stats = (Get-CleanupStats $Plan); summary = $Plan.summary; manualGuide = @($Plan.manualGuide); rebuild = @($Plan.rebuild); runbook = @($Plan.runbook)
        items = @($Plan.items | ForEach-Object {
            [ordered]@{ index = $_.index; name = $_.name; detail = $_.detail; type = $_.type; status = $_.status; reason = $_.reason
                lastUpdated = $_.lastUpdated; notes = $_.notes; executor = $_.executor; defaultExcluded = $_.defaultExcluded
                manual = $(if ($_.manual) { [ordered]@{ where = $_.manual.where; steps = @($_.manual.steps); verify = $_.manual.verify } } else { $null }) }
        })
    }
}

function Write-CleanupReport([Parameter(Mandatory)]$Plan) {
    $dir = [string]$Plan.runDir
    $json = (ConvertTo-CleanupViewModel $Plan) | ConvertTo-Json -Depth 30 -Compress -EscapeHandling EscapeHtml
    Set-CleanupFileAtomic (Join-Path $dir 'cleanup-data.js') "window.DEMO_CLEANUP_DATA = $json;`n"
    $template = Get-Content -LiteralPath (Join-Path $script:CleanerSkillDir 'assets\cleanup-report.html') -Raw -Encoding utf8
    $title = [System.Net.WebUtility]::HtmlEncode("Demo Cleaner - lab $($Plan.prefix)")
    $html = $template.Replace('__TITLE__', $title).Replace('__DATA_FILE__', 'cleanup-data.js').Replace('__INITIAL_DATA__', $json)
    Set-CleanupFileAtomic (Join-Path $dir 'cleanup-report.html') $html
}

function Get-CleanupReportUri([Parameter(Mandatory)][string]$RunDir) { ([System.Uri](Join-Path $RunDir 'cleanup-report.html')).AbsoluteUri }

# ------------------------------------------------------------------------------------------------------ context
# Demo configuration hashtable for the Demo Builder helpers, rebuilt from the plan context (the lab folder may be gone).
function ConvertTo-CleanupConfig([Parameter(Mandatory)]$Context) {
    $c = [ordered]@{}
    foreach ($k in 'prefix', 'pack', 'locale', 'tenantId', 'subscriptionId', 'domain', 'adminUpn', 'region', 'copilotStudio', 'foundry', 'licenseSkus') { $c[$k] = $Context[$k] }
    if ($Context.auth.mode -eq 'lab' -and $Context.auth.azConfigDir) { $c['azConfigDir'] = $Context.auth.azConfigDir }
    if (-not $c.copilotStudio) { $c['copilotStudio'] = @{} }
    if (-not $c.foundry) { $c['foundry'] = @{} }
    return $c
}

# Applies the isolated authentication context of the run to THIS process (every tool call is a new process): the
# lab-private az profile of the build, or the dedicated session directory of this cleanup. Never the shared default.
function Use-CleanupAuth([Parameter(Mandatory)]$Context) {
    if ($Context.auth.mode -eq 'session') {
        if (-not $Context.auth.sessionDir) { throw 'The cleanup context has no session authentication directory.' }
        New-Item -ItemType Directory -Force -Path $Context.auth.sessionDir | Out-Null
        $env:DEMO_SESSION_AUTH_DIR = [string]$Context.auth.sessionDir
    }
    else {
        Remove-Item Env:\DEMO_SESSION_AUTH_DIR -ErrorAction SilentlyContinue
        if (-not $Context.auth.azConfigDir) { throw 'The cleanup context has no lab-private az profile: use the session authentication mode.' }
        $abs = if ([IO.Path]::IsPathRooted([string]$Context.auth.azConfigDir)) { [string]$Context.auth.azConfigDir } else { Join-Path $script:DemoRepoRoot $Context.auth.azConfigDir }
        if (-not (Test-Path -LiteralPath $abs)) { throw "The lab-private az profile $abs no longer exists (lab folder deleted?): continue in the session authentication mode." }
    }
    $cfg = ConvertTo-CleanupConfig $Context
    Use-DemoAzProfile $cfg
    return $cfg
}

function Get-CleanupLoginCommand([Parameter(Mandatory)]$Context) {
    $null = Use-CleanupAuth $Context
    "`$env:AZURE_CONFIG_DIR='$($env:AZURE_CONFIG_DIR)'; `$env:AZURE_EXTENSION_DIR='$($env:AZURE_EXTENSION_DIR)'; az login --tenant $($Context.tenantId)"
}

# Delegated Microsoft Graph scopes of the cleanup (Microsoft Graph Command Line Tools client, system browser on first use,
# the lab's MSAL cache of the isolated context). az tokens are used where they suffice (users, groups, apps, deleted items).
$script:CleanerGraphScopes = @('Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess', 'EntitlementManagement.ReadWrite.All',
    'CustomSecAttributeDefinition.ReadWrite.All', 'CopilotPackages.ReadWrite.All', 'AgentRegistration.ReadWrite.All',
    'eDiscovery.ReadWrite.All', 'Sites.Read.All', 'Files.Read.All', 'RoleManagement.ReadWrite.Directory', 'Group.ReadWrite.All')
$script:CleanerGraphToken = $null; $script:CleanerGraphTokenExp = [datetime]::MinValue
function Get-CleanupGraphToken([Parameter(Mandatory)]$Config, [switch]$SilentOnly) {
    if ($script:CleanerGraphToken -and $script:CleanerGraphTokenExp -gt (Get-Date).AddMinutes(5)) { return $script:CleanerGraphToken }
    $t = Get-DemoMsalToken -TenantId $Config.tenantId -Prefix $Config.prefix -LoginHint $Config.adminUpn -Scopes $script:CleanerGraphScopes -SilentOnly:$SilentOnly
    if ($t) { $script:CleanerGraphToken = $t; $script:CleanerGraphTokenExp = (Get-Date).AddMinutes(50) }
    return $t
}

# GET that returns $null on 404 and throws on any other error (an authorization failure must never look like "absent").
function Get-CleanupObject([Parameter(Mandatory)][string]$Uri, [string]$Token) {
    $p = @{ NoThrow = $true; MaxRetries = 3 }
    if ($Token) { $p['Token'] = $Token }
    $r = Invoke-DemoGraph GET $Uri @p
    if ($r -and $r.PSObject.Properties['error'] -and $r.PSObject.Properties['status'] -and @($r.PSObject.Properties).Count -eq 2) {
        if ($r.status -eq 404) { return $null }
        throw $r.error
    }
    return $r
}

# Entra application or service principal by object id or appId; $null when neither resolves.
function Find-CleanupEntraObject([Parameter(Mandatory)][ValidateSet('applications', 'servicePrincipals')][string]$Collection, [string]$Id) {
    if (-not $Id) { return $null }
    $o = Get-CleanupObject "https://graph.microsoft.com/v1.0/$Collection/$Id`?`$select=id,appId,displayName"
    if (-not $o) { $o = Get-CleanupObject "https://graph.microsoft.com/v1.0/$Collection(appId='$Id')?`$select=id,appId,displayName" }
    return $o
}
