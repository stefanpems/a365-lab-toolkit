#requires -Version 5.1
<#
.SYNOPSIS
  Verify that every relative Markdown link and local file reference in the repo resolves.
.DESCRIPTION
  Scans tracked *.md files (excluding generated/, .git/, node_modules/, .venv/) and, for each
  Markdown link of the form ](relative/path[#anchor]), asserts the target file exists on disk.
  External links (http/https/mailto), pure anchors (#...) and template placeholders (<...>, {{...}})
  are skipped. This guards the dense cross-reference web (docs <-> skills <-> sample code) so a
  migration never silently breaks a reference. Read-only. Exit code 1 if any link is broken.
.EXAMPLE
  pwsh -File .\check-links.ps1
#>
[CmdletBinding()]
param([string]$RepoRoot)
$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path }

$skipDirs = @('\generated\', '\.git\', '\node_modules\', '\.venv\', '\__pycache__\',
    '\aca\', '\foundry-hosted\', '\foundry-declarative\')   # vendored sample READMEs: upstream boilerplate, out of the migration doc-web
$mdFiles = Get-ChildItem $RepoRoot -Recurse -File -Filter *.md |
    Where-Object { $p = $_.FullName; -not ($skipDirs | Where-Object { $p -like "*$_*" }) }

$linkRx = [regex]']\((?<t>[^)]+)\)'
$broken = New-Object System.Collections.Generic.List[string]
$checked = 0
foreach ($f in $mdFiles) {
    $text = Get-Content -LiteralPath $f.FullName -Raw
    foreach ($mm in $linkRx.Matches($text)) {
        $t = $mm.Groups['t'].Value.Trim()
        if ($t -match '^(https?:|mailto:|#)') { continue }         # external / anchor-only
        if ($t -match '^[<{]' ) { continue }                        # placeholder
        $path = ($t -split '#', 2)[0]                               # strip anchor
        if (-not $path) { continue }
        if ($path -match '^[a-z]+://') { continue }
        if ($path -match '[|<>{}]') { continue }                     # skip template/placeholder targets
        $resolved = Join-Path $f.DirectoryName ($path.Replace('/', '\'))
        $checked++
        if (-not (Test-Path -LiteralPath $resolved)) {
            $rel = $f.FullName.Substring($RepoRoot.Length + 1) -replace '\\', '/'
            $broken.Add(($rel + '  ->  ' + $t))
        }
    }
}

Write-Host "Checked $checked local Markdown links across $($mdFiles.Count) files." -ForegroundColor Cyan
if ($broken.Count -gt 0) {
    Write-Host "BROKEN links ($($broken.Count)):" -ForegroundColor Red
    $broken | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "All local Markdown links resolve." -ForegroundColor Green
