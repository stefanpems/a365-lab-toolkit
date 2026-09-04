$ErrorActionPreference = "Stop"

$blueprintSP = az ad sp show --id $env:AGENT_IDENTITY_BLUEPRINT_ID --query id -o tsv

if ([string]::IsNullOrEmpty($blueprintSP)) {
    throw "Failed to get service principal for blueprint ID $($env:AGENT_IDENTITY_BLUEPRINT_ID)"
}

Write-Host "Creating OAuth2 permission grants for blueprint service principal..."


$apxAppId = "5a807f24-c9de-44ee-a3a7-329e88a00ffc"

$apxSP = az ad sp show --id $apxAppId --query id -o tsv
if ([string]::IsNullOrEmpty($apxSP)) {
    throw "Failed to get service principal for APEX app ID $apxAppId"
}

$prodMCPAppId = "ea9ffc3e-8a23-4a7d-836d-234d7c7565c1"
$prodMCP_SP = az ad sp show --id $prodMCPAppId --query id -o tsv

if ([string]::IsNullOrEmpty($prodMCP_SP)) {
    throw "Failed to get service principal for Prod MCP app ID $prodMCPAppId"
}

# 00000003-0000-0000-c000-000000000000 is graph appId
$graphToken = az account get-access-token --resource https://graph.microsoft.com/ --query accessToken -o tsv


$mcpOauthGrant = @"
{
  "clientId": "$blueprintSP",
  "consentType": "AllPrincipals",
  "principalId": null,
  "resourceId": "$prodMCP_SP",
  "scope": "McpServers.M365Admin.All McpServers.DASearch.All McpServers.WebSearch.All McpServers.Files.All AgentTools.MOSEvents.All McpServers.Admin365Graph.All McpServers.ERPAnalytics.All McpServers.DataverseCustom.All McpServers.Dataverse.All McpServers.D365Service.All McpServers.D365Sales.All McpServers.Management.All McpServersMetadata.Read.All McpServers.Developer.All McpServers.CopilotMCP.All McpServers.OneDriveSharepoint.All McpServers.Mail.All McpServers.Teams.All McpServers.Me.All McpServers.Calendar.All McpServers.SharepointLists.All McpServers.Knowledge.All McpServers.Excel.All McpServers.Word.All McpServers.PowerPoint.All"
}
"@
# Catch "Permission entry already exists" error and continue
try {
    $response = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" `
        -Method Post `
        -Headers @{
            "Content-Type" = "application/json"
            "Accept"       = "application/json"
            "Authorization" = "Bearer $($graphToken)"
        } `
        -Body $mcpOauthGrant

    Write-Host ""
    Write-Host "MCP oauth grant response:"
    $response | ConvertTo-Json -Depth 5 | Write-Host

} catch {
    $err = $_.ErrorDetails.Message | ConvertFrom-Json
    if ($err.error.code -eq "Request_BadRequest" -and
        $err.error.message -like "*Permission entry already exists*") {

        Write-Host "Permission already exists  ignoring."
    }
    else {
        throw
    }
}


try {
    $apxOauthGrant = @"
    {
        "clientId": "$blueprintSP",
        "consentType": "AllPrincipals",
        "principalId": null,
        "resourceId": "$apxSP",
        "scope": "AgentData.ReadWrite"
    }
"@

    $response = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" `
        -Method Post `
        -Headers @{
            "Content-Type" = "application/json"
            "Accept"       = "application/json"
            "Authorization" = "Bearer $($graphToken)"
        } `
        -Body $apxOauthGrant

    Write-Host ""
    Write-Host "APX oauth grant response:"
    $response | ConvertTo-Json -Depth 5 | Write-Host
}
catch {
    $err = $_.ErrorDetails.Message | ConvertFrom-Json
    if ($err.error.code -eq "Request_BadRequest" -and
        $err.error.message -like "*Permission entry already exists*") {

        Write-Host "Permission already exists  ignoring."
    }
    else {
        throw
    }
}


# ---------------------------------------------------------------------------
# INHERITABLE permissions on the blueprint.
#
# The oauth2PermissionGrants above consent the BLUEPRINT service principal, but each hired
# autopilot INSTANCE is a SEPARATE agent identity. Without inheritable permissions the
# instance's delegated-token exchange for the MCP scopes fails with
#   AADSTS65001 (consent_required) for app '<instance>'
# and the agent reports "I cannot send emails at the moment". Configuring inheritablePermissions
# on the blueprint makes every instance inherit the resource's scopes. This is what
# `a365 setup permissions mcp` does for the ACA agents. Ref:
# https://learn.microsoft.com/entra/agent-id/configure-inheritable-permissions-blueprints
#
# PRIVILEGE: writing inheritablePermissions requires the caller to hold the **Agent ID
# Administrator** (or Agent ID Developer) directory role. Global Administrator ALONE returns
# 403 Authorization_RequestDenied. Ensure the deploy identity has that role (or run
# `a365 setup permissions mcp`, which is Global-Admin-sufficient).
# ---------------------------------------------------------------------------
$blueprintAppObjectId = az ad app show --id $env:AGENT_IDENTITY_BLUEPRINT_ID --query id -o tsv
if ([string]::IsNullOrEmpty($blueprintAppObjectId)) {
    throw "Failed to get blueprint application object id for $($env:AGENT_IDENTITY_BLUEPRINT_ID)"
}

# Resource apps whose SCOPES instances must inherit: Agent 365 Tools (MCP incl. Mail) + APX.
# These expose delegated scopes, not app roles, so inherit scopes only (noRoles) — requesting
# allAllowedRoles here returns 403.
foreach ($resId in @($prodMCPAppId, $apxAppId)) {
    $inheritBody = @"
{
  "resourceAppId": "$resId",
  "inheritableScopes": { "@odata.type": "#microsoft.graph.allAllowedScopes", "kind": "allAllowed" },
  "inheritableRoles": { "@odata.type": "#microsoft.graph.noRoles", "kind": "none" }
}
"@
    try {
        Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/applications/microsoft.graph.agentIdentityBlueprint/$blueprintAppObjectId/inheritablePermissions" `
            -Method Post `
            -Headers @{
                "Content-Type"  = "application/json"
                "Accept"        = "application/json"
                "OData-Version" = "4.0"
                "Authorization" = "Bearer $($graphToken)"
            } `
            -Body $inheritBody | Out-Null
        Write-Host "Inheritable permissions configured for resource $resId."
    }
    catch {
        $msg = "$($_.ErrorDetails.Message)"
        if ($msg -like "*already exist*" -or $msg -like "*conflict*" -or $msg -like "*duplicate*") {
            Write-Host "Inheritable permissions already configured for $resId  ignoring."
        }
        else {
            Write-Host "WARNING: could not set inheritable permissions for ${resId}: $msg"
        }
    }
}
