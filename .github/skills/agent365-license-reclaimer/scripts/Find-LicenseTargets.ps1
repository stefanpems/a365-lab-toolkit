#requires -Version 7.0
<#
.SYNOPSIS
  READ-ONLY discovery for the License Reclaimer wizard: list the tenant's license SKUs, or find the
  users that hold a selected set of SKUs. Performs NO mutations.

.DESCRIPTION
  Two actions:

    ListSkus   Enumerate every subscribed SKU in the tenant (Microsoft Graph /subscribedSkus), classify
               each into the wizard's license categories (Frontier for Autopilots, Teams Enterprise, E5,
               E7, Agent 365, Teams), and flag which categories are pre-selected by default (Frontier +
               Teams Enterprise, when present). The wizard shows only the categories that exist in the
               tenant.

    FindUsers  Given the target SKU ids the operator picked and a user selector, return every user that
               actually HOLDS one or more of those SKUs, with the exact target SKUs each holds and — when
               -IncludeDependents is set — the dependent add-on SKUs (Project, Visio, Teams Phone, Audio
               Conferencing, Power BI, Power Apps/Automate, …) each also holds. The removal script uses
               this to know what to remove per user.

  All Graph calls use a token from `az account get-access-token` via Invoke-RestMethod (robust against
  az.cmd argument parsing of `$select`/`$filter` commas on Windows). The subscription is pinned and the
  tenant is asserted before any call, because Graph uses the active az account, not `--subscription`.

.PARAMETER Action
  ListSkus or FindUsers.

.PARAMETER Subscription
  Target subscription id. Pins the az context (guards the tenant assertion).

.PARAMETER TenantId
  Expected tenant id. The script aborts if the signed-in az context is a different tenant.

.PARAMETER SkuIds
  (FindUsers) The target SKU ids to search for (the operator's selection from ListSkus).

.PARAMETER Selector
  (FindUsers) How to identify users: ObjectId (ids or UPNs in -SelectorValues), Prefix (a name/UPN
  prefix in -SelectorValues[0], matched against displayName/givenName/surname/userPrincipalName), or
  All (every holder of the target SKUs).

.PARAMETER SelectorValues
  (FindUsers) The object ids / UPNs (ObjectId) or the single prefix (Prefix). Ignored for All.

.PARAMETER IncludeDependents
  (FindUsers) Also surface each matched user's dependent add-on SKUs.

.PARAMETER OutFile
  Optional path to write the JSON result to (the wizard passes a path under
  generated/license-reclaimer/<timestamp>/).

.EXAMPLE
  pwsh -File .\Find-LicenseTargets.ps1 -Action ListSkus -Subscription <sub> -TenantId <tenant> `
      -OutFile .\skus.json

.EXAMPLE
  pwsh -File .\Find-LicenseTargets.ps1 -Action FindUsers -Subscription <sub> -TenantId <tenant> `
      -SkuIds <guid1>,<guid2> -Selector Prefix -SelectorValues afdw -IncludeDependents -OutFile .\users.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('ListSkus', 'FindUsers')][string]$Action,
    [Parameter(Mandatory)][string]$Subscription,
    [string]$TenantId,
    [string[]]$SkuIds,
    [ValidateSet('ObjectId', 'Prefix', 'All')][string]$Selector,
    [string[]]$SelectorValues,
    [switch]$IncludeDependents,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ---------------------------------------------------------------------------
# Friendly names and category / add-on classification.
# ---------------------------------------------------------------------------
# Commercial display names are not exposed by Graph; map the lab-relevant ones and fall back to the
# skuPartNumber for the rest.
$FriendlyMap = @{
    'Microsoft_Teams_Enterprise' = 'Microsoft Teams Enterprise'
    'TEAMS_ENTERPRISE'           = 'Microsoft Teams Enterprise'
    'SPE_E5'                     = 'Microsoft 365 E5'
    'ENTERPRISEPREMIUM'          = 'Office 365 E5'
    'SPE_E3'                     = 'Microsoft 365 E3'
    'ENTERPRISEPACK'             = 'Office 365 E3'
    'PROJECTPROFESSIONAL'        = 'Project Plan 3'
    'PROJECTPREMIUM'             = 'Project Plan 5'
    'VISIOCLIENT'                = 'Visio Plan 2'
    'MCOEV'                      = 'Microsoft Teams Phone Standard'
    'MCOMEETADV'                 = 'Microsoft 365 Audio Conferencing'
    'POWER_BI_PRO'               = 'Power BI Pro'
    'FLOW_FREE'                  = 'Microsoft Power Automate Free'
}

function Get-SkuFriendlyName {
    param([string]$Part)
    if ($FriendlyMap.ContainsKey($Part)) { return $FriendlyMap[$Part] }
    return $Part
}

# The six wizard categories. Order matters: Teams Enterprise is tested before the generic Teams bucket,
# and E7 before E5, so a more specific match wins.
function Get-SkuCategory {
    param([string]$Part, [string]$Friendly)
    $s = "$Part $Friendly"
    if ($s -match '(?i)frontier') { return 'Frontier' }
    if ($s -match '(?i)teams[_ ]?enterprise') { return 'TeamsEnterprise' }
    if ($s -match '(?i)(_|\b)E7(\b|_)') { return 'E7' }
    if ($s -match '(?i)((_|\b)E5(\b|_)|SPE_E5|ENTERPRISEPREMIUM)') { return 'E5' }
    if ($s -match '(?i)agent[_ ]?365') { return 'Agent365' }
    if ($s -match '(?i)teams') { return 'Teams' }
    return $null
}

$CategoryLabels = [ordered]@{
    Frontier        = 'Microsoft 365 Frontier for Autopilots (no Teams)'
    TeamsEnterprise = 'Microsoft Teams Enterprise'
    E5              = 'Microsoft 365 / Office 365 E5'
    E7              = 'Microsoft 365 E7'
    Agent365        = 'Agent 365'
    Teams           = 'Microsoft Teams (standalone)'
}

# Dependent add-on SKUs: products that typically require a qualifying base plan. When a base removal is
# blocked by one of these and the operator granted permission, the removal script also removes them.
function Test-IsAddOn {
    param([string]$Part, [string]$Friendly)
    $s = "$Part $Friendly"
    return [bool]($s -match '(?i)(project|visio|MCOEV|PHONESYSTEM|MCOPSTN|MCOMEETADV|MCOCAP|AUDIO[_ ]?CONFERENC|POWER[_ ]?BI|FLOW_|POWERAUTOMATE|POWER[_ ]?AUTOMATE|POWERAPPS|POWER[_ ]?APPS|TEAMS[_ ]?PHONE|CALLING)')
}

# ---------------------------------------------------------------------------
# Context + Graph helpers.
# ---------------------------------------------------------------------------
az account set --subscription $Subscription | Out-Null
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' first." }
if ($TenantId -and $ctx.tenantId -ne $TenantId) {
    throw "az context tenant '$($ctx.tenantId)' != -TenantId '$TenantId'. Re-pin the context and retry."
}
$graphToken = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($graphToken)) {
    throw "Failed to acquire a Microsoft Graph token. Run: az login --tenant $($ctx.tenantId) --scope https://graph.microsoft.com/.default"
}

function Invoke-GraphGet {
    param([string]$Url)
    Invoke-RestMethod -Method GET -Uri $Url -Headers @{ Authorization = "Bearer $graphToken" }
}
function Get-GraphPaged {
    param([string]$Url)
    $items = New-Object System.Collections.Generic.List[object]
    $next = $Url
    while ($next) {
        $r = Invoke-GraphGet -Url $next
        if ($r.value) { foreach ($v in $r.value) { $items.Add($v) } }
        $next = $r.'@odata.nextLink'
    }
    return $items
}

function Get-SubscribedSkus {
    $skus = (Invoke-GraphGet -Url 'https://graph.microsoft.com/v1.0/subscribedSkus').value
    $out = foreach ($s in $skus) {
        $friendly = Get-SkuFriendlyName -Part $s.skuPartNumber
        [pscustomobject]@{
            skuId         = $s.skuId
            skuPartNumber = $s.skuPartNumber
            friendlyName  = $friendly
            category      = Get-SkuCategory -Part $s.skuPartNumber -Friendly $friendly
            isAddOn       = Test-IsAddOn -Part $s.skuPartNumber -Friendly $friendly
            enabledUnits  = $s.prepaidUnits.enabled
            consumedUnits = $s.consumedUnits
        }
    }
    return @($out)
}

# ---------------------------------------------------------------------------
# ListSkus
# ---------------------------------------------------------------------------
if ($Action -eq 'ListSkus') {
    $all = @(Get-SubscribedSkus | Where-Object { $_.enabledUnits -gt 0 })
    $categories = foreach ($key in $CategoryLabels.Keys) {
        $matched = @($all | Where-Object { $_.category -eq $key })
        if ($matched.Count -eq 0) { continue }
        [pscustomobject]@{
            category      = $key
            label         = $CategoryLabels[$key]
            defaultSelect = ($key -in @('Frontier', 'TeamsEnterprise'))
            skus          = @($matched | ForEach-Object {
                    [pscustomobject]@{ skuId = $_.skuId; skuPartNumber = $_.skuPartNumber; friendlyName = $_.friendlyName; consumedUnits = $_.consumedUnits; enabledUnits = $_.enabledUnits }
                })
        }
    }
    $result = [pscustomobject]@{
        tenantId   = $ctx.tenantId
        categories = @($categories)
        allSkus    = $all
    }
    $json = $result | ConvertTo-Json -Depth 8
    if ($OutFile) {
        $dir = Split-Path -Parent $OutFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Set-Content -LiteralPath $OutFile -Value $json -Encoding utf8
    }
    Write-Output $json
    return
}

# ---------------------------------------------------------------------------
# FindUsers
# ---------------------------------------------------------------------------
if (-not $SkuIds -or $SkuIds.Count -eq 0) { throw "FindUsers requires -SkuIds (the target SKU ids)." }
if (-not $Selector) { throw "FindUsers requires -Selector (ObjectId | Prefix | All)." }
if ($Selector -in @('ObjectId', 'Prefix') -and (-not $SelectorValues -or $SelectorValues.Count -eq 0)) {
    throw "Selector '$Selector' requires -SelectorValues."
}

$skuMap = @{}
foreach ($s in (Get-SubscribedSkus)) { $skuMap[$s.skuId] = $s }
$targetSet = @{}; foreach ($id in $SkuIds) { $targetSet[$id] = $true }

# Pull every user once with the properties we need (assignedLicenses is not a default property, so it
# must be $select-ed). Lab tenants are small; client-side filtering keeps the OData simple and robust.
$users = Get-GraphPaged -Url 'https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName,givenName,surname,assignedLicenses&$top=999'

function Test-SelectorMatch {
    param($User)
    switch ($Selector) {
        'All' { return $true }
        'ObjectId' {
            foreach ($v in $SelectorValues) {
                if ($User.id -eq $v) { return $true }
                if ($User.userPrincipalName -and $User.userPrincipalName.ToLower() -eq $v.ToLower()) { return $true }
            }
            return $false
        }
        'Prefix' {
            $p = $SelectorValues[0].ToLower()
            foreach ($f in @($User.displayName, $User.givenName, $User.surname, $User.userPrincipalName)) {
                if ($f -and $f.ToLower().StartsWith($p)) { return $true }
            }
            return $false
        }
    }
}

$matchedUsers = New-Object System.Collections.Generic.List[object]
foreach ($u in $users) {
    if (-not (Test-SelectorMatch -User $u)) { continue }
    $held = @($u.assignedLicenses | ForEach-Object { $_.skuId } | Where-Object { $_ })
    $heldTargets = @($held | Where-Object { $targetSet.ContainsKey($_) })
    if ($heldTargets.Count -eq 0) { continue }

    $targetObjs = foreach ($id in $heldTargets) {
        $m = $skuMap[$id]
        [pscustomobject]@{ skuId = $id; skuPartNumber = $m.skuPartNumber; friendlyName = $m.friendlyName }
    }
    $dependentObjs = @()
    if ($IncludeDependents) {
        $dep = @($held | Where-Object { -not $targetSet.ContainsKey($_) -and $skuMap[$_] -and $skuMap[$_].isAddOn })
        $dependentObjs = foreach ($id in $dep) {
            $m = $skuMap[$id]
            [pscustomobject]@{ skuId = $id; skuPartNumber = $m.skuPartNumber; friendlyName = $m.friendlyName }
        }
    }

    $matchedUsers.Add([pscustomobject]@{
            id                = $u.id
            displayName       = $u.displayName
            userPrincipalName = $u.userPrincipalName
            targetSkus        = @($targetObjs)
            dependentSkus     = @($dependentObjs)
        })
}

$result = [pscustomobject]@{
    tenantId          = $ctx.tenantId
    selector          = $Selector
    includeDependents = [bool]$IncludeDependents
    targetSkuIds      = @($SkuIds)
    users             = @($matchedUsers)
}
$json = $result | ConvertTo-Json -Depth 8
if ($OutFile) {
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Set-Content -LiteralPath $OutFile -Value $json -Encoding utf8
}
Write-Output $json
