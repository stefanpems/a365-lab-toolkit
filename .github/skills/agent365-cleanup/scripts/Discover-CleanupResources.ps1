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

  Agent instances are frequently given custom names at hire time (e.g. `AFDHDW3I1`) that do NOT contain
  the agent name, so this script ALSO surfaces every user that holds a Frontier / Agent 365 license as a
  "license-identified" candidate. The mandatory human review is the safety net for both paths.

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
    [string]$OutFile
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
    # shared RG (e.g. rg-a365-foundry-agent used by FD) will simply not match a prefix filter.
    $rgs = Invoke-AzJson @('group', 'list', '--subscription', $sub, '-o', 'json')
    foreach ($rg in @($rgs)) {
        $n = $rg.name
        if ($n -notmatch [regex]::Escape($NameFilter)) { continue }
        if ($n -match '(?i)(ui-rg|mcp)') { continue }
        Add-Item -Category 'Agents' -Kind 'azure-rg' -Id $n -ObjectId $null -DisplayName $n `
            -Detail (Get-RgDetail $n) -Action 'delete-rg' -DeleteOrder 40 -Extra @{ location = $rg.location }
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

    # Agent instances (agent users). Two discovery paths, de-duplicated by id:
    #   (a) users whose display name matches the filter;
    #   (b) users holding a Frontier / Agent 365 license (catches custom-named instances).
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

    # (b) license-identified users. Find the agent SKUs, then query users holding each.
    $map = Get-SkuMap
    $agentSkuIds = @()
    foreach ($kv in $map.GetEnumerator()) {
        if ($kv.Value -match '(?i)(FRONTIER|AGENT[_ ]?365)') { $agentSkuIds += $kv.Key }
    }
    foreach ($skuId in $agentSkuIds) {
        foreach ($u in (Get-GraphFiltered 'users' "assignedLicenses/any(x:x/skuId eq $skuId)" @('ConsistencyLevel=eventual'))) {
            & $addUser $u "holds agent license $($map[$skuId])"
        }
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
# Run the requested categories.
# ---------------------------------------------------------------------------
if ($Categories -contains 'WebUI') { Find-WebUi }
if ($Categories -contains 'CustomMcp') { Find-CustomMcp }
if ($Categories -contains 'Agents') { Find-Agents }

# ---------------------------------------------------------------------------
# Emit.
# ---------------------------------------------------------------------------
# De-duplicate: the same recycle-bin object can match more than one category filter (e.g. an
# ext_<Name> object matches both the CustomMcp and the Agents deleted-item scan). Keep the first
# occurrence per (kind, objectId); genuinely distinct objects have distinct objectIds and are kept.
$seenKey = @{}
$dedup = New-Object System.Collections.Generic.List[object]
foreach ($it in $items) {
    if ($it.objectId) {
        $k = "$($it.kind)|$($it.objectId)"
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
