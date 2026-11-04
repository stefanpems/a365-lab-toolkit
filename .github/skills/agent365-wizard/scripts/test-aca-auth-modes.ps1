#requires -Version 7.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'modules\_common.ps1')
. (Join-Path $PSScriptRoot 'modules\scaffold.tools.ps1')
. (Join-Path $PSScriptRoot 'modules\scaffold.aca.ps1')
$directory = Join-Path ([IO.Path]::GetTempPath()) ('a365-authmode-' + [guid]::NewGuid().ToString('N'))
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
$passed = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
    Write-Host "PASS: $Message"
}
try {
    $plan = @{
        solution = @{
            prefix = 'fixture'; tenantId = '11111111-1111-1111-1111-111111111111'
            subscriptionId = '22222222-2222-2222-2222-222222222222'; region = 'swedencentral'
            namingMode = 'custom'; resourceGroupStrategy = 'isolated'
            azureOpenAI = @{ mode = 'reuse-existing'; account = 'fixtureaoai'; existingResourceGroup = 'fixture-model-rg'; deployment = 'gpt-4.1-mini' }
            observability = @{ appInsights = @{ mode = 'none' } }
        }
        agents = @(); ui = @{ mode = 'none' }
    }
    foreach ($namingMode in 'custom', 'default') {
        $plan.solution.namingMode = $namingMode
        foreach ($type in 'ACA-OBO', 'ACA-S2S', 'ACA-DW') {
            $nextCommands = [Collections.Generic.List[string]]::new()
            $agent = @{
                name = "fixture-$type"; type = $type; resourceGroup = "fixture-$type-rg"; tools = @()
                displayNames = @{ identity = "Fixture $type Identity"; blueprint = "Fixture $type Blueprint" }
            }
            $destination = Join-Path $directory "$namingMode-$type"
            New-Item -ItemType Directory -Force -Path $destination | Out-Null
            Invoke-ScaffoldAcaAgent $agent @{ deploy = 'deploy.ps1' } $destination
            $config = Get-Content -LiteralPath (Join-Path $destination 'a365.config.json') -Raw | ConvertFrom-Json
            Assert ($config.useBlueprint -eq $true -and $config.aiTeammate -eq ($type -eq 'ACA-DW')) "$namingMode $type retains its intended blueprint/DW mode."
            $setup = @($nextCommands | Where-Object { $_ -match 'a365 setup all' }) -join "`n"
            if ($type -eq 'ACA-DW') {
                Assert (-not $config.PSObject.Properties['authMode'] -and $setup -match '--aiteammate' -and $setup -notmatch '--authmode') "$namingMode DW does not receive a non-DW authentication flag."
            }
            else {
                $expected = if ($type -eq 'ACA-S2S') { 's2s' } else { 'obo' }
                Assert ($config.authMode -eq $expected) "$namingMode $type persists the exact authentication mode."
                Assert ($setup -match "--authmode $expected" -and $setup -notmatch '--aiteammate') "$namingMode $type emits the exact setup flag even when agent-name bootstrap ignores config."
            }
        }
    }
    Write-Host "$passed ACA authentication-mode checks passed."
}
finally {
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}
