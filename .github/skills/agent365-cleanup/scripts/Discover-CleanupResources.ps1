#requires -Version 7.0
<#
.SYNOPSIS
  READ-ONLY discovery of Agent 365 lab resources created by the provisioning wizard, for cleanup.

.DESCRIPTION
  Given one or more categories (WebUI / CustomMcp / Agents) and a name filter, enumerates every
  matching resource so the cleanup wizard can present a checkbox review before anything is deleted.
  It performs NO mutations — only `az ... list/show` and Microsoft Graph / Power Platform GET calls.

  For each category it discovers:
    WebUI     — Azure resource groups (name contains the filter and 'ui'), Static Web Apps, and the
                Entra SPA app registration (`<prefix>-ui-spa`).
    CustomMcp — Azure resource groups (name contains the MCP slug and 'mcp') and their resources, the
                Entra `ext_<Name>*` proxy/resource apps, and Power Platform custom connectors.
    Agents    — Azure resource groups dedicated to an agent (`<agent-name>-rg`), Entra blueprint /
                identity apps, agent instances (agent users) and the M365 licenses they hold, plus any
                matching objects still sitting in the Entra recycle bin (deletedItems) from a prior
                half-finished deletion.

  Agent instances are named `<blueprintName>-iN`, and a blueprint may have a CUSTOM name that does not
  contain the prefix, so discovery scopes instances to THIS lab by three paths: (a) name-match on the
  prefix, (a') the archived plan's agent names (the precise catch for custom-named labs), and (b) a
  Frontier / Agent 365 license sweep that is FILTERED to holders whose name/UPN starts with a lab
  blueprint name — holders outside the lab (other runs) are skipped, never surfaced. The mandatory human
  review remains the final safety net.

  Output: a JSON array of resource items (also written to -OutFile when supplied). The Remove script
  consumes the selected subset. Nothing here deletes anything.

.PARAMETER Categories
  One or more of WebUI, CustomMcp, Agents.

.PARAMETER NameFilter
  Substring matched (case-insensitively) against WebUI and Agent resource names. Required when WebUI
  or Agents is requested. Typically the solution prefix (e.g. `h2256`).

.PARAMETER McpNameFilter
  The custom MCP <Name> (e.g. `h2256`). Required when CustomMcp is requested. Azure resources match its
  lowercased alphanumeric slug; Entra apps match `ext_<Name>`.

.PARAMETER Subscription
  Target subscription id. Pins the az context (az ad / Graph use the active account, so this also
  guards the tenant check below).

.PARAMETER TenantId
  Expected tenant id. The script aborts if the signed-in az context is a different tenant.

.PARAMETER OutFile
  Optional path to write the discovered JSON array to. The wizard passes a path under
  generated/cleanup/<timestamp>/discovered.json.

.EXAMPLE
  pwsh -File .\Discover-CleanupResources.ps1 -Categories Agents,WebUI -NameFilter h2256 `
      -Subscription <sub> -TenantId <tenant> -OutFile .\discovered.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('WebUI', 'CustomMcp', 'Agents')][string[]]$Categories,
    [string]$NameFilter,
    [string]$McpNameFilter,
    [Parameter(Mandatory)][string]$Subscription,
    [string]$TenantId,
    [string]$OutFile,
    # Optional archived plan (generated/<prefix>/a365-deployment-plan.json). When supplied, discovery
    # ALSO seeds the EXACT resource names from it (including CUSTOM agent names that do not contain the
    # prefix) and adds any that still exist — the primary, precise path for a lab created with custom
    # names, and the one that catches a half-created resource that was created before it could be tagged.
    [string]$PlanPath
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ---------------------------------------------------------------------------
# Validation of the filters required by the chosen categories.
# ---------------------------------------------------------------------------
if (($Categories -contains 'WebUI' -or $Categories -contains 'Agents') -and [string]::IsNullOrWhiteSpace($NameFilter)) {
    throw "NameFilter is required when discovering WebUI or Agents."
}
if ($Categories -contains 'CustomMcp' -and [string]::IsNullOrWhiteSpace($McpNameFilter)) {
    throw "McpNameFilter is required when discovering CustomMcp."
}
# Names in this lab are alphanumeric/hyphen; strip anything that could break an OData filter literal.
function ConvertTo-SafeFilter { param([string]$Value) if ($null -eq $Value) { return '' } ($Value -replace "['`"]", '').Trim() }
$NameFilter = ConvertTo-SafeFilter $NameFilter
$McpNameFilter = ConvertTo-SafeFilter $McpNameFilter
$mcpSlug = ($McpNameFilter -replace '[^A-Za-z0-9]', '').ToLower()

# ---------------------------------------------------------------------------
# Context: pin the subscription and verify the tenant. az ad / Graph ignore
# --subscription and use the active account, so a wrong tenant here would scan
# (and later delete) the wrong directory.
# ---------------------------------------------------------------------------
az account set --subscription $Subscription | Out-Null
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' first." }
if ($TenantId -and $ctx.tenantId -ne $TenantId) {
    throw "az context tenant '$($ctx.tenantId)' != -TenantId '$TenantId'. Re-pin the context and retry."
}
$sub = $ctx.id
$signedIn = $ctx.user.name
Write-Host "Discovery as '$signedIn' — tenant $($ctx.tenantId), subscription $sub" -ForegroundColor Cyan
Write-Host "Categories: $($Categories -join ', ')  |  NameFilter: '$NameFilter'  |  McpNameFilter: '$McpNameFilter'" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------
function Invoke-AzJson {
    param([string[]]$AzArgs)
    $out = az @AzArgs 2>$null
    if (-not $out) { return $null }
    try { return ($out | ConvertFrom-Json) } catch { return $null }
}

# GET a Microsoft Graph collection, following @odata.nextLink (capped to keep lab scans bounded).
function Get-GraphCollection {
    param([string]$Url, [string[]]$Headers, [int]$MaxPages = 20)
    $items = New-Object System.Collections.Generic.List[object]
    $next = $Url
    $page = 0
    while ($next -and $page -lt $MaxPages) {
        $page++
        $azArgs = @('rest', '--method', 'GET', '--url', $next, '-o', 'json')
        foreach ($h in $Headers) { $azArgs += @('--headers', $h) }
        $raw = az @azArgs 2>$null
        if (-not $raw) { break }
        $obj = $null
        try { $obj = $raw | ConvertFrom-Json } catch { break }
        if ($null -ne $obj.value) { foreach ($v in $obj.value) { $items.Add($v) } } else { $items.Add($obj) }
        $next = $obj.'@odata.nextLink'
    }
    return $items
}

# Reliable Graph collection GET with a server-side $filter. The filter value is URL-ENCODED and used as
# the ONLY query parameter (no '&', no $select/$top): az.cmd/cmd.exe corrupt '&', quotes and parentheses
# in a --url on some Windows hosts, which would otherwise return nothing and silently under-report.
function Get-GraphFiltered {
    param([string]$Entity, [string]$FilterExpr, [string[]]$Headers)
    $url = "https://graph.microsoft.com/v1.0/$Entity" + '?$filter=' + [uri]::EscapeDataString($FilterExpr)
    $azArgs = @('rest', '--method', 'GET', '--url', $url, '-o', 'json')
    foreach ($h in $Headers) { $azArgs += @('--headers', $h) }
    $raw = az @azArgs 2>$null
    if (-not $raw) { return @() }
    try { return @((($raw -join "`n") | ConvertFrom-Json).value) } catch { return @() }
}
# Reliable single-object Graph GET (no query params, or a single already-safe one).
function Get-GraphObject {
    param([string]$Url)
    $raw = az rest --method GET --url $Url -o json 2>$null
    if (-not $raw) { return $null }
    try { return (($raw -join "`n") | ConvertFrom-Json) } catch { return $null }
}

$items = New-Object System.Collections.Generic.List[object]
function Add-Item {
    param($Category, $Kind, $Id, $ObjectId, $DisplayName, $Detail, $Action, [int]$DeleteOrder, $Extra)
    $o = [ordered]@{
        category    = $Category
        kind        = $Kind
        id          = $Id
        objectId    = $ObjectId
        displayName = $DisplayName
        detail      = $Detail
        action      = $Action
        deleteOrder = $DeleteOrder
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] } }
    $items.Add([pscustomobject]$o)
}

# Summarize an Azure resource group's contents for the review screen.
function Get-RgDetail {
    param([string]$Rg)
    $res = Invoke-AzJson @('resource', 'list', '-g', $Rg, '--subscription', $sub, '--query', '[].type', '-o', 'json')
    if (-not $res) { return '0 resources (empty)' }
    $arr = @($res)
    $types = ($arr | ForEach-Object { ($_ -split '/')[-1] } | Sort-Object -Unique) -join ', '
    return "$($arr.Count) resource(s): $types"
}

# Cache of subscribedSkus (skuId -> partNumber) for license labelling.
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
    foreach ($l in @($AssignedLicenses)) {
        if ($l.skuId) { $parts += ($map[$l.skuId] ?? $l.skuId) }
    }
    return , $parts
}

# True when an agent-instance (agent user) belongs to THIS lab: its display name or UPN local-part starts
# with a lab blueprint name (the prefix, or a plan agent name — instances are named '<blueprintName>-iN').
# This scopes the Frontier/Agent365 license sweep to the lab so OTHER labs' instances are never surfaced.
function Test-InstanceBelongsToLab {
    param([string]$DisplayName, [string]$Upn, [string[]]$Prefixes)
    $local = if ($Upn) { ($Upn -split '@', 2)[0] } else { '' }
    foreach ($p in $Prefixes) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ($DisplayName -and $DisplayName.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($local -and $local.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# WebUI discovery.
# ---------------------------------------------------------------------------
function Find-WebUi {
    Write-Host "Scanning Web UI resources..." -ForegroundColor Cyan
    # Azure resource groups: contain the filter and look like a UI RG (and are not an MCP RG).
    $rgs = Invoke-AzJson @('group', 'list', '--subscription', $sub, '-o', 'json')
    foreach ($rg in @($rgs)) {
        $n = $rg.name
        if ($n -notmatch [regex]::Escape($NameFilter)) { continue }
        if ($n -notmatch '(?i)ui') { continue }
        if ($n -match '(?i)mcp') { continue }
        Add-Item -Category 'WebUI' -Kind 'azure-rg' -Id $n -ObjectId $null -DisplayName $n `
            -Detail (Get-RgDetail $n) -Action 'delete-rg' -DeleteOrder 40 -Extra @{ location = $rg.location }
    }
    # Static Web Apps whose name contains the filter (in case the RG name does not).
    $swa = Invoke-AzJson @('staticwebapp', 'list', '--subscription', $sub, '-o', 'json')
    foreach ($s in @($swa)) {
        if ($s.name -notmatch [regex]::Escape($NameFilter)) { continue }
        Add-Item -Category 'WebUI' -Kind 'azure-swa' -Id $s.id -ObjectId $null -DisplayName $s.name `
            -Detail "Static Web App in RG $($s.resourceGroup) — host $($s.defaultHostname)" `
            -Action 'delete-swa' -DeleteOrder 38 -Extra @{ resourceGroup = $s.resourceGroup }
    }
    # SHARED web UIs (created outside this lab) that host THIS lab's agents: they carry the tag
    # a365ref_<prefix>. We must NOT delete them — only DEREGISTER this lab's tabs (Remove-WebUiTab.ps1)
    # and clear the tag. A SWA whose name contains the prefix is the lab's OWN UI (deleted above), so
    # deregistration there is moot; only emit a deregister item for a DIFFERENT (shared) SWA.
    $refKey = "a365ref_$NameFilter"
    foreach ($s in @($swa)) {
        $tags = $s.tags
        if (-not ($tags -and ($tags.PSObject.Properties.Name -contains $refKey))) { continue }
        if ($s.name -match [regex]::Escape($NameFilter)) { continue }   # own UI, deleted above
        Add-Item -Category 'WebUI' -Kind 'webui-registration' -Id "$($s.name)#$NameFilter" -ObjectId $null -DisplayName $s.name `
            -Detail "Shared web UI '$($s.name)' hosts lab '$NameFilter' agents (tag $refKey) — DEREGISTER the lab's tabs (SWA preserved, other labs untouched)" `
            -Action 'deregister-webui-tab' -DeleteOrder 5 -Extra @{ swaName = $s.name; labPrefix = $NameFilter; resourceGroup = $s.resourceGroup }
    }
    # Entra SPA app registration (<prefix>-ui-spa).
    $apps = Get-GraphFiltered 'applications' "startswith(displayName,'$NameFilter')"
    foreach ($a in @($apps)) {
        if (-not $a.displayName) { continue }
        if ($a.displayName -notmatch '(?i)ui') { continue }
        Add-Item -Category 'WebUI' -Kind 'entra-app' -Id $a.appId -ObjectId $a.id -DisplayName $a.displayName `
            -Detail 'SPA app registration (deleted app + its service principal, then purged)' `
            -Action 'delete-app' -DeleteOrder 20
    }
}

# ---------------------------------------------------------------------------
# Custom MCP discovery.
# ---------------------------------------------------------------------------
function Find-CustomMcp {
    Write-Host "Scanning custom MCP resources..." -ForegroundColor Cyan
    # Azure resource groups: contain the MCP slug and 'mcp'.
    $rgs = Invoke-AzJson @('group', 'list', '--subscription', $sub, '-o', 'json')
    foreach ($rg in @($rgs)) {
        $n = $rg.name
        if ($n -notmatch '(?i)mcp') { continue }
        if ($mcpSlug -and $n -notmatch [regex]::Escape($mcpSlug)) { continue }
        Add-Item -Category 'CustomMcp' -Kind 'azure-rg' -Id $n -ObjectId $null -DisplayName $n `
            -Detail (Get-RgDetail $n) -Action 'delete-rg' -DeleteOrder 40 -Extra @{ location = $rg.location }
    }
    # Entra apps: the registered servers and every proxy/resource app derive from ext_<Name>.
    $extPrefix = "ext_$McpNameFilter"
    $apps = Get-GraphFiltered 'applications' "startswith(displayName,'$extPrefix')"
    foreach ($a in @($apps)) {
        if (-not $a.displayName) { continue }
        Add-Item -Category 'CustomMcp' -Kind 'entra-app' -Id $a.appId -ObjectId $a.id -DisplayName $a.displayName `
            -Detail 'MCP registration app (proxy / public-clients / resource). Deleted + purged.' `
            -Action 'delete-app' -DeleteOrder 20
    }
    # Power Platform custom connectors named ext_<Name>* across every environment.
    # Best-effort: Power Platform access is optional and BYO-MCP is preview, so a token/API/escaping
    # failure here must degrade gracefully and never abort the read-only discovery. Connectors are
    # filtered in PowerShell rather than via a JMESPath '[?...]' query, which breaks cmd-line escaping
    # when embedded in a loop on this platform and yields a non-JSON error string.
    try {
        $ppResource = 'https://service.powerapps.com/'
        $envsRaw = az rest --method get --url 'https://api.powerapps.com/providers/Microsoft.PowerApps/environments?api-version=2016-11-01' --resource $ppResource --query 'value[].name' -o tsv 2>$null
        foreach ($envId in @($envsRaw)) {
            if ([string]::IsNullOrWhiteSpace($envId)) { continue }
            $listUrl = "https://api.powerapps.com/providers/Microsoft.PowerApps/apis?api-version=2016-11-01&`$filter=environment eq '$envId'"
            $connsText = ((az rest --method get --url $listUrl --resource $ppResource -o json 2>$null) -join "`n").Trim()
            if ([string]::IsNullOrWhiteSpace($connsText) -or ($connsText[0] -ne '{' -and $connsText[0] -ne '[')) { continue }
            $parsed = $null
            try { $parsed = $connsText | ConvertFrom-Json } catch { continue }
            $connList = if ($null -ne $parsed.value) { $parsed.value } else { $parsed }
            foreach ($c in @($connList)) {
                $dn = $c.properties.displayName
                if ([string]::IsNullOrWhiteSpace($dn) -or -not $dn.StartsWith("ext_$McpNameFilter", [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                Add-Item -Category 'CustomMcp' -Kind 'powerplatform-connector' -Id $c.name -ObjectId $null -DisplayName $dn `
                    -Detail "Power Platform custom connector in environment $envId" `
                    -Action 'delete-connector' -DeleteOrder 30 -Extra @{ environment = $envId }
            }
        }
    }
    catch {
        Write-Host "  (Power Platform connector scan skipped: $($_.Exception.Message))" -ForegroundColor DarkYellow
    }
    # Recycle-bin leftovers from a prior failed registration/cleanup.
    Find-DeletedItems -Category 'CustomMcp' -Filter $extPrefix -IncludeUsers:$false
}

# ---------------------------------------------------------------------------
# Agents discovery.
# ---------------------------------------------------------------------------
function Find-Agents {
    Write-Host "Scanning agent resources..." -ForegroundColor Cyan
    # Azure resource groups dedicated to an agent (isolated strategy). Exclude UI and MCP RGs; a
    # pre-existing shared RG (e.g. rg-a365-foundry-agent used by FD, or a solution.foundry
    # 'reuse-existing' account) is not prefix-named so it will not match. The 'create-shared' Foundry
    # RG <prefix>-foundry-rg IS prefix-named and lab-owned, so it matches here and is deleted like an
    # agent RG (correct — the wizard created it for the lab).
    $rgs = Invoke-AzJson @('group', 'list', '--subscription', $sub, '-o', 'json')
    foreach ($rg in @($rgs)) {
        $n = $rg.name
        if ($n -notmatch [regex]::Escape($NameFilter)) { continue }
        if ($n -match '(?i)(ui-rg|mcp)') { continue }
        Add-Item -Category 'Agents' -Kind 'azure-rg' -Id $n -ObjectId $null -DisplayName $n `
            -Detail (Get-RgDetail $n) -Action 'delete-rg' -DeleteOrder 40 -Extra @{ location = $rg.location }
        # Cognitive Services (Foundry AIServices / Azure OpenAI) accounts in the RG SOFT-DELETE on RG
        # delete and keep blocking their name + counting against the regional quota until PURGED. Add an
        # explicit delete+purge just BEFORE the RG delete (order 39). Purging the account also removes its
        # child project — the "workspace" the Foundry azd provider complains about on re-provision — so no
        # separate AML-workspace purge is needed.
        $cogs = Invoke-AzJson @('cognitiveservices', 'account', 'list', '-g', $n, '--subscription', $sub, '-o', 'json')
        foreach ($c in @($cogs)) {
            Add-Item -Category 'Agents' -Kind 'cognitiveservices-account' -Id $c.name -ObjectId $null -DisplayName $c.name `
                -Detail "Cognitive Services account (kind $($c.kind)) in RG $n — soft-deletes on RG delete; delete+purge frees its name + quota (and its project/workspace)" `
                -Action 'purge-cognitiveservices' -DeleteOrder 39 -Extra @{ resourceGroup = $n; location = $c.location }
        }
    }
    # Prior-run leftovers: accounts already sitting SOFT-DELETED whose ORIGINAL RG matches the prefix (a
    # previous cleanup deleted the RG but never purged the account — they pile up against the quota). Sweep
    # the sub's deleted-accounts list and add a purge item for each match.
    $deletedCogs = Invoke-AzJson @('cognitiveservices', 'account', 'list-deleted', '--subscription', $sub, '-o', 'json')
    foreach ($d in @($deletedCogs)) {
        $origRg = if ($d.id -match '/resourceGroups/([^/]+)/') { $matches[1] } else { '' }
        if ($origRg -notmatch [regex]::Escape($NameFilter)) { continue }
        if ($origRg -match '(?i)(ui-rg|mcp)') { continue }
        Add-Item -Category 'Agents' -Kind 'cognitiveservices-deleted' -Id $d.name -ObjectId $null -DisplayName $d.name `
            -Detail "SOFT-DELETED Cognitive Services account (original RG $origRg, $($d.location)) — pending purge; frees its name + quota" `
            -Action 'purge-cognitiveservices' -DeleteOrder 39 -Extra @{ resourceGroup = $origRg; location = $d.location }
    }
    # Entra apps: blueprint + identity apps derive from the agent name. Exclude UI/MCP apps.
    $apps = Get-GraphFiltered 'applications' "startswith(displayName,'$NameFilter')"
    foreach ($a in @($apps)) {
        if (-not $a.displayName) { continue }
        if ($a.displayName -match '(?i)(ui-spa|^ext_)') { continue }
        Add-Item -Category 'Agents' -Kind 'entra-app' -Id $a.appId -ObjectId $a.id -DisplayName $a.displayName `
            -Detail 'Agent blueprint / identity app (deleted + cascades its SP, then purged)' `
            -Action 'delete-app' -DeleteOrder 20
    }
    # Entra service principals that need explicit deletion: agent-identity leftovers ('<name> Identity')
    # that have no matching app in this tenant. Skip SPs that cascade from an app we already listed, and
    # container-app managed identities (lowercase '<name>-<hosting>-<identity>') removed with their RG.
    $agentAppNames = @($items | Where-Object { $_.category -eq 'Agents' -and $_.kind -eq 'entra-app' } | ForEach-Object { $_.displayName })
    foreach ($sp in (Get-GraphFiltered 'servicePrincipals' "startswith(displayName,'$NameFilter')")) {
        if (-not $sp.displayName) { continue }
        if ($agentAppNames -contains $sp.displayName) { continue }
        # Only agent-identity leftovers ('<name> Identity') need an explicit SP delete: blueprint SPs
        # cascade from their app, container / MCP managed identities go with their resource group, and
        # agent-instance SPs are handled by the agent-instance (user) path below.
        if ($sp.displayName -notmatch '(?i) Identity$') { continue }
        Add-Item -Category 'Agents' -Kind 'entra-sp' -Id $sp.appId -ObjectId $sp.id -DisplayName $sp.displayName `
            -Detail 'Agent identity / leftover service principal (deleted directly, then purged)' `
            -Action 'delete-sp' -DeleteOrder 22
    }

    # Agent instances (agent users). Three lab-scoped discovery paths, de-duplicated by id:
    #   (a)  users whose display name starts with the prefix;
    #   (a') users whose display name starts with a plan agent name (custom-named labs);
    #   (b)  Frontier / Agent 365 license holders FILTERED to this lab's blueprint names (others skipped).
    $seen = @{}
    $addUser = {
        param($u, $why)
        if (-not $u.id -or $seen.ContainsKey($u.id)) { return }
        $seen[$u.id] = $true
        $full = Get-GraphObject ("https://graph.microsoft.com/v1.0/users/$($u.id)?" + '$select=' + [uri]::EscapeDataString('id,displayName,userPrincipalName,userType,assignedLicenses'))
        if (-not $full) { $full = $u }
        $lic = Format-Licenses $full.assignedLicenses
        $licTxt = if ($lic.Count) { $lic -join '; ' } else { '(no licenses)' }
        Add-Item -Category 'Agents' -Kind 'agent-instance' -Id $u.id -ObjectId $u.id -DisplayName $full.displayName `
            -Detail "UPN $($full.userPrincipalName) | userType $($full.userType) | $why | licenses: $licTxt" `
            -Action 'remove-licenses-and-delete-user' -DeleteOrder 10 `
            -Extra @{ userPrincipalName = $full.userPrincipalName; licenses = $lic }
    }

    # (a) name-matched users (reliable encoded filter; per-user detail fetched in $addUser).
    foreach ($u in (Get-GraphFiltered 'users' "startswith(displayName,'$NameFilter')")) { & $addUser $u 'name match' }

    # Agent instances belong to THIS lab when their name starts with a lab blueprint name: the prefix, or a
    # plan agent name (instances are named '<blueprintName>-iN'). This set scopes the license sweep below so
    # it can NEVER surface other labs' Frontier/Agent365 instances (the previous unscoped sweep did).
    $labPrefixes = @(@($NameFilter) + $script:LabAgentNames | Where-Object { $_ } | Select-Object -Unique)

    # (a') plan-seeded custom-named instances: for each lab agent name that does NOT contain the prefix,
    # find its instances directly (startswith '<agentName>'). This is the PRECISE catch for custom-named
    # labs and does not depend on the license sweep.
    foreach ($an in $script:LabAgentNames) {
        if ([string]::IsNullOrWhiteSpace($an) -or ($an -match [regex]::Escape($NameFilter))) { continue }
        foreach ($u in (Get-GraphFiltered 'users' "startswith(displayName,'$($an.Replace("'", "''"))')")) { & $addUser $u "plan agent '$an' instance" }
    }

    # (b) license-identified users — SCOPED to this lab. Enumerate Frontier / Agent 365 holders, but add
    # ONLY those whose name / UPN matches a lab blueprint prefix; holders outside this lab belong to other
    # labs and are skipped (counted for a console note). This is the safety net for a lab instance not
    # already caught by (a)/(a') — it never crosses the lab boundary again.
    $map = Get-SkuMap
    $agentSkuIds = @()
    foreach ($kv in $map.GetEnumerator()) {
        if ($kv.Value -match '(?i)(FRONTIER|AGENT[_ ]?365)') { $agentSkuIds += $kv.Key }
    }
    $skippedForeign = 0
    foreach ($skuId in $agentSkuIds) {
        foreach ($u in (Get-GraphFiltered 'users' "assignedLicenses/any(x:x/skuId eq $skuId)" @('ConsistencyLevel=eventual'))) {
            if ($seen.ContainsKey($u.id)) { continue }
            if (Test-InstanceBelongsToLab -DisplayName $u.displayName -Upn $u.userPrincipalName -Prefixes $labPrefixes) {
                & $addUser $u "holds agent license $($map[$skuId])"
            }
            else { $skippedForeign++ }
        }
    }
    if ($skippedForeign -gt 0) {
        Write-Host "  Skipped $skippedForeign Frontier/Agent365 license holder(s) outside this lab's names (belong to other labs)." -ForegroundColor DarkYellow
    }

    # Recycle-bin leftovers (apps, service principals, users) from a prior half-finished deletion.
    Find-DeletedItems -Category 'Agents' -Filter $NameFilter -IncludeUsers:$true
}

# ---------------------------------------------------------------------------
# Recycle bin (deletedItems) — surface objects still pending purge, for ANY state.
# ---------------------------------------------------------------------------
function Find-DeletedItems {
    param([string]$Category, [string]$Filter, [switch]$IncludeUsers)
    $types = @(
        @{ seg = 'microsoft.graph.application'; kind = 'deleted-app' },
        @{ seg = 'microsoft.graph.servicePrincipal'; kind = 'deleted-sp' }
    )
    if ($IncludeUsers) { $types += @{ seg = 'microsoft.graph.user'; kind = 'deleted-user' } }
    foreach ($t in $types) {
        $del = Get-GraphObject "https://graph.microsoft.com/v1.0/directory/deletedItems/$($t.seg)"
        foreach ($d in @($del.value)) {
            if (-not $d.displayName -or $d.displayName -notmatch [regex]::Escape($Filter)) { continue }
            $when = if ($d.deletedDateTime) { " (deleted $($d.deletedDateTime))" } else { '' }
            Add-Item -Category $Category -Kind $t.kind -Id ($d.appId ?? $d.id) -ObjectId $d.id -DisplayName $d.displayName `
                -Detail "In Entra recycle bin$when — will be permanently purged" `
                -Action 'purge-deleted-item' -DeleteOrder 24
        }
    }
}

# ---------------------------------------------------------------------------
# Preflight: Microsoft Graph must be reachable. Every category has an Entra
# component (WebUI SPA app, MCP proxy/resource apps, agent blueprint/identity
# apps, and — critically — agent instances plus the M365 licenses to release).
# If Graph is blocked (e.g. a Conditional Access / CAE challenge:
# InteractionRequired / TokenCreatedWithOutdatedPolicies), the scans below would
# silently return nothing and UNDER-REPORT. For a license-releasing cleanup that
# is dangerous, so abort loudly and tell the operator to re-authenticate.
# ---------------------------------------------------------------------------
$graphProbe = az rest --method GET --url 'https://graph.microsoft.com/v1.0/organization?$select=id' -o json 2>&1
if ($LASTEXITCODE -ne 0) {
    throw @"
Microsoft Graph is not accessible from the current az context (az exit $LASTEXITCODE).
This is usually a Conditional Access / CAE challenge (InteractionRequired /
TokenCreatedWithOutdatedPolicies). Graph is REQUIRED to discover Entra apps,
agent instances and the M365 licenses to release, so discovery is aborting to
avoid silently missing them.

Fix: re-authenticate, then re-run this discovery:
  az login --tenant $($ctx.tenantId) --scope https://graph.microsoft.com/.default

Detail: $graphProbe
"@
}

# ---------------------------------------------------------------------------
# Preload the archived plan once (folder-primary). Its agent names — INCLUDING custom names that do not
# contain the prefix — scope agent-instance discovery to THIS lab (instances are named '<agentName>-iN'),
# which is what stops the license sweep in Find-Agents from surfacing OTHER labs' Frontier/Agent365
# instances. Reused below by Find-PlanSeeded so the plan is parsed only once.
# ---------------------------------------------------------------------------
$script:SeedPlan = $null
$script:LabAgentNames = @()
if ($PlanPath -and (Test-Path -LiteralPath $PlanPath)) {
    try { $script:SeedPlan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json } catch { $script:SeedPlan = $null }
    if ($script:SeedPlan) {
        $script:LabAgentNames = @($script:SeedPlan.agents | Where-Object { $_.name -and $_.type -notlike 'MCS-*' } | ForEach-Object { $_.name })
    }
}

# ---------------------------------------------------------------------------
# Run the requested categories.
# ---------------------------------------------------------------------------
if ($Categories -contains 'WebUI') { Find-WebUi }
if ($Categories -contains 'CustomMcp') { Find-CustomMcp }
if ($Categories -contains 'Agents') { Find-Agents }

# ---------------------------------------------------------------------------
# Durable-tag discovery (finds CUSTOM-named resources the name scans above miss). Lab Builder stamps
# a365lab=<prefix> on lab-owned Azure RGs and a365lab:<prefix> on lab-owned Entra apps/SPs when agents
# were given custom names. This runs regardless of naming mode (a default lab simply has no such tags).
# Classify each tagged object into the SELECTED categories so the review stays scoped.
# ---------------------------------------------------------------------------
function Find-TaggedResources {
    if ([string]::IsNullOrWhiteSpace($NameFilter)) { return }
    $labTag = "a365lab:$NameFilter"
    Write-Host "Scanning durable lab tag ($labTag)..." -ForegroundColor Cyan

    # Azure resource groups carrying tag a365lab=<prefix>.
    $rgs = Invoke-AzJson @('group', 'list', '--subscription', $sub, '--query', "[?tags.a365lab=='$NameFilter']", '-o', 'json')
    foreach ($rg in @($rgs)) {
        $n = $rg.name
        $cat = if ($n -match '(?i)ui-rg' -and $n -notmatch '(?i)mcp') { 'WebUI' } elseif ($n -match '(?i)mcp') { 'CustomMcp' } else { 'Agents' }
        if ($Categories -notcontains $cat) { continue }
        Add-Item -Category $cat -Kind 'azure-rg' -Id $n -ObjectId $null -DisplayName $n `
            -Detail ((Get-RgDetail $n) + ' [tag]') -Action 'delete-rg' -DeleteOrder 40 -Extra @{ location = $rg.location }
        if ($cat -eq 'Agents') {
            foreach ($c in @(Invoke-AzJson @('cognitiveservices', 'account', 'list', '-g', $n, '--subscription', $sub, '-o', 'json'))) {
                Add-Item -Category 'Agents' -Kind 'cognitiveservices-account' -Id $c.name -ObjectId $null -DisplayName $c.name `
                    -Detail "Cognitive Services account (kind $($c.kind)) in RG $n [tag] — delete+purge frees its name + quota" `
                    -Action 'purge-cognitiveservices' -DeleteOrder 39 -Extra @{ resourceGroup = $n; location = $c.location }
            }
        }
    }

    # Entra apps carrying tag a365lab:<prefix>. tags/any(...) is a supported directory filter.
    $apps = Get-GraphFiltered 'applications' "tags/any(t:t eq '$labTag')" @('ConsistencyLevel=eventual')
    foreach ($a in @($apps)) {
        if (-not $a.displayName) { continue }
        $cat = if ($a.displayName -match '(?i)ui-spa') { 'WebUI' } elseif ($a.displayName -match '(?i)^ext_') { 'CustomMcp' } else { 'Agents' }
        if ($Categories -notcontains $cat) { continue }
        Add-Item -Category $cat -Kind 'entra-app' -Id $a.appId -ObjectId $a.id -DisplayName $a.displayName `
            -Detail 'Agent/UI/MCP app registration [tag] (deleted + cascades its SP, then purged)' `
            -Action 'delete-app' -DeleteOrder 20
    }
    # Entra service principals carrying the tag that need an explicit delete (identity leftovers whose app is gone).
    $appIds = @($items | Where-Object { $_.kind -eq 'entra-app' } | ForEach-Object { $_.id })
    foreach ($sp in (Get-GraphFiltered 'servicePrincipals' "tags/any(t:t eq '$labTag')" @('ConsistencyLevel=eventual'))) {
        if (-not $sp.displayName -or ($appIds -contains $sp.appId)) { continue }
        if ($Categories -notcontains 'Agents') { continue }
        Add-Item -Category 'Agents' -Kind 'entra-sp' -Id $sp.appId -ObjectId $sp.id -DisplayName $sp.displayName `
            -Detail 'Tagged service principal [tag] (deleted directly, then purged)' `
            -Action 'delete-sp' -DeleteOrder 22
    }
}

# ---------------------------------------------------------------------------
# Plan-seeded discovery (folder-primary). When the archived plan is available it names every resource
# EXACTLY — including custom names — so we add each that actually exists. This is the precise path and it
# catches a resource created before Set-LabTags could tag it (interrupted run). Existence is verified so a
# never-created reference is skipped.
# ---------------------------------------------------------------------------
function Find-PlanSeeded {
    param($Plan)
    if (-not $Plan) { return }
    Write-Host "Scanning plan-named resources (folder-primary)..." -ForegroundColor Cyan
    $rgStrategy = $Plan.solution.resourceGroupStrategy
    $sharedRg = if ($Plan.solution.sharedResourceGroup) { $Plan.solution.sharedResourceGroup } else { "$NameFilter-rg" }
    foreach ($a in @($Plan.agents)) {
        if ($a.type -like 'MCS-*') { continue }   # MCS = Dataverse; handled by the cleanup SKILL via <prefix>MCS* uniquename.
        if ($Categories -notcontains 'Agents') { continue }
        $rg = if ($rgStrategy -eq 'shared') { $sharedRg } elseif ($a.resourceGroup) { $a.resourceGroup } else { "$($a.name)-rg" }
        if ((az group exists -n $rg --subscription $sub 2>$null) -eq 'true') {
            Add-Item -Category 'Agents' -Kind 'azure-rg' -Id $rg -ObjectId $null -DisplayName $rg `
                -Detail ((Get-RgDetail $rg) + ' [plan]') -Action 'delete-rg' -DeleteOrder 40 `
                -Extra @{ location = (Invoke-AzJson @('group', 'show', '-n', $rg, '--subscription', $sub, '--query', 'location', '-o', 'json')) }
            foreach ($c in @(Invoke-AzJson @('cognitiveservices', 'account', 'list', '-g', $rg, '--subscription', $sub, '-o', 'json'))) {
                Add-Item -Category 'Agents' -Kind 'cognitiveservices-account' -Id $c.name -ObjectId $null -DisplayName $c.name `
                    -Detail "Cognitive Services account (kind $($c.kind)) in RG $rg [plan] — delete+purge frees its name + quota" `
                    -Action 'purge-cognitiveservices' -DeleteOrder 39 -Extra @{ resourceGroup = $rg; location = $c.location }
            }
        }
        # ACA blueprint/identity app registrations (named by the plan). FH/FD blueprints are Foundry-generated.
        if ($a.type -like 'ACA-*') {
            $names = @()
            if ($a.displayNames.blueprint) { $names += $a.displayNames.blueprint } else { $names += "$($a.name) Blueprint" }
            if ($a.displayNames.identity) { $names += $a.displayNames.identity } else { $names += "$($a.name) Identity" }
            foreach ($dn in $names) {
                foreach ($app in (Get-GraphFiltered 'applications' "displayName eq '$($dn.Replace("'", "''"))'")) {
                    if (-not $app.displayName) { continue }
                    Add-Item -Category 'Agents' -Kind 'entra-app' -Id $app.appId -ObjectId $app.id -DisplayName $app.displayName `
                        -Detail 'Agent blueprint / identity app [plan] (deleted + cascades its SP, then purged)' `
                        -Action 'delete-app' -DeleteOrder 20
                }
            }
        }
    }
}

Find-TaggedResources
if ($script:SeedPlan) { Find-PlanSeeded $script:SeedPlan }


# ---------------------------------------------------------------------------
# Emit.
# ---------------------------------------------------------------------------
# De-duplicate: the same object can now be found by MORE THAN ONE path (name substring, durable tag,
# plan-seed) or match more than one category filter. Key on (kind, objectId-or-id) so an Azure RG (which
# has no objectId) also dedupes; keep the first occurrence. Genuinely distinct objects have distinct ids.
$seenKey = @{}
$dedup = New-Object System.Collections.Generic.List[object]
foreach ($it in $items) {
    $idPart = if ($it.objectId) { $it.objectId } else { $it.id }
    if ($idPart) {
        $k = "$($it.kind)|$idPart"
        if ($seenKey.ContainsKey($k)) { continue }
        $seenKey[$k] = $true
    }
    $dedup.Add($it)
}
$sorted = @($dedup | Sort-Object deleteOrder, category, kind, displayName)
Write-Host ""
Write-Host "Discovered $($sorted.Count) resource(s):" -ForegroundColor Green
$sorted | ForEach-Object { Write-Host ("  [{0}] {1} — {2}" -f $_.category, $_.kind, $_.displayName) -ForegroundColor Gray }

$json = if ($sorted.Count -eq 1) { '[' + ($sorted | ConvertTo-Json -Depth 8) + ']' } else { $sorted | ConvertTo-Json -Depth 8 }
if ([string]::IsNullOrWhiteSpace($json)) { $json = '[]' }
if ($OutFile) {
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Set-Content -LiteralPath $OutFile -Value $json -Encoding utf8
    Write-Host "Wrote discovery to $OutFile" -ForegroundColor Cyan
}
else {
    $json
}
