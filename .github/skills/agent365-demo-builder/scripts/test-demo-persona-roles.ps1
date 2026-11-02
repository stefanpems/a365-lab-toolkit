#requires -Version 7.0
<#
.SYNOPSIS
  Offline regressions for persona Entra roles: template resolution, active permanent root-scope semantics,
  scoped existing-user repairs, state evidence, reporting and the People pre-flight/reset.
  Graph, tenant checks and config loading are mocked. Unexpected requests fail closed. All files are temporary.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_demo-common.ps1')
$sourcePack = Get-DemoPack
$identity = @($sourcePack.personas | Where-Object key -eq identityAdmin)[0]
$sourceRoot = $script:DemoRepoRoot
$originalPacksRoot = $env:DEMO_PACKS_ROOT
$temp = Join-Path ([IO.Path]::GetTempPath()) ('a365-persona-roles-' + [guid]::NewGuid().ToString('N'))
$passed = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
    Write-Host "PASS: $Message"
}
function Assert-Throws([scriptblock]$Operation, [string]$Pattern, [string]$Message) {
    $failure = ''
    try { & $Operation | Out-Null } catch { $failure = $_.Exception.Message }
    Assert ($failure -match $Pattern) $Message
}
function Get-FixtureScript([string]$Path) {
    $text = [IO.File]::ReadAllText($Path)
    foreach ($import in @(
        ". (Join-Path `$PSScriptRoot '_demo-common.ps1')",
        ". (Join-Path `$builder '_demo-common.ps1')",
        ". (Join-Path `$builder '_demo-entra.ps1')",
        ". (Join-Path `$PSScriptRoot '_demo-registry.ps1')"
    )) { $text = $text.Replace($import, '') }
    $directory = (Split-Path -Parent $Path).Replace("'", "''")
    $text = $text.Replace('Join-Path $PSScriptRoot ', "Join-Path '$directory' ")
    return [scriptblock]::Create($text)
}
$productionRoles = Get-FixtureScript (Join-Path $PSScriptRoot 'Set-DemoIdentities.ps1')
$productionReport = Get-FixtureScript (Join-Path $PSScriptRoot 'Get-DemoPersonas.ps1')
$productionPreflight = Get-FixtureScript (Join-Path $PSScriptRoot '..\..\agent365-demo-reset\scripts\Get-DemoState.ps1')
$productionReset = Get-FixtureScript (Join-Path $PSScriptRoot '..\..\agent365-demo-reset\scripts\Reset-DemoState.ps1')
$expectedTemplates = [ordered]@{
    'Global Secure Access Administrator' = 'ac434307-12b9-4fa1-a708-88bf58caabc1'
    'Identity Governance Administrator' = '45d8d3c5-c802-45c6-b32a-1d70b5e1e86e'
    'Lifecycle Workflows Administrator' = '59d46f88-662b-457b-bceb-5c3809e5908f'
}
$definitions = @(
    $index = 0
    foreach ($name in $identity.entraRoles) {
        $index++
        [pscustomobject]@{ id = "tenant-definition-$index"; templateId = $(if ($expectedTemplates.Contains($name)) { $expectedTemplates[$name] } else { "legacy-template-$index" })
            displayName = $(if ($expectedTemplates.Contains($name)) { "Provider display $index" } else { $name }); isBuiltIn = $true }
        if ($expectedTemplates.Contains($name)) {
            [pscustomobject]@{ id = "custom-decoy-$index"; templateId = "custom-template-$index"; displayName = $name; isBuiltIn = $false }
        }
    }
)
$script:RoleDefinitions = $definitions
$script:RoleCalls = [Collections.Generic.List[object]]::new()
$script:Active = [Collections.Generic.List[object]]::new()
$script:Instances = [Collections.Generic.List[object]]::new()
$script:DemoG = 'https://graph.microsoft.com'
$script:DemoAgentLookups = [Collections.Generic.List[object]]::new()
function Read-DemoConfig { $script:ConfigReads++; return $script:RoleConfig }
function Assert-DemoTenant { $script:TenantChecks++ }
function Get-DemoPack { $script:RolePack }
function Get-DemoLocale { $script:RoleLocale }
function Get-DemoUpn($Locale, $Config, [string]$Key) {
    if ($Key -ne 'identityAdmin') { throw 'Unexpected other-persona UPN lookup.' }
    return 'identity@example.test'
}
function Write-DemoLog { }
function Start-Sleep { }
function Add-HeldRole([string]$Name) {
    $definition = Resolve-DemoEntraRoleDefinition $Name $script:RoleDefinitions
    $script:NextAssignment++
    $id = "assignment-$script:NextAssignment"
    $script:Active.Add([pscustomobject]@{ id = $id; principalId = 'identity-user'; roleDefinitionId = $definition.id; directoryScopeId = '/'; appScopeId = $null })
    $script:Instances.Add([pscustomobject]@{ principalId = 'identity-user'; roleDefinitionId = $definition.id
        directoryScopeId = '/'; appScopeId = $null; assignmentType = 'Assigned'; memberType = 'Direct'
        roleAssignmentOriginId = $id; startDateTime = '2020-01-01T00:00:00Z'; endDateTime = $null })
}
function Invoke-DemoGraph {
    param($Method, $Uri, $Body, $Token, [switch]$NoThrow, [switch]$All, [int]$MaxRetries)
    $script:RoleCalls.Add([pscustomobject]@{ method = $Method; uri = $Uri; body = $Body; all = [bool]$All })
    if ($Method -eq 'GET' -and $Uri -match '/users/([^?]+)\?') {
        $reference = [uri]::UnescapeDataString($Matches[1])
        if ($reference -notin 'identity-user', 'identity@example.test') { throw "Unexpected other-user read: $reference" }
        if (-not $script:UserExists) { return [pscustomobject]@{ error = 'NotFound'; status = 404 } }
        return [pscustomobject]@{ id = 'identity-user'; jobTitle = 'Identity Administrator'; accountEnabled = $true
            assignedLicenses = @(@{ skuId = 'sku1' }, @{ skuId = 'sku2' }, @{ skuId = 'sku3' }) }
    }
    if ($Method -eq 'GET' -and $Uri -match '/roleDefinitions\?') { return $script:RoleDefinitions }
    if ($Method -eq 'GET' -and $Uri -match "/roleAssignments\?.*principalId eq 'identity-user'") { return $script:Active.ToArray() }
    if ($Method -eq 'GET' -and $Uri -match "/roleAssignmentScheduleInstances\?.*principalId eq 'identity-user'") {
        if ($script:DenyScheduleRead) { throw 'Forbidden schedule-instance read (403)' }
        return $script:Instances.ToArray()
    }
    if ($Method -eq 'GET' -and $Uri.EndsWith('/subscribedSkus')) { return @() }
    if ($Method -eq 'POST' -and $Uri.EndsWith('/roleAssignments')) {
        if ($Body.principalId -ne 'identity-user' -or $Body.directoryScopeId -ne '/' -or $Body.Count -ne 3) { throw 'Unexpected assignment body or scope.' }
        $definition = @($script:RoleDefinitions | Where-Object id -eq $Body.roleDefinitionId)[0]
        if (-not $definition -or $definition.isBuiltIn -ne $true) { throw 'Unexpected role definition.' }
        if ($script:FailWrite -or $Body.roleDefinitionId -eq $script:FailDefinition) { return [pscustomobject]@{ error = 'Forbidden'; status = 403 } }
        if (-not $script:IgnoreWrite -and (-not $script:Conflict -or $script:ConcurrentAssignment)) {
            Add-HeldRole (Get-DemoEntraRoleName $definition)
            if ($script:TemporaryWrite) { $script:Instances[-1].endDateTime = '2099-01-01T00:00:00Z' }
        }
        if ($script:Conflict) { return [pscustomobject]@{ error = 'Conflict'; status = 409 } }
        return [pscustomobject]@{ id = 'accepted' }
    }
    throw "Unexpected request in offline role test: $Method $Uri"
}
function New-Case {
    $script:RoleCalls.Clear(); $script:Active.Clear(); $script:Instances.Clear()
    $script:NextAssignment = 0; $script:ConfigReads = 0; $script:TenantChecks = 0
    $script:UserExists = $true; $script:FailWrite = $false; $script:IgnoreWrite = $false; $script:TemporaryWrite = $false
    $script:Conflict = $false; $script:ConcurrentAssignment = $false; $script:DenyScheduleRead = $false
    $script:FailDefinition = ''
    $script:RoleDefinitions = $definitions
    $script:RoleConfig = @{ prefix = 'fixture'; pack = 'agent-governance'; locale = 'en'; domain = 'example.test'
        adminUpn = 'operator@example.test'; licenseSkus = @{}; copilotStudio = @{ paygEnvironmentId = 'environment' } }
    $script:RolePack = @{ personas = @($identity, @{ key = 'unselected'; entraRoles = @('Global Administrator') })
        groups = @(@{ key = 'untouched' }); agents = @(); demos = @(); operatorSlots = @(); mcp = @{} }
    $script:RoleLocale = @{ personas = @{ identityAdmin = @{ givenName = 'Identity'; surname = 'Administrator'; jobTitle = 'Identity Administrator' } }; governance = @{} }
    $state = [ordered]@{ prefix = 'fixture'; agentResolution = @{ version = 1; legacyAliases = $false }
        users = [ordered]@{ identityAdmin = [ordered]@{ id = 'identity-user'; upn = 'identity@example.test'; photo = 'preserved' }
            unselected = @{ id = 'unselected-user'; marker = 'preserved' } }
        groups = @{ untouched = @{ marker = 'preserved' } }; governance = @{ marker = 'preserved' }; phases = @{ marker = 'preserved' }
        agents = @{}; mcp = @{ pool = @() }; knowledge = @{} }
    Save-DemoLabState fixture $state
}
function Invoke-Repair([switch]$WhatIf) {
    & $productionRoles -Prefix fixture -Persona identityAdmin -RolesOnly -WhatIf:$WhatIf 6>&1 | Out-String
}
function Seed-LegacyRoles {
    foreach ($name in $identity.entraRoles) {
        if ($name -notin 'Global Secure Access Administrator', 'Lifecycle Workflows Administrator') { Add-HeldRole $name }
    }
}
try {
    $script:DemoRepoRoot = $temp
    foreach ($name in $expectedTemplates.Keys) {
        Assert ($script:DemoEntraRoleTemplateIds[$name] -ceq $expectedTemplates[$name]) "the exact built-in template ID is used for $name"
        Assert (@($identity.entraRoles | Where-Object { $_ -ceq $name }).Count -eq 1) "the pack declares $name exactly once"
        $resolved = Resolve-DemoEntraRoleDefinition $name $definitions
        Assert ($resolved.id -like 'tenant-definition-*' -and $resolved.displayName -ne $name) "template resolution ignores same-name custom decoys and provider display names for $name"
    }
    Assert ($identity.entraRoles.Count -eq 8) 'the six existing roles are preserved and only the two missing names are added'
    foreach ($name in 'Conditional Access Administrator', 'Attribute Definition Administrator', 'Attribute Assignment Administrator', 'Security Operator', 'Reports Reader') {
        Assert ($identity.entraRoles -ccontains $name) "existing role preserved: $name"
    }

    New-Case
    Seed-LegacyRoles
    $statePath = Join-Path (Get-DemoLabDir fixture) 'state.json'
    $before = [IO.File]::ReadAllText($statePath)
    $dryRun = Invoke-Repair -WhatIf
    Assert (@($script:RoleCalls | Where-Object method -ne GET).Count -eq 0 -and [IO.File]::ReadAllText($statePath) -ceq $before) 'dry-run has no tenant writes or state changes'
    Assert ($dryRun.Contains('would ASSIGN identityAdmin = Global Secure Access Administrator') -and $dryRun.Contains('would ASSIGN identityAdmin = Lifecycle Workflows Administrator')) 'dry-run identifies only the two missing role assignments'
    $script:RoleCalls.Clear()
    $applied = Invoke-Repair
    $writes = @($script:RoleCalls | Where-Object method -eq POST)
    Assert ($writes.Count -eq 2) 'repair adds only the two missing roles, not the existing Identity Governance Administrator assignment'
    foreach ($write in $writes) {
        Assert ($write.body.principalId -ceq 'identity-user' -and $write.body.directoryScopeId -ceq '/' -and $write.body.roleDefinitionId -like 'tenant-definition-*') 'writes use the selected principal, resolved definition ID and directory root'
    }
    $saved = Read-DemoLabState fixture
    Assert ($saved.users.identityAdmin.roleAssignments.Count -eq 8) 'all eight verified role assignments are persisted in state.json'
    foreach ($name in $identity.entraRoles) {
        $evidence = $saved.users.identityAdmin.roleAssignments[$name]
        $definition = Resolve-DemoEntraRoleDefinition $name $definitions
        Assert ($evidence.assignmentId -like 'assignment-*' -and $evidence.principalId -ceq 'identity-user' -and
            $evidence.roleDefinitionId -ceq $definition.id -and $evidence.roleTemplateId -ceq $definition.templateId -and
            $evidence.directoryScopeId -ceq '/' -and $evidence.assignmentType -ceq 'Assigned' -and $evidence.memberType -ceq 'Direct' -and
            $null -eq $evidence.endDateTime -and $evidence.verifiedAt) "state contains read-back assignment evidence and exact permanent root semantics for $name"
    }
    Assert ($saved.users.identityAdmin.photo -ceq 'preserved' -and $saved.users.unselected.marker -ceq 'preserved' -and
        $saved.groups.untouched.marker -ceq 'preserved' -and $saved.governance.marker -ceq 'preserved' -and $saved.phases.marker -ceq 'preserved') 'state repair preserves user metadata, other personas, groups, governance and phase state'
    Assert (@($script:RoleCalls | Where-Object { $_.uri -match 'unselected|/groups|/manager|assignLicense|/me\?|operator' }).Count -eq 0) 'repair never reads or changes other personas, groups, managers, licenses or the operator'
    Assert (@($script:RoleCalls | Where-Object { $_.method -eq 'GET' -and $_.uri -match '/role(Definitions|Assignments|AssignmentScheduleInstances)\?' -and -not $_.all }).Count -eq 0) 'definition, active-assignment and schedule-instance collections request every page'
    Assert ($applied.Contains('Sign out and back in')) 'successful repair ends with the sign-out/sign-in reminder'
    $priorIds = @($saved.users.identityAdmin.roleAssignments.Values | ForEach-Object assignmentId) -join ','
    $script:RoleCalls.Clear(); $null = Invoke-Repair
    $again = Read-DemoLabState fixture
    Assert (@($script:RoleCalls | Where-Object method -ne GET).Count -eq 0 -and
        (@($again.users.identityAdmin.roleAssignments.Values | ForEach-Object assignmentId) -join ',') -ceq $priorIds) 'reruns neither duplicate assignments nor change recorded assignment IDs'

    $script:RoleCalls.Clear()
    $report = (& $productionReport -Prefix fixture -Persona identityAdmin -AsJson | ConvertFrom-Json)
    Assert (@($report).Count -eq 1 -and $report.persona -ceq 'identityAdmin' -and $report.entraRoles -notmatch 'MISSING') 'scoped persona read-back reports exactly the verified existing identity administrator'
    foreach ($name in $expectedTemplates.Keys) { Assert ($report.entraRoles.Contains($name)) "read-back reports the canonical built-in name for $name" }
    Assert (@($script:RoleCalls | Where-Object { $_.method -ne 'GET' -or $_.uri -match 'unselected|operator|/groups|assignLicense' }).Count -eq 0) 'scoped read-back cannot touch another persona or tenant object'

    foreach ($selection in @(@(), @('all'), @('identityAdmin', 'unselected'), @('identityAdmin,all'))) {
        New-Case
        Assert-Throws { & $productionRoles -Prefix fixture -RolesOnly -Persona $selection } 'exactly one explicit' 'broad or empty roles-only selections fail closed'
        Assert ($script:RoleCalls.Count -eq 0 -and $script:ConfigReads -eq 0 -and $script:TenantChecks -eq 0) 'invalid scope fails before config, tenant or Graph access'
    }
    New-Case
    Assert-Throws { & $productionRoles -Prefix fixture -RolesOnly } 'exactly one explicit' 'omitted roles-only persona never defaults to a broad build'
    Assert-Throws { & $productionRoles -Prefix fixture -RolesOnly -Persona identityAdmin -SkipRoles } 'cannot be combined' 'conflicting switches are rejected before any cloud access'
    Assert-Throws { & $productionRoles -Prefix fixture -RolesOnly -Persona unknown } 'Unknown persona' 'unknown persona is not replaced by a default selection'
    Assert ($script:RoleCalls.Count -eq 0 -and $script:TenantChecks -eq 0) 'invalid repair requests make no Graph calls or tenant checks'
    $script:UserExists = $false
    Assert-Throws { Invoke-Repair } 'requires an existing persona user' 'a missing persona fails without creating a replacement user'
    Assert (@($script:RoleCalls | Where-Object method -ne GET).Count -eq 0) 'missing-user repair cannot create users, groups or assignments'

    New-Case
    $definition = Resolve-DemoEntraRoleDefinition 'Global Secure Access Administrator' $definitions
    $script:RoleDefinitions = @($definitions | Where-Object id -ne $definition.id)
    Assert-Throws { Invoke-Repair } 'Global Secure Access Administrator.*0 exact definitions' 'a same-name custom role cannot replace a missing built-in template'
    $script:RoleDefinitions = @($definitions) + @($definition)
    Assert-Throws { Invoke-Repair } 'Global Secure Access Administrator.*2 exact definitions' 'ambiguous built-in template resolution fails instead of selecting the first match'
    New-Case
    $stateWithoutUser = Read-DemoLabState fixture
    $stateWithoutUser.users.Remove('identityAdmin')
    Save-DemoLabState fixture $stateWithoutUser
    $null = Invoke-Repair
    Assert ((Read-DemoLabState fixture).users.identityAdmin.id -ceq 'identity-user') 'an existing persona can be resolved by its exact UPN when its state record is absent'
    Assert (@($script:RoleCalls | Where-Object { $_.method -ne 'GET' -and -not $_.uri.EndsWith('/roleAssignments') }).Count -eq 0) 'missing state never triggers user, group or license creation'

    # Check every part of the equivalence predicate independently, not merely role-name presence.
    $probe = 'Global Secure Access Administrator'
    foreach ($kind in 'valid', 'time-bound', 'activated', 'group', 'future', 'scoped', 'app-scoped', 'wrong-principal', 'wrong-definition', 'wrong-origin', 'missing-end', 'invalid-start', 'eligibility-only', 'no-schedule', 'active-scoped', 'active-app-scoped', 'active-wrong-principal') {
        New-Case
        Add-HeldRole $probe
        switch ($kind) {
            'time-bound' { $script:Instances[0].endDateTime = '2099-01-01T00:00:00Z' }
            'activated' { $script:Instances[0].assignmentType = 'Activated' }
            'group' { $script:Instances[0].memberType = 'Group' }
            'future' { $script:Instances[0].startDateTime = '2099-01-01T00:00:00Z' }
            'scoped' { $script:Instances[0].directoryScopeId = '/administrativeUnits/unit' }
            'app-scoped' { $script:Instances[0].appScopeId = '/applications/app' }
            'wrong-principal' { $script:Instances[0].principalId = 'unselected-user' }
            'wrong-definition' { $script:Instances[0].roleDefinitionId = 'custom-decoy' }
            'wrong-origin' { $script:Instances[0].roleAssignmentOriginId = 'other-assignment' }
            'missing-end' { $script:Instances[0].PSObject.Properties.Remove('endDateTime') }
            'invalid-start' { $script:Instances[0].startDateTime = 'unknown' }
            'eligibility-only' { $script:Active.Clear() }
            'no-schedule' { $script:Instances.Clear() }
            'active-scoped' { $script:Active[0].directoryScopeId = '/administrativeUnits/unit' }
            'active-app-scoped' { $script:Active[0].appScopeId = '/applications/app' }
            'active-wrong-principal' { $script:Active[0].principalId = 'unselected-user' }
        }
        $held = @(Get-DemoPermanentEntraRoleAssignments 'identity-user')
        Assert ($held.Count -eq $(if ($kind -eq 'valid') { 1 } else { 0 })) "assignment equivalence checks $kind evidence correctly"
    }

    New-Case
    Add-HeldRole $probe
    $script:Instances[0].endDateTime = '2099-01-01T00:00:00Z'
    $null = Invoke-Repair
    Assert (@($script:RoleCalls | Where-Object { $_.method -eq 'POST' -and $_.body.roleDefinitionId -eq (Resolve-DemoEntraRoleDefinition $probe $definitions).id }).Count -eq 1) 'an active time-bound assignment does not suppress the missing permanent root assignment'
    New-Case
    $script:FailWrite = $true
    Assert-Throws { Invoke-Repair } '403.*Forbidden' 'a forbidden assignment fails explicitly'
    Assert (-not (Read-DemoLabState fixture).users.identityAdmin.roleAssignments) 'a denied assignment is never persisted as verified'
    foreach ($mode in 'unobservable', 'temporary') {
        New-Case
        $script:IgnoreWrite = $mode -eq 'unobservable'; $script:TemporaryWrite = $mode -eq 'temporary'
        Assert-Throws { Invoke-Repair } 'not verified by read-back' "accepted but $mode assignment is not reported as permanent success"
        Assert (-not (Read-DemoLabState fixture).users.identityAdmin.roleAssignments) 'state never records unverified role evidence'
    }
    New-Case
    $script:DenyScheduleRead = $true
    Assert-Throws { Invoke-Repair } 'Forbidden schedule-instance read' 'unavailable schedule evidence never falls back to assuming permanence'
    Assert (@($script:RoleCalls | Where-Object method -ne GET).Count -eq 0) 'a failed permanence read prevents writes'
    New-Case
    Seed-LegacyRoles
    $script:FailDefinition = (Resolve-DemoEntraRoleDefinition 'Lifecycle Workflows Administrator' $definitions).id
    Assert-Throws { Invoke-Repair } 'Lifecycle Workflows Administrator.*403' 'a later role failure is reported without broad retries'
    $partial = Read-DemoLabState fixture
    Assert ($partial.users.identityAdmin.roleAssignments.Contains('Global Secure Access Administrator') -and
        -not $partial.users.identityAdmin.roleAssignments.Contains('Lifecycle Workflows Administrator')) 'verified earlier assignments survive a later failure, without recording failed roles as verified'
    New-Case
    $script:Conflict = $true; $script:ConcurrentAssignment = $true
    $null = Invoke-Repair
    Assert ((Read-DemoLabState fixture).users.identityAdmin.roleAssignments.Count -eq 8) 'concurrent equivalent assignments are verified after a conflict without duplicate errors'
    New-Case
    $script:Conflict = $true
    Assert-Throws { Invoke-Repair } '409.*no equivalent active permanent' 'a conflict without equivalent permanent read-back is not silently accepted'

    New-Case
    $script:RolePack.personas = @($identity)
    foreach ($name in $identity.entraRoles) { if (-not $expectedTemplates.Contains($name)) { Add-HeldRole $name } }
    $checks = @(& $productionPreflight -Prefix fixture -Demo People -AsObject)
    foreach ($name in $expectedTemplates.Keys) {
        $missing = @($checks | Where-Object { $_.Status -eq 'KO' -and $_.Item -ceq "identity@example.test: Entra role $name" })
        Assert ($missing.Count -eq 1 -and $missing[0].Actual -match 'MISSING' -and $missing[0].Fix.Contains('-Persona identityAdmin -RolesOnly')) "People pre-flight names $name in its own KO and scoped fix"
    }
    $missingReport = (& $productionReport -Prefix fixture -Persona identityAdmin -AsJson | ConvertFrom-Json)
    foreach ($name in $expectedTemplates.Keys) { Assert ($missingReport.entraRoles -match "MISSING:.*$([regex]::Escape($name))") "persona read-back flags missing $name" }
    $script:RoleCalls.Clear()
    $null = & $productionReset -Prefix fixture -Demo People 6>&1 | Out-String
    Assert (@($script:RoleCalls | Where-Object method -ne GET).Count -eq 0) 'People reset dry-run does not assign roles'
    $script:RoleCalls.Clear()
    $null = & $productionReset -Prefix fixture -Demo People -Apply 6>&1 | Out-String
    Assert (@($script:RoleCalls | Where-Object method -eq POST).Count -eq 3) 'People reset assigns exactly the three missing pack roles through the shared helper'
    Assert ((Read-DemoLabState fixture).users.identityAdmin.roleAssignments.Count -eq 8) 'People reset saves the same verified role evidence as the identity build'
    $afterChecks = @(& $productionPreflight -Prefix fixture -Demo People -AsObject)
    Assert (@($afterChecks | Where-Object { $_.Item -like '*Entra role*' -and $_.Status -eq 'KO' }).Count -eq 0) 'People pre-flight passes all role checks after the mocked reset'
    $script:RoleCalls.Clear()
    $null = & $productionReset -Prefix fixture -Demo People -Apply 6>&1 | Out-String
    Assert (@($script:RoleCalls | Where-Object method -ne GET).Count -eq 0) 'People reset is idempotent and never changes other object types'
    $script:UserExists = $false; $script:RoleCalls.Clear()
    $missingUserChecks = @(& $productionPreflight -Prefix fixture -Demo People -AsObject)
    foreach ($name in $expectedTemplates.Keys) {
        Assert (@($missingUserChecks | Where-Object { $_.Status -eq 'KO' -and $_.Item -ceq "identity@example.test: Entra role $name" }).Count -eq 1) "People pre-flight still names $name when the persona user is missing"
    }
    $null = & $productionReset -Prefix fixture -Demo People -Apply 6>&1 | Out-String
    Assert (@($script:RoleCalls | Where-Object method -ne GET).Count -eq 0) 'People reset never recreates a missing persona or its other objects'

    # Exercise the production offline validator on a copied pack, never edit source locales.
    $packs = Join-Path $temp 'packs'
    $packDir = Join-Path $packs 'agent-governance'
    New-Item -ItemType Directory -Force -Path (Join-Path $packDir 'locales') | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'demo-packs\agent-governance\locales\en') -Destination (Join-Path $packDir 'locales') -Recurse
    $env:DEMO_PACKS_ROOT = $packs
    foreach ($missingRole in $expectedTemplates.Keys) {
        $copy = $sourcePack | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
        $person = @($copy.personas | Where-Object key -eq identityAdmin)[0]
        $person.entraRoles = @($person.entraRoles | Where-Object { $_ -cne $missingRole })
        $copy | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $packDir 'pack.json') -Encoding utf8
        $validation = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Test-DemoPack.ps1') -Pack agent-governance -Locale en 2>&1 | Out-String
        Assert ($LASTEXITCODE -ne 0 -and $validation.Contains("missing required built-in role '$missingRole'")) "offline validator rejects missing $missingRole"
    }
    $copy = $sourcePack | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    $person = @($copy.personas | Where-Object key -eq identityAdmin)[0]
    $person.entraRoles += 'Identity Governance Administrator'
    $copy | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $packDir 'pack.json') -Encoding utf8
    $validation = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Test-DemoPack.ps1') -Pack agent-governance -Locale en 2>&1 | Out-String
    Assert ($LASTEXITCODE -ne 0 -and $validation.Contains("duplicate directory role 'Identity Governance Administrator'")) 'offline validator rejects duplicate Identity Governance Administrator entries'
    $person.entraRoles = @($identity.entraRoles | ForEach-Object { if ($_ -ceq 'Global Secure Access Administrator') { $_.ToLowerInvariant() } else { $_ } })
    $copy | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $packDir 'pack.json') -Encoding utf8
    $validation = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Test-DemoPack.ps1') -Pack agent-governance -Locale en 2>&1 | Out-String
    Assert ($LASTEXITCODE -ne 0 -and $validation.Contains('must use its canonical English name')) 'offline validator enforces canonical English built-in role names'
    Write-Host "Passed $passed, failed 0"
}
finally {
    $script:DemoRepoRoot = $sourceRoot
    $env:DEMO_PACKS_ROOT = $originalPacksRoot
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
