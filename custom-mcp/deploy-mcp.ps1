#requires -Version 5.1
<#
.SYNOPSIS
  Deploy the Agent 365 sample custom MCP server to Azure Container Apps (resource-safe).
.DESCRIPTION
  Builds the image in the cloud (az acr build — no local Docker) and deploys a Container App
  with EXTERNAL ingress on port 8000. Hosts both MCP servers:
    https://<fqdn>/anon/mcp   (register with auth-type NoAuth)
    https://<fqdn>/auth/mcp   (register with auth-type EntraOAuth)

  This script is RESOURCE-SAFE: it creates the resource group / environment / registry if they
  are missing and reuses them otherwise. It never deletes a resource group.

  The $RG / $APP / $ENVNAME / $LOC constants below are rewritten by the wizard scaffolder from the
  deployment plan. You can also run it as-is and edit them here.
.PARAMETER Subscription
  Target subscription id. Pinned on every az command so a concurrent 'az account set' cannot hijack it.
.PARAMETER AuthClientId
  (Optional) Entra app client id for the /auth server's propagate_to_graph (On-Behalf-Of). Enables
  the advanced credential-propagation test.
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
$RG      = "sample-mcp-rg"
$APP     = "sample-mcp-ca"
$ENVNAME = "sample-mcp-cae"
$LOC     = "centralus"
$IMAGE   = "sample-mcp:1.0.0"
# ---------------------------------------------------------------------------------------------

$SubArg = @('--subscription', $Subscription)

Write-Host "Deploying custom MCP server to RG '$RG' ($LOC), app '$APP'..." -ForegroundColor Cyan
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
Write-Host "Building image on ACR '$acr'..." -ForegroundColor Cyan
az acr build --registry $acr --image $IMAGE @SubArg . | Out-Null

# Container Apps environment (create if absent; reused otherwise).
if (-not (az containerapp env show -n $ENVNAME -g $RG @SubArg 2>$null)) {
    az containerapp env create -n $ENVNAME -g $RG -l $LOC --logs-destination none @SubArg | Out-Null
}

# Optional: propagate_to_graph credentials for the /auth server.
$envVars = @('PORT=8000', 'FASTMCP_HTTP_HOST_ORIGIN_PROTECTION=false')
if ($AuthClientId -and $AuthTenantId) {
    $secret = Read-Host "Enter the auth app client secret for propagate_to_graph (leave blank to skip)" -AsSecureString
    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret))
    if ($plain) {
        $envVars += "MCP_AUTH_CLIENT_ID=$AuthClientId"
        $envVars += "MCP_AUTH_TENANT_ID=$AuthTenantId"
        $envVars += "MCP_AUTH_CLIENT_SECRET=$plain"
    }
}

# Deploy / update the Container App with external ingress on port 8000.
$acrServer = "$acr.azurecr.io"
if (az containerapp show -n $APP -g $RG @SubArg 2>$null) {
    az containerapp update -n $APP -g $RG --image "$acrServer/$IMAGE" --set-env-vars @envVars @SubArg | Out-Null
} else {
    az containerapp create `
        -n $APP -g $RG --environment $ENVNAME `
        --image "$acrServer/$IMAGE" `
        --registry-server $acrServer --registry-identity system `
        --target-port 8000 --ingress external `
        --min-replicas 1 --max-replicas 2 `
        --env-vars @envVars @SubArg | Out-Null
}

$fqdn = az containerapp show -n $APP -g $RG @SubArg --query properties.configuration.ingress.fqdn -o tsv
Write-Host ""
Write-Host "MCP server deployed." -ForegroundColor Green
Write-Host "  Anonymous (NoAuth)   : https://$fqdn/anon/mcp"
Write-Host "  Authenticated (Entra): https://$fqdn/auth/mcp"
Write-Host "  Health               : https://$fqdn/health"
