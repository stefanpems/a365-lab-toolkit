#requires -Version 7.0
<#
.SYNOPSIS
  Checks that the Copilot Studio agents of a demo lab are really published, and publishes them through Dataverse when
  the Publish button of Copilot Studio silently did nothing.
.DESCRIPTION
  Reference lab, 29/09: Teams and Microsoft 365 Copilot serve the PUBLISHED version (the test pane runs the draft). A
  publish can silently do nothing: the bot's synchronization state stays "Synchronizing" and its 'publishedon' date does
  not move. This script reads, per agent (bots table of the agent's environment): publishedon, modifiedon and the
  synchronization state. With -Publish it calls the Dataverse action PvaPublish (as the signed-in environment admin) on
  the agents that are not up to date (or on all of them with -Force) and polls until 'publishedon' changes.
  Side effect of -Publish: Copilot Studio shows "Published by" the operator; re-run Set-DemoGovernance.ps1 -Step
  identities if the owner or sponsor of the agent identity drifts.
.EXAMPLE
  pwsh -File .\Publish-DemoMcsAgent.ps1 -Prefix cts2
.EXAMPLE
  pwsh -File .\Publish-DemoMcsAgent.ps1 -Prefix cts2 -Agent grantsDesk -Publish
#>
[CmdletBinding(PositionalBinding = $false)]
param([Parameter(Mandatory)][string]$Prefix, [string[]]$Agent = @('all'), [switch]$Publish, [switch]$Force, [int]$TimeoutMinutes = 5)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_demo-common.ps1')
$Agent = @($Agent | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$cfg = Read-DemoConfig $Prefix
$pack = Get-DemoPack $cfg.pack
$LOC = Get-DemoLocale -Locale $cfg.locale -Pack $cfg.pack
$state = Read-DemoLabState $Prefix
Assert-DemoTenant $cfg
$list = @($pack.agents | Where-Object { $_.platform -eq 'copilotStudio' -and ($Agent -contains 'all' -or $Agent -contains $_.key) })
if (-not $list.Count) { throw "No Copilot Studio agent of pack '$($cfg.pack)' matches: $($Agent -join ', ')." }

function Get-SyncState($Bot) { try { [string](([string]$Bot.synchronizationstatus | ConvertFrom-Json).currentSynchronizationState.state) } catch { '' } }

foreach ($a in $list) {
    $name = Get-DemoAgentName -Locale $LOC -Key $a.key -Surface copilotStudio
    $envId = if ($a.environment -eq 'default') { [string]$cfg.copilotStudio.defaultEnvironmentId } else { [string]$cfg.copilotStudio.paygEnvironmentId }
    if (-not $envId) { Write-DemoLog $Prefix "${name}: no environment id in the demo config (New-DemoConfig.ps1)" 'WARN'; continue }
    $b = Resolve-DemoCopilotStudioBot $cfg $LOC $state $a
    if (-not $b) { Write-DemoLog $Prefix "${name}: bot not found by id or exact configured name" 'WARN'; continue }
    $org = [string]$state.agents[$a.key].dataverseUrl
    $syncState = Get-SyncState $b
    $pub = if ($b.publishedon) { [datetime]$b.publishedon } else { [datetime]::MinValue }
    $mod = [datetime]$b.modifiedon
    $stale = (-not $b.publishedon) -or ($mod -gt $pub.AddMinutes(1))
    $stuck = $syncState -eq 'Synchronizing'
    # Agents whose starting state is a pending request or a block are never republished without -Force: a publish would
    # change what the live demo shows.
    $protected = $a.baseline -and ($a.baseline.pendingRequest -or $a.baseline.blocked)
    $verdict = if ($stale) { 'NOT up to date' } elseif ($stuck) { 'synchronization not finished (check the Channels page)' } else { 'up to date' }
    Write-Host ("{0,-34} published {1}  modified {2}  sync '{3}'  -> {4}{5}" -f $name, $(if ($b.publishedon) { $pub.ToString('s') } else { 'never' }), $mod.ToString('s'), $syncState, $verdict, $(if ($protected) { ' [pending request or blocked: never republished without -Force]' }))
    if (-not $Publish) { continue }
    if ($protected -and -not $Force) { continue }
    if (-not ($stale -or $stuck) -and -not $Force) { continue }
    $t = Get-DemoAzToken -Resource $org
    Invoke-DemoGraph POST "$org/api/data/v9.2/bots($($b.botid))/Microsoft.Dynamics.CRM.PvaPublish" -Token $t -Body @{} | Out-Null
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes); $done = $false
    while (-not $done -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10
        $nb = Resolve-DemoCopilotStudioBot $cfg $LOC $state $a
        if (-not $nb) { throw "Bot '$($b.botid)' disappeared while waiting for publication." }
        $done = $nb.publishedon -and ([datetime]$nb.publishedon -gt $pub) -and ((Get-SyncState $nb) -ne 'Synchronizing')
    }
    Write-DemoLog $Prefix "${name}: PvaPublish $(if ($done) { 'done' } else { "not confirmed within $TimeoutMinutes min (check Channels in Copilot Studio)" })" $(if ($done) { 'INFO' } else { 'WARN' })
}
Write-Host 'After a publish: in Teams / Microsoft 365 Copilot start a new conversation; tools in Invoker mode ask each user to allow the connection at the first call.'
