#requires -Version 7.0
<#
.SYNOPSIS
  Second gate of the Demo Cleaner: applies the exceptions chosen by the operator (elements NOT to delete), includes the
  elements kept by default that the operator wants deleted, keeps the dependents of what is kept, and, with -Confirm,
  records the confirmation that allows Invoke-DemoCleanup.ps1 -Apply to run. Changes nothing in the tenant.
.DESCRIPTION
  Specs use the indexes of the report: '3, 7-9, #12' and whole types 'type:User' (User, Group, Resource, Configuration,
  Component, Agent). The HTML "Copy exception list" button produces 'exclude: 3, 7-9'. Without -Confirm the effective
  selection is only previewed (and written to the report), so the agent can show what the closure added; such a call
  also withdraws an earlier confirmation, so -Apply never runs on a selection changed after it was confirmed. The dry
  run (Invoke-DemoCleanup.ps1 -WhatIf) works on the previewed selection.
.EXAMPLE
  pwsh -File .\Set-DemoCleanupSelection.ps1 -RunDir <run folder> -Exclude '3, 7-9' -Include '41'
.EXAMPLE
  pwsh -File .\Set-DemoCleanupSelection.ps1 -RunDir <run folder> -Exclude '3, 7-9' -ManualMode defer -Confirm
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)][string]$RunDir,
    [string]$Exclude = '',
    [string]$Include = '',
    [ValidateSet('pause', 'defer')][string]$ManualMode = 'pause',
    [switch]$Confirm,
    [switch]$AsJson
)
$ErrorActionPreference = 'Stop'
$builder = Join-Path $PSScriptRoot '..\..\agent365-demo-builder\scripts'
. (Join-Path $builder '_demo-common.ps1')
. (Join-Path $PSScriptRoot '_demo-cleaner.ps1')
$cp = Read-CleanupPlan $RunDir
if ($cp.mode -eq 'snapshot' -or $cp.phase -eq 'snapshot') { throw 'This run is a snapshot preview (no cloud reads): run a live discovery before choosing what to delete.' }
if ($cp.phase -notin 'review', 'confirmed') { throw "The selection can change only before the deletion starts (phase is '$($cp.phase)')." }
$prev = @([string]$cp.selection.excludeSpec, [string]$cp.selection.includeSpec, [string]$cp.manualMode)
$r = Set-CleanupSelection $cp $Exclude $Include
$cp['manualMode'] = $ManualMode
$cp['phase'] = 'review'
# A confirmation holds only for the call that gives it; a dry run only for the same selection.
$cp.selection.confirmedAt = $null
if (($prev -join '|') -ne (@($Exclude, $Include, $ManualMode) -join '|')) { $cp.selection.whatIfAt = $null }
if ($Confirm) {
    $cp.selection.confirmedAt = (Get-Date).ToString('o')
    $cp['phase'] = 'confirmed'
}
$null = Update-CleanupSummary $cp
$cp['summary'] = $null
Save-CleanupPlan $cp
$label = { param([int[]]$Indexes) if (-not $Indexes.Count) { return '-' }; (@($Indexes | ForEach-Object { $it = Get-CleanupItemByIndex $cp $_; "#$_ $($it.name)" }) -join '; ') }
$out = [ordered]@{
    toDelete = $r.toDelete; manualActions = $r.manual; manualMode = $ManualMode; confirmed = [bool]$Confirm
    excludedByOperator = @($r.excludedByUser); keptByDefault = @($r.keptByDefault); keptBecauseOfDependencies = @($r.keptByClosure)
    addedByThisCall = @($r.closureAdded); tenantId = $cp.context.tenantId; report = (Get-CleanupReportUri $cp.runDir)
}
if ($AsJson) { $out | ConvertTo-Json -Depth 6; return }
Write-Host ("Elements to delete: {0} (of which {1} manual portal actions, mode '{2}') in tenant {3}" -f $r.toDelete, $r.manual, $ManualMode, $cp.context.tenantId)
Write-Host "Kept at your request: $(& $label $r.excludedByUser)"
Write-Host "Kept by default:      $(& $label $r.keptByDefault)"
Write-Host "Kept because a prerequisite is kept: $(& $label $r.keptByClosure)"
Write-Host "Report: $($out.report)"
if ($Confirm) { Write-Host 'Selection CONFIRMED: Invoke-DemoCleanup.ps1 -RunDir <run> -Apply can start.' -ForegroundColor Yellow }
