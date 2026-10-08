#requires -Version 7.0
<#
.SYNOPSIS
  Creates or updates the demo people and groups from the demo pack + locale: users (properties, lab tag),
  managers, groups (members, owners, lab tag), directory roles and licenses. Idempotent. -WhatIf = dry run.
.DESCRIPTION
  Passwords of NEW users go ONLY to generated/<prefix>/demo/secrets/personas.secret.txt (never printed).
  Users are tagged extensionAttribute15 = a365lab:<prefix>; groups carry the open extension com.a365lab.lab.
  Every created object is recorded in generated/<prefix>/demo/state.json (inventory for the reset and the teardown).
.EXAMPLE
  pwsh -File .\Set-DemoIdentities.ps1 -Prefix cts2 -WhatIf
#>
[CmdletBinding(PositionalBinding = $false)]
param([Parameter(Mandatory)][string]$Prefix, [string[]]$Persona = @('all'), [switch]$SkipLicenses, [switch]$SkipRoles, [switch]$WhatIf)
. (Join-Path $PSScriptRoot '_demo-common.ps1')
$cfg = Read-DemoConfig $Prefix
Assert-DemoTenant $cfg
$pack = Get-DemoPack $cfg.pack
$LOC = Get-DemoLocale -Locale $cfg.locale -Pack $cfg.pack
$state = Read-DemoLabState $Prefix
$G = 'https://graph.microsoft.com/v1.0'
$tag = "a365lab:$Prefix"
$Persona = @($Persona | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$secrets = Join-Path (Get-DemoLabDir $Prefix) 'secrets\personas.secret.txt'
$log = [System.Collections.Generic.List[string]]::new()
function Note([string]$m) { $log.Add($m); Write-Host "  $m" }
function New-DemoPassword {
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#%+=?@')
    $all = ($sets -join '').ToCharArray()
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($set in $sets) { $chars.Add($set[[Security.Cryptography.RandomNumberGenerator]::GetInt32($set.Length)]) }
    while ($chars.Count -lt 20) { $chars.Add($all[[Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)]) }
    return -join ($chars | Sort-Object { [Security.Cryptography.RandomNumberGenerator]::GetInt32(1000) })
}
function Get-UserOrNull([string]$Upn) {
    $r = Invoke-DemoGraph GET "$G/users/$([uri]::EscapeDataString($Upn))?`$select=id,assignedLicenses,onPremisesExtensionAttributes" -NoThrow
    if ($r -and $r.PSObject.Properties['error']) { return $null }
    return $r
}

# --- users ----------------------------------------------------------------------------------------------------
Write-DemoLog $Prefix "Identities ($(if ($WhatIf) { 'dry run' } else { 'apply' })): users"
$ids = @{}
foreach ($p in $pack.personas) {
    $lp = $LOC.personas[$p.key]
    $alias = Get-DemoPersonaAlias $LOC $p.key
    $upn = "$alias@$($cfg.domain)"
    $props = [ordered]@{ displayName = "$($lp.givenName) $($lp.surname)"; givenName = $lp.givenName; surname = $lp.surname
        jobTitle = $lp.jobTitle; department = $lp.department; officeLocation = $LOC.org.offices[$p.office]; usageLocation = $LOC.usageLocation }
    $u = Get-UserOrNull $upn
    $selected = $Persona -contains 'all' -or $Persona -contains $p.key
    if (-not $selected) { if ($u) { $ids[$p.key] = $u.id }; continue }
    # Leaver-aware: once a leaver was deleted (orphan scenario prepared), 'all' never recreates it; only an explicit
    # -Persona <leaver> does (New-OrphanAgent.ps1).
    $wasDeleted = $p.leaver -and $state.users.Contains($p.key) -and $state.users[$p.key].deletedAt
    if (-not $u -and $wasDeleted -and $Persona -notcontains $p.key) { Note "skip    $upn (leaver deleted on $($state.users[$p.key].deletedAt); recreate it only with -Persona $($p.key))"; continue }
    if (-not $u) {
        if ($WhatIf) { Note "would CREATE $upn"; continue }
        $pw = New-DemoPassword
        $body = [ordered]@{ accountEnabled = $true; mailNickname = $alias; userPrincipalName = $upn
            passwordProfile = @{ forceChangePasswordNextSignIn = $false; password = $pw } }
        foreach ($k in $props.Keys) { $body[$k] = $props[$k] }
        $u = Invoke-DemoGraph POST "$G/users" -Body $body
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $secrets) | Out-Null
        Add-Content -LiteralPath $secrets -Value ("{0}`t{1}" -f $upn, $pw) -Encoding utf8
        $pw = $null
        for ($i = 0; $i -lt 20 -and -not (Get-UserOrNull $upn); $i++) { Start-Sleep -Seconds 3 }
        Note "CREATED $upn (password in the secrets file)"
    }
    elseif (-not $WhatIf) { Invoke-DemoGraph PATCH "$G/users/$($u.id)" -Body $props | Out-Null; Note "updated $upn" }
    else { Note "exists  $upn" }
    if (-not $WhatIf -and $u.onPremisesExtensionAttributes.extensionAttribute15 -ne $tag) {
        Invoke-DemoGraph PATCH "$G/users/$($u.id)" -Body @{ onPremisesExtensionAttributes = @{ extensionAttribute15 = $tag } } | Out-Null
    }
    $ids[$p.key] = $u.id
    $prev = if ($state.users.Contains($p.key)) { $state.users[$p.key] } else { $null }
    $state.users[$p.key] = [ordered]@{ upn = $upn; id = $u.id; leaver = [bool]$p.leaver; photo = $(if ($prev) { $prev.photo } else { $null }) }
}
# --- managers -------------------------------------------------------------------------------------------------
Write-DemoLog $Prefix 'Identities: managers'
foreach ($p in $pack.personas) {
    if (-not $ids.ContainsKey($p.key)) { continue }
    $cur = Invoke-DemoGraph GET "$G/users/$($ids[$p.key])/manager?`$select=id" -NoThrow
    $curId = if ($cur -and -not $cur.PSObject.Properties['error']) { $cur.id } else { $null }
    if ($p.manager) {
        $mid = $ids[$p.manager]
        if (-not $mid) { Note "manager of $($p.key) ($($p.manager)) does not exist yet"; continue }
        if ($curId -ne $mid) {
            if ($WhatIf) { Note "would SET manager $($p.key) -> $($p.manager)" }
            else { Invoke-DemoGraph PUT "$G/users/$($ids[$p.key])/manager/`$ref" -Body @{ '@odata.id' = "$G/users/$mid" } | Out-Null; Note "manager SET $($p.key) -> $($p.manager)" }
        }
    }
    elseif ($curId) {
        if ($WhatIf) { Note "would REMOVE the manager of $($p.key) (the pack wants none)" }
        else { Invoke-DemoGraph DELETE "$G/users/$($ids[$p.key])/manager/`$ref" | Out-Null; Note "manager REMOVED from $($p.key)" }
    }
}

# --- groups ---------------------------------------------------------------------------------------------------
Write-DemoLog $Prefix 'Identities: groups'
$me = Invoke-DemoGraph GET "$G/me?`$select=id"
foreach ($gd in $pack.groups) {
    $lg = $LOC.groups[$gd.key]
    $grp = @((Invoke-DemoGraph GET "$G/groups?`$filter=mailNickname eq '$($lg.mailNickname)'&`$select=id,displayName").value) | Select-Object -First 1
    if (-not $grp) {
        if ($WhatIf) { Note "would CREATE group $($lg.displayName) [$($gd.kind)]"; continue }
        $body = [ordered]@{ displayName = $lg.displayName; mailNickname = $lg.mailNickname; description = $lg.description }
        if ($gd.kind -eq 'm365') {
            $owners = @($me.id) + @($gd.owners | ForEach-Object { $ids[$_] } | Where-Object { $_ })
            $body['groupTypes'] = @('Unified'); $body['mailEnabled'] = $true; $body['securityEnabled'] = $true; $body['visibility'] = 'Private'
            $body['owners@odata.bind'] = @($owners | Select-Object -Unique | ForEach-Object { "$G/users/$_" })
        }
        else { $body['mailEnabled'] = $false; $body['securityEnabled'] = $true }
        $grp = Invoke-DemoGraph POST "$G/groups" -Body $body
        for ($i = 0; $i -lt 20; $i++) { $chk = Invoke-DemoGraph GET "$G/groups/$($grp.id)?`$select=id" -NoThrow; if ($chk -and -not $chk.PSObject.Properties['error']) { break }; Start-Sleep -Seconds 3 }
        Note "CREATED group $($lg.displayName)"
    }
    else { Note "exists  group $($lg.displayName)" }
    if ($WhatIf) { continue }
    $members = @((Invoke-DemoGraph GET "$G/groups/$($grp.id)/members?`$select=id" -All) | ForEach-Object { $_.id })
    foreach ($m in $gd.members) {
        $mid = $ids[$m]
        if ($mid -and $members -notcontains $mid) { Invoke-DemoGraph POST "$G/groups/$($grp.id)/members/`$ref" -Body @{ '@odata.id' = "$G/directoryObjects/$mid" } | Out-Null; Note "  + member $m" }
    }
    if ($gd.owners) {
        $owners = @((Invoke-DemoGraph GET "$G/groups/$($grp.id)/owners?`$select=id" -All) | ForEach-Object { $_.id })
        foreach ($o in @($gd.owners | ForEach-Object { $ids[$_] } | Where-Object { $_ })) {
            if ($owners -notcontains $o) { Invoke-DemoGraph POST "$G/groups/$($grp.id)/owners/`$ref" -Body @{ '@odata.id' = "$G/directoryObjects/$o" } | Out-Null; Note '  + owner' }
        }
    }
    $ext = Invoke-DemoGraph GET "$G/groups/$($grp.id)/extensions/com.a365lab.lab" -NoThrow
    if (-not $ext -or $ext.PSObject.Properties['error']) {
        Invoke-DemoGraph POST "$G/groups/$($grp.id)/extensions" -Body @{ '@odata.type' = 'microsoft.graph.openTypeExtension'; extensionName = 'com.a365lab.lab'; lab = $Prefix } | Out-Null
    }
    $state.groups[$gd.key] = [ordered]@{ id = $grp.id; displayName = $lg.displayName; mailNickname = $lg.mailNickname; kind = $gd.kind }
}
# --- directory roles ----------------------------------------------------------------------------------------------
if (-not $SkipRoles) {
    Write-DemoLog $Prefix 'Identities: directory roles'
    $defs = @(Invoke-DemoGraph GET "$G/roleManagement/directory/roleDefinitions?`$select=id,displayName" -All)
    foreach ($p in $pack.personas) {
        if (-not $ids.ContainsKey($p.key)) { continue }
        foreach ($rn in @($p.entraRoles)) {
            $def = $defs | Where-Object displayName -eq $rn | Select-Object -First 1
            if (-not $def) { Note "role NOT FOUND '$rn'"; continue }
            $has = @((Invoke-DemoGraph GET ("$G/roleManagement/directory/roleAssignments?`$filter=principalId eq '{0}' and roleDefinitionId eq '{1}'" -f $ids[$p.key], $def.id)).value)
            if ($has.Count) { continue }
            if ($WhatIf) { Note "would ASSIGN $($p.key) = $rn"; continue }
            $r = Invoke-DemoGraph POST "$G/roleManagement/directory/roleAssignments" -Body @{ principalId = $ids[$p.key]; roleDefinitionId = $def.id; directoryScopeId = '/' } -NoThrow
            if ($r -and $r.PSObject.Properties['error']) { Note "role FAILED $($p.key) = $rn ($($r.status))" } else { Note "role ASSIGNED $($p.key) = $rn" }
        }
    }
    # The operator (adminUpn) needs these roles for the governance step: a Global Administrator does NOT have them
    # (custom security attributes, docs/demo-environment-prerequisites.md section 6). A role change reaches the
    # delegated tokens only after a refresh (Set-DemoGovernance.ps1 forces it).
    if ($cfg.adminUpn) {
        $op = Invoke-DemoGraph GET "$G/users/$([uri]::EscapeDataString([string]$cfg.adminUpn))?`$select=id" -NoThrow
        if (-not $op -or $op.PSObject.Properties['error']) { Note "operator $($cfg.adminUpn) NOT FOUND: roles not checked" }
        else {
            foreach ($rn in $script:DemoOperatorEntraRoles) {
                $def = $defs | Where-Object displayName -eq $rn | Select-Object -First 1
                if (-not $def) { Note "role NOT FOUND '$rn'"; continue }
                $has = @((Invoke-DemoGraph GET ("$G/roleManagement/directory/roleAssignments?`$filter=principalId eq '{0}' and roleDefinitionId eq '{1}'" -f $op.id, $def.id)).value)
                if ($has.Count) { continue }
                if ($WhatIf) { Note "would ASSIGN operator $($cfg.adminUpn) = $rn"; continue }
                $r = Invoke-DemoGraph POST "$G/roleManagement/directory/roleAssignments" -Body @{ principalId = $op.id; roleDefinitionId = $def.id; directoryScopeId = '/' } -NoThrow
                if ($r -and $r.PSObject.Properties['error']) { Note "role FAILED operator = $rn ($($r.status))" } else { Note "role ASSIGNED operator $($cfg.adminUpn) = $rn" }
            }
        }
    }
}

# --- licenses ----------------------------------------------------------------------------------------------------
if (-not $SkipLicenses) {
    Write-DemoLog $Prefix 'Identities: licenses'
    $skus = @(Invoke-DemoGraph GET "$G/subscribedSkus" -All)
    $skipTeams = @(Get-DemoRolePlans $skus ([string]$cfg.licenseSkus.copilotUser)) -contains 'TEAMS1'
    foreach ($p in $pack.personas) {
        if (-not $ids.ContainsKey($p.key) -or -not ($Persona -contains 'all' -or $Persona -contains $p.key)) { continue }
        $u = Invoke-DemoGraph GET "$G/users/$($ids[$p.key])?`$select=assignedLicenses"
        $have = @($u.assignedLicenses | ForEach-Object { [string]($_.skuId) })
        $wanted = @()
        foreach ($role in @(Get-DemoPersonaLicenseRoles $p $cfg)) {
            if ($role -eq 'teams' -and $skipTeams) { continue }
            foreach ($part in Get-DemoSkuParts ([string]$cfg.licenseSkus[$role])) {
                $sku = $skus | Where-Object { $_.skuPartNumber -eq $part } | Select-Object -First 1
                if (-not $sku) { Note "license SKU missing: $part ($role)"; continue }
                if (@($wanted | Where-Object { $_.skuId -eq $sku.skuId }).Count -eq 0) { $wanted += $sku }
            }
        }
        $add = @(Get-DemoLicenseAdds $wanted $have $skus)
        if (-not $add.Count) { continue }
        $desc = ($add | ForEach-Object { "$($_.partNumber)$(if (@($_.disabledPlans).Count) { ' (mailbox plan disabled)' })" }) -join ', '
        if ($WhatIf) { Note "would ADD $($add.Count) license(s) to $($p.key): $desc"; continue }
        $body = @{ addLicenses = @($add | ForEach-Object { @{ skuId = $_.skuId; disabledPlans = @($_.disabledPlans) } }); removeLicenses = @() }
        $r = Invoke-DemoGraph POST "$G/users/$($ids[$p.key])/assignLicense" -Body $body -NoThrow
        if ($r -and $r.PSObject.Properties['error']) { Note "licenses FAILED $($p.key) ($($r.status)): free seats? run Test-DemoPrereqs.ps1" } else { Note "licenses ADDED $($p.key): $desc" }
    }
}

# --- Purview role groups and Power Platform roles: printed, not applied (other tools) -----------------------------
foreach ($p in $pack.personas | Where-Object { $_.purviewRoleGroups }) {
    Note "MANUAL (Purview portal > Roles and scopes > Role groups, or Security & Compliance PowerShell Add-RoleGroupMember): add $(Get-DemoPersonaAlias $LOC $p.key)@$($cfg.domain) to $($p.purviewRoleGroups -join ', ')"
    if (-not $WhatIf) {
        $pv = @(Get-DemoIdsFor $pack -Portals @('purview'))
        $null = Set-DemoUserAction -Prefix $Prefix -Key "purview-roles-$($p.key)" -Action "Purview role groups for $(Get-DemoPersonaAlias $LOC $p.key)@$($cfg.domain): $($p.purviewRoleGroups -join ', ')" `
            -Where 'Purview portal > Settings > Roles and scopes > Role groups (card 40-purview, section 1)' -NeededBy $(if ($pv.Count) { $pv -join ', ' } else { 'the Purview demos' })
    }
}
$pp = @($pack.personas | Where-Object { $_.powerPlatformRoles })
if ($pp.Count -and $cfg.copilotStudio.paygEnvironmentId) {
    foreach ($p in $pp) { foreach ($r in $p.powerPlatformRoles) { Note ("NEXT: pac admin assign-user --environment {0} --user {1}@{2} --role `"{3}`"" -f $cfg.copilotStudio.paygEnvironmentId, (Get-DemoPersonaAlias $LOC $p.key), $cfg.domain, $r) } }
}
if (-not $WhatIf) { Save-DemoLabState $Prefix $state }
Write-DemoLog $Prefix "Identities done ($(if ($WhatIf) { 'dry run' } else { 'applied' })): $($log.Count) line(s)"
