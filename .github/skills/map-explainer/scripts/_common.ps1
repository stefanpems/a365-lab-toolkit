#Requires -Version 7
<#
.SYNOPSIS
  Shared, READ-ONLY helpers for the Map Explainer.
  Dot-source this file: . "$PSScriptRoot/_common.ps1"

  The Map Explainer reproduces the numbers shown on the Microsoft Admin Center / Agent 365 "Map"
  for a Copilot Studio (MCS) agent, from the lab's Application Insights resource, and lets the user
  drill into the underlying sessions / tool calls / exceptions with meaningful detail.

  VERIFIED FACTS (2026-09-20) baked into these helpers:
   * Per-event agent identity = column cloud_RoleInstance (cloud_RoleName is always
     "Microsoft Copilot Studio"). The App Insights Analytics API rejects where/summarize/extend on
     cloud_RoleInstance with BadArgumentError, so we PROJECT it and aggregate CLIENT-SIDE.
   * Every query passes --offset 30d (the default window is 1h) and uses SINGLE-LINE KQL.
   * Tables used: customEvents (turns/topics/errors), dependencies (tool/connector calls),
     pageViews (topic + connected-agent invocations).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------------------
# Azure CLI Application Insights query (read-only) with retry, returning the first table or $null.
# KQL MUST be a single line. Time window is controlled by -OffsetDays (API default is 1h).
# ---------------------------------------------------------------------------------------------------
function Invoke-AiQuery {
    param(
        [Parameter(Mandatory)] [string] $App,
        [Parameter(Mandatory)] [string] $Rg,
        [Parameter(Mandatory)] [string] $Kql,
        [int] $OffsetDays = 30,
        [int] $Retries = 6
    )
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $json = az monitor app-insights query --app $App -g $Rg --offset "$($OffsetDays)d" --analytics-query $Kql -o json 2>$null
        if ($json) {
            try { $obj = $json | ConvertFrom-Json } catch { $obj = $null }
            if ($obj -and $obj.tables -and $obj.tables[0]) { return $obj.tables[0] }
        }
    }
    return $null
}

function ConvertFrom-AiRow {
    # Turn a table's columns+rows into an array of PSCustomObjects keyed by column name.
    param($Table)
    if (-not $Table) { return @() }
    $names = @($Table.columns | ForEach-Object { $_.name })
    foreach ($row in $Table.rows) {
        $o = [ordered]@{}
        for ($i = 0; $i -lt $names.Count; $i++) { $o[$names[$i]] = $row[$i] }
        [pscustomobject]$o
    }
}

function ConvertFrom-Cd {
    # Parse an App Insights customDimensions string into an object (empty object on failure).
    param([string] $Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return [pscustomobject]@{} }
    try { return $Raw | ConvertFrom-Json } catch { return [pscustomobject]@{} }
}

function Get-Prop {
    # StrictMode-safe read of a possibly-absent property; returns '' when missing.
    param($Obj, [string] $Name)
    if ($null -eq $Obj) { return '' }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return '' }
    return [string]$p.Value
}

# ---------------------------------------------------------------------------------------------------
# Data pulls — always PROJECT (never filter/group on cloud_RoleInstance in KQL) and aggregate later.
# ---------------------------------------------------------------------------------------------------
function Get-MapCustomEvents {
    param([Parameter(Mandatory)] [string] $App, [Parameter(Mandatory)] [string] $Rg, [int] $OffsetDays = 30)
    $tbl = Invoke-AiQuery -App $App -Rg $Rg -OffsetDays $OffsetDays -Kql `
        "customEvents | project ts=timestamp, name, session=session_Id, agent=cloud_RoleInstance, userId=user_Id, cd=customDimensions"
    foreach ($r in (ConvertFrom-AiRow $tbl)) {
        $d = ConvertFrom-Cd $r.cd
        [pscustomobject]@{
            ts        = [datetime]$r.ts
            name      = [string]$r.name
            session   = [string]$r.session
            agent     = [string]$r.agent
            userId    = [string]$r.userId
            conv      = Get-Prop $d 'conversationId'
            user      = Get-Prop $d 'fromName'
            channel   = Get-Prop $d 'channelId'
            type      = Get-Prop $d 'type'
            recipient = Get-Prop $d 'recipientName'
            text      = Get-Prop $d 'text'
            errorCode = Get-Prop $d 'ErrorCode'
            errorMsg  = Get-Prop $d 'ErrorMessage'
            designMode = Get-Prop $d 'DesignMode'
        }
    }
}

function Get-MapDependencies {
    param([Parameter(Mandatory)] [string] $App, [Parameter(Mandatory)] [string] $Rg, [int] $OffsetDays = 30)
    $tbl = Invoke-AiQuery -App $App -Rg $Rg -OffsetDays $OffsetDays -Kql `
        "dependencies | project ts=timestamp, name, target, type, success, resultCode, duration, agent=cloud_RoleInstance, cd=customDimensions"
    foreach ($r in (ConvertFrom-AiRow $tbl)) {
        $d = ConvertFrom-Cd $r.cd
        [pscustomobject]@{
            ts         = [datetime]$r.ts
            name       = [string]$r.name
            target     = [string]$r.target
            type       = [string]$r.type
            success    = ([string]$r.success -eq 'True')
            resultCode = [string]$r.resultCode
            duration   = [double]($r.duration)
            agent      = [string]$r.agent
            conv       = Get-Prop $d 'conversationId'
            channel    = Get-Prop $d 'channelId'
        }
    }
}

function Get-MapPageViews {
    param([Parameter(Mandatory)] [string] $App, [Parameter(Mandatory)] [string] $Rg, [int] $OffsetDays = 30)
    $tbl = Invoke-AiQuery -App $App -Rg $Rg -OffsetDays $OffsetDays -Kql `
        "pageViews | project ts=timestamp, name, agent=cloud_RoleInstance, cd=customDimensions"
    foreach ($r in (ConvertFrom-AiRow $tbl)) {
        $d = ConvertFrom-Cd $r.cd
        [pscustomobject]@{
            ts      = [datetime]$r.ts
            name    = [string]$r.name
            agent   = [string]$r.agent
            conv    = Get-Prop $d 'conversationId'
            channel = Get-Prop $d 'channelId'
        }
    }
}

# ---------------------------------------------------------------------------------------------------
# Presentation helpers
# ---------------------------------------------------------------------------------------------------
function Get-ToolLabel {
    # Friendly tool name from a dependency target (shared_<connector>/<Action>).
    param([string] $Target, [string] $Name)
    switch -Wildcard ($Target) {
        '*a365outlookmailmcp/mcp_MailTools' { return 'A365 Outlook Mail MCP (mcp_MailTools)' }
        '*Anon*/InvokeServer'               { return "Custom MCP (Anon) InvokeServer [$Name]" }
        '*Auth*/InvokeServer'               { return "Custom MCP (Auth) InvokeServer [$Name]" }
        default                             { if ($Target) { return $Target } else { return $Name } }
    }
}

function Format-Ts { param([datetime] $T) $T.ToString('yyyy-MM-dd HH:mm:ss') }

function Get-Trunc { param([string] $S, [int] $Max = 140)
    if ([string]::IsNullOrEmpty($S)) { return '' }
    $one = ($S -replace '\s+', ' ').Trim()
    if ($one.Length -le $Max) { return $one }
    return $one.Substring(0, $Max) + '…'
}

# Best-effort AAD object-id -> display name resolution (read-only, cached). Falls back to 'oid:<id>'.
$script:AadCache = @{}
function Resolve-AadName {
    param([string] $ObjectId)
    if ([string]::IsNullOrWhiteSpace($ObjectId)) { return '' }
    if ($script:AadCache.ContainsKey($ObjectId)) { return $script:AadCache[$ObjectId] }
    $name = $null
    try { $name = az ad user show --id $ObjectId --query displayName -o tsv 2>$null } catch { $name = $null }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = "oid:$ObjectId" }
    $script:AadCache[$ObjectId] = $name
    return $name
}
