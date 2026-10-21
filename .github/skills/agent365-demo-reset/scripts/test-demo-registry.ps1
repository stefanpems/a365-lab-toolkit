#requires -Version 7.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\agent365-demo-builder\scripts\_demo-common.ps1')
. (Join-Path $PSScriptRoot '_demo-registry.ps1')
$repoRoot = $script:DemoRepoRoot
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("a365-registry-resolution-" + [guid]::NewGuid().ToString('N'))
$script:DemoRepoRoot = $tempRoot
$passed = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
    Write-Host "PASS: $Message"
}
$script:FixturePackages = @()
$script:FixtureDetails = @{}
$script:ListReads = 0
function Get-DemoPackageList($Config) { $script:ListReads++; return $script:FixturePackages }
function Get-DemoPackageDetail($Config, [string]$Id) { return $script:FixtureDetails[$Id] }
function Set-Fixture([object[]]$Packages) {
    $script:FixturePackages = $Packages
    $script:FixtureDetails = @{}
    $script:ListReads = 0
    foreach ($package in $Packages) { $script:FixtureDetails[$package.id] = $package }
}
function New-State([bool]$Legacy = $false) {
    @{ prefix = 'fixture'; agentResolution = @{ version = 1; legacyAliases = $Legacy }; agents = @{} }
}
$cfg = @{ prefix = 'fixture' }
$locale = @{ agents = @{ sample = @{ codeName = 'Sample-Agent'; displayName = 'Sample Agent'
    aliases = @{ registry = @('Sample-Agent Agent', 'Old Sample Agent') } } } }
$agent = @{ key = 'sample'; platform = 'code'; variant = 'ACA-OBO' }
$legacy = [pscustomobject]@{ id = 'legacy'; displayName = 'Sample-Agent Agent'; type = 'shared' }
$custom = [pscustomobject]@{ id = 'custom'; displayName = 'Sample Agent'; type = 'shared' }
$published = [pscustomobject]@{ id = 'published'; displayName = 'Sample Agent'; type = 'published' }
try {
    $state = New-State
    Set-Fixture @($legacy)
    $result = Get-DemoAgentPackages $cfg $locale $state $agent
    Assert ($result.all.Count -eq 0) 'new labs never construct or accept a conventional technical name'
    $state = New-State $true
    $result = Get-DemoAgentPackages $cfg $locale $state $agent
    Assert ($result.shared.id -eq 'legacy') 'an existing lab accepts an explicitly configured compatibility alias'
    Assert ((Read-DemoLabState fixture).agents.sample.packages -contains 'legacy') 'a successful compatibility fallback immediately persists its id'
    $state = New-State $true
    Set-Fixture @($legacy, $custom)
    $result = Get-DemoAgentPackages $cfg $locale $state $agent
    Assert ($result.shared.id -eq 'custom' -and $result.all.Count -eq 1) 'the exact configured name takes precedence over legacy aliases'
    Assert ((Read-DemoLabState fixture).agents.sample.titleId -eq 'custom') 'the verified Agent Builder or registry title id is stored explicitly'
    $renamed = [pscustomobject]@{ id = 'custom'; displayName = 'Renamed remotely'; type = 'shared' }
    Set-Fixture @($renamed, $legacy)
    $result = Get-DemoAgentPackages $cfg $locale $state $agent
    Assert ($result.shared.id -eq 'custom' -and $script:ListReads -eq 0) 'known package ids remain authoritative after a remote rename'
    $state.agents.sample.packages = @('deleted')
    Set-Fixture @($custom)
    $result = Get-DemoAgentPackages $cfg $locale $state $agent
    Assert ($result.shared.id -eq 'custom' -and (Read-DemoLabState fixture).agents.sample.packages -contains 'custom') 'a stale package id is replaced by a successful exact fallback'
    $state = New-State
    Set-Fixture @($custom, $published)
    $agent.platform = 'copilotStudio'; $agent.variant = 'MCS-NH'
    $result = Get-DemoAgentPackages $cfg $locale $state $agent
    Assert ($result.shared.id -eq 'custom' -and $result.published.id -eq 'published' -and $result.all.Count -eq 2) 'shared and published packages retain their separate roles'
    $saved = Read-DemoLabState fixture
    Assert ($saved.agents.sample.titleId -eq 'custom' -and $saved.agents.sample.publishedTitleId -eq 'published') 'both shared and published title ids persist'
    $state.agents.sample.packages = @('custom', 'deleted-published')
    $result = Get-DemoAgentPackages $cfg $locale $state $agent
    Assert ($result.all.Count -eq 2 -and $result.published.id -eq 'published') 'one valid recorded id does not hide a stale second package id'
    $state = New-State
    Set-Fixture @($custom, [pscustomobject]@{ id = 'duplicate'; displayName = 'Sample Agent'; type = 'shared' })
    $caught = ''
    try { Get-DemoAgentPackages $cfg $locale $state $agent | Out-Null } catch { $caught = $_.Exception.Message }
    Assert ($caught -match 'ambiguous') 'duplicate registry roles fail instead of choosing the newest or first object'
    $state = New-State
    Set-Fixture @([pscustomobject]@{ id = 'other'; displayName = 'Sample Agent Extra'; type = 'shared' })
    $result = Get-DemoAgentPackages $cfg $locale $state $agent
    Assert ($result.all.Count -eq 0 -and -not $result.shared) 'prefix and substring matches are never accepted'
    Set-Fixture @()
    $result = Get-DemoAgentPackages $cfg $locale $state $agent
    Assert ($result.all.Count -eq 0 -and -not $result.published) 'an absent catalog returns no invented package'
    Write-Host "Passed $passed, failed 0"
}
finally {
    $script:DemoRepoRoot = $repoRoot
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
