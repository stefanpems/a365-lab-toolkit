#Requires -Version 7
<#
.SYNOPSIS
  Step 1 of the Map Explainer: list the agents that logged telemetry in an Application Insights
  resource, with their session / tool-call / error counts, so the user can pick one.

.DESCRIPTION
  READ-ONLY. Pulls customEvents + dependencies (projected) and aggregates client-side by
  cloud_RoleInstance (the per-event agent identity). Optional -Filter narrows the list:
    -Filter lab      -> only agents whose name starts with 'lab' (Lab Builder agents)
    -Filter M        -> only agents whose name starts with 'M' (any initial / prefix)
  The match is a case-insensitive prefix on the agent name.

.EXAMPLE
  pwsh -File Get-MapAgents.ps1 -App lab16-appinsights -Rg lab16-appinsights-rg
  pwsh -File Get-MapAgents.ps1 -App lab16-appinsights -Rg lab16-appinsights-rg -Filter lab
#>
param(
    [Parameter(Mandatory)] [string] $App,
    [Parameter(Mandatory)] [string] $Rg,
    [string] $Filter,
    [int] $OffsetDays = 30,
    [switch] $Json
)
. "$PSScriptRoot/_common.ps1"

$events = Get-MapCustomEvents -App $App -Rg $Rg -OffsetDays $OffsetDays
$deps   = Get-MapDependencies -App $App -Rg $Rg -OffsetDays $OffsetDays

if (-not $events) { Write-Host "No customEvents found in $App (window ${OffsetDays}d). Is it the right resource?"; return }

$agents = @($events | Where-Object { $_.agent } | Select-Object -ExpandProperty agent -Unique)
if ($Filter) { $agents = @($agents | Where-Object { $_ -like "$Filter*" }) }
$agents = @($agents | Sort-Object)

$rows = foreach ($a in $agents) {
    $ce = @($events | Where-Object { $_.agent -eq $a })
    $dp = @($deps   | Where-Object { $_.agent -eq $a })
    $sessions = (@($ce.session | Where-Object { $_ }) | Sort-Object -Unique).Count
    $users    = @($ce | Where-Object { $_.name -eq 'BotMessageReceived' -and $_.user } | Select-Object -ExpandProperty user -Unique)
    [pscustomobject]@{
        Agent       = $a
        Sessions    = $sessions
        Users       = $users.Count
        ToolCalls   = $dp.Count
        Exceptions  = @($dp | Where-Object { -not $_.success }).Count
        AgentErrors = @($ce | Where-Object { $_.name -eq 'OnErrorLog' }).Count
        LastSeen    = (@($ce.ts) | Measure-Object -Maximum).Maximum
    }
}

if ($Json) { $rows | ConvertTo-Json -Depth 5; return }

Write-Host ""
Write-Host "Agents in $App (last ${OffsetDays}d)$([string]::IsNullOrEmpty($Filter) ? '' : "  [filter: $Filter*]")" -ForegroundColor Cyan
if (-not $rows) { Write-Host "  (no agents match)"; return }
$i = 0
foreach ($r in $rows) {
    $i++
    "{0,2}. {1,-20} sessions={2,-4} users={3,-3} toolCalls={4,-4} exceptions={5,-3} agentErrors={6,-3} last={7:yyyy-MM-dd HH:mm}" -f `
        $i, $r.Agent, $r.Sessions, $r.Users, $r.ToolCalls, $r.Exceptions, $r.AgentErrors, $r.LastSeen
}
Write-Host ""
Write-Host "Note: 'sessions' here = distinct App Insights session_Id. The MAC/Agent 365 Map can show a"
Write-Host "higher number because Copilot Studio analytics retains sessions from before this App Insights"
Write-Host "was wired; very recent sessions may not be on the Map yet."
