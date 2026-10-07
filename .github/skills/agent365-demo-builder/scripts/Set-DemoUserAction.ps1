#requires -Version 7.0
<#
.SYNOPSIS
  Adds or updates one row of the user-actions register of a demo lab (generated/<prefix>/demo/user-actions.json,
  rendered to USER-ACTIONS.md), or lists the register.
.DESCRIPTION
  The Demo Builder scripts register their own manual actions (Invoke-DemoPhase.ps1 manual steps, Test-DemoPrereqs.ps1,
  Set-DemoIdentities.ps1, Publish-DemoKnowledge.ps1, New-DemoMcpRegistration.ps1). The agent uses this script ONLY for
  the actions that no script knows (for example a package produced by the Lab Builder, a deferred agent test, a check
  found during the build), so that every row has the same format. Never edit USER-ACTIONS.md by hand.
  Rows are keyed: re-running with the same -Key updates the row (id, and status unless -Status is given, are kept).
.EXAMPLE
  pwsh -File .\Set-DemoUserAction.ps1 -Prefix cts2 -Key dw-manifest-upload -Action "Upload the AI-teammate package" -Where "admin center > Agents > Upload custom agent" -NeededBy D7
.EXAMPLE
  pwsh -File .\Set-DemoUserAction.ps1 -Prefix cts2 -Key dw-manifest-upload -Status DONE
.EXAMPLE
  pwsh -File .\Set-DemoUserAction.ps1 -Prefix cts2 -List
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)][string]$Prefix,
    [string]$Key,
    [string]$Action,
    [string]$Where,
    [string]$NeededBy,
    [switch]$Blocking,
    [switch]$NotBlocking,
    [ValidateSet('', 'TODO', 'DONE')][string]$Status = '',
    [string]$WebUiUrl,
    [switch]$List
)
. (Join-Path $PSScriptRoot '_demo-common.ps1')
if ($List) {
    $reg = Read-DemoUserActions $Prefix
    $reg.actions | ForEach-Object { [pscustomobject]@{ id = $_.id; status = $(if ($_.status -eq 'DONE') { 'DONE' } elseif ($_.blocking) { 'BLOCKING' } else { 'TODO' }); key = $_.key; action = $_.action; neededBy = $_.neededBy } } |
        Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    Write-Host "Register: $(Join-Path (Get-DemoLabDir $Prefix) 'USER-ACTIONS.md')"
    return
}
if (-not $Key) { throw '-Key is required (or use -List).' }
if ($Blocking -and $NotBlocking) { throw 'Use -Blocking or -NotBlocking, not both.' }
$p = @{ Prefix = $Prefix; Key = $Key }
foreach ($n in 'Action', 'Where', 'NeededBy', 'WebUiUrl') { if ($PSBoundParameters.ContainsKey($n)) { $p[$n] = Get-Variable -Name $n -ValueOnly } }
if ($Status) { $p['Status'] = $Status }
if ($Blocking) { $p['Blocking'] = $true } elseif ($NotBlocking) { $p['Blocking'] = $false }
$row = Set-DemoUserAction @p
Write-Host ("{0} [{1}{2}] {3}" -f $row.id, $row.status, $(if ($row.blocking -and $row.status -ne 'DONE') { ', BLOCKING' }), $row.action)
