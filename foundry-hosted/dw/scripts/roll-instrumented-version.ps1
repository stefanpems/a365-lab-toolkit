# Rolls a new hosted agent version that injects Application Insights into the container env.
# Reuses the existing container image (no rebuild). Idempotent-ish: creates a new version each run.
$ErrorActionPreference = 'Stop'

$ep    = "https://dwfhhxvtywwocznayacct.services.ai.azure.com/api/projects/dwfhhxvtywwocznayproj"
$agent = "sample-fh-dw-agent"
$acr   = "dwfhhxvtywwocznayacr.azurecr.io"
$maib  = "sample-fh-dw-agent-maib"

# App Insights connection string (dwfh2-appinsights)
$conn = $env:APPLICATIONINSIGHTS_CONNECTION_STRING
if (-not $conn) {
    $conn = az monitor app-insights component show --app dwfh2-appinsights -g sample-fh-dw-rg --query connectionString -o tsv
}

$tok = az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv
$headers = @{
    "Content-Type"     = "application/json"
    "Accept"           = "application/json"
    "Authorization"    = "Bearer $tok"
    "Foundry-Features" = "HostedAgents=V1Preview,AgentEndpoints=V1Preview"
}

$body = @{
    definition = @{
        kind                        = "hosted"
        image                       = "$acr/hello-world-a365-agent:latest"
        cpu                         = "2"
        memory                      = "4Gi"
        environment_variables       = @{
            APPLICATIONINSIGHTS_CONNECTION_STRING = $conn
            LOG_LEVEL                             = "INFO"
        }
        container_protocol_versions = @(@{ protocol = "activity_protocol"; version = "v1" })
    }
    metadata            = @{ enableVnextExperience = "true" }
    description         = "Foundry digital worker (App Insights instrumented)."
    agent_endpoint      = @{ protocols = @("activity") }
    blueprint_reference = @{ type = "ManagedAgentIdentityBlueprint"; blueprint_id = $maib }
} | ConvertTo-Json -Depth 8

Write-Host "Creating new agent version..." -ForegroundColor Cyan
$resp = Invoke-RestMethod -Uri "$ep/agents/$agent/versions?api-version=2025-11-15-preview" -Method Post -Headers $headers -Body $body
$ver = $resp.version
Write-Host "Created version=$ver status=$($resp.status)" -ForegroundColor Green

# Poll until active
$pollUrl = "$ep/agents/$agent/versions/$ver`?api-version=2025-11-15-preview"
$status = $resp.status
for ($i = 0; $i -lt 30 -and $status -ne 'active' -and $status -ne 'failed'; $i++) {
    Start-Sleep -Seconds 10
    try {
        $p = Invoke-RestMethod -Uri $pollUrl -Method Get -Headers $headers
        $status = $p.status
    } catch { Write-Host "poll error: $($_.Exception.Message)" }
    Write-Host "  status=$status"
}
Write-Host "Final status: $status" -ForegroundColor Yellow
if ($status -ne 'active') { throw "Version $ver did not become active (status=$status)." }
Write-Host "New instrumented version $ver is active and @latest now serves it." -ForegroundColor Green
