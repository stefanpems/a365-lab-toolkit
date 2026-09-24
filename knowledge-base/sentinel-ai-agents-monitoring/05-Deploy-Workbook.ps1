<#
.SYNOPSIS
  Step 5 - Deploys the "AI Agents Monitoring" workbook to a Log Analytics workspace: the Microsoft Sentinel workspace
  and/or the workspace behind an Application Insights resource (no Sentinel needed for the latter).
.EXAMPLE
  # Sentinel workspace (shown under Sentinel > Workbooks)
  .\05-Deploy-Workbook.ps1 -TargetWorkspaceResourceId $sentinelWs -SentinelWorkspaceResourceId $sentinelWs
.EXAMPLE
  # Workspace behind an App Insights resource, workbook stored in the App Insights resource group
  .\05-Deploy-Workbook.ps1 -TargetWorkspaceResourceId $aiWs -ResourceGroup my-appinsights-rg `
      -DisplayName 'AI Agents Monitoring - Contoso agents' -SentinelWorkspaceResourceId $sentinelWs
#>
param(
    [Parameter(Mandatory)][string] $TargetWorkspaceResourceId,
    [string] $SentinelWorkspaceResourceId,
    [string] $ResourceGroup,
    [string] $Location,
    [string] $DisplayName = 'AI Agents Monitoring',
    [string[]] $Tag = @(),
    [string] $RepoPath,
    [switch] $WhatIf
)
. (Join-Path $PSScriptRoot '_common.ps1')
if (-not $RepoPath) { $RepoPath = $DefaultRepoPath }
$wb = Join-Path $RepoPath 'Workbooks\AI-Agents-Monitoring\AI-Agents-Monitoring-Workbook.workbook'
if (-not (Test-Path $wb)) { throw "Workbook not found: $wb (run 01-Prepare-Packs.ps1 first)" }

$a = @((Join-Path $PSScriptRoot 'deploy_workbook.py'), '--workbook', $wb, '--target-workspace', $TargetWorkspaceResourceId,
       '--display-name', $DisplayName)
if ($SentinelWorkspaceResourceId) { $a += '--sentinel-workspace', $SentinelWorkspaceResourceId }
if ($ResourceGroup) { $a += '--resource-group', $ResourceGroup }
if ($Location) { $a += '--location', $Location }
foreach ($t in $Tag) { $a += '--tag', $t }
if ($WhatIf) { $a += '--what-if' }
$env:PYTHONUTF8 = '1'
python @a
if ($LASTEXITCODE) { throw 'Workbook deployment failed' }
