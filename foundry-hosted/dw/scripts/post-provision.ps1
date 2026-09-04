#!/usr/bin/env pwsh
Write-Host "Starting post-provision script..."

# AZURE_LOCATION is a default azd environment variable
Write-Host "Resources were deployed to: location $env:AZURE_LOCATION blueprintId $env:AZURE_AGENT_IDENTITY_BLUEPRINT_ID subscriptionId $env:AZURE_SUBSCRIPTION_ID agentName $env:AGENT_NAME"

# Write-Host "===============Building and pushing Docker image==============="
& "$PSScriptRoot/build-docker-image-acr.ps1"

Write-Host "===============Creating Agent Version==============="
$agentGuid = & "$PSScriptRoot/agent-creation-script.ps1"

Write-Host "===============Publishing digital worker==============="

& "$PSScriptRoot/publish-digital-worker.ps1" -AgentGuid $agentGuid

# oAuth2 grants for the blueprint SP. NON-FATAL: this pre-consents the MCP/APX scopes on the
# blueprint SP via Microsoft Graph (az), but (a) it is superseded by the publish
# `optionalPermissionScopes` + the admin center "Grant admin consent" (which consents Mail, MCP
# metadata, Access agent data and telemetry on the blueprint), and (b) `az`->Graph is often blocked
# by Continuous Access Evaluation (TokenCreatedWithOutdatedPolicies) in hardened tenants, where this
# step cannot run at all. So a failure here must NOT fail the whole provision — grant consent in the
# Microsoft 365 admin center instead (see setup-MAF-FH-DW.md §8.1).
Write-Host "===============OAuth2 grants for blueprint SP (best-effort)==============="
try {
    & "$PSScriptRoot/create-blueprintsp-oauth2-grants.ps1"
}
catch {
    Write-Warning "OAuth2 grants step failed (continuing): $($_.Exception.Message)"
    Write-Warning "This is expected in CAE-hardened tenants. Grant admin consent in the Microsoft 365 admin center (Agents -> Requests -> Review permissions -> Grant admin consent)."
}

Write-Host "===============Adding current user as blueprint owner (best-effort)==============="
try {
    & "$PSScriptRoot/add-current-user-as-blueprint-owner.ps1"
}
catch {
    Write-Warning "Add-blueprint-owner step failed (continuing): $($_.Exception.Message)"
}

# Write-Host "===============Configuring blueprint backend in Teams Dev Portal==============="
# & "$PSScriptRoot/configure-blueprint-backend.ps1"


Write-Host ""
Write-Host "Post-provision script finished."
