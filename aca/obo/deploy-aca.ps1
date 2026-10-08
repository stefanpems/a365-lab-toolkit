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
    # Assisted secret handling: read the secret with 'a365 setup blueprint --show-secret' (run from the agent folder).
    [switch]$ClientSecretFromA365,
    [string]$Subscription = $env:DEPLOY_SUB,
    [string]$AoaiRg       = $env:DEPLOY_AOAI_RG,
    [string]$AoaiAcc      = $env:DEPLOY_AOAI_ACC,
    # Agent identity appId for Agent 365 observability (A365_AGENT_ID). Optional: resolved from
    # a365.generated.config.json (agenticAppId) or by the identity display name in Entra.
    [string]$AgentId,
    # -ReuseEnv: reuse the existing resource group + ACA environment (NO RG deletion,
    # no region-probe). Handy for fast re-deploys: deleting a managed environment takes
    # 20-40 min, this avoids it entirely. Fails if the RG/environment do not already exist.
    [switch]$ReuseEnv
)
$ErrorActionPreference = 'Stop'
# Assisted secret handling: the value never reaches the console or a chat.
if (-not $ClientSecret -and $ClientSecretFromA365) {
    $a365Out = a365 setup blueprint --show-secret 2>&1 | Out-String
    if ($a365Out -match 'Blueprint client secret:\s*(\S+)') { $ClientSecret = $Matches[1] }
    else { Write-Error "Could not read the blueprint client secret with 'a365 setup blueprint --show-secret' (run this script from the agent folder, after 'a365 setup all')."; exit 1 }
    $a365Out = $null
}

# Console UTF-8 for the az output. The image is built with 'az acr build --no-logs' (no log stream), so the script
# is safe to run with its output captured (an agent's shell, a pipe or a file).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"

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
# Agent identity (NOT the blueprint) for Agent 365 observability: the exporter authenticates as this
# identity and stamps its appId on every span. Without it the web UI /chat turns never reach Agent 365
# (admin center: 0 active users / 0 sessions). Order: -AgentId > agenticAppId > Entra display-name lookup
# validated against this blueprint.
if (-not $AgentId -and (Test-Path a365.generated.config.json)) {
    $AgentId = (Get-Content a365.generated.config.json | ConvertFrom-Json).agenticAppId
}
if (-not $AgentId) {
    $idName = (Get-Content a365.config.json | ConvertFrom-Json).agentIdentityDisplayName
    if ($idName) {
        $flt = "displayName eq '$($idName.Replace("'", "''"))'"
        $AgentId = @(az rest --method get --url "https://graph.microsoft.com/beta/servicePrincipals?`$filter=$flt&`$select=appId,agentIdentityBlueprintId" --query "value[?agentIdentityBlueprintId=='$clientId'].appId" -o tsv 2>$null) | Select-Object -First 1
    }
}
if ($AgentId) { Write-Host "Agent identity (A365_AGENT_ID): $AgentId" -ForegroundColor Green }
else { Write-Warning "Agent identity not resolved: Agent 365 observability for the web UI is OFF. Re-run with -AgentId <agent identity appId>." }
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
    # App Insights role name = the app (instead of 'unknown_service').
    "OTEL_SERVICE_NAME=$APP"
)
if ($AgentId) { $envVars += "A365_AGENT_ID=$AgentId" }
if ($m['SECRET_AZURE_OPENAI_API_KEY']) {
    $envVars += "AZURE_OPENAI_API_KEY=$($m['SECRET_AZURE_OPENAI_API_KEY'])"
}

# --- 5. Build the image in the cloud and create/update the Container App ---
# No 'az containerapp up': it streams the build log, which crashes with UnicodeEncodeError (colorama/cp1252)
# whenever the output is captured (an agent's shell, a pipe, a file) and then the app is never created. The
# image is built server-side with 'az acr build --no-logs' (as the S2S/DW scripts do) and the app pulls it
# with its system-assigned managed identity (as 'az containerapp up' configured it on earlier deploys).
$acrName = az acr list -g $RG --query "[0].name" -o tsv @SubArg 2>$null
if (-not $acrName) {
    $acrName = "afoboacr" + (Get-Random -Minimum 10000 -Maximum 99999)
    Write-Host "Creating ACR '$acrName'..." -ForegroundColor Cyan
    az acr create -n $acrName -g $RG -l $LOC --sku Basic @SubArg | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "az acr create '$acrName' failed."; exit 1 }
}
$acrServer = az acr show -n $acrName -g $RG --query loginServer -o tsv @SubArg
$IMAGE = "${APP}:$(Get-Date -Format 'yyyyMMddHHmmss')"
Write-Host "Building image '$IMAGE' on ACR '$acrName' (cloud build, --no-logs)..." -ForegroundColor Cyan
az acr build -r $acrName -t $IMAGE --no-logs . @SubArg | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "az acr build failed (see: az acr task list-runs -r $acrName)."; exit 1 }

Write-Host "Deploying Container App '$APP' in '$LOC'..." -ForegroundColor Cyan
$appExists = az containerapp show -n $APP -g $RG --query name -o tsv @SubArg 2>$null
if ($appExists) {
    $miPrincipal = az containerapp identity assign -n $APP -g $RG --system-assigned --query principalId -o tsv @SubArg
    $acrId = az acr show -n $acrName --query id -o tsv @SubArg
    az role assignment create --assignee-object-id $miPrincipal --assignee-principal-type ServicePrincipal --role AcrPull --scope $acrId @SubArg 2>$null | Out-Null
    az containerapp registry set -n $APP -g $RG --server $acrServer --identity system @SubArg 2>$null | Out-Null
    az containerapp update -n $APP -g $RG --image "$acrServer/$IMAGE" --set-env-vars @envVars @SubArg | Out-Null
}
else {
    az containerapp create `
        --name $APP --resource-group $RG --environment $ENVNAME `
        --image "$acrServer/$IMAGE" `
        --registry-server $acrServer --registry-identity system `
        --target-port 3978 --ingress external `
        --env-vars @envVars @SubArg | Out-Null
}
if ($LASTEXITCODE -ne 0) { Write-Error "Container App '$APP' create/update failed."; exit 1 }

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
if (-not $fqdn) { Write-Error "Container App '$APP' has no ingress FQDN: the deploy did not complete (check 'az containerapp show -n $APP -g $RG')."; exit 1 }
Write-Host ""
Write-Host "Deploy complete." -ForegroundColor Green
Write-Host "Messaging endpoint: https://$fqdn/api/messages"
Write-Host "Health:             https://$fqdn/api/health"
Write-Host ""
Write-Host "Register the endpoint on the blueprint with:"
Write-Host "  a365 setup blueprint --endpoint-only --messaging-endpoint `"https://$fqdn/api/messages`""
