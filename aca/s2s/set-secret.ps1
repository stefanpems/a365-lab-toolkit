#requires -Version 5.1
# Sets the blueprint client secret (cleartext) as an ACA secret and redeploys.
# The secret is prompted at runtime and stays in your terminal.
$ErrorActionPreference = 'Stop'

$RG  = "agentframework-rg-pl"
$APP = "agentframework-sample"
$IMG = "ca80215d4590acr.azurecr.io/agentframework-sample:v3"

$sec = Read-Host "Paste the CLEARTEXT blueprint client secret (from 'a365 setup blueprint --show-secret')"
if ([string]::IsNullOrWhiteSpace($sec)) { throw "Secret vuoto: interrompo." }
Write-Host ("Lunghezza secret: {0} caratteri" -f $sec.Length) -ForegroundColor DarkGray

Write-Host "1) Imposto il secret ACA 'blueprint-secret'..." -ForegroundColor Cyan
az containerapp secret set -n $APP -g $RG --secrets "blueprint-secret=$sec" -o none

Write-Host "2) Updating the Container App (image v3, normal startup command, secret via secretref)..." -ForegroundColor Cyan
az containerapp update -n $APP -g $RG `
  --image $IMG `
  --command "python" --args "start_with_generic_host.py" `
  --set-env-vars "connections__service_connection__settings__clientSecret=secretref:blueprint-secret" `
  -o none

Write-Host "3) Waiting for the new revision to start..." -ForegroundColor Cyan
Start-Sleep -Seconds 30
az containerapp revision list -n $APP -g $RG `
  --query "[?properties.active].{name:name,running:properties.runningState,replicas:properties.replicas}" -o table

$fqdn = az containerapp show -n $APP -g $RG --query "properties.configuration.ingress.fqdn" -o tsv
Write-Host ""
Write-Host ("Health:  https://{0}/api/health" -f $fqdn)
Write-Host ("Messages: https://{0}/api/messages" -f $fqdn)
