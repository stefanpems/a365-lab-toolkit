#requires -Version 7.0
<#
.SYNOPSIS
  Offline unit test of the Demo Builder helpers that need no tenant: license bundles (Get-DemoSkuParts,
  Get-DemoPersonaLicenseRoles, Get-DemoRolePlans, Get-DemoLicenseAdds), the lab-private az profile (Use-DemoAzProfile,
  New-DemoConfig.ps1 -IsolatedAzProfile / -TeamsForAllPersonas / SKU persistence) and the reserved knowledge folder
  names of Test-DemoPack.ps1. Uses throwaway prefixes under generated/ that it deletes. Exit code 0 = all passed.
.EXAMPLE
  pwsh -File .\test-demo-helpers.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_demo-common.ps1')
$script:fail = 0; $script:pass = 0
function Assert([bool]$Cond, [string]$Name) { if ($Cond) { $script:pass++; Write-Host "  ok   $Name" } else { $script:fail++; Write-Host "  FAIL $Name" -ForegroundColor Red } }
function New-Sku([string]$Part, [string]$Id, [string[]]$Plans) { [pscustomobject]@{ skuPartNumber = $Part; skuId = $Id; servicePlans = @($Plans | ForEach-Object { [pscustomobject]@{ servicePlanName = $_; servicePlanId = "plan-$_" } }) } }
function Read-DemoLabConfigRaw([string]$Prefix) { Get-Content -LiteralPath (Join-Path (Get-DemoLabDir $Prefix) 'demo-config.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable }
$tmpPrefixes = @('zzhelp1', 'zzhelp2')
$saveCfgDir = $env:AZURE_CONFIG_DIR; $saveExtDir = $env:AZURE_EXTENSION_DIR
try {
    Write-Host 'License bundles'
    Assert ((Get-DemoSkuParts 'A') -join '|' -eq 'A') 'single SKU'
    Assert ((Get-DemoSkuParts ' A + B+C ') -join '|' -eq 'A|B|C') 'bundle split and trimmed'
    Assert (@(Get-DemoSkuParts '').Count -eq 0) 'empty value = no SKU'
    $p1 = [pscustomobject]@{ licenses = @('copilotUser', 'teams') }; $p2 = [pscustomobject]@{ licenses = @('copilotUser') }
    Assert ((Get-DemoPersonaLicenseRoles $p2 @{ teamsForAllPersonas = $false }) -join ',' -eq 'copilotUser') 'no Teams added by default'
    Assert ((Get-DemoPersonaLicenseRoles $p2 @{ teamsForAllPersonas = $true }) -join ',' -eq 'copilotUser,teams') 'teamsForAllPersonas adds Teams'
    Assert ((Get-DemoPersonaLicenseRoles $p1 @{ teamsForAllPersonas = $true }) -join ',' -eq 'copilotUser,teams') 'Teams never duplicated'
    $e5 = New-Sku 'E5NT' 'id-e5' @('EXCHANGE_S_ENTERPRISE', 'AAD_PREMIUM_P2')
    $cop = New-Sku 'COP' 'id-cop' @('M365_COPILOT_BUSINESS_CHAT')
    $fr = New-Sku 'FR' 'id-fr' @('AGENT_365', 'EXCHANGE_S_STANDARD', 'Entra_Identity_Governance')
    $tm = New-Sku 'TM' 'id-tm' @('TEAMS1', 'EXCHANGE_S_FOUNDATION')
    $all = @($e5, $cop, $fr, $tm)
    $plans = @(Get-DemoRolePlans $all 'E5NT+COP+FR')
    Assert ($plans -contains 'AGENT_365' -and $plans -contains 'M365_COPILOT_BUSINESS_CHAT' -and $plans -contains 'AAD_PREMIUM_P2' -and $plans -notcontains 'TEAMS1') 'bundle plans = union'
    Assert (@(Get-DemoRolePlans $all 'E5NT+MISSING').Count -eq 2) 'a missing SKU of a bundle is ignored in the union'
    $adds = @(Get-DemoLicenseAdds @($e5, $cop, $fr, $tm) @() $all)
    Assert ($adds.Count -eq 4) 'nothing held: every SKU added'
    Assert (@($adds[0].disabledPlans).Count -eq 0) 'first mailbox SKU keeps its mailbox'
    Assert ((@($adds | Where-Object { $_.partNumber -eq 'FR' })[0].disabledPlans -join ',') -eq 'plan-EXCHANGE_S_STANDARD') 'second mailbox plan disabled'
    Assert (@(@($adds | Where-Object { $_.partNumber -eq 'TM' })[0].disabledPlans).Count -eq 0) 'EXCHANGE_S_FOUNDATION is not a mailbox conflict'
    $adds = @(Get-DemoLicenseAdds @($e5, $fr) @('id-e5') $all)
    Assert ($adds.Count -eq 1 -and $adds[0].partNumber -eq 'FR' -and ($adds[0].disabledPlans -join ',') -eq 'plan-EXCHANGE_S_STANDARD') 'held mailbox SKU disables the new one'
    $adds = @(Get-DemoLicenseAdds @($fr, $e5) @() $all)
    Assert (@($adds[0].disabledPlans).Count -eq 0 -and ($adds[1].disabledPlans -join ',') -eq 'plan-EXCHANGE_S_ENTERPRISE') 'bundle order decides which mailbox stays'
    Assert (@(Get-DemoLicenseAdds @($e5) @('id-e5') $all).Count -eq 0) 'all held: nothing to add'

    Write-Host 'Lab-private az profile and config persistence'
    $nc = Join-Path $PSScriptRoot 'New-DemoConfig.ps1'
    pwsh -NoProfile -File $nc -Prefix zzhelp1 -Locale en -CopilotSku 'A+B' -IsolatedAzProfile *> $null
    $c = Read-DemoLabConfigRaw -Prefix zzhelp1
    Assert ($c.azConfigDir -eq 'generated/zzhelp1/demo/secrets/azcfg' -and $c.licenseSkus.copilotUser -eq 'A+B' -and $c.teamsForAllPersonas -eq $false -and -not $c.Contains('eventDate')) 'config: azConfigDir, bundle, teamsForAllPersonas=false, no eventDate'
    pwsh -NoProfile -File $nc -Prefix zzhelp1 -Region r2 -TeamsForAllPersonas *> $null
    $c = Read-DemoLabConfigRaw -Prefix zzhelp1
    Assert ($c.azConfigDir -and $c.licenseSkus.copilotUser -eq 'A+B' -and $c.teamsForAllPersonas -eq $true -and $c.region -eq 'r2') 're-run keeps the profile and the SKU, sets Teams for all'
    pwsh -NoProfile -File $nc -Prefix zzhelp1 -IsolatedAzProfile:$false -EventDate 2026-12-01 *> $null
    $c = Read-DemoLabConfigRaw -Prefix zzhelp1
    Assert (-not $c.Contains('azConfigDir') -and $c.eventDate -eq '2026-12-01') '-IsolatedAzProfile:$false removes it; -EventDate is optional and kept when given'
    pwsh -NoProfile -File $nc -Prefix zzhelp1 -IsolatedAzProfile *> $null
    $env:AZURE_CONFIG_DIR = $null; $env:AZURE_EXTENSION_DIR = $null
    $cfgRead = Read-DemoConfig 'zzhelp1'
    $want = Join-Path $script:DemoRepoRoot 'generated/zzhelp1/demo/secrets/azcfg'
    Assert ($env:AZURE_CONFIG_DIR -eq $want -and (Test-Path -LiteralPath $want)) 'Read-DemoConfig sets AZURE_CONFIG_DIR (absolute) and creates the folder'
    Assert ($env:AZURE_EXTENSION_DIR -eq (Join-Path $HOME '.azure\cliextensions')) 'extensions stay shared'
    Assert ((Get-DemoAzLoginCommand $cfgRead) -match "AZURE_CONFIG_DIR='.*zzhelp1.*'; .*az login --tenant") 'login command carries the profile'
    $env:AZURE_CONFIG_DIR = $null
    pwsh -NoProfile -File $nc -Prefix zzhelp2 -Locale en *> $null
    $null = Read-DemoConfig 'zzhelp2'
    Assert (-not $env:AZURE_CONFIG_DIR) 'no azConfigDir = the environment is left untouched (legacy behaviour)'

    Write-Host 'Reserved knowledge folder names (Test-DemoPack.ps1)'
    $tp = Join-Path $PSScriptRoot 'Test-DemoPack.ps1'
    $out = pwsh -NoProfile -File $tp -Pack agent-governance -Locale en 2>&1 | Out-String
    Assert ($LASTEXITCODE -eq 0) 'the shipped en locale passes'
    $kj = Join-Path (Get-DemoPackDir 'agent-governance') 'locales\en\knowledge.json'
    $orig = Get-Content -LiteralPath $kj -Raw -Encoding utf8
    try {
        ($orig -replace '"forms": "Grant Forms"', '"forms": "Forms"') | Set-Content -LiteralPath $kj -Encoding utf8 -NoNewline
        $out = pwsh -NoProfile -File $tp -Pack agent-governance -Locale en 2>&1 | Out-String
        Assert ($LASTEXITCODE -ne 0 -and $out -match 'reserved folder name') "'Forms' is rejected"
    }
    finally { Set-Content -LiteralPath $kj -Value $orig -Encoding utf8 -NoNewline }
    Assert ((Get-Content -LiteralPath $kj -Raw -Encoding utf8) -eq $orig) 'locale file restored'
}
finally {
    $env:AZURE_CONFIG_DIR = $saveCfgDir; $env:AZURE_EXTENSION_DIR = $saveExtDir
    foreach ($p in $tmpPrefixes) { $d = Join-Path $script:DemoRepoRoot "generated\$p"; if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force } }
}
Write-Host ''
Write-Host "Passed $($script:pass), failed $($script:fail)" -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $(if ($script:fail) { 1 } else { 0 })
