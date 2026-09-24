<#
.SYNOPSIS
  Step 1 - Downloads the AI-agent monitoring content of davidalonsod/Dalonso-Security-Repo, applies the tuning
  fixes (patch_packs.py) and regenerates the ARM templates of the Copilot Studio and Foundry packs.
.EXAMPLE
  .\01-Prepare-Packs.ps1
  .\01-Prepare-Packs.ps1 -RepoPath C:\temp\dalonso -Ref 913b658d5dc9fc2d8d137b5684d681c8815016be
.NOTES
  Default clone path: %LOCALAPPDATA%\Dalonso-Security-Repo. Requires git, python 3 and PowerShell 7.
#>
param(
    [string] $RepoPath,
    [string] $Ref = 'main',
    [switch] $SkipPatch,
    [switch] $NoAgent365MailMcp
)
. (Join-Path $PSScriptRoot '_common.ps1')
if (-not $RepoPath) { $RepoPath = $DefaultRepoPath }

if (-not (Test-Path (Join-Path $RepoPath '.git'))) {
    Write-Host "== Cloning (sparse) into $RepoPath"
    git clone --quiet --filter=blob:none --sparse --no-checkout https://github.com/davidalonsod/Dalonso-Security-Repo.git $RepoPath
    if ($LASTEXITCODE) { throw 'git clone failed' }
    git -C $RepoPath config core.longpaths true
    git -C $RepoPath sparse-checkout set 'Use Cases Threat Hunting/Monitoring AI Agents' 'Workbooks/AI-Agents-Monitoring'
}
git -C $RepoPath fetch --quiet origin
$target = if (git -C $RepoPath rev-parse -q --verify "origin/$Ref") { "origin/$Ref" } else { $Ref }
# --force discards any previous patch, so the fixes are always re-applied on a clean upstream copy.
git -C $RepoPath checkout --quiet --force --detach $target
if ($LASTEXITCODE) { throw "git checkout $target failed" }
Write-Host ("== Upstream commit: {0}" -f (git -C $RepoPath log -1 --format='%h %cd' --date=short))

$packs = Get-PacksRoot $RepoPath
if (-not $SkipPatch) {
    Write-Host '== Applying tuning fixes'
    $a = @((Join-Path $PSScriptRoot 'patch_packs.py'), $packs)
    if ($NoAgent365MailMcp) { $a += '--no-agent365-mail-mcp' }
    $env:PYTHONUTF8 = '1'
    python @a
    if ($LASTEXITCODE) { throw 'patch_packs.py failed' }
}

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host '== Installing module powershell-yaml (CurrentUser)'
    Install-Module powershell-yaml -Scope CurrentUser -Force
}
Write-Host '== Regenerating ARM templates'
& (Join-Path $packs 'CopilotStudio\Deploy\New-CopilotStudioArmTemplate.ps1') | Out-Null
& (Join-Path $packs 'Foundry_Agents\Deploy\New-FoundryArmTemplate.ps1') | Out-Null
foreach ($p in 'CopilotStudio', 'Foundry_Agents') {
    $t = Get-Content (Join-Path $packs "$p\Deploy\azuredeploy.json") -Raw | ConvertFrom-Json
    $types = $t.resources | Group-Object { ($_.type -split '/')[-1] } | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Host ("   {0,-15} {1}" -f $p, ($types -join ', '))
}
Write-Host "Templates ready under: $packs"
