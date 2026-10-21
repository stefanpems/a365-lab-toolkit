# Registry helpers of the demo reset: Agent 365 catalog packages, agent registrations and agent risk. Dot-source AFTER
# the Demo Builder's _demo-common.ps1 and _demo-entra.ps1. One delegated MSAL token (Microsoft Graph Command Line Tools
# client, system browser on first use, cached per lab) carries every scope below.
$script:DemoRegScopes = @('CopilotPackages.ReadWrite.All', 'AgentRegistration.ReadWrite.All', 'IdentityRiskyAgent.ReadWrite.All',
    'EntitlementManagement.ReadWrite.All', 'Policy.Read.All', 'Sites.Read.All', 'CustomSecAttributeAssignment.Read.All')
$script:DemoRegToken = $null; $script:DemoRegTokenExp = [datetime]::MinValue
$script:DemoPackages = $null; $script:DemoPackageDetail = @{}; $script:DemoExists = @{}

function Get-DemoRegToken($Config) {
    if ($script:DemoRegToken -and $script:DemoRegTokenExp -gt (Get-Date).AddMinutes(5)) { return $script:DemoRegToken }
    $script:DemoRegToken = Get-DemoMsalToken -TenantId $Config.tenantId -Prefix $Config.prefix -LoginHint $Config.adminUpn -Scopes $script:DemoRegScopes
    $script:DemoRegTokenExp = (Get-Date).AddMinutes(50)
    return $script:DemoRegToken
}

# REST call with the registry token; returns { ok, status, body, error } and never throws.
function Invoke-DemoReg($Config, [string]$Method, [string]$Uri, $Body) {
    $r = Invoke-DemoGraph $Method $Uri -Body $Body -Token (Get-DemoRegToken $Config) -NoThrow
    $isErr = $r -and $r.PSObject.Properties['error'] -and $r.PSObject.Properties['status'] -and @($r.PSObject.Properties).Count -eq 2
    if ($isErr) { return [pscustomobject]@{ ok = $false; status = $r.status; body = $null; error = [string]$r.error } }
    return [pscustomobject]@{ ok = $true; status = 200; body = $r; error = $null }
}

function Clear-DemoPackageCache { $script:DemoPackages = $null; $script:DemoPackageDetail = @{}; $script:DemoExists = @{} }
function Get-DemoPackageList($Config) {
    if (-not $script:DemoPackages) { $script:DemoPackages = @(Invoke-DemoGraph GET "$script:DemoG/beta/copilot/admin/catalog/packages" -Token (Get-DemoRegToken $Config) -All) }
    return $script:DemoPackages
}
function Get-DemoPackageDetail($Config, [string]$Id) {
    if (-not $script:DemoPackageDetail.ContainsKey($Id)) {
        $r = Invoke-DemoReg $Config GET "$script:DemoG/beta/copilot/admin/catalog/packages/$Id"
        if (-not $r.ok -and $r.status -ne 404) { throw "Registry package '$Id' could not be read ($($r.status)): $($r.error)" }
        if ($r.ok -and [string]::IsNullOrWhiteSpace([string]$r.body.id)) { throw "Registry package '$Id' returned no package id." }
        $script:DemoPackageDetail[$Id] = if ($r.ok) { $r.body } else { $null }
        Start-Sleep -Milliseconds 300
    }
    return $script:DemoPackageDetail[$Id]
}

# Shared and published packages keep separate roles. Never choose between duplicate roles by date or list order.
function Get-DemoAgentPackages($Config, $Locale, $State, $AgentDef) {
    $known = if ($State.agents -and $State.agents.Contains($AgentDef.key)) { @($State.agents[$AgentDef.key].packages) } else { @() }
    $known = @($known | Where-Object { $_ } | Select-Object -Unique)
    $all = @($known | ForEach-Object { Get-DemoPackageDetail $Config $_ } | Where-Object { $_ })
    $method = 'id'; $matchedName = ''
    if (-not $known.Count -or $all.Count -ne $known.Count) {
        $names = @(Get-DemoAgentName -Locale $Locale -Key $AgentDef.key -Surface registry -State $State -IncludeAliases)
        $packages = @(Get-DemoPackageList $Config)
        $found = @()
        foreach ($name in $names) {
            $hits = @($packages | Where-Object { $_.displayName -ceq $name } |
                ForEach-Object { Get-DemoPackageDetail $Config ([string]$_.id) } | Where-Object { $_ })
            if (-not $hits.Count) { continue }
            $found += $hits
            $matchedName = $name
            $method = if ($name -ceq $names[0]) { 'name' } else { 'alias' }
            if ($method -eq 'name') { break }
        }
        $all = @(@($all) + @($found) | Group-Object id | ForEach-Object { $_.Group[0] })
        if (-not $all.Count) { $method = 'missing'; $matchedName = $names[0] }
    }
    $sharedEntries = @($all | Where-Object { $_.type -eq 'shared' })
    $publishedEntries = @($all | Where-Object { $_.type -and $_.type -ne 'shared' })
    if ($sharedEntries.Count -gt 1 -or $publishedEntries.Count -gt 1 -or
        ($all.Count -gt 1 -and $sharedEntries.Count + $publishedEntries.Count -ne $all.Count)) {
        throw "Agent '$($AgentDef.key)' has ambiguous registry packages. Record the intended shared/published ids in state.json."
    }
    $shared = if ($sharedEntries.Count) { $sharedEntries[0] } else { $null }
    $published = if ($publishedEntries.Count) { $publishedEntries[0] } else { $null }
    if (-not $shared -and -not $published -and $all.Count -eq 1) { $shared = $all[0] }
    if ($all.Count) {
        $ids = @{ packages = @($all | ForEach-Object { [string]$_.id })
            titleId = [string]$(if ($shared) { $shared.id } else { $published.id }) }
        if ($published) { $ids['publishedTitleId'] = [string]$published.id }
        Set-DemoAgentIds $Config.prefix $State $AgentDef.key $ids
    }
    Add-DemoAgentLookup $Config $AgentDef.key 'packages' $method $matchedName (@($all.id) -join ',')
    return [pscustomobject]@{ shared = $shared; published = $published; all = $all }
}

# The catalog keeps the id of a permanently deleted owner: an agent is ownerless when ownerId is empty OR unresolvable.
function Test-DemoObjectExists([string]$Id) {
    if (-not $Id) { return $false }
    if (-not $script:DemoExists.ContainsKey($Id)) {
        $r = Invoke-DemoGraph GET "$script:DemoG/v1.0/directoryObjects/${Id}?`$select=id" -NoThrow -MaxRetries 1
        $script:DemoExists[$Id] = -not ($r -and $r.PSObject.Properties['error'] -and $r.status -eq 404)
    }
    return $script:DemoExists[$Id]
}
function Test-DemoOwnerless($Package) { return (-not $Package.ownerId) -or -not (Test-DemoObjectExists ([string]$Package.ownerId)) }

# Registry owner: code agents through their agent registration (Lab Builder config agentRegistrationId), the others
# through the catalog reassign action.
function Set-DemoRegistryOwner($Config, $Package, [string]$UserId, [string]$RegistrationId) {
    if ($RegistrationId) { return Invoke-DemoReg $Config PATCH "$script:DemoG/beta/copilot/agentRegistrations/$RegistrationId" @{ ownerIds = @($UserId) } }
    return Invoke-DemoReg $Config POST "$script:DemoG/beta/copilot/admin/catalog/packages/$($Package.id)/reassign" @{ userId = $UserId }
}
function Set-DemoPackageBlocked($Config, $Package, [bool]$Blocked) {
    return Invoke-DemoReg $Config POST "$script:DemoG/beta/copilot/admin/catalog/packages/$($Package.id)/$(if ($Blocked) { 'block' } else { 'unblock' })"
}

# Agent risk (Entra ID Protection): 'none' when there is no record.
function Get-DemoAgentRisk($Config, [string]$IdentityId) {
    $r = Invoke-DemoReg $Config GET "$script:DemoG/beta/identityProtection/riskyAgents/$IdentityId"
    if ($r.ok) { return "$($r.body.riskLevel)/$($r.body.riskState)" }
    if ($r.status -eq 404) { return 'none' }
    return "error $($r.status)"
}
function Clear-DemoAgentRisk($Config, [string]$IdentityId) {
    return Invoke-DemoReg $Config POST "$script:DemoG/beta/identityProtection/riskyAgents/dismiss" @{ agentIds = @($IdentityId) }
}
