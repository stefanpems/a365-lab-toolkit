// =================================================================================================
// Monitoring / observability module
// -------------------------------------------------------------------------------------------------
// Creates a Log Analytics workspace and routes the Azure Bot Service "BotRequest" diagnostic logs
// to it. BotRequest captures the gateway hops: the inbound Teams/M365 activity AND the outbound
// relay to the Foundry activityProtocol endpoint (including the HTTP status Foundry returns).
// This is the primary way to tell WHERE a message is lost between Teams and the hosted agent.
//
// NOTE: container stdout/stderr is NOT captured here. Foundry hosted-agent container logs are
// platform-managed and streamed LIVE per session (see scripts/read-logs.ps1 -Mode live, or
// `azd ai agent monitor --session-id <id> --follow`). APPLICATIONINSIGHTS_CONNECTION_STRING is a
// reserved container env var and cannot be injected.
// =================================================================================================

@description('Name of the Bot Service whose diagnostics are collected')
param botName string

@description('Name of the Log Analytics workspace')
param workspaceName string

@description('Location for the workspace')
param location string

@description('Tags to apply')
param tags object = {}

resource workspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource botService 'Microsoft.BotService/botServices@2022-09-15' existing = {
  name: botName
}

resource botDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${botName}-diag'
  scope: botService
  properties: {
    workspaceId: workspace.id
    logs: [
      {
        category: 'BotRequest'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output workspaceName string = workspace.name
output workspaceId string = workspace.id
