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

    Write-Host 'Lab az profile settings (Set-DemoAzProfileDefaults)'
    $d = Join-Path $env:TEMP 'zzhelp-azcfg'; if (Test-Path $d) { Remove-Item $d -Recurse -Force }; New-Item -ItemType Directory $d | Out-Null
    Set-DemoAzProfileDefaults $d
    $ini = Get-Content (Join-Path $d 'config') -Raw
    Assert ($ini -match '(?m)^\[core\]' -and $ini -match 'enable_broker_on_windows = false' -and $ini -match 'login_experience_v2 = off') 'new profile: browser sign-in, no subscription picker'
    "[cloud]`nname = AzureCloud`n`n[core]`ncollect_telemetry = false`nenable_broker_on_windows = true`n`n[extension]`nuse_dynamic_install = no" | Set-Content (Join-Path $d 'config') -Encoding utf8
    Set-DemoAzProfileDefaults $d
    $ini = Get-Content (Join-Path $d 'config') -Raw
    Assert ($ini -match 'enable_broker_on_windows = false' -and $ini -notmatch 'enable_broker_on_windows = true' -and $ini -match 'collect_telemetry = false' -and $ini -match '(?s)\[core\].*login_experience_v2 = off.*\[extension\]' -and $ini -match 'use_dynamic_install = no' -and $ini -match 'name = AzureCloud') 'existing profile: value fixed, key added in [core], other sections kept'
    $before = Get-Content (Join-Path $d 'config') -Raw; Set-DemoAzProfileDefaults $d
    Assert ((Get-Content (Join-Path $d 'config') -Raw) -eq $before) 'idempotent'

    Write-Host 'Cached access tokens of the lab az profile (py/az_cache_drop.py, DPAPI cache)'
    $py = Join-Path $PSScriptRoot 'py\az_cache_drop.py'
    $mk = @"
import json, os
from msal_extensions import FilePersistenceWithDataProtection as P
c = {"AccessToken": {"g": {"target": "https://graph.microsoft.com/.default"}, "m": {"target": "https://management.core.windows.net//.default"}}, "RefreshToken": {"r": {"secret": "x"}}, "Account": {}}
P(os.path.join(r"$d", "msal_token_cache.bin")).save(json.dumps(c))
"@
    python -c $mk
    $o = python $py --config-dir $d --resource graph.microsoft.com 2>&1 | Out-String
    $left = python -c "import json,os; from msal_extensions import FilePersistenceWithDataProtection as P; c=json.loads(P(os.path.join(r'$d','msal_token_cache.bin')).load()); print(','.join(sorted(c['AccessToken'])), len(c['RefreshToken']))"
    Assert ($LASTEXITCODE -eq 0 -and $o -match 'dropped 1' -and "$left".Trim() -eq 'm 1') 'Graph access token dropped, ARM token and refresh token kept'
    python $py --config-dir (Join-Path $HOME '.azure') 2>$null | Out-Null
    Assert ($LASTEXITCODE -eq 2) 'the machine-wide profile is refused'
    $e2 = Join-Path $env:TEMP 'zzhelp-empty'; New-Item -ItemType Directory -Force $e2 | Out-Null
    python $py --config-dir $e2 2>$null | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'no cache = nothing to do'
    Remove-Item $d, $e2 -Recurse -Force
    $env:AZURE_CONFIG_DIR = $null
    Assert (-not (Reset-DemoAzCachedTokens)) 'Reset-DemoAzCachedTokens does nothing without a lab profile'

    Write-Host 'Invoke-DemoGraph: CAE revocation retried once after dropping the cached token (mocked)'
    function New-Cae401 { $r = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Unauthorized); $er = [System.Management.Automation.ErrorRecord]::new([Microsoft.PowerShell.Commands.HttpResponseException]::new('401', $r), 'cae', 'InvalidOperation', $null); $er.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"error":{"code":"InvalidAuthenticationToken","message":"Continuous access evaluation resulted in challenge with result: InteractionRequired and code: TokenIssuedBeforeRevocationTimestamp"}}'); return $er }
    function Get-DemoAzToken { 'fake-token' }
    function Reset-DemoAzCachedTokens { $script:resets++; return $true }
    function Invoke-RestMethod { $script:calls++; if ($script:calls -le $script:failCalls) { throw (New-Cae401) }; [pscustomobject]@{ ok = $true } }
    $env:AZURE_CONFIG_DIR = Join-Path $env:TEMP 'zzhelp-fake-profile'
    $script:calls = 0; $script:resets = 0; $script:failCalls = 1; $script:DemoCaeRetried = $false
    $r = Invoke-DemoGraph GET 'https://graph.microsoft.com/v1.0/x' -MaxRetries 0
    Assert ($r.ok -and $script:calls -eq 2 -and $script:resets -eq 1) 'first 401 CAE -> cache dropped once -> success'
    $script:calls = 0; $script:resets = 0; $script:failCalls = 9; $script:DemoCaeRetried = $false
    $msg = ''; try { Invoke-DemoGraph GET 'https://graph.microsoft.com/v1.0/x' -MaxRetries 0 | Out-Null } catch { $msg = "$_" }
    Assert ($script:resets -eq 1 -and $script:calls -eq 2 -and $msg -match 'az login --tenant' -and $msg -match 'zzhelp-fake-profile') 'still refused -> one retry only, then the login command of the lab profile'
    $script:calls = 0; $script:resets = 0; $script:failCalls = 9; $script:DemoCaeRetried = $false
    $r = Invoke-DemoGraph GET 'https://graph.microsoft.com/v1.0/x' -MaxRetries 0 -Token 'explicit' -NoThrow
    Assert ($script:resets -eq 0 -and $r.status -eq 401) 'an explicit -Token (MSAL) is never handled as an az token'
    Remove-Item Function:\Invoke-RestMethod, Function:\Get-DemoAzToken, Function:\Reset-DemoAzCachedTokens
}
finally {
    $env:AZURE_CONFIG_DIR = $saveCfgDir; $env:AZURE_EXTENSION_DIR = $saveExtDir
    foreach ($p in $tmpPrefixes) { $d = Join-Path $script:DemoRepoRoot "generated\$p"; if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force } }
}
Write-Host ''
Write-Host "Passed $($script:pass), failed $($script:fail)" -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $(if ($script:fail) { 1 } else { 0 })
