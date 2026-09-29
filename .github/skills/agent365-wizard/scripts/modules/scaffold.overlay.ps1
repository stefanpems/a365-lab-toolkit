# Optional per-agent OVERLAY (plan field agents[].overlay = folder path, absolute or relative to the repo root).
# Its files are copied over the scaffolded agent: agent_overlay.py (+ helpers and data files; FD: knowledge/ for
# File search). The ACA and FD samples import agent_overlay ONLY when it is present (a role prompt placed before
# COMMON_MISSION, extra in-process tools, DW texts, FD extra tools), so a plain lab is unchanged. A Digital Worker
# overlay may carry manifest.overrides.json { name{short,full}, description{short,full}, developer{name} }: it is
# validated against the iron rules (references/text-limits.json) and applied with Set-DwManifestTexts.ps1.
# Written by the Demo Builder (generated/<prefix>/demo/overlays/<agent>/). Reads $repoRoot / $nextCommands.

function Resolve-OverlayPath {
    param($a)
    if (-not $a.PSObject.Properties['overlay'] -or -not $a.overlay) { return $null }
    $p = [string]$a.overlay
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $repoRoot $p }
    return $p
}

# Validation (called from the router's validation phase): returns error strings.
function Test-AgentOverlay {
    param($a)
    $errs = @()
    $p = Resolve-OverlayPath $a
    if (-not $p) { return $errs }
    if ($a.type -notmatch '^(ACA-(OBO|S2S|DW)|FD-(OBO|S2S))$') { return @("$($a.name): agents[].overlay is supported on ACA-OBO/S2S/DW and FD-OBO/S2S agents only (not $($a.type)).") }
    if (-not (Test-Path -LiteralPath (Join-Path $p 'agent_overlay.py'))) { $errs += "$($a.name): overlay folder '$p' has no agent_overlay.py." }
    $mo = Join-Path $p 'manifest.overrides.json'
    if (Test-Path -LiteralPath $mo) {
        if ($a.type -notlike '*-DW') { $errs += "$($a.name): manifest.overrides.json is only valid for a Digital Worker." }
        else {
            $m = Get-Content -LiteralPath $mo -Raw -Encoding utf8 | ConvertFrom-Json
            foreach ($v in @(Test-TeamsManifestText -NameShort $m.name.short -NameFull $m.name.full -DescriptionShort $m.description.short -DescriptionFull $m.description.full -DeveloperName $m.developer.name)) {
                if ($v.level -eq 'error') { $errs += "$($a.name): overlay $($v.field) $($v.message)" }
            }
        }
    }
    return $errs
}

function Invoke-ScaffoldOverlay {
    param($a, $dst)
    $p = Resolve-OverlayPath $a
    if (-not $p) { return }
    foreach ($item in Get-ChildItem -LiteralPath $p -Force) { Copy-Item -LiteralPath $item.FullName -Destination $dst -Recurse -Force }
    Write-Host "    overlay applied from $p" -ForegroundColor DarkCyan
    if (Test-Path -LiteralPath (Join-Path $dst 'manifest.overrides.json')) {
        $tool = Join-Path (Split-Path -Parent $PSScriptRoot) 'Set-DwManifestTexts.ps1'
        & $tool -AgentDir $dst | Out-Null
        $nextCommands.Add("#   ^ $($a.name) (overlay): 'a365 publish --aiteammate' may rewrite manifest\manifest.json. At its 'Open manifest in your default editor now? (Y/n)' answer n, then BEFORE pressing Enter at 'Press Enter when you have finished editing the manifest' run: pwsh -File `"$tool`" -AgentDir `"$dst`"   (re-applies + re-validates the localized name/description). If the zip was already built, run it with -Zip to rebuild manifest\manifest.zip.")
    }
}
