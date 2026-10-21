# Shared Entra helpers of the Demo Builder, used by the build (Set-DemoGovernance.ps1) and the reset scripts. Dot-source
# AFTER _demo-common.ps1. Agent-identity sponsors/owners and custom security attribute ASSIGNMENTS are application-only
# APIs: New-DemoAppOnlySession creates a TEMPORARY app registration (tagged a365lab:<prefix>) with only the Graph
# application permissions needed, a 4-hour secret kept in memory, and Close-DemoAppOnlySession deletes and purges it.
# Directory writes replicate asynchronously: every change is re-read until visible (Wait-DemoConverged).
$script:DemoG = 'https://graph.microsoft.com'

function Get-DemoAgentIdentities([switch]$Refresh) {
    if ($script:DemoAgentIdentities -and -not $Refresh) { return $script:DemoAgentIdentities }
    $script:DemoAgentIdentities = @(Invoke-DemoGraph GET "$script:DemoG/beta/servicePrincipals/microsoft.graph.agentIdentity?`$select=id,appId,displayName,agentIdentityBlueprintId,accountEnabled,createdDateTime&`$top=999" -All)
    return $script:DemoAgentIdentities
}

function Get-DemoIdentityById([string]$Id) {
    $columns = 'id,appId,displayName,accountEnabled'
    $identity = Get-DemoGraphObject "$script:DemoG/beta/servicePrincipals/$Id`?`$select=$columns"
    if (-not $identity) { $identity = Get-DemoGraphObject "$script:DemoG/beta/servicePrincipals(appId='$Id')?`$select=$columns" }
    return $identity
}

function Get-DemoFoundryAgentResource($Config, $Locale, $State, $AgentDef, [string]$ExpectedIdentityId) {
    $entry = $State.agents[$AgentDef.key]
    $knownResourceId = [bool]$entry.foundryAgentId
    $endpoint = ([string]$Config.foundry.endpoint).TrimEnd('/')
    if ($entry.foundryEndpoint -and $entry.foundryEndpoint -ne $endpoint) {
        throw "Agent '$($AgentDef.key)' is recorded in a different Foundry project. Reconcile state.json before continuing."
    }
    $resourceId = if ($entry.foundryAgentId) { [string]$entry.foundryAgentId } else { [string]$Locale.agents[$AgentDef.key].codeName }
    $token = Get-DemoAzToken -Resource 'https://ai.azure.com' -TenantId $Config.tenantId
    $resource = Get-DemoGraphObject "$endpoint/agents/$([uri]::EscapeDataString($resourceId))?api-version=v1" $token
    if (-not $resource) { return $null }
    if (-not $resource.id -or -not $resource.instance_identity.principal_id) {
        throw "Foundry agent '$resourceId' returned no resource or instance identity id."
    }
    if ($ExpectedIdentityId -and $resource.instance_identity.principal_id -ne $ExpectedIdentityId) {
        throw "Foundry agent '$resourceId' does not reference the recorded identity '$ExpectedIdentityId'. Reconcile state.json."
    }
    $ids = @{ foundryAgentId = [string]$resource.id; foundryEndpoint = $endpoint }
    if ($resource.blueprint.client_id) { $ids['blueprintAppId'] = [string]$resource.blueprint.client_id }
    if ($resource.blueprint.principal_id) { $ids['blueprintPrincipalId'] = [string]$resource.blueprint.principal_id }
    Set-DemoAgentIds $Config.prefix $State $AgentDef.key $ids
    Add-DemoAgentLookup $Config $AgentDef.key 'foundryAgentId' $(if ($knownResourceId) { 'id' } else { 'relationship' }) '' $resource.id
    return $resource
}

function Resolve-DemoAgentIdentity($Config, $Locale, $State, $AgentDef) {
    Initialize-DemoAgentState $Config $Locale $State $AgentDef
    $entry = $State.agents[$AgentDef.key]
    $foundryLookupId = ''; $knownIdentity = $null; $resource = $null
    if ([string]$AgentDef.variant -match '^(FD|FH)-' -and $Config.foundry.endpoint -match '/api/projects/') {
        $foundryLookupId = if ($entry.identityId) { [string]$entry.identityId } else { [string]$entry.identityAppId }
        if ($foundryLookupId) { $knownIdentity = Get-DemoIdentityById $foundryLookupId }
        if (-not $knownIdentity -or -not $entry.blueprintAppId) {
            $resource = Get-DemoFoundryAgentResource $Config $Locale $State $AgentDef ([string]$knownIdentity.id)
        }
    }
    $candidates = @($entry.identityAppId, $resource.instance_identity.principal_id | Where-Object { $_ })
    $identity = Resolve-DemoAgentObject -Config $Config -Locale $Locale -State $State -Key $AgentDef.key -IdField identityId -Surface entra -CandidateIds $candidates -ReadById {
        param($id)
        if ($foundryLookupId -and $id -eq $foundryLookupId) { return $knownIdentity }
        Get-DemoIdentityById $id
    } -FindByName {
        param($name)
        $filter = [uri]::EscapeDataString("displayName eq '$($name.Replace("'", "''"))'")
        Invoke-DemoGraph GET "$script:DemoG/beta/servicePrincipals/microsoft.graph.agentIdentity?`$filter=$filter&`$select=id,appId,displayName,accountEnabled" -All
    }
    if ($identity.appId) { Set-DemoAgentIds $Config.prefix $State $AgentDef.key @{ identityAppId = [string]$identity.appId } }
    if ($identity -and $resource.blueprint.client_id -and -not $State.agents[$AgentDef.key].blueprintId) {
        $null = Resolve-DemoAgentBlueprint $Config $Locale $State $AgentDef
    }
    return $identity
}

function Resolve-DemoAgentBlueprint($Config, $Locale, $State, $AgentDef) {
    Initialize-DemoAgentState $Config $Locale $State $AgentDef
    $entry = $State.agents[$AgentDef.key]
    $blueprint = Resolve-DemoAgentObject -Config $Config -Locale $Locale -State $State -Key $AgentDef.key -IdField blueprintId -Surface blueprint -CandidateIds @($entry.blueprintAppId) -ReadById {
        param($id)
        $object = Get-DemoGraphObject "$script:DemoG/beta/applications/$id`?`$select=id,appId,displayName"
        if (-not $object) { $object = Get-DemoGraphObject "$script:DemoG/beta/applications(appId='$id')?`$select=id,appId,displayName" }
        $object
    } -FindByName {
        param($name)
        $filter = [uri]::EscapeDataString("displayName eq '$($name.Replace("'", "''"))'")
        Invoke-DemoGraph GET "$script:DemoG/beta/applications/microsoft.graph.agentIdentityBlueprint?`$filter=$filter&`$select=id,appId,displayName" -All
    }
    if ($blueprint.appId) { Set-DemoAgentIds $Config.prefix $State $AgentDef.key @{ blueprintAppId = [string]$blueprint.appId } }
    return $blueprint
}

function Get-DemoFoundryProjectIdentity($Config, $State, $AgentDef) {
    $entry = $State.agents[$AgentDef.key]
    $knownIdentity = $null
    if ($entry.projectIdentityId) {
        $knownIdentity = Get-DemoIdentityById $entry.projectIdentityId
        if ($knownIdentity -and $entry.projectResourceId -and $entry.projectBlueprintId -and $entry.projectBlueprintAppId) {
            Add-DemoAgentLookup $Config $AgentDef.key 'projectIdentityId' 'id' '' $knownIdentity.id
            return $knownIdentity
        }
        if (-not $knownIdentity) {
            Write-DemoLog $Config.prefix "Agent '$($AgentDef.key)': recorded project identity no longer exists; reading the Foundry project resource." 'WARN'
        }
    }
    $projectMatch = [regex]::Match([string]$Config.foundry.endpoint, '/api/projects/([^/?]+)/?$')
    if (-not $Config.subscriptionId -or -not $Config.foundry.account -or -not $Config.foundry.existingResourceGroup -or
        -not $projectMatch.Success) {
        throw "Agent '$($AgentDef.key)': configure the Foundry account, resource group, subscription and project endpoint to resolve its project identity by resource id."
    }
    $projectName = [uri]::EscapeDataString([uri]::UnescapeDataString($projectMatch.Groups[1].Value))
    $uri = "https://management.azure.com/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.foundry.existingResourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($Config.foundry.account)/projects/$projectName`?api-version=2025-04-01-preview"
    if ($entry.projectResourceId) { $uri = "https://management.azure.com$($entry.projectResourceId)?api-version=2025-04-01-preview" }
    $token = Get-DemoAzToken -Resource 'https://management.azure.com/' -TenantId $Config.tenantId
    $project = Get-DemoGraphObject $uri $token
    if ($project.properties.agentIdentity.agentIdentityId) {
        if ($knownIdentity -and $project.properties.agentIdentity.agentIdentityId -ne $knownIdentity.id) {
            throw "Foundry project metadata does not reference the recorded identity '$($knownIdentity.id)'. Reconcile state.json."
        }
        $identity = if ($knownIdentity) { $knownIdentity } else { Get-DemoIdentityById $project.properties.agentIdentity.agentIdentityId }
        if ($identity) {
            Set-DemoAgentIds $Config.prefix $State $AgentDef.key @{
                projectIdentityId = [string]$identity.id
                projectBlueprintAppId = [string]$project.properties.agentIdentity.agentIdentityBlueprintId
                projectBlueprintId = [string]$project.properties.agentIdentity.agentIdentityBlueprintObjectId
                projectManagedIdentityId = [string]$project.identity.principalId
                projectResourceId = [string]$project.id
            }
            Add-DemoAgentLookup $Config $AgentDef.key 'projectIdentityId' $(if ($knownIdentity) { 'id' } else { 'relationship' }) '' $identity.id
            return $identity
        }
    }
    Write-DemoLog $Config.prefix "Agent '$($AgentDef.key)': the Foundry project has no resolvable agent identity yet." 'WARN'
    Add-DemoAgentLookup $Config $AgentDef.key 'projectIdentityId' 'missing' '' ''
    return $null
}

function Get-DemoIdentityPlan([string]$Prefix, $Pack, $Locale, $State, $Config) {
    if (-not $Config) { $Config = Read-DemoConfig $Prefix }
    if (-not $State) { $State = Read-DemoLabState $Prefix }
    @(foreach ($a in @($Pack.agents | Where-Object { $_.entraOwner -or $_.sponsor -or $_.attribute })) {
        Initialize-DemoAgentState $Config $Locale $State $a
        $entry = $State.agents[$a.key]
        $ids = @()
        if ($a.sponsorOn -eq 'instance') {
            $known = @($entry.instanceIdentityIds | Where-Object { $_ })
            $ids = @($known | ForEach-Object { Get-DemoIdentityById $_ } | Where-Object { $_ })
            if (-not $known.Count -or $ids.Count -ne $known.Count) {
                $blueprint = Resolve-DemoAgentBlueprint $Config $Locale $State $a
                if ($blueprint) { $ids = @(Get-DemoBlueprintInstances ([string]$blueprint.appId)) }
                if ($ids.Count) {
                    Set-DemoAgentIds $Prefix $State $a.key @{ instanceIdentityIds = @($ids | ForEach-Object { [string]$_.id }) }
                }
                Add-DemoAgentLookup $Config $a.key 'instanceIdentityIds' $(if ($ids.Count) { 'relationship' } else { 'missing' }) '' (@($ids.id) -join ',')
            }
            else { Add-DemoAgentLookup $Config $a.key 'instanceIdentityIds' 'id' '' ($known -join ',') }
        }
        else { $ids = @(Resolve-DemoAgentIdentity $Config $Locale $State $a | Where-Object { $_ }) }
        if ([string]$a.variant -like 'FD-*' -and $ids.Count -eq 1) {
            $projectIdentity = Get-DemoFoundryProjectIdentity $Config $State $a
            if ($projectIdentity) { $ids += $projectIdentity }
        }
        [pscustomobject]@{ key = [string]$a.key; name = Get-DemoAgentName -Locale $Locale -Key $a.key; def = $a; identities = @($ids) }
    })
}

# Instances (agent identities) created from one blueprint, e.g. the Digital Worker instances of an ACA-DW/FH-DW agent.
function Get-DemoBlueprintInstances([Parameter(Mandatory)][string]$BlueprintAppId) {
    return @(Invoke-DemoGraph GET "$script:DemoG/beta/servicePrincipals/microsoft.graph.agentIdentity?`$filter=agentIdentityBlueprintId eq '$BlueprintAppId'&`$select=id,appId,displayName,agentIdentityBlueprintId,accountEnabled" -All)
}

function Resolve-DemoInstanceUser($Config, $Locale, $State, $AgentDef) {
    Initialize-DemoAgentState $Config $Locale $State $AgentDef
    $entry = $State.agents[$AgentDef.key]
    $columns = 'id,displayName,userPrincipalName,accountEnabled,assignedLicenses,identityParentId'
    $candidateIds = @()
    $identityIds = @($entry.instanceIdentityIds | Where-Object { $_ })
    if (-not $entry.instanceUserId -and $identityIds.Count -eq 1) {
        $parentId = [string]$identityIds[0]
        $users = @(Invoke-DemoGraph GET "$script:DemoG/beta/users/microsoft.graph.agentUser?`$filter=identityParentId eq '$parentId'&`$select=$columns" -All)
        if ($users.Count -gt 1) { throw "Agent '$($AgentDef.key)' has multiple users for identity '$parentId'. Record instanceUserId in state.json." }
        $candidateIds = @($users | ForEach-Object { [string]$_.id })
    }
    $user = Resolve-DemoAgentObject -Config $Config -Locale $Locale -State $State -Key $AgentDef.key -IdField instanceUserId -Surface instance -CandidateIds $candidateIds -ReadById {
        param($id) Get-DemoGraphObject "$script:DemoG/beta/users/$id`?`$select=$columns"
    } -FindByName {
        param($name)
        $filter = [uri]::EscapeDataString("displayName eq '$($name.Replace("'", "''"))'")
        Invoke-DemoGraph GET "$script:DemoG/beta/users/microsoft.graph.agentUser?`$filter=$filter&`$select=$columns" -All
    }
    if ($user.identityParentId) {
        $identities = @(@($entry.instanceIdentityIds) + @([string]$user.identityParentId) | Where-Object { $_ } | Select-Object -Unique)
        Set-DemoAgentIds $Config.prefix $State $AgentDef.key @{ instanceIdentityIds = $identities }
    }
    return $user
}

function Wait-DemoConverged([scriptblock]$Read, [scriptblock]$IsDone, [int]$Tries = 6, [int]$DelaySeconds = 8) {
    $v = $null
    for ($i = 0; $i -lt $Tries; $i++) { $v = & $Read; if (& $IsDone $v) { return $v }; Start-Sleep -Seconds $DelaySeconds }
    return $v
}

function ConvertFrom-DemoJwt([string]$Jwt) {
    $p = $Jwt.Split('.')[1].Replace('-', '+').Replace('_', '/'); switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
}

# Temporary app with the given Graph APPLICATION permissions; returns @{ app; token; roles }. Always pair with
# Close-DemoAppOnlySession in a finally block.
function New-DemoAppOnlySession {
    param([Parameter(Mandatory)][string]$Prefix, [Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string[]]$Roles)
    $G = $script:DemoG
    $name = "$Prefix-demo-automation (temporary)"
    $app = (Invoke-DemoGraph GET "$G/v1.0/applications?`$filter=displayName eq '$name'&`$select=id,appId").value | Select-Object -First 1
    if (-not $app) {
        $app = Invoke-DemoGraph POST "$G/v1.0/applications" -Body @{ displayName = $name; signInAudience = 'AzureADMyOrg'; tags = @("a365lab:$Prefix")
            notes = 'Temporary app-only automation of the Demo Builder (agent sponsors/owners, custom security attributes). Safe to delete.' }
        Write-DemoLog $Prefix "Temporary app created: $name ($($app.appId))"
    }
    $session = @{ app = $app; token = $null; roles = $Roles; prefix = $Prefix }
    $sp = $null
    for ($i = 0; $i -lt 10 -and -not $sp; $i++) {
        $sp = (Invoke-DemoGraph GET "$G/v1.0/servicePrincipals?`$filter=appId eq '$($app.appId)'&`$select=id").value | Select-Object -First 1
        if (-not $sp) { try { $sp = Invoke-DemoGraph POST "$G/v1.0/servicePrincipals" -Body @{ appId = $app.appId; tags = @("a365lab:$Prefix") } -MaxRetries 1 } catch { Start-Sleep -Seconds 3 } }
    }
    if (-not $sp) { throw 'Service principal of the temporary app not created.' }
    $graphSp = (Invoke-DemoGraph GET "$G/v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=id,appRoles").value | Select-Object -First 1
    $have = @((Invoke-DemoGraph GET "$G/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments" -All) | ForEach-Object { $_.appRoleId })
    foreach ($rn in $Roles) {
        $role = $graphSp.appRoles | Where-Object { $_.value -eq $rn -and $_.allowedMemberTypes -contains 'Application' } | Select-Object -First 1
        if (-not $role) { throw "Graph application permission $rn not found." }
        if ($have -notcontains $role.id) { Invoke-DemoGraph POST "$G/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments" -Body @{ principalId = $sp.id; resourceId = $graphSp.id; appRoleId = $role.id } | Out-Null }
    }
    $cred = Invoke-DemoGraph POST "$G/v1.0/applications/$($app.id)/addPassword" -Body @{ passwordCredential = @{ displayName = 'temporary'; endDateTime = (Get-Date).ToUniversalTime().AddHours(4).ToString('o') } }
    $secret = $cred.secretText; $cred = $null
    for ($i = 0; $i -lt 30 -and -not $session.token; $i++) {
        try {
            $r = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -ContentType 'application/x-www-form-urlencoded' `
                -Body @{ client_id = $app.appId; client_secret = $secret; scope = "$G/.default"; grant_type = 'client_credentials' } -ErrorAction Stop
            $got = @((ConvertFrom-DemoJwt $r.access_token).roles)
            if (@($Roles | Where-Object { $got -notcontains $_ }).Count -eq 0) { $session.token = $r.access_token; break }
        }
        catch { }
        Start-Sleep -Seconds 10
    }
    $secret = $null
    if (-not $session.token) { Close-DemoAppOnlySession $session; throw 'App-only token with the expected roles not obtained within 5 minutes.' }
    # The first resource call can fail 401 Authorization_IdentityNotFound while the new service principal propagates.
    for ($i = 0; $i -lt 12; $i++) {
        try { Invoke-RestMethod -Method GET -Uri "$G/beta/servicePrincipals/microsoft.graph.agentIdentity?`$top=1&`$select=id" -Headers @{ Authorization = "Bearer $($session.token)" } -ErrorAction Stop | Out-Null; Start-Sleep -Seconds 15; break }
        catch { Start-Sleep -Seconds 10 }
    }
    Write-DemoLog $Prefix "App-only token obtained ($($Roles -join ', '))"
    return $session
}

function Close-DemoAppOnlySession($Session) {
    if (-not $Session -or -not $Session.app) { return }
    $Session.token = $null
    $G = $script:DemoG
    try {
        Invoke-DemoGraph DELETE "$G/v1.0/applications/$($Session.app.id)" | Out-Null
        try { Invoke-DemoGraph DELETE "$G/v1.0/directory/deletedItems/$($Session.app.id)" -MaxRetries 2 | Out-Null } catch { }
        Write-DemoLog $Session.prefix 'Temporary app deleted and purged'
    }
    catch { Write-DemoLog $Session.prefix "Temporary app NOT deleted ($($_.Exception.Message)): delete '$($Session.prefix)-demo-automation (temporary)' manually" 'WARN' }
}
# --- Agent identity: sponsors, owners, enabled flag, custom security attribute (application-only) ---------------
function Get-DemoRef([string]$ObjectId) { @{ '@odata.id' = "$script:DemoG/beta/directoryObjects/$ObjectId" } }
function Format-DemoRefs($List) {
    @($List | ForEach-Object { $n = if ($_.displayName) { $_.displayName } else { $_.id }; if ($_.'@odata.type' -and $_.'@odata.type' -ne '#microsoft.graph.user') { "$n <app>" } else { $n } })
}

# Sponsor = -UserId (with -Exclusive every other sponsor is removed). Returns the final sponsors.
function Set-DemoIdentitySponsor($Session, [string]$IdentityId, [string]$UserId, [switch]$Exclusive) {
    $base = "$script:DemoG/beta/servicePrincipals/$IdentityId/microsoft.graph.agentIdentity/sponsors"
    $read = { @((Invoke-DemoGraph GET "${base}?`$select=id,displayName" -Token $Session.token).value) }
    $cur = & $read
    if (@($cur | ForEach-Object { $_.id }) -notcontains $UserId) { Invoke-DemoGraph POST "$base/`$ref" -Body (Get-DemoRef $UserId) -Token $Session.token | Out-Null }
    if ($Exclusive) { foreach ($o in @($cur | Where-Object { $_.id -ne $UserId })) { Invoke-DemoGraph DELETE "$base/$($o.id)/`$ref" -Token $Session.token | Out-Null } }
    return (Format-DemoRefs (Wait-DemoConverged $read { param($l) (@($l | ForEach-Object { $_.id }) -contains $UserId) -and (-not $Exclusive -or @($l).Count -eq 1) }))
}

# User owner = -UserId (with -ExclusiveUser the other USER owners are removed; service-principal owners such as the
# Foundry project managed identity are always kept). Falls back to the delegated token, as in the reference lab.
function Set-DemoIdentityOwner($Session, [string]$IdentityId, [string]$UserId, [switch]$ExclusiveUser) {
    $base = "$script:DemoG/beta/servicePrincipals/$IdentityId/microsoft.graph.agentIdentity/owners"
    $read = { @((Invoke-DemoGraph GET "${base}?`$select=id,displayName" -Token $Session.token).value) }
    $cur = & $read
    if (@($cur | ForEach-Object { $_.id }) -notcontains $UserId) {
        $r = Invoke-DemoGraph POST "$base/`$ref" -Body (Get-DemoRef $UserId) -Token $Session.token -NoThrow
        if ($r -and $r.PSObject.Properties['error']) { Invoke-DemoGraph POST "$base/`$ref" -Body (Get-DemoRef $UserId) | Out-Null }
    }
    if ($ExclusiveUser) {
        foreach ($o in @($cur | Where-Object { $_.id -ne $UserId -and $_.'@odata.type' -eq '#microsoft.graph.user' })) {
            $r = Invoke-DemoGraph DELETE "$base/$($o.id)/`$ref" -Token $Session.token -NoThrow
            if ($r -and $r.PSObject.Properties['error']) { Invoke-DemoGraph DELETE "$script:DemoG/v1.0/servicePrincipals/$IdentityId/owners/$($o.id)/`$ref" | Out-Null }
        }
    }
    $isDone = { param($l) (@($l | ForEach-Object { $_.id }) -contains $UserId) -and (-not $ExclusiveUser -or @($l | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.user' }).Count -eq 1) }
    return (Format-DemoRefs (Wait-DemoConverged $read $isDone))
}

function Set-DemoIdentityEnabled($Session, [string]$IdentityId, [bool]$Enabled) {
    $cur = Invoke-DemoGraph GET "$script:DemoG/beta/servicePrincipals/${IdentityId}?`$select=accountEnabled" -Token $Session.token
    if ([bool]$cur.accountEnabled -eq $Enabled) { return 'unchanged' }
    Invoke-DemoGraph PATCH "$script:DemoG/beta/servicePrincipals/$IdentityId/microsoft.graph.agentIdentity" -Body @{ accountEnabled = $Enabled } -Token $Session.token | Out-Null
    return 'changed'
}

# Custom security attribute assignment on an agent identity; returns the value read back.
function Set-DemoIdentityAttribute($Session, [string]$IdentityId, [string]$AttributeSet, [string]$Attribute, [string]$Value) {
    $body = @{ customSecurityAttributes = @{ $AttributeSet = @{ '@odata.type' = '#Microsoft.DirectoryServices.CustomSecurityAttributeValue'; $Attribute = $Value } } }
    $errs = @(); $done = $false
    foreach ($u in "$script:DemoG/beta/servicePrincipals/$IdentityId/microsoft.graph.agentIdentity", "$script:DemoG/beta/servicePrincipals/$IdentityId") {
        $r = Invoke-DemoGraph PATCH $u -Body $body -Token $Session.token -NoThrow
        if ($r -and $r.PSObject.Properties['error']) { $errs += $r.error } else { $done = $true; break }
    }
    if (-not $done) { throw "Attribute $AttributeSet/$Attribute on ${IdentityId}: $($errs -join ' | ')" }
    $read = { try { [string](Invoke-DemoGraph GET "$script:DemoG/beta/servicePrincipals/${IdentityId}?`$select=customSecurityAttributes" -Token $Session.token).customSecurityAttributes.$AttributeSet.$Attribute } catch { '' } }
    return (Wait-DemoConverged $read { param($v) $v -eq $Value })
}

# Resource names of pack.json agents[].directAppRoles -> appId of the resource service principal.
$script:DemoResourceApps = @{ 'Microsoft Graph' = '00000003-0000-0000-c000-000000000000' }

# Direct application permission (app role) of a resource granted to an agent identity; returns 'present' or 'added'.
function Set-DemoIdentityAppRole($Session, [string]$IdentityId, [string]$Resource, [string]$Role) {
    $appId = $script:DemoResourceApps[$Resource]
    if (-not $appId) { throw "Unknown resource '$Resource' (known: $($script:DemoResourceApps.Keys -join ', '))." }
    $res = (Invoke-DemoGraph GET "$script:DemoG/v1.0/servicePrincipals?`$filter=appId eq '$appId'&`$select=id,appRoles" -Token $Session.token).value | Select-Object -First 1
    $ar = $res.appRoles | Where-Object { $_.value -eq $Role -and $_.allowedMemberTypes -contains 'Application' } | Select-Object -First 1
    if (-not $ar) { throw "Application permission $Role not found on $Resource." }
    $read = { @((Invoke-DemoGraph GET "$script:DemoG/v1.0/servicePrincipals/$IdentityId/appRoleAssignments" -Token $Session.token -All) | Where-Object { $_.resourceId -eq $res.id -and $_.appRoleId -eq $ar.id }) }
    if (@(& $read).Count) { return 'present' }
    Invoke-DemoGraph POST "$script:DemoG/v1.0/servicePrincipals/$IdentityId/appRoleAssignments" -Token $Session.token -Body @{ principalId = $IdentityId; resourceId = $res.id; appRoleId = $ar.id } | Out-Null
    $null = Wait-DemoConverged $read { param($l) @($l).Count -gt 0 }
    return 'added'
}
