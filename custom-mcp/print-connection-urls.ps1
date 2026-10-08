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
.PARAMETER Server
  Instead of -Name: one or more full ext_ server names (any registered BYO server, e.g. the Demo Builder
  servers), comma-separated or as an array. One URL per server (its '...p' proxy connector).
.PARAMETER PassThru
  Also return one object per URL found (server, connectorId, environmentId, url) for calling scripts.
.PARAMETER EnvironmentId
  Optional Power Platform environment id of the hidden 'Compliant Container' that hosts the ext_
  connectors. The environment-listing APIs do NOT return that env, so if auto-discovery fails, obtain
  the id once from an OBO agent (ask it: "Give me the Power Platform setup URL for the ext_<Name>Anon
  server" and copy the environmentName= value) and pass it here. It is then cached per tenant under
  %LOCALAPPDATA%\a365-lab\pp-compliant-env.<tenantId>.txt and reused automatically on later runs.
  Without it, the script falls back to scanning the environments: a scan result is printed as UNVERIFIED
  and never cached (the ext_ connectors are visible in every environment).
.EXAMPLE
  .\print-connection-urls.ps1 -Name a09081
.EXAMPLE
  .\print-connection-urls.ps1 -Name a09081 -EnvironmentId ecbd2b6e-2347-ee97-b7ab-3755741cf207
.EXAMPLE
  .\print-connection-urls.ps1 -Server ext_RecordsTest,ext_CompaniesTest
#>
[CmdletBinding()]
param(
    [string]$Name,
    [string]$EnvironmentId,
    [string[]]$Server,
    [switch]$PassThru
)
$ErrorActionPreference = 'Stop'
$Server = @($Server | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $Name -and -not $Server.Count) { throw 'Pass -Name <base> (sample pair ext_<Name>Anon/Auth) or -Server <ext_ server name(s)>.' }
$tok = az account get-access-token --resource "https://service.powerapps.com/" --query accessToken -o tsv
$hdr = @{ Authorization = "Bearer $tok" }
$slug = if ($Name) { $Name.ToLower() } else { $null }

# Connectors to resolve: the sample pair (-Name) or explicit servers (-Server). The '...p' (proxy)
# connector carries the user connection; with -Server the match is exact ('<name>p-5f<hash>').
$targets = if ($Server.Count) {
    @($Server | ForEach-Object { [pscustomobject]@{ label = $_; server = $_; like = "*ext-5f$(($_ -replace '^ext_', '').ToLower())p-5f*"; kind = 'one-time connection' } })
} else {
    @('Anon', 'Auth') | ForEach-Object { [pscustomobject]@{ label = $_; server = "ext_$Name$_"; like = "*ext-5f$slug$($_.ToLower())p*"; kind = $(if ($_ -eq 'Auth') { 'EntraOAuth - prompts an OAuth sign-in' } else { 'NoAuth' }) } }
}
$discoverLike = if ($Server.Count) { @($targets | ForEach-Object { $_.like }) } else { @("*ext-5f$slug*") }
function Test-Hit($list) { foreach ($p in $discoverLike) { if ($list | Where-Object { $_.name -like $p }) { return $true } }; return $false }

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
# Where the env id comes from: 'param' (given by the user, from an agent's setup URL = verified), 'cache' (a value
# that was given before), 'scan' (first non-Default environment where the connectors are VISIBLE - NOT verified:
# ext_ connectors are visible in every environment, so a scan can return an ordinary environment).
$source = $null
if ($EnvironmentId) {
    $apis = Get-Apis $EnvironmentId
    $source = 'param'
} else {
    # 1) Prefer the per-tenant cache: the Compliant Container env id is stable per tenant and the
    #    environment-listing APIs don't return it, so the cache is the reliable fast path.
    if ($cacheFile -and (Test-Path -LiteralPath $cacheFile)) {
        $cand = (Get-Content -LiteralPath $cacheFile -Raw).Trim()
        if ($cand) {
            $a = Get-Apis $cand
            if (Test-Hit $a) { $EnvironmentId = $cand; $apis = $a; $source = 'cache' }
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
            if (Test-Hit $a) { $EnvironmentId = $e.name; $apis = $a; $source = 'scan'; break }
        }
    }
    if (-not $EnvironmentId) {
        $first = $targets[0].server
        $rerun = if ($Server.Count) { "-Server $($Server -join ',')" } else { "-Name $Name" }
        Write-Error @"
Could not auto-discover the Power Platform 'Compliant Container' environment hosting the $(($targets | ForEach-Object { $_.server }) -join ' / ') connectors (the environment-listing APIs do not return it, and no cached id exists for this tenant).
Obtain the environment id ONCE and re-run with -EnvironmentId (it is then cached per tenant and reused automatically):
  - In an OBO agent chat (ACA/FH/FD-OBO) that has the server attached, send exactly:  Give me the Power Platform setup URL for the $first server.
    The agent returns a URL like  https://make.powerapps.com/connectionsMcp?...&environmentName=<ENV-ID>  - copy <ENV-ID>.
  - Then run:  .\print-connection-urls.ps1 $rerun -EnvironmentId <ENV-ID>
"@
        exit 1
    }
}

# Cache ONLY an env id given with -EnvironmentId (taken from an agent's setup URL): a scan result is a guess and,
# once cached, would be reused silently by every later run and lab in the tenant.
if ($source -eq 'param' -and $cacheFile -and (Test-Hit $apis)) {
    try { New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null; Set-Content -LiteralPath $cacheFile -Value $EnvironmentId } catch { }
}

Write-Host "Power Platform environment: $EnvironmentId ($source)" -ForegroundColor Cyan
if ($source -eq 'scan') {
    Write-Warning ("UNVERIFIED environment: '$EnvironmentId' was found by scanning, and ext_ connectors are visible in every environment, so it may not be the hidden 'Compliant Container' (not cached). " +
        "If the URL below shows no connector or the connection fails, ask an OBO agent that has the server attached: 'Give me the Power Platform setup URL for the $($targets[0].server) server', " +
        "copy environmentName=<ENV-ID> and re-run with -EnvironmentId <ENV-ID> (that value is cached per tenant).")
}
Write-Host "Give the user $(if (-not $Server.Count) { 'BOTH URLs' } elseif ($targets.Count -gt 1) { 'ALL the URLs' } else { 'the URL' }) below - each ext_ server needs its OWN one-time connection:" -ForegroundColor Cyan
$found = @()
foreach ($t in $targets) {
    $c = $apis | Where-Object { $_.name -like $t.like } | Select-Object -First 1
    if (-not $c) {
        Write-Host "  $($t.label) : connector not found yet (register $($t.server) first)." -ForegroundColor Yellow
        continue
    }
    # The connectionsMcp connectorId is the api name with 'shared_' rewritten to 'shared_tc-'. In the
    # Compliant Container the name is 'shared_ext-...' (rewrite needed); some environments already return
    # 'shared_tc-ext-...' (leave as-is) - guard against a doubled 'tc-'.
    $connectorId = if ($c.name -like 'shared_tc-*') { $c.name } else { $c.name -replace '^shared_', 'shared_tc-' }
    $url = "https://make.powerapps.com/connectionsMcp?connectorIds=$connectorId&environmentName=$EnvironmentId"
    Write-Host ""
    Write-Host "  $($t.label) ($($c.properties.displayName), $($t.kind)):" -ForegroundColor Green
    Write-Host "    $url"
    $found += [pscustomobject]@{ server = $t.server; connectorId = $connectorId; environmentId = $EnvironmentId; url = $url; verified = ($source -ne 'scan'); source = $source }
}
Write-Host ""
Write-Host "Fallback (lists every connector needing a connection): https://make.powerapps.com/connectionsMcp?environmentName=$EnvironmentId"
if ($PassThru) { return $found }
