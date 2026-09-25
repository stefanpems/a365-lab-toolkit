#requires -Version 5.1
<#
.SYNOPSIS
  Deploy the lab's web-fetch MCP server (one tool: fetch_url) to Azure Container Apps and wire its URL
  into the Foundry declarative (FD) agents' .env - resource-safe, non-interactive, idempotent.
.DESCRIPTION
  WHY: FD prompt agents run no custom code, so they get web access (URL reachability + page text) from
  this anonymous MCP server, attached DIRECTLY to each FD agent as an MCPTool (no token). The ACA / FH
  agents do NOT need it: they carry the same fetch_url as an in-process function tool (web_fetch.py).

  Steps: resource group (create if missing; tagged a365component=web-fetch and, for a lab,
  a365lab=<prefix> so the Lab Cleaner removes it) -> Azure Container Registry (reuse or create) ->
  cloud image build (az acr build --no-logs, unique tag per run) -> Container Apps environment (reuse or
  create) -> ONE Container App, single replica (FastMCP keeps the MCP session in memory per replica) ->
  readiness (/health) -> MCP SMOKE TEST (initialize, tools/list must contain fetch_url, tools/call).

  SAFETY GATE: WEB_FETCH_MCP_URL is written into the FD agents' .env ONLY when the smoke test passes.
  On ANY failure it is CLEARED (empty = the FD agent deploys WITHOUT web access), because a prompt agent
  whose MCP tool cannot enumerate its tools fails EVERY turn. The rest of the lab is never blocked.

  RESOURCE-SAFE: never deletes anything; re-running rolls a new revision with a fresh image tag.
  The constants below are rewritten by the Lab Builder scaffolder (scaffold.webfetch.ps1) from the plan.
.PARAMETER Subscription
  Target subscription id. Pinned on every az command.
.EXAMPLE
  .\deploy-web-fetch.ps1 -Subscription 00000000-0000-0000-0000-000000000000
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$Subscription
)
$ErrorActionPreference = 'Stop'

# --- Constants (rewritten by scaffold.webfetch.ps1 from the deployment plan) -----------------
$RG           = "sample-webfetch-rg"
$ENVNAME      = "sample-webfetch-cae"
$LOC          = "swedencentral"
$REPO         = "sample-webfetch"
$APP          = "sample-webfetch-ca"
$LAB          = ""      # lab prefix -> RG tag a365lab=<prefix> (empty = standalone, no lab ownership tag)
$FD_ENV_FILES = @()     # FD agents' .env files that receive WEB_FETCH_MCP_URL
$URL_FILE     = ""      # where the verified URL is persisted (re-scaffold safe); empty = not persisted
# ---------------------------------------------------------------------------------------------

$SubArg = @('--subscription', $Subscription)
$env:PYTHONIOENCODING = 'utf-8'; $env:PYTHONUTF8 = '1'   # az CLI log/encoding hygiene on Windows

function Set-DotEnvValue {
    # Set KEY=VALUE in a .env file (replace an existing, possibly commented, KEY line; else append).
    param([string]$Path, [string]$Key, [string]$Value)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { Write-Host "  skip (folder missing): $Path" -ForegroundColor DarkYellow; return $false }
    $lines = if (Test-Path -LiteralPath $Path) { @(Get-Content -LiteralPath $Path) } else { @() }
    $set = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*#?\s*$([regex]::Escape($Key))=") { $lines[$i] = "$Key=$Value"; $set = $true }
    }
    if (-not $set) { $lines = @($lines) + "$Key=$Value" }
    # UTF-8 WITHOUT BOM (python-dotenv would otherwise read the BOM into the first key).
    [System.IO.File]::WriteAllLines($Path, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
    return $true
}

function Publish-WebFetchUrl {
    # Write (or clear, when $Url is empty) WEB_FETCH_MCP_URL in every FD .env + the persisted URL file.
    param([string]$Url)
    foreach ($f in $FD_ENV_FILES) {
        if (Set-DotEnvValue -Path $f -Key 'WEB_FETCH_MCP_URL' -Value $Url) { Write-Host "  WEB_FETCH_MCP_URL=$Url -> $f" }
    }
    if ($URL_FILE) {
        if ($Url) { [System.IO.File]::WriteAllText($URL_FILE, $Url, (New-Object System.Text.UTF8Encoding($false))) }
        elseif (Test-Path -LiteralPath $URL_FILE) { Remove-Item -LiteralPath $URL_FILE -Force }
    }
}

function Invoke-McpPost {
    # One MCP streamable-HTTP JSON-RPC POST; returns status, session id and the parsed JSON payload
    # (the response may be plain JSON or an SSE stream whose last 'data:' line carries the JSON).
    param([string]$Url, [hashtable]$Body, [string]$SessionId)
    $headers = @{ Accept = 'application/json, text/event-stream' }
    if ($SessionId) { $headers['Mcp-Session-Id'] = $SessionId }
    $resp = Invoke-WebRequest -Uri $Url -Method Post -Headers $headers -ContentType 'application/json' `
        -Body ($Body | ConvertTo-Json -Depth 10 -Compress) -TimeoutSec 60 -UseBasicParsing
    $content = if ($resp.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($resp.Content) } else { [string]$resp.Content }
    $sid = $null
    foreach ($k in @($resp.Headers.Keys)) { if ($k -ieq 'mcp-session-id') { $sid = @($resp.Headers[$k])[0] } }
    $dataLines = @($content -split "`r?`n" | Where-Object { $_ -like 'data:*' })
    $raw = if ($dataLines.Count) { $dataLines[-1] -replace '^data:\s*', '' } else { $content }
    $payload = $null
    if ($raw -and $raw.Trim()) { try { $payload = $raw | ConvertFrom-Json } catch { $payload = $null } }
    [pscustomobject]@{ Status = [int]$resp.StatusCode; SessionId = $sid; Payload = $payload }
}

function Test-WebFetchMcp {
    # $true only when the server lists 'fetch_url' (what a Foundry MCPTool enumerates on every turn).
    param([string]$McpUrl)
    $init = Invoke-McpPost -Url $McpUrl -Body @{
        jsonrpc = '2.0'; id = 1; method = 'initialize'
        params  = @{ protocolVersion = '2025-03-26'; capabilities = @{}; clientInfo = @{ name = 'deploy-web-fetch'; version = '1.0' } }
    }
    if (-not ($init.Payload -and $init.Payload.result)) { Write-Host "  MCP initialize failed (HTTP $($init.Status))." -ForegroundColor Yellow; return $false }
    $sid = $init.SessionId
    $null = Invoke-McpPost -Url $McpUrl -Body @{ jsonrpc = '2.0'; method = 'notifications/initialized' } -SessionId $sid
    $list = Invoke-McpPost -Url $McpUrl -Body @{ jsonrpc = '2.0'; id = 2; method = 'tools/list'; params = @{} } -SessionId $sid
    $names = @($list.Payload.result.tools | ForEach-Object { $_.name })
    Write-Host "  MCP tools/list: $($names -join ', ')"
    if ($names -notcontains 'fetch_url') { return $false }
    # Informational: a real call (egress). A non-200 here does NOT block (the tool still enumerates).
    try {
        $call = Invoke-McpPost -Url $McpUrl -SessionId $sid -Body @{
            jsonrpc = '2.0'; id = 3; method = 'tools/call'
            params  = @{ name = 'fetch_url'; arguments = @{ url = 'https://example.com/'; max_chars = 200 } }
        }
        $sc = $call.Payload.result.structuredContent
        if ($sc) { Write-Host "  fetch_url(https://example.com/): reachable=$($sc.reachable) http_status=$($sc.http_status) title='$($sc.title)'" }
        else { Write-Host "  fetch_url call returned: $(($call.Payload | ConvertTo-Json -Depth 6 -Compress))" }
    } catch { Write-Host "  fetch_url test call failed (non-blocking): $($_.Exception.Message)" -ForegroundColor Yellow }
    return $true
}

$mcpUrl = $null
try {
    Write-Host "Deploying the web-fetch MCP server '$APP' to RG '$RG' ($LOC)..." -ForegroundColor Cyan
    az account set @SubArg | Out-Null
    az extension add --name containerapp --upgrade --only-show-errors 2>$null | Out-Null
    foreach ($ns in 'Microsoft.App', 'Microsoft.OperationalInsights', 'Microsoft.ContainerRegistry') {
        az provider register --namespace $ns --wait @SubArg 2>$null | Out-Null
    }

    # Resource group (create if absent; never deleted) + durable tags.
    if ((az group exists -n $RG @SubArg) -ne 'true') {
        az group create -n $RG -l $LOC @SubArg -o none
        if ($LASTEXITCODE -ne 0) { throw "Could not create resource group '$RG'." }
    }
    az group update -n $RG --set "tags.a365component=web-fetch" @SubArg -o none 2>$null
    if ($LAB) { az group update -n $RG --set "tags.a365lab=$LAB" @SubArg -o none 2>$null }

    # Azure Container Registry (reuse the one in the RG, else create a uniquely named one).
    $acr = az acr list -g $RG @SubArg --query "[0].name" -o tsv 2>$null
    if (-not $acr) {
        $acr = "webfetch" + (Get-Random -Minimum 10000 -Maximum 99999)
        az acr create -g $RG -n $acr --sku Basic -l $LOC @SubArg -o none
        if ($LASTEXITCODE -ne 0) { throw "Could not create the container registry '$acr'." }
    }
    $acrServer = "$acr.azurecr.io"

    # Cloud build with a UNIQUE tag (a new revision is guaranteed on every run).
    # --no-logs avoids the Windows colorama/cp1252 crash of the streamed build log.
    $tag = "1.0.0-" + (Get-Date -Format 'yyyyMMddHHmmss')
    $image = "${REPO}:$tag"
    Write-Host "Building $acrServer/$image (az acr build --no-logs)..." -ForegroundColor Cyan
    Push-Location $PSScriptRoot
    try { az acr build --registry $acr --image $image --no-logs @SubArg . -o none } finally { Pop-Location }
    $run = az acr task list-runs --registry $acr --top 1 @SubArg --query "[0].{status:status,tag:outputImages[0].tag}" -o json | ConvertFrom-Json
    if (-not $run -or $run.status -ne 'Succeeded' -or $run.tag -ne $tag) { throw "Image build did not succeed (last run: $($run.status) / $($run.tag))." }

    # Container Apps environment (reuse or create).
    if (-not (az containerapp env show -n $ENVNAME -g $RG @SubArg --query name -o tsv 2>$null)) {
        az containerapp env create -n $ENVNAME -g $RG -l $LOC --logs-destination none @SubArg -o none
        if ($LASTEXITCODE -ne 0) { throw "Could not create the Container Apps environment '$ENVNAME' in '$LOC' (quota/capacity?)." }
    }

    # The Container App: single replica (FastMCP keeps the MCP session in memory per replica).
    $envVars = @('PORT=8000', 'FASTMCP_HTTP_HOST_ORIGIN_PROTECTION=false')
    if (az containerapp show -n $APP -g $RG @SubArg --query name -o tsv 2>$null) {
        az containerapp update -n $APP -g $RG --image "$acrServer/$image" --min-replicas 1 --max-replicas 1 --set-env-vars @envVars @SubArg -o none
    } else {
        az containerapp create -n $APP -g $RG --environment $ENVNAME `
            --image "$acrServer/$image" --registry-server $acrServer --registry-identity system `
            --target-port 8000 --ingress external --min-replicas 1 --max-replicas 1 `
            --env-vars @envVars @SubArg -o none
    }
    if ($LASTEXITCODE -ne 0) { throw "Container App create/update failed for '$APP'." }

    $st = $null
    for ($i = 0; $i -lt 40; $i++) {
        $st = az containerapp show -n $APP -g $RG @SubArg --query "{rev:properties.latestRevisionName,ready:properties.latestReadyRevisionName,fqdn:properties.configuration.ingress.fqdn,image:properties.template.containers[0].image}" -o json | ConvertFrom-Json
        if ($st -and $st.rev -and $st.rev -eq $st.ready -and $st.image -eq "$acrServer/$image") { break }
        Start-Sleep -Seconds 10
    }
    if (-not ($st -and $st.fqdn)) { throw "Could not resolve the Container App FQDN." }
    Write-Host "Revision $($st.rev) ready=$($st.ready) image=$($st.image)"
    $candidate = "https://$($st.fqdn)/mcp"

    # Readiness + MCP smoke test (retries cover the cold start).
    $ok = $false
    for ($i = 1; $i -le 12 -and -not $ok; $i++) {
        try {
            $h = Invoke-WebRequest -Uri "https://$($st.fqdn)/health" -TimeoutSec 20 -UseBasicParsing
            if ([int]$h.StatusCode -eq 200) { $ok = Test-WebFetchMcp -McpUrl $candidate }
        } catch { Write-Host "  attempt $i/12: $($_.Exception.Message)" -ForegroundColor DarkGray }
        if (-not $ok) { Start-Sleep -Seconds 10 }
    }
    if (-not $ok) { throw "The web-fetch MCP server at $candidate did not pass the smoke test (fetch_url not listed)." }
    $mcpUrl = $candidate
}
catch {
    Write-Host ""
    Write-Host "WEB-FETCH MCP DEPLOY FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Clearing WEB_FETCH_MCP_URL so the FD agents deploy WITHOUT web access (nothing else is affected)." -ForegroundColor Yellow
    Publish-WebFetchUrl -Url ''
    Write-Host "Fix the cause and re-run this script, then redeploy the FD agents (python deploy_agent.py) to add web access." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "Web-fetch MCP server deployed and verified: $mcpUrl" -ForegroundColor Green
Publish-WebFetchUrl -Url $mcpUrl
if ($FD_ENV_FILES.Count) {
    Write-Host "Next: deploy (or redeploy) the FD agents - 'python deploy_agent.py' now attaches the 'web_fetch' MCP tool (fetch_url)." -ForegroundColor Green
}
