#requires -Version 7.0
# Offline tests of the Demo Cleaner helpers: review-gate specs, closure, status propagation, statistics, rebuild notes,
# the reserved ext_ names memory, the live HTML report and the runner's main loop (manual checkpoints, defer, retry,
# dependencies, limitations; az stubbed). No cloud call, no tenant, no lab folder needed.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\agent365-demo-builder\scripts\_demo-common.ps1')
. (Join-Path $PSScriptRoot '_demo-cleaner.ps1')
$passed = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
    Write-Host "PASS: $Message"
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('demo-cleaner-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $ctx = [ordered]@{ prefix = 'unit'; pack = 'fixture'; locale = 'it'; tenantId = 'tenant'; subscriptionId = 'subscription'; domain = 'contoso.example'
        auth = [ordered]@{ mode = 'session'; sessionDir = (Join-Path $root 'auth'); azConfigDir = '' } }
    $cp = New-CleanupPlan 'unit' $root $ctx
    $add = { param($it) Add-CleanupItem $cp $it | Out-Null }
    & $add (New-CleanupItem -Id 'catalog:1' -Name 'Catalog' -Type Configuration -Order 3030 -Executor 'graph' -Action 'delete-catalog' -Kind 'catalog')
    & $add (New-CleanupItem -Id 'group:dir' -Name 'Directory readers' -Type Group -Order 6210 -Executor 'graph' -Action 'delete-group' -Kind 'group' -DependsOn @('catalog:1'))
    & $add (New-CleanupItem -Id 'group:site' -Name 'Site group' -Type Group -Order 6211 -Executor 'graph' -Action 'delete-group' -Kind 'group')
    & $add (New-CleanupItem -Id 'sharepoint:site' -Name 'Knowledge site' -Type Resource -Order 6212 -Executor 'covered' -Action 'covered' -Kind 'sharepoint-site' -CoveredBy 'group:site')
    & $add (New-CleanupItem -Id 'mcp-server:ext_RecordsTest' -Name 'ext_RecordsTest' -Type Component -Order 1510 -Executor 'mcp-neutralize' -Kind 'mcp-server' -Limitation 'cannot be deleted')
    & $add (New-CleanupItem -Id 'csa:definition' -Name 'Set / Attr' -Type Configuration -Order 7020 -Executor 'graph' -Kind 'csa-definition')
    & $add (New-CleanupItem -Id 'pp:payg' -Name 'PAYG environment' -Type Configuration -Order 7060 -Executor 'manual' -Kind 'tenant-setting' -DefaultExcluded -Notes 'prerequisite' `
        -Manual ([ordered]@{ where = 'PPAC'; steps = @('Delete it'); verify = 'none' }))
    & $add (New-CleanupItem -Id 'user:maker' -Name 'Luke <script>alert(1)</script> Byrne' -Type User -Order 6010 -Executor 'lab-cleaner' -Kind 'persona-user')
    & $add (New-CleanupItem -Id 'admin:tag' -Name 'Tag' -Type Configuration -Order 1030 -Executor 'manual' -Kind 'admin-center-object' -Manual ([ordered]@{ where = 'Admin center'; steps = @('Delete the tag') }))
    & $add (New-CleanupItem -Id 'local:lab-folder' -Name 'generated\unit' -Type Resource -Order 9010 -Executor 'local' -Kind 'local-folder')
    & $add (New-CleanupItem -Id 'catalog:1' -Name 'Duplicate' -Type Configuration -Order 1 -Executor 'graph' -Origin 'second-path')
    Update-CleanupIndexes $cp
    $ids = @($cp.items | ForEach-Object { $_.id })
    Assert ($cp.items.Count -eq 10) 'duplicate ids are not added twice'
    Assert ((Get-CleanupItem $cp 'catalog:1').origin -match 'second-path') 'a second discovery path is recorded in the origin'
    Assert ($ids[0] -eq 'admin:tag' -and $ids[1] -eq 'mcp-server:ext_RecordsTest' -and $ids[-1] -eq 'local:lab-folder') 'deletion order follows the order field'
    Assert ((@($cp.items | ForEach-Object { $_.index }) -join ',') -eq '1,2,3,4,5,6,7,8,9,10') 'indexes are 1..N in deletion order'
    Assert ((Get-CleanupItem $cp 'pp:payg').status -eq 'excluded' -and (Get-CleanupItem $cp 'pp:payg').reason -eq 'default') 'default-kept items start excluded'

    # Review-gate specs.
    $idx = { param($id) [int](Get-CleanupItem $cp $id).index }
    Assert ((@(ConvertFrom-CleanupSpec $cp '1, 3-4, #6') -join ',') -eq '1,3,4,6') 'indexes, ranges and # prefixes'
    Assert ((@(ConvertFrom-CleanupSpec $cp 'exclude: 5-3') -join ',') -eq '3,4,5') 'reversed range and exclude label'
    Assert ((@(ConvertFrom-CleanupSpec $cp 'type:Groups') -join ',') -eq "$(& $idx 'group:dir'),$(& $idx 'group:site')" -or (@(ConvertFrom-CleanupSpec $cp 'type:Groups') -join ',') -eq "$(& $idx 'group:site'),$(& $idx 'group:dir')") 'type filter, plural accepted'
    Assert (@(ConvertFrom-CleanupSpec $cp 'exclude: none').Count -eq 0) "'none' means no exception"
    $bad = $false; try { ConvertFrom-CleanupSpec $cp '99' | Out-Null } catch { $bad = $_.Exception.Message -like '*out of range*' }
    Assert $bad 'an index out of range is refused'
    $bad = $false; try { ConvertFrom-CleanupSpec $cp 'users' | Out-Null } catch { $bad = $_.Exception.Message -like 'Cannot read*' }
    Assert $bad 'an unreadable token is refused'
    $bad = $false; try { ConvertFrom-CleanupSpec $cp 'type:Robots' | Out-Null } catch { $bad = $_.Exception.Message -like 'Unknown type*' }
    Assert $bad 'an unknown type is refused'

    # Selection, closure and the local folder.
    $r = Set-CleanupSelection $cp "$(& $idx 'catalog:1')" "$(& $idx 'pp:payg')"
    Assert ((Get-CleanupItem $cp 'catalog:1').reason -eq 'user') 'an exception keeps the element'
    Assert ((Get-CleanupItem $cp 'group:dir').status -eq 'excluded' -and (Get-CleanupItem $cp 'group:dir').reason -eq 'closure') 'a dependent of a kept prerequisite is kept'
    Assert ((Get-CleanupItem $cp 'local:lab-folder').status -eq 'excluded') 'the local folder is kept while lab objects are kept'
    Assert ((Get-CleanupItem $cp 'pp:payg').status -eq 'toDelete') 'include brings back a default-kept element'
    Assert (@($r.closureAdded) -contains (& $idx 'group:dir')) 'the closure additions are reported'
    $r = Set-CleanupSelection $cp '' ''
    Assert ((Get-CleanupItem $cp 'catalog:1').status -eq 'toDelete' -and (Get-CleanupItem $cp 'group:dir').status -eq 'toDelete') 'a new selection resets the previous exceptions'
    Assert ((Get-CleanupItem $cp 'pp:payg').status -eq 'excluded') 'a new selection restores the default-kept elements'
    Assert ((Get-CleanupItem $cp 'local:lab-folder').status -eq 'toDelete') 'without exceptions the local folder is deleted'

    # Status propagation and statistics.
    Set-CleanupItemStatus $cp (Get-CleanupItem $cp 'group:site') 'deleted' -Notes 'ok'
    Assert ((Get-CleanupItem $cp 'sharepoint:site').status -eq 'deleted') 'a covered element follows its covering element'
    Set-CleanupItemStatus $cp (Get-CleanupItem $cp 'mcp-server:ext_RecordsTest') 'failed' 'limitation' -Notes 'blocked'
    Set-CleanupItemStatus $cp (Get-CleanupItem $cp 'user:maker') 'failed' 'error' -Notes 'denied'
    $st = Get-CleanupStats $cp
    Assert ($st.deleted -eq 2 -and $st.failed -eq 2 -and $st.errors -eq 1 -and $st.limitations -eq 1) 'statistics by status and reason'
    Assert ($st.byType.Group.deleted -eq 1 -and $st.byType.Resource.deleted -eq 1) 'statistics by type'
    $sum = Update-CleanupSummary $cp
    Assert (@($sum.problems).Count -eq 2) 'the problems list holds every element that could not be deleted'
    $tagGuide = @($cp.manualGuide | Where-Object { $_.name -eq 'Tag' })
    Assert ($tagGuide.Count -eq 1 -and $tagGuide[0].when -like 'When the run reaches #1*') 'the manual guide says when to act'
    $topics = @($cp.rebuild | ForEach-Object { $_.topic })
    Assert ($topics -contains 'Demo MCP server names (ext_)' -and $topics -contains 'Custom security attribute') 'rebuild notes cover the reserved names and the attribute'
    Assert ($topics -contains 'Persona users and groups') 'rebuild notes flag users that are not purged'
    Assert ($topics -contains 'Lab name (prefix)') 'rebuild notes retire the lab name once the removal started'
    Assert (@($cp.rebuild | Where-Object { $_.severity -eq 'info' }).Count -ge 2) 'rebuild notes keep the by-design items'

    # Live report: one data file plus a self-contained page with the same data embedded.
    Save-CleanupPlan $cp
    $html = Get-Content -LiteralPath (Join-Path $root 'cleanup-report.html') -Raw
    $js = Get-Content -LiteralPath (Join-Path $root 'cleanup-data.js') -Raw
    Assert ($html -notmatch '__(TITLE|DATA_FILE|INITIAL_DATA)__') 'every template token is resolved'
    Assert ($js.StartsWith('window.DEMO_CLEANUP_DATA = ')) 'the data file sets the report data'
    Assert ($html -notmatch '<script>alert\(1\)' -and $js -notmatch '<script>alert') 'markup in names is escaped in page and data'
    $m = [regex]::Match($html, '<script type="application/json" id="initial-data">(.*?)</script>', 'Singleline')
    $data = $m.Groups[1].Value | ConvertFrom-Json
    Assert ($data.items.Count -eq 10 -and $data.items[0].name -eq 'Tag') 'the embedded data holds every element in order'
    Assert ($data.items.Where({ $_.name -like 'Luke*' })[0].name -eq 'Luke <script>alert(1)</script> Byrne') 'escaping keeps the original text'
    Assert (@($data.types) -join ',' -eq 'User,Group,Resource,Configuration,Component,Agent') 'the six types are offered as filters'
    Assert ($html -match 'id="auto" checked' -and $html -match 'id="refresh"' -and $html -match 'id="status-filter"' -and $html -match 'id="type-filter"') 'refresh button, auto-refresh checkbox and both filters'
    Assert ($html -match 'setInterval' -and $html -match 'seconds = 60') 'auto-refresh every 60 seconds'
    Assert ($html -notmatch '<script[^>]+src=' -and $html -notmatch '<link[^>]+href=') 'no external script or stylesheet'
    Assert ($html -match 'copy-exceptions') 'the review gate offers the exception list copy'
    Assert (-not (Get-ChildItem -LiteralPath $root -Filter '*.tmp')) 'atomic writes leave no temporary file'

    # Tenant memory of the ext_ names that stay reserved.
    $script:DemoRepoRoot = $root
    $f = Add-DemoReservedMcpNames -TenantId 'tenant' -Prefix 'unit' -Names @(@{ name = 'ext_RecordsTest'; state = 'approved' }, @{ name = 'ext_DatesTest01'; state = 'pending' })
    $null = Add-DemoReservedMcpNames -TenantId 'tenant' -Prefix 'unit2' -Names @(@{ name = 'ext_RecordsTest'; state = 'approved' })
    $names = @(Get-DemoReservedMcpNames 'tenant')
    Assert ($names.Count -eq 2 -and $names -contains 'ext_DatesTest01') 'reserved names are recorded once per tenant'
    Assert ($f -like "*generated\cleanup\tenant-tenant\reserved-ext-mcp-names.json") 'the memory lives under generated\cleanup (kept when a lab folder is deleted)'
    Assert (@(Get-DemoReservedMcpNames 'other').Count -eq 0) 'another tenant has its own memory'

    # Operator answers on ext_ servers and platform refusals of tool connectors.
    Assert ((Get-McpNeutralizeGap ([pscustomobject]@{ isBlocked = $false; requestStatus = $null })) -like '*Block it*') "an approved ext_ server answered 'Done' must be blocked"
    Assert ((Get-McpNeutralizeGap ([pscustomobject]@{ isBlocked = $false; requestStatus = 'pending' })) -like '*Reject it*') 'a pending ext_ request must be rejected'
    Assert ((Get-McpNeutralizeGap ([pscustomobject]@{ isBlocked = $true; requestStatus = $null })) -eq '' -and (Get-McpNeutralizeGap $null) -eq '') 'a blocked or no longer listed ext_ server is neutralized'
    Assert ((Get-McpNeutralizeGap ([pscustomobject]@{ isBlocked = $false; requestStatus = 'approved' })) -like '*Block it*') 'an unknown request status is not taken as neutralized'
    Assert ((Get-McpNeutralizedState ([pscustomobject]@{ isBlocked = $true })) -eq 'blocked' -and (Get-McpNeutralizedState ([pscustomobject]@{ isBlocked = $false; requestStatus = 'rejected' })) -eq 'rejected' -and (Get-McpNeutralizedState $null) -eq 'gone') 'the neutralized state recorded for the next build'
    $refused = 'connector delete failed: ERROR: Forbidden({"error":{"code":"ApiAuthorizationFailed","message":"no permission to custom connector"}})'
    Assert (Test-CleanupConnectorRefusal @{ action = 'delete-connector'; id = 'shared_tc-ext-5frecordstest-5f41' } $refused) 'a refused platform-managed tool connector is not a plain error'
    Assert (-not (Test-CleanupConnectorRefusal @{ action = 'delete-connector'; id = 'shared_ext-5frecordstest-5f41' } $refused)) 'a refused custom connector stays an error'
    $cfgs = @([pscustomobject]@{ agenticAppId = 'id-a'; agentRegistrationId = 'reg-a' }, [pscustomobject]@{ agenticAppId = 'id-b'; agentRegistrationId = '' }, $null)
    Assert ((@(Get-CleanupRegistrationIds $cfgs 'id-a') -join ',') -eq 'reg-a' -and @(Get-CleanupRegistrationIds $cfgs 'id-b').Count -eq 0 -and @(Get-CleanupRegistrationIds $cfgs '').Count -eq 0) 'the agent registration of a code agent is found by its agent identity'
    $deleted = @([pscustomobject]@{ id = '1'; displayName = 'unit-dmcp-records-ca' }, [pscustomobject]@{ id = '2'; displayName = 'unit-foundry/projects/demo' },
        [pscustomobject]@{ id = '3'; displayName = 'unit2-foundry' }, [pscustomobject]@{ id = '4'; displayName = 'Records Assistant' }, [pscustomobject]@{ error = 'x'; status = 403 })
    Assert ((@(Select-CleanupPrefixedIds $deleted 'unit') -join ',') -eq '1,2') "the recycle-bin sweep takes only '<prefix>-' names (not another lab's prefix, not an error object)"
    $mi1 = [pscustomobject]@{ id = 'm1'; displayName = 'unit-dmcp-records-ca'; servicePrincipalType = 'ManagedIdentity'; deletedDateTime = [datetime]'2026-11-13T22:29:38Z' }
    $mi2 = [pscustomobject]@{ id = 'm2'; displayName = 'unit-foundry'; servicePrincipalType = 'ManagedIdentity'; deletedDateTime = '2026-11-14T01:00:00Z' }
    Assert ((Test-CleanupManagedIdentity $mi1) -and -not (Test-CleanupManagedIdentity ([pscustomobject]@{ servicePrincipalType = 'Application' })) -and -not (Test-CleanupManagedIdentity $null)) 'managed identities in the recycle bin are recognized (they cannot be purged)'
    $note = Get-CleanupManagedIdentityNote @($mi1, $mi2)
    Assert ($note -match '^2 managed identities' -and $note -match 'unit-dmcp-records-ca, unit-foundry' -and $note -match 'by 2026-12-1[34]' -and (Get-CleanupManagedIdentityNote @()) -eq '') 'the managed-identity note names them and gives the automatic purge date'

    # Pure helpers of the page (Node.js, when installed).
    if (Get-Command node -ErrorAction SilentlyContinue) {
        $page = Get-Content -LiteralPath (Join-Path $script:CleanerSkillDir 'assets\cleanup-report.html') -Raw
        $scripts = [regex]::Matches($page, '<script>(.*?)</script>', 'Singleline') | ForEach-Object { $_.Groups[1].Value }
        $core = Join-Path $root 'core.js'
        Set-Content -LiteralPath $core -Value ($scripts[1] + @'

const R = globalThis.DemoCleanerReport;
const items = [{ index: 1, type: "User", status: "toDelete", name: "Grace", detail: "", notes: "" },
  { index: 2, type: "Group", status: "deleted", name: "Dept", detail: "", notes: "x" }];
const out = [R.compressRanges([7, 3, 4, 5, 9, 4]), R.filterItems(items, { types: ["User"] }).length,
  R.filterItems(items, { types: [], status: "deleted" }).length, R.filterItems(items, { query: "gra" }).length, R.formatTime("bad")];
console.log(JSON.stringify(out));
'@) -Encoding utf8
        $res = node $core | ConvertFrom-Json
        Assert ($res[0] -eq '3-5, 7, 9') 'exception list compressed into ranges'
        Assert ($res[1] -eq 1 -and $res[2] -eq 1 -and $res[3] -eq 1) 'table filters by type, status and text'
        Assert ($res[4] -eq 'bad') 'an unreadable time is shown as it is'
        foreach ($i in 0..($scripts.Count - 1)) {
            $file = Join-Path $root "script$i.js"; Set-Content -LiteralPath $file -Value $scripts[$i] -Encoding utf8
            node --check $file
            Assert ($LASTEXITCODE -eq 0) "page script $i has valid JavaScript syntax"
        }
    }
    else { Write-Host 'SKIP: Node.js not installed (JavaScript checks)' }

    # Runner main loop, offline: an az stub first in PATH (this process and its children only), no cloud element.
    if ($IsWindows) {
        $run = Join-Path $root 'run'; $bin = Join-Path $root 'bin'
        New-Item -ItemType Directory -Force -Path $run, $bin | Out-Null
        "@echo off`r`nif `"%1`"==`"account`" if `"%2`"==`"show`" (echo tenant& exit /b 0)`r`nexit /b 0" | Set-Content -LiteralPath (Join-Path $bin 'az.cmd') -Encoding ascii
        $rctx = [ordered]@{ prefix = 'unit'; pack = 'fixture'; locale = 'it'; tenantId = 'tenant'; subscriptionId = 'subscription'
            auth = [ordered]@{ mode = 'session'; sessionDir = (Join-Path $run 'auth'); azConfigDir = '' } }
        $rp = New-CleanupPlan 'unit' $run $rctx
        $man = { param($w) [ordered]@{ where = $w; steps = @('Delete it.'); verify = 'Confirm it in the chat.' } }
        Add-CleanupItem $rp (New-CleanupItem -Id 'rule' -Name 'Rule' -Type Configuration -Order 1010 -Executor 'manual' -Kind 'admin-center-object' -Manual (& $man 'Admin center')) | Out-Null
        Add-CleanupItem $rp (New-CleanupItem -Id 'set' -Name 'Attribute set' -Type Configuration -Order 7030 -Executor 'record-only' -Kind 'csa-set' -Limitation 'Attribute sets cannot be deleted.') | Out-Null
        Add-CleanupItem $rp (New-CleanupItem -Id 'search' -Name 'Audit search' -Type Resource -Order 7040 -Executor 'manual' -Kind 'audit-search' -Manual (& $man 'Purview')) | Out-Null
        Add-CleanupItem $rp (New-CleanupItem -Id 'query' -Name 'Hunting query' -Type Configuration -Order 7050 -Executor 'manual' -Kind 'hunting-query' -DependsOn 'search' -Manual (& $man 'Defender')) | Out-Null
        Add-CleanupItem $rp (New-CleanupItem -Id 'local' -Name 'generated\unit' -Type Resource -Order 9010 -Executor 'local' -Kind 'local-folder' -Data ([ordered]@{ path = (Join-Path $root 'no-lab-folder') })) | Out-Null
        Update-CleanupIndexes $rp
        $rp['phase'] = 'review'
        Save-CleanupPlan $rp
        $oldPath = $env:PATH; $env:PATH = "$bin;$env:PATH"
        try {
            $runner = Join-Path $PSScriptRoot 'Invoke-DemoCleanup.ps1'
            $selector = Join-Path $PSScriptRoot 'Set-DemoCleanupSelection.ps1'
            $status = { param($Id) $p = Get-Content -LiteralPath (Join-Path $run 'cleanup-plan.json') -Raw | ConvertFrom-Json; $i = @($p.items | Where-Object id -eq $Id)[0]; "$($i.status)/$($i.reason)" }
            $phase = { (Get-Content -LiteralPath (Join-Path $run 'cleanup-plan.json') -Raw | ConvertFrom-Json).phase }
            $null = & pwsh -NoProfile -File $runner -RunDir $run -Apply 2>&1
            Assert ($LASTEXITCODE -ne 0 -and (& $status 'rule') -eq 'toDelete/') 'the runner refuses to delete before the second gate'
            $rp['phase'] = 'discovery'; Save-CleanupPlan $rp
            $null = & pwsh -NoProfile -File $runner -RunDir $run -WhatIf 2>&1
            Assert ($LASTEXITCODE -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $run 'whatif.log')) -and (& $phase) -eq 'discovery') 'the dry run waits for the end of the discovery (no partial plan saved back)'
            $rp['phase'] = 'review'; Save-CleanupPlan $rp
            $null = & pwsh -NoProfile -File $runner -RunDir $run -WhatIf 2>&1
            Assert ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $run 'whatif.log')) -and (& $phase) -eq 'review') 'the dry run works on the previewed selection, before the confirmation'
            $null = & pwsh -NoProfile -File $selector -RunDir $run -Confirm 2>&1
            $null = & pwsh -NoProfile -File $selector -RunDir $run -Exclude 2 2>&1
            $null = & pwsh -NoProfile -File $runner -RunDir $run -Apply 2>&1
            Assert ($LASTEXITCODE -ne 0 -and (& $phase) -eq 'review') 'a later preview withdraws the confirmation'
            $null = & pwsh -NoProfile -File $selector -RunDir $run -Confirm 2>&1
            $null = & pwsh -NoProfile -File $runner -RunDir $run -Apply 2>&1
            $pending = @(Get-Content -LiteralPath (Join-Path $run 'pending-manual.json') -Raw | ConvertFrom-Json)
            Assert ($LASTEXITCODE -eq 10 -and $pending.Count -eq 1 -and $pending[0].index -eq 1) 'a manual element pauses the run (exit code 10) at its checkpoint'
            $null = & pwsh -NoProfile -File $runner -RunDir $run -Apply -Done 1 -ManualMode defer 2>&1
            Assert ($LASTEXITCODE -eq 0 -and (& $status 'rule') -eq 'deleted/' -and (& $status 'set') -eq 'failed/limitation') 'answered manual element deleted; record-only element ends as a platform limitation'
            Assert ((& $status 'search') -eq 'failed/manual' -and (& $status 'query') -eq 'failed/dependency') 'defer mode goes on; the dependent of a deferred action is blocked'
            Assert ((& $status 'local') -eq 'toDelete/') 'the local lab folder waits while something can be retried'
            Assert ((Get-Content -LiteralPath (Join-Path $run 'summary.md') -Raw) -match '(?s)Problems that prevented a deletion.*Manual rollback still to do') 'summary.md lists the problems and the open manual rollback'
            $null = & pwsh -NoProfile -File $runner -RunDir $run -Apply -Retry -Only 4 2>&1
            Assert ((& $status 'search') -eq 'failed/manual' -and (& $status 'query') -eq 'failed/dependency') 'with -Only, -Retry reopens only the listed elements'
            $null = & pwsh -NoProfile -File $runner -RunDir $run -Apply -Done '3, 2' -Retry 2>&1
            Assert ((& $status 'set') -eq 'failed/limitation') 'an operator answer on an automatic element is ignored'
            $null = & pwsh -NoProfile -File $runner -RunDir $run -Apply -Absent 4 2>&1
            Assert ((& $status 'search') -eq 'deleted/' -and (& $status 'query') -eq 'deleted/' -and (& $status 'local') -eq 'deleted/') 'Retry and the later answers complete the run; the local folder goes last'
        }
        finally { $env:PATH = $oldPath }
    }
    else { Write-Host 'SKIP: runner simulation (Windows az stub)' }

    foreach ($name in 'Get-DemoCleanupPlan.ps1', 'Set-DemoCleanupSelection.ps1', 'Invoke-DemoCleanup.ps1', '_demo-cleaner.ps1') {
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name), [ref]$null, [ref]$errors)
        Assert (-not $errors.Count) "$name has valid PowerShell syntax"
    }
    Write-Host "Passed $passed, failed 0"
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
