#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Create the managed agent identity blueprint (MAIB) OUT-OF-BAND.

.DESCRIPTION
    On subscriptions whose Azure Policy forbids shared-key access on storage accounts, the ARM
    deployment script in infra/modules/maib-creation-script.bicep fails with
    'KeyBasedAuthenticationNotPermitted' (its container mounts an Azure File share with the
    storage shared key). This script performs the SAME data-plane call the deployment script
    makes, but from your own Entra ID (az) context — no storage, no shared key — so it works
    under the policy.

    Run it BETWEEN the first `azd provision` (which creates account/project/ACR/model, then
    stops at the blueprint step) and a second `azd provision` (which, with
    AGENT_IDENTITY_BLUEPRINT_CLIENT_ID set, SKIPS the deployment script and finishes the Bot
    Service + monitoring + postprovision).

    Steps performed (idempotent):
      1. Discover the Foundry account + project in the resource group.
      2. Grant the caller the data-plane role 'Cognitive Services User' on the account.
      3. PUT the blueprint on the project's managedagentidentityblueprints endpoint.
      4. Delete any failed 'create-agent-script' deploymentScript left by the first provision.
      5. `azd env set AGENT_IDENTITY_BLUEPRINT_CLIENT_ID <clientId>`.

.PARAMETER Subscription
    Target subscription id. Defaults to $env:AZURE_SUBSCRIPTION_ID (set by azd).

.PARAMETER ResourceGroup
    Resource group that holds the Foundry account. Defaults to $env:AZURE_RESOURCE_GROUP.

.PARAMETER AgentName
    Agent name (the MAIB is '<AgentName>-maib'). Defaults to the bicep default.

.EXAMPLE
    ./scripts/create-agent-blueprint.ps1 -ResourceGroup sample-fh-dw-rg
#>
param(
    [string]$Subscription = $env:AZURE_SUBSCRIPTION_ID,
    [string]$ResourceGroup = $env:AZURE_RESOURCE_GROUP,
    [string]$AgentName = 'sample-fh-dw-agent',
    [string]$MaibName
)

$ErrorActionPreference = 'Stop'
if (-not $MaibName) { $MaibName = "$AgentName-maib" }
if (-not $Subscription) { throw "Subscription not set. Pass -Subscription or set AZURE_SUBSCRIPTION_ID." }
if (-not $ResourceGroup) { throw "ResourceGroup not set. Pass -ResourceGroup or set AZURE_RESOURCE_GROUP." }

az account set --subscription $Subscription | Out-Null
$oid = az ad signed-in-user show --query id -o tsv
$who = az ad signed-in-user show --query userPrincipalName -o tsv
Write-Host "Caller: $who ($oid) | sub=$Subscription | rg=$ResourceGroup" -ForegroundColor Green

# 1. Discover Foundry account + project in the RG.
$account = az cognitiveservices account list -g $ResourceGroup --subscription $Subscription --query "[0].name" -o tsv
if (-not $account) { throw "No Cognitive Services (Foundry) account in '$ResourceGroup'. Run 'azd provision' first." }
$projFull = az resource list -g $ResourceGroup --subscription $Subscription `
    --resource-type 'Microsoft.CognitiveServices/accounts/projects' --query "[0].name" -o tsv
if (-not $projFull) { throw "No Foundry project found under account '$account'." }
$project = $projFull.Split('/')[-1]
Write-Host "Foundry account=$account project=$project maib=$MaibName" -ForegroundColor Cyan

# 2. Grant the data-plane role needed to call the project (Cognitive Services User).
$acctId = az cognitiveservices account show -n $account -g $ResourceGroup --subscription $Subscription --query id -o tsv
az role assignment create --assignee-object-id $oid --assignee-principal-type User `
    --role 'a97b65f3-24c7-4388-baec-2e87135dc908' --scope $acctId 2>$null | Out-Null
Write-Host "Ensured 'Cognitive Services User' on the account." -ForegroundColor Cyan

# 3. Create the blueprint (same call as the deployment script).
$endpoint = "https://$account.services.ai.azure.com/api/projects/$project"
$maibUrl = "$endpoint/managedagentidentityblueprints/$MaibName`?api-version=2025-11-15-preview"
$tok = az account get-access-token --resource 'https://ai.azure.com' --query accessToken -o tsv
$headers = @{ 'Content-Type' = 'application/json'; 'Accept' = 'application/json'; 'Authorization' = "Bearer $tok" }
Write-Host "PUT $maibUrl" -ForegroundColor Cyan
$resp = Invoke-RestMethod -Uri $maibUrl -Method Put -Headers $headers -ErrorAction Stop
$clientId = $resp.agentIdentityBlueprint.clientId
if (-not $clientId) { throw "Blueprint response did not contain a clientId." }
Write-Host "Blueprint clientId = $clientId" -ForegroundColor Green

# 4. Remove any failed deployment script left by the first provision (conflicts on re-provision).
$dsId = az resource show -g $ResourceGroup -n create-agent-script `
    --resource-type 'Microsoft.Resources/deploymentScripts' --subscription $Subscription --query id -o tsv 2>$null
if ($dsId) {
    az resource delete --ids $dsId --subscription $Subscription 2>$null | Out-Null
    Write-Host "Deleted failed 'create-agent-script' deploymentScript." -ForegroundColor Cyan
}

# 5. Feed it back to azd so the next `azd provision` skips the deployment script.
azd env set AGENT_IDENTITY_BLUEPRINT_CLIENT_ID $clientId | Out-Null
Write-Host "`nDone. Set AGENT_IDENTITY_BLUEPRINT_CLIENT_ID=$clientId. Now run: azd provision" -ForegroundColor Green
