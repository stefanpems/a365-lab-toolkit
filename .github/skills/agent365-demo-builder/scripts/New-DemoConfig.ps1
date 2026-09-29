#requires -Version 7.0
<#
.SYNOPSIS
  Writes the per-lab Demo Builder configuration generated/<prefix>/demo/demo-config.json (secret-free, gitignored).
.DESCRIPTION
  Called by the Demo Builder after the interview. Every other Demo Builder script reads this file, so tenant,
  subscription, language and environments are chosen ONCE. Re-running it updates the given values only.
.EXAMPLE
  pwsh -File .\New-DemoConfig.ps1 -Prefix cts2 -Locale fr -TenantId <tid> -SubscriptionId <sid> -Domain contoso.onmicrosoft.com `
       -AdminUpn admin@contoso.onmicrosoft.com -Region swedencentral -PaygEnvironmentId <envId> -DefaultEnvironmentId <envId> -EventDate 2026-10-01
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9]{2,8}$')][string]$Prefix,
    [string]$Pack = 'agent-governance',
    [string]$Locale,
    [string]$TenantId,
    [string]$SubscriptionId,
    [string]$Domain,
    [string]$AdminUpn,
    [string]$Region,
    [string]$SwaRegion = 'eastus2',
    [ValidateSet('manual', 'assisted')][string]$SecretHandling = 'manual',
    [string]$PaygEnvironmentId,
    [string]$DefaultEnvironmentId,
    [ValidateSet('create-shared', 'reuse-existing')][string]$FoundryMode = 'create-shared',
    [string]$FoundryEndpoint, [string]$FoundryAccount, [string]$FoundryResourceGroup, [string]$FoundryDeployment = 'gpt-4.1',
    [string]$CopilotSku = 'MICROSOFT_365_E7_NO_TEAMS', [string]$TeamsSku = 'Microsoft_Teams_Enterprise_New', [string]$FrontierSku = 'MICROSOFT_AGENT_FRONTIER_NO_TEAMS',
    [string]$EventDate
)
. (Join-Path $PSScriptRoot '_demo-common.ps1')
$dir = Get-DemoLabDir $Prefix
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$path = Join-Path $dir 'demo-config.json'
$c = if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } else { [ordered]@{} }
$c['prefix'] = $Prefix; $c['pack'] = $Pack
foreach ($k in 'Locale', 'TenantId', 'SubscriptionId', 'Domain', 'AdminUpn', 'Region', 'SwaRegion', 'SecretHandling', 'EventDate') {
    $v = Get-Variable -Name $k -ValueOnly
    $key = $k.Substring(0, 1).ToLowerInvariant() + $k.Substring(1)
    if ($PSBoundParameters.ContainsKey($k) -or -not $c.Contains($key)) { $c[$key] = $v }
}
if (-not $c.Contains('copilotStudio')) { $c['copilotStudio'] = [ordered]@{} }
if ($PaygEnvironmentId) { $c.copilotStudio['paygEnvironmentId'] = $PaygEnvironmentId }
if ($DefaultEnvironmentId) { $c.copilotStudio['defaultEnvironmentId'] = $DefaultEnvironmentId }
if ($PSBoundParameters.ContainsKey('FoundryMode') -or -not $c.Contains('foundry')) {
    $c['foundry'] = if ($FoundryMode -eq 'reuse-existing') { [ordered]@{ mode = 'reuse-existing'; endpoint = $FoundryEndpoint; account = $FoundryAccount; existingResourceGroup = $FoundryResourceGroup; deployment = $FoundryDeployment } } else { [ordered]@{ mode = 'create-shared' } }
}
$c['licenseSkus'] = [ordered]@{ copilotUser = $CopilotSku; teams = $TeamsSku; frontierAgent = $FrontierSku }
if (-not $c.locale) { throw '-Locale is required the first time (en, it, fr, es, de or another locale folder of the pack).' }
$null = Get-DemoLocale -Locale $c.locale -Pack $Pack   # fails early if the locale is missing
$c | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
Write-Host "Demo config written: $path" -ForegroundColor Green
$c | ConvertTo-Json -Depth 10
