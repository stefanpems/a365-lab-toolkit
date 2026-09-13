#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Read diagnostic logs for the Foundry hosted digital-worker agent and its Teams gateway.

.DESCRIPTION
    The message path is:

        Teams / M365  ->  Azure Bot Service (gateway)  ->  Foundry activityProtocol endpoint  ->  hosted container (agent.py)

    This script surfaces logs at each hop so you can tell WHERE a message is lost:

      1. gateway   : Azure Bot Service "BotRequest" diagnostic logs (Log Analytics).
                     Shows the inbound Teams activity and the outbound relay to Foundry,
                     including the HTTP status Foundry returned (e.g. 403 / 500 / timeout).
      2. container : Foundry hosted-agent per-session log stream (container stdout/stderr),
                     given a session id. Session ids show up in the gateway logs and in
                     error responses as FOUNDRY_AGENT_SESSION_ID.

.PARAMETER Mode
    gateway  (default) - query Bot Service BotRequest logs from Log Analytics.
    sessions           - list the hosted-agent sessions (newest last).
    session            - stream a Foundry hosted-agent session log (requires -SessionId).
    live               - snapshot sessions, wait for you to send a Teams message, then
                         stream the logs of the NEW session that gets created.

.PARAMETER Minutes
    Look-back window for gateway logs. Default 30.

.PARAMETER SessionId
    Foundry session id/name to stream (Mode=session).

.EXAMPLE
    ./read-logs.ps1                          # last 30 min of gateway logs
.EXAMPLE
    ./read-logs.ps1 -Mode sessions
.EXAMPLE
    ./read-logs.ps1 -Mode session -SessionId <FOUNDRY_AGENT_SESSION_ID>
.EXAMPLE
    ./read-logs.ps1 -Mode live               # then send a message in Teams
#>
[CmdletBinding()]
param(
    [ValidateSet('gateway', 'sessions', 'session', 'live')]
    [string]$Mode = 'gateway',
    [int]$Minutes = 30,
    [string]$SessionId,

    # --- Environment-specific values (fill in for your own deployment) --------
    # Defaults come from environment variables so nothing tenant-specific is
    # hard-coded here. Override on the command line or set the env vars.
    [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
    [string]$ResourceGroup  = $env:AZURE_RESOURCE_GROUP,
    [string]$WorkspaceName  = $env:LOG_ANALYTICS_WORKSPACE,
    [string]$AccountName    = $env:FOUNDRY_ACCOUNT_NAME,
    [string]$ProjectName    = $env:FOUNDRY_PROJECT_NAME,
    [string]$AgentName      = $env:FOUNDRY_AGENT_NAME,
    [string]$AzdEnv         = $env:AZURE_ENV_NAME
)

$ErrorActionPreference = 'Stop'

foreach ($p in 'SubscriptionId', 'ResourceGroup', 'WorkspaceName', 'AccountName', 'ProjectName', 'AgentName') {
    if (-not (Get-Variable $p -ValueOnly)) {
        throw "Missing required value '$p'. Pass -$p or set the matching environment variable."
    }
}
$ProjectEndpoint = "https://$AccountName.services.ai.azure.com/api/projects/$ProjectName"
# azd needs to resolve the project config (azure.yaml), which lives in the repo root.
$ProjectDir     = Split-Path -Parent $PSScriptRoot

function Get-WorkspaceGuid {
    az monitor log-analytics workspace show `
        -g $ResourceGroup -n $WorkspaceName `
        --query customerId -o tsv
}

function Read-GatewayLogs {
    $wsGuid = Get-WorkspaceGuid
    if (-not $wsGuid) { throw "Log Analytics workspace '$WorkspaceName' not found." }

    $query = @"
AzureDiagnostics
| where TimeGenerated > ago(${Minutes}m)
| where ResourceProvider == "MICROSOFT.BOTSERVICE"
| project TimeGenerated, Activity=ActivityType_s, Status=ResultSignature_s,
          ResultDescription, Callback=CallbackUri_s, Channel=ChannelId_s
| order by TimeGenerated desc
| take 100
"@

    Write-Host "=== Gateway (Bot Service BotRequest) logs — last ${Minutes}m ===" -ForegroundColor Cyan
    $res = az monitor log-analytics query `
        --workspace $wsGuid `
        --analytics-query $query `
        -o json | ConvertFrom-Json

    if (-not $res -or $res.Count -eq 0) {
        Write-Host "No BotRequest rows yet." -ForegroundColor Yellow
        Write-Host "Notes:" -ForegroundColor DarkGray
        Write-Host "  * First ingestion after enabling diagnostics can take 5-15 min." -ForegroundColor DarkGray
        Write-Host "  * Rows only appear AFTER a message is sent to the agent in Teams." -ForegroundColor DarkGray
        Write-Host "  * If a message was sent and still nothing here, the activity never" -ForegroundColor DarkGray
        Write-Host "    reached the Bot Service (Teams channel / app manifest problem)." -ForegroundColor DarkGray
        return
    }
    $res | Format-Table -AutoSize
}

function Get-AiToken {
    az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv
}

function Get-SessionIds {
    # The agent-scoped /sessions REST route is 404; the reliable listing path is the
    # azd ai agents extension, which resolves via FOUNDRY_PROJECT_ENDPOINT + --agent-name.
    $env:FOUNDRY_PROJECT_ENDPOINT = $ProjectEndpoint
    $out = azd ai agent sessions list -e $AzdEnv --agent-name $AgentName -o json 2>$null
    try { (($out -join "`n") | ConvertFrom-Json).data } catch { @() }
}

function Show-Sessions {
    $sessions = Get-SessionIds | Sort-Object last_accessed_at
    Write-Host "=== Hosted agent sessions (oldest first) ===" -ForegroundColor Cyan
    $sessions | Select-Object `
        @{n = 'session_id'; e = { $_.agent_session_id } }, `
        status, `
        @{n = 'last_accessed'; e = { [DateTimeOffset]::FromUnixTimeSeconds($_.last_accessed_at).LocalDateTime } } |
        Format-Table -AutoSize
}

function Stream-Session {
    param([string]$Id)
    # Prefer the official azd extension (richer formatting). Container logs are LIVE-only,
    # so --follow must be attached while the session is still active.
    # azd resolves the agent from azure.yaml, so run from the project dir.
    $env:FOUNDRY_PROJECT_ENDPOINT = $ProjectEndpoint
    Push-Location $ProjectDir
    try {
        azd ai agent monitor -e $AzdEnv --session-id $Id --type console --follow
    }
    finally {
        Pop-Location
    }
}

function Read-SessionLog {
    if (-not $SessionId) { throw "Mode=session requires -SessionId <id>." }
    Write-Host "=== Foundry container session log: $SessionId ===" -ForegroundColor Cyan
    Write-Host "Streaming (Ctrl+C to stop)..." -ForegroundColor DarkGray
    Stream-Session -Id $SessionId
}

function Read-LiveLog {
    $before = @(Get-SessionIds | ForEach-Object { $_.agent_session_id })
    Write-Host "Current sessions: $($before.Count)" -ForegroundColor DarkGray
    Write-Host "" 
    Write-Host ">>> NOW send a message to the agent in Teams. <<<" -ForegroundColor Green
    Write-Host "Waiting for a new session to appear (up to 3 min), then attaching to its live logs..." -ForegroundColor DarkGray

    $deadline = (Get-Date).AddMinutes(3)
    $newId = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 1200
        $now = @(Get-SessionIds)
        $new = $now | Where-Object { $before -notcontains $_.agent_session_id } | Sort-Object last_accessed_at
        if ($new) { $newId = ($new | Select-Object -Last 1).agent_session_id; break }
    }

    if (-not $newId) {
        Write-Host "No new session appeared. The message never reached Foundry" -ForegroundColor Yellow
        Write-Host "(check gateway logs: ./read-logs.ps1 -Mode gateway)." -ForegroundColor Yellow
        return
    }
    Write-Host "New session: $newId - attaching live logs..." -ForegroundColor Cyan
    Stream-Session -Id $newId
}

switch ($Mode) {
    'gateway'  { Read-GatewayLogs }
    'sessions' { Show-Sessions }
    'session'  { Read-SessionLog }
    'live'     { Read-LiveLog }
}
