#requires -Version 5.1
# Deploy the AI Teammate agent "AgentFrameworkDWSample" to Azure Container Apps.
# Fixed region: polandcentral (verified with capacity). Self-contained LAW (created in the DW RG).
# Usage:
#   .\deploy-aca-DW.ps1 -ClientSecret '<blueprint client secret cleartext>' `
#       -Subscription <TARGET_SUB> -AoaiRg <AOAI_RG> -AoaiAcc <AOAI_ACCOUNT>
# Subscription/AoaiRg/AoaiAcc fall back to $env:DEPLOY_SUB / DEPLOY_AOAI_RG / DEPLOY_AOAI_ACC,
# so no tenant-specific value is committed. The secret is NOT hardcoded:
# retrieve it with 'a365 setup blueprint --show-secret'.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClientSecret,
    [string]$Subscription = $env:DEPLOY_SUB,
    [string]$AoaiRg       = $env:DEPLOY_AOAI_RG,
    [string]$AoaiAcc      = $env:DEPLOY_AOAI_ACC
)
$ErrorActionPreference = 'Stop'

# Console UTF-8: avoids UnicodeEncodeError (cp1252) in the 'az acr build' log stream.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"

# ============================ Parameters ============================
$RG        = "agentframework-DW-rg-pl"
# NB: Container App names must be lowercase (Azure does not allow uppercase).
$APP       = "agentframework-dw-sample"
$ENVNAME   = "agentframework-DW-env"
$LOC       = "polandcentral"
$IMAGE_TAG = "v1"
$IMAGE     = "agentframework-dw-sample:$IMAGE_TAG"
# SELF-CONTAINED Log Analytics workspace (created in this RG, no external dependency).
$LAW_NAME  = "agentframework-DW-logs"
# Azure OpenAI with Entra ID auth (needed if the sub disables key auth):
$AOAI_RG   = $AoaiRg    # e.g. 'agentframework-aoai-rg' (empty = skip MI/role, use the key)
$AOAI_ACC  = $AoaiAcc   # e.g. Azure OpenAI account name (empty = skip MI/role, use the key)
# ==================================================================

# Concurrency-safe subscription pinning: resolve the subscription ONCE and pass it explicitly
# (--subscription $SUB, splat @SubArg) on EVERY az command, to protect against a parallel session
# that flips the shared az context mid-deploy.
if (-not $Subscription) {
    $Subscription = az account show --query id -o tsv
    Write-Host "No -Subscription given: pinning to current az context '$Subscription'." -ForegroundColor Yellow
}
$SUB = $Subscription
$SubArg = @('--subscription', $SUB)
az account set --subscription $SUB
$acct = az account show --subscription $SUB --query "{name:name,id:id,tenantId:tenantId,user:user.name}" -o json | ConvertFrom-Json
Write-Host "Target subscription: $($acct.name) [$($acct.id)] tenant $($acct.tenantId) as $($acct.user)" -ForegroundColor Green

# --- 1. Providers (idempotent) ---
az provider register -n Microsoft.App --wait @SubArg
az provider register -n Microsoft.OperationalInsights --wait @SubArg
az provider register -n Microsoft.ContainerRegistry --wait @SubArg

# --- 2. DW resource group ---
if ((az group exists -n $RG @SubArg) -ne "true") {
    Write-Host "Creating resource group '$RG' in '$LOC'..." -ForegroundColor Cyan
    az group create -n $RG -l $LOC @SubArg | Out-Null
}

# --- 3. Self-contained Log Analytics workspace ---
$lawId = az monitor log-analytics workspace show -g $RG -n $LAW_NAME --query customerId -o tsv @SubArg 2>$null
if (-not $lawId) {
    Write-Host "Creating Log Analytics workspace '$LAW_NAME'..." -ForegroundColor Cyan
    az monitor log-analytics workspace create -g $RG -n $LAW_NAME -l $LOC @SubArg | Out-Null
    $lawId = az monitor log-analytics workspace show -g $RG -n $LAW_NAME --query customerId -o tsv @SubArg
}
$lawKey = az monitor log-analytics workspace get-shared-keys -g $RG -n $LAW_NAME --query primarySharedKey -o tsv @SubArg

# --- 4. Container Apps environment (log-analytics = self-contained LAW) ---
$envExists = az containerapp env show -n $ENVNAME -g $RG --query name -o tsv @SubArg 2>$null
if (-not $envExists) {
    Write-Host "Creating ACA environment '$ENVNAME' linked to LAW '$LAW_NAME'..." -ForegroundColor Cyan
    az containerapp env create -n $ENVNAME -g $RG -l $LOC `
        --logs-destination log-analytics `
        --logs-workspace-id $lawId --logs-workspace-key $lawKey @SubArg | Out-Null
}

# --- 5. Azure Container Registry + build image from the Dockerfile ---
$acrName = az acr list -g $RG --query "[0].name" -o tsv @SubArg 2>$null
if (-not $acrName) {
    $acrName = "afdwacr" + (Get-Random -Minimum 10000 -Maximum 99999)
    Write-Host "Creating ACR '$acrName'..." -ForegroundColor Cyan
    az acr create -n $acrName -g $RG --sku Basic --admin-enabled true @SubArg | Out-Null
}
Write-Host "Building image '$IMAGE' via ACR '$acrName'..." -ForegroundColor Cyan
# --no-logs: avoids the cp1252 crash on the build log stream in the Windows console.
az acr build -r $acrName -t $IMAGE --no-logs . @SubArg | Out-Null

$acrServer = az acr show -n $acrName -g $RG --query loginServer -o tsv @SubArg
$acrUser   = az acr credential show -n $acrName -g $RG --query username -o tsv @SubArg
$acrPass   = az acr credential show -n $acrName -g $RG --query "passwords[0].value" -o tsv @SubArg

# --- 6. Blueprint config + LLM credentials ---
$cfg      = Get-Content a365.generated.config.json | ConvertFrom-Json
$clientId = $cfg.agentBlueprintId
$tenantId = az account show --subscription $SUB --query tenantId -o tsv

$m = @{}
Get-Content env/.env.playground.user |
    Where-Object { $_ -match '=' -and $_ -notmatch '^\s*#' } |
    ForEach-Object { $k, $v = $_ -split '=', 2; $m[$k.Trim()] = $v.Trim() }

# Base env vars. NB: pass the AOAI key ONLY when set: with Entra ID (key auth
# disabled) an empty string "" is interpreted by the openai client as a supplied
# but invalid key -> "Missing credentials" that bypasses managed-identity auth.
$coreEnv = @(
    "PORT=3978"
    "HOST=0.0.0.0"
    "PYTHONUTF8=1"
    "PYTHON_ENVIRONMENT=Production"
    "AZURE_OPENAI_ENDPOINT=$($m['AZURE_OPENAI_ENDPOINT'])"
    "AZURE_OPENAI_DEPLOYMENT=$($m['AZURE_OPENAI_DEPLOYMENT_NAME'])"
    "AZURE_OPENAI_API_VERSION=$($m['AZURE_OPENAI_API_VERSION'])"
    "AUTH_HANDLER_NAME=AGENTIC"
    "USE_AGENTIC_AUTH=true"
    "AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__TYPE=AgenticUserAuthorization"
    "AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__SETTINGS__SCOPES=ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/.default"
    "AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__SETTINGS__ALT_BLUEPRINT_NAME=SERVICE_CONNECTION"
    "CONNECTIONSMAP__0__SERVICEURL=*"
    "CONNECTIONSMAP__0__CONNECTION=SERVICE_CONNECTION"
    "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID=$clientId"
    "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET=secretref:blueprint-secret"
    "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID=$tenantId"
)
if ($m['SECRET_AZURE_OPENAI_API_KEY']) {
    $coreEnv += "AZURE_OPENAI_API_KEY=$($m['SECRET_AZURE_OPENAI_API_KEY'])"
}

# --- 7. Create/update the Container App ---
Write-Host "Deploying Container App '$APP' in '$LOC'..." -ForegroundColor Cyan
$appExists = az containerapp show -n $APP -g $RG --query name -o tsv @SubArg 2>$null
if ($appExists) {
    az containerapp registry set -n $APP -g $RG --server $acrServer --username $acrUser --password $acrPass @SubArg | Out-Null
    az containerapp secret set -n $APP -g $RG --secrets "blueprint-secret=$ClientSecret" @SubArg | Out-Null
    az containerapp update -n $APP -g $RG --image "$acrServer/$IMAGE" --set-env-vars @coreEnv @SubArg | Out-Null
}
else {
    az containerapp create `
        --name $APP --resource-group $RG --environment $ENVNAME `
        --image "$acrServer/$IMAGE" `
        --registry-server $acrServer --registry-username $acrUser --registry-password $acrPass `
        --target-port 3978 --ingress external `
        --min-replicas 1 --max-replicas 1 `
        --secrets "blueprint-secret=$ClientSecret" `
        --env-vars @coreEnv @SubArg | Out-Null
}

# --- 7b. (Entra ID auth for Azure OpenAI) Managed identity + role ---
# Needed when the subscription disables key auth (Azure Policy disableLocalAuth=true):
# the agent uses DefaultAzureCredential and the Container App authenticates with its managed identity.
if ($AOAI_ACC -and $AOAI_RG) {
    Write-Host "Enabling the Container App managed identity and assigning 'Cognitive Services OpenAI User'..." -ForegroundColor Cyan
    $miPrincipal = az containerapp identity assign -n $APP -g $RG --system-assigned --query principalId -o tsv @SubArg
    $aoaiScope = az cognitiveservices account show -n $AOAI_ACC -g $AOAI_RG --query id -o tsv @SubArg
    az role assignment create --assignee-object-id $miPrincipal --assignee-principal-type ServicePrincipal `
        --role "Cognitive Services OpenAI User" --scope $aoaiScope @SubArg | Out-Null
    # Restart the revision so the assigned identity is used immediately.
    $rev = az containerapp show -n $APP -g $RG --query properties.latestRevisionName -o tsv @SubArg
    az containerapp revision restart -n $APP -g $RG --revision $rev @SubArg 2>$null | Out-Null
    Write-Host "Managed identity + role assigned on '$AOAI_ACC'." -ForegroundColor Green
} else {
    Write-Host "AOAI_RG/AOAI_ACC not set: skipping managed identity/role (key path)." -ForegroundColor Yellow
}

# --- 8. Output URL + next step ---
$fqdn = az containerapp show -n $APP -g $RG --query properties.configuration.ingress.fqdn -o tsv @SubArg
Write-Host ""
Write-Host "Deploy completato." -ForegroundColor Green
Write-Host "Messaging endpoint: https://$fqdn/api/messages"
Write-Host "Health:             https://$fqdn/api/health"
Write-Host ""
Write-Host "Prossimo passo: registra l'endpoint sul blueprint:"
Write-Host "  a365 setup blueprint --endpoint-only --messaging-endpoint `"https://$fqdn/api/messages`""
