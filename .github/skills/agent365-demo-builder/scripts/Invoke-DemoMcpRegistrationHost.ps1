#requires -Version 7.0
<#
.SYNOPSIS
  Runs the installed official MCP registration executor with lab-private authentication.
.DESCRIPTION
  Dry-run by default. -Authenticate permits an announced browser sign-in when the private
  gateway cache is empty. -Apply submits the request; it never approves it.
  Tokens reach the host only through standard input, never command arguments or files.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Prefix,
    [Parameter(Mandatory)][string]$PayloadPath,
    [switch]$Apply,
    [switch]$Authenticate
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_demo-common.ps1')
$cfg = Read-DemoConfig $Prefix
if (-not ($cfg.azConfigDir -or $env:DEMO_SESSION_AUTH_DIR)) {
    throw 'The isolated registration host requires the stored lab-private Azure profile or DEMO_SESSION_AUTH_DIR.'
}
Assert-DemoTenant $cfg
$payloadPath = (Resolve-Path -LiteralPath $PayloadPath).Path
$payload = Get-Content -LiteralPath $payloadPath -Raw | ConvertFrom-Json
if (-not $payload.serverName -or $payload.authType -ne 'NoAuth') {
    throw 'The demo registration host requires a named NoAuth demo-server payload.'
}
$receiptPath = "$payloadPath.receipt.json"
if ($Apply -and (Test-Path -LiteralPath $receiptPath)) {
    throw "A submission receipt already exists for $($payload.serverName). Reconcile the receipt and registration log; do not resubmit."
}
$gatewayArgs = @{
    TenantId = [string]$cfg.tenantId
    Prefix = $Prefix
    LoginHint = [string]$cfg.adminUpn
    ClientId = '1950a258-227b-4e31-a9cf-717495945fc2'
    Scopes = @('ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/.default')
    CacheName = 'msal_gateway_cache.json'
}
$gatewayToken = Get-DemoMsalToken @gatewayArgs -SilentOnly
if (-not $gatewayToken) {
    if (-not $Authenticate) {
        throw 'A lab-private gateway sign-in is required. Announce the interactive browser login, then run this helper with -Authenticate (without -Apply) first. Do not sign in to the admin center to submit a request.'
    }
    Write-Host "Interactive gateway sign-in required for $($cfg.adminUpn); the configured external browser will open."
    $gatewayToken = Get-DemoMsalToken @gatewayArgs
}
$tool = Get-Command a365 -CommandType Application -ErrorAction Stop
$toolList = dotnet tool list --global 2>&1
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the installed global Agent 365 .NET tool.' }
$versionLine = @($toolList | Where-Object { "$_" -match '^\s*microsoft\.agents\.a365\.devtools\.cli\s+(\S+)\s+' })
if ($versionLine.Count -ne 1) { throw 'Exactly one installed global Agent 365 CLI version is required.' }
$null = "$($versionLine[0])" -match '^\s*microsoft\.agents\.a365\.devtools\.cli\s+(\S+)\s+'
$version = $Matches[1]
$package = 'microsoft.agents.a365.devtools.cli'
$toolsDirectory = Join-Path (Split-Path -Parent $tool.Source) ".store\$package\$version\$package\$version\tools"
$assemblies = @(Get-ChildItem -LiteralPath $toolsDirectory -Filter 'Microsoft.Agents.A365.DevTools.Cli.dll' -File -Recurse)
if ($assemblies.Count -ne 1) { throw 'Cannot uniquely resolve the installed CLI assembly; no registration was attempted.' }
$cliDir = $assemblies[0].DirectoryName
$regDir = Split-Path -Parent $payloadPath
$hostDir = Join-Path $regDir "host-$version"
$buildLog = Join-Path $regDir 'host-build.log'
$project = Join-Path $PSScriptRoot 'dotnet\IsolatedMcpRegistration\IsolatedMcpRegistration.csproj'
dotnet build $project "-p:A365CliDir=$cliDir" "-p:BaseIntermediateOutputPath=$regDir\host-obj\" --output $hostDir --nologo --verbosity quiet *> $buildLog
if ($LASTEXITCODE -ne 0) { throw "The isolated registration host did not build. See $buildLog. No registration was attempted." }
if (-not (Test-Path -LiteralPath (Join-Path $hostDir 'Microsoft.Agents.A365.DevTools.Cli.dll'))) {
    throw 'The host build omitted the official CLI runtime. No registration was attempted.'
}
if ($Apply) {
    $escaped = ([string]$payload.serverName).Replace("'", "''")
    $existing = Invoke-DemoGraph GET "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$escaped-A365Proxy' or displayName eq '$escaped-PublicClients' or displayName eq '$escaped - BYO'&`$select=id,appId,displayName"
    if (@($existing.value).Count) {
        throw "Backing applications already exist for $($payload.serverName). Reconcile the partial registration before retrying."
    }
}
$arguments = @((Join-Path $hostDir 'IsolatedMcpRegistration.dll'), $payloadPath)
if (-not $Apply) { $arguments += '--dry-run' }
$log = Join-Path $regDir "$(if ($Apply) { 'register' } else { 'dry-run' })-$($payload.serverName).log"
try {
    $bundle = @{
        TenantId = [string]$cfg.tenantId
        LoginHint = [string]$cfg.adminUpn
        GraphToken = Get-DemoAzToken -TenantId $cfg.tenantId
        GatewayToken = $gatewayToken
    } | ConvertTo-Json -Compress
    $bundle | dotnet @arguments *> $log
    $code = $LASTEXITCODE
}
finally { $bundle = $null; $gatewayToken = $null }
if ($code -ne 0) { throw "The official registration executor failed (exit $code). See $log and reconcile any receipt before retrying." }
if ($Apply) {
    $text = Get-Content -LiteralPath $log -Raw
    if (-not (Test-Path -LiteralPath $receiptPath) -or $text -notmatch 'has been registered successfully') {
        throw "Submission or post-registration configuration is incomplete. See $log; do not resubmit blindly."
    }
    Write-DemoLog $Prefix "$($payload.serverName): gateway submission and official app configuration completed; admin approval is still pending."
}
else { Write-DemoLog $Prefix "$($payload.serverName): official registration dry run passed; no request was submitted." }
