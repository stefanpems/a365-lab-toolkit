#requires -Version 7.0
<#
.SYNOPSIS
  READ-ONLY. Produce a consistent dashboard of the state of an Agent 365 lab run identified by name.

.DESCRIPTION
  Given a lab name (the solution prefix, e.g. `a09091`), this script discovers the SIGNIFICANT objects
  the Lab Builder can create for that run, checks whether each one actually exists in Azure / Entra /
  Microsoft 365, reports a status where a status is meaningful, and renders a deterministic Markdown
  dashboard (fixed table structure, coloured status emoji) plus a machine-readable `state.json`.

  It performs NO mutations — only `az ... list/show/exists` and Microsoft Graph GET calls.

  Object types reported (chosen because their state is meaningful — supporting/detail resources such as
  NICs, disks, Container Apps environments, ACRs, Log Analytics workspaces, user-assigned identities and
  the individual MCP proxy apps are intentionally NOT listed as rows; they are covered by their resource
  group):
    Web UI        - the UI resource group, the Static Web App (+ its URL), the SPA app registration.
    Custom MCP    - the MCP resource group, the anon + auth container apps (running status + FQDN), the
                    ext_<Name>Anon / ext_<Name>Auth registration apps and the auth resource app, plus a
                    best-effort Power Platform connector count.
    Agents        - per agent: the (isolated) resource group, the compute (ACA container app running
                    status / FH Foundry account provisioning state / FD prompt-agent note), the blueprint
                    app and the identity app (the Entra Agent ID components).
    Shared Foundry- for solution.foundry create-shared: the <prefix>-foundry-rg + its Cognitive Services
                    account provisioning state.
    DW instances  - for ACA-DW / FH-DW: the agent-user instances (by Frontier / Agent 365 license), each
                    with its accountEnabled flag and the licenses assigned to it.

  Expected objects come from the run's deployment plan when available (generated/<prefix>/
  a365-deployment-plan.json, or -PlanPath, or the repo-root plan if its prefix matches); otherwise the
  agent set is reconstructed from the cloud (blueprint apps named "<prefix>-<FRAMEWORK>-<HOSTING>-<IDENTITY>[ Blueprint]").

.PARAMETER LabName
  The lab name / solution prefix (e.g. `a09091`).

.PARAMETER Subscription
  Target subscription id. Pins the az context.

.PARAMETER TenantId
  Expected tenant id. Aborts if the signed-in az context is a different tenant (guards the shared,
  concurrently-flipping az context).

.PARAMETER PlanPath
  Optional explicit path to the run's a365-deployment-plan.json. Auto-located when omitted.

.PARAMETER OutDir
  Optional output directory for state.json + report.md. Defaults to
  generated/lab-reporter/<LabName>-<timestamp>/.

.EXAMPLE
  pwsh -File .\Get-LabState.ps1 -LabName a09091 -Subscription <sub> -TenantId <tenant>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LabName,
    [Parameter(Mandatory)][string]$Subscription,
    [string]$TenantId,
    [string]$PlanPath,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$prefix = ($LabName -replace "['`"]", '').Trim()
if ([string]::IsNullOrWhiteSpace($prefix)) { throw "LabName is required." }
$mcpSlug = ($prefix -replace '[^A-Za-z0-9]', '').ToLower()

# ---------------------------------------------------------------------------
# Context: pin the subscription and verify the tenant.
# ---------------------------------------------------------------------------
az account set --subscription $Subscription | Out-Null
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' first." }
if ($TenantId -and $ctx.tenantId -ne $TenantId) {
    throw "az context tenant '$($ctx.tenantId)' != -TenantId '$TenantId'. Re-pin the context and retry."
}
$sub = $ctx.id
$signedIn = $ctx.user.name
Write-Host "Lab state report for '$prefix' — tenant $($ctx.tenantId), subscription $sub (as $signedIn)" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Helpers (read-only; mirror the escaping-safe patterns used by the cleanup discovery).
# ---------------------------------------------------------------------------
function Invoke-AzJson {
    param([string[]]$AzArgs)
    $out = az @AzArgs 2>$null
    if (-not $out) { return $null }
    try { return (($out -join "`n") | ConvertFrom-Json) } catch { return $null }
}
function Get-GraphFiltered {
    # Server-side $filter, URL-encoded as the ONLY query parameter (az.cmd corrupts '&'/quotes/parens).
    param([string]$Entity, [string]$FilterExpr, [string[]]$Headers, [switch]$Beta)
    $base = if ($Beta) { 'https://graph.microsoft.com/beta/' } else { 'https://graph.microsoft.com/v1.0/' }
    $url = "$base$Entity" + '?$filter=' + [uri]::EscapeDataString($FilterExpr)
    $azArgs = @('rest', '--method', 'GET', '--url', $url, '-o', 'json')
    foreach ($h in $Headers) { $azArgs += @('--headers', $h) }
    $raw = az @azArgs 2>$null
    if (-not $raw) { return @() }
    try { return @((($raw -join "`n") | ConvertFrom-Json).value) } catch { return @() }
}
function Get-GraphObject {
    param([string]$Url)
    $raw = az rest --method GET --url $Url -o json 2>$null
    if (-not $raw) { return $null }
    try { return (($raw -join "`n") | ConvertFrom-Json) } catch { return $null }
}
function Test-RgExists {
    param([string]$Rg)
    if ([string]::IsNullOrWhiteSpace($Rg)) { return $false }
    return (az group exists -n $Rg --subscription $sub 2>$null) -eq 'true'
}
function Get-RgTypes {
    param([string]$Rg)
    $res = Invoke-AzJson @('resource', 'list', '-g', $Rg, '--subscription', $sub, '--query', '[].type', '-o', 'json')
    if (-not $res) { return @() }
    return @(@($res) | ForEach-Object { ($_ -split '/')[-1] } | Sort-Object -Unique)
}
# subscribedSkus map (skuId -> partNumber) for license labelling.
$script:SkuMap = $null
function Get-SkuMap {
    if ($null -ne $script:SkuMap) { return $script:SkuMap }
    $script:SkuMap = @{}
    $skus = (Get-GraphObject 'https://graph.microsoft.com/v1.0/subscribedSkus').value
    foreach ($s in @($skus)) { if ($s.skuId) { $script:SkuMap[$s.skuId] = $s.skuPartNumber } }
    return $script:SkuMap
}
function Format-Licenses {
    param($AssignedLicenses)
    $map = Get-SkuMap
    $parts = @()
    foreach ($l in @($AssignedLicenses)) { if ($l.skuId) { $parts += ($map[$l.skuId] ?? $l.skuId) } }
    return , $parts
}
function Get-StatusEmoji {
    param([string]$State)
    switch ($State) {
        'ok' { '✅'; break }
        'warn' { '🟡'; break }
        'fail' { '❌'; break }
        'na' { '⚪'; break }
        'info' { '🔵'; break }
        default { '⚪' }
    }
}
# Markdown-escape a cell (avoid breaking the table on a literal pipe).
function Escape-Cell { param([string]$Text) if ($null -eq $Text) { return '' } return ($Text -replace '\|', '\|' -replace '\r?\n', ' ').Trim() }

# ---------------------------------------------------------------------------
# Graph preflight — every category has an Entra component. If Graph is blocked
# (CAE / Conditional Access), the scans would silently under-report.
# ---------------------------------------------------------------------------
$graphProbe = az rest --method GET --url 'https://graph.microsoft.com/v1.0/organization?$select=id' -o json 2>&1
if ($LASTEXITCODE -ne 0) {
    throw @"
Microsoft Graph is not accessible from the current az context (az exit $LASTEXITCODE).
This is usually a Conditional Access / CAE challenge. Re-authenticate and re-run:
  az login --tenant $($ctx.tenantId) --scope https://graph.microsoft.com/.default
Detail: $graphProbe
"@
}

# ---------------------------------------------------------------------------
# Locate + load the run's deployment plan (authoritative "expected" objects).
# ---------------------------------------------------------------------------
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
$plan = $null
$planSource = 'cloud discovery only (no plan found)'
$candidatePlans = @()
if ($PlanPath) { $candidatePlans += $PlanPath }
$candidatePlans += (Join-Path $repoRoot 'generated' $prefix 'a365-deployment-plan.json')
$candidatePlans += (Join-Path $repoRoot 'a365-deployment-plan.json')
foreach ($p in $candidatePlans) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    try { $cand = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json } catch { continue }
    if ($cand.solution.prefix -eq $prefix) { $plan = $cand; $planSource = $p; break }
}
Write-Host "Plan source: $planSource" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Determine the agent set: from the plan when available, else from blueprint apps.
# ---------------------------------------------------------------------------
$agents = @()
if ($plan) {
    foreach ($a in @($plan.agents)) {
        $agents += [pscustomobject]@{
            type       = $a.type
            name       = $a.name
            rg         = $a.resourceGroup
            aiKind     = $a.ai.kind
            blueprint  = $a.displayNames.blueprint
            identity   = $a.displayNames.identity
        }
    }
}
else {
    # No plan: reconstruct the agent set from any available evidence (union, de-duplicated by name):
    #   (1) Entra blueprint apps "<prefix>-<FRAMEWORK>-<HOSTING>-<IDENTITY>[ Blueprint]" (finds ACA — FH/FD have none);
    #   (2) local scaffold folders generated/<prefix>-* (flat) and generated/<prefix>/<prefix>-* (nested);
    #   (3) agent resource groups <prefix>-<FRAMEWORK>-<HOSTING>-<IDENTITY>-rg.
    # Names carry a FIXED framework segment (e.g. contoso-MAF-ACA-OBO); DW blueprint apps have NO
    # " Blueprint" suffix, so the strip below is a no-op for them and the bare name still matches.
    $found = @{}
    $reVariant = '(?i)^' + [regex]::Escape($prefix) + '-([A-Za-z0-9]{2,})-(ACA|FH|FD)-(OBO|S2S|DW)$'
    foreach ($app in (Get-GraphFiltered 'applications' "startswith(displayName,'$prefix')")) {
        $nm = $app.displayName -replace ' Blueprint$', ''
        if ($nm -match $reVariant) { $found[$nm] = $true }
    }
    foreach ($gr in @((Join-Path $repoRoot 'generated'), (Join-Path $repoRoot 'generated' $prefix))) {
        if (-not (Test-Path -LiteralPath $gr)) { continue }
        foreach ($d in (Get-ChildItem -LiteralPath $gr -Directory -ErrorAction SilentlyContinue)) {
            if ($d.Name -match $reVariant) { $found[$d.Name] = $true }
        }
    }
    foreach ($rgn in @(Invoke-AzJson @('group', 'list', '--subscription', $sub, '--query', '[].name', '-o', 'json'))) {
        if ($rgn -match ('(?i)^' + [regex]::Escape($prefix) + '-([A-Za-z0-9]{2,})-(ACA|FH|FD)-(OBO|S2S|DW)-rg$')) { $found[($rgn -replace '(?i)-rg$', '')] = $true }
    }
    foreach ($nm in ($found.Keys | Sort-Object)) {
        # type = hosting-identity (drop the <prefix>-<framework> lead); classify AI kind by hosting.
        $t = if ($nm -match $reVariant) { "$($matches[2])-$($matches[3])".ToUpper() } else { ($nm -replace "(?i)^$([regex]::Escape($prefix))-", '').ToUpper() }
        $aik = switch -Regex ($t) { '^ACA' { 'azure-openai' } default { 'foundry' } }
        $bp  = if ($t -like '*-DW') { $nm } else { "$nm Blueprint" }  # DW blueprint has no " Blueprint" suffix
        $agents += [pscustomobject]@{ type = $t; name = $nm; rg = "$nm-rg"; aiKind = $aik; blueprint = $bp; identity = "$nm Identity" }
    }
}

# Pre-load Entra apps + service principals once for existence checks. Custom-MCP objects are named
# ext_<prefix>* (NOT <prefix>*), so load those separately. The agent "Identity" is a service principal
# (only ACA-OBO/S2S) and the blueprint exists as both an app and an SP, so service principals are loaded too.
$allPrefixApps = @(Get-GraphFiltered 'applications' "startswith(displayName,'$prefix')")
$allPrefixSps = @(Get-GraphFiltered 'servicePrincipals' "startswith(displayName,'$prefix')")
$allExtApps = @(Get-GraphFiltered 'applications' "startswith(displayName,'ext_$prefix')")
function Test-EntraApp { param([string]$DisplayName) return @($allPrefixApps | Where-Object { $_.displayName -eq $DisplayName }) }
function Find-ExtApp { param([string]$Pattern) return @($allExtApps | Where-Object { $_.displayName -like $Pattern }) }
function Find-AgentEntra { param([string]$AgentName) return @(@($allPrefixApps + $allPrefixSps) | Where-Object { $_.displayName -like "$AgentName Blueprint*" -or $_.displayName -like "$AgentName Identity*" }) }

# Durable per-agent blueprint reference (NEVER name-based — agent names can be custom).
# The run records, under generated/<prefix>/<agentName>/, either the blueprint's Entra appId directly or
# the agent's instance-identity client id (from which the blueprint is resolved via Graph):
#   ACA          -> a365.generated.config.json .agentBlueprintId            (blueprint appId)
#   FH-DW        -> .azure/<env>/.env AGENT_IDENTITY_BLUEPRINT_ID           (blueprint appId)
#   FH-OBO/S2S   -> .azure/<env>/.env AGENT_<NAME>_INSTANCE_IDENTITY_CLIENT_ID  (agentIdentity appId)
# FD (declarative) and MCS (Copilot Studio / Dataverse) record no Entra blueprint reference.
function Get-RecordedBlueprintRef {
    param([string]$AgentName)
    $ref = [pscustomobject]@{ blueprintId = $null; identityClientId = $null }
    if ([string]::IsNullOrWhiteSpace($AgentName)) { return $ref }
    $base = Join-Path $repoRoot 'generated' $prefix $AgentName
    if (-not (Test-Path -LiteralPath $base)) { return $ref }
    $cfg = Join-Path $base 'a365.generated.config.json'
    if (Test-Path -LiteralPath $cfg) {
        try { $j = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json; if ($j.agentBlueprintId) { $ref.blueprintId = "$($j.agentBlueprintId)"; return $ref } } catch {}
    }
    $azureDir = Join-Path $base '.azure'
    if (Test-Path -LiteralPath $azureDir) {
        foreach ($envFile in (Get-ChildItem -LiteralPath $azureDir -Recurse -Filter '.env' -File -ErrorAction SilentlyContinue)) {
            $lines = Get-Content -LiteralPath $envFile.FullName
            foreach ($line in $lines) {
                if ($line -match '^\s*AGENT_IDENTITY_BLUEPRINT_ID\s*=\s*"?([0-9a-fA-F-]{36})"?') { $ref.blueprintId = $matches[1]; return $ref }
            }
            foreach ($line in $lines) {
                if ($line -match '^\s*AGENT_.*_INSTANCE_IDENTITY_CLIENT_ID\s*=\s*"?([0-9a-fA-F-]{36})"?') { $ref.identityClientId = $matches[1] }
            }
        }
    }
    return $ref
}
# Resolve a blueprint appId to its Entra application object (beta — agentIdentityBlueprint is a beta type).
function Resolve-BlueprintApp {
    param([string]$AppId)
    if ([string]::IsNullOrWhiteSpace($AppId)) { return $null }
    return @(Get-GraphFiltered 'applications' "appId eq '$AppId'" -Beta)[0]
}
# Blueprint apps tagged for this lab (tag-based Entra augmentation, name-independent).
$labTaggedBlueprints = @(Get-GraphFiltered 'applications' "tags/any(t:t eq 'a365lab:$prefix')" -Beta |
    Where-Object { "$($_.'@odata.type')" -match 'agentIdentityBlueprint' })
# Accumulates every blueprint appId proven to belong to this lab (recorded + tagged); used to scope DW instances.
$labBlueprintIds = @{}
foreach ($b in $labTaggedBlueprints) { if ($b.appId) { $labBlueprintIds[$b.appId.ToLower()] = $true } }
# agentIdentity service principals tagged for this lab. Some blueprint apps (e.g. ACA-DW) carry no
# a365lab tag while their linked identity does; index the blueprint ids those tagged identities point to
# so the [a365lab] marker can fall back to the identity's tag.
$labTaggedIdentityBpIds = @{}
foreach ($sp in @(Get-GraphFiltered 'servicePrincipals' "tags/any(t:t eq 'a365lab:$prefix')" -Beta)) {
    if ($sp.agentIdentityBlueprintId) { $labTaggedIdentityBpIds["$($sp.agentIdentityBlueprintId)".ToLower()] = $true }
}

# Rows accumulator for the resource-style sections (uniform schema).
$sections = [ordered]@{ webui = @(); mcp = @(); foundry = @(); aoai = @() }
function Add-ResRow {
    param([string]$Section, [string]$Object, [string]$Layer, [string]$Name, [bool]$Exists, [string]$State, [string]$Details)
    $script:sections[$Section] += [pscustomobject]@{
        object = $Object; layer = $Layer; name = $Name; exists = $Exists; state = $State; details = $Details
    }
}

# Shared Foundry (solution.foundry create-shared) resource group, if any — used by both the shared
# Foundry section and the FH agent compute cell. Computed once to avoid nested if-expressions.
$sharedFoundry = $false
$sharedFoundryRg = $null
if ($plan -and $plan.solution.foundry -and $plan.solution.foundry.mode -eq 'create-shared') {
    $sharedFoundry = $true
    $sharedFoundryRg = if ($plan.solution.foundry.resourceGroup) { $plan.solution.foundry.resourceGroup } else { "$prefix-foundry-rg" }
}

# Shared Azure OpenAI (solution.azureOpenAI create-shared) resource group, if any — lab-owned, so it is
# discovered/reported like the shared Foundry RG above.
$sharedAoai = $false
$sharedAoaiRg = $null
if ($plan -and $plan.solution.azureOpenAI -and $plan.solution.azureOpenAI.mode -eq 'create-shared') {
    $sharedAoai = $true
    $sharedAoaiRg = if ($plan.solution.azureOpenAI.resourceGroup) { $plan.solution.azureOpenAI.resourceGroup } else { "$prefix-aoai-rg" }
}

# ---------------------------------------------------------------------------
# 1. Web UI.
# ---------------------------------------------------------------------------
$uiPlanned = (-not $plan) -or ($plan.ui.mode -in @('create', 'attach'))
if ($uiPlanned) {
    $uiRg = "$prefix-ui-rg"
    $uiRgExists = Test-RgExists $uiRg
    Add-ResRow 'webui' 'Resource group' 'Azure' $uiRg $uiRgExists ($(if ($uiRgExists) { 'ok' } else { 'fail' })) `
        ($(if ($uiRgExists) { (Get-RgTypes $uiRg) -join ', ' } else { 'not found' }))
    # Static Web App by name contains prefix + 'ui'.
    $swa = @(Invoke-AzJson @('staticwebapp', 'list', '--subscription', $sub, '-o', 'json')) |
    Where-Object { $_.name -match [regex]::Escape($prefix) -and $_.name -match '(?i)ui' }
    if ($swa.Count -gt 0) {
        foreach ($s in $swa) {
            Add-ResRow 'webui' 'Static Web App' 'Azure' $s.name $true 'ok' "https://$($s.defaultHostname)"
        }
    }
    else {
        Add-ResRow 'webui' 'Static Web App' 'Azure' "$prefix-ui" $false 'fail' 'not found'
    }
    # SPA app registration.
    $spa = Test-EntraApp "$prefix-ui-spa"
    if (@($spa).Count -gt 0) {
        Add-ResRow 'webui' 'SPA app registration' 'Entra' "$prefix-ui-spa" $true 'ok' "appId $(@($spa)[0].appId)"
    }
    else {
        Add-ResRow 'webui' 'SPA app registration' 'Entra' "$prefix-ui-spa" $false 'fail' 'not found'
    }
}

# ---------------------------------------------------------------------------
# 2. Custom MCP.
# ---------------------------------------------------------------------------
$mcpPlanned = (-not $plan) -or ($plan.customMcp.enabled)
if ($mcpPlanned) {
    $mcpRg = if ($plan.customMcp.resourceGroup) { $plan.customMcp.resourceGroup } else { "$prefix-mcp-rg" }
    $mcpRgExists = Test-RgExists $mcpRg
    Add-ResRow 'mcp' 'Resource group' 'Azure' $mcpRg $mcpRgExists ($(if ($mcpRgExists) { 'ok' } else { 'fail' })) `
        ($(if ($mcpRgExists) { (Get-RgTypes $mcpRg) -join ', ' } else { 'not found' }))
    # Container apps in the MCP RG (anon / auth).
    $cas = @()
    if ($mcpRgExists) { $cas = @(Invoke-AzJson @('containerapp', 'list', '-g', $mcpRg, '--subscription', $sub, '-o', 'json')) }
    foreach ($role in @('anon', 'auth')) {
        $ca = $cas | Where-Object { $_.name -match "(?i)$role" } | Select-Object -First 1
        if ($ca) {
            $run = $ca.properties.runningStatus
            $fqdn = $ca.properties.configuration.ingress.fqdn
            $st = if ($run -match '(?i)running') { 'ok' } elseif ($run) { 'warn' } else { 'warn' }
            Add-ResRow 'mcp' "Container app ($role)" 'Azure' $ca.name $true $st "runningStatus=$run; https://$fqdn"
        }
        else {
            $want = ($plan.customMcp.servers -contains $role) -or (-not $plan)
            Add-ResRow 'mcp' "Container app ($role)" 'Azure' "$mcpSlug-mcp-$role-ca" $false ($(if ($want) { 'fail' } else { 'na' })) `
                ($(if ($want) { 'not found' } else { 'not in this lab' }))
        }
    }
    # Registration apps: the registered BYO servers appear in Entra as `ext_<Name>Anon - BYO` /
    # `ext_<Name>Auth - BYO`, plus the EntraOAuth auth resource app `ext_<Name>Auth-Resource`.
    foreach ($reg in @(
            @{ pat = "ext_${prefix}Anon*BYO*"; nm = "ext_${prefix}Anon"; l = 'anon registration'; want = ((-not $plan) -or ($plan.customMcp.servers -contains 'anon')) },
            @{ pat = "ext_${prefix}Auth*BYO*"; nm = "ext_${prefix}Auth"; l = 'auth registration'; want = ((-not $plan) -or ($plan.customMcp.servers -contains 'auth')) },
            @{ pat = "ext_${prefix}Auth-Resource"; nm = "ext_${prefix}Auth-Resource"; l = 'auth resource app'; want = ((-not $plan) -or ($plan.customMcp.servers -contains 'auth')) }
        )) {
        $app = Find-ExtApp $reg.pat
        if (@($app).Count -gt 0) {
            Add-ResRow 'mcp' $reg.l 'Entra / Agent 365' (@($app)[0].displayName) $true 'ok' "appId $(@($app)[0].appId)"
        }
        else {
            Add-ResRow 'mcp' $reg.l 'Entra / Agent 365' $reg.nm $false ($(if ($reg.want) { 'fail' } else { 'na' })) ($(if ($reg.want) { 'not found (not registered/approved yet)' } else { 'not in this lab' }))
        }
    }
    # Supporting proxy apps (A365Proxy / PublicClients / RemoteProxy) — summarized, not individual rows.
    $proxyApps = @($allExtApps | Where-Object { $_.displayName -match "(?i)(A365Proxy|PublicCl|RemotePr)" })
    Add-ResRow 'mcp' 'Proxy apps (supporting)' 'Entra' "ext_${prefix}* proxy/public-clients" ($proxyApps.Count -gt 0) `
        ($(if ($proxyApps.Count -gt 0) { 'info' } else { 'na' })) "$($proxyApps.Count) proxy app(s) present"
    # Power Platform connectors — best-effort count.
    $connCount = 0
    try {
        $ppResource = 'https://service.powerapps.com/'
        $envsRaw = az rest --method get --url 'https://api.powerapps.com/providers/Microsoft.PowerApps/environments?api-version=2016-11-01' --resource $ppResource --query 'value[].name' -o tsv 2>$null
        foreach ($envId in @($envsRaw)) {
            if ([string]::IsNullOrWhiteSpace($envId)) { continue }
            $listUrl = "https://api.powerapps.com/providers/Microsoft.PowerApps/apis?api-version=2016-11-01&`$filter=environment eq '$envId'"
            $connsText = ((az rest --method get --url $listUrl --resource $ppResource -o json 2>$null) -join "`n").Trim()
            if ([string]::IsNullOrWhiteSpace($connsText) -or ($connsText[0] -ne '{' -and $connsText[0] -ne '[')) { continue }
            $parsed = $null; try { $parsed = $connsText | ConvertFrom-Json } catch { continue }
            $connList = if ($null -ne $parsed.value) { $parsed.value } else { $parsed }
            foreach ($c in @($connList)) {
                $dn = $c.properties.displayName
                if ($dn -and $dn.StartsWith("ext_$prefix", [System.StringComparison]::OrdinalIgnoreCase)) { $connCount++ }
            }
        }
        Add-ResRow 'mcp' 'Power Platform connectors' 'Power Platform' "ext_${prefix}*" ($connCount -gt 0) `
            'info' ($(if ($connCount -gt 0) { "$connCount connector(s) found" } else { "0 listed — BYO connectors usually live in a hidden 'Compliant Container' environment the API does not enumerate; verify at make.powerapps.com/connectionsMcp" }))
    }
    catch {
        Add-ResRow 'mcp' 'Power Platform connectors' 'Power Platform' "ext_${prefix}*" $false 'info' 'not queried (Power Platform access unavailable)'
    }
}

# ---------------------------------------------------------------------------
# 4. Shared Foundry (solution.foundry create-shared).
# ---------------------------------------------------------------------------
if ($sharedFoundry) {
    $fRg = $sharedFoundryRg
    $fRgExists = Test-RgExists $fRg
    Add-ResRow 'foundry' 'Resource group' 'Azure' $fRg $fRgExists ($(if ($fRgExists) { 'ok' } else { 'fail' })) `
        ($(if ($fRgExists) { (Get-RgTypes $fRg) -join ', ' } else { 'not found' }))
    if ($fRgExists) {
        $accs = @(Invoke-AzJson @('cognitiveservices', 'account', 'list', '-g', $fRg, '--subscription', $sub, '-o', 'json'))
        if ($accs.Count -gt 0) {
            foreach ($ac in $accs) {
                $ps = $ac.properties.provisioningState
                $st = if ($ps -match '(?i)succeeded') { 'ok' } elseif ($ps) { 'warn' } else { 'warn' }
                Add-ResRow 'foundry' 'Foundry account' 'Azure' $ac.name $true $st "provisioningState=$ps; kind=$($ac.kind)"
            }
        }
        else {
            Add-ResRow 'foundry' 'Foundry account' 'Azure' '(none)' $false 'fail' 'no Cognitive Services account in the RG'
        }
    }
}

# ---------------------------------------------------------------------------
# 4b. Shared Azure OpenAI (solution.azureOpenAI create-shared).
# ---------------------------------------------------------------------------
if ($sharedAoai) {
    $oRg = $sharedAoaiRg
    $oRgExists = Test-RgExists $oRg
    Add-ResRow 'aoai' 'Resource group' 'Azure' $oRg $oRgExists ($(if ($oRgExists) { 'ok' } else { 'fail' })) `
        ($(if ($oRgExists) { (Get-RgTypes $oRg) -join ', ' } else { 'not found' }))
    if ($oRgExists) {
        $oAccs = @(Invoke-AzJson @('cognitiveservices', 'account', 'list', '-g', $oRg, '--subscription', $sub, '-o', 'json'))
        if ($oAccs.Count -gt 0) {
            foreach ($ac in $oAccs) {
                $ps = $ac.properties.provisioningState
                $st = if ($ps -match '(?i)succeeded') { 'ok' } elseif ($ps) { 'warn' } else { 'warn' }
                Add-ResRow 'aoai' 'Azure OpenAI account' 'Azure' $ac.name $true $st "provisioningState=$ps; kind=$($ac.kind)"
            }
        }
        else {
            Add-ResRow 'aoai' 'Azure OpenAI account' 'Azure' '(none)' $false 'fail' 'no Cognitive Services account in the RG'
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Agents (per-agent row; compute depends on hosting).
# ---------------------------------------------------------------------------
$agentRows = @()
foreach ($ag in $agents) {
    $rgExists = Test-RgExists $ag.rg
    $rgCell = if ($rgExists) { @{ e = 'ok'; d = $ag.rg } } else { @{ e = 'na'; d = "$($ag.rg) (none)" } }

    # Compute cell.
    $computeState = 'na'; $computeDetail = ''
    if ($ag.type -like 'ACA-*') {
        if ($rgExists) {
            $ca = @(Invoke-AzJson @('containerapp', 'list', '-g', $ag.rg, '--subscription', $sub, '-o', 'json')) | Select-Object -First 1
            if ($ca) {
                $run = $ca.properties.runningStatus
                $computeState = if ($run -match '(?i)running') { 'ok' } elseif ($run) { 'warn' } else { 'warn' }
                $computeDetail = "ACA $($ca.name): runningStatus=$run"
            }
            else { $computeState = 'fail'; $computeDetail = 'ACA container app: none in RG' }
        }
        else { $computeState = 'fail'; $computeDetail = 'RG missing' }
    }
    elseif ($ag.type -like 'FH-*') {
        # FH compute = Cognitive Services account (isolated RG) or the shared create-shared account.
        $searchRg = if ($rgExists) { $ag.rg } elseif ($sharedFoundry) { $sharedFoundryRg } else { $null }
        if ($searchRg -and (Test-RgExists $searchRg)) {
            $ac = @(Invoke-AzJson @('cognitiveservices', 'account', 'list', '-g', $searchRg, '--subscription', $sub, '-o', 'json')) | Select-Object -First 1
            if ($ac) {
                $ps = $ac.properties.provisioningState
                $computeState = if ($ps -match '(?i)succeeded') { 'ok' } elseif ($ps) { 'warn' } else { 'warn' }
                $computeDetail = "Foundry $($ac.name): provisioningState=$ps" + ($(if (-not $rgExists) { ' (shared)' } else { '' }))
            }
            else { $computeState = 'fail'; $computeDetail = 'Foundry account: none' }
        }
        else { $computeState = 'fail'; $computeDetail = 'Foundry RG missing' }
    }
    elseif ($ag.type -like 'FD-*') {
        $computeState = 'info'; $computeDetail = 'prompt agent (shared Foundry project — no dedicated Azure compute)'
    }
    elseif ($ag.type -like 'MCS-*') {
        $computeState = 'na'; $computeDetail = 'Copilot Studio (Dataverse) — not queryable via Azure/Graph'
    }

    # Entra Agent ID: every ACA/FH agent has an agentIdentityBlueprint application. Its durable Entra
    # appId is recorded in generated/<prefix>/<agent>/ (never inferred from the — possibly custom — name).
    # Resolve that appId in Entra (beta) and validate the a365lab tag. FD agents are declarative (defined
    # in the Foundry project, no Entra blueprint); MCS agents live in Copilot Studio (Dataverse).
    $ref = Get-RecordedBlueprintRef $ag.name
    $bpId = $ref.blueprintId
    if (-not $bpId -and $ref.identityClientId) {
        $idsp = @(Get-GraphFiltered 'servicePrincipals' "appId eq '$($ref.identityClientId)'" -Beta)[0]
        if ($idsp -and $idsp.agentIdentityBlueprintId) { $bpId = "$($idsp.agentIdentityBlueprintId)" }
    }
    $bpApp = Resolve-BlueprintApp $bpId
    if ($bpApp) {
        $labBlueprintIds[$bpId.ToLower()] = $true
        $tagged = (@($bpApp.tags) -contains "a365lab:$prefix") -or $labTaggedIdentityBpIds.ContainsKey($bpId.ToLower())
        $entraState = 'ok'
        $entraDetail = "blueprint '$($bpApp.displayName)' (appId $bpId)" + ($(if ($tagged) { ' [a365lab]' } else { '' }))
    }
    elseif ($bpId) {
        $entraState = 'fail'; $entraDetail = "recorded blueprint appId $bpId not found in Entra"
    }
    elseif ($ag.type -like 'FD-*') {
        $entraState = 'info'; $entraDetail = 'declarative agent — defined in the Foundry project (no Entra blueprint app)'
    }
    elseif ($ag.type -like 'MCS-*') {
        $entraState = 'na'; $entraDetail = 'Copilot Studio agent — Dataverse solution (not an Entra/Azure object)'
    }
    else {
        # ACA/FH with no recorded id (older run) — last-resort tag/name lookup, still not trusting the name alone.
        $entra = Find-AgentEntra $ag.name
        if (@($entra).Count -gt 0) { $entraState = 'ok'; $entraDetail = ((@($entra) | ForEach-Object { $_.displayName } | Select-Object -Unique) -join ', ') }
        else { $entraState = 'fail'; $entraDetail = 'blueprint not found (no recorded id)' }
    }

    # Overall = worst meaningful state; if only info/na (FD), fall back to the compute state.
    $states = @($rgCell.e, $computeState, $entraState) | Where-Object { $_ -in @('ok', 'warn', 'fail') }
    $overall = if ($states -contains 'fail') { 'fail' } elseif ($states -contains 'warn') { 'warn' } elseif ($states -contains 'ok') { 'ok' } else { $computeState }

    $agentRows += [pscustomobject]@{
        name = $ag.name; type = $ag.type
        rgState = $rgCell.e; rgDetail = $rgCell.d
        computeState = $computeState; computeDetail = $computeDetail
        entraState = $entraState; entraDetail = $entraDetail
        overall = $overall
    }
}

# ---------------------------------------------------------------------------
# 5. Digital Worker instances + licenses (agent users holding a Frontier / Agent 365 license).
#    An instance name is arbitrary (custom at hire time), so scope by the DURABLE link only:
#    user.identityParentId -> agentIdentity SP -> agentIdentityBlueprintId ∈ this lab's blueprint set.
# ---------------------------------------------------------------------------
$dwTypes = @($agents | Where-Object { $_.type -like '*-DW' } | ForEach-Object { $_.type })
$dwInstances = @()
if ($dwTypes.Count -gt 0) {
    $map = Get-SkuMap
    $agentSkuIds = @()
    foreach ($kv in $map.GetEnumerator()) { if ($kv.Value -match '(?i)(FRONTIER|AGENT[_ ]?365)') { $agentSkuIds += $kv.Key } }
    $seen = @{}
    $bpCache = @{}
    foreach ($skuId in $agentSkuIds) {
        foreach ($u in (Get-GraphFiltered 'users' "assignedLicenses/any(x:x/skuId eq $skuId)" @('ConsistencyLevel=eventual') -Beta)) {
            if (-not $u.id -or $seen.ContainsKey($u.id)) { continue }
            $seen[$u.id] = $true
            # Full object via the reliable $filter list pattern (single-object /beta GETs are flaky on this az.cmd).
            $full = @(Get-GraphFiltered 'users' "id eq '$($u.id)'" -Beta)[0]
            if (-not $full) { $full = $u }
            $lic = Format-Licenses $full.assignedLicenses
            # Resolve the durable chain: parent agentIdentity SP -> its blueprint appId.
            $bpId = $null
            $parent = $full.identityParentId
            if ($parent) {
                if (-not $bpCache.ContainsKey($parent)) {
                    $sp = @(Get-GraphFiltered 'servicePrincipals' "id eq '$parent'" -Beta)[0]
                    $bpCache[$parent] = if ($sp) { $sp.agentIdentityBlueprintId } else { $null }
                }
                $bpId = $bpCache[$parent]
            }
            $matchesLab = [bool]($bpId -and $labBlueprintIds.ContainsKey("$bpId".ToLower()))
            $dwInstances += [pscustomobject]@{
                displayName       = $full.displayName
                userPrincipalName = $full.userPrincipalName
                accountEnabled    = [bool]$full.accountEnabled
                licenses          = @($lic)
                blueprintId       = $bpId
                matchesLab        = $matchesLab
            }
        }
    }
}
# Lab-scoped instances first (blueprint-linked), then other agent-license holders as candidates.
$dwLab = @($dwInstances | Where-Object { $_.matchesLab })
$dwOther = @($dwInstances | Where-Object { -not $_.matchesLab })

# ---------------------------------------------------------------------------
# Entra recycle-bin leftovers matching the prefix (informational).
# ---------------------------------------------------------------------------
$recycle = @()
foreach ($seg in @('microsoft.graph.application', 'microsoft.graph.servicePrincipal', 'microsoft.graph.user')) {
    $del = Get-GraphObject "https://graph.microsoft.com/v1.0/directory/deletedItems/$seg"
    foreach ($d in @($del.value)) {
        if (-not $d.displayName) { continue }
        if (($d.displayName -notmatch [regex]::Escape($prefix)) -and ($d.displayName -notmatch "(?i)^ext_$([regex]::Escape($prefix))")) { continue }
        $recycle += [pscustomobject]@{ kind = ($seg -replace 'microsoft.graph.', ''); displayName = $d.displayName; deleted = $d.deletedDateTime }
    }
}

# ---------------------------------------------------------------------------
# Build the state model + render the deterministic Markdown dashboard.
# ---------------------------------------------------------------------------
$nowUtc = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'
if (-not $OutDir) {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $OutDir = Join-Path $repoRoot 'generated' 'lab-reporter' "$prefix-$stamp"
}
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

# Acronyms used in this report (all and only the ones that appear): the agent taxonomy is
# <prefix>-<FRAMEWORK>-<HOSTING>-<IDENTITY> (e.g. MAF-ACA-OBO). Kept in the state model so the HTML
# renderer reuses the exact same definitions (no drift).
$glossary = [ordered]@{
    MAF  = 'Microsoft Agent Framework — the framework the sample agents are currently built with.'
    ACA  = 'Azure Container Apps — agent hosting on the managed container platform.'
    FH   = 'Foundry Hosted — agent hosting managed by Azure AI Foundry.'
    FD   = 'Foundry Declarative — a prompt (declarative) agent defined in Azure AI Foundry.'
    MCS  = 'Microsoft Copilot Studio — low-code agent platform; agents are Dataverse solutions.'
    OBO  = 'On-Behalf-Of — the agent acts using the signed-in user''s delegated identity.'
    S2S  = 'Service-to-Service — the agent acts with its own application identity.'
    DW   = 'Digital Worker — an AI-teammate agent hired as an agent user (holds a Frontier / Agent 365 license).'
    OH   = 'Old Harness — the legacy Microsoft Copilot Studio agent runtime (MCS-OH).'
    NH   = 'New Harness — the new Microsoft Copilot Studio agent runtime, based on GitHub Copilot (MCS-NH).'
    GHCP = 'GitHub Copilot — the coding-assistant harness the New Harness Copilot Studio agents build on.'
}

$state = [ordered]@{
    labName      = $prefix
    tenantId     = $ctx.tenantId
    subscription = $sub
    generatedUtc = $nowUtc
    planSource   = $planSource
    acronyms     = $glossary
    webui        = $sections.webui
    customMcp    = $sections.mcp
    sharedFoundry = $sections.foundry
    sharedAoai   = $sections.aoai
    agents       = $agentRows
    dwInstances  = @{ lab = $dwLab; other = $dwOther }
    recycleBin   = $recycle
}
Set-Content -LiteralPath (Join-Path $OutDir 'state.json') -Value ($state | ConvertTo-Json -Depth 10) -Encoding utf8

# --- Markdown rendering (fixed structure every run) ---
$sb = New-Object System.Text.StringBuilder
function Emit { param([string]$Line) [void]$sb.AppendLine($Line) }

Emit "# Lab state report — ``$prefix``"
Emit ''
Emit "- **Tenant:** $($ctx.tenantId)"
Emit "- **Subscription:** $sub"
Emit "- **Generated:** $nowUtc"
Emit "- **Plan source:** $planSource"
Emit ''
Emit 'Legend: ✅ present & healthy · 🟡 present, provisioning/degraded · ❌ missing or failed · ⚪ not part of this lab · 🔵 informational'
Emit ''

Emit '## Acronyms'
Emit ''
foreach ($k in $glossary.Keys) { Emit ("- **$k** — " + $glossary[$k]) }
Emit ''

function Emit-ResTable {
    param([string]$Title, $Rows, [string]$EmptyNote)
    Emit "## $Title"
    Emit ''
    if (-not $Rows -or @($Rows).Count -eq 0) { Emit "_$EmptyNote_"; Emit ''; return }
    Emit '| Object | Layer | Name | Exists | Status | Details |'
    Emit '| --- | --- | --- | :--: | :--: | --- |'
    foreach ($r in @($Rows)) {
        $ex = if ($r.exists) { '✅' } else { '❌' }
        $st = Get-StatusEmoji $r.state
        Emit ("| {0} | {1} | ``{2}`` | {3} | {4} | {5} |" -f (Escape-Cell $r.object), (Escape-Cell $r.layer), (Escape-Cell $r.name), $ex, $st, (Escape-Cell $r.details))
    }
    Emit ''
}

Emit-ResTable '1. Web UI' $sections.webui 'No web UI in this lab.'
Emit-ResTable '2. Custom MCP' $sections.mcp 'No custom MCP in this lab.'

# Agents (per-agent row).
Emit '## 3. Agents'
Emit ''
if (@($agentRows).Count -eq 0) {
    Emit '_No agents discovered for this lab._'
    Emit ''
}
else {
    Emit '| Agent | Type | Resource group | Compute | Entra Agent ID | Overall |'
    Emit '| --- | --- | :--: | --- | --- | :--: |'
    foreach ($r in $agentRows) {
        $rg = (Get-StatusEmoji $r.rgState)
        $cp = (Get-StatusEmoji $r.computeState) + ' ' + (Escape-Cell $r.computeDetail)
        $en = (Get-StatusEmoji $r.entraState) + ' ' + (Escape-Cell $r.entraDetail)
        $ov = (Get-StatusEmoji $r.overall)
        Emit ("| ``{0}`` | {1} | {2} | {3} | {4} | {5} |" -f (Escape-Cell $r.name), (Escape-Cell $r.type), $rg, $cp, $en, $ov)
    }
    Emit ''
    Emit '_Entra Agent ID = the agent''s blueprint application (agentIdentityBlueprint), resolved from the durable appId recorded in generated/<lab>/<agent>/ and validated by the a365lab Entra tag ([a365lab]). FD agents are declarative (defined in the Foundry project — no Entra blueprint app); MCS agents live in Copilot Studio (Dataverse). Compute: ACA = container app running status; FH = Foundry account provisioning state; FD = prompt agent (no dedicated Azure compute)._'
    Emit ''
}

if ($sharedFoundry) { Emit-ResTable '4. Shared Foundry (create-shared)' $sections.foundry 'No shared Foundry resources found.' }
if ($sharedAoai) { Emit-ResTable '4b. Shared Azure OpenAI (create-shared)' $sections.aoai 'No shared Azure OpenAI resources found.' }

# DW instances.
if ($dwTypes.Count -gt 0) {
    Emit '## 5. Digital Worker instances & licenses'
    Emit ''
    Emit "DW agents in this lab: $((@($dwTypes) | Sort-Object -Unique) -join ', ')."
    Emit ''
    if (@($dwLab).Count -eq 0) {
        Emit '_No agent-user instances linked to this lab''s blueprints were found. If a DW was published but not yet hired, there are no instances yet._'
        if (@($dwOther).Count -gt 0) { Emit ''; Emit "_(Note: $(@($dwOther).Count) other Frontier / Agent 365 license holder(s) exist in the tenant but are not linked to this lab's blueprints — likely other labs.)_" }
        Emit ''
    }
    else {
        Emit '| Instance (display name) | UPN | Enabled | Licenses |'
        Emit '| --- | --- | :--: | --- |'
        foreach ($i in @($dwLab)) {
            $en = if ($i.accountEnabled) { '✅' } else { '❌' }
            $lic = if (@($i.licenses).Count) { (@($i.licenses) -join '; ') } else { '(none)' }
            Emit ("| {0} | {1} | {2} | {3} |" -f (Escape-Cell $i.displayName), (Escape-Cell $i.userPrincipalName), $en, (Escape-Cell $lic))
        }
        Emit ''
        if (@($dwOther).Count -gt 0) { Emit "_(Plus $(@($dwOther).Count) other Frontier / Agent 365 license holder(s) in the tenant not linked to this lab's blueprints — likely other labs; not listed here.)_"; Emit '' }
    }
}

# Recycle bin.
if (@($recycle).Count -gt 0) {
    Emit '## Entra recycle bin (pending purge)'
    Emit ''
    Emit '| Kind | Display name | Deleted |'
    Emit '| --- | --- | --- |'
    foreach ($r in $recycle) { Emit ("| {0} | ``{1}`` | {2} |" -f (Escape-Cell $r.kind), (Escape-Cell $r.displayName), (Escape-Cell $r.deleted)) }
    Emit ''
}

# Summary counts. Denominators count only SIGNIFICANT rows (ok/warn/fail); informational (🔵) and
# not-part-of-this-lab (⚪) rows are excluded so they never inflate the X / Y health ratio.
function Measure-Significant { param($Rows) @($Rows | Where-Object { $_.state -in @('ok', 'warn', 'fail') }).Count }
$agSig = @($agentRows | Where-Object { $_.overall -in @('ok', 'warn', 'fail') })
$agHealthy = @($agSig | Where-Object { $_.overall -eq 'ok' }).Count
$agTotal = @($agSig).Count
$agInfo = @($agentRows | Where-Object { $_.overall -in @('info', 'na') }).Count
Emit '## Summary'
Emit ''
Emit "- **Agents:** $agHealthy / $agTotal healthy (Azure compute + Entra blueprint). $agInfo declarative/Copilot Studio agent(s) excluded from the ratio (no queryable Azure/Entra footprint — verify in the Foundry / Copilot Studio portal)."
if ($uiPlanned) { $uiOk = @($sections.webui | Where-Object { $_.state -eq 'ok' }).Count; Emit "- **Web UI:** $uiOk / $(Measure-Significant $sections.webui) objects healthy." }
if ($mcpPlanned) { $mcpOk = @($sections.mcp | Where-Object { $_.state -eq 'ok' }).Count; Emit "- **Custom MCP:** $mcpOk / $(Measure-Significant $sections.mcp) objects healthy (informational proxy apps / connectors excluded)." }
if ($dwTypes.Count -gt 0) { Emit "- **DW instances:** $(@($dwLab).Count) lab-matched (by blueprint link), $(@($dwOther).Count) other agent-license holder(s)." }
Emit ''

$reportPath = Join-Path $OutDir 'report.md'
Set-Content -LiteralPath $reportPath -Value $sb.ToString() -Encoding utf8

Write-Host ''
Write-Host "Lab state report written to:" -ForegroundColor Green
Write-Host "  $reportPath" -ForegroundColor White
Write-Host "  $(Join-Path $OutDir 'state.json')" -ForegroundColor DarkGray
Write-Output $reportPath
