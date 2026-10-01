#requires -Version 7.0
<#
.SYNOPSIS
  Recreates the "creator has left" condition on an Agent Builder agent of the pack (agents[].leaver) so that the
  ownership demos can be repeated. DRY-RUN unless -Apply. About 10-20 minutes.
.DESCRIPTION
  Technique (temporary leaver): recreate the leaver persona with Set-DemoIdentities.ps1 -Persona <leaver> (same name,
  UPN, license and manager as in the pack) and its photo (Set-DemoPhotos.ps1 -Persona), make it the registry owner of
  the agent (catalog reassign API; one guided click in the admin center if the API refuses), then remove its licenses,
  delete and permanently delete the user. A soft delete is not enough: the agent is ownerless only when its owner is
  empty or no longer resolves. A leaver WITHOUT a manager leaves the agent in "Agents without owners" (D1, D5); a leaver
  WITH a manager makes it eligible for the reassignment rule, which is run live (D8).
.EXAMPLE
  pwsh -File .\New-OrphanAgent.ps1 -Prefix cts2 -Agent circularsAssistant -Apply
.NOTES
  Reference lab, 29/09: the admin-center card "Agents without owners" may keep a ghost owner for days after the hard
  delete (the API already reports an unresolvable owner): verify the CARD, not only the API. -Force re-runs the cycle
  even when the API already sees the agent as ownerless; -HoldMinutes keeps the temporary owner in place before the
  deletion (default 30: a short hold was not enough there); -KeepLeaver stops after the reassignment (diagnostic: check
  that the admin center shows the temporary owner by name, then delete the user from the portals).
#>
[CmdletBinding(PositionalBinding = $false)]
param([Parameter(Mandatory)][string]$Prefix, [Parameter(Mandatory)][string]$Agent, [switch]$Apply, [switch]$Force, [switch]$KeepLeaver,
      [ValidateRange(0, 240)][int]$HoldMinutes = 30, [int]$TimeoutMinutes = 20)
$ErrorActionPreference = 'Stop'
$builder = Join-Path $PSScriptRoot '..\..\agent365-demo-builder\scripts'
. (Join-Path $builder '_demo-common.ps1')
. (Join-Path $builder '_demo-entra.ps1')
. (Join-Path $PSScriptRoot '_demo-registry.ps1')
$cfg = Read-DemoConfig $Prefix
$pack = Get-DemoPack $cfg.pack
$LOC = Get-DemoLocale -Locale $cfg.locale -Pack $cfg.pack
$state = Read-DemoLabState $Prefix
Assert-DemoTenant $cfg
$G = $script:DemoG
$a = $pack.agents | Where-Object { $_.key -eq $Agent } | Select-Object -First 1
if (-not $a -or -not $a.leaver) { throw "'$Agent' is not an agent with a leaver in pack '$($cfg.pack)' ($(@($pack.agents | Where-Object { $_.leaver } | ForEach-Object { $_.key }) -join ', '))." }
$leaver = [string]$a.leaver
$lp = $pack.personas | Where-Object { $_.key -eq $leaver } | Select-Object -First 1
$upn = Get-DemoUpn $LOC $cfg $leaver
$nm = [string]$LOC.agents[$a.key].displayName
$pk = Get-DemoAgentPackages $cfg $LOC $state $a
$pkg = if ($pk.shared) { $pk.shared } else { $pk.published }
if (-not $pkg) { throw "'$nm' is not in the registry: create it first (Agent Builder card)." }
Write-DemoLog $Prefix "Orphan reset '$nm' ($($pkg.id)): leaver $upn (manager: $(if ($lp.manager) { Get-DemoUpn $LOC $cfg $lp.manager } else { 'none' }))"
if ((Test-DemoOwnerless $pkg) -and -not $Force) { Write-DemoLog $Prefix "'$nm' is already ownerless for the API: nothing to do (check the admin-center card; -Force re-runs the cycle)"; return }
if (-not $Apply) {
    $rest = if ($KeepLeaver) { 'then STOP (-KeepLeaver)' } else { 'then remove its licenses, delete and permanently delete it; 4) wait until the agent is ownerless' }
    Write-Host "DRY-RUN. With -Apply: 1) recreate $upn (Set-DemoIdentities.ps1 -Persona $leaver) and its photo; 2) make it the owner of '$nm';"
    Write-Host "         3) hold $HoldMinutes min, $rest."
    return
}
function Get-OwnerId { Clear-DemoPackageCache; $x = Get-DemoAgentPackages $cfg $LOC $state $a; return [string]$(if ($x.shared) { $x.shared.ownerId } else { $x.published.ownerId }) }

# 1) The leaver comes back (same persona definition as the build)
& (Join-Path $builder 'Set-DemoIdentities.ps1') -Prefix $Prefix -Persona $leaver
try { & (Join-Path $builder 'Set-DemoPhotos.ps1') -Prefix $Prefix -Persona $leaver } catch { Write-DemoLog $Prefix "Photo of $upn not set: $($_.Exception.Message)" 'WARN' }
$u = Invoke-DemoGraph GET "$G/v1.0/users/$([uri]::EscapeDataString($upn))?`$select=id,assignedLicenses"
Start-Sleep -Seconds 30

# 2) The leaver becomes the owner
$r = Set-DemoRegistryOwner $cfg $pkg ([string]$u.id) ''
if ($r.ok) { Write-DemoLog $Prefix 'Reassign API accepted' }
else {
    Write-DemoLog $Prefix "Reassign API refused ($($r.status)): $($r.error)" 'WARN'
    Write-Host ">>> MANUAL (one click): admin center > Agents > All agents > '$nm' > Assign new owner > $(Get-DemoPersonaDisplayName $LOC $leaver) ($upn) > Assign."
}
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
while ((Get-OwnerId) -ne [string]$u.id) {
    if ((Get-Date) -gt $deadline) { throw "The owner of '$nm' did not become $upn within $TimeoutMinutes minutes (the leaver is kept: re-run after the manual step)." }
    Start-Sleep -Seconds 20
}
Write-DemoLog $Prefix "Owner of '$nm' is now $upn"
if ($KeepLeaver) {
    Write-DemoLog $Prefix "-KeepLeaver: $upn stays the owner. Check that the admin center shows it by name, then delete the user (Microsoft 365 admin center > Delete user, then Entra > Deleted users > Delete permanently) and verify the 'Agents without owners' card."
    return
}
if ($HoldMinutes) { Write-DemoLog $Prefix "Holding the temporary owner for $HoldMinutes min before the deletion"; Start-Sleep -Seconds ($HoldMinutes * 60) }

# 3) The leaver leaves: licenses removed, deleted, permanently deleted
$u = Invoke-DemoGraph GET "$G/v1.0/users/$($u.id)?`$select=id,assignedLicenses"
$skuIds = @($u.assignedLicenses | ForEach-Object { [string]$_.skuId })
if ($skuIds.Count) { Invoke-DemoGraph POST "$G/v1.0/users/$($u.id)/assignLicense" -Body @{ addLicenses = @(); removeLicenses = $skuIds } | Out-Null }
Invoke-DemoGraph DELETE "$G/v1.0/users/$($u.id)" | Out-Null
$purged = $false
for ($i = 0; $i -lt 12 -and -not $purged; $i++) {
    Start-Sleep -Seconds 10
    $x = Invoke-DemoGraph DELETE "$G/v1.0/directory/deletedItems/$($u.id)" -NoThrow -MaxRetries 1
    $purged = -not ($x -and $x.PSObject.Properties['error'])
}
Write-DemoLog $Prefix "Leaver $upn deleted$(if ($purged) { ' and permanently deleted' } else { ' (permanent deletion pending: remove it from Deleted users)' })"
$st = Read-DemoLabState $Prefix
if ($st.users.Contains($leaver)) { $st.users[$leaver]['deletedAt'] = (Get-Date).ToString('s'); Save-DemoLabState $Prefix $st }

# 4) The agent is ownerless again (the catalog may keep the deleted id for a while: unresolvable = ownerless)
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
while ($true) {
    Clear-DemoPackageCache
    $x = Get-DemoAgentPackages $cfg $LOC $state $a
    $cur = if ($x.shared) { $x.shared } else { $x.published }
    if (Test-DemoOwnerless $cur) {
        $how = if ([string]$cur.ownerId) { "the catalog keeps the deleted user's id ($($cur.ownerId)): the admin center may show a nameless owner and not count the agent" } else { 'empty owner' }
        Write-DemoLog $Prefix "'$nm' is ownerless again for the API, $how ($(if ($lp.manager) { 'ready for the reassignment rule, run live in D8' } else { 'ready for D1 and D5' }))"
        break
    }
    if ((Get-Date) -gt $deadline) { Write-DemoLog $Prefix "'$nm' still shows owner $($cur.ownerId) after $TimeoutMinutes minutes: check again later" 'WARN'; break }
    Start-Sleep -Seconds 30
}
Write-Host "Verify the admin-center card 'Agents without owners' the day after: in some tenants the hard delete leaves a dangling owner for good and the card (and the D8 rule) never count the agent. Plan B = the empty Owner column in All agents; 'Assign new owner' works anyway."
# Shared agents are reachable only through their share link: the recipients open it again after every recreation.
$link = "https://m365.cloud.microsoft/chat/?titleId=$($cur.id)"
$who = @($a.shareLinkOpenedBy | ForEach-Object { "$(Get-DemoPersonaDisplayName $LOC $_) ($(Get-DemoUpn $LOC $cfg $_))" })
if ($who.Count) { Write-Host "Share link to open once, signed in as each recipient: $link`n  $($who -join "`n  ")" }
