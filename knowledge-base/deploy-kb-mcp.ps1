#requires -Version 5.1
<#
.SYNOPSIS
  Build and deploy the knowledge-base MCP shim to Azure Container Apps, and emit the
  register-kb.json payload for Agent 365. STANDALONE — not part of Lab Builder. Step 3.

.DESCRIPTION
  Builds the kb-mcp image in the cloud (az acr build — no local Docker) and deploys ONE Container
  App hosting the MCP server at the ROOT path '/mcp'. The read-only Azure AI Search query key is
  passed as a Container App SECRET (never on the command line, never committed). Single replica
  (min=max=1) because FastMCP keeps the streamable-HTTP session in memory per replica.

  Reuses the values recorded in kb.state.json by provision-search.ps1 and appends the deployed
  FQDN / app / server name. Resources are tagged a365component=knowledge-base (never a365lab).

.PARAMETER ServerName
  Agent 365 external server name to register later (e.g. ext_Docs4AgentsKb). Letters/digits only
  after the ext_ prefix.
.PARAMETER Publisher
  Publisher display name used in the registration payload.
#>
[CmdletBinding()]
param(
    [string]$ServerName = 'ext_Docs4AgentsKb',
    [string]$Publisher = 'Agent 365 Lab'
)
$ErrorActionPreference = 'Stop'
$stateFile = Join-Path $PSScriptRoot 'kb.state.json'
if (-not (Test-Path $stateFile)) { throw "kb.state.json not found. Run provision-search.ps1 (and ingest) first." }
$state = Get-Content $stateFile -Raw | ConvertFrom-Json

$Subscription = $state.subscription
$RG           = $state.resourceGroup
$LOC          = $state.location
$SubArg       = @('--subscription', $Subscription)
$IMAGE        = 'kb-mcp:1.0.0'
$APP          = 'kb-mcp-ca'

Write-Host "Deploying knowledge-base MCP shim to RG '$RG' ($LOC)..." -ForegroundColor Cyan
az account set @SubArg | Out-Null
az extension add --name containerapp --upgrade --only-show-errors | Out-Null
az provider register --namespace Microsoft.App --wait @SubArg | Out-Null
az provider register --namespace Microsoft.OperationalInsights --wait @SubArg | Out-Null

# Azure Container Registry (reuse one in the RG, else create).
$acr = az acr list -g $RG @SubArg --query "[0].name" -o tsv 2>$null
if (-not $acr) {
    $acr = ("kbmcp" + (Get-Random -Maximum 99999))
    az acr create -g $RG -n $acr --sku Basic -l $LOC @SubArg | Out-Null
}
$acrServer = "$acr.azurecr.io"
Write-Host "Building image on ACR '$acr'..." -ForegroundColor Cyan
Push-Location (Join-Path $PSScriptRoot 'kb-mcp')
try {
    az acr build --registry $acr --image $IMAGE --no-logs @SubArg . | Out-Null
} finally {
    Pop-Location
}

# Container Apps environment (create if absent).
$ENVNAME = 'kb-mcp-cae'
if (-not (az containerapp env show -n $ENVNAME -g $RG @SubArg 2>$null)) {
    az containerapp env create -n $ENVNAME -g $RG -l $LOC --logs-destination none @SubArg | Out-Null
}

$envVars = @(
    "PORT=8000",
    "FASTMCP_HTTP_HOST_ORIGIN_PROTECTION=false",
    "SEARCH_ENDPOINT=$($state.searchEndpoint)",
    "SEARCH_INDEX=$($state.indexName)",
    "SEARCH_QUERY_KEY=secretref:search-query-key"
)
if (az containerapp show -n $APP -g $RG @SubArg 2>$null) {
    az containerapp secret set -n $APP -g $RG --secrets "search-query-key=$($state.queryKey)" @SubArg | Out-Null
    az containerapp update -n $APP -g $RG --image "$acrServer/$IMAGE" `
        --min-replicas 1 --max-replicas 1 --set-env-vars @envVars @SubArg | Out-Null
} else {
    az containerapp create `
        -n $APP -g $RG --environment $ENVNAME `
        --image "$acrServer/$IMAGE" `
        --registry-server $acrServer --registry-identity system `
        --target-port 8000 --ingress external `
        --min-replicas 1 --max-replicas 1 `
        --secrets "search-query-key=$($state.queryKey)" `
        --env-vars @envVars @SubArg | Out-Null
}
$fqdn = az containerapp show -n $APP -g $RG @SubArg --query properties.configuration.ingress.fqdn -o tsv
$mcpUrl = "https://$fqdn/mcp"

# Persist deploy outputs to the state file.
function Set-StateProp($obj, $name, $value) {
    if ($obj.PSObject.Properties[$name]) { $obj.$name = $value } else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}
Set-StateProp $state 'mcpApp'     $APP
Set-StateProp $state 'mcpFqdn'    $fqdn
Set-StateProp $state 'mcpUrl'     $mcpUrl
Set-StateProp $state 'serverName' $ServerName
$state | ConvertTo-Json -Depth 8 | Set-Content $stateFile -Encoding utf8

# Render the registration payload from the template.
$tpl = Get-Content (Join-Path $PSScriptRoot 'register-kb.template.json') -Raw
$tpl = $tpl.Replace('<SERVER_NAME>', $ServerName).Replace('<MCP_URL>', $mcpUrl).Replace('<PUBLISHER>', $Publisher)
$outFile = Join-Path $PSScriptRoot 'register-kb.json'
$tpl | Set-Content $outFile -Encoding utf8

Write-Host ""
Write-Host "Knowledge-base MCP shim deployed." -ForegroundColor Green
Write-Host "  MCP URL     : $mcpUrl"
Write-Host "  Server name : $ServerName"
Write-Host "  Registration: $outFile"
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "  1. a365 develop-mcp register-external-mcp-server -f `"$outFile`" --dry-run"
Write-Host "  2. a365 develop-mcp register-external-mcp-server -f `"$outFile`""
Write-Host "  3. Approve the tool in the M365 admin center (Agents > Tools)."
Write-Host "  4. ./attach-to-lab.ps1 -LabPrefix <lab>   (attach to all OBO/S2S agents)"
