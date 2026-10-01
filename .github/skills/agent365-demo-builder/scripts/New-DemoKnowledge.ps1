#requires -Version 7.0
<#
.SYNOPSIS
  Generates the fictional knowledge documents of the demo in the chosen language (docx, pdf, personal xlsx) into
  generated/<prefix>/demo/knowledge/out/<SharePoint folder>/<file>, from the demo pack locale, and the packages of the
  Agent Builder custom skills of the pack into generated/<prefix>/demo/skills/<name>.zip.
.DESCRIPTION
  Pure local step (no tenant call). Python packages: py/requirements.txt (python-docx, fpdf2, openpyxl); with
  -InstallRequirements they are installed with pip for the current user when missing.
.EXAMPLE
  pwsh -File .\New-DemoKnowledge.ps1 -Prefix cts2 -InstallRequirements
#>
[CmdletBinding(PositionalBinding = $false)]
param([Parameter(Mandatory)][string]$Prefix, [switch]$InstallRequirements)
. (Join-Path $PSScriptRoot '_demo-common.ps1')
$cfg = Read-DemoConfig $Prefix
$pack = Get-DemoPack $cfg.pack
$L = Get-DemoLocale -Locale $cfg.locale -Pack $cfg.pack
$py = Join-Path $PSScriptRoot 'py'
python -c "import docx, fpdf, openpyxl" 2>$null
if ($LASTEXITCODE -ne 0) {
    if (-not $InstallRequirements) { throw "Missing Python packages: run again with -InstallRequirements (installs $py\requirements.txt for the current user)." }
    python -m pip install --user --quiet --disable-pip-version-check -r (Join-Path $py 'requirements.txt')
    if ($LASTEXITCODE -ne 0) { throw 'pip install failed.' }
}
$work = Join-Path (Get-DemoLabDir $Prefix) 'knowledge'
$out = Join-Path $work 'out'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
New-Item -ItemType Directory -Force -Path $out | Out-Null
# Operator slots (security-test texts, never shipped in the repo): generated/<prefix>/demo/operator-slots.json
# { "<locale>": { "slot-1": "..." } } - see demo-packs/<pack>/OPERATOR-SLOTS.md. Values are never printed.
$slotFile = Join-Path (Get-DemoLabDir $Prefix) 'operator-slots.json'
$slots = @{}
if (Test-Path -LiteralPath $slotFile) {
    $all = Get-Content -LiteralPath $slotFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    if ($all.Contains($cfg.locale)) { foreach ($k in $all[$cfg.locale].Keys) { if ($all[$cfg.locale][$k]) { $slots[$k] = $all[$cfg.locale][$k] } } }
}
$filled = @($pack.operatorSlots | Where-Object { $_.kind -eq 'knowledgeText' -and $slots.ContainsKey($_.id) }).Count
Write-Host "Operator knowledge slots filled for '$($cfg.locale)': $filled of $(@($pack.operatorSlots | Where-Object { $_.kind -eq 'knowledgeText' }).Count) ($slotFile)"
$kin = [ordered]@{ org = $L.org; folders = $L.knowledge.folders; documents = $L.knowledge.documents; personal = $L.knowledge.personal; packDocuments = $pack.knowledge.documents; slots = $slots }
$inPath = Join-Path $work 'knowledge-input.json'
$kin | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $inPath -Encoding utf8
python (Join-Path $py 'build_knowledge.py') --input $inPath --out $out
if ($LASTEXITCODE -ne 0) { throw 'Knowledge generation failed.' }
Remove-Item -LiteralPath $inPath -Force   # it may contain operator slots: do not leave a second copy around
Write-DemoLog $Prefix "Knowledge generated ($($cfg.locale)): $out"

# Agent Builder custom skills (preview for Frontier tenants): one zip per skill with SKILL.md at the root (frontmatter
# name + description, then the instructions), uploaded by the agent's creator (Agent Builder card).
$skillDir = Join-Path (Get-DemoLabDir $Prefix) 'skills'
foreach ($a in @($pack.agents | Where-Object { $_.customSkill })) {
    $s = $L.skills[[string]$a.customSkill]
    if (-not $s) { throw "Locale '$($cfg.locale)' has no skills.$($a.customSkill) (agent $($a.key))." }
    $d = Join-Path $skillDir $s.name
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    $md = @('---', "name: $($s.name)", "description: $($s.description)", '---', '', [string]$s.body) -join "`n"
    [System.IO.File]::WriteAllText((Join-Path $d 'SKILL.md'), $md + "`n", [System.Text.UTF8Encoding]::new($false))
    $zip = Join-Path $skillDir "$($s.name).zip"
    Compress-Archive -Path (Join-Path $d 'SKILL.md') -DestinationPath $zip -Force
    Write-DemoLog $Prefix "Custom skill package for $($a.key): $zip"
}
Write-Host "Next: Publish-DemoKnowledge.ps1 -Prefix $Prefix (SharePoint site of the site group); the personal file goes to the program lead's OneDrive (manual step, see the cards)." -ForegroundColor Cyan
