#requires -Version 5.1
# Imposta il blueprint client secret (in chiaro) come secret ACA e ridispiega.
# Il secret viene chiesto a runtime e resta nel tuo terminale.
$ErrorActionPreference = 'Stop'

$RG  = "agentframework-rg-pl"
$APP = "agentframework-sample"
$IMG = "ca80215d4590acr.azurecr.io/agentframework-sample:v3"

$sec = Read-Host "Incolla il blueprint client secret IN CHIARO (da 'a365 setup blueprint --show-secret')"
if ([string]::IsNullOrWhiteSpace($sec)) { throw "Secret vuoto: interrompo." }
Write-Host ("Lunghezza secret: {0} caratteri" -f $sec.Length) -ForegroundColor DarkGray

Write-Host "1) Imposto il secret ACA 'blueprint-secret'..." -ForegroundColor Cyan
az containerapp secret set -n $APP -g $RG --secrets "blueprint-secret=$sec" -o none

Write-Host "2) Aggiorno la Container App (immagine v3, comando di avvio normale, secret via secretref)..." -ForegroundColor Cyan
az containerapp update -n $APP -g $RG `
  --image $IMG `
  --command "python" --args "start_with_generic_host.py" `
  --set-env-vars "connections__service_connection__settings__clientSecret=secretref:blueprint-secret" `
  -o none

Write-Host "3) Attendo l'avvio della nuova revision..." -ForegroundColor Cyan
Start-Sleep -Seconds 30
az containerapp revision list -n $APP -g $RG `
  --query "[?properties.active].{name:name,running:properties.runningState,replicas:properties.replicas}" -o table

$fqdn = az containerapp show -n $APP -g $RG --query "properties.configuration.ingress.fqdn" -o tsv
Write-Host ""
Write-Host ("Health:  https://{0}/api/health" -f $fqdn)
Write-Host ("Messages: https://{0}/api/messages" -f $fqdn)
