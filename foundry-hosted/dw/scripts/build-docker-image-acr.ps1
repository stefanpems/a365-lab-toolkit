# Build Docker image using Azure Container Registry (ACR) Build
# This script uses ACR Tasks to build the image in the cloud instead of locally

Set-Location "$($PSScriptRoot)/../src/hello_world_a365_agent"

Remove-Item "./__pycache__" -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path . -Filter "__pycache__" -Recurse -Force -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "./.vs" -Recurse -Force -ErrorAction SilentlyContinue

$authorityEndpoint = "https://login.microsoftonline.com/$($env:TENANT_ID)"
$azureOpenAIEndpoint = "https://$($env:ACCOUNT_NAME).openai.azure.com/"
# Preferred model path: the Foundry PROJECT endpoint. Routing inference through it gives every
# autopilot instance identity implicit model access (no per-instance Cognitive Services role).
$projectEndpoint = if ($env:AZURE_AI_PROJECT_ENDPOINT) {
    $env:AZURE_AI_PROJECT_ENDPOINT
} else {
    "https://$($env:ACCOUNT_NAME).services.ai.azure.com/api/projects/$($env:PROJECT_NAME)"
}


$acrLoginServer = $env:AZURE_CONTAINER_REGISTRY_ENDPOINT

# split the login server to get the registry name
$registryName = $acrLoginServer.Split(".")[0]

$imageName = "hello-world-a365-agent:latest"

Write-Host "Building image using ACR Build in registry: $registryName"

# Force UTF-8 for the child az process (helps, but is not sufficient on its own).
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"

# KNOWN WINDOWS BUG: `az acr build` streams the remote build log through colorama and can
# crash with UnicodeEncodeError ('charmap' codec can't encode / cp1252) on non-ASCII pip
# output, returning exit code 1 EVEN THOUGH the server-side build actually SUCCEEDS. azd
# runs this hook under a conpty, so redirecting/piping stdout does not reliably suppress it.
# Therefore we DO NOT trust az's exit code alone: if it exits non-zero we verify the real
# ACR run status and only fail if the build genuinely did not succeed.

# Build image using ACR Build (builds in the cloud)
az acr build `
    --registry $registryName `
    --image $imageName `
    --file "./foundry-infra/Dockerfile" `
    --build-arg BLUEPRINT_CLIENT_ID=$env:AGENT_IDENTITY_BLUEPRINT_ID `
    --build-arg AUTHORITY_ENDPOINT=$authorityEndpoint `
    --build-arg TENANT_ID=$env:TENANT_ID `
    --build-arg AZURE_OPENAI_ENDPOINT=$azureOpenAIEndpoint `
    --build-arg MODEL_DEPLOYMENT=$env:MODEL_NAME `
    --build-arg AZURE_AI_PROJECT_ENDPOINT=$projectEndpoint `
    .
$azExit = $LASTEXITCODE

if ($azExit -ne 0) {
    Write-Warning "az acr build exited $azExit (likely the Windows log-streaming/cp1252 CLI bug). Verifying server-side run status..."
    $ok = $false
    $status = $null
    for ($i = 0; $i -lt 30; $i++) {
        $runs = az acr task list-runs --registry $registryName --top 1 -o json 2>$null | ConvertFrom-Json
        $status = if ($runs) { $runs[0].status } else { $null }
        if ($status -eq 'Succeeded') { $ok = $true; break }
        if ($status -in @('Failed', 'Canceled', 'Error', 'Timeout')) { break }
        Start-Sleep -Seconds 10
    }
    if (-not $ok) {
        throw "ACR build failed (az exit $azExit; last run status '$status')."
    }
    Write-Host "Server-side ACR build succeeded despite the CLI streaming crash; continuing."
}

Write-Host "Image built and pushed successfully: $acrLoginServer/$imageName"
