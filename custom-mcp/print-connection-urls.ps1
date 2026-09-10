#requires -Version 5.1
<#
.SYNOPSIS
  Print the exact make.powerapps.com/connectionsMcp URL the user must open to create the one-time
  Power Platform connection for EACH registered sample custom MCP server (anon AND auth). Run it after
  registering the servers; hand BOTH URLs to the user (the auth one triggers an OAuth sign-in).

.DESCRIPTION
  A BYO MCP tool only returns data once the invoking user has created the connector connection. Each
  ext_<Name> server has its OWN Power Platform connector, so the user must create a SEPARATE connection
  for anon and auth. This script discovers the connectors in the tenant's default Power Platform
  environment and builds the deep-link connectionsMcp URL for each, so the provisioning flow can give
  the user the precise URLs instead of a vague "go create the connection".

  The connectionsMcp deep-link connectorId is the Power Platform api name with the 'shared_' prefix
  rewritten to 'shared_tc-' (verified against a working URL). The '...p' (proxy) connector is the one
  that carries the user connection.

.PARAMETER Name
  The MCP base name (solution prefix), e.g. 'contoso' -> ext_contosoAnon / ext_contosoAuth.
.PARAMETER EnvironmentId
  Optional Power Platform environment id of the hidden 'Compliant Container' that hosts the ext_
  connectors. The environment-listing APIs do NOT return that env, so if auto-discovery fails, obtain
  the id once from an OBO agent (ask it: "Give me the Power Platform setup URL for the ext_<Name>Anon
  server" and copy the environmentName= value) and pass it here. It is then cached per tenant under
  %LOCALAPPDATA%\a365-lab\pp-compliant-env.<tenantId>.txt and reused automatically on later runs.
.EXAMPLE
  .\print-connection-urls.ps1 -Name a09081
.EXAMPLE
  .\print-connection-urls.ps1 -Name a09081 -EnvironmentId ecbd2b6e-2347-ee97-b7ab-3755741cf207
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$Name,
    [string]$EnvironmentId
)
$ErrorActionPreference = 'Stop'
$tok = az account get-access-token --resource "https://service.powerapps.com/" --query accessToken -o tsv
$hdr = @{ Authorization = "Bearer $tok" }
$slug = $Name.ToLower()

function Get-Apis([string]$envId) {
    $u = "https://api.powerapps.com/providers/Microsoft.PowerApps/apis?api-version=2016-11-01&`$filter=environment eq '$envId'"
    try { return (Invoke-RestMethod -Uri $u -Headers $hdr).value } catch { return @() }
}

# The ext_<name> connectors live in a hidden Power Platform 'Compliant Container' environment that the
# environment-listing APIs do NOT return, so scanning environments usually cannot find it. That env id
# is STABLE per tenant, so once it is known (passed via -EnvironmentId or obtained from an agent's setup
# URL) it is cached per tenant here and reused automatically on later runs/agents.
$cacheDir  = Join-Path $env:LOCALAPPDATA 'a365-lab'
$tenantId  = (az account show --query tenantId -o tsv 2>$null)
$cacheFile = if ($tenantId) { Join-Path $cacheDir "pp-compliant-env.$tenantId.txt" } else { $null }

$apis = @()
if ($EnvironmentId) {
    $apis = Get-Apis $EnvironmentId
} else {
    # 1) Prefer the per-tenant cache: the Compliant Container env id is stable per tenant and the
    #    environment-listing APIs don't return it, so the cache is the reliable fast path.
    if ($cacheFile -and (Test-Path -LiteralPath $cacheFile)) {
        $cand = (Get-Content -LiteralPath $cacheFile -Raw).Trim()
        if ($cand) {
            $a = Get-Apis $cand
            if ($a | Where-Object { $_.name -like "*ext-5f$slug*" }) { $EnvironmentId = $cand; $apis = $a }
        }
    }
    # 2) Otherwise scan environments, EXCLUDING the tenant Default: 'shared_' custom connectors are
    #    visible in EVERY environment (including Default), but the A365 MCP CONNECTION must be created
    #    in the hidden 'Compliant Container' env - a Default match is a false positive that builds a
    #    wrong connectionsMcp URL (wrong environmentName + a doubled 'tc-' connector id).
    if (-not $EnvironmentId) {
        $envs = Invoke-RestMethod -Uri "https://api.powerapps.com/providers/Microsoft.PowerApps/environments?api-version=2016-11-01" -Headers $hdr
        foreach ($e in $envs.value) {
            if ($e.name -like 'Default-*') { continue }
            $a = Get-Apis $e.name
            if ($a | Where-Object { $_.name -like "*ext-5f$slug*" }) { $EnvironmentId = $e.name; $apis = $a; break }
        }
    }
    if (-not $EnvironmentId) {
        Write-Error @"
Could not auto-discover the Power Platform 'Compliant Container' environment hosting the ext_$Name connectors (the environment-listing APIs do not return it, and no cached id exists for this tenant).
Obtain the environment id ONCE and re-run with -EnvironmentId (it is then cached per tenant and reused automatically):
  - In an OBO agent chat (ACA/FH/FD-OBO), send exactly:  Give me the Power Platform setup URL for the ext_${Name}Anon server.
    The agent returns a URL like  https://make.powerapps.com/connectionsMcp?...&environmentName=<ENV-ID>  - copy <ENV-ID>.
  - Then run:  .\print-connection-urls.ps1 -Name $Name -EnvironmentId <ENV-ID>
"@
        exit 1
    }
}

# Cache the resolved env id per tenant so later runs/agents resolve it without -EnvironmentId.
if ($EnvironmentId -and $cacheFile -and ($apis | Where-Object { $_.name -like "*ext-5f$slug*" })) {
    try { New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null; Set-Content -LiteralPath $cacheFile -Value $EnvironmentId } catch { }
}

Write-Host "Power Platform environment: $EnvironmentId" -ForegroundColor Cyan
Write-Host "Give the user BOTH URLs below - each ext_ server needs its OWN one-time connection:" -ForegroundColor Cyan
foreach ($srv in @('Anon', 'Auth')) {
    # The '...p' (proxy) connector carries the user connection.
    $c = $apis | Where-Object { $_.name -like "*ext-5f$slug$($srv.ToLower())p*" } | Select-Object -First 1
    if (-not $c) {
        Write-Host "  $srv : connector not found yet (register ext_${Name}$srv first)." -ForegroundColor Yellow
        continue
    }
    # The connectionsMcp connectorId is the api name with 'shared_' rewritten to 'shared_tc-'. In the
    # Compliant Container the name is 'shared_ext-...' (rewrite needed); some environments already return
    # 'shared_tc-ext-...' (leave as-is) - guard against a doubled 'tc-'.
    $connectorId = if ($c.name -like 'shared_tc-*') { $c.name } else { $c.name -replace '^shared_', 'shared_tc-' }
    $url = "https://make.powerapps.com/connectionsMcp?connectorIds=$connectorId&environmentName=$EnvironmentId"
    $authKind = if ($srv -eq 'Auth') { 'EntraOAuth - prompts an OAuth sign-in' } else { 'NoAuth' }
    Write-Host ""
    Write-Host "  $srv ($($c.properties.displayName), $authKind):" -ForegroundColor Green
    Write-Host "    $url"
}
Write-Host ""
Write-Host "Fallback (lists every connector needing a connection): https://make.powerapps.com/connectionsMcp?environmentName=$EnvironmentId"
