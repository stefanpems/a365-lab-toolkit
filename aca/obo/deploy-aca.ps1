#requires -Version 5.1
# Cleanup + (re)deploy the agent to Azure Container Apps in a region with capacity.
# Usage: from a PowerShell terminal in the project folder ->
#   .\deploy-aca.ps1 -Subscription <TARGET_SUB_ID> -AoaiRg <AOAI_RG> -AoaiAcc <AOAI_ACCOUNT>
# The blueprint client secret is requested interactively (Read-Host) unless -ClientSecret is passed.
# Subscription/AoaiRg/AoaiAcc also fall back to env vars DEPLOY_SUB / DEPLOY_AOAI_RG / DEPLOY_AOAI_ACC,
# so no tenant-specific value needs to be committed to this file.
[CmdletBinding()]
param(
    [string]$ClientSecret,
    [string]$Subscription = $env:DEPLOY_SUB,
    [string]$AoaiRg       = $env:DEPLOY_AOAI_RG,
    [string]$AoaiAcc      = $env:DEPLOY_AOAI_ACC
)
$ErrorActionPreference = 'Stop'

# ============================ Parametri ============================
$RG      = "agentframework-OBO-rg-pl"
$APP     = "agentframework-obo-sample"
$ENVNAME = "agentframework-OBO-env"
$SUB     = $Subscription   # ID subscription TARGET (via -Subscription o $env:DEPLOY_SUB). Vuoto = subscription corrente (rischioso).
# Azure OpenAI con auth Entra ID (opzionale ma necessario se la sub disabilita la key auth):
# RG e nome dell'account Azure OpenAI su cui assegnare il ruolo alla managed identity.
$AOAI_RG  = $AoaiRg    # es. 'agentframework-aoai-rg' (vuoto = salta MI/ruolo, usa la key)
$AOAI_ACC = $AoaiAcc   # es. il nome dell'account Azure OpenAI (vuoto = salta MI/ruolo, usa la key)

# Region da provare in ordine. polandcentral verificata con capacity (2026-07-07).
$REGIONS = @(
    "polandcentral","italynorth","spaincentral","switzerlandnorth",
    "germanywestcentral","norwayeast","francecentral","uksouth",
    "northeurope","swedencentral","westeurope",
    "eastus2","centralus","westus3"
)
# ==================================================================

# Concurrency-safe subscription pinning: resolve the target subscription ONCE and pass it
# explicitly (--subscription $SUB, splatted as @SubArg) on EVERY az command below. This protects
# against a parallel session flipping the shared az context mid-deploy.
if (-not $SUB) {
    $SUB = az account show --query id -o tsv
    Write-Host "No -Subscription given: pinning to current az context '$SUB'." -ForegroundColor Yellow
}
$SubArg = @('--subscription', $SUB)
az account set --subscription $SUB
$acct = az account show --subscription $SUB --query "{name:name,id:id,tenantId:tenantId,user:user.name}" -o json | ConvertFrom-Json
Write-Host "Target subscription: $($acct.name) [$($acct.id)] tenant $($acct.tenantId) as $($acct.user)" -ForegroundColor Green

# --- 1. Cleanup: elimina il resource group precedente (rimuove env/workspace parziali) ---
if ((az group exists -n $RG @SubArg) -eq "true") {
    Write-Host "Elimino il resource group '$RG' e tutto il suo contenuto..." -ForegroundColor Yellow
    az group delete -n $RG --yes @SubArg
}

# --- 2. Provider (idempotente) ---
az provider register -n Microsoft.App --wait @SubArg
az provider register -n Microsoft.OperationalInsights --wait @SubArg

# --- 3. Trova una region con capacity creando l'environment ACA ---
$LOC = $null
foreach ($r in $REGIONS) {
    Write-Host "`n=== Provo region '$r' ===" -ForegroundColor Cyan
    if ((az group exists -n $RG @SubArg) -eq "true") { az group delete -n $RG --yes @SubArg }
    az group create -n $RG -l $r @SubArg | Out-Null

    az containerapp env create -n $ENVNAME -g $RG -l $r --logs-destination none @SubArg 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Capacity OK in '$r'." -ForegroundColor Green
        $LOC = $r
        break
    }
    Write-Host "Region '$r' has no capacity (or error). Trying the next one..." -ForegroundColor DarkYellow
}

if (-not $LOC) {
    Write-Error "Nessuna region provata ha capacity per l'environment ACA. Aggiungi region a `$REGIONS o riprova piu' tardi."
    exit 1
}

# --- 4. Leggi credenziali blueprint + config LLM (restano nel terminale, non stampate) ---
$cfg          = Get-Content a365.generated.config.json | ConvertFrom-Json
$clientId     = $cfg.agentBlueprintId
$tenantId     = az account show --subscription $SUB --query tenantId -o tsv
# NB: a365.generated.config.json contiene il secret cifrato DPAPI (solo Windows).
# The CLEARTEXT secret from 'a365 setup blueprint --show-secret' is required.
$clientSecret = if ($ClientSecret) { $ClientSecret } else { Read-Host "Paste the CLEARTEXT blueprint client secret (a365 setup blueprint --show-secret)" }

$m = @{}
Get-Content env/.env.playground.user |
    Where-Object { $_ -match '=' -and $_ -notmatch '^\s*#' } |
    ForEach-Object { $k,$v = $_ -split '=',2; $m[$k.Trim()] = $v.Trim() }

# --- 5. Deploy su Azure Container Apps (build dal Dockerfile via ACR) ---
Write-Host "Deploying Container App '$APP' in '$LOC'..." -ForegroundColor Cyan
az containerapp up `
  --name $APP --resource-group $RG --location $LOC --environment $ENVNAME `
  --subscription $SUB `
  --source . --target-port 3978 --ingress external `
  --env-vars `
    "PORT=3978" `
    "HOST=0.0.0.0" `
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
    "CONNECTIONSMAP__0__CONNECTION=service_connection" `
    "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID=$clientId" `
    "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET=$clientSecret" `
    "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID=$tenantId"

# --- 5b. (Entra ID auth per Azure OpenAI) Managed identity + ruolo ---
# Necessario quando la subscription disabilita la key auth (Azure Policy disableLocalAuth=true):
# l'agente usa DefaultAzureCredential e la Container App autentica con la sua managed identity.
if ($AOAI_ACC -and $AOAI_RG) {
    Write-Host "Abilito la managed identity della Container App e assegno 'Cognitive Services OpenAI User'..." -ForegroundColor Cyan
    $miPrincipal = az containerapp identity assign -n $APP -g $RG --system-assigned --query principalId -o tsv @SubArg
    $aoaiScope = az cognitiveservices account show -n $AOAI_ACC -g $AOAI_RG --query id -o tsv @SubArg
    az role assignment create --assignee-object-id $miPrincipal --assignee-principal-type ServicePrincipal `
        --role "Cognitive Services OpenAI User" --scope $aoaiScope @SubArg | Out-Null
    # Riavvia la revisione cosi' l'identita' assegnata viene usata subito.
    $rev = az containerapp show -n $APP -g $RG --query properties.latestRevisionName -o tsv @SubArg
    az containerapp revision restart -n $APP -g $RG --revision $rev @SubArg 2>$null | Out-Null
    Write-Host "Managed identity + ruolo assegnati su '$AOAI_ACC'." -ForegroundColor Green
} else {
    Write-Host "AOAI_RG/AOAI_ACC non impostati: salto managed identity/ruolo (percorso a chiave)." -ForegroundColor Yellow
}

# --- 6. Output URL + prossimo passo ---
$fqdn = az containerapp show -n $APP -g $RG --query properties.configuration.ingress.fqdn -o tsv @SubArg
Write-Host ""
Write-Host "Deploy completato." -ForegroundColor Green
Write-Host "Messaging endpoint: https://$fqdn/api/messages"
Write-Host "Health:             https://$fqdn/api/health"
Write-Host ""
Write-Host "Registra l'endpoint sul blueprint con:"
Write-Host "  a365 setup blueprint --endpoint-only --messaging-endpoint `"https://$fqdn/api/messages`""
