#requires -Version 7.0
<#
.SYNOPSIS
  READ-ONLY table of the demo people: demo role (persona), user (name - UPN), job title, Entra roles ACTUALLY assigned
  (read back from Microsoft Graph) and the other roles of the demo. Required in the hand-over report of the build.
.DESCRIPTION
  Sources: pack.json (personas: profile, story, entraRoles, powerPlatformRoles, purviewRoleGroups), the lab locale
  (names, job titles), state.json (UPNs) and Graph (users, role assignments). A planned Entra role that is not assigned
  is flagged MISSING. Leavers that were already deleted are shown as such. The operator (demo-config adminUpn) is the
  last row. Passwords are never read: they stay in generated/<prefix>/demo/secrets/personas.secret.txt.
  Writes generated/<prefix>/demo/personas.md; -AsJson prints the rows as JSON instead of the table.
.EXAMPLE
  pwsh -File .\Get-DemoPersonas.ps1 -Prefix cts2
#>
[CmdletBinding(PositionalBinding = $false)]
param([Parameter(Mandatory)][string]$Prefix, [switch]$AsJson)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_demo-common.ps1')
$cfg = Read-DemoConfig $Prefix
Assert-DemoTenant $cfg
$pack = Get-DemoPack $cfg.pack
$LOC = Get-DemoLocale -Locale $cfg.locale -Pack $cfg.pack
$state = Read-DemoLabState $Prefix
$G = 'https://graph.microsoft.com/v1.0'
$defs = @{}
foreach ($d in @(Invoke-DemoGraph GET "$G/roleManagement/directory/roleDefinitions?`$select=id,displayName" -All)) { $defs[[string]$d.id] = [string]$d.displayName }
$leaverKeys = @($pack.agents | Where-Object { $_.leaver } | ForEach-Object { [string]$_.leaver })
function Get-AssignedRoles([string]$UserId) {
    @((Invoke-DemoGraph GET "$G/roleManagement/directory/roleAssignments?`$filter=principalId eq '$UserId'&`$select=roleDefinitionId" -All) | ForEach-Object { $defs[[string]$_.roleDefinitionId] } | Where-Object { $_ } | Sort-Object -Unique)
}
function Format-Roles([string[]]$Assigned, [string[]]$Planned) {
    $miss = @($Planned | Where-Object { $Assigned -notcontains $_ })
    $txt = if ($Assigned.Count) { $Assigned -join ', ' } else { 'none' }
    if ($miss.Count) { $txt += " (MISSING: $($miss -join ', '))" }
    return $txt
}
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($p in $pack.personas) {
    $lp = $LOC.personas[$p.key]
    $name = "$($lp.givenName) $($lp.surname)"
    $upn = if ($state.users.Contains($p.key) -and $state.users[$p.key].upn) { [string]$state.users[$p.key].upn } else { Get-DemoUpn $LOC $cfg $p.key }
    $story = [string]$p.story
    $role = if ($story -match '^([^:]+):') { $Matches[1].Trim() } else { $story }
    $u = Invoke-DemoGraph GET "$G/users/$([uri]::EscapeDataString($upn))?`$select=id,jobTitle" -NoThrow
    $exists = $u -and -not $u.PSObject.Properties['error']
    $planned = @($p.entraRoles | Where-Object { $_ })
    $entra = if ($exists) { Format-Roles @(Get-AssignedRoles ([string]$u.id)) $planned } elseif ($leaverKeys -contains $p.key) { 'n/a (user deleted: leaver)' } else { "USER NOT FOUND (planned: $(if ($planned.Count) { $planned -join ', ' } else { 'none' }))" }
    $notes = @()
    if (@($p.powerPlatformRoles | Where-Object { $_ }).Count) { $notes += "Power Platform (payg environment): $($p.powerPlatformRoles -join ', ')" }
    if (@($p.purviewRoleGroups | Where-Object { $_ }).Count) { $notes += "Purview role groups (manual): $($p.purviewRoleGroups -join ', ')" }
    if ($leaverKeys -contains $p.key) { $notes += 'leaver: creates and shares an Agent Builder agent, then is permanently deleted' }
    $rows.Add([pscustomobject]@{ persona = $p.key; profile = [string]$p.profile; demoRole = $role; name = $name; upn = $upn
            jobTitle = $(if ($exists -and $u.jobTitle) { [string]$u.jobTitle } else { [string]$lp.jobTitle }); entraRoles = $entra; notes = ($notes -join '; ') })
}
if ($cfg.adminUpn) {
    $u = Invoke-DemoGraph GET "$G/users/$([uri]::EscapeDataString([string]$cfg.adminUpn))?`$select=id,displayName,jobTitle" -NoThrow
    $ok = $u -and -not $u.PSObject.Properties['error']
    $rows.Add([pscustomobject]@{ persona = 'operator'; profile = ''; demoRole = 'Operator (builds and resets the lab)'; name = $(if ($ok) { [string]$u.displayName } else { '' }); upn = [string]$cfg.adminUpn
            jobTitle = $(if ($ok) { [string]$u.jobTitle } else { '' }); entraRoles = $(if ($ok) { Format-Roles @(Get-AssignedRoles ([string]$u.id)) $script:DemoOperatorEntraRoles } else { 'USER NOT FOUND' }); notes = 'demo-config adminUpn' })
}
if ($AsJson) { $rows | ConvertTo-Json -Depth 5; return }
function Esc([string]$s) { ($s -replace '\|', '\|').Trim() }
$md = @("# Demo people - $Prefix", '', "Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') by Get-DemoPersonas.ps1 (Entra roles read back from the tenant). Passwords: generated/$Prefix/demo/secrets/personas.secret.txt.", '',
    '| Demo role (persona) | User (name - UPN) | Job title | Entra roles assigned | Other roles / notes |', '|---|---|---|---|---|')
$md += $rows | ForEach-Object { '| {0} | {1} | {2} | {3} | {4} |' -f (Esc "$(if ($_.profile) { "$($_.profile) " })$($_.demoRole) (``$($_.persona)``)"), (Esc "$($_.name) - $($_.upn)"), (Esc $_.jobTitle), (Esc $_.entraRoles), (Esc $_.notes) }
$out = Join-Path (Get-DemoLabDir $Prefix) 'personas.md'
$md | Set-Content -LiteralPath $out -Encoding utf8
$md | Write-Output
Write-DemoLog $Prefix "Demo people table written: $out ($(@($rows | Where-Object { $_.entraRoles -match 'MISSING|NOT FOUND' }).Count) row(s) with a problem)"
