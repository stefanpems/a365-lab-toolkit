<#
.SYNOPSIS
  Remove a Microsoft Copilot Studio (MCS) agent and/or its solution from a Copilot Studio environment.
.DESCRIPTION
  Used by the Lab Cleaner and Agent Remover to tear down MCS-OH / MCS-NH agents. Two removals:
    1. The Power Platform SOLUTION container   -> `pac solution delete --solution-name <unique>` (reliable).
    2. The Copilot Studio AGENT (bot) record   -> `pac copilot-studio delete-copilot-agent --bot-id <id>`.
  Deleting an UNMANAGED solution does not remove its bot component, so to fully remove the agent supply
  -BotId (found in the Copilot Studio agent URL: .../bots/<guid>) or delete it in the portal.

  Requires the Power Platform CLI (pac) authenticated to the TARGET tenant.
.PARAMETER Tenant             Target tenant id (interactive sign-in if no matching pac profile).
.PARAMETER EnvironmentId      Target environment GUID (resolved to org URL) — or pass -EnvironmentUrl.
.PARAMETER EnvironmentUrl     Target Dataverse org URL.
.PARAMETER SolutionUniqueName Solution to delete (as recorded in the plan; e.g. contosoMCSOH).
.PARAMETER DisplayName        Agent display name — used to AUTO-DISCOVER the bot GUID (via a Dataverse
                              query with an az token) so -BotId is not needed. Requires az logged into
                              the target tenant.
.PARAMETER SchemaName         Optional bot schema name, used as a fallback key for bot-id discovery.
.PARAMETER BotId              Optional bot GUID to delete the agent directly (skips auto-discovery).
.PARAMETER WhatIf             Show what would be deleted without deleting.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Tenant,
    [string]$EnvironmentId,
    [string]$EnvironmentUrl,
    [string]$SolutionUniqueName,
    [string]$DisplayName,
    [string]$SchemaName,
    [string]$BotId
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_mcs-common.ps1')
$pac = Assert-PacCli

if ($Tenant) {
    $active = (& $pac auth list) 2>$null
    if (-not ($active -match $Tenant)) {
        Write-Host "A browser sign-in will open — sign in as an admin of tenant $Tenant." -ForegroundColor Yellow
        & $pac auth create --name "mcs-target" --tenant $Tenant | Out-Null
    }
}

if (-not $EnvironmentUrl) {
    if (-not $EnvironmentId) { throw "Provide -EnvironmentUrl or -EnvironmentId." }
    $row = (& $pac env list) 2>&1 | Select-String -SimpleMatch $EnvironmentId
    if ($row -and $row.Line -match 'https://\S+') { $EnvironmentUrl = $matches[0].TrimEnd('/') + '/' }
    else { throw "Environment $EnvironmentId not found by 'pac env list'." }
}

# Auto-discover the bot GUID from the display name / schema name when -BotId was not supplied.
if (-not $BotId -and ($DisplayName -or $SchemaName)) {
    $BotId = Get-McsBotId -OrgUrl $EnvironmentUrl -DisplayName $DisplayName -SchemaName $SchemaName
    if ($BotId) { Write-Host "  Resolved bot id for '$DisplayName': $BotId" -ForegroundColor DarkGray }
    else { Write-Host "  Could not auto-resolve the bot id (is az logged into the target tenant?). The agent record won't be deleted unless you pass -BotId." -ForegroundColor Yellow }
}

# 1) Delete the agent (bot) record if the id is known (supplied or auto-discovered).
if ($BotId) {
    if ($PSCmdlet.ShouldProcess("$BotId in $EnvironmentUrl", "delete Copilot Studio agent")) {
        Write-Host "  Deleting agent (bot) $BotId ..." -ForegroundColor Cyan
        & $pac copilot-studio delete-copilot-agent --bot-id $BotId --environment $EnvironmentUrl
    }
}
else {
    Write-Host "  No bot id (supplied or discovered): the agent record is not auto-deleted. Pass -DisplayName (with az logged into the target tenant) or -BotId <guid> (from the Copilot Studio URL '.../bots/<guid>'), or delete it in the portal (Settings -> Delete agent)." -ForegroundColor Yellow
}

# 2) Delete the solution container.
if ($SolutionUniqueName) {
    if ($PSCmdlet.ShouldProcess("$SolutionUniqueName in $EnvironmentUrl", "delete solution")) {
        Write-Host "  Deleting solution '$SolutionUniqueName' ..." -ForegroundColor Cyan
        & $pac solution delete --solution-name $SolutionUniqueName --environment $EnvironmentUrl
        Write-Host "  Solution '$SolutionUniqueName' deleted." -ForegroundColor Green
    }
}
else {
    Write-Host "  No -SolutionUniqueName supplied: skipping solution delete. List with 'pac solution list --environment $EnvironmentUrl'." -ForegroundColor Yellow
}
