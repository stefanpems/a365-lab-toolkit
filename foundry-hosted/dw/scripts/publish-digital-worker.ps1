#!/usr/bin/env pwsh
param(
    # Kept for backward compatibility with post-provision.ps1. The agent endpoint identifies the
    # agent by name in the URL, so the agent GUID is not part of the publish body.
    [Parameter(Mandatory = $false)]
    [string]$AgentGuid
)

$ErrorActionPreference = "Stop"

Write-Host "Starting publish-digital-worker script..."

# AZURE_LOCATION is a default azd environment variable
Write-Host "Resources were deployed to: location $env:LOCATION blueprintId $env:AGENT_IDENTITY_BLUEPRINT_ID subscriptionId $env:SUBSCRIPTION_ID agentName $env:AGENT_NAME agentVersion $env:AGENT_VERSION"

# Publish app version. Overridable via PUBLISH_APP_VERSION so the DW can be re-published with a
# bumped version (the endpoint rejects re-publishing an already-published version). Bump this
# whenever you change publish metadata such as optionalPermissionScopes.
$appVersion = if ($env:PUBLISH_APP_VERSION) { $env:PUBLISH_APP_VERSION } else { "1.0.0" }

# Publish via the AGENT endpoint (publishAsAutopilot). This is the only publish path that honors
# `optionalPermissionScopes` — the older AzureML agent-asset endpoint (publishAsDigitalWorker)
# silently ignores that field, so the MCP tool scopes never reach the blueprint and instances hit
# AADSTS65001 on Mail. For an AUTOPILOT `publishScope` is ALWAYS "Tenant" (the blueprint goes to
# admin approval); the agent endpoint authorization scheme is "BotServiceRbac" (set in
# agent-creation-script.ps1), NOT "BotServiceTenant". Autopilots relay activity through a hosted
# pass-through endpoint authorized by Foundry Azure RBAC — using BotServiceTenant makes instance
# creation fail with "Autopilot activity access boundaries require ... BotServiceRbac authorization".
$agentPublishUrl = "$($env:AZURE_AI_PROJECT_ENDPOINT)/agents/$($env:AGENT_NAME)/microsoft365/publish?api-version=2025-11-15-preview"

$body = @{
    agentDisplayName         = $env:AGENT_NAME
    publishAsAutopilot       = $true
    publishScope             = "Tenant"
    appVersion               = $appVersion
    canRespondWithoutMention = $true
    shortDescription    = "Foundry A365 Agent deployed via Azure Developer CLI"
    fullDescription     = "A Foundry A365 agent example that demonstrates integration with Microsoft 365 and Azure Cognitive Services."
    developerName       = "Azure Developer"
    developerWebsiteUrl = "https://azure.microsoft.com"
    privacyUrl          = "https://privacy.microsoft.com"
    termsOfUseUrl       = "https://www.microsoft.com/legal/terms-of-use"
    # optionalPermissionScopes declares the Microsoft 365 delegated (MCP tool) scopes the hired
    # instances need. On this AGENT endpoint the PLATFORM uses them at admin approval to configure the
    # managed agent identity blueprint's INHERITABLE permissions, so every hired instance inherits
    # them. Without this the instance's token exchange for the tool fails with AADSTS65001 and the
    # agent reports "I cannot send emails". Do NOT PATCH the blueprint directly (it is platform-managed).
    # ea9ffc3e-... = Agent 365 Tools (MCP). McpServers.Mail.All = the Mail tool; McpServersMetadata.Read.All
    # is required alongside it for MCP tool/metadata discovery (matches the ACA DW's declared scopes).
    optionalPermissionScopes = @(
        @{
            resourceAppId = "ea9ffc3e-8a23-4a7d-836d-234d7c7565c1"
            scopes        = @("McpServers.Mail.All", "McpServersMetadata.Read.All")
        }
    )
    useAgenticUserTemplate = $true
    agenticUserTemplate = @{
            Id                         = "digitalWorkerTemplate"
            File                       = "agenticUserTemplateManifest.json"
            SchemaVersion              = "0.1.0-preview"
            AgentIdentityBlueprintId   = $env:AGENT_IDENTITY_BLUEPRINT_ID
            CommunicationProtocol      = "activityProtocol"
    }
}

$jsonBody = $body | ConvertTo-Json -Depth 10

$aiAzureToken = az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv


Write-Host "Sending Microsoft 365 publish request to $agentPublishUrl (this submits the agent blueprint for admin approval in the Microsoft 365 admin center)..."
Write-Host "JSON Body:"
Write-Host $jsonBody

# Send POST request

try{
    $response = Invoke-RestMethod -Uri $agentPublishUrl `
    -Method Post `
    -Headers @{
        "Content-Type" = "application/json"
        "Accept"       = "application/json"
        "Authorization" = "Bearer $($aiAzureToken)"
    } `
    -Body $jsonBody

    Write-Host ""
    Write-Host "Response:"
    $response | ConvertTo-Json -Depth 5 | Write-Host
}
catch {
        $err = $_.ErrorDetails.Message | ConvertFrom-Json
    if ($err.error.code -eq "UserError" -and
        $err.error.message -like "*version already exists*") {

        Write-Host "A digital worker is already published with this version. Ignoring."
    }
    else {
        throw
    }
}

Write-Host ""
Write-Host "Publish digital worker script finished."
