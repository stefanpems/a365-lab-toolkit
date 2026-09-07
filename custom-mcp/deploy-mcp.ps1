#requires -Version 5.1
<#
.SYNOPSIS
  Deploy the Agent 365 sample custom MCP server(s) to Azure Container Apps (resource-safe).
.DESCRIPTION
  Builds ONE image in the cloud (az acr build — no local Docker) and deploys ONE Container App PER
  server, each hosting a single MCP server at the ROOT path '/mcp' (selected via MCP_SERVER_MODE):
    anon container -> https://<anon-fqdn>/mcp   (register NoAuth,    ext_<Name>Anon)
    auth container -> https://<auth-fqdn>/mcp   (register EntraOAuth, ext_<Name>Auth)

  WHY one container per server at '/mcp' (NOT one container at /anon/mcp + /auth/mcp): Agent 365
  registration builds a proxy connector from the serverUrl and returns 'HTTP 400: Bad Request' when
  the MCP endpoint is under a MULTI-SEGMENT path such as '/anon/mcp'. A single-segment root '/mcp'
  works. Each container also runs a SINGLE replica (min=max=1): FastMCP streamable-HTTP keeps the MCP
  session in memory per replica, so 2+ replicas break the approval's server validation with
  'Session not found'.

  RESOURCE-SAFE: creates the resource group / environment / registry if missing, reuses otherwise,
  never deletes a resource group.

  The $RG / $ENVNAME / $LOC / $IMAGE / $APP_ANON / $APP_AUTH / $SERVERS constants are rewritten by the
  wizard scaffolder from the deployment plan.
.PARAMETER Subscription
  Target subscription id. Pinned on every az command so a concurrent 'az account set' cannot hijack it.
.PARAMETER AuthClientId
  (Optional) Entra app client id for the AUTH server's propagate_to_graph (On-Behalf-Of).
.PARAMETER AuthTenantId
  (Optional) Entra tenant id for propagate_to_graph.
.NOTES
  The client secret for propagate_to_graph is entered in the terminal (Read-Host), never passed on
  the command line and never stored in the repo.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$Subscription,
    [string]$AuthClientId,
    [string]$AuthTenantId
)
$ErrorActionPreference = 'Stop'

# --- Constants (rewritten by scaffold-from-plan.ps1 from the deployment plan) ----------------
$RG       = "sample-mcp-rg"
$ENVNAME  = "sample-mcp-cae"
$LOC      = "centralus"
$IMAGE    = "sample-mcp:1.0.0"
$APP_ANON = "sample-mcp-anon-ca"
$APP_AUTH = "sample-mcp-auth-ca"
$SERVERS  = @('anon', 'auth')   # which servers (one container each) to deploy
# ---------------------------------------------------------------------------------------------

$SubArg = @('--subscription', $Subscription)
Write-Host "Deploying custom MCP server(s) [$($SERVERS -join ', ')] to RG '$RG' ($LOC)..." -ForegroundColor Cyan
az account set @SubArg | Out-Null

az extension add --name containerapp --upgrade --only-show-errors | Out-Null
az provider register --namespace Microsoft.App --wait @SubArg | Out-Null
az provider register --namespace Microsoft.OperationalInsights --wait @SubArg | Out-Null

# Resource group (create if absent; never deleted).
if (-not (az group show -n $RG @SubArg 2>$null)) {
    az group create -n $RG -l $LOC @SubArg | Out-Null
}

# Azure Container Registry (create a unique one if none exists in the RG).
$acr = az acr list -g $RG @SubArg --query "[0].name" -o tsv 2>$null
if (-not $acr) {
    $acr = ("samplemcp" + (Get-Random -Maximum 99999))
    az acr create -g $RG -n $acr --sku Basic -l $LOC @SubArg | Out-Null
}
$acrServer = "$acr.azurecr.io"
Write-Host "Building image on ACR '$acr' (--no-logs avoids the Windows colorama/cp1252 CLI crash)..." -ForegroundColor Cyan
az acr build --registry $acr --image $IMAGE --no-logs @SubArg . | Out-Null

# Container Apps environment (create if absent; reused otherwise).
if (-not (az containerapp env show -n $ENVNAME -g $RG @SubArg 2>$null)) {
    az containerapp env create -n $ENVNAME -g $RG -l $LOC --logs-destination none @SubArg | Out-Null
}

function Deploy-McpContainer {
    param([string]$App, [string]$Mode, [string[]]$ExtraEnv)
    # Single replica (min=max=1): FastMCP keeps the MCP session in memory per replica.
    $envVars = @("PORT=8000", "FASTMCP_HTTP_HOST_ORIGIN_PROTECTION=false", "MCP_SERVER_MODE=$Mode") + $ExtraEnv
    if (az containerapp show -n $App -g $RG @SubArg 2>$null) {
        az containerapp update -n $App -g $RG --image "$acrServer/$IMAGE" --min-replicas 1 --max-replicas 1 --set-env-vars @envVars @SubArg | Out-Null
    } else {
        az containerapp create `
            -n $App -g $RG --environment $ENVNAME `
            --image "$acrServer/$IMAGE" `
            --registry-server $acrServer --registry-identity system `
            --target-port 8000 --ingress external `
            --min-replicas 1 --max-replicas 1 `
            --env-vars @envVars @SubArg | Out-Null
    }
    return (az containerapp show -n $App -g $RG @SubArg --query properties.configuration.ingress.fqdn -o tsv)
}

# propagate_to_graph credentials go on the AUTH container only.
# The AUTH server also advertises OAuth 2.0 Protected Resource Metadata (RFC 9728) so the Agent 365
# gateway forwards a caller bearer token. The PRM needs the tenant id + scope, so set them ALWAYS
# (independent of the optional propagate_to_graph secret) BEFORE the server is registered — the
# gateway captures the auth type into the Power Platform connector at registration time.
$authTenant = if ($AuthTenantId) { $AuthTenantId } else { az account show --query tenantId -o tsv @SubArg }
$authEnv = @("MCP_AUTH_TENANT_ID=$authTenant", "MCP_AUTH_SCOPE=access_as_agent")
if ($AuthClientId -and $AuthTenantId) {
    $secret = Read-Host "Enter the auth app client secret for propagate_to_graph (leave blank to skip)" -AsSecureString
    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret))
    if ($plain) {
        $authEnv += @("MCP_AUTH_CLIENT_ID=$AuthClientId", "MCP_AUTH_CLIENT_SECRET=$plain")
    }
}

$anonFqdn = $null; $authFqdn = $null
if ($SERVERS -contains 'anon') { $anonFqdn = Deploy-McpContainer -App $APP_ANON -Mode 'anon' -ExtraEnv @() }
if ($SERVERS -contains 'auth') { $authFqdn = Deploy-McpContainer -App $APP_AUTH -Mode 'auth' -ExtraEnv $authEnv }

Write-Host ""
Write-Host "MCP server(s) deployed (register each with its /mcp URL — single-segment path is required)." -ForegroundColor Green
if ($anonFqdn) { Write-Host "  Anonymous (NoAuth)    : https://$anonFqdn/mcp" }
if ($authFqdn) { Write-Host "  Authenticated (Entra) : https://$authFqdn/mcp" }

