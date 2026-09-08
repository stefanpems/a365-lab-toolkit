#requires -Version 7.0
<#
.SYNOPSIS
  Discover and delete local `generated/` folders associated with cleaned-up lab resources.

.DESCRIPTION
  Companion to the cloud cleanup: after Remove-CleanupResources.ps1 deletes the Azure/Entra resources,
  this removes the matching local scaffolding folders under the generated root, with all their content.

  Matching is by the presence of an identifier string in the folder NAME (case-insensitive substring) —
  normally just the solution PREFIX, which every per-run folder name begins with. The scan is RECURSIVE
  and returns only the OUTERMOST match on each branch: the scaffolder groups a whole run under a single
  per-run root `generated/<prefix>/` (the agents, `<prefix>-ui` and `<prefix>-mcp` live inside it), so
  that root is the one and only match for the prefix and a single confirmation removes the WHOLE branch
  (every sub-folder cascades with it). The cleanup audit folder (generated/cleanup/**) is always
  excluded, and nothing outside the generated root is ever touched.

  Read-only with -List (emit candidate folders as JSON for the wizard's checkbox review); otherwise it
  deletes the confirmed selection. Every action is appended to the persistent deletion log.

.PARAMETER Identifiers
  One or more substrings identifying the run — normally just the solution PREFIX (e.g. `a1730`). Every
  per-run folder name begins with it, so the prefix alone selects the whole `generated/<prefix>/` root
  (agents + web UI + custom MCP) as a single candidate. Required for -List and for identifier-based deletion.

.PARAMETER GeneratedRoot
  The generated/ root to scan. Defaults to `generated` under the current location.

.PARAMETER List
  Read-only: emit the candidate folders as JSON (to -OutFile when supplied) and delete nothing.

.PARAMETER OutFile
  Where -List writes the JSON array.

.PARAMETER SelectionPath
  JSON array of confirmed folders to delete (objects with a `path`/`relativePath`, or plain strings),
  as produced by -List and pruned in the review.

.PARAMETER Path
  Explicit folder path(s) to delete (alternative to -SelectionPath).

.PARAMETER LogPath
  Persistent deletion log to append to. Defaults next to -OutFile / -SelectionPath.

.PARAMETER WhatIf
  Show what would be deleted (WHATIF log lines) without deleting.

.PARAMETER Force
  Skip the final "type DELETE" confirmation (for wizard-driven runs confirmed in chat).

.EXAMPLE
  # Discover:
  pwsh -File .\Remove-GeneratedFolders.ps1 -List -Identifiers a1730,myMcp -OutFile .\folders.json
  # Delete the confirmed subset:
  pwsh -File .\Remove-GeneratedFolders.ps1 -SelectionPath .\folders.selection.json -Force
#>
[CmdletBinding()]
param(
    [string[]]$Identifiers,
    [string]$GeneratedRoot = 'generated',
    [switch]$List,
    [string]$OutFile,
    [string]$SelectionPath,
    [string[]]$Path,
    [string]$LogPath,
    [switch]$WhatIf,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Test-Path -LiteralPath $GeneratedRoot)) { throw "Generated root not found: $GeneratedRoot" }
$rootFull = (Resolve-Path -LiteralPath $GeneratedRoot).Path.TrimEnd('\', '/')
$sep = [IO.Path]::DirectorySeparatorChar
# The cleanup audit trail lives here and must never be a deletion candidate.
$auditRoot = (Join-Path $rootFull 'cleanup')

if (-not $LogPath) {
    $anchor = if ($OutFile) { $OutFile } elseif ($SelectionPath) { $SelectionPath } else { Join-Path $rootFull 'cleanup' }
    $dir = if (Test-Path -LiteralPath $anchor -PathType Container) { $anchor } else { Split-Path -Parent $anchor }
    if (-not $dir) { $dir = $rootFull }
    $LogPath = Join-Path $dir 'deletion.log'
}
function Write-Log {
    param([string]$Status, [string]$Message)
    $line = "[{0}] [{1}] {2}" -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $Status, $Message
    $ld = Split-Path -Parent $LogPath
    if ($ld -and -not (Test-Path -LiteralPath $ld)) { New-Item -ItemType Directory -Force -Path $ld | Out-Null }
    Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
    $color = switch ($Status) { 'OK' { 'Green' } 'ERROR' { 'Red' } 'WHATIF' { 'Yellow' } 'SKIP' { 'DarkYellow' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
}

# Is $candidate inside (or equal to) $parent?
function Test-IsUnder {
    param([string]$Candidate, [string]$Parent)
    $c = $Candidate.TrimEnd('\', '/'); $p = $Parent.TrimEnd('\', '/')
    if ($c -eq $p) { return $true }
    return $c.StartsWith($p + $sep, [System.StringComparison]::OrdinalIgnoreCase)
}

# Recursively find the OUTERMOST generated/ folders whose name contains any identifier.
function Get-CandidateFolders {
    param([string[]]$Ids)
    $ids = @($Ids | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
    if ($ids.Count -eq 0) { return @() }
    $all = Get-ChildItem -LiteralPath $rootFull -Recurse -Directory -Force -ErrorAction SilentlyContinue
    $matched = New-Object System.Collections.Generic.List[string]
    foreach ($d in $all) {
        if (Test-IsUnder $d.FullName $auditRoot) { continue }   # never the audit trail
        foreach ($id in $ids) {
            if ($d.Name.IndexOf($id, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $matched.Add($d.FullName); break }
        }
    }
    $paths = @($matched | Sort-Object -Unique)
    $top = New-Object System.Collections.Generic.List[string]
    foreach ($p in $paths) {
        $inside = $false
        foreach ($t in $top) { if (Test-IsUnder $p $t) { $inside = $true; break } }
        if (-not $inside) { $top.Add($p) }
    }
    return @($top)
}

# ---------------------------------------------------------------------------
# List mode: read-only discovery for the wizard's checkbox review.
# ---------------------------------------------------------------------------
if ($List) {
    $cands = Get-CandidateFolders -Ids $Identifiers
    $rows = @($cands | ForEach-Object {
            $rel = $_.Substring($rootFull.Length).TrimStart('\', '/')
            $count = @(Get-ChildItem -LiteralPath $_ -Recurse -Force -File -ErrorAction SilentlyContinue).Count
            [pscustomobject]@{ path = $_; relativePath = $rel; fileCount = $count }
        })
    $json = if ($rows.Count -eq 1) { '[' + ($rows | ConvertTo-Json -Depth 5) + ']' } elseif ($rows.Count -eq 0) { '[]' } else { $rows | ConvertTo-Json -Depth 5 }
    Write-Host "Found $($rows.Count) candidate folder(s) under $rootFull for [$($Identifiers -join ', ')]:" -ForegroundColor Green
    $rows | ForEach-Object { Write-Host ("  {0}  ({1} file(s))" -f $_.relativePath, $_.fileCount) -ForegroundColor Gray }
    if ($OutFile) {
        $od = Split-Path -Parent $OutFile
        if ($od -and -not (Test-Path -LiteralPath $od)) { New-Item -ItemType Directory -Force -Path $od | Out-Null }
        Set-Content -LiteralPath $OutFile -Value $json -Encoding utf8
        Write-Host "Wrote candidates to $OutFile" -ForegroundColor Cyan
    }
    else { $json }
    return
}

# ---------------------------------------------------------------------------
# Deletion mode: resolve the target folders.
# ---------------------------------------------------------------------------
$targets = @()
if ($SelectionPath) {
    if (-not (Test-Path -LiteralPath $SelectionPath)) { throw "Selection file not found: $SelectionPath" }
    $sel = Get-Content -LiteralPath $SelectionPath -Raw | ConvertFrom-Json
    $targets = @($sel | ForEach-Object { if ($_ -is [string]) { $_ } elseif ($_.path) { $_.path } elseif ($_.relativePath) { Join-Path $rootFull $_.relativePath } })
}
elseif ($Path) { $targets = @($Path) }
else { $targets = @(Get-CandidateFolders -Ids $Identifiers) }

$targets = @($targets | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique)
if ($targets.Count -eq 0) { Write-Host "No local folders to delete." -ForegroundColor Yellow; return }

if (-not $WhatIf -and -not $Force) {
    Write-Host ""
    Write-Host "About to permanently delete $($targets.Count) local folder(s) and all their content:" -ForegroundColor Red
    $targets | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    $answer = Read-Host "Type DELETE to proceed (anything else cancels)"
    if ($answer -ne 'DELETE') { Write-Log 'INFO' 'Local folder deletion cancelled at confirmation.'; return }
}

Write-Log 'INFO' "=== Local generated/ folder cleanup: $($targets.Count) target(s)$(if($WhatIf){' [WHATIF]'}) ==="
foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t)) { Write-Log 'SKIP' "folder not found: $t"; continue }
    $full = (Resolve-Path -LiteralPath $t).Path.TrimEnd('\', '/')
    # Safety: never delete the generated root itself, the audit trail, or anything outside the root.
    if (-not (Test-IsUnder $full $rootFull) -or $full -eq $rootFull) { Write-Log 'ERROR' "refusing to delete outside the generated root: $full"; continue }
    if (Test-IsUnder $full $auditRoot) { Write-Log 'SKIP' "refusing to delete the cleanup audit folder: $full"; continue }
    if ($WhatIf) { Write-Log 'WHATIF' "would remove local folder $full"; continue }
    try { Remove-Item -LiteralPath $full -Recurse -Force; Write-Log 'OK' "removed local folder $full" }
    catch { Write-Log 'ERROR' "failed to remove $full`: $($_.Exception.Message)" }
}
Write-Log 'INFO' "=== Local generated/ folder cleanup finished ==="
