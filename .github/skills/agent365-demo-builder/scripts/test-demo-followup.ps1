#requires -Version 7.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_demo-common.ps1')
$validator = Join-Path $PSScriptRoot 'Test-DemoPack.ps1'
$rolesScript = Join-Path $PSScriptRoot 'Set-DemoIdentities.ps1'
$originalPacksRoot = $env:DEMO_PACKS_ROOT
$temp = Join-Path ([IO.Path]::GetTempPath()) ('a365-demo-followup-' + [guid]::NewGuid().ToString('N'))
$passed = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        if ($script:ValidationOutput) { Write-Host $script:ValidationOutput }
        throw "FAIL: $Message"
    }
    $script:passed++
    Write-Host "PASS: $Message"
}
function Run-Validation([switch]$Fix) {
    $arguments = @('-NoProfile', '-File', $validator, '-Pack', 'fixture', '-Locale', 'en')
    if ($Fix) { $arguments += '-Fix' }
    $script:ValidationOutput = & pwsh @arguments 2>&1 | Out-String
    $script:ValidationCode = $LASTEXITCODE
}
try {
    $pack = Get-DemoPack
    $locale = Get-DemoLocale -Locale en
    $locale.Remove('_unresolved')
    $knowledge = $locale.knowledge; $locale.Remove('knowledge')
    $tests = $locale.tests; $locale.Remove('tests')
    $pack.locales = @('en'); $pack.defaultLocale = 'en'
    $root = Join-Path $temp 'packs'
    $directory = Join-Path $root 'fixture\locales\en'
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $pack | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $root 'fixture\pack.json')
    $core = Join-Path $directory 'core.json'
    $locale | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $core
    $knowledge | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $directory 'knowledge.json')
    $tests | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $directory 'tests.json')
    $env:DEMO_PACKS_ROOT = $root
    $original = [IO.File]::ReadAllText($core)
    Run-Validation
    Assert ($script:ValidationCode -eq 0) 'distinct identity and blueprint words/suffixes pass validation'
    $oldName = ' Reports  Monitor ' + [char]0x2013 + ' Test Blueprint '
    Set-DemoJsonProperties -Path $core -Changes @{ 'agents.reportsMonitorTest.blueprint' = $oldName }
    Run-Validation
    Assert ($script:ValidationCode -eq 0 -and $script:ValidationOutput.Contains('agents.reportsMonitorTest.blueprint') -and
        $script:ValidationOutput.Contains("Current: '$oldName'") -and
        $script:ValidationOutput.Contains("canonical: 'Reports Monitor - Test Blueprint'")) 'typography warnings identify the exact field, current value and canonical value'
    Run-Validation -Fix
    $fixed = Get-Content -LiteralPath $core -Raw | ConvertFrom-Json -AsHashtable
    Assert ($script:ValidationCode -eq 0 -and $fixed.agents.reportsMonitorTest.blueprint -ceq 'Reports Monitor - Test Blueprint') '-Fix changes only punctuation and preserves the Blueprint suffix'
    Assert ($fixed.agents.reportsMonitorTest.aliases.blueprint -ccontains $oldName) '-Fix retains the prior spelling as an exact surface alias'
    Assert ($fixed.agents.recordsColleague.identity -ceq 'Records Colleague Identity' -and
        $fixed.agents.recordsAssistant.blueprint -ceq 'Records Assistant Blueprint') 'other intended identity and blueprint suffixes remain unchanged'
    Assert ($fixed.agents.applicationReview.names.registry -ceq 'Application-Review') 'an explicit technical provider name is not changed to display-name punctuation'
    $hash = (Get-FileHash -LiteralPath $core).Hash
    Run-Validation -Fix
    Assert ((Get-FileHash -LiteralPath $core).Hash -eq $hash) '-Fix is byte-idempotent'
    [IO.File]::WriteAllText($core, $original)
    Set-DemoJsonProperties -Path $core -Changes @{ 'agents.reportsMonitor.displayName' = 'Reports Monitor - Test' }
    $hash = (Get-FileHash -LiteralPath $core).Hash
    Run-Validation -Fix
    Assert ($script:ValidationCode -ne 0 -and $script:ValidationOutput.Contains('Ambiguous punctuation-equivalent names')) 'ambiguous names fail with an explicit no-automatic-fix diagnostic'
    Assert ((Get-FileHash -LiteralPath $core).Hash -eq $hash) 'ambiguous name fixes never alter either agent'
    foreach ($field in 'liveDisplayName', 'liveAlias') {
        $fixture = $original | ConvertFrom-Json -AsHashtable
        $fixture.agents.recordsColleague.instance.Remove($field)
        $fixture | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $core
        Run-Validation
        Assert ($script:ValidationCode -ne 0 -and $script:ValidationOutput.Contains("agents.recordsColleague.instance.$field")) "every locale requires the D7 $field key"
    }
    foreach ($key in 'applyProductionTemplate', 'rejectStalePublishRequests') {
        $fixture = $original | ConvertFrom-Json -AsHashtable
        $fixture.governance.rules.Remove($key)
        $fixture | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $core
        Run-Validation
        Assert ($script:ValidationCode -ne 0 -and $script:ValidationOutput.Contains("governance.rules.$key")) "every locale requires the D8 $key name"
    }
    $surgical = Join-Path $temp 'surgical.json'
    $prefix = "{`r`n  `"unchanged`": `"a \\quoted\\ value`",`r`n  `"agents`": { `"sample`": { `"identity`": `"Old Identity`" } },`r`n  `"items`": [{`"roles`":[`"Reader`"]}],`r`n  `"last`": `"keep`"`r`n}"
    [IO.File]::WriteAllText($surgical, $prefix)
    Set-DemoJsonProperties -Path $surgical -Changes ([ordered]@{
        'agents.sample.identity' = 'New Identity'; 'agents.sample.aliases' = @{ entra = @('Old Identity') }
        'items.0.roles' = @('Reader', 'Writer')
    })
    $edited = [IO.File]::ReadAllText($surgical)
    $result = $edited | ConvertFrom-Json -AsHashtable
    Assert ($result.agents.sample.identity -ceq 'New Identity' -and $result.agents.sample.aliases.entra[0] -ceq 'Old Identity' -and
        $result.items[0].roles.Count -eq 2) 'surgical JSON editing supports scalar, new alias and array-index properties'
    Assert ($edited.StartsWith($prefix.Substring(0, $prefix.IndexOf('  "agents"'))) -and
        $edited.EndsWith("  `"last`": `"keep`"`r`n}")) 'unrelated JSON formatting, escapes and line endings stay byte-identical'
    Assert ((ConvertTo-DemoCanonicalAgentName ('User' + [char]0x2019 + 's Agent Identity')) -ceq "User's Agent Identity") 'quote normalization preserves every word and suffix'
    $locale = $original | ConvertFrom-Json -AsHashtable
    Assert-DemoLiveNames $pack $locale
    $rendered = Expand-DemoText '{{agents.recordsColleague.instance.liveDisplayName}}|{{agents.recordsColleague.instance.liveAlias}}|{{governance.rules.applyProductionTemplate}}|{{governance.rules.rejectStalePublishRequests}}' $locale @{} @{} $pack
    Assert ($rendered -ceq ('Records Colleague Galway|records.colleague.galway|Contoso ' + [char]0x2013 +
        ' Apply production-agents template|Contoso ' + [char]0x2013 + ' Reject publish requests older than 14 days')) 'D7 and D8 card placeholders use the English locale values verbatim'
    $tokens = $null; $parseErrors = $null
    $guidePath = Join-Path $PSScriptRoot '..\..\agent365-demo-guide\scripts\New-DemoGuide.ps1'
    $ast = [Management.Automation.Language.Parser]::ParseFile($guidePath, [ref]$tokens, [ref]$parseErrors)
    foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($function.Name -in 'Get-GovItems', 'Format-Code', 'Get-Who') { Invoke-Expression $function.Extent.Text }
    }
    $LOC = $locale; $gov = $locale.governance; $cfg = @{ adminUpn = 'operator@example.test'; domain = 'example.test' }
    $d7 = @(Get-GovItems D7) -join "`n"; $d8 = @(Get-GovItems D8) -join "`n"
    Assert ($d7.Contains('Records Colleague Galway') -and $d7.Contains('records.colleague.galway')) 'the real D7 guide renderer uses the configured live instance and alias'
    Assert ($d8.Contains($locale.governance.rules.applyProductionTemplate) -and
        $d8.Contains($locale.governance.rules.rejectStalePublishRequests)) 'the real D8 guide renderer uses both configured rule labels'
    $locale.agents.recordsColleague.instance.Remove('liveDisplayName')
    $message = ''
    try { Assert-DemoLiveNames $pack $locale } catch { $message = $_.Exception.Message }
    Assert ($message -match 'no configured name') 'missing live names stop rendering instead of falling back to English or a constructed city name'

    $preparedLocale = $original | ConvertFrom-Json -AsHashtable
    $preparedConfig = @{ prefix = 'prep1'; domain = 'example.test'; tenantId = 'tenant' }
    $definition = $pack.agents | Where-Object { $_.key -eq 'recordsColleague' }
    $action = Get-DemoPreparedInstanceAction $preparedConfig $preparedLocale $definition
    $actionText = @($action.Action, $action.Where, $action.NeededBy) -join ' '
    Assert ($action.Action.Contains('Records Colleague Dublin') -and $action.Where.Contains('Teams > Apps') -and
        $action.Where.Contains('luke.byrne@example.test')) 'the prepared-instance action specifies the configured maker and manual Teams creation'
    Assert ($actionText.Contains('after the AI-teammate package upload and activation') -and
        $action.Where.StartsWith('After the package upload/activation is verified') -and
        $action.NeededBy.Contains('before identities-refresh')) 'the manual action follows package activation and precedes identity refresh'
    Assert (-not $actionText.Contains('Records Colleague Galway') -and -not $actionText.Contains('records.colleague.galway')) 'the action never registers the separate on-camera D7 instance'
    $savedRepoRoot = $script:DemoRepoRoot
    $script:DemoRepoRoot = $temp
    try {
        $registered = Set-DemoUserAction -Prefix prep1 @action
        $null = Set-DemoUserAction -Prefix prep1 -Key $action.Key -Status DONE
        $again = Set-DemoUserAction -Prefix prep1 @action
        Assert ($registered.id -eq $again.id -and $again.status -eq 'DONE' -and
            (Read-DemoUserActions prep1).actions.Count -eq 1) 're-registering the prepared action preserves its id and completed status'
        $planPath = Join-Path $PSScriptRoot 'New-DemoLabPlan.ps1'
        $planAst = [Management.Automation.Language.Parser]::ParseFile($planPath, [ref]$tokens, [ref]$parseErrors)
        $registration = @($planAst.FindAll({ param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -eq '-not $ValidateOnly'
        }, $true))
        Assert ($registration.Count -eq 1) 'the production plan has one non-validation action-registration block'
        function Get-Agent365TagAction { @{ Key = 'fixture-tag'; Action = 'Fixture native tag'; Where = 'portal'; NeededBy = 'rehearsal' } }
        $Prefix = 'prep2'; $cfg = @{ prefix = $Prefix; domain = 'example.test'; tenantId = 'tenant' }
        $L = $preparedLocale; $agents = @($pack.agents); $ValidateOnly = $true
        Invoke-Expression $registration[0].Extent.Text
        Assert (-not (Test-Path -LiteralPath (Get-DemoUserActionsPath $Prefix))) 'validation-only planning never registers a prepared instance'
        $ValidateOnly = $false
        Invoke-Expression $registration[0].Extent.Text
        $actions = @((Read-DemoUserActions $Prefix).actions | Where-Object { $_.key -like 'prepared-instance-*' })
        Assert ($actions.Count -eq 1 -and $actions[0].key -eq $action.Key -and $actions[0].status -eq 'TODO') 'the production plan automatically registers exactly the prepared instance for a new lab'
        Assert (-not (@($actions.action) -join ' ').Contains('Galway')) 'automatic registration does not add a live-demo instance action'
    }
    finally {
        $script:DemoRepoRoot = $savedRepoRoot
        if (Test-Path Function:\Get-Agent365TagAction) { Remove-Item Function:\Get-Agent365TagAction }
    }

    $rolesSource = [IO.File]::ReadAllText($rolesScript).Replace(". (Join-Path `$PSScriptRoot '_demo-common.ps1')", '')
    $productionRoles = [scriptblock]::Create($rolesSource)
    $script:RoleCalls = [Collections.Generic.List[object]]::new()
    $script:HeldRoles = [Collections.Generic.HashSet[string]]::new()
    $null = $script:HeldRoles.Add('reader')
    $script:FailRoleWrite = $false
    $script:IgnoreRoleWrite = $false
    $script:RoleSaveCount = 0
    $script:RolePack = @{ personas = @(
        @{ key = 'aiAdmin'; entraRoles = @('Global Reader', 'Conditional Access Administrator', 'Attribute Assignment Administrator') },
        @{ key = 'maker'; entraRoles = @('Global Administrator') }
    ) }
    function Read-DemoConfig { @{ prefix = 'fixture'; tenantId = 'tenant'; adminUpn = 'operator@example.test' } }
    function Assert-DemoTenant { }
    function Get-DemoPack { $script:RolePack }
    function Get-DemoLocale { @{ personas = @{} } }
    function Read-DemoLabState { @{ users = @{ aiAdmin = @{ id = 'admin-user' }; maker = @{ id = 'maker-user' } } } }
    function Save-DemoLabState { $script:RoleSaveCount++ }
    function Write-DemoLog { }
    function Start-Sleep { }
    function Invoke-DemoGraph {
        param($Method, $Uri, $Body, $Token, [switch]$NoThrow, [switch]$All)
        $script:RoleCalls.Add([pscustomobject]@{ method = $Method; uri = $Uri; body = $Body })
        if ($Method -eq 'GET' -and $Uri -match '/users/admin-user\?') { return [pscustomobject]@{ id = 'admin-user' } }
        if ($Method -eq 'GET' -and $Uri -match '/roleDefinitions\?') {
            return @(
                [pscustomobject]@{ id = 'reader'; displayName = 'Global Reader' },
                [pscustomobject]@{ id = 'ca'; displayName = 'Conditional Access Administrator' },
                [pscustomobject]@{ id = 'attributes'; displayName = 'Attribute Assignment Administrator' }
            )
        }
        if ($Method -eq 'GET' -and $Uri -match "/roleAssignments\?.*principalId eq 'admin-user'.*roleDefinitionId eq '([^']+)'") {
            $id = $Matches[1]
            return [pscustomobject]@{ value = @(
                if ($script:HeldRoles.Contains($id)) {
                    [pscustomobject]@{ id = "assignment-$id"; principalId = 'admin-user'; roleDefinitionId = $id; directoryScopeId = '/' }
                }
            ) }
        }
        if ($Method -eq 'POST' -and $Uri.EndsWith('/roleAssignments') -and
            $Body.principalId -eq 'admin-user' -and $Body.directoryScopeId -eq '/' -and $Body.roleDefinitionId -in 'ca', 'attributes') {
            if ($script:FailRoleWrite) { return [pscustomobject]@{ error = 'Forbidden'; status = 403 } }
            if (-not $script:IgnoreRoleWrite) { $null = $script:HeldRoles.Add([string]$Body.roleDefinitionId) }
            return [pscustomobject]@{ id = 'new-assignment' }
        }
        throw "Unexpected roles-only request: $Method $Uri"
    }
    & $productionRoles -Prefix fixture -Persona aiAdmin -RolesOnly -WhatIf
    Assert (@($script:RoleCalls | Where-Object method -ne GET).Count -eq 0 -and $script:RoleSaveCount -eq 0) 'roles-only dry run performs no tenant writes or state save'
    $script:RoleCalls.Clear()
    & $productionRoles -Prefix fixture -Persona aiAdmin -RolesOnly
    $writes = @($script:RoleCalls | Where-Object method -eq POST)
    Assert ($writes.Count -eq 2 -and $script:HeldRoles.Contains('ca') -and $script:HeldRoles.Contains('attributes')) 'only the two missing selected-persona roles are assigned and verified'
    Assert (@($script:RoleCalls | Where-Object { $_.uri -match 'maker-user|/manager|/groups|/me\?|assignLicense|operator' }).Count -eq 0) 'roles-only cannot change other personas, user properties, managers, groups, licenses or operator roles'
    $script:RoleCalls.Clear()
    & $productionRoles -Prefix fixture -Persona aiAdmin -RolesOnly
    Assert (@($script:RoleCalls | Where-Object method -ne GET).Count -eq 0) 'reapplying already-held persona roles is idempotent'
    $null = $script:HeldRoles.Remove('ca'); $script:FailRoleWrite = $true
    $message = ''
    try { & $productionRoles -Prefix fixture -Persona aiAdmin -RolesOnly } catch { $message = $_.Exception.Message }
    Assert ($message -match '403.*Forbidden') 'a denied role write fails explicitly instead of reporting success'
    $script:FailRoleWrite = $false; $script:IgnoreRoleWrite = $true
    $message = ''
    try { & $productionRoles -Prefix fixture -Persona aiAdmin -RolesOnly } catch { $message = $_.Exception.Message }
    Assert ($message -match 'not verified by read-back') 'an accepted but unobservable assignment does not count as success'
    $script:RoleCalls.Clear(); $message = ''
    try { & $productionRoles -Prefix fixture -Persona aiAdmin -RolesOnly -SkipRoles } catch { $message = $_.Exception.Message }
    Assert ($message -match 'cannot be combined' -and $script:RoleCalls.Count -eq 0) 'conflicting role switches fail before any cloud call'
    Write-Host "Passed $passed, failed 0"
}
finally {
    $env:DEMO_PACKS_ROOT = $originalPacksRoot
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
