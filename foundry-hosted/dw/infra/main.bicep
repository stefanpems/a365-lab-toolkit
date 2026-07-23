targetScope = 'resourceGroup'

// =================================================================================================
// Main parameters
// =================================================================================================

@minLength(1)
@maxLength(64)
@description('Name of the application. Used to ensure resource names are unique.')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
param location string

// =================================================================================================
// Project module parameters
// =================================================================================================

@description('Name of the Cognitive Services account')
param accountName string = 'dwfh${uniqueString(resourceGroup().id)}acct'

@description('Name of the Cognitive Services project')
param projectName string = 'dwfh${uniqueString(resourceGroup().id)}proj'

@description('Name of the Container Registry')
param containerRegistryName string = 'dwfh${uniqueString(resourceGroup().id)}acr'

@description('SKU of Cognitive Services account')
param cognitiveServicesSku string = 'S0'

@description('SKU of Container Registry')
@allowed(['Basic', 'Standard', 'Premium'])
param containerRegistrySku string = 'Basic'

param agentName string = 'agentframeworkFH-DW2-agent'

param maibName string = '${agentName}-maib'

// =================================================================================================
// Bot Service module parameters
// =================================================================================================

@description('Name of the Bot Service')
param botName string = '${agentName}-bot'

@description('Display name of the bot')
param botDisplayName string = '${agentName} Bot'

@description('SKU of the Bot Service')
param botServiceSku string = 'F0'

@description('Model name')
param modelName string = 'gpt-4.1'

@description('Model version')
param modelVersion string = '2025-04-14'

// =================================================================================================
// Common parameters
// =================================================================================================

@description('Tags to apply to all resources')
param tags object = {}

// =================================================================================================
// Module deployments
// =================================================================================================

// 1. Deploy the project module (Cognitive Services account, project, and Container Registry)
module project 'modules/project.bicep' = {
  name: 'project-deployment'
  params: {
    accountName: accountName
    projectName: projectName
    containerRegistryName: containerRegistryName
    location: location
    tags: tags
    cognitiveServicesSku: cognitiveServicesSku
    containerRegistrySku: containerRegistrySku
    modelName: modelName
    modelVersion: modelVersion
  }
}

// 2. Create deployment script UMI and grant roles on RG.
module deploymentScriptUmi 'modules/deployment-script-umi.bicep' = {
  name: 'deployment-script-umi'
  dependsOn: [
    project
  ]
}

// 3. Create managed agent identity blueprint using a deployment script (data-plane operation).
module deploymentScriptAgent 'modules/maib-creation-script.bicep' = {
  name: 'maib-creation-script'
  params: {
    uamiResourceId: deploymentScriptUmi.outputs.uamiResourceId
    azureAIProjectEndpoint: project.outputs.foundryProjectEndpoint
    maibName: maibName
  }
  dependsOn: [
    deploymentScriptUmi
  ]
}

// 4. Deploy the bot service module
module botService 'modules/botservice.bicep' = {
  name: 'botservice-deployment'
  params: {
    botName: botName
    displayName: botDisplayName
    msaAppId: deploymentScriptAgent.outputs.blueprintClientId
    endpoint: 'https://${accountName}.services.ai.azure.com/api/projects/${projectName}/agents/${agentName}/endpoint/protocols/activityProtocol?api-version=2025-05-15-preview'
    botServiceSku: botServiceSku
  }
  dependsOn: [
    deploymentScriptAgent
  ]
}

// 5. Wire gateway (Bot Service) diagnostics to a Log Analytics workspace so the Teams<->Foundry
//    relay is observable. See scripts/read-logs.ps1 for how to query these logs.
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring-deployment'
  params: {
    botName: botName
    workspaceName: '${environmentName}-logs'
    location: location
    tags: tags
  }
  dependsOn: [
    botService
  ]
}

// =================================================================================================
// Outputs - These become environment variables in post-provision.sh
// =================================================================================================

@description('ACR login server endpoint')
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = project.outputs.acrloginServer

output AZURE_AI_PROJECT_ENDPOINT string = project.outputs.foundryProjectEndpoint

@description('Agent identity blueprint ID')
output AGENT_IDENTITY_BLUEPRINT_ID string = deploymentScriptAgent.outputs.blueprintClientId

output SUBSCRIPTION_ID string = subscription().subscriptionId

output RESOURCE_GROUP string = resourceGroup().name

output LOCATION string = location

output ACCOUNT_NAME string = accountName

output PROJECT_NAME string = projectName

output AGENT_NAME string = agentName

output TENANT_ID string = tenant().tenantId

output PROJECT_PRINCIPAL_ID string = project.outputs.foundryProjectPrincipalId

output MAIB_NAME string = maibName

output MODEL_NAME string = modelName

@description('Log Analytics workspace collecting Bot Service gateway diagnostics')
output LOG_ANALYTICS_WORKSPACE string = monitoring.outputs.workspaceName