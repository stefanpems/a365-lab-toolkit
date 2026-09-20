#Requires -Version 7
<#
.SYNOPSIS
  Step 3 of the Map Explainer: drill into ONE connection of an agent and print the meaningful
  per-item detail (sessions / tool calls / exceptions / connected-agent invocations).

.DESCRIPTION
  READ-ONLY. The "meaningful details" are fixed by design (chosen to explain WHEN it happened, WHAT
  happened, the question, the answer, and error causes):

    -Kind USER  -Key <display name>
        One row per session: start/end (UTC) + duration, channel (Teams vs Studio vs published test),
        #user/#bot turns, the FIRST user prompt (the ask), the LAST bot reply (the outcome), and any
        error in the session. Add -Full to print the whole ordered transcript of each session.

    -Kind TOOL  -Key <target | Anon | Auth | Mail | mcp_MailTools | InvokeServer ...>
        One row per tool call: timestamp, success + HTTP resultCode, duration(ms), the triggering user
        prompt (nearest preceding user turn in the same conversation) and the resulting bot reply
        (nearest following bot turn). Use -OnlyExceptions to show only the failed calls (with the
        agent-level OnErrorLog message nearest each failure, i.e. the likely error cause).

    -Kind AGENT -Key <connected agent name>
        One row per connected-agent invocation: timestamp, the user prompt that triggered the
        delegation, the CALLER's final reply, and (from the same App Insights) the CALLEE's
        sub-conversation turns for that hand-off.

.EXAMPLE
  pwsh -File Show-MapConnectionDetails.ps1 -App lab16-appinsights -Rg lab16-appinsights-rg -Agent lab16-MCS-OH-1 -Kind TOOL -Key Auth
  pwsh -File Show-MapConnectionDetails.ps1 -App lab16-appinsights -Rg lab16-appinsights-rg -Agent lab16-MCS-OH-1 -Kind TOOL -Key Mail -OnlyExceptions
  pwsh -File Show-MapConnectionDetails.ps1 -App lab16-appinsights -Rg lab16-appinsights-rg -Agent lab16-MCS-OH-1 -Kind USER -Key "MOD Administrator"
  pwsh -File Show-MapConnectionDetails.ps1 -App lab16-appinsights -Rg lab16-appinsights-rg -Agent lab16-MCS-OH-1 -Kind AGENT -Key lab16-MCS-OH-2
#>
param(
    [Parameter(Mandatory)] [string] $App,
    [Parameter(Mandatory)] [string] $Rg,
    [Parameter(Mandatory)] [string] $Agent,
    [Parameter(Mandatory)] [ValidateSet('USER', 'TOOL', 'AGENT')] [string] $Kind,
    [Parameter(Mandatory)] [string] $Key,
    [switch] $OnlyExceptions,
    [switch] $Full,
    [int] $Max = 50,
    [int] $OffsetDays = 30
)
. "$PSScriptRoot/_common.ps1"

$allEvents = Get-MapCustomEvents -App $App -Rg $Rg -OffsetDays $OffsetDays
$allDeps   = Get-MapDependencies -App $App -Rg $Rg -OffsetDays $OffsetDays
$allPv     = Get-MapPageViews    -App $App -Rg $Rg -OffsetDays $OffsetDays

# Turns for THIS agent, in time order (used for correlation and transcripts).
$turns = @($allEvents | Where-Object { $_.agent -eq $Agent -and $_.name -in @('BotMessageReceived', 'BotMessageSend') } | Sort-Object ts)
$errs  = @($allEvents | Where-Object { $_.agent -eq $Agent -and $_.name -eq 'OnErrorLog' } | Sort-Object ts)

function Get-TriggerPrompt {
    param([string] $Conv, [datetime] $At)
    $c = @($turns | Where-Object { $_.conv -eq $Conv -and $_.name -eq 'BotMessageReceived' -and $_.type -eq 'message' -and $_.ts -le $At.AddSeconds(2) } | Sort-Object ts)
    if ($c.Count) { return $c[-1].text }
    return ''
}
function Get-FollowingReply {
    param([string] $Conv, [datetime] $At)
    $c = @($turns | Where-Object { $_.conv -eq $Conv -and $_.name -eq 'BotMessageSend' -and $_.text -and $_.ts -ge $At.AddSeconds(-2) } | Sort-Object ts)
    if ($c.Count) { return $c[0].text }
    return ''
}
function Get-NearestError {
    param([string] $Conv, [datetime] $At)
    $c = @($errs | Where-Object { $_.conv -eq $Conv } | Sort-Object { [math]::Abs(($_.ts - $At).TotalSeconds) })
    if ($c.Count) { return "$($c[0].errorCode): $($c[0].errorMsg)" }
    return ''
}

Write-Host ""
Write-Host "Detail: $Agent  /  $Kind  /  $Key   (last ${OffsetDays}d)" -ForegroundColor Cyan

switch ($Kind) {

    'USER' {
        # Resolve which sessions belong to this user (display name or oid).
        $sessOf = @{}
        foreach ($e in ($allEvents | Where-Object { $_.agent -eq $Agent -and $_.session })) {
            $k = $null
            if ($e.user) { $k = $e.user }
            elseif ($e.userId -match '([0-9a-fA-F-]{36})') { $k = Resolve-AadName $Matches[1] }
            if ($k -and $k -eq $Key) { $sessOf[$e.session] = $true }
        }
        $sessions = @($sessOf.Keys)
        if (-not $sessions) { Write-Host "  No sessions for user '$Key'."; return }
        Write-Host ("  {0} session(s). Showing up to {1}, most recent first." -f $sessions.Count, $Max)
        $sessLast = @{}
        foreach ($s in $sessions) { $sessLast[$s] = (@($allEvents | Where-Object { $_.session -eq $s }).ts | Measure-Object -Maximum).Maximum }
        $ordered = $sessions | Sort-Object { $sessLast[$_] } -Descending
        $n = 0
        foreach ($s in $ordered) {
            if ($n -ge $Max) { break }
            $n++
            $se = @($allEvents | Where-Object { $_.session -eq $s } | Sort-Object ts)
            $st = (@($se.ts) | Measure-Object -Minimum).Minimum
            $en = (@($se.ts) | Measure-Object -Maximum).Maximum
            $dur = [int]($en - $st).TotalSeconds
            $ch = (@($se.channel | Where-Object { $_ } | Sort-Object -Unique) -join ',')
            $uT = @($se | Where-Object { $_.name -eq 'BotMessageReceived' -and $_.type -eq 'message' })
            $bT = @($se | Where-Object { $_.name -eq 'BotMessageSend' })
            $firstAskT = @($uT | Where-Object { $_.text }) | Select-Object -First 1
            $lastRepT  = @($bT | Where-Object { $_.text }) | Select-Object -Last 1
            $firstAsk = if ($firstAskT) { $firstAskT.text } else { '' }
            $lastRep  = if ($lastRepT)  { $lastRepT.text }  else { '' }
            $err = @($se | Where-Object { $_.name -eq 'OnErrorLog' })
            Write-Host ""
            Write-Host ("  [{0}] {1} -> {2}  ({3}s, {4})  turns:{5}u/{6}b{7}" -f `
                $n, (Format-Ts $st), (Format-Ts $en), $dur, $ch, $uT.Count, $bT.Count, ($(if ($err.Count) { "  ERRORS:$($err.Count)" } else { '' }))) -ForegroundColor Yellow
            if ($firstAsk) { Write-Host ("      ask:     {0}" -f (Get-Trunc $firstAsk 160)) }
            if ($lastRep)  { Write-Host ("      outcome: {0}" -f (Get-Trunc $lastRep 160)) }
            if ($err.Count) { Write-Host ("      error:   {0}: {1}" -f $err[0].errorCode, (Get-Trunc $err[0].errorMsg 120)) -ForegroundColor Red }
            if ($Full) {
                foreach ($t in $se | Where-Object { $_.name -in @('BotMessageReceived', 'BotMessageSend') }) {
                    $dir = if ($t.name -eq 'BotMessageReceived') { 'USER ->' } else { '<- BOT ' }
                    $tx = if ($t.text) { $t.text } else { '(no text captured)' }
                    Write-Host ("        [{0}] {1} {2}" -f (Format-Ts $t.ts), $dir, (Get-Trunc $tx 200))
                }
            }
        }
    }

    'TOOL' {
        $calls = @($allDeps | Where-Object { $_.agent -eq $Agent })
        # Match Key against target (exact/substring) or the friendly label.
        $sel = @($calls | Where-Object {
                $_.target -eq $Key -or
                $_.target -like "*$Key*" -or
                $_.name -like "*$Key*" -or
                (Get-ToolLabel -Target $_.target -Name $_.name) -like "*$Key*"
            })
        if ($OnlyExceptions) { $sel = @($sel | Where-Object { -not $_.success }) }
        $sel = @($sel | Sort-Object ts -Descending)
        if (-not $sel) { Write-Host "  No$([string]$(if($OnlyExceptions){' failed'})) tool calls match '$Key'."; return }
        $targets = @($sel.target | Sort-Object -Unique)
        Write-Host ("  {0} call(s){1} across target(s): {2}. Showing up to {3}." -f $sel.Count, ($(if ($OnlyExceptions) { ' [failures only]' } else { '' })), ($targets -join ', '), $Max)
        $n = 0
        foreach ($c in $sel) {
            if ($n -ge $Max) { break }
            $n++
            $verdict = if ($c.success) { 'OK ' } else { 'FAIL' }
            $col = if ($c.success) { 'Green' } else { 'Red' }
            Write-Host ""
            Write-Host ("  [{0}] {1}  {2}  http={3}  {4}ms  {5}" -f `
                $n, (Format-Ts $c.ts), $verdict, $c.resultCode, [int]$c.duration, (Get-ToolLabel -Target $c.target -Name $c.name)) -ForegroundColor $col
            $ask = Get-TriggerPrompt -Conv $c.conv -At $c.ts
            $rep = Get-FollowingReply -Conv $c.conv -At $c.ts
            if ($ask) { Write-Host ("      trigger: {0}" -f (Get-Trunc $ask 160)) }
            if ($rep) { Write-Host ("      result:  {0}" -f (Get-Trunc $rep 160)) }
            if (-not $c.success) {
                $er = Get-NearestError -Conv $c.conv -At $c.ts
                if ($er) { Write-Host ("      cause:   {0}" -f (Get-Trunc $er 160)) -ForegroundColor Red }
            }
        }
    }

    'AGENT' {
        $inv = @($allPv | Where-Object { $_.agent -eq $Agent -and $_.name -match "InvokeConnectedAgentTaskAction\.$([regex]::Escape($Key))$" } | Sort-Object ts -Descending)
        if (-not $inv) {
            $inv = @($allPv | Where-Object { $_.agent -eq $Agent -and $_.name -match 'InvokeConnectedAgentTaskAction' -and $_.name -like "*$Key*" } | Sort-Object ts -Descending)
        }
        if (-not $inv) { Write-Host "  No connected-agent invocations to '$Key'."; return }
        Write-Host ("  {0} invocation(s) of {1}. Showing up to {2}." -f $inv.Count, $Key, $Max)
        # Callee turns (the connected agent's own telemetry in the same App Insights).
        $calleeTurns = @($allEvents | Where-Object { $_.agent -eq $Key -and $_.name -in @('BotMessageReceived', 'BotMessageSend') } | Sort-Object ts)
        $n = 0
        foreach ($iv in $inv) {
            if ($n -ge $Max) { break }
            $n++
            Write-Host ""
            Write-Host ("  [{0}] {1}  caller-conv={2}" -f $n, (Format-Ts $iv.ts), (Get-Trunc $iv.conv 40)) -ForegroundColor Yellow
            $ask = Get-TriggerPrompt -Conv $iv.conv -At $iv.ts
            $rep = Get-FollowingReply -Conv $iv.conv -At $iv.ts
            if ($ask) { Write-Host ("      user asked:    {0}" -f (Get-Trunc $ask 160)) }
            if ($rep) { Write-Host ("      caller reply:  {0}" -f (Get-Trunc $rep 160)) }
            # Best-effort callee sub-conversation: turns of the callee whose conv starts with the caller conv.
            $sub = @($calleeTurns | Where-Object { $_.conv -and ($_.conv -like "$($iv.conv)*") -and [math]::Abs(($_.ts - $iv.ts).TotalMinutes) -le 5 } | Sort-Object ts)
            foreach ($t in $sub) {
                $dir = if ($t.name -eq 'BotMessageReceived') { "$Key received" } else { "$Key replied " }
                if ($t.text) { Write-Host ("        {0}: {1}" -f $dir, (Get-Trunc $t.text 160)) }
            }
        }
    }
}
Write-Host ""
