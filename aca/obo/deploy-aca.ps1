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
    [string]$AoaiAcc      = $env:DEPLOY_AOAI_ACC,
    # -ReuseEnv: reuse the existing resource group + ACA environment (NO RG deletion,
    # no region-probe). Handy for fast re-deploys: deleting a managed environment takes
    # 20-40 min, this avoids it entirely. Fails if the RG/environment do not already exist.
    [switch]$ReuseEnv
)
$ErrorActionPreference = 'Stop'

# ============================ Parameters ============================
$RG      = "agentframework-OBO-rg-pl"
$APP     = "agentframework-obo-sample"
$ENVNAME = "agentframework-OBO-env"
$SUB     = $Subscription   # TARGET subscription ID (via -Subscription or $env:DEPLOY_SUB). Empty = current subscription (risky).
# Azure OpenAI with Entra ID auth (optional but needed if the sub disables key auth):
# RG and name of the Azure OpenAI account on which to assign the role to the managed identity.
$AOAI_RG  = $AoaiRg    # e.g. 'agentframework-aoai-rg' (empty = skip MI/role, use the key)
$AOAI_ACC = $AoaiAcc   # e.g. the Azure OpenAI account name (empty = skip MI/role, use the key)

# Regions to try in order. polandcentral verified with capacity (2026-07-07).
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

# --- 1-3. Environment preparation ---
if ($ReuseEnv) {
    # REUSE path: no RG deletion, no region-probe. Reuse what already exists.
    if ((az group exists -n $RG @SubArg) -ne "true") {
        Write-Error "-ReuseEnv set but resource group '$RG' does not exist. Run without -ReuseEnv for a clean deploy."
        exit 1
    }
    $LOC = az containerapp env show -n $ENVNAME -g $RG @SubArg --query location -o tsv 2>$null
    if (-not $LOC) {
        Write-Error "-ReuseEnv set but environment '$ENVNAME' does not exist in '$RG'. Run without -ReuseEnv."
        exit 1
    }
    # Normalize 'Poland Central' -> 'polandcentral' for --location.
    $LOC = ($LOC -replace '\s','').ToLower()
    Write-Host "Reusing existing environment '$ENVNAME' in '$LOC' (RG '$RG'). Skipping deletion and region-probe." -ForegroundColor Green
} else {
    # --- 1. Cleanup: delete the previous resource group (removes partial env/workspace) ---
    if ((az group exists -n $RG @SubArg) -eq "true") {
        Write-Host "Deleting resource group '$RG' and all its contents..." -ForegroundColor Yellow
        az group delete -n $RG --yes @SubArg
    }

    # --- 2. Providers (idempotent) ---
    az provider register -n Microsoft.App --wait @SubArg
    az provider register -n Microsoft.OperationalInsights --wait @SubArg

    # --- 3. Find a region with capacity by creating the ACA environment ---
    $LOC = $null
    foreach ($r in $REGIONS) {
        Write-Host "`n=== Trying region '$r' ===" -ForegroundColor Cyan
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
}

if (-not $LOC) {
    Write-Error "No tried region has capacity for the ACA environment. Add regions to `$REGIONS or retry later."
    exit 1
}

# --- 4. Read blueprint credentials + LLM config (kept in the terminal, not printed) ---
# 'a365 setup all' writes a365.generated.config.json ONLY when it is run FROM this agent folder
# (it detects the project here). If setup ran elsewhere (e.g. an async shell dropped the leading
# 'cd'), the file is absent - resolve the blueprint application by its display name so the deploy
# still works, then persist a minimal config so re-runs and tooling find the id.
$clientId = if (Test-Path a365.generated.config.json) { (Get-Content a365.generated.config.json | ConvertFrom-Json).agentBlueprintId } else { $null }
if (-not $clientId) {
    $bpName = (Get-Content a365.config.json | ConvertFrom-Json).agentBlueprintDisplayName
    Write-Host "a365.generated.config.json missing agentBlueprintId; resolving blueprint '$bpName' by display name..." -ForegroundColor Yellow
    $clientId = az ad app list --display-name $bpName --query "[0].appId" -o tsv
    if (-not $clientId) { Write-Error "Could not resolve blueprint '$bpName'. Run 'a365 setup all' FROM this agent folder, then retry."; exit 1 }
    @{ agentBlueprintId = $clientId } | ConvertTo-Json | Set-Content a365.generated.config.json -Encoding utf8
    Write-Host "Resolved blueprint id $clientId; wrote minimal a365.generated.config.json." -ForegroundColor Green
}
$tenantId     = az account show --subscription $SUB --query tenantId -o tsv
# NB: a365.generated.config.json holds the DPAPI-encrypted secret (Windows only).
# The CLEARTEXT secret from 'a365 setup blueprint --show-secret' is required.
$clientSecret = if ($ClientSecret) { $ClientSecret } else { Read-Host "Paste the CLEARTEXT blueprint client secret (a365 setup blueprint --show-secret)" }

$m = @{}
Get-Content env/.env.playground.user |
    Where-Object { $_ -match '=' -and $_ -notmatch '^\s*#' } |
    ForEach-Object { $k,$v = $_ -split '=',2; $m[$k.Trim()] = $v.Trim() }

# Force the AOAI endpoint to the -AoaiAcc account so a stale env/.env.playground.user (copied from the
# sample = a prior lab's account) can't point the container at the wrong Azure OpenAI account, where
# the managed identity has no role -> a 401 on the model call.
if ($AOAI_ACC) { $m['AZURE_OPENAI_ENDPOINT'] = "https://$AOAI_ACC.openai.azure.com/" }

# --- 5. Deploy to Azure Container Apps (build from the Dockerfile via ACR) ---
Write-Host "Deploying Container App '$APP' in '$LOC'..." -ForegroundColor Cyan

# Base env vars. NB: do NOT set AZURE_OPENAI_API_KEY when the key is empty:
# with Entra ID (key auth disabled) an empty string "" is interpreted by the
# openai client as a supplied-but-invalid key -> "Missing credentials" error
# that bypasses managed-identity auth. Pass the key ONLY when it has a value.
$envVars = @(
    "PORT=3978"
    "HOST=0.0.0.0"
    "AZURE_OPENAI_ENDPOINT=$($m['AZURE_OPENAI_ENDPOINT'])"
    "AZURE_OPENAI_DEPLOYMENT=$($m['AZURE_OPENAI_DEPLOYMENT_NAME'])"
    "AZURE_OPENAI_API_VERSION=$($m['AZURE_OPENAI_API_VERSION'])"
    "AUTH_HANDLER_NAME=AGENTIC"
    "USE_AGENTIC_AUTH=true"
    "AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__TYPE=AgenticUserAuthorization"
    "AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__SETTINGS__SCOPES=ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/.default"
    "AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__SETTINGS__ALT_BLUEPRINT_NAME=SERVICE_CONNECTION"
    "CONNECTIONSMAP__0__SERVICEURL=*"
    "CONNECTIONSMAP__0__CONNECTION=service_connection"
    "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID=$clientId"
    "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET=$clientSecret"
    "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID=$tenantId"
)
if ($m['SECRET_AZURE_OPENAI_API_KEY']) {
    $envVars += "AZURE_OPENAI_API_KEY=$($m['SECRET_AZURE_OPENAI_API_KEY'])"
}

az containerapp up `
  --name $APP --resource-group $RG --location $LOC --environment $ENVNAME `
  --subscription $SUB `
  --source . --target-port 3978 --ingress external `
  --env-vars @envVars

# 'az containerapp up' can create the app before the system-assigned identity has AcrPull on the
# auto-created ACR, leaving the first revision on the mcr.microsoft.com/k8se/quickstart placeholder.
# Detect and remediate: grant AcrPull to the app identity and (re)set the real built image.
$curImg = az containerapp show -n $APP -g $RG --query "properties.template.containers[0].image" -o tsv @SubArg 2>$null
if ($curImg -like '*k8se/quickstart*') {
    Write-Host "First revision fell back to the quickstart image; granting AcrPull and setting the built image..." -ForegroundColor Yellow
    $acrName = az acr list -g $RG --query "[0].name" -o tsv @SubArg
    if ($acrName) {
        $miPrincipal = az containerapp identity assign -n $APP -g $RG --system-assigned --query principalId -o tsv @SubArg
        $acrId = az acr show -n $acrName --query id -o tsv @SubArg
        az role assignment create --assignee-object-id $miPrincipal --assignee-principal-type ServicePrincipal --role AcrPull --scope $acrId @SubArg 2>$null | Out-Null
        $realTag = az acr repository show-tags -n $acrName --repository $APP --orderby time_desc --top 1 -o tsv @SubArg 2>$null
        if ($realTag) {
            az containerapp registry set -n $APP -g $RG --server "$acrName.azurecr.io" --identity system @SubArg 2>$null | Out-Null
            az containerapp update -n $APP -g $RG --image "$acrName.azurecr.io/$APP`:$realTag" @SubArg | Out-Null
            Write-Host "Set image $acrName.azurecr.io/$APP`:$realTag with AcrPull on the managed identity." -ForegroundColor Green
        }
    }
}

# --- 5b. (Entra ID auth for Azure OpenAI) Managed identity + role ---
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

# --- 6. Output URL + next step ---
$fqdn = az containerapp show -n $APP -g $RG --query properties.configuration.ingress.fqdn -o tsv @SubArg
Write-Host ""
Write-Host "Deploy complete." -ForegroundColor Green
Write-Host "Messaging endpoint: https://$fqdn/api/messages"
Write-Host "Health:             https://$fqdn/api/health"
Write-Host ""
Write-Host "Register the endpoint on the blueprint with:"
Write-Host "  a365 setup blueprint --endpoint-only --messaging-endpoint `"https://$fqdn/api/messages`""
