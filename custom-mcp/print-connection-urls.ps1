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
  Optional Power Platform environment id. Defaults to the tenant's default environment.
.EXAMPLE
  .\print-connection-urls.ps1 -Name a09081
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

# The ext_<name> connectors can live in a NON-default Power Platform environment (e.g. a compliant
# container). If no environment is given, search every environment for the one that actually has them.
$apis = @()
if ($EnvironmentId) {
    $apis = Get-Apis $EnvironmentId
} else {
    $envs = Invoke-RestMethod -Uri "https://api.powerapps.com/providers/Microsoft.PowerApps/environments?api-version=2016-11-01" -Headers $hdr
    foreach ($e in $envs.value) {
        $a = Get-Apis $e.name
        if ($a | Where-Object { $_.name -like "*ext-5f$slug*" }) { $EnvironmentId = $e.name; $apis = $a; break }
    }
    if (-not $EnvironmentId) { Write-Error "No environment has ext_$Name connectors yet. Register the servers first (or pass -EnvironmentId)."; exit 1 }
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
    $connectorId = $c.name -replace '^shared_', 'shared_tc-'
    $url = "https://make.powerapps.com/connectionsMcp?connectorIds=$connectorId&environmentName=$EnvironmentId"
    $authKind = if ($srv -eq 'Auth') { 'EntraOAuth - prompts an OAuth sign-in' } else { 'NoAuth' }
    Write-Host ""
    Write-Host "  $srv ($($c.properties.displayName), $authKind):" -ForegroundColor Green
    Write-Host "    $url"
}
Write-Host ""
Write-Host "Fallback (lists every connector needing a connection): https://make.powerapps.com/connectionsMcp?environmentName=$EnvironmentId"
