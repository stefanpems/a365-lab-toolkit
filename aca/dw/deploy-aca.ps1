#requires -Version 5.1
# Cleanup + (re)deploy the agent to Azure Container Apps in a region with capacity.
# Usage: from a PowerShell terminal in the project folder -> .\deploy-aca.ps1
$ErrorActionPreference = 'Stop'

# ============================ Parameters ============================
$RG      = "agentframework-rg-pl"
$APP     = "agentframework-sample"
$ENVNAME = "agentframework-env"
$SUB     = ""   # optional: subscription name/ID. Empty = current subscription

# Regions to try in order. polandcentral verified with capacity (2026-07-07).
$REGIONS = @(
    "polandcentral","italynorth","spaincentral","switzerlandnorth",
    "germanywestcentral","norwayeast","francecentral","uksouth",
    "northeurope","swedencentral","westeurope",
    "eastus2","centralus","westus3"
)
# ==================================================================

if ($SUB) { az account set --subscription $SUB }

# --- 1. Cleanup: delete the previous resource group (removes partial env/workspace) ---
if ((az group exists -n $RG) -eq "true") {
    Write-Host "Deleting resource group '$RG' and all its contents..." -ForegroundColor Yellow
    az group delete -n $RG --yes
}

# --- 2. Providers (idempotent) ---
az provider register -n Microsoft.App --wait
az provider register -n Microsoft.OperationalInsights --wait

# --- 3. Find a region with capacity by creating the ACA environment ---
$LOC = $null
foreach ($r in $REGIONS) {
    Write-Host "`n=== Trying region '$r' ===" -ForegroundColor Cyan
    if ((az group exists -n $RG) -eq "true") { az group delete -n $RG --yes }
    az group create -n $RG -l $r | Out-Null

    az containerapp env create -n $ENVNAME -g $RG -l $r --logs-destination none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Capacity OK in '$r'." -ForegroundColor Green
        $LOC = $r
        break
    }
    Write-Host "Region '$r' has no capacity (or error). Trying the next one..." -ForegroundColor DarkYellow
}

if (-not $LOC) {
    Write-Error "No tried region has capacity for the ACA environment. Add regions to `$REGIONS or retry later."
    exit 1
}

# --- 4. Read blueprint credentials + LLM config (kept in the terminal, not printed) ---
$cfg          = Get-Content a365.generated.config.json | ConvertFrom-Json
$clientId     = $cfg.agentBlueprintId
$tenantId     = az account show --query tenantId -o tsv
# NB: a365.generated.config.json holds the DPAPI-encrypted secret (Windows only).
# The CLEARTEXT secret from 'a365 setup blueprint --show-secret' is required.
$clientSecret = Read-Host "Paste the CLEARTEXT blueprint client secret (a365 setup blueprint --show-secret)"

$m = @{}
Get-Content env/.env.playground.user |
    Where-Object { $_ -match '=' -and $_ -notmatch '^\s*#' } |
    ForEach-Object { $k,$v = $_ -split '=',2; $m[$k.Trim()] = $v.Trim() }

# --- 5. Deploy to Azure Container Apps (build from the Dockerfile via ACR) ---
Write-Host "Deploying Container App '$APP' in '$LOC'..." -ForegroundColor Cyan
az containerapp up `
  --name $APP --resource-group $RG --location $LOC --environment $ENVNAME `
  --source . --target-port 3978 --ingress external `
  --env-vars `
    "PORT=3978" `
    "HOST=0.0.0.0" `
    "PYTHON_ENVIRONMENT=Production" `
    "AZURE_OPENAI_ENDPOINT=$($m['AZURE_OPENAI_ENDPOINT'])" `
    "AZURE_OPENAI_API_KEY=$($m['SECRET_AZURE_OPENAI_API_KEY'])" `
    "AZURE_OPENAI_DEPLOYMENT=$($m['AZURE_OPENAI_DEPLOYMENT_NAME'])" `
    "AZURE_OPENAI_API_VERSION=$($m['AZURE_OPENAI_API_VERSION'])" `
    "AUTH_HANDLER_NAME=AGENTIC" `
    "USE_AGENTIC_AUTH=true" `
    "AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__TYPE=AgenticUserAuthorization" `
    "AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__SETTINGS__SCOPES=ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/.default" `
    "AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__SETTINGS__ALT_BLUEPRINT_NAME=SERVICE_CONNECTION" `
    "CONNECTIONSMAP__0__SERVICEURL=*" `
    "CONNECTIONSMAP__0__CONNECTION=SERVICE_CONNECTION" `
    "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID=$clientId" `
    "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET=$clientSecret" `
    "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID=$tenantId"

# --- 6. Output URL + next step ---
$fqdn = az containerapp show -n $APP -g $RG --query properties.configuration.ingress.fqdn -o tsv
Write-Host ""
Write-Host "Deploy complete." -ForegroundColor Green
Write-Host "Messaging endpoint: https://$fqdn/api/messages"
Write-Host "Health:             https://$fqdn/api/health"
Write-Host ""
Write-Host "Register the endpoint on the blueprint with:"
Write-Host "  a365 setup blueprint --endpoint-only --messaging-endpoint `"https://$fqdn/api/messages`""
