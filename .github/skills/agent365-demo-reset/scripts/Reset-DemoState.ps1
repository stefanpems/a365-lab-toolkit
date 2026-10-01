#requires -Version 7.0
<#
.SYNOPSIS
  Restores the starting conditions of a demo lab (DRY-RUN unless -Apply), then prints the manual resets of the selected
  demos. Run Get-DemoState.ps1 afterwards to verify. Run it the evening before a run: some changes need hours.
.DESCRIPTION
  Automatic (from pack.json + the lab locale + state.json, like Get-DemoState.ps1):
    Registry  registry owners (catalog reassign, or the agent registration of code agents); agents that must be
              ownerless are handed to New-OrphanAgent.ps1 (temporary leaver; -SkipOrphan skips it); UNBLOCK of agents
              that must not be blocked. A block that a demo shows (audit trail) is never done here: it is a manual step
              of the story persona in the admin center.
    Entra     user owner, sponsor, attribute value and enabled flag of every agent identity (application-only APIs
              through a temporary app). Blocked agents keep their agent ID disabled by design: never re-enabled.
    D9/D17    agent risk dismissed on the agents of those demos.
    D10       access-package assignments and pending requests of the target agent removed.
    D6        reserve-name MCP pool: a base without a non-retired instance gets the next payload
              (New-DemoMcpRegistration.ps1 -Action Register), which the operator registers with the printed command.
  -Demo selects demo codes (D1..D17) and/or the areas Registry, Entra, Mcp; default All.
.EXAMPLE
  pwsh -File .\Reset-DemoState.ps1 -Prefix cts2
.EXAMPLE
  pwsh -File .\Reset-DemoState.ps1 -Prefix cts2 -Demo D5,D8 -Apply
#>
[CmdletBinding(PositionalBinding = $false)]
param([Parameter(Mandatory)][string]$Prefix, [string[]]$Demo = @('All'), [switch]$Apply, [switch]$SkipOrphan)
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
$gov = $LOC.governance
$mode = if ($Apply) { 'APPLY' } else { 'DRY-RUN' }
$log = [System.Collections.Generic.List[object]]::new()
function Add-Action([string]$Item, [string]$Current, [string]$Target, [string]$Result) { $log.Add([pscustomobject]@{ Item = $Item; Current = $Current; Target = $Target; Result = $Result }) }
function Test-Sel([string[]]$Tags) { if ($Demo -contains 'All') { return $true }; foreach ($t in $Tags) { if ($Demo -contains $t) { return $true } }; return $false }
function Test-Err($R) { return ($null -eq $R) -or ($R.PSObject.Properties['error'] -and $R.PSObject.Properties['status'] -and @($R.PSObject.Properties).Count -eq 2) }
function Get-Upn([string]$Key) { Get-DemoUpn $LOC $cfg $Key }
$script:userIds = @{}
function Get-UserId([string]$Key) {
    if (-not $script:userIds.ContainsKey($Key)) { $r = Invoke-DemoGraph GET "$G/v1.0/users/$([uri]::EscapeDataString((Get-Upn $Key)))?`$select=id" -NoThrow -MaxRetries 1; $script:userIds[$Key] = if (Test-Err $r) { $null } else { [string]$r.id } }
    return $script:userIds[$Key]
}
function Get-Name([string]$Id) { if (-not $Id) { return '(none)' }; $r = Invoke-DemoGraph GET "$G/v1.0/directoryObjects/${Id}?`$select=displayName" -NoThrow -MaxRetries 1; if (Test-Err $r) { "(deleted $Id)" } else { [string]$r.displayName } }
function Get-Res($R, [string]$Done) { if ($R.ok) { $Done } else { "FAILED $($R.status): $($R.error)" } }
Write-DemoLog $Prefix "Demo reset ($mode) for: $($Demo -join ', ')"
$orphans = @()

# --- 1. Registry owners and blocks ---------------------------------------------------------------------------------
foreach ($a in @($pack.agents)) {
    if (-not (Test-Sel (@('Registry') + @($a.demos)))) { continue }
    $nm = [string]$LOC.agents[$a.key].displayName
    if ($a.catalog -eq $false) { continue }
    $pk = Get-DemoAgentPackages $cfg $LOC $state $a
    if (-not @($pk.all).Count) { Add-Action "${nm}: registry" 'not found' 'exists' 'MANUAL: create or publish it (cards)'; continue }
    $own = if ($pk.shared) { $pk.shared } else { $pk.published }
    $scope = if ($pk.published) { $pk.published } else { $own }
    $ro = [string]$a.registryOwner
    if ($ro -and $ro -ne 'none') {
        $want = Get-UserId $ro
        if ($want -and [string]$own.ownerId -ne $want) {
            $gc = if ($a.platform -eq 'code') { Get-DemoAgentConfig $LOC $Prefix $a } else { $null }
            $res = 'would reassign'
            if ($Apply) { $res = Get-Res (Set-DemoRegistryOwner $cfg $own $want $(if ($gc) { [string]$gc.agentRegistrationId } else { '' })) 'reassigned' }
            if ($res -like 'FAILED*') { $res += " - admin center > Agents > $nm > Assign new owner > $(Get-DemoPersonaDisplayName $LOC $ro)" }
            Add-Action "${nm}: registry owner" (Get-Name ([string]$own.ownerId)) (Get-Upn $ro) $res
        }
    }
    elseif ($ro -eq 'none' -and $a.leaver -and -not (Test-DemoOwnerless $own)) {
        $orphans += $a.key
        Add-Action "${nm}: ownerless" (Get-Name ([string]$own.ownerId)) 'none (creator left)' $(if ($SkipOrphan) { 'skipped (-SkipOrphan)' } elseif ($Apply) { 'New-OrphanAgent.ps1 (below)' } else { 'would run New-OrphanAgent.ps1' })
    }
    $b = $a.baseline
    if ($b -and $null -ne $b.blocked -and [bool]$scope.isBlocked -ne [bool]$b.blocked) {
        if ($b.blocked) { Add-Action "${nm}: blocked" 'False' 'True' "MANUAL: $(Get-DemoPersonaDisplayName $LOC 'aiAdmin') blocks it in the admin center (published entry, reason 'Not approved for use') - the audit trail must show the persona" }
        else {
            $res = 'would unblock'
            if ($Apply) { $res = Get-Res (Set-DemoPackageBlocked $cfg $scope $false) 'unblocked' }
            if ($b.installedFor) { $res += "; then re-install it for $($b.installedFor) in the admin center (a block removes installations)" }
            Add-Action "${nm}: blocked" 'True' 'False' $res
        }
    }
}
# --- 2. Entra: owner, sponsor, attribute, enabled (application-only, temporary app) -------------------------------
$blockedKeys = @($pack.agents | Where-Object { $_.baseline -and $_.baseline.blocked } | ForEach-Object { [string]$_.key })
$plan = @()
if (Test-Sel (@('Entra') + @($pack.agents | Where-Object { $_.entraOwner -or $_.sponsor -or $_.attribute } | ForEach-Object { $_.demos }))) { $plan = @(Get-DemoIdentityPlan $Prefix $pack $LOC) }
$fix = @()
foreach ($p in $plan) {
    if (-not (Test-Sel (@('Entra') + @($p.def.demos)))) { continue }
    foreach ($id in $p.identities) {
        $o = Invoke-DemoGraph GET "$G/beta/servicePrincipals/$($id.id)/owners?`$select=id" -NoThrow
        $uo = @(if (-not (Test-Err $o)) { @($o.value) | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.user' } })
        $s = Invoke-DemoGraph GET "$G/beta/servicePrincipals/$($id.id)/microsoft.graph.agentIdentity/sponsors?`$select=id" -NoThrow
        $sp = @(if (-not (Test-Err $s)) { @($s.value) })
        $en = Invoke-DemoGraph GET "$G/beta/servicePrincipals/$($id.id)?`$select=accountEnabled" -NoThrow -MaxRetries 1
        $needOwner = $p.def.entraOwner -and -not ($uo.Count -eq 1 -and $uo[0].id -eq (Get-UserId $p.def.entraOwner))
        $needSponsor = $p.def.sponsor -and -not ($sp.Count -eq 1 -and $sp[0].id -eq (Get-UserId $p.def.sponsor))
        $needEnable = (-not (Test-Err $en)) -and (-not $en.accountEnabled) -and ($blockedKeys -notcontains $p.key)
        $needAttr = $false
        if ($p.def.attribute -and $id -eq $p.identities[0]) {
            $r = Invoke-DemoReg $cfg GET "$G/beta/servicePrincipals/$($id.id)?`$select=customSecurityAttributes"
            $cur = if ($r.ok) { [string]$r.body.customSecurityAttributes.($gov.attributeSet.id).($gov.attribute.name) } else { $null }
            $needAttr = $cur -ne [string]$gov.attribute.values[$p.def.attribute]
        }
        if ($needOwner -or $needSponsor -or $needEnable -or $needAttr) {
            $fix += [pscustomobject]@{ plan = $p; identity = $id; owner = $needOwner; sponsor = $needSponsor; enable = $needEnable; attribute = $needAttr }
            Add-Action "$($p.name): $($id.displayName)" (@($(if ($needOwner) { 'owner' }), $(if ($needSponsor) { 'sponsor' }), $(if ($needEnable) { 'disabled' }), $(if ($needAttr) { $gov.attribute.name })) | Where-Object { $_ }) -join ', ' 'baseline' $(if ($Apply) { 'fixing (below)' } else { 'would fix' })
        }
    }
}
if ($Apply -and $fix.Count) {
    $roles = @('AgentIdentity.ReadWrite.All'); if (@($fix | Where-Object { $_.attribute }).Count) { $roles += 'CustomSecAttributeAssignment.ReadWrite.All' }
    $session = $null
    try {
        $session = New-DemoAppOnlySession -Prefix $Prefix -TenantId $cfg.tenantId -Roles $roles
        foreach ($f in $fix) {
            $d = $f.plan.def; $iid = $f.identity.id
            try {
                if ($f.owner) { $null = Set-DemoIdentityOwner $session $iid (Get-UserId $d.entraOwner) -ExclusiveUser }
                if ($f.sponsor) { $null = Set-DemoIdentitySponsor $session $iid (Get-UserId $d.sponsor) -Exclusive }
                if ($f.enable) { $null = Set-DemoIdentityEnabled $session $iid $true }
                if ($f.attribute) { $null = Set-DemoIdentityAttribute $session $iid ([string]$gov.attributeSet.id) ([string]$gov.attribute.name) ([string]$gov.attribute.values[$d.attribute]) }
                Write-DemoLog $Prefix "Reset: $($f.plan.name) / $($f.identity.displayName) fixed"
            }
            catch { Write-DemoLog $Prefix "Reset: $($f.plan.name) / $($f.identity.displayName) FAILED: $($_.Exception.Message)" 'ERROR' }
        }
    }
    finally { Close-DemoAppOnlySession $session }
}

# --- 3. Agent risk of the D9/D17 agents -----------------------------------------------------------------------------
if (Test-Sel @('D9', 'D17')) {
    $riskKeys = @($pack.demos | Where-Object { $_.id -in 'D9', 'D17' } | ForEach-Object { $_.agents } | Select-Object -Unique)
    if (-not $plan.Count) { $plan = @(Get-DemoIdentityPlan $Prefix $pack $LOC) }
    foreach ($p in @($plan | Where-Object { $riskKeys -contains $_.key -and $_.identities.Count })) {
        $iid = $p.identities[0].id
        $lvl = Get-DemoAgentRisk $cfg $iid
        if ($lvl -match '^(none|low)' -or $lvl -match 'dismissed|confirmedSafe|remediated') { continue }
        $res = 'would dismiss'
        if ($Apply) { $res = Get-Res (Clear-DemoAgentRisk $cfg $iid) 'dismissed' }
        Add-Action "$($p.name): agent risk" $lvl 'none' $res
    }
}

# --- 4. D10: no assignment or pending request of the target agent ---------------------------------------------------
$ent = $pack.governance.entitlement
if ($ent -and (Test-Sel @($ent.demos))) {
    $apName = [string]$gov.accessPackage.name
    $r = Invoke-DemoReg $cfg GET "$G/v1.0/identityGovernance/entitlementManagement/accessPackages?`$filter=$([uri]::EscapeDataString("displayName eq '$($apName.Replace("'", "''"))'"))"
    $ap = if ($r.ok) { @($r.body.value) | Select-Object -First 1 } else { $null }
    if (-not $ap) { Add-Action "Access package '$apName'" 'missing' 'exists' 'MANUAL: Entra card, section 3' }
    else {
        if (-not $plan.Count) { $plan = @(Get-DemoIdentityPlan $Prefix $pack $LOC) }
        $tp = $plan | Where-Object { $_.key -eq $ent.target } | Select-Object -First 1
        $tid = if ($tp -and $tp.identities.Count) { [string]$tp.identities[0].id } else { $null }
        $as = Invoke-DemoReg $cfg GET "$G/v1.0/identityGovernance/entitlementManagement/assignments?`$filter=accessPackage/id eq '$($ap.id)'&`$expand=target"
        foreach ($x in @(if ($as.ok) { @($as.body.value) | Where-Object { $_.target.objectId -eq $tid -and $_.state -notin 'expired', 'deliveryFailed' } })) {
            $res = 'would remove'
            if ($Apply) { $res = Get-Res (Invoke-DemoReg $cfg POST "$G/v1.0/identityGovernance/entitlementManagement/assignmentRequests" @{ requestType = 'adminRemove'; assignment = @{ id = $x.id } }) 'removal requested' }
            Add-Action "$($LOC.agents[$ent.target].displayName): access-package assignment" $x.state 'none' $res
        }
        # assignmentRequests has no 'target' navigation ($expand=target returns 400): the target is on the assignment.
        $rq = Invoke-DemoReg $cfg GET "$G/v1.0/identityGovernance/entitlementManagement/assignmentRequests?`$filter=accessPackage/id eq '$($ap.id)'&`$expand=assignment(`$expand=target)"
        if (-not $rq.ok) { Add-Action 'Pending access-package requests' "error $($rq.status)" 'none' 'MANUAL: check the requests of the package in the Entra admin center' }
        foreach ($x in @(if ($rq.ok) { @($rq.body.value) | Where-Object { $_.assignment.target.objectId -eq $tid -and $_.state -match '(?i)pending' } })) {
            $res = 'would cancel'
            if ($Apply) { $res = Get-Res (Invoke-DemoReg $cfg POST "$G/v1.0/identityGovernance/entitlementManagement/assignmentRequests/$($x.id)/cancel") 'cancelled' }
            Add-Action "$($LOC.agents[$ent.target].displayName): pending access-package request" $x.state 'none' $res
        }
    }
}

# --- 5. D6: reserve-name MCP pool ------------------------------------------------------------------------------------
if (Test-Sel @('Mcp', 'D6')) {
    foreach ($b in $pack.mcp.pool) {
        $base = "$($LOC.mcp.servers[$b.key].base)NN"
        $open = @($state.mcp.pool | Where-Object { $_ -and $_.key -eq $b.key -and $_.status -in 'pending', 'approved' })
        if ($open.Count -eq 0) {
            $role = [string]@($b.roles)[0]
            $res = "would prepare the next name (New-DemoMcpRegistration.ps1 -Action Register -Role $role)"
            if ($Apply) {
                try { & (Join-Path $builder 'New-DemoMcpRegistration.ps1') -Prefix $Prefix -Action Register -Role $role; $res = 'payload ready: run the printed a365 command, then -Action Confirm' }
                catch { $res = "FAILED: $($_.Exception.Message)" }
            }
            Add-Action "MCP pool $base" 'none' '1 pending instance' $res
        }
        elseif ($open.Count -eq 1) {
            if ($open[0].status -eq 'approved') { Add-Action "MCP pool $base" "$($open[0].name) [approved]" 'a new pending instance' "MANUAL: Block $($open[0].name) in Tools, then New-DemoMcpRegistration.ps1 -Action Retire -Name $($open[0].name) -Confirmed, then re-run this reset" }
        }
        else { Add-Action "MCP pool $base" (@($open | ForEach-Object { "$($_.name) [$($_.status)]" }) -join ', ') 'at most 1' 'MANUAL: Reject/Block all but one in the admin center, then Retire -Confirmed the others' }
    }
}

# --- 6. Orphan agents (temporary leaver), then the manual resets -----------------------------------------------------
if ($Apply -and -not $SkipOrphan) { foreach ($k in $orphans) { & (Join-Path $PSScriptRoot 'New-OrphanAgent.ps1') -Prefix $Prefix -Agent $k -Apply } }
if ($log.Count) { $log | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host } else { Write-Host 'Automatic part: everything already at the starting conditions.' }
$manual = @(foreach ($d in @($pack.demos | Where-Object { $_.manualReset })) { if (Test-Sel @($d.id)) { foreach ($m in $d.manualReset) { "  [$($d.id)] $(Expand-DemoText $m $LOC $cfg $state $pack)" } } })
if ($manual.Count) { Write-Host "`nMANUAL resets of the selected demos:"; $manual | ForEach-Object { Write-Host $_ } }
Write-DemoLog $Prefix "Demo reset ($mode) finished: $($log.Count) automatic item(s), $($manual.Count) manual. Verify with Get-DemoState.ps1."
