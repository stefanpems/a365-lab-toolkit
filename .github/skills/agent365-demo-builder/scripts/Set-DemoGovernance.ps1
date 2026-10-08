#requires -Version 7.0
<#
.SYNOPSIS
  Entra governance objects of the demo (build phase): custom security attribute set/definition/allowed values, the user
  owner + sponsor + attribute value of every agent identity, and the entitlement catalog with its group resource(s).
.DESCRIPTION
  Data-driven: pack.json agents[].entraOwner / sponsor / sponsorOn / attribute and governance.*; names from the locale.
  Steps (-Step, comma-separated, default all):
    attributes  attribute set + definition + allowed values (delegated: CustomSecAttributeDefinition.ReadWrite.All)
    identities  per agent identity: user owner, sponsor (exclusive) and attribute value, through application-only APIs
                (temporary app, deleted at the end). Identities: code agents by the agenticAppId of their Lab Builder
                config, Digital Worker instances by blueprint (sponsorOn: instance), the others by their localized
                identity name. Identities that do not exist yet (e.g. an agent not published yet) are skipped: re-run.
    catalog     entitlement catalog + its group resource(s) (delegated: EntitlementManagement.ReadWrite.All)
  Done in the portal with the guided cards of New-DemoCards.ps1, as in the reference lab: the Conditional Access
  policies, the access package and its policy, Purview, Defender and the admin-center templates. The custom security
  attribute roles are needed even by a Global Administrator (docs/demo-environment-prerequisites.md). Registry owners
  (Agent 365 catalog) are starting conditions: they are set by the agent365-demo-reset skill.
.EXAMPLE
  pwsh -File .\Set-DemoGovernance.ps1 -Prefix cts2 -WhatIf
.EXAMPLE
  pwsh -File .\Set-DemoGovernance.ps1 -Prefix cts2 -Step identities
#>
[CmdletBinding(PositionalBinding = $false)]
param([Parameter(Mandatory)][string]$Prefix, [string[]]$Step = @('all'), [switch]$WhatIf)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_demo-common.ps1')
. (Join-Path $PSScriptRoot '_demo-entra.ps1')
$Step = @($Step | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($s in $Step) { if ($s -notin 'all', 'attributes', 'identities', 'catalog') { throw "Unknown step '$s' (all, attributes, identities, catalog)." } }
$cfg = Read-DemoConfig $Prefix
$pack = Get-DemoPack $cfg.pack
$LOC = Get-DemoLocale -Locale $cfg.locale -Pack $cfg.pack
$state = Read-DemoLabState $Prefix
$gov = $LOC.governance
$G = 'https://graph.microsoft.com'
$setId = [string]$gov.attributeSet.id
$attrName = [string]$gov.attribute.name
$defId = "${setId}_$attrName"
function Test-Step([string]$S) { $Step -contains 'all' -or $Step -contains $S }
function Get-Upn([string]$Key) { "$(Get-DemoPersonaAlias $LOC $Key)@$($cfg.domain)" }
$script:delegated = $null
function Get-Delegated {
    # -ForceRefresh: a cached access token minted before a directory role change (Attribute Definition/Assignment
    # Administrator) would still be denied with 403; the refresh token is reused, no browser.
    if (-not $script:delegated) { $script:delegated = Get-DemoMsalToken -TenantId $cfg.tenantId -Prefix $Prefix -LoginHint $cfg.adminUpn -Scopes @('CustomSecAttributeDefinition.ReadWrite.All', 'EntitlementManagement.ReadWrite.All', 'Group.Read.All') -ForceRefresh }
    return $script:delegated
}
# $true when a -NoThrow GET says 404; any other error stops with a hint.
function Test-Missing($R, [string]$What, [string]$Hint) {
    if (-not ($R -and $R.PSObject.Properties['error'])) { return $false }
    if ($R.status -eq 404) { return $true }
    throw "${What}: $($R.error)$(if ($Hint) { " ($Hint)" })"
}
Assert-DemoTenant $cfg
Write-DemoLog $Prefix "Demo governance ($($cfg.locale)): steps [$($Step -join ', ')]$(if ($WhatIf) { ' [WhatIf]' })"

# --- 1. Custom security attribute: set, definition, allowed values ------------------------------------------------
if (Test-Step 'attributes') {
    $vals = @($pack.governance.attribute.values | ForEach-Object { [string]$gov.attribute.values[$_] })
    Write-Host "  attribute $setId/$attrName, values [$($vals -join ', ')]"
    if (-not $WhatIf) {
        $t = Get-Delegated
        $hint = 'the operator needs the Attribute Definition Administrator role, see docs/demo-environment-prerequisites.md'
        if (Test-Missing (Invoke-DemoGraph GET "$G/v1.0/directory/attributeSets/$setId" -Token $t -NoThrow) "attribute set $setId" $hint) {
            Invoke-DemoGraph POST "$G/v1.0/directory/attributeSets" -Token $t -Body @{ id = $setId; description = [string]$gov.attributeSet.description; maxAttributesPerSet = 25 } | Out-Null
            Write-DemoLog $Prefix "Attribute set $setId created"
        }
        if (Test-Missing (Invoke-DemoGraph GET "$G/v1.0/directory/customSecurityAttributeDefinitions/$defId" -Token $t -NoThrow) "attribute $defId" $hint) {
            Invoke-DemoGraph POST "$G/v1.0/directory/customSecurityAttributeDefinitions" -Token $t -Body @{ attributeSet = $setId; name = $attrName; description = [string]$gov.attribute.description
                type = 'String'; status = 'Available'; isCollection = $false; isSearchable = $true; usePreDefinedValuesOnly = $true } | Out-Null
            Write-DemoLog $Prefix "Attribute $setId/$attrName created"
        }
        $have = @((Invoke-DemoGraph GET "$G/v1.0/directory/customSecurityAttributeDefinitions/$defId/allowedValues" -Token $t).value | ForEach-Object { $_.id })
        foreach ($v in $vals) {
            if ($have -contains $v) { continue }
            Invoke-DemoGraph POST "$G/v1.0/directory/customSecurityAttributeDefinitions/$defId/allowedValues" -Token $t -Body @{ id = $v; isActive = $true } | Out-Null
            Write-DemoLog $Prefix "Allowed value $v added"
        }
        $state.governance['attribute'] = [ordered]@{ set = $setId; name = $attrName; values = $vals }
        Save-DemoLabState $Prefix $state
    }
}
# --- 2. Agent identities: user owner, sponsor, attribute value (application-only APIs) ---------------------------
if (Test-Step 'identities') {
    $plan = Get-DemoIdentityPlan $Prefix $pack $LOC
    foreach ($p in $plan) {
        $what = @()
        if ($p.def.entraOwner) { $what += "owner $(Get-Upn $p.def.entraOwner)" }
        if ($p.def.sponsor) { $what += "sponsor $(Get-Upn $p.def.sponsor)$(if ($p.def.sponsorOn -eq 'instance') { ' (on each instance)' })" }
        if ($p.def.attribute) { $what += "$attrName=$($gov.attribute.values[$p.def.attribute])" }
        foreach ($dr in @($p.def.directAppRoles | Where-Object { $_ })) { $what += "app permission $($dr.resource) $($dr.role)" }
        Write-Host ("  {0,-28} identities {1}: {2}" -f $p.name, $p.identities.Count, ($what -join ', '))
    }
    $missing = @($plan | Where-Object { -not $_.identities.Count })
    if ($missing.Count) { Write-DemoLog $Prefix "Agent identities not found yet (skipped; re-run after they exist): $(@($missing | ForEach-Object { $_.name }) -join ', ')" 'WARN' }
    $todo = @($plan | Where-Object { $_.identities.Count })
    if (-not $WhatIf -and $todo.Count) {
        $users = @{}
        foreach ($k in @($todo | ForEach-Object { $_.def.entraOwner; $_.def.sponsor } | Where-Object { $_ } | Select-Object -Unique)) {
            $users[$k] = (Invoke-DemoGraph GET "$G/v1.0/users/$([uri]::EscapeDataString((Get-Upn $k)))?`$select=id").id
        }
        $roles = @('AgentIdentity.ReadWrite.All')
        if (@($todo | Where-Object { $_.def.attribute }).Count) { $roles += 'CustomSecAttributeAssignment.ReadWrite.All' }
        if (@($todo | Where-Object { @($_.def.directAppRoles | Where-Object { $_ }).Count }).Count) { $roles += 'AppRoleAssignment.ReadWrite.All' }
        if (-not $state.governance.Contains('identities')) { $state.governance['identities'] = [ordered]@{} }
        $session = $null
        try {
            $session = New-DemoAppOnlySession -Prefix $Prefix -TenantId $cfg.tenantId -Roles $roles
            foreach ($p in $todo) {
                $rows = @(foreach ($id in $p.identities) {
                    $r = [ordered]@{ identityId = $id.id; displayName = $id.displayName }
                    try {
                        if ($p.def.entraOwner) { $r['owners'] = (Set-DemoIdentityOwner $session $id.id $users[$p.def.entraOwner] -ExclusiveUser) -join ', ' }
                        if ($p.def.sponsor) { $r['sponsors'] = (Set-DemoIdentitySponsor $session $id.id $users[$p.def.sponsor] -Exclusive) -join ', ' }
                        if ($p.def.attribute) { $r['attribute'] = Set-DemoIdentityAttribute $session $id.id $setId $attrName ([string]$gov.attribute.values[$p.def.attribute]) }
                        # Direct application permissions (D9: the test twin answers before the block and fails after it).
                        if ($id -eq $p.identities[0]) {
                            foreach ($dr in @($p.def.directAppRoles | Where-Object { $_ })) { $r["appRole:$($dr.role)"] = Set-DemoIdentityAppRole $session $id.id ([string]$dr.resource) ([string]$dr.role) }
                        }
                    }
                    catch { $r['error'] = $_.Exception.Message }
                    Write-DemoLog $Prefix ('Identity {0} ({1}): owners=[{2}] sponsors=[{3}]{4}{5}' -f $id.displayName, $p.key, $r.owners, $r.sponsors, $(if ($r.Contains('attribute')) { " $attrName=[$($r.attribute)]" }), $(if ($r.error) { " ERROR: $($r.error)" })) $(if ($r.error) { 'ERROR' } else { 'INFO' })
                    $r
                })
                $state.governance.identities[$p.key] = $rows
            }
        }
        finally { Close-DemoAppOnlySession $session; Save-DemoLabState $Prefix $state }
    }
    # Blueprints of the code agents: the Entra owner is added as co-owner, the admin stays (reference lab); blueprint
    # sponsors are not settable (403), they stay the creator's.
    foreach ($a in @($pack.agents | Where-Object { $_.platform -eq 'code' -and $_.entraOwner })) {
        $la = $LOC.agents[$a.key]
        $gcFile = Join-Path $script:DemoRepoRoot "generated\$Prefix\$($la.codeName)\a365.generated.config.json"
        if (-not (Test-Path -LiteralPath $gcFile)) { continue }
        $bpApp = [string](Get-Content -LiteralPath $gcFile -Raw | ConvertFrom-Json).agentBlueprintId
        if (-not $bpApp) { continue }
        $bp = Invoke-DemoGraph GET "$G/v1.0/applications(appId='$bpApp')?`$select=id,displayName" -NoThrow
        if ($bp -and $bp.PSObject.Properties['error']) { Write-DemoLog $Prefix "Blueprint of $($la.displayName) not readable ($($bp.status))" 'WARN'; continue }
        $ownerUpn = Get-Upn $a.entraOwner
        $uid = (Invoke-DemoGraph GET "$G/v1.0/users/$([uri]::EscapeDataString($ownerUpn))?`$select=id").id
        $cur = @((Invoke-DemoGraph GET "$G/v1.0/applications/$($bp.id)/owners?`$select=id" -All) | ForEach-Object { $_.id })
        if ($cur -contains $uid) { continue }
        if ($WhatIf) { Write-Host "  would add $ownerUpn as co-owner of the blueprint '$($bp.displayName)'"; continue }
        $r = Invoke-DemoGraph POST "$G/v1.0/applications/$($bp.id)/owners/`$ref" -Body @{ '@odata.id' = "$G/v1.0/directoryObjects/$uid" } -NoThrow
        Write-DemoLog $Prefix "Blueprint '$($bp.displayName)': co-owner $ownerUpn $(if ($r -and $r.PSObject.Properties['error']) { "FAILED ($($r.status))" } else { 'added' })" $(if ($r -and $r.PSObject.Properties['error']) { 'WARN' } else { 'INFO' })
    }
}

# --- 3. Entitlement catalog + group resource(s) (the access package itself: guided card) ------------------------
if (Test-Step 'catalog') {
    $catName = [string]$gov.catalog.name
    $groupKeys = @($pack.governance.entitlement.resources | Where-Object { $_ -like 'group:*' } | ForEach-Object { $_.Substring(6) })
    Write-Host "  catalog '$catName', group resource(s) [$(@($groupKeys | ForEach-Object { $LOC.groups[$_].displayName }) -join ', ')]"
    if (-not $WhatIf) {
        $t = Get-Delegated
        $esc = { param([string]$v) $v.Replace("'", "''") }
        $cat = (Invoke-DemoGraph GET "$G/v1.0/identityGovernance/entitlementManagement/catalogs?`$filter=displayName eq '$(& $esc $catName)'" -Token $t).value | Select-Object -First 1
        if (-not $cat) {
            $cat = Invoke-DemoGraph POST "$G/v1.0/identityGovernance/entitlementManagement/catalogs" -Token $t -Body @{ displayName = $catName; description = [string]$gov.catalog.description; isExternallyVisible = $false }
            Write-DemoLog $Prefix "Catalog created: $catName"
        }
        $inCat = @((Invoke-DemoGraph GET "$G/v1.0/identityGovernance/entitlementManagement/catalogs/$($cat.id)/resources?`$select=originId" -Token $t -All) | ForEach-Object { $_.originId })
        foreach ($gk in $groupKeys) {
            $gn = [string]$LOC.groups[$gk].displayName
            $grp = (Invoke-DemoGraph GET "$G/v1.0/groups?`$filter=displayName eq '$(& $esc $gn)'&`$select=id" -Token $t).value | Select-Object -First 1
            if (-not $grp) { Write-DemoLog $Prefix "Group '$gn' not found: run Set-DemoIdentities.ps1 first" 'WARN'; continue }
            if ($inCat -contains $grp.id) { continue }
            Invoke-DemoGraph POST "$G/v1.0/identityGovernance/entitlementManagement/resourceRequests" -Token $t -Body @{ requestType = 'adminAdd'; resource = @{ originId = $grp.id; originSystem = 'AadGroup' }; catalog = @{ id = $cat.id } } | Out-Null
            Write-DemoLog $Prefix "Group '$gn' added to the catalog"
        }
        $state.governance['catalog'] = [ordered]@{ id = $cat.id; name = $catName }
        Save-DemoLabState $Prefix $state
    }
}
Write-DemoLog $Prefix 'Demo governance done. Next (portal, guided): New-DemoCards.ps1 cards for Conditional Access, the access package, Purview, Defender and the admin-center templates.'
