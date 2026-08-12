#requires -Version 5.1
# Deploy the S2S (Service-to-Service) agent "AgentFrameworkS2SSample" to Azure Container Apps.
# The agent acts with its OWN application identity (client credentials) via a service connection.
#
# Uso (il secret NON e' hardcoded: recuperabile con 'a365 setup blueprint --show-secret'):
#   .\deploy-aca-S2S.ps1 -Subscription '<TARGET_SUB_ID>' -AoaiRg '<AOAI_RG>' -AoaiAcc '<AOAI_ACCOUNT>'
# Il secret viene richiesto interattivo (Read-Host) se non passato con -ClientSecret.
#
# NB CONCORRENZA: il contesto 'az' e' condiviso su disco; se un'altra shell fa 'az account set'
# puo' flippare la subscription. Questo script risolve $SUB una volta e passa --subscription su
# OGNI comando az (@SubArg) per non farsi dirottare.
[CmdletBinding()]
param(
    [string]$ClientSecret,
    [string]$Subscription = $env:DEPLOY_SUB,
    [string]$AoaiRg       = $env:DEPLOY_AOAI_RG,
    [string]$AoaiAcc      = $env:DEPLOY_AOAI_ACC,
    [switch]$ReuseEnv
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
# Log Analytics workspace dedicato (creato in $RG se assente).
$LAW_NAME  = "agentframework-S2S-logs"
# ==================================================================

# --- 0. Risolvi e PINNA la subscription target ---
if (-not $Subscription) {
    $Subscription = az account show --query id -o tsv
    Write-Host "Nessuna -Subscription: uso quella attiva ($Subscription)." -ForegroundColor Yellow
}
$SUB = $Subscription
az account set --subscription $SUB | Out-Null
$SubArg = @('--subscription', $SUB)
$who = az account show --query "user.name" -o tsv @SubArg
Write-Host "Deploy su subscription $SUB (identita': $who)." -ForegroundColor Cyan

# --- 1. Provider (idempotente) ---
az provider register -n Microsoft.App --wait @SubArg
az provider register -n Microsoft.OperationalInsights --wait @SubArg
az provider register -n Microsoft.ContainerRegistry --wait @SubArg

# --- 2. Resource group S2S ---
if ((az group exists -n $RG @SubArg) -ne "true") {
    Write-Host "Creo il resource group '$RG' in '$LOC'..." -ForegroundColor Cyan
    az group create -n $RG -l $LOC @SubArg | Out-Null
}

# --- 3. Log Analytics workspace dedicato (crea in $RG se assente) ---
$lawId = az monitor log-analytics workspace show -g $RG -n $LAW_NAME --query customerId -o tsv @SubArg 2>$null
if (-not $lawId) {
    Write-Host "Creo il Log Analytics workspace '$LAW_NAME' in '$RG'..." -ForegroundColor Cyan
    az monitor log-analytics workspace create -g $RG -n $LAW_NAME -l $LOC @SubArg | Out-Null
    $lawId = az monitor log-analytics workspace show -g $RG -n $LAW_NAME --query customerId -o tsv @SubArg
}
$lawKey = az monitor log-analytics workspace get-shared-keys -g $RG -n $LAW_NAME --query primarySharedKey -o tsv @SubArg

# --- 4. Container Apps environment (log-analytics = LAW dedicato) ---
$envExists = az containerapp env show -n $ENVNAME -g $RG --query name -o tsv @SubArg 2>$null
if (-not $envExists) {
    Write-Host "Creo l'environment ACA '$ENVNAME' collegato al LAW '$LAW_NAME'..." -ForegroundColor Cyan
    az containerapp env create -n $ENVNAME -g $RG -l $LOC `
        --logs-destination log-analytics `
        --logs-workspace-id $lawId --logs-workspace-key $lawKey @SubArg | Out-Null
}
elseif (-not $ReuseEnv) {
    Write-Host "Environment '$ENVNAME' gia' presente (riuso)." -ForegroundColor Yellow
}

# --- 5. Azure Container Registry + build immagine dal Dockerfile ---
$acrName = az acr list -g $RG --query "[0].name" -o tsv @SubArg 2>$null
if (-not $acrName) {
    $acrName = "afs2sacr" + (Get-Random -Minimum 10000 -Maximum 99999)
    Write-Host "Creo l'ACR '$acrName'..." -ForegroundColor Cyan
    az acr create -n $acrName -g $RG --sku Basic --admin-enabled true @SubArg | Out-Null
}
Write-Host "Building image '$IMAGE' via ACR '$acrName'..." -ForegroundColor Cyan
# --no-logs: lo streaming dei log di 'az acr build' va in crash su Windows con
# UnicodeEncodeError (colorama/cp1252) e puo' interrompere lo script. La build gira
# comunque server-side; senza --logs non si rompe.
az acr build -r $acrName -t $IMAGE --no-logs . @SubArg | Out-Null

$acrServer = az acr show -n $acrName -g $RG --query loginServer -o tsv @SubArg
$acrUser   = az acr credential show -n $acrName -g $RG --query username -o tsv @SubArg
$acrPass   = az acr credential show -n $acrName -g $RG --query "passwords[0].value" -o tsv @SubArg

# --- 6. Config blueprint + credenziali LLM ---
$cfg      = Get-Content a365.generated.config.json | ConvertFrom-Json
$clientId = $cfg.agentBlueprintId
$tenantId = az account show --query tenantId -o tsv @SubArg
# Secret in chiaro (a365 setup blueprint --show-secret). Richiesto interattivo se non passato.
if (-not $ClientSecret) { $ClientSecret = Read-Host "Paste the CLEARTEXT blueprint client secret (a365 setup blueprint --show-secret)" }

$m = @{}
$llmEnv = 'env/.env.playground.user'
if (-not (Test-Path $llmEnv)) {
    Write-Error "Manca '$llmEnv': crealo con la config Azure OpenAI (AZURE_OPENAI_ENDPOINT, AZURE_OPENAI_DEPLOYMENT_NAME, AZURE_OPENAI_API_VERSION e SECRET_AZURE_OPENAI_API_KEY vuoto se usi Entra ID). Vedi env/.env.playground.user dell'agente OBO come riferimento."
    exit 1
}
Get-Content $llmEnv |
    Where-Object { $_ -match '=' -and $_ -notmatch '^\s*#' } |
    ForEach-Object { $k, $v = $_ -split '=', 2; $m[$k.Trim()] = $v.Trim() }

# --- 7. Env vars (NON impostare AZURE_OPENAI_API_KEY se vuota: con Entra ID una stringa vuota
#         viene interpretata dal client openai come chiave non valida -> "Missing credentials"). ---
$envVars = @(
    "PORT=3978"
    "HOST=0.0.0.0"
    "PYTHONUTF8=1"
    "AZURE_OPENAI_ENDPOINT=$($m['AZURE_OPENAI_ENDPOINT'])"
    "AZURE_OPENAI_DEPLOYMENT=$($m['AZURE_OPENAI_DEPLOYMENT_NAME'])"
    "AZURE_OPENAI_API_VERSION=$($m['AZURE_OPENAI_API_VERSION'])"
    "USE_AGENTIC_AUTH=false"
    "CONNECTIONSMAP__0__SERVICEURL=*"
    "CONNECTIONSMAP__0__CONNECTION=service_connection"
    "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID=$clientId"
    "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET=secretref:blueprint-secret"
    "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID=$tenantId"
)
if ($m['SECRET_AZURE_OPENAI_API_KEY']) {
    $envVars += "AZURE_OPENAI_API_KEY=$($m['SECRET_AZURE_OPENAI_API_KEY'])"
}

# --- 7b. Crea/aggiorna la Container App ---
Write-Host "Deploying Container App '$APP' in '$LOC'..." -ForegroundColor Cyan
$appExists = az containerapp show -n $APP -g $RG --query name -o tsv @SubArg 2>$null
if ($appExists) {
    az containerapp registry set -n $APP -g $RG --server $acrServer --username $acrUser --password $acrPass @SubArg | Out-Null
    az containerapp secret set -n $APP -g $RG --secrets "blueprint-secret=$ClientSecret" @SubArg | Out-Null
    az containerapp update -n $APP -g $RG --image "$acrServer/$IMAGE" --set-env-vars @envVars @SubArg | Out-Null
}
else {
    az containerapp create `
        --name $APP --resource-group $RG --environment $ENVNAME `
        --image "$acrServer/$IMAGE" `
        --registry-server $acrServer --registry-username $acrUser --registry-password $acrPass `
        --target-port 3978 --ingress external `
        --min-replicas 1 --max-replicas 1 `
        --secrets "blueprint-secret=$ClientSecret" `
        --env-vars @envVars @SubArg | Out-Null
}

# --- 7c. (Entra ID auth per Azure OpenAI) Managed identity + ruolo ---
# Necessario quando la subscription disabilita la key auth (Azure Policy disableLocalAuth=true):
# l'agente usa DefaultAzureCredential e la Container App autentica con la sua managed identity.
if ($AoaiAcc -and $AoaiRg) {
    Write-Host "Abilito la managed identity della Container App e assegno 'Cognitive Services OpenAI User'..." -ForegroundColor Cyan
    $miPrincipal = az containerapp identity assign -n $APP -g $RG --system-assigned --query principalId -o tsv @SubArg
    $aoaiScope = az cognitiveservices account show -n $AoaiAcc -g $AoaiRg --query id -o tsv @SubArg
    az role assignment create --assignee-object-id $miPrincipal --assignee-principal-type ServicePrincipal `
        --role "Cognitive Services OpenAI User" --scope $aoaiScope @SubArg | Out-Null
    # Riavvia la revisione cosi' l'identita' assegnata viene usata subito.
    $rev = az containerapp show -n $APP -g $RG --query properties.latestRevisionName -o tsv @SubArg
    az containerapp revision restart -n $APP -g $RG --revision $rev @SubArg 2>$null | Out-Null
    Write-Host "Managed identity + ruolo assegnati su '$AoaiAcc'." -ForegroundColor Green
}

# --- 8. Output URL + prossimi passi ---
$fqdn = az containerapp show -n $APP -g $RG --query properties.configuration.ingress.fqdn -o tsv @SubArg
Write-Host ""
Write-Host "Deploy completato." -ForegroundColor Green
Write-Host "Messaging endpoint: https://$fqdn/api/messages"
Write-Host "Health:             https://$fqdn/api/health"
Write-Host ""
Write-Host "Prossimi passi:"
Write-Host "  1) Registra l'endpoint sul blueprint (terminale esterno, a365):"
Write-Host "       a365 setup blueprint --endpoint-only --messaging-endpoint `"https://$fqdn/api/messages`""
Write-Host "  2) Web UI: abilita la CORS con l'origine della SWA:"
Write-Host "       az containerapp update -n $APP -g $RG --subscription $SUB --set-env-vars `"UI_ALLOWED_ORIGINS=https://<swa-host>`""
