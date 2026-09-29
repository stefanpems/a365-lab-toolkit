#requires -Version 7.0
<#
.SYNOPSIS
  Creates (idempotent) a Foundry account + project + model deployment for labs whose Foundry agents are ALL
  prompt agents (FD): the plan must then use solution.foundry.mode = "reuse-existing" (an FD agent has no azd
  project that could provision a shared account). Tags every resource a365lab=<prefix>.
.DESCRIPTION
  Account kind AIServices (allowProjectManagement), system-assigned identity, a project, and a model deployment
  tried with the SKUs in -Skus order (default DataZoneStandard, then GlobalStandard). Prints the values for the
  plan (endpoint, account, existingResourceGroup, deployment); -AsJson returns them as JSON only.
.EXAMPLE
  pwsh -File .\New-FoundryProject.ps1 -Prefix contoso -Subscription <sub> -Region swedencentral -AsJson
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9]{2,11}$')][string]$Prefix,
    [Parameter(Mandatory)][string]$Subscription,
    [Parameter(Mandatory)][string]$Region,
    [string]$ResourceGroup,
    [string]$Account,
    [string]$Project = 'demo',
    [string]$Model = 'gpt-4.1', [string]$ModelVersion = '2025-04-14', [int]$Capacity = 50,
    [string[]]$Skus = @('DataZoneStandard', 'GlobalStandard'),
    [switch]$AsJson
)
$ErrorActionPreference = 'Stop'
if (-not $ResourceGroup) { $ResourceGroup = "$Prefix-foundry-rg" }
if (-not $Account) { $Account = "$Prefix-foundry" }
$Skus = @($Skus | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
function Write-Info([string]$m) { if (-not $AsJson) { Write-Host $m } }
function Invoke-Arm([string]$Method, [string]$Path, $Body) {
    $args2 = @('rest', '--method', $Method, '--url', "https://management.azure.com/subscriptions/$Subscription/$Path")
    if ($null -ne $Body) { $tmp = New-TemporaryFile; $Body | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tmp -Encoding utf8; $args2 += @('--body', "@$tmp", '--headers', 'Content-Type=application/json') }
    $out = az @args2 2>&1
    if ($tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    if ($LASTEXITCODE -ne 0) { throw "ARM $Method $Path failed: $($out | Out-String)" }
    if ($out) { return ($out | Out-String | ConvertFrom-Json) }
}
function Wait-Provisioned([string]$Path, [int]$TimeoutSec = 900) {
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec) {
        $s = (Invoke-Arm GET $Path).properties.provisioningState
        if ($s -in 'Succeeded', 'Failed', 'Canceled') { return $s }
        Start-Sleep -Seconds 10
    }
    return 'Timeout'
}
$api = 'api-version=2025-06-01'
if ((az group exists -n $ResourceGroup --subscription $Subscription) -ne 'true') { az group create -n $ResourceGroup -l $Region --subscription $Subscription --tags "a365lab=$Prefix" -o none }
else { az group update -n $ResourceGroup --subscription $Subscription --set "tags.a365lab=$Prefix" -o none }
$acctPath = "resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$Account"
Invoke-Arm PUT "$acctPath`?$api" @{ location = $Region; kind = 'AIServices'; sku = @{ name = 'S0' }; identity = @{ type = 'SystemAssigned' }; tags = @{ a365lab = $Prefix }
    properties = @{ customSubDomainName = $Account; allowProjectManagement = $true; publicNetworkAccess = 'Enabled'; disableLocalAuth = $false } } | Out-Null
Write-Info "Foundry account ${Account}: $(Wait-Provisioned "$acctPath`?$api")"
Invoke-Arm PUT "$acctPath/projects/$Project`?$api" @{ location = $Region; identity = @{ type = 'SystemAssigned' }; tags = @{ a365lab = $Prefix }
    properties = @{ displayName = $Project; description = "Lab $Prefix project" } } | Out-Null
Write-Info "Foundry project ${Project}: $(Wait-Provisioned "$acctPath/projects/$Project`?$api")"
$deployedSku = $null
foreach ($sku in $Skus) {
    try {
        Invoke-Arm PUT "$acctPath/deployments/$Model`?$api" @{ sku = @{ name = $sku; capacity = $Capacity }; properties = @{ model = @{ format = 'OpenAI'; name = $Model; version = $ModelVersion } } } | Out-Null
        if ((Wait-Provisioned "$acctPath/deployments/$Model`?$api") -eq 'Succeeded') { $deployedSku = $sku; break }
    }
    catch { Write-Info "  $Model with $sku not available: $($_.Exception.Message.Split([Environment]::NewLine)[0])" }
}
if (-not $deployedSku) { throw "Could not deploy $Model with any of: $($Skus -join ', ') (region $Region). Pick another region or model." }
$result = [ordered]@{ mode = 'reuse-existing'; endpoint = "https://$Account.services.ai.azure.com/api/projects/$Project"; account = $Account; existingResourceGroup = $ResourceGroup; deployment = $Model; sku = $deployedSku }
if ($AsJson) { $result | ConvertTo-Json -Compress } else { Write-Host "Ready: plan solution.foundry = $($result | ConvertTo-Json -Compress)" -ForegroundColor Green }
