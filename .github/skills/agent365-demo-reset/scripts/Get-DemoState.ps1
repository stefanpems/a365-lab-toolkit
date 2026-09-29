#requires -Version 7.0
<#
.SYNOPSIS
  READ-ONLY pre-flight of a demo lab: compares the tenant with the starting conditions of the demo pack and prints, per
  demo, OK / KO / WARN / MANUAL / INFO with the fix. Writes generated/<prefix>/demo/demo-state.md and demo-state.json.
.DESCRIPTION
  Starting conditions come from pack.json (personas, agents[].registryOwner / entraOwner / sponsor / attribute /
  baseline, governance, mcp, operatorSlots, demos[].manualReset), names from the lab locale, ids from state.json and the
  Lab Builder configs. -Demo selects demo codes (D1..D17) and/or the areas People, Registry, Entra, Mcp; default All.
  The only write is local: the catalog package ids found by name are remembered in state.json (agents.<key>.packages).
.EXAMPLE
  pwsh -File .\Get-DemoState.ps1 -Prefix cts2
.EXAMPLE
  pwsh -File .\Get-DemoState.ps1 -Prefix cts2 -Demo D5,D10
#>
[CmdletBinding(PositionalBinding = $false)]
param([Parameter(Mandatory)][string]$Prefix, [string[]]$Demo = @('All'), [switch]$AsObject)
$ErrorActionPreference = 'Stop'
$builder = Join-Path $PSScriptRoot '..\..\agent365-demo-builder\scripts'
. (Join-Path $builder '_demo-common.ps1')
. (Join-Path $builder '_demo-entra.ps1')
. (Join-Path $PSScriptRoot '_demo-registry.ps1')
$Demo = @($Demo | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$cfg = Read-DemoConfig $Prefix
$pack = Get-DemoPack $cfg.pack
$LOC = Get-DemoLocale -Locale $cfg.locale -Pack $cfg.pack
$state = Read-DemoLabState $Prefix
Assert-DemoTenant $cfg
$G = $script:DemoG
$checks = [System.Collections.Generic.List[object]]::new()
function Add-Check([string]$Tag, [string]$Item, [string]$Expected, [string]$Actual, [ValidateSet('OK', 'KO', 'WARN', 'INFO', 'MANUAL')][string]$Status, [string]$Fix = '') {
    $checks.Add([pscustomobject]@{ Status = $Status; Demo = $Tag; Item = $Item; Expected = $Expected; Actual = $Actual; Fix = $Fix })
}
function Test-Sel([string[]]$Tags) { if ($Demo -contains 'All') { return $true }; foreach ($t in $Tags) { if ($Demo -contains $t) { return $true } }; return $false }
function Test-Err($R) { return ($null -eq $R) -or ($R.PSObject.Properties['error'] -and $R.PSObject.Properties['status'] -and @($R.PSObject.Properties).Count -eq 2) }
function Get-Upn([string]$Key) { Get-DemoUpn $LOC $cfg $Key }
$script:userIds = @{}
function Get-UserId([string]$Key) {
    if (-not $script:userIds.ContainsKey($Key)) { $r = Invoke-DemoGraph GET "$G/v1.0/users/$([uri]::EscapeDataString((Get-Upn $Key)))?`$select=id" -NoThrow -MaxRetries 1; $script:userIds[$Key] = if (Test-Err $r) { $null } else { [string]$r.id } }
    return $script:userIds[$Key]
}
function Get-Name([string]$Id) {
    if (-not $Id) { return '(none)' }
    $r = Invoke-DemoGraph GET "$G/v1.0/directoryObjects/${Id}?`$select=displayName" -NoThrow -MaxRetries 1
    if (Test-Err $r) { return "(deleted $Id)" }; return [string]$r.displayName
}
function Get-GroupId([string]$Key) {
    $n = ([string]$LOC.groups[$Key].displayName).Replace("'", "''")
    $r = Invoke-DemoGraph GET "$G/v1.0/groups?`$filter=displayName eq '$n'&`$select=id" -NoThrow -MaxRetries 1
    if (Test-Err $r) { return $null }; return [string](@($r.value) | Select-Object -First 1).id
}
Write-DemoLog $Prefix "Demo pre-flight (read-only) for: $($Demo -join ', ')"

# --- People and licenses -----------------------------------------------------------------------------------------
if (Test-Sel @('People')) {
    foreach ($p in $pack.personas) {
        $u = Invoke-DemoGraph GET "$G/v1.0/users/$([uri]::EscapeDataString((Get-Upn $p.key)))?`$select=id,accountEnabled,assignedLicenses" -NoThrow -MaxRetries 1
        $exists = -not (Test-Err $u)
        if ($p.leaver) { Add-Check (@($p.demos) -join ',') "leaver $(Get-Upn $p.key)" 'hard-deleted after creating and sharing the agent' $(if ($exists) { 'still exists' } else { 'gone' }) 'INFO'; continue }
        if (-not $exists) { Add-Check 'People' (Get-Upn $p.key) 'exists, enabled, licensed' 'MISSING' 'KO' 'Set-DemoIdentities.ps1'; continue }
        $st = if ($u.accountEnabled -and @($u.assignedLicenses).Count -ge @($p.licenses).Count) { 'OK' } else { 'KO' }
        Add-Check 'People' (Get-Upn $p.key) "enabled, $(@($p.licenses).Count)+ license(s)" "enabled=$($u.accountEnabled) licenses=$(@($u.assignedLicenses).Count)" $st $(if ($st -eq 'KO') { 'Set-DemoIdentities.ps1' } else { '' })
    }
    $skus = @(Invoke-DemoGraph GET "$G/v1.0/subscribedSkus" -All)
    foreach ($role in 'copilotUser', 'frontierAgent') {
        $part = [string]$cfg.licenseSkus[$role]
        $s = $skus | Where-Object { $_.skuPartNumber -eq $part } | Select-Object -First 1
        if (-not $s) { Add-Check 'Licenses' $part 'subscribed' 'MISSING' 'KO' 'docs/demo-environment-prerequisites.md (license gate)'; continue }
        $free = [int]$s.prepaidUnits.enabled - [int]$s.consumedUnits
        $need = if ($role -eq 'copilotUser') { '>= 1 free (temporary leaver of New-OrphanAgent.ps1)' } else { '>= 1 free per new Digital Worker instance' }
        Add-Check 'Licenses' $part $need "free $free of $($s.prepaidUnits.enabled)" $(if ($free -ge 1) { 'OK' } else { 'WARN' })
    }
}
# --- Registry (Agent 365 catalog) ---------------------------------------------------------------------------------
$ownerless = @(); $learned = $false
if (-not $state.Contains('agents')) { $state['agents'] = [ordered]@{} }
if (Test-Sel (@('Registry') + @($pack.agents | ForEach-Object { $_.demos }))) {
    foreach ($a in @($pack.agents)) {
        if (-not (Test-Sel (@('Registry') + @($a.demos)))) { continue }
        $tag = @($a.demos) -join ','; $nm = [string]$LOC.agents[$a.key].displayName
        if ($a.catalog -eq $false) { Add-Check $tag "${nm}: registry entry" 'none by design (no Microsoft channel)' 'not checked' 'INFO'; continue }
        $pk = Get-DemoAgentPackages $cfg $LOC $state $a
        if (-not @($pk.all).Count) { Add-Check $tag "${nm}: registry entry" "exists ('$(Get-DemoCatalogName $LOC $a)')" 'NOT FOUND' 'KO' 'create or publish it (cards), then re-run'; continue }
        $ids = @($pk.all | ForEach-Object { [string]$_.id })
        if (-not $state.agents.Contains($a.key)) { $state.agents[$a.key] = [ordered]@{} }
        if ((@($state.agents[$a.key].packages) -join ',') -ne ($ids -join ',')) { $state.agents[$a.key]['packages'] = $ids; $learned = $true }
        $own = if ($pk.shared) { $pk.shared } else { $pk.published }
        $scope = if ($pk.published) { $pk.published } else { $own }
        $ro = [string]$a.registryOwner
        if ($ro -eq 'none' -and [string]$a.variant -like '*-DW') { }   # a Digital Worker template has no owner and is not "ownerless"
        elseif ($ro -eq 'none') {
            $ol = Test-DemoOwnerless $own
            if ($ol) { $ownerless += $nm }
            Add-Check $tag "${nm}: registry owner" 'none (the creator left)' $(if ($ol) { 'ownerless' } else { Get-Name ([string]$own.ownerId) }) $(if ($ol) { 'OK' } else { 'KO' }) $(if ($ol) { '' } else { "New-OrphanAgent.ps1 -Agent $($a.key)" })
        }
        elseif ($ro) {
            $want = Get-UserId $ro; $act = [string]$own.ownerId
            if (Test-DemoOwnerless $own) { $ownerless += $nm }
            $shown = if ($act -and -not (Test-DemoObjectExists $act)) { "(deleted user $act)" } else { Get-Name $act }
            Add-Check $tag "${nm}: registry owner" (Get-Upn $ro) $shown $(if ($want -and $act -eq $want) { 'OK' } else { 'KO' }) 'Reset-DemoState.ps1 -Demo Registry -Apply'
        }
        $b = $a.baseline
        if (-not $b) { continue }
        if ($b.installedFor) {
            $who = [string]$b.installedFor
            $wantId = if ($who -like 'group:*') { Get-GroupId $who.Substring(6) } else { Get-UserId ($who -replace '^persona:', '') }
            $acq = @($scope.acquireUsersAndGroups | ForEach-Object { [string]$_.resourceId })
            Add-Check $tag "${nm}: installed for" $who "deployedTo=$($scope.deployedTo) [$((@($acq | ForEach-Object { Get-Name $_ })) -join ', ')]" $(if ($wantId -and $acq -contains $wantId) { 'OK' } else { 'KO' }) 'admin center > Agents > the published entry > Users (the API ignores install scopes)'
        }
        if ($null -ne $b.blocked) {
            $is = [bool]$scope.isBlocked; $exp = [bool]$b.blocked
            $st = if ($is -eq $exp) { 'OK' } elseif ($exp) { 'WARN' } else { 'KO' }
            $fix = if ($exp) { "block it the evening before, as $(Get-DemoPersonaDisplayName $LOC 'aiAdmin') in the admin center (admin-center card)" } else { 'Reset-DemoState.ps1 -Apply (unblock)' }
            Add-Check $tag "${nm}: blocked" "$exp" "$is" $st $(if ($st -eq 'OK') { '' } else { $fix })
        }
        if ($b.pendingRequest) {
            $rs = @($pk.all | ForEach-Object { "$($_.requestStatus)" }) -join ','
            Add-Check $tag "${nm}: publish request" 'pending (decided live)' "requestStatus=$rs" $(if ($rs -match '(?i)pending|submitted') { 'OK' } else { 'MANUAL' }) 'manual reset of the demo (resubmit the request)'
        }
        if ($b.usage) {
            $sess = (@($pk.all | ForEach-Object { [int]$_.totalSessions }) | Measure-Object -Maximum).Maximum
            Add-Check $tag "${nm}: usage" 'sessions > 0 (activity, map)' "sessions=$sess" $(if ($sess -gt 0) { 'OK' } else { 'WARN' }) 'traffic tests of the hand-out'
        }
        if ($b.exceptions) {
            $ex = (@($pk.all | ForEach-Object { [double]$_.exceptionRate }) | Measure-Object -Maximum).Maximum
            Add-Check $tag "${nm}: exceptions" 'exception rate > 0' "$ex" $(if ($ex -gt 0) { 'OK' } else { 'WARN' }) 'the traffic test with the simulated errors'
        }
    }
    if (Test-Sel @('D1', 'D5', 'D8', 'Registry')) {
        $exp = @($pack.agents | Where-Object { $_.baseline -and $_.baseline.ownerless } | ForEach-Object { [string]$LOC.agents[$_.key].displayName })
        $same = ((@($ownerless | Sort-Object -Unique) -join '|') -eq (@($exp | Sort-Object -Unique) -join '|'))
        Add-Check 'D1' 'Agents without owners' ($exp -join ', ') $(if ($ownerless) { (@($ownerless | Sort-Object -Unique) -join ', ') } else { '(none)' }) $(if ($same) { 'OK' } else { 'KO' }) 'New-OrphanAgent.ps1 / the D8 rule'
        Add-Check 'D1' 'Agents without owners (admin-center card)' ($exp -join ', ') 'API only: the card can lag for hours or keep a ghost owner' 'MANUAL' 'check the card as the AI administrator; plan B: the empty Owner column in All agents'
    }
    foreach ($a in @($pack.agents | Where-Object { $_.shareLinkOpenedBy })) {
        $pk = Get-DemoAgentPackages $cfg $LOC $state $a
        $id = if ($pk.shared) { $pk.shared.id } elseif ($pk.published) { $pk.published.id } else { $null }
        if (-not $id) { continue }
        $who = @($a.shareLinkOpenedBy | ForEach-Object { Get-DemoPersonaDisplayName $LOC $_ }) -join ', '
        Add-Check (@($a.demos) -join ',') "$($LOC.agents[$a.key].displayName): share link opened by $who" 'each recipient opened it once (shared agents are not listed anywhere)' "https://m365.cloud.microsoft/chat/?titleId=$id" 'MANUAL' 'open it signed in as each recipient (again after every orphan recreation)'
    }
    if ($learned) { Save-DemoLabState $Prefix $state }
}

# --- Entra: owners, sponsors, attribute, enabled, risk --------------------------------------------------------------
if (Test-Sel (@('Entra') + @($pack.agents | Where-Object { $_.entraOwner -or $_.sponsor -or $_.attribute } | ForEach-Object { $_.demos }))) {
    $blockedKeys = @($pack.agents | Where-Object { $_.baseline -and $_.baseline.blocked } | ForEach-Object { [string]$_.key })
    $riskKeys = @($pack.demos | Where-Object { $_.id -in 'D9', 'D17' } | ForEach-Object { $_.agents } | Select-Object -Unique)
    $gov = $LOC.governance
    foreach ($p in Get-DemoIdentityPlan $Prefix $pack $LOC) {
        if (-not (Test-Sel (@('Entra') + @($p.def.demos)))) { continue }
        $tag = if (@($p.def.demos | Where-Object { $_ }).Count) { @($p.def.demos) -join ',' } else { 'Entra' }
        if (-not $p.identities.Count) {
            $isDw = $p.def.sponsorOn -eq 'instance'
            Add-Check $tag "$($p.name): agent identity" 'exists' 'not found' $(if ($isDw) { 'KO' } else { 'WARN' }) $(if ($isDw) { 'create the Digital Worker instance (card)' } else { 'publish the agent, then Set-DemoGovernance.ps1 -Step identities' })
            continue
        }
        foreach ($id in $p.identities) {
            $label = "$($p.name): $($id.displayName)"
            $o = Invoke-DemoGraph GET "$G/beta/servicePrincipals/$($id.id)/owners?`$select=id,displayName" -NoThrow
            $userOwners = @(if (-not (Test-Err $o)) { @($o.value) | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.user' } })
            $s = Invoke-DemoGraph GET "$G/beta/servicePrincipals/$($id.id)/microsoft.graph.agentIdentity/sponsors?`$select=id,displayName" -NoThrow
            $sponsors = @(if (-not (Test-Err $s)) { @($s.value) })
            $okO = (-not $p.def.entraOwner) -or ($userOwners.Count -eq 1 -and $userOwners[0].id -eq (Get-UserId $p.def.entraOwner))
            $okS = (-not $p.def.sponsor) -or ($sponsors.Count -eq 1 -and $sponsors[0].id -eq (Get-UserId $p.def.sponsor))
            $expText = @($(if ($p.def.entraOwner) { "owner $(Get-DemoPersonaDisplayName $LOC $p.def.entraOwner)" }), $(if ($p.def.sponsor) { "sponsor $(Get-DemoPersonaDisplayName $LOC $p.def.sponsor)" })) -join ' / '
            Add-Check $tag "${label}: owner / sponsor" $expText "owners=$(@($userOwners | ForEach-Object { $_.displayName }) -join ', ') sponsors=$(@($sponsors | ForEach-Object { $_.displayName }) -join ', ')" $(if ($okO -and $okS) { 'OK' } else { 'KO' }) 'Reset-DemoState.ps1 -Demo Entra -Apply'
            $sp = Invoke-DemoGraph GET "$G/beta/servicePrincipals/$($id.id)?`$select=accountEnabled" -NoThrow -MaxRetries 1
            # A blocked agent keeps its agent ID disabled by design: never flagged.
            if (-not (Test-Err $sp) -and -not $sp.accountEnabled -and $blockedKeys -notcontains $p.key) { Add-Check $tag "${label}: enabled" 'true' 'DISABLED' 'KO' 'Reset-DemoState.ps1 -Demo Entra -Apply' }
            if ($p.def.attribute -and $id -eq $p.identities[0]) {
                $want = [string]$gov.attribute.values[$p.def.attribute]
                $r = Invoke-DemoReg $cfg GET "$G/beta/servicePrincipals/$($id.id)?`$select=customSecurityAttributes"
                $v = if ($r.ok) { [string]$r.body.customSecurityAttributes.($gov.attributeSet.id).($gov.attribute.name) } else { "not readable ($($r.status)): the operator needs Attribute Assignment Reader" }
                Add-Check $tag "${label}: $($gov.attribute.name)" $want $v $(if ($v -eq $want) { 'OK' } elseif ($r.ok) { 'KO' } else { 'WARN' }) 'Reset-DemoState.ps1 -Demo D11 -Apply'
            }
            if ($riskKeys -contains $p.key -and $id -eq $p.identities[0]) {
                $lvl = Get-DemoAgentRisk $cfg $id.id
                Add-Check $tag "${label}: agent risk" 'none (dismissed or confirmed safe)' $lvl $(if ($lvl -match '^(none|low)' -or $lvl -match 'dismissed|confirmedSafe|remediated') { 'OK' } else { 'KO' }) 'Reset-DemoState.ps1 -Demo D9 -Apply'
            }
        }
    }
}
# --- Conditional Access and access package -------------------------------------------------------------------------
$gov = $LOC.governance
if (Test-Sel @($pack.governance.conditionalAccess | ForEach-Object { $_.demos })) {
    $r = Invoke-DemoReg $cfg GET "$G/v1.0/identity/conditionalAccess/policies?`$select=id,displayName,state"
    foreach ($ca in $pack.governance.conditionalAccess) {
        if (-not (Test-Sel @($ca.demos))) { continue }
        $name = [string]$gov.conditionalAccess[$ca.key]
        $pol = if ($r.ok) { @($r.body.value) | Where-Object { $_.displayName -eq $name } | Select-Object -First 1 } else { $null }
        Add-Check (@($ca.demos) -join ',') "Conditional Access '$name'" $ca.state $(if ($pol) { $pol.state } elseif ($r.ok) { 'MISSING' } else { "error $($r.status)" }) $(if ($pol -and $pol.state -eq $ca.state) { 'OK' } else { 'KO' }) 'Entra card'
    }
}
$ent = $pack.governance.entitlement
if ($ent -and (Test-Sel @($ent.demos))) {
    $tag = @($ent.demos) -join ','
    $apName = [string]$gov.accessPackage.name
    $flt = [uri]::EscapeDataString("displayName eq '$($apName.Replace("'", "''"))'")
    $r = Invoke-DemoReg $cfg GET "$G/v1.0/identityGovernance/entitlementManagement/accessPackages?`$filter=$flt"
    $ap = if ($r.ok) { @($r.body.value) | Select-Object -First 1 } else { $null }
    if (-not $ap) { Add-Check $tag "Access package '$apName'" 'exists' $(if ($r.ok) { 'MISSING' } else { "error $($r.status)" }) 'KO' 'Entra card, section 3' }
    else {
        $tp = Get-DemoIdentityPlan $Prefix $pack $LOC | Where-Object { $_.key -eq $ent.target } | Select-Object -First 1
        $tid = if ($tp -and $tp.identities.Count) { [string]$tp.identities[0].id } else { $null }
        $as = Invoke-DemoReg $cfg GET "$G/v1.0/identityGovernance/entitlementManagement/assignments?`$filter=accessPackage/id eq '$($ap.id)'&`$expand=target"
        $mine = @(if ($as.ok) { @($as.body.value) | Where-Object { $_.target.objectId -eq $tid -and $_.state -notin 'expired', 'deliveryFailed' } })
        Add-Check $tag "$($LOC.agents[$ent.target].displayName): access-package assignment" 'none before the live request' $(if ($mine.Count) { "$($mine.Count) active ($($mine[0].state))" } else { 'none' }) $(if ($mine.Count) { 'KO' } else { 'OK' }) 'Reset-DemoState.ps1 -Demo D10 -Apply'
    }
}

# --- Demo MCP servers and the reserve-name pool ---------------------------------------------------------------------
if (Test-Sel @('Mcp', 'D6')) {
    foreach ($k in @($pack.mcp.longLived | ForEach-Object { $_.key })) {
        $s = if ($state.mcp.servers -and $state.mcp.servers.Contains($k)) { $state.mcp.servers[$k] } else { $null }
        Add-Check 'D6' "MCP server $(if ($s) { $s.name } else { $LOC.mcp.servers[$k].name })" 'approved' $(if ($s) { $s.status } else { 'not registered' }) $(if ($s -and $s.status -eq 'approved') { 'OK' } else { 'KO' }) 'New-DemoMcpRegistration.ps1'
    }
    foreach ($b in $pack.mcp.pool) {
        $open = @($state.mcp.pool | Where-Object { $_ -and $_.key -eq $b.key -and $_.status -in 'pending', 'approved' })
        $isLive = @($b.roles) -contains 'live'
        $st = if ($open.Count -gt 1) { 'KO' } elseif ($open.Count -eq 1) { if ($isLive -and $open[0].status -ne 'pending') { 'KO' } else { 'OK' } } elseif ($isLive) { 'KO' } else { 'WARN' }
        Add-Check 'D6' "pool $($LOC.mcp.servers[$b.key].base)NN ($(@($b.roles) -join '/'))" $(if ($isLive) { 'exactly 1 PENDING instance' } else { 'at most 1 non-retired instance' }) $(if ($open.Count) { (@($open | ForEach-Object { "$($_.name) [$($_.status)]" }) -join ', ') } else { 'none' }) $st 'Reset-DemoState.ps1 -Demo D6 -Apply'
    }
}

# --- Knowledge documents that carry an operator slot -----------------------------------------------------------------
foreach ($sl in @($pack.operatorSlots | Where-Object { $_.kind -eq 'knowledgeText' -and $_.document })) {
    if (-not (Test-Sel @($sl.demos))) { continue }
    $doc = $pack.knowledge.documents | Where-Object { $_.key -eq $sl.document } | Select-Object -First 1
    $file = [string]$LOC.knowledge.documents[$sl.document].file
    $folder = [string]$LOC.knowledge.folders[$doc.folder]
    $hit = $null
    if ($state.knowledge -and $state.knowledge.driveId) {
        $r = Invoke-DemoReg $cfg GET "$G/v1.0/drives/$($state.knowledge.driveId)/root:/$([uri]::EscapeDataString($folder))/$([uri]::EscapeDataString($file))?`$select=name,lastModifiedDateTime"
        $hit = if ($r.ok) { $r.body } else { $null }
    }
    Add-Check (@($sl.demos) -join ',') "document with $($sl.id) in '$folder'" "present, built with the operator slot" $(if ($hit) { "present ($($hit.lastModifiedDateTime))" } elseif ($state.knowledge.driveId) { 'MISSING' } else { 'library not published yet' }) $(if ($hit) { 'OK' } else { 'KO' }) 'New-DemoKnowledge.ps1 with the operator slots file, then Publish-DemoKnowledge.ps1'
}

# --- Manual checks of the selected demos -----------------------------------------------------------------------------
foreach ($d in @($pack.demos | Where-Object { $_.manualReset })) {
    if (-not (Test-Sel @($d.id))) { continue }
    foreach ($m in $d.manualReset) { Add-Check $d.id 'manual check' '' (Expand-DemoText $m $LOC $cfg $state $pack) 'MANUAL' }
}

# --- Report ----------------------------------------------------------------------------------------------------------
$order = @{ KO = 0; WARN = 1; MANUAL = 2; INFO = 3; OK = 4 }
$rows = @($checks | Sort-Object @{ e = { $order[$_.Status] } }, Demo, Item)
$sum = ($checks | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
$dir = Get-DemoLabDir $Prefix
$md = @("# Demo state · lab $Prefix · $(Get-Date -Format 'yyyy-MM-dd HH:mm')", '', "Summary: $sum", '', '| Status | Demo | Item | Expected | Actual | Fix |', '|---|---|---|---|---|---|')
$md += $rows | ForEach-Object { "| $($_.Status) | $($_.Demo) | $($_.Item) | $($_.Expected) | $(([string]$_.Actual) -replace '\|', '/') | $($_.Fix) |" }
Set-Content -LiteralPath (Join-Path $dir 'demo-state.md') -Value $md -Encoding utf8
$rows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dir 'demo-state.json') -Encoding utf8
Write-DemoLog $Prefix "Demo pre-flight: $sum (report: $(Join-Path $dir 'demo-state.md'))"
if ($AsObject) { return $rows }
$rows | Format-Table Status, Demo, Item, Actual, Fix -AutoSize -Wrap | Out-String -Width 220 | Write-Host
