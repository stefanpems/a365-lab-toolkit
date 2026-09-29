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
        $script:DemoPackageDetail[$Id] = if ($r.ok) { $r.body } else { $null }
        Start-Sleep -Milliseconds 300
    }
    return $script:DemoPackageDetail[$Id]
}

# Catalog display name of a pack agent (reference lab, 28/09): ACA/FH code agents '<codeName> Agent', Foundry prompt
# agents '<codeName>', Digital Worker templates and every other agent their localized display name.
function Get-DemoCatalogName($Locale, $AgentDef) {
    $la = $Locale.agents[$AgentDef.key]
    if ($AgentDef.platform -eq 'code' -and [string]$AgentDef.variant -like '*-DW') { return [string]$(if ($la.manifest -and $la.manifest.nameShort) { $la.manifest.nameShort } else { $la.displayName }) }
    if ($AgentDef.platform -eq 'code' -and [string]$AgentDef.variant -like 'FD-*') { return [string]$la.codeName }
    if ($AgentDef.platform -eq 'code') { return "$($la.codeName) Agent" }
    return [string]$la.displayName
}

# Packages of a pack agent: the ids learned in state.json (agents.<key>.packages) or, the first time, every package with
# the catalog name. A published Copilot Studio agent has TWO: 'shared' (owner) and the organization-catalog one
# (install scope, block). Returns @{ shared; published; all }.
function Get-DemoAgentPackages($Config, $Locale, $State, $AgentDef) {
    $known = if ($State.agents -and $State.agents.Contains($AgentDef.key)) { @($State.agents[$AgentDef.key].packages) } else { @() }
    $ids = if (@($known | Where-Object { $_ }).Count) { @($known | Where-Object { $_ }) } else { @(Get-DemoPackageList $Config | Where-Object { $_.displayName -eq (Get-DemoCatalogName $Locale $AgentDef) } | ForEach-Object { [string]$_.id }) }
    $all = @($ids | ForEach-Object { Get-DemoPackageDetail $Config $_ } | Where-Object { $_ })
    $shared = @($all | Where-Object { $_.type -eq 'shared' }) | Sort-Object createdDateTime -Descending | Select-Object -First 1
    $published = @($all | Where-Object { $_.type -and $_.type -ne 'shared' }) | Sort-Object createdDateTime -Descending | Select-Object -First 1
    if (-not $shared -and -not $published) { $shared = $all | Select-Object -First 1 }
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

# Lab Builder config of a code agent (agenticAppId, agentBlueprintId, agentRegistrationId), or $null.
function Get-DemoAgentConfig($Locale, [string]$Prefix, $AgentDef) {
    $cn = [string]$Locale.agents[$AgentDef.key].codeName
    if (-not $cn) { return $null }
    $f = Join-Path $script:DemoRepoRoot "generated\$Prefix\$cn\a365.generated.config.json"
    if (Test-Path -LiteralPath $f) { return (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json) }
    return $null
}
