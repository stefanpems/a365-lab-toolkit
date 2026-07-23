// Azure Bot Service that relays Teams / M365 Copilot messages to the Foundry agent's
// activity-protocol endpoint. For a PUBLIC Foundry project we enable public network access
// (the Bot Channel Adapters reach the public agent endpoint directly, so no VNet step is
// needed). Ref: https://learn.microsoft.com/azure/foundry/agents/how-to/publish-copilot-virtual-network#step-2-create-the-azure-bot-service-resource
param botName string
param displayName string
param msaAppId string          // Agent identity principal ID (instance_identity.principal_id)
param tenantId string          // Your Microsoft Entra tenant ID
param endpoint string          // Agent activity-protocol endpoint
param botServiceSku string = 'F0'

resource botService 'Microsoft.BotService/botServices@2022-09-15' = {
  name: botName
  kind: 'azurebot'
  location: 'global'
  sku: {
    name: botServiceSku
  }
  properties: {
    displayName: displayName
    endpoint: endpoint
    msaAppId: msaAppId
    msaAppTenantId: tenantId
    msaAppType: 'SingleTenant'
    publicNetworkAccess: 'Enabled'
  }
}

resource botServiceMsTeamsChannel 'Microsoft.BotService/botServices/channels@2021-03-01' = {
  parent: botService
  location: 'global'
  name: 'MsTeamsChannel'
  properties: {
    channelName: 'MsTeamsChannel'
  }
}

output botServiceArmId string = botService.id
