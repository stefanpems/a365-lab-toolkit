#requires -Version 5.1
# Corregge il case dei nomi env var per Linux (case-sensitive) e ripristina il comando.
# Su Windows os.environ rende MAIUSCOLI i nomi -> il parser trova CONNECTIONS.
# Su Linux i nomi restano com'e' -> servono MAIUSCOLI per matchare il parser dell'SDK.
$ErrorActionPreference = 'Stop'

$RG  = "agentframework-rg-pl"
$APP = "agentframework-sample"
$IMG = "ca80215d4590acr.azurecr.io/agentframework-sample:v3"

$cfg      = Get-Content a365.generated.config.json | ConvertFrom-Json
$clientId = $cfg.agentBlueprintId
$tenantId = az account show --query tenantId -o tsv

$m = @{}
Get-Content env/.env.playground.user |
    Where-Object { $_ -match '=' -and $_ -notmatch '^\s*#' } |
    ForEach-Object { $k,$v = $_ -split '=',2; $m[$k.Trim()] = $v.Trim() }

Write-Host "Aggiorno env var (MAIUSCOLE) + reset comando di avvio..." -ForegroundColor Cyan
az containerapp update -n $APP -g $RG `
  --image $IMG `
  --command "python" --args "start_with_generic_host.py" `
  --replace-env-vars `
    "PORT=3978" `
    "AZURE_OPENAI_ENDPOINT=$($m['AZURE_OPENAI_ENDPOINT'])" `
    "AZURE_OPENAI_API_KEY=$($m['SECRET_AZURE_OPENAI_API_KEY'])" `
    "AZURE_OPENAI_DEPLOYMENT=$($m['AZURE_OPENAI_DEPLOYMENT_NAME'])" `
    "AZURE_OPENAI_API_VERSION=$($m['AZURE_OPENAI_API_VERSION'])" `
    "AUTH_HANDLER_NAME=AGENTIC" `
    "USE_AGENTIC_AUTH=true" `
    "CONNECTIONSMAP__0__SERVICEURL=*" `
    "CONNECTIONSMAP__0__CONNECTION=service_connection" `
    "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID=$clientId" `
    "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET=secretref:blueprint-secret" `
    "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID=$tenantId" `
  -o none
Write-Host "update exit=$LASTEXITCODE" -ForegroundColor Green

Write-Host "Attendo l'avvio..." -ForegroundColor Cyan
Start-Sleep -Seconds 35
az containerapp revision list -n $APP -g $RG `
  --query "[?properties.active].{name:name,running:properties.runningState,replicas:properties.replicas}" -o table
