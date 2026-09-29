#requires -Version 7.0
<#
.SYNOPSIS
  Applies the localized AI-teammate (Digital Worker) manifest texts of an agent folder (manifest.overrides.json)
  to manifest\manifest.json after validating them against the iron rules; -Zip rebuilds manifest\manifest.zip.
.DESCRIPTION
  manifest.overrides.json: { "name": { "short", "full" }, "description": { "short", "full" }, "developer": { "name" } }.
  Limits (references/text-limits.json): name.short <= 30, name.full <= 100, description.short <= 80,
  description.full <= 4000, developer.name <= 32. Nothing is written when a text breaks a limit.
.EXAMPLE
  pwsh -File .\Set-DwManifestTexts.ps1 -AgentDir generated\contoso\Records-Colleague -Zip
#>
[CmdletBinding(PositionalBinding = $false)]
param([Parameter(Mandatory)][string]$AgentDir, [switch]$Zip)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Test-A365Names.ps1')
$ov = Join-Path $AgentDir 'manifest.overrides.json'
$mf = Join-Path $AgentDir 'manifest\manifest.json'
if (-not (Test-Path -LiteralPath $ov)) { throw "No manifest.overrides.json in $AgentDir." }
if (-not (Test-Path -LiteralPath $mf)) { throw "No manifest\manifest.json in $AgentDir." }
$o = Get-Content -LiteralPath $ov -Raw -Encoding utf8 | ConvertFrom-Json
$bad = @(Test-TeamsManifestText -NameShort $o.name.short -NameFull $o.name.full -DescriptionShort $o.description.short -DescriptionFull $o.description.full -DeveloperName $o.developer.name | Where-Object level -eq 'error')
if ($bad) { $bad | ForEach-Object { Write-Host "  $($_.field) $($_.message)" -ForegroundColor Red }; throw 'Manifest texts break the iron rules: nothing written.' }
$m = Get-Content -LiteralPath $mf -Raw -Encoding utf8 | ConvertFrom-Json
$m.name.short = $o.name.short; $m.name.full = $o.name.full
$m.description.short = $o.description.short; $m.description.full = $o.description.full
if ($o.developer.name) { $m.developer.name = $o.developer.name }
$m | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $mf -Encoding utf8
Write-Host "Manifest texts applied: '$($o.name.short)' / '$($o.description.short)' ($($o.description.short.Length)/80)" -ForegroundColor Green
if ($Zip) {
    $zipPath = Join-Path $AgentDir 'manifest\manifest.zip'
    $files = Get-ChildItem -LiteralPath (Join-Path $AgentDir 'manifest') -File | Where-Object { $_.Extension -in '.json', '.png' }
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -LiteralPath $files.FullName -DestinationPath $zipPath
    Write-Host "Rebuilt $zipPath ($($files.Count) files). Upload it again in the Microsoft 365 admin center (Choose file again: the old selection is cached)." -ForegroundColor Green
}
