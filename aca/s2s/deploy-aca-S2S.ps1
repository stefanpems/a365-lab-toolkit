#requires -Version 5.1
# Deploy the S2S (Service-to-Service) agent "AgentFrameworkS2SSample" to Azure Container Apps.
# The agent acts with its OWN application identity (client credentials) via a service connection.
# Region fissa: polandcentral (verificata con capacity). Riusa il LAW agentframework-logs.
# Uso:
#   .\deploy-aca-S2S.ps1 -ClientSecret '<blueprint client secret in cleartext>'
# Il secret NON e' hardcoded: recuperabile con 'a365 setup blueprint --show-secret'.
param(
    [Parameter(Mandatory = $true)]
    [string]$ClientSecret
)
$ErrorActionPreference = 'Stop'

# Console UTF-8: evita UnicodeEncodeError (cp1252) nello streaming log di 'az acr build'.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"

# ============================ Parametri ============================
$RG        = "agentframework-S2S-rg-pl"
# NB: Container App names must be lowercase (Azure does not allow uppercase).
$APP       = "agentframework-s2s-sample"
$ENVNAME   = "agentframework-S2S-env"
$LOC       = "polandcentral"
$IMAGE_TAG = "v1"
$IMAGE     = "agentframework-s2s-sample:$IMAGE_TAG"

# Log Analytics workspace da RIUSARE (creato nella sessione precedente)
$LAW_RG    = "agentframework-rg-pl"
$LAW_NAME  = "agentframework-logs"
# ==================================================================

# --- 1. Provider (idempotente) ---
az provider register -n Microsoft.App --wait
az provider register -n Microsoft.OperationalInsights --wait
az provider register -n Microsoft.ContainerRegistry --wait

# --- 2. Resource group S2S ---
if ((az group exists -n $RG) -ne "true") {
    Write-Host "Creo il resource group '$RG' in '$LOC'..." -ForegroundColor Cyan
    az group create -n $RG -l $LOC | Out-Null
}

# --- 3. Recupera credenziali del LAW da riusare ---
Write-Host "Recupero credenziali del Log Analytics workspace '$LAW_NAME'..." -ForegroundColor Cyan
$lawId  = az monitor log-analytics workspace show -g $LAW_RG -n $LAW_NAME --query customerId -o tsv
$lawKey = az monitor log-analytics workspace get-shared-keys -g $LAW_RG -n $LAW_NAME --query primarySharedKey -o tsv

# --- 4. Container Apps environment (log-analytics = reused LAW) ---
$envExists = az containerapp env show -n $ENVNAME -g $RG --query name -o tsv 2>$null
if (-not $envExists) {
    Write-Host "Creo l'environment ACA '$ENVNAME' collegato al LAW '$LAW_NAME'..." -ForegroundColor Cyan
    az containerapp env create -n $ENVNAME -g $RG -l $LOC `
        --logs-destination log-analytics `
        --logs-workspace-id $lawId --logs-workspace-key $lawKey | Out-Null
}

# --- 5. Azure Container Registry + build immagine dal Dockerfile ---
$acrName = az acr list -g $RG --query "[0].name" -o tsv 2>$null
if (-not $acrName) {
    $acrName = "afs2sacr" + (Get-Random -Minimum 10000 -Maximum 99999)
    Write-Host "Creo l'ACR '$acrName'..." -ForegroundColor Cyan
    az acr create -n $acrName -g $RG --sku Basic --admin-enabled true | Out-Null
}
Write-Host "Building image '$IMAGE' via ACR '$acrName'..." -ForegroundColor Cyan
az acr build -r $acrName -t $IMAGE . | Out-Null

$acrServer = az acr show -n $acrName -g $RG --query loginServer -o tsv
$acrUser   = az acr credential show -n $acrName -g $RG --query username -o tsv
$acrPass   = az acr credential show -n $acrName -g $RG --query "passwords[0].value" -o tsv

# --- 6. Config blueprint + credenziali LLM ---
$cfg      = Get-Content a365.generated.config.json | ConvertFrom-Json
$clientId = $cfg.agentBlueprintId
$tenantId = az account show --query tenantId -o tsv

$m = @{}
Get-Content env/.env.playground.user |
    Where-Object { $_ -match '=' -and $_ -notmatch '^\s*#' } |
    ForEach-Object { $k, $v = $_ -split '=', 2; $m[$k.Trim()] = $v.Trim() }

# --- 7. Crea/aggiorna la Container App ---
Write-Host "Deploying Container App '$APP' in '$LOC'..." -ForegroundColor Cyan
$appExists = az containerapp show -n $APP -g $RG --query name -o tsv 2>$null
if ($appExists) {
    az containerapp registry set -n $APP -g $RG --server $acrServer --username $acrUser --password $acrPass | Out-Null
    az containerapp secret set -n $APP -g $RG --secrets "blueprint-secret=$ClientSecret" | Out-Null
    az containerapp update -n $APP -g $RG --image "$acrServer/$IMAGE" | Out-Null
}
else {
    az containerapp create `
        --name $APP --resource-group $RG --environment $ENVNAME `
        --image "$acrServer/$IMAGE" `
        --registry-server $acrServer --registry-username $acrUser --registry-password $acrPass `
        --target-port 3978 --ingress external `
        --min-replicas 1 --max-replicas 1 `
        --secrets "blueprint-secret=$ClientSecret" `
        --env-vars `
            "PORT=3978" `
            "HOST=0.0.0.0" `
            "PYTHONUTF8=1" `
            "AZURE_OPENAI_ENDPOINT=$($m['AZURE_OPENAI_ENDPOINT'])" `
            "AZURE_OPENAI_API_KEY=$($m['SECRET_AZURE_OPENAI_API_KEY'])" `
            "AZURE_OPENAI_DEPLOYMENT=$($m['AZURE_OPENAI_DEPLOYMENT_NAME'])" `
            "AZURE_OPENAI_API_VERSION=$($m['AZURE_OPENAI_API_VERSION'])" `
            "USE_AGENTIC_AUTH=false" `
            "CONNECTIONSMAP__0__SERVICEURL=*" `
            "CONNECTIONSMAP__0__CONNECTION=service_connection" `
            "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID=$clientId" `
            "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET=secretref:blueprint-secret" `
            "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID=$tenantId" | Out-Null
}

# --- 8. Output URL + prossimo passo ---
$fqdn = az containerapp show -n $APP -g $RG --query properties.configuration.ingress.fqdn -o tsv
Write-Host ""
Write-Host "Deploy completato." -ForegroundColor Green
Write-Host "Messaging endpoint: https://$fqdn/api/messages"
Write-Host "Health:             https://$fqdn/api/health"
Write-Host ""
Write-Host "Prossimo passo: registra l'endpoint sul blueprint:"
Write-Host "  a365 setup blueprint --endpoint-only --messaging-endpoint `"https://$fqdn/api/messages`""
