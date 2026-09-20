#Requires -Version 7
<#
.SYNOPSIS
  Step 2 of the Map Explainer: for one agent, list its Map "connections" with the same counters the
  Map shows, so the user can pick one to drill into.

.DESCRIPTION
  READ-ONLY. Three connection kinds (matching the Map graph edges):
    USER   <agent> <-> a user      : sessions / user turns / errors           (from customEvents)
    TOOL   <agent> <-> a tool       : calls / exceptions                        (from dependencies, by target)
    AGENT  <agent> <-> another agent: connected-agent invocations               (from pageViews)
  Every counter is aggregated CLIENT-SIDE after projecting cloud_RoleInstance.

.EXAMPLE
  pwsh -File Get-MapConnections.ps1 -App lab16-appinsights -Rg lab16-appinsights-rg -Agent lab16-MCS-OH-1
#>
param(
    [Parameter(Mandatory)] [string] $App,
    [Parameter(Mandatory)] [string] $Rg,
    [Parameter(Mandatory)] [string] $Agent,
    [int] $OffsetDays = 30,
    [switch] $Json
)
. "$PSScriptRoot/_common.ps1"

$events = Get-MapCustomEvents -App $App -Rg $Rg -OffsetDays $OffsetDays
$deps   = Get-MapDependencies -App $App -Rg $Rg -OffsetDays $OffsetDays
$pv     = Get-MapPageViews    -App $App -Rg $Rg -OffsetDays $OffsetDays

$ce = @($events | Where-Object { $_.agent -eq $Agent })
$dp = @($deps   | Where-Object { $_.agent -eq $Agent })
$pg = @($pv     | Where-Object { $_.agent -eq $Agent })

if (-not $ce -and -not $dp) { Write-Host "No telemetry for agent '$Agent' in $App (window ${OffsetDays}d)."; return }

# --- USER connections ---
# The Map's user node aggregates every session a user had with the agent, across ALL channels.
# fromName is only present on Teams turns; pva-studio / pva-published sessions carry the user's AAD
# object id inside user_Id (channel-prefixed). Resolve one user key PER SESSION so counts match.
$sessionUser = @{}   # session -> user key (display name if known, else 'oid:<guid>')
$sessionMeta = @{}   # session -> [pscustomobject] channel/last
foreach ($e in $ce) {
    if (-not $e.session) { continue }
    if (-not $sessionMeta.ContainsKey($e.session)) {
        $sessionMeta[$e.session] = [pscustomobject]@{ channel = $e.channel; last = $e.ts }
    }
    elseif ($e.ts -gt $sessionMeta[$e.session].last) { $sessionMeta[$e.session].last = $e.ts }

    $key = $null
    if ($e.user) { $key = $e.user }
    elseif ($e.userId -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { $key = Resolve-AadName $Matches[1] }
    if ($key) {
        # Prefer a real display name over an oid key if we ever see one for the session.
        if (-not $sessionUser.ContainsKey($e.session) -or ($sessionUser[$e.session] -like 'oid:*' -and $key -notlike 'oid:*')) {
            $sessionUser[$e.session] = $key
        }
    }
}
$userGroups = $sessionUser.GetEnumerator() | Group-Object { $_.Value }
$userConns = foreach ($g in $userGroups) {
    $sessIds = @($g.Group | ForEach-Object { $_.Key })
    $meta    = @($sessIds | ForEach-Object { $sessionMeta[$_] })
    [pscustomobject]@{
        Kind     = 'USER'
        Key      = $g.Name
        Sessions = $sessIds.Count
        UserTurns= @($ce | Where-Object { $_.type -eq 'message' -and $sessIds -contains $_.session }).Count
        Channels = (@($meta.channel | Where-Object { $_ } | Sort-Object -Unique) -join ',')
        Last     = (@($meta.last) | Measure-Object -Maximum).Maximum
    }
}
$userConns = @($userConns | Sort-Object -Property Sessions -Descending)

# --- TOOL connections (by dependency target) ---
$toolConns = foreach ($g in ($dp | Group-Object target)) {
    [pscustomobject]@{
        Kind       = 'TOOL'
        Key        = $g.Name
        Label      = (Get-ToolLabel -Target $g.Name -Name $g.Group[0].name)
        Calls      = $g.Count
        Exceptions = @($g.Group | Where-Object { -not $_.success }).Count
        Last       = (@($g.Group.ts) | Measure-Object -Maximum).Maximum
    }
}

# --- CONNECTED-AGENT connections (pageViews InvokeConnectedAgentTaskAction.<callee>) ---
$agentConns = foreach ($g in ($pg | Where-Object { $_.name -match 'InvokeConnectedAgentTaskAction' } | Group-Object name)) {
    $callee = ($g.Name -split '\.InvokeConnectedAgentTaskAction\.')[-1]
    [pscustomobject]@{
        Kind  = 'AGENT'
        Key   = $callee
        Calls = $g.Count
        Last  = (@($g.Group.ts) | Measure-Object -Maximum).Maximum
    }
}

if ($Json) {
    [pscustomobject]@{ agent = $Agent; users = $userConns; tools = $toolConns; connectedAgents = $agentConns } | ConvertTo-Json -Depth 6
    return
}

Write-Host ""
Write-Host "Connections for $Agent (last ${OffsetDays}d)" -ForegroundColor Cyan
Write-Host ""
Write-Host "USERS (agent <-> user)" -ForegroundColor Yellow
if ($userConns) { foreach ($u in $userConns) { "   [U] {0,-20} sessions={1,-4} userTurns={2,-4} channels={3,-45} last={4:yyyy-MM-dd HH:mm}" -f $u.Key,$u.Sessions,$u.UserTurns,$u.Channels,$u.Last } } else { "   (none)" }
Write-Host ""
Write-Host "TOOLS (agent <-> tool)" -ForegroundColor Yellow
if ($toolConns) { foreach ($t in $toolConns) { "   [T] {0,-42} calls={1,-4} exceptions={2,-3} last={3:yyyy-MM-dd HH:mm}" -f $t.Label,$t.Calls,$t.Exceptions,$t.Last } } else { "   (none)" }
Write-Host ""
Write-Host "CONNECTED AGENTS (agent <-> agent)" -ForegroundColor Yellow
if ($agentConns) { foreach ($a in $agentConns) { "   [A] {0,-20} calls={1,-4} last={2:yyyy-MM-dd HH:mm}" -f $a.Key,$a.Calls,$a.Last } } else { "   (none)" }
Write-Host ""
Write-Host "Pick a connection to drill into (e.g. a USER, a TOOL, or a connected AGENT); then I run"
Write-Host "Show-MapConnectionDetails.ps1 for the meaningful per-item details."
