#requires -Version 5.1
<#
.SYNOPSIS
    Clean up the Entra apps and Power Platform connectors a FAILED custom-MCP registration leaves behind.

.DESCRIPTION
    `a365 develop-mcp register-external-mcp-server` creates two Entra proxy apps
    (`ext_<Name>Anon-A365Proxy`, `ext_<Name>Anon-PublicClients`) and one or more Power Platform
    custom connectors BEFORE it calls the MOS/AddMcpServer API. When that later call fails, the CLI
    prints "All created resources have been cleaned up" but in practice it does NOT roll back the
    Entra proxy apps (it says so explicitly) and sometimes leaves the connectors too. On the next
    attempt the leftover connector causes a deterministic `HTTP 400` ("Failed to create connector
    shared_ext_<Name>...P"). This script removes those leftovers so a retry starts clean.

    It ONLY deletes artifacts whose name matches the registration of the given <Name>
    (`ext_<Name>Anon*` / `ext_<Name>Auth*`). It never touches anything else.

.PARAMETER Name
    The custom MCP <Name> (as in the wizard). Matches `ext_<Name>Anon*` and `ext_<Name>Auth*`.

.PARAMETER Subscription
    Target subscription id (pins the az context before Graph/Power Platform calls).

.PARAMETER TenantId
    Target tenant id. Used only to sanity-check the signed-in az context.

.PARAMETER WhatIf
    List what would be deleted without deleting anything.

.EXAMPLE
    ./cleanup-registration.ps1 -Name h2256 -Subscription <sub> -TenantId <tenant>
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)] [string]$Name,
    [Parameter(Mandatory = $true)] [string]$Subscription,
    [string]$TenantId
)
$ErrorActionPreference = 'Stop'

az account set --subscription $Subscription | Out-Null
$ctxTenant = az account show --query tenantId -o tsv
if ($TenantId -and $ctxTenant -ne $TenantId) {
    throw "az context tenant '$ctxTenant' != -TenantId '$TenantId'. Re-pin and retry."
}
$who = az ad signed-in-user show --query userPrincipalName -o tsv 2>$null
Write-Host "Cleanup for MCP '<Name>=$Name' as '$who' (tenant $ctxTenant)." -ForegroundColor Cyan

function ConvertFrom-JsonSafe {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $t = $Text.Trim()
    if (-not ($t.StartsWith('[') -or $t.StartsWith('{'))) { return @() }
    try { return ($t | ConvertFrom-Json) } catch { return @() }
}

# --- 1. Delete the Entra proxy app registrations the CLI does NOT roll back. ---
# Names follow: ext_<Name>Anon-A365Proxy, ext_<Name>Anon-PublicClients (and the Auth variants).
$appPrefixes = @("ext_${Name}Anon", "ext_${Name}Auth")
foreach ($prefix in $appPrefixes) {
    $raw = az ad app list --filter "startswith(displayName,'$prefix-')" --query "[].{id:appId, name:displayName}" -o json 2>$null
    $apps = ConvertFrom-JsonSafe ([string]$raw)
    foreach ($app in $apps) {
        if ($PSCmdlet.ShouldProcess($app.name, "az ad app delete")) {
            az ad app delete --id $app.id 2>&1 | Out-Null
            Write-Host "  deleted Entra app '$($app.name)' ($($app.id))" -ForegroundColor Green
        }
        else {
            Write-Host "  [WhatIf] would delete Entra app '$($app.name)' ($($app.id))" -ForegroundColor Yellow
        }
    }
}

# --- 2. Delete leftover Power Platform custom connectors for this <Name>. ---
# The registration creates connectors whose displayName is 'ext_<Name>Anon' / 'ext_<Name>AnonP'
# (and the Auth variants). A leftover 'P' connector is what triggers the retry HTTP 400.
$ppResource = "https://service.powerapps.com/"
$envs = az rest --method get --url "https://api.powerapps.com/providers/Microsoft.PowerApps/environments?api-version=2016-11-01" --resource $ppResource --query "value[].name" -o tsv 2>$null
foreach ($envId in $envs) {
    $listUrl = "https://api.powerapps.com/providers/Microsoft.PowerApps/apis?api-version=2016-11-01&`$filter=environment eq '$envId'"
    $conns = az rest --method get --url $listUrl --resource $ppResource --query "value[?starts_with(properties.displayName,'ext_$Name')].{name:name, display:properties.displayName}" -o json 2>$null
    foreach ($conn in (ConvertFrom-JsonSafe ([string]$conns))) {
        $delUrl = "https://api.powerapps.com/providers/Microsoft.PowerApps/apis/$($conn.name)?api-version=2016-11-01&`$filter=environment eq '$envId'"
        if ($PSCmdlet.ShouldProcess("$($conn.display) [$envId]", "delete connector")) {
            az rest --method delete --url $delUrl --resource $ppResource 2>&1 | Out-Null
            Write-Host "  deleted connector '$($conn.display)' in env $envId" -ForegroundColor Green
        }
        else {
            Write-Host "  [WhatIf] would delete connector '$($conn.display)' in env $envId" -ForegroundColor Yellow
        }
    }
}

Write-Host "Cleanup complete. You can now retry 'a365 develop-mcp register-external-mcp-server'." -ForegroundColor Cyan
