#requires -Version 7.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_demo-registry.ps1')
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
    foreach ($p in $Packages) { $script:FixtureDetails[$p.id] = $p }
}
$cfg = @{ prefix = 'fixture' }
$locale = @{ agents = @{ sample = @{ codeName = 'Sample-Agent'; displayName = 'Sample Agent'; identity = 'Sample Agent - Test' } } }
$agent = @{ key = 'sample'; platform = 'code'; variant = 'ACA-OBO' }
$state = @{ agents = @{} }
$legacy = [pscustomobject]@{ id = 'legacy'; displayName = 'Sample-Agent Agent'; type = 'shared'; createdDateTime = '2026-01-01T00:00:00Z' }
$custom = [pscustomobject]@{ id = 'custom'; displayName = 'Sample Agent'; type = 'shared'; createdDateTime = '2026-01-02T00:00:00Z' }
$identity = [pscustomobject]@{ id = 'identity'; displayName = 'Sample Agent - Test'; type = 'shared'; createdDateTime = '2026-01-03T00:00:00Z' }
Set-Fixture @($legacy)
$r = Get-DemoAgentPackages $cfg $locale $state $agent
Assert ($r.shared.id -eq 'legacy') 'legacy technical catalog name remains supported'
Set-Fixture @($custom)
$r = Get-DemoAgentPackages $cfg $locale $state $agent
Assert ($r.shared.id -eq 'custom') 'custom localized name resolves without the technical suffix'
Set-Fixture @($identity)
$locale.agents.sample.displayName = 'Sample Agent ' + [char]0x2013 + ' Test'
$r = Get-DemoAgentPackages $cfg $locale $state $agent
Assert ($r.shared.id -eq 'identity') 'configured identity name resolves a different localized dash'
$locale.agents.sample.displayName = 'Sample Agent'
Set-Fixture @($legacy, $custom)
$r = Get-DemoAgentPackages $cfg $locale $state $agent
Assert ($r.shared.id -eq 'legacy' -and $r.all.Count -eq 1) 'exact catalog name takes precedence over fallback aliases'
$state.agents.sample = @{ packages = @('custom') }
$r = Get-DemoAgentPackages $cfg $locale $state $agent
Assert ($r.shared.id -eq 'custom') 'recorded package id remains authoritative'
$script:ListReads = 0
$null = Get-DemoAgentPackages $cfg $locale $state $agent
Assert ($script:ListReads -eq 0) 'resolved recorded ids do not trigger name-based discovery'
$state.agents.sample.packages = @('deleted')
Set-Fixture @($custom)
$r = Get-DemoAgentPackages $cfg $locale $state $agent
Assert ($r.shared.id -eq 'custom') 'stale recorded ids fall back to exact names'
$published = [pscustomobject]@{ id = 'published'; displayName = 'Sample Agent'; type = 'published'; createdDateTime = '2026-01-04T00:00:00Z' }
$state.agents = @{}
Set-Fixture @($custom, $published)
$agent.platform = 'copilotStudio'; $agent.variant = 'MCS-NH'
$r = Get-DemoAgentPackages $cfg $locale $state $agent
Assert ($r.shared.id -eq 'custom' -and $r.published.id -eq 'published' -and $r.all.Count -eq 2) 'shared and published entries keep their distinct roles'
Set-Fixture @([pscustomobject]@{ id = 'other'; displayName = 'Sample Agent Extra'; type = 'shared' })
$r = Get-DemoAgentPackages $cfg $locale $state $agent
Assert ($r.all.Count -eq 0 -and -not $r.shared) 'prefix and substring matches are never accepted'
Set-Fixture @()
$r = Get-DemoAgentPackages $cfg $locale $state $agent
Assert ($r.all.Count -eq 0 -and -not $r.published) 'an absent catalog returns no invented package'
Write-Host "Passed $passed, failed 0"
