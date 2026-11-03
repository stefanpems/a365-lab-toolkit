#requires -Version 7.0
<#
.SYNOPSIS
  Offline regression for the Demo Builder's exact five language choices and localized runtime configuration.
  Uses an isolated English-text fixture pack and a unique throwaway prefix; never signs in or changes a tenant.
.EXAMPLE
  pwsh -NoProfile -File .\test-demo-locales.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_demo-common.ps1')
$script:fail = 0; $script:pass = 0
function Assert([bool]$Cond, [string]$Name) {
    if ($Cond) { $script:pass++; Write-Host "  ok   $Name" }
    else { $script:fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
}

$languages = [ordered]@{ en = 'English'; it = 'Italian'; es = 'Spanish'; fr = 'French'; de = 'German' }
$locales = @($languages.Keys)
$configScript = Join-Path $PSScriptRoot 'New-DemoConfig.ps1'
$validation = @((Get-Command $configScript).Parameters['Locale'].Attributes |
    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })
Assert ($validation.Count -eq 1 -and ($validation[0].ValidValues -join ',') -ceq ($locales -join ',')) `
    'configuration accepts exactly en, it, es, fr, de'

$languageRows = @(Select-String -LiteralPath (Join-Path $PSScriptRoot '..\SKILL.md') `
    -Pattern '^\| `([a-z]{2})` \| ([A-Za-z]+) \(([A-Z]{2})\) \|$')
$questionLocales = @($languageRows | ForEach-Object { $_.Matches[0].Groups[1].Value })
Assert (($questionLocales -join ',') -ceq ($locales -join ',')) `
    'the language question lists all and only the five supported choices in order'
foreach ($row in $languageRows) {
    $match = $row.Matches[0]
    $locale = $match.Groups[1].Value
    Assert ($match.Groups[2].Value -ceq $languages[$locale] -and
        $match.Groups[3].Value -ceq $locale.ToUpperInvariant()) "language label matches $locale"
}

$packDir = Get-DemoPackDir 'agent-governance'
$shipped = @(Get-ChildItem -LiteralPath (Join-Path $packDir 'locales') -Directory | Select-Object -ExpandProperty Name)
Assert (($shipped | Sort-Object) -join ',' -ceq (($locales | Sort-Object) -join ',')) `
    'the shipped pack contains exactly the five supported locale directories'
foreach ($locale in $locales) {
    foreach ($part in 'core', 'knowledge', 'tests') {
        Assert (Test-Path -LiteralPath (Join-Path $packDir "locales\$locale\$part.json")) "$locale includes $part.json"
    }
}

$prefix = 'z' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$testRoot = Join-Path $script:DemoRepoRoot "generated\$prefix"
$savedPacksRoot = $env:DEMO_PACKS_ROOT
$created = $false
try {
    $null = New-Item -ItemType Directory -Path $testRoot
    $created = $true
    $env:DEMO_PACKS_ROOT = Join-Path $testRoot 'locale-fixtures'
    foreach ($locale in $locales) {
        $dir = Join-Path $env:DEMO_PACKS_ROOT "agent-governance\locales\$locale"
        $null = New-Item -ItemType Directory -Force -Path $dir
        $name = "Demo $($languages[$locale]) caf$([char]0x00e9)"
        @{ locale = $locale; language = $languages[$locale]; org = @{ name = $name } } |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $dir 'core.json') -Encoding utf8
        @{ title = '{{org.name}} handbook' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'knowledge.json') -Encoding utf8
        @{ prompt = 'Find {{org.name}}' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'tests.json') -Encoding utf8
    }

    $configPath = Join-Path (Get-DemoLabDir $prefix) 'demo-config.json'
    foreach ($locale in $locales) {
        $null = & $configScript -Prefix $prefix -Locale $locale 6>$null
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        Assert ($config.locale -ceq $locale) "$locale is accepted and saved without an English-only gate"
        $loaded = Get-DemoLocale -Locale $config.locale
        $name = "Demo $($languages[$locale]) caf$([char]0x00e9)"
        Assert ($loaded.locale -ceq $locale -and $loaded.org.name -ceq $name) `
            "$locale loads its own UTF-8 values without an English fallback"
        Assert ($loaded.knowledge.title -ceq "$name handbook" -and $loaded.tests.prompt -ceq "Find $name") `
            "$locale preserves selected values in knowledge and test placeholders"

        $null = & $configScript -Prefix $prefix -Region 'test-region' 6>$null
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        Assert ($config.locale -ceq $locale) "$locale survives an update that omits the language"

        $null = & $configScript -Prefix $prefix -Locale $locale.ToUpperInvariant() 6>$null
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        Assert ($config.locale -ceq $locale) "$locale uses a canonical lowercase code"
    }

    $before = Get-Content -LiteralPath $configPath -Raw -Encoding utf8
    foreach ($unsupported in 'pt', 'en-US') {
        $rejected = $false
        try { $null = & $configScript -Prefix $prefix -Locale $unsupported 6>$null }
        catch [System.Management.Automation.ParameterBindingException] {
            if ($_.FullyQualifiedErrorId -ne 'ParameterArgumentValidationError,New-DemoConfig.ps1') { throw }
            $rejected = $true
        }
        Assert $rejected "unsupported choice $unsupported is rejected"
        Assert ((Get-Content -LiteralPath $configPath -Raw -Encoding utf8) -ceq $before) `
            "rejecting $unsupported preserves the existing locale and configuration"
    }
}
finally {
    $env:DEMO_PACKS_ROOT = $savedPacksRoot
    if ($created) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

Write-Host "$script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
