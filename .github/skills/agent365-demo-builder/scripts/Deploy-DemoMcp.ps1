#requires -Version 7.0
<#
.SYNOPSIS
  Builds the demo-pack MCP image in the cloud (az acr build, no local Docker) and deploys ONE Container App per demo
  backend (for agent-governance: records, companies, deadlines, forms), each serving one MCP server at the root '/mcp'.
.DESCRIPTION
  Same deployment rules as the Lab Builder sample servers (see the header of custom-mcp/deploy-mcp.ps1 for WHY):
  single-segment '/mcp' path, a single replica (min = max = 1) and '--no-logs' on az acr build.
  The build context is a staging copy of demo-packs/<pack>/mcp plus mcp-config.json generated from the lab locale
  (org + mcp.servers), so tool names, descriptions and data are in the demo language. The image tag is a content hash:
  an unchanged pack/locale reuses the existing image. Only the selected backends are (re)deployed.
  Azure: RG <prefix>-demomcp-rg (tags a365lab=<prefix> -> deleted by the Lab Cleaner; a365component=demo-mcp),
  one ACR, one Container Apps environment, apps <prefix>-dmcp-<key>-ca. RESOURCE-SAFE: creates if missing, reuses
  otherwise, never deletes. Every backend is verified (GET /health, then MCP tools/list = the declared tool names)
  and its URL is saved in state.json (mcp.backends.<key>) for New-DemoMcpRegistration.ps1.
.EXAMPLE
  pwsh -File .\Deploy-DemoMcp.ps1 -Prefix cts2 -WhatIf
.EXAMPLE
  pwsh -File .\Deploy-DemoMcp.ps1 -Prefix cts2 -Server records,companies
#>
[CmdletBinding(PositionalBinding = $false)]
param([Parameter(Mandatory)][string]$Prefix, [string[]]$Server = @('all'), [string]$Region, [string]$ImageTag, [switch]$WhatIf)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_demo-common.ps1')
$Server = @($Server | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$cfg = Read-DemoConfig $Prefix
$pack = Get-DemoPack $cfg.pack
$LOC = Get-DemoLocale -Locale $cfg.locale -Pack $cfg.pack
$defs = @(@($pack.mcp.longLived) + @($pack.mcp.pool))
$keys = @($defs | ForEach-Object { [string]$_.key })
$sel = if ($Server -contains 'all') { $keys } else { $Server }
foreach ($k in $sel) { if ($keys -notcontains $k) { throw "Unknown MCP backend '$k' (backends of pack '$($cfg.pack)': $($keys -join ', '))." } }
$names = Get-DemoMcpAzureNames $Prefix
$region = if ($Region) { $Region } elseif ($cfg.region) { [string]$cfg.region } else { throw 'No region: pass -Region or set it with New-DemoConfig.ps1 -Region.' }

# --- Build context: pack mcp folder + locale-generated mcp-config.json ------------------------------------------
$src = Join-Path (Get-DemoPackDir $cfg.pack) 'mcp'
$stage = Join-Path (Get-DemoLabDir $Prefix) 'mcp-build'
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
foreach ($f in 'server.py', 'requirements.txt', 'Dockerfile') { Copy-Item -LiteralPath (Join-Path $src $f) -Destination $stage }
[ordered]@{ org = $LOC.org; servers = $LOC.mcp.servers } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $stage 'mcp-config.json') -Encoding utf8
if (-not $ImageTag) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = foreach ($f in 'server.py', 'requirements.txt', 'Dockerfile', 'mcp-config.json') { [System.IO.File]::ReadAllBytes((Join-Path $stage $f)) }
    $ImageTag = 'c' + ([System.BitConverter]::ToString($sha.ComputeHash([byte[]]$bytes)) -replace '-', '').Substring(0, 12).ToLowerInvariant()
}
$image = "$([string]$pack.mcp.backendImage):$ImageTag"

Write-DemoLog $Prefix "Demo MCP deploy: backends [$($sel -join ', ')], locale $($cfg.locale), image $image, RG $($names.resourceGroup) ($region)$(if ($WhatIf) { ' [WhatIf]' })"
foreach ($k in $sel) {
    $d = $defs | Where-Object { [string]$_.key -eq $k } | Select-Object -First 1
    Write-Host ("  {0,-10} app {1,-26} tools [{2}]{3}" -f $k, "$($names.appPrefix)$k-ca", ((Get-DemoMcpDeclaredTools $LOC $k) -join ', '), $(if ($d.failureRate) { " FAILURE_RATE=$($d.failureRate)" }))
}
if ($WhatIf) { Write-Host "WhatIf: build context ready in $stage; nothing created in Azure."; return }
# --- Azure: RG (tagged), ACR, image, Container Apps environment ------------------------------------------------
Assert-DemoTenant $cfg
$SubArg = @('--subscription', [string]$cfg.subscriptionId)
az extension add --name containerapp --upgrade --only-show-errors 2>$null | Out-Null
foreach ($ns in 'Microsoft.App', 'Microsoft.OperationalInsights', 'Microsoft.ContainerRegistry') { az provider register --namespace $ns --wait @SubArg | Out-Null }
$RG = $names.resourceGroup
if ((az group exists -n $RG @SubArg) -ne 'true') { az group create -n $RG -l $region @SubArg -o none }
az group update -n $RG --set "tags.a365lab=$Prefix" "tags.a365component=$($names.component)" @SubArg -o none
if ($LASTEXITCODE -ne 0) { throw "Could not create or tag the resource group $RG." }
$acr = az acr list -g $RG @SubArg --query '[0].name' -o tsv 2>$null
if (-not $acr) {
    $acr = ($Prefix.ToLowerInvariant() -replace '[^a-z0-9]', '') + 'demomcp' + ([string]$cfg.subscriptionId -replace '-', '').Substring(0, 8)
    az acr create -g $RG -n $acr --sku Basic -l $region @SubArg -o none
    if ($LASTEXITCODE -ne 0) { throw "az acr create $acr failed." }
}
$acrServer = az acr show -n $acr -g $RG @SubArg --query loginServer -o tsv
$existingTags = @(az acr repository show-tags -n $acr --repository ([string]$pack.mcp.backendImage) @SubArg -o tsv 2>$null)
if ($existingTags -contains $ImageTag) { Write-DemoLog $Prefix "Image $image already in $acr (same content): build skipped" }
else {
    Write-DemoLog $Prefix "Building $image on $acr (cloud build, --no-logs)"
    az acr build --registry $acr --image $image --no-logs @SubArg $stage -o none
    if ($LASTEXITCODE -ne 0) { throw 'az acr build failed.' }
}
$envState = az containerapp env show -n $names.environment -g $RG @SubArg --query properties.provisioningState -o tsv 2>$null
if ($envState -eq 'Failed') {
    # A Failed environment (for example after a regional capacity error) is never usable: recreate it, but only when
    # no app lives in it (resource-safe).
    $apps = @(az containerapp list -g $RG @SubArg --query "[?contains(properties.managedEnvironmentId, '/$($names.environment)')].name" -o tsv 2>$null | Where-Object { $_ })
    if ($apps.Count) { throw "Container Apps environment $($names.environment) is Failed and hosts apps ($($apps -join ', ')): fix it by hand." }
    Write-DemoLog $Prefix "Container Apps environment $($names.environment) is Failed: deleting it to recreate it" 'WARN'
    az containerapp env delete -n $names.environment -g $RG @SubArg --yes -o none
    $envState = $null
}
if (-not $envState) {
    # AKSCapacityHeavyUsage = no capacity in the region right now: retry, then stop with the way out (another region).
    $created = $false
    for ($try = 1; $try -le 3 -and -not $created; $try++) {
        $out = az containerapp env create -n $names.environment -g $RG -l $region --logs-destination none @SubArg -o none 2>&1
        $created = $LASTEXITCODE -eq 0 -and (az containerapp env show -n $names.environment -g $RG @SubArg --query properties.provisioningState -o tsv 2>$null) -eq 'Succeeded'
        if ($created) { break }
        $capacity = ($out | Out-String) -match 'AKSCapacityHeavyUsage|heavy usage'
        Write-DemoLog $Prefix "az containerapp env create $($names.environment) failed (try $try/3)$(if ($capacity) { ': no capacity in the region (AKSCapacityHeavyUsage)' })" 'WARN'
        if ((az containerapp env show -n $names.environment -g $RG @SubArg --query properties.provisioningState -o tsv 2>$null) -eq 'Failed') { az containerapp env delete -n $names.environment -g $RG @SubArg --yes -o none }
        if (-not $capacity) { break }
        if ($try -lt 3) { Start-Sleep -Seconds 120 }
    }
    if (-not $created) { throw "az containerapp env create $($names.environment) failed in $region. On a capacity error choose another region for the whole lab (New-DemoConfig.ps1 -Prefix $Prefix -Region <region>, e.g. polandcentral), then re-run; the agents use the same region." }
}

# --- One app per backend, then /health and tools/list = declared tools ------------------------------------------
$state = Read-DemoLabState $Prefix
if (-not $state.mcp.Contains('backends')) { $state.mcp['backends'] = [ordered]@{} }
$failed = @()
foreach ($k in $sel) {
    $d = $defs | Where-Object { [string]$_.key -eq $k } | Select-Object -First 1
    $app = "$($names.appPrefix)$k-ca"
    $envVars = @('PORT=8000', 'FASTMCP_HTTP_HOST_ORIGIN_PROTECTION=false', "MCP_SERVER_MODE=$k")
    if ($null -ne $d.failureRate) { $envVars += "FAILURE_RATE=$($d.failureRate)" }
    az containerapp show -n $app -g $RG @SubArg -o none 2>$null
    if ($LASTEXITCODE -eq 0) {
        az containerapp update -n $app -g $RG --image "$acrServer/$image" --min-replicas 1 --max-replicas 1 --set-env-vars @envVars @SubArg -o none
    }
    else {
        az containerapp create -n $app -g $RG --environment $names.environment --image "$acrServer/$image" `
            --registry-server $acrServer --registry-identity system --target-port 8000 --ingress external `
            --min-replicas 1 --max-replicas 1 --env-vars @envVars @SubArg -o none
    }
    if ($LASTEXITCODE -ne 0) { $failed += $k; Write-DemoLog $Prefix "$app deploy FAILED (az exit $LASTEXITCODE)" 'ERROR'; continue }
    $fqdn = az containerapp show -n $app -g $RG @SubArg --query properties.configuration.ingress.fqdn -o tsv
    $url = "https://$fqdn/mcp"
    $healthy = $false
    for ($i = 0; $i -lt 18 -and -not $healthy; $i++) { try { $healthy = ((Invoke-RestMethod -Uri "https://$fqdn/health" -TimeoutSec 20).status -eq 'ok') } catch { Start-Sleep -Seconds 10 } }
    $exposed = @(); $match = $false
    if ($healthy) {
        try { $exposed = @(Get-DemoMcpBackendTools $url | Sort-Object) } catch { Write-DemoLog $Prefix "$app tools/list failed: $($_.Exception.Message)" 'WARN' }
        $declared = @(Get-DemoMcpDeclaredTools $LOC $k | Sort-Object)
        $match = $exposed.Count -gt 0 -and (($exposed -join ',') -eq ($declared -join ','))
    }
    $state.mcp.backends[$k] = [ordered]@{ app = $app; url = $url; image = $image; locale = $cfg.locale; healthy = $healthy; toolsMatch = $match; tools = $exposed; deployedAt = (Get-Date).ToString('s') }
    Save-DemoLabState $Prefix $state
    $ok = $healthy -and $match
    if (-not $ok) { $failed += $k }
    Write-DemoLog $Prefix ('{0} -> {1} (health {2}, tools {3}: [{4}])' -f $app, $url, $(if ($healthy) { 'ok' } else { 'KO' }), $(if ($match) { 'match' } else { 'MISMATCH' }), ($exposed -join ', ')) $(if ($ok) { 'INFO' } else { 'ERROR' })
}
if ($failed.Count) { throw "Demo MCP backends not ready: $($failed -join ', ') (details in generated\$Prefix\wizard-progress.log)." }
Write-DemoLog $Prefix "Demo MCP backends ready: $($sel -join ', '). Next: New-DemoMcpRegistration.ps1 -Prefix $Prefix"
