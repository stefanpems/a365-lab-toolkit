#requires -Version 7.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_demo-common.ps1')
. (Join-Path $PSScriptRoot '_demo-entra.ps1')
$repoRoot = $script:DemoRepoRoot
$passed = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
    Write-Host "PASS: $Message"
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $caught = ''
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert ($caught -match $Pattern) $Message
}
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("a365-agent-resolution-" + [guid]::NewGuid().ToString('N'))
$script:DemoRepoRoot = $tempRoot
$savedAuthDir = $env:DEMO_SESSION_AUTH_DIR
$savedAzDir = $env:AZURE_CONFIG_DIR
$savedExtensionDir = $env:AZURE_EXTENSION_DIR
$cfg = @{ prefix = 'fixture'; tenantId = 'tenant'; copilotStudio = @{ paygEnvironmentId = 'environment' } }
$locale = @{ agents = @{ sample = @{
    codeName = 'Sample-Agent'; displayName = 'Sample Agent'; identity = 'Sample Agent'; blueprint = 'Sample Agent'
    instance = @{ displayName = 'Sample Instance' }
    names = @{ entra = 'Configured Entra Name' }
    aliases = @{ registry = @('Old Agent'); entra = @('Old Identity', 'Older Identity'); copilotStudio = @('Old Bot') }
} } }
$script:ById = @{}
$script:ByName = @{}
$script:NameReads = 0
$script:GraphReads = [Collections.Generic.List[string]]::new()
$script:GraphResponses = @{}
function Get-DemoAzToken { 'offline-token' }
function Invoke-DemoGraph {
    param($Method, $Uri, $Body, $Token, [switch]$All, [switch]$NoThrow)
    if ($Method -ne 'GET') { throw 'An offline resolver attempted a tenant write.' }
    $script:GraphReads.Add($Uri)
    if (-not $script:GraphResponses.ContainsKey($Uri)) { throw "Unexpected offline request: $Uri" }
    $response = $script:GraphResponses[$Uri]
    if ($All -and $response -and $response.PSObject.Properties['value']) { return $response.value }
    return $response
}
$read = { param($id) $script:ById[$id] }
$find = { param($name) $script:NameReads++; @($script:ByName[$name] | Where-Object { $_ }) }
function Resolve-Fixture($State) {
    Resolve-DemoAgentObject -Config $cfg -Locale $locale -State $State -Key sample -IdField identityId -Surface entra -ReadById $read -FindByName $find
}
try {
    $state = Read-DemoLabState fixture
    Assert (-not $state.agentResolution.legacyAliases) 'new labs never opt in to compatibility aliases'
    Assert ((Get-DemoAgentName -Locale $locale -Key sample -Surface entra) -ceq 'Configured Entra Name') 'surface names are explicit configuration, not conventions'
    Assert ((Get-DemoAgentName -Locale $locale -Key sample -Surface webui) -ceq 'Sample Agent') 'the web UI uses the same configured display name'
    Assert-Throws { Get-DemoAgentName -Locale $locale -Key absent } 'not configured' 'unknown agent keys fail explicitly'
    $object = [pscustomobject]@{ id = 'identity-1'; displayName = 'Configured Entra Name' }
    $script:ByName['Configured Entra Name'] = @($object)
    $result = Resolve-Fixture $state
    $saved = Read-DemoLabState fixture
    Assert ($result.id -eq 'identity-1' -and $saved.agents.sample.identityId -eq 'identity-1') 'a first exact-name verification persists its id immediately'
    Assert ($script:DemoAgentLookups[-1].method -eq 'name') 'fallback use is reported explicitly'
    $script:ById['identity-1'] = [pscustomobject]@{ id = 'identity-1'; displayName = 'Renamed in tenant' }
    $script:ByName.Clear(); $script:NameReads = 0
    $result = Resolve-Fixture $saved
    Assert ($result.id -eq 'identity-1' -and $script:NameReads -eq 0) 'persisted ids remain authoritative after an object is renamed'
    $script:ById.Clear()
    $script:ByName['Configured Entra Name'] = @([pscustomobject]@{ id = 'identity-2'; displayName = 'Configured Entra Name' })
    $result = Resolve-Fixture $saved
    Assert ((Read-DemoLabState fixture).agents.sample.identityId -eq 'identity-2') 'a stale id is repaired only by a successful exact configured-name fallback'
    $saved.agents.sample.Remove('identityId')
    $script:ByName['Configured Entra Name'] = @([pscustomobject]@{ id = 'wrong'; displayName = 'Configured Entra Name Extra' })
    Assert ($null -eq (Resolve-Fixture $saved)) 'a prefix or substring match is rejected even when an API returns it'
    $script:ByName['Configured Entra Name'] = @($object, $object)
    Assert-Throws { Resolve-Fixture $saved } 'ambiguous' 'duplicate exact names fail rather than choosing the first object'
    $script:ByName.Clear()
    $script:ByName['Old Identity'] = @([pscustomobject]@{ id = 'legacy'; displayName = 'Old Identity' })
    Assert ($null -eq (Resolve-Fixture $saved)) 'fresh labs do not resolve legacy names'
    $saved.agentResolution.legacyAliases = $true
    $result = Resolve-Fixture $saved
    Assert ($result.id -eq 'legacy' -and (Read-DemoLabState fixture).agents.sample.identityId -eq 'legacy') 'an existing lab resolves an explicit alias and persists its id'
    $saved.agents.sample.Remove('identityId')
    $script:ByName['Older Identity'] = @([pscustomobject]@{ id = 'other-legacy'; displayName = 'Older Identity' })
    Assert-Throws { Resolve-Fixture $saved } 'different objects' 'conflicting compatibility aliases fail deterministically'
    $saved.agents.sample.identityId = 'denied'
    Assert-Throws {
        Resolve-DemoAgentObject -Config $cfg -Locale $locale -State $saved -Key sample -IdField identityId -Surface entra -ReadById { throw 'HTTP 403' } -FindByName $find
    } 'HTTP 403' 'authorization errors never become name fallbacks or missing-object successes'
    Assert-Throws {
        Resolve-DemoAgentObject -Config $cfg -Locale $locale -State $saved -Key sample -IdField identityId -Surface entra -ReadById { [pscustomobject]@{ displayName = 'No identifier' } } -FindByName $find
    } "without 'id'" 'invalid API responses never become successful name fallbacks'

    $state = Read-DemoLabState 'imported'
    $generatedDir = Join-Path $tempRoot 'generated\fixture\Sample-Agent'
    New-Item -ItemType Directory -Force -Path $generatedDir | Out-Null
    @{ agentBlueprintId = 'blueprint-app'; agentBlueprintObjectId = 'blueprint-object'; agenticAppId = 'identity-app'
        agentRegistrationId = 'registration'; ignoredCredential = 'not-an-identifier' } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $generatedDir 'a365.generated.config.json')
    $state.governance.identities = @{ sample = @(@{ identityId = 'legacy-identity' }, @{ identityId = 'project-identity' }) }
    $definition = @{ key = 'sample'; platform = 'code'; variant = 'FD-OBO' }
    Initialize-DemoAgentState $cfg $locale $state $definition
    $saved = Read-DemoLabState fixture
    Assert ($saved.agents.sample.blueprintId -eq 'blueprint-object' -and $saved.agents.sample.blueprintAppId -eq 'blueprint-app') 'blueprint object and application ids are imported separately'
    Assert ($saved.agents.sample.identityId -eq 'legacy-identity' -and $saved.agents.sample.projectIdentityId -eq 'project-identity') 'existing governance evidence migrates identity and project ids without names'
    Assert ($saved.agents.sample.registrationId -eq 'registration' -and -not ($saved | ConvertTo-Json -Depth 20).Contains('ignoredCredential')) 'only public deployment identifiers reach state.json'
    Assert (-not $saved.agentResolution.legacyAliases) 'creating deployment files never enables aliases in a versioned fresh lab'
    $legacyDirectory = Join-Path $tempRoot 'generated\legacy-fixture'
    New-Item -ItemType Directory -Force -Path (Join-Path $legacyDirectory 'Sample-Agent'), (Join-Path $legacyDirectory 'demo') | Out-Null
    '{}' | Set-Content -LiteralPath (Join-Path $legacyDirectory 'Sample-Agent\a365.generated.config.json')
    @{ prefix = 'legacy-fixture'; agents = @{}; governance = @{} } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $legacyDirectory 'demo\state.json')
    Assert ((Read-DemoLabState 'legacy-fixture').agentResolution.legacyAliases) 'pre-existing generated deployments identify an already-built legacy lab even before its first pre-flight'

    $state = Read-DemoLabState 'bot-fixture'
    $botConfig = @{ prefix = 'bot-fixture'; tenantId = 'tenant'; copilotStudio = @{ paygEnvironmentId = 'environment' } }
    $definition = @{ key = 'sample'; platform = 'copilotStudio' }
    $script:DemoOrgUrls['tenant/environment'] = 'https://example.crm.dynamics.com'
    $columns = 'botid,name,publishedon,modifiedon,synchronizationstatus'
    $filter = [uri]::EscapeDataString("name eq 'Sample Agent'")
    $listUri = "https://example.crm.dynamics.com/api/data/v9.2/bots?`$select=$columns&`$filter=$filter"
    $botUri = "https://example.crm.dynamics.com/api/data/v9.2/bots(bot-1)?`$select=$columns"
    $bot = [pscustomobject]@{ botid = 'bot-1'; name = 'Sample Agent'; publishedon = '2026-01-01T00:00:00Z' }
    $script:GraphResponses[$listUri] = [pscustomobject]@{ value = @($bot) }
    $script:GraphResponses[$botUri] = $bot
    $null = Resolve-DemoCopilotStudioBot $botConfig $locale $state $definition
    Assert ((Read-DemoLabState 'bot-fixture').agents.sample.botId -eq 'bot-1') 'Copilot Studio first verification stores the bot id and environment'
    $script:GraphReads.Clear()
    $null = Resolve-DemoCopilotStudioBot $botConfig $locale $state $definition
    Assert ($script:GraphReads.Count -eq 1 -and $script:GraphReads[0] -eq $botUri) 'publication polling reads the bot by id, not name'
    $state.agents.sample.environmentId = 'different-environment'
    Assert-Throws { Resolve-DemoCopilotStudioBot $botConfig $locale $state $definition } 'Reconcile' 'a bot id cannot silently move to another environment'

    $identityConfig = @{ prefix = 'identity-fixture'; tenantId = 'tenant' }
    $state = Read-DemoLabState 'identity-fixture'
    $state.agents.sample = @{ identityId = 'identity-directory'; identityAppId = 'old-client'
        blueprintId = 'blueprint-directory'; blueprintAppId = 'blueprint-client' }
    $definition = @{ key = 'sample'; platform = 'code'; variant = 'ACA-OBO' }
    $identityUri = 'https://graph.microsoft.com/beta/servicePrincipals/identity-directory?$select=id,appId,displayName,accountEnabled'
    $script:GraphResponses[$identityUri] = [pscustomobject]@{ id = 'identity-directory'; appId = 'identity-client'; displayName = 'Renamed identity' }
    $script:GraphReads.Clear()
    $result = Resolve-DemoAgentIdentity $identityConfig $locale $state $definition
    Assert ($result.id -eq 'identity-directory' -and $script:GraphReads.Count -eq 1 -and $script:GraphReads[0] -eq $identityUri) 'Entra identity reads use the recorded directory id without enumerating names'
    Assert ((Read-DemoLabState 'identity-fixture').agents.sample.identityAppId -eq 'identity-client') 'identity directory and application ids remain separate'
    $blueprintUri = 'https://graph.microsoft.com/beta/applications/blueprint-directory?$select=id,appId,displayName'
    $script:GraphResponses[$blueprintUri] = [pscustomobject]@{ id = 'blueprint-directory'; appId = 'blueprint-client'; displayName = 'Renamed blueprint' }
    $script:GraphReads.Clear()
    $result = Resolve-DemoAgentBlueprint $identityConfig $locale $state $definition
    Assert ($result.id -eq 'blueprint-directory' -and $script:GraphReads.Count -eq 1) 'blueprint verification uses the recorded object id after a rename'

    $foundryConfig = @{ prefix = 'foundry-fixture'; tenantId = 'tenant'; subscriptionId = 'subscription'
        foundry = @{ endpoint = 'https://account.services.ai.azure.com/api/projects/project'; account = 'account'; existingResourceGroup = 'foundry-rg' } }
    $state = Read-DemoLabState 'foundry-fixture'
    $definition = @{ key = 'sample'; platform = 'code'; variant = 'FD-OBO'; entraOwner = 'admin' }
    $resourceUri = 'https://account.services.ai.azure.com/api/projects/project/agents/Sample-Agent?api-version=v1'
    $resourceByIdUri = 'https://account.services.ai.azure.com/api/projects/project/agents/provider-agent?api-version=v1'
    $resource = [pscustomobject]@{ id = 'provider-agent'; instance_identity = [pscustomobject]@{ principal_id = 'foundry-identity' }
        blueprint = [pscustomobject]@{ client_id = 'foundry-blueprint-client'; principal_id = 'foundry-blueprint-principal' } }
    $script:GraphResponses[$resourceUri] = $resource
    $script:GraphResponses['https://graph.microsoft.com/beta/servicePrincipals/foundry-identity?$select=id,appId,displayName,accountEnabled'] =
        [pscustomobject]@{ id = 'foundry-identity'; appId = 'foundry-identity'; displayName = 'Provider generated identity' }
    $script:GraphResponses['https://graph.microsoft.com/beta/applications/foundry-blueprint-client?$select=id,appId,displayName'] =
        [pscustomobject]@{ status = 404; error = 'Not found by object id' }
    $script:GraphResponses["https://graph.microsoft.com/beta/applications(appId='foundry-blueprint-client')?`$select=id,appId,displayName"] =
        [pscustomobject]@{ id = 'foundry-blueprint-object'; appId = 'foundry-blueprint-client'; displayName = 'Provider generated blueprint' }
    $projectUri = 'https://management.azure.com/subscriptions/subscription/resourceGroups/foundry-rg/providers/Microsoft.CognitiveServices/accounts/account/projects/project?api-version=2025-04-01-preview'
    $script:GraphResponses[$projectUri] = [pscustomobject]@{ id = 'project-resource'; identity = [pscustomobject]@{ principalId = 'project-managed-identity' }
        properties = [pscustomobject]@{ agentIdentity = [pscustomobject]@{ agentIdentityId = 'project-agent-identity'
            agentIdentityBlueprintId = 'project-blueprint-client'; agentIdentityBlueprintObjectId = 'project-blueprint-object' } } }
    $script:GraphResponses['https://graph.microsoft.com/beta/servicePrincipals/project-agent-identity?$select=id,appId,displayName,accountEnabled'] =
        [pscustomobject]@{ id = 'project-agent-identity'; appId = 'project-agent-identity'; displayName = 'Provider generated project identity' }
    $script:GraphReads.Clear()
    $result = @(Get-DemoIdentityPlan 'foundry-fixture' @{ agents = @($definition) } $locale $state $foundryConfig)
    $saved = Read-DemoLabState 'foundry-fixture'
    Assert ($result[0].identities.Count -eq 2 -and $saved.agents.sample.identityId -eq 'foundry-identity') 'a new Foundry lab resolves agent and project identities from provider resource ids'
    Assert ($saved.agents.sample.blueprintId -eq 'foundry-blueprint-object' -and $saved.agents.sample.blueprintPrincipalId -eq 'foundry-blueprint-principal') 'Foundry blueprint application and principal ids are never confused'
    Assert ($saved.agents.sample.projectIdentityId -eq 'project-agent-identity' -and $saved.agents.sample.projectManagedIdentityId -eq 'project-managed-identity') 'the project agent identity comes from ARM metadata, not its managed-identity owner or a generated name'
    $state.agents.sample.Remove('projectResourceId')
    $state.agents.sample.Remove('projectBlueprintId')
    $null = Get-DemoFoundryProjectIdentity $foundryConfig $state $definition
    Assert ((Read-DemoLabState 'foundry-fixture').agents.sample.projectBlueprintId -eq 'project-blueprint-object') 'legacy project identity ids are retained while missing project and blueprint ids are backfilled'
    $script:GraphReads.Clear()
    $null = Get-DemoIdentityPlan 'foundry-fixture' @{ agents = @($definition) } $locale $state $foundryConfig
    Assert ($script:GraphReads.Count -eq 2 -and @($script:GraphReads | Where-Object { $_ -notmatch '/servicePrincipals/' }).Count -eq 0) 'warm Foundry lookups use only the persisted agent and project identity ids'
    $script:GraphResponses['https://graph.microsoft.com/beta/servicePrincipals/foundry-identity?$select=id,appId,displayName,accountEnabled'] = [pscustomobject]@{ status = 404; error = 'Deleted identity' }
    $script:GraphResponses["https://graph.microsoft.com/beta/servicePrincipals(appId='foundry-identity')?`$select=id,appId,displayName,accountEnabled"] = [pscustomobject]@{ status = 404; error = 'Deleted identity' }
    $resource.instance_identity.principal_id = 'replacement-foundry-identity'
    $script:GraphResponses[$resourceByIdUri] = $resource
    $script:GraphResponses['https://graph.microsoft.com/beta/servicePrincipals/replacement-foundry-identity?$select=id,appId,displayName,accountEnabled'] =
        [pscustomobject]@{ id = 'replacement-foundry-identity'; appId = 'replacement-foundry-identity'; displayName = 'Replacement provider identity' }
    $script:GraphReads.Clear()
    $null = Get-DemoIdentityPlan 'foundry-fixture' @{ agents = @($definition) } $locale $state $foundryConfig
    Assert ((Read-DemoLabState 'foundry-fixture').agents.sample.identityId -eq 'replacement-foundry-identity' -and
        $script:GraphReads -contains $resourceByIdUri) 'a deleted Foundry identity is repaired from the persisted provider resource id without a name search'

    $instanceConfig = @{ prefix = 'instance-fixture'; tenantId = 'tenant' }
    $state = Read-DemoLabState 'instance-fixture'
    $state.agents.sample = @{ instanceIdentityIds = @('instance-identity') }
    $definition = @{ key = 'sample'; platform = 'code'; variant = 'ACA-DW'; sponsorOn = 'instance' }
    $userColumns = 'id,displayName,userPrincipalName,accountEnabled,assignedLicenses,identityParentId'
    $relationshipUri = "https://graph.microsoft.com/beta/users/microsoft.graph.agentUser?`$filter=identityParentId eq 'instance-identity'&`$select=$userColumns"
    $userUri = "https://graph.microsoft.com/beta/users/instance-user?`$select=$userColumns"
    $user = [pscustomobject]@{ id = 'instance-user'; displayName = 'Renamed instance'; identityParentId = 'instance-identity'; accountEnabled = $true }
    $script:GraphResponses[$relationshipUri] = [pscustomobject]@{ value = @($user) }
    $script:GraphResponses[$userUri] = $user
    $script:GraphReads.Clear()
    $result = Resolve-DemoInstanceUser $instanceConfig $locale $state $definition
    Assert ($result.id -eq 'instance-user' -and (Read-DemoLabState 'instance-fixture').agents.sample.instanceUserId -eq 'instance-user') 'an AI-teammate user is learned from its identity relationship and persisted'
    Assert (@($script:GraphReads | Where-Object { $_ -match 'displayName eq' }).Count -eq 0) 'a known instance identity does not require a display-name fallback'
    $script:GraphReads.Clear()
    $null = Resolve-DemoInstanceUser $instanceConfig $locale $state $definition
    Assert ($script:GraphReads.Count -eq 1 -and $script:GraphReads[0] -eq $userUri) 'subsequent instance checks read only the persisted user id'
    $state = Read-DemoLabState 'missing-instance-fixture'
    $missingConfig = @{ prefix = 'missing-instance-fixture'; tenantId = 'tenant' }
    $nameFilter = [uri]::EscapeDataString("displayName eq 'Sample Instance'")
    $missingUri = "https://graph.microsoft.com/beta/users/microsoft.graph.agentUser?`$filter=$nameFilter&`$select=$userColumns"
    $script:GraphResponses[$missingUri] = [pscustomobject]@{ value = @() }
    $result = Resolve-DemoInstanceUser $missingConfig $locale $state $definition
    Assert ($null -eq $result -and $script:DemoAgentLookups[-1].method -eq 'missing') 'an instance without recorded identities or a user is reported missing without indexing null'

    $env:DEMO_SESSION_AUTH_DIR = Join-Path $tempRoot 'session-auth'
    Use-DemoAzProfile @{ azConfigDir = 'must-not-be-used' }
    Assert ($env:AZURE_CONFIG_DIR -eq (Join-Path $env:DEMO_SESSION_AUTH_DIR 'azure')) 'session isolation overrides a configured lab authentication profile'
    Assert ((Get-DemoAzLoginCommand @{ tenantId = 'tenant' }).Contains($env:AZURE_CONFIG_DIR)) 'the login instruction carries the session profile even without a lab profile'
    function python { $script:TokenArguments = @($args); $global:LASTEXITCODE = 0; 'offline-token' }
    $null = Get-DemoMsalToken -TenantId tenant -Scopes @('User.Read') -Prefix fixture -SilentOnly
    $cacheIndex = [array]::IndexOf($script:TokenArguments, '--cache')
    Assert ($script:TokenArguments[$cacheIndex + 1] -eq (Join-Path $env:DEMO_SESSION_AUTH_DIR 'msal\fixture\msal_graph_cache.json')) 'MSAL uses the session-specific cache without copying a shared cache'
    Remove-Item Function:\python
    $env:DEMO_SESSION_AUTH_DIR = $savedAuthDir

    . (Join-Path $repoRoot '.github\skills\agent365-wizard\scripts\modules\_common.ps1')
    . (Join-Path $repoRoot '.github\skills\agent365-wizard\scripts\modules\scaffold.ui.ps1')
    . (Join-Path $repoRoot '.github\skills\agent365-web-ui\scripts\_webui-config.ps1')
    Set-StrictMode -Off
    $technicalAgent = [pscustomobject]@{ name = 'Technical-Agent'; type = 'ACA-OBO'; displayName = 'Configured Agent - Test'; tools = @() }
    $plan = [pscustomobject]@{ solution = [pscustomobject]@{ prefix = 'unit'; tenantId = 'tenant' }
        agents = @($technicalAgent)
        ui = [pscustomobject]@{ mode = 'create'; swaRegion = 'eastus2'; expose = @([pscustomobject]@{ agentName = 'Technical-Agent' }) } }
    $RunRoot = Join-Path $tempRoot 'ui'
    New-Item -ItemType Directory -Force -Path $RunRoot | Out-Null
    $nextCommands = [Collections.Generic.List[string]]::new()
    Invoke-ScaffoldUi
    $uiConfig = Read-AppConfig -Text (Get-Content -LiteralPath (Join-Path $RunRoot 'unit-ui\config.js') -Raw)
    Assert ($uiConfig.agents[0].name -ceq 'Configured Agent - Test') 'the generated web UI consumes the resolver-provided label verbatim'
    Assert ($uiConfig.agents[0].id -eq 'obo' -and $uiConfig.agents[0].enabled -eq $false) 'a display label does not change tab ids or deployment visibility'
    $technicalAgent.PSObject.Properties.Remove('displayName')
    Invoke-ScaffoldUi
    $uiConfig = Read-AppConfig -Text (Get-Content -LiteralPath (Join-Path $RunRoot 'unit-ui\config.js') -Raw)
    Assert ($uiConfig.agents[0].name -ceq 'Technical-Agent (ACA, OBO)') 'plans without an explicit display label preserve existing web UI behavior'
    $technicalAgent | Add-Member -NotePropertyName displayName -NotePropertyValue 'Configured Agent - Test'
    $plan.ui.mode = 'attach'
    $plan.ui | Add-Member -NotePropertyName existing -NotePropertyValue ([pscustomobject]@{ staticWebApp = 'existing-ui' })
    $nextCommands.Clear()
    Invoke-ScaffoldUi
    Assert (@($nextCommands | Where-Object { $_ -match '-Name "Configured Agent - Test"' }).Count -eq 1) 'attaching to a shared UI uses the same explicit label without regenerating its config'

    $left = 'Reports Monitor - Test'
    $right = ' Reports  Monitor ' + [char]0x2013 + ' Test '
    Assert ((ConvertTo-DemoAgentNameKey $left) -eq (ConvertTo-DemoAgentNameKey $right)) 'dash and spacing variants have the same validation key'
    Assert ((ConvertTo-DemoAgentNameKey "User's Agent") -eq (ConvertTo-DemoAgentNameKey ("User" + [char]0x2019 + 's Agent'))) 'straight and typographic quote variants have the same validation key'
    foreach ($bad in @(
        '$name = "$($la.codeName) Agent"',
        '$name = $la.codeName + '' Agent''',
        '$name = "*-$codeName-AgentIdentity"',
        '$name = "$base Agent"',
        '$name = "$base (Microsoft Copilot Studio)"',
        '$name = $Locale.agents[$key].displayName',
        '$agentLocale = $Locale.agents[$key]; $name = $agentLocale.identity'
    )) { Assert (@(Test-DemoAgentNameSource -Source $bad).Count -gt 0) 'the source guard rejects an out-of-resolver name computation' }
    Assert (@(Test-DemoAgentNameSource -Source '$name = Get-DemoAgentName -Locale $Locale -Key $key -Surface registry').Count -eq 0) 'resolver calls pass the source guard'
    Assert (@(Test-DemoAgentNameSource -Source '$file = Join-Path $root "$($la.codeName)\a365.generated.config.json"').Count -eq 0) 'technical folder keys remain valid'
    $references = @{ agents = @{ sample = @{ titleId = 'T title'; botId = 'bot-id'; environmentId = 'environment'
        identityId = 'identity-id'; blueprintId = 'blueprint-id'; instanceUserId = 'user-id' } } }
    Assert ((Get-DemoAgentReference $locale $references sample) -match '\?titleId=T%20title') 'guide and Agent Builder references use the recorded escaped title id'
    Assert ((Get-DemoAgentReference $locale $references sample copilotStudio) -match '/environments/environment/bots/bot-id/overview') 'Copilot Studio cards link to the recorded bot id'
    Assert ((Get-DemoAgentReference $locale $references sample entra) -eq 'Configured Entra Name (identityId: identity-id)') 'Entra references never substitute a registry title for an identity id'
    Assert ((Expand-DemoText '{{agents.sample.displayName}} / {agent:sample}' $locale $cfg $references @{}) -eq 'Sample Agent / Sample Agent') 'card locale placeholders and agent placeholders use the same resolver'
    $cardTokens = $null; $cardErrors = $null
    $cardAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot '.github\skills\agent365-demo-builder\scripts\New-DemoCards.ps1'), [ref]$cardTokens, [ref]$cardErrors)
    $renderers = @('Get-Upn', 'Get-Who', 'Format-Code', 'Format-Block', 'Get-DemoList', 'Get-FolderText', 'Get-CopilotStudioSections', 'Get-AgentBuilderSections')
    foreach ($function in $cardAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($function.Name -in $renderers) { Invoke-Expression $function.Extent.Text }
    }
    $LOC = $locale; $state = $references
    $pack = @{ agents = @(@{ key = 'sample'; platform = 'copilotStudio'; variant = 'MCS-OH'; environment = 'payg'; buildOrder = 1; demos = @() }) }
    $studioSection = Get-CopilotStudioSections
    Assert ($studioSection.Contains('/bots/bot-id/overview') -and $studioSection.Contains('**Name**: `Sample Agent`')) 'the real Copilot Studio card renderer emits the canonical name and recorded bot link'
    $pack.agents[0].platform = 'agentBuilder'; $pack.agents[0].creator = 'admin'
    $builderSection = Get-AgentBuilderSections
    Assert ($builderSection.Contains('?titleId=T%20title') -and $builderSection.Contains('**Name**: `Sample Agent`')) 'the real Agent Builder card renderer emits the canonical name and recorded title link'
    $script:DemoRepoRoot = $repoRoot
    $violations = @(foreach ($folder in 'agent365-demo-builder', 'agent365-demo-reset', 'agent365-demo-guide') {
        $scripts = Join-Path $repoRoot ".github\skills\$folder\scripts"
        foreach ($file in Get-ChildItem -LiteralPath $scripts -Filter '*.ps1' -File) {
            if ($file.Name -cmatch '^test-' -or $file.Name -eq 'Test-DemoPack.ps1') { continue }
            Test-DemoAgentNameSource -Source (Get-Content -LiteralPath $file.FullName -Raw) -File $file.FullName
        }
    })
    foreach ($violation in $violations) { Write-Host "$($violation.file):$($violation.line): $($violation.message)" }
    Assert ($violations.Count -eq 0) 'every demo build, pre-flight, reset, guide, inventory and card script uses the resolver'
    Write-Host "Passed $passed, failed 0"
}
finally {
    $script:DemoRepoRoot = $repoRoot
    $env:DEMO_SESSION_AUTH_DIR = $savedAuthDir
    $env:AZURE_CONFIG_DIR = $savedAzDir
    $env:AZURE_EXTENSION_DIR = $savedExtensionDir
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
