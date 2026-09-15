#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.
#
# Assigns the `Agent365.Observability.OtelWrite` APPLICATION app-role to a Foundry Hosted
# agent's identity service principal, so the A365 observability exporter (enabled in
# foundry-hosted/{obo,s2s}/main.py and foundry-hosted/dw/.../host_agent_server.py) can write
# telemetry to Agent 365. App-only export is the documented flow for FH-OBO/S2S/DW
# (see docs/setup-MAF-FH-OBO.md §5 and docs/setup-MAF-FH-S2S.md §5).
#
# NON-FATAL by design: telemetry is best-effort; a failure here must not fail a lab run.
# Restart the agent container afterward (its managed-identity token is cached from before the grant).
#
# Usage:
#   ./assign-observability-role.ps1 -PrincipalId <agent-identity-SP-objectId>
#
# The PrincipalId is the objectId of the SP whose appId the exporter presents (the one named
# in a 403 from the observability endpoint). For an FH agent it is the agent identity / managed
# identity service principal.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PrincipalId,

    # Agent365Observability resource application (appId). Stable well-known value.
    [string]$ObservabilityAppId = '9b975845-388f-4429-889e-eab1ef63949c',

    # `Agent365.Observability.OtelWrite` application app-role id. Stable well-known value.
    [string]$OtelWriteRoleId = '8f71190c-00c8-461d-a63b-f74abde9ba52'
)

$ErrorActionPreference = 'Stop'

try {
    Write-Host "Resolving Agent365Observability service principal ($ObservabilityAppId)..."
    $obsSpId = az ad sp show --id $ObservabilityAppId --query id -o tsv 2>$null
    if (-not $obsSpId) {
        # Not provisioned in this tenant yet — create it (idempotent).
        az ad sp create --id $ObservabilityAppId 2>$null | Out-Null
        $obsSpId = az ad sp show --id $ObservabilityAppId --query id -o tsv 2>$null
    }
    if (-not $obsSpId) {
        Write-Warning "Could not resolve the Agent365Observability SP. Skipping OtelWrite grant."
        return
    }

    # Idempotency: skip if the assignment already exists.
    $existing = az rest --method GET `
        --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments" `
        --query "value[?appRoleId=='$OtelWriteRoleId' && resourceId=='$obsSpId'] | [0].id" -o tsv 2>$null
    if ($existing) {
        Write-Host "OtelWrite already assigned to $PrincipalId (assignment $existing). Nothing to do."
        return
    }

    Write-Host "Assigning Agent365.Observability.OtelWrite to $PrincipalId ..."
    $body = @{
        principalId = $PrincipalId
        resourceId  = $obsSpId
        appRoleId   = $OtelWriteRoleId
    } | ConvertTo-Json -Compress

    az rest --method POST `
        --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments" `
        --headers "Content-Type=application/json" `
        --body $body | Out-Null

    Write-Host "OtelWrite granted. Restart the agent container so it re-acquires a token that carries the role."
}
catch {
    Write-Warning "OtelWrite grant failed (continuing): $($_.Exception.Message)"
    Write-Warning "Grant it manually per docs/setup-MAF-FH-OBO.md §5, then restart the container."
}
