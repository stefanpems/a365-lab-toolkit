# Web SPA UI: copy ui/, drop the tenant-specific config.js, and regenerate it from the plan's
# exposed OBO/S2S agents (DW is never exposed). Emits the SWA create/deploy next-command.
# Reads $plan / $repoRoot / $OutRoot / $nextCommands from the router scope.

function Invoke-ScaffoldUi {
    $uiFolderName = "$($plan.solution.prefix)-ui"
    $uiDst = Join-Path $OutRoot $uiFolderName
    if (Test-Path -LiteralPath $uiDst) { Remove-Item -LiteralPath $uiDst -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path $repoRoot 'ui') -Destination $uiDst -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $uiDst 'config.js') -Force -ErrorAction SilentlyContinue

    $clientId  = if ($plan.ui.mode -eq 'attach') { $plan.ui.existing.spaAppId } else { '<YOUR_SPA_APP_ID>' }
    $exposeTypes = @($plan.ui.expose | ForEach-Object { $_.agentType })
    $uiAgents = New-Object System.Collections.Generic.List[object]

    # Custom (BYO) MCP: each attached OBO agent reaches the ext_ servers through the Agent 365 gateway
    # with a per-server delegated user token. The SPA needs each server's token AUDIENCE (BYO resource
    # app id) to acquire that token: read it from the attached agents' ToolingManifest.json (written by
    # 'a365 develop add-mcp-servers'). Empty until the servers are attached — RE-RUN this scaffolder
    # after attaching so config.js gains customScopes (ACA/FH-OBO) / customInputs (FD-OBO).
    $mcpEnabled = [bool]($plan.customMcp -and $plan.customMcp.enabled)
    $mcpName    = if ($mcpEnabled) { $plan.customMcp.name } else { '' }
    $mcpAttach  = if ($mcpEnabled) { @($plan.customMcp.attachTo) } else { @() }
    $audMap = @{}
    if ($mcpEnabled) {
        foreach ($att in $mcpAttach) {
            $aag = $plan.agents | Where-Object { $_.type -eq $att } | Select-Object -First 1
            if (-not $aag) { continue }
            $mani = Join-Path $OutRoot (Join-Path $aag.name 'ToolingManifest.json')
            if (-not (Test-Path -LiteralPath $mani)) { continue }
            try {
                foreach ($s in (Get-Content -LiteralPath $mani -Raw | ConvertFrom-Json).mcpServers) {
                    if ($s.mcpServerName -like 'ext_*' -and $s.audience) { $audMap[$s.mcpServerName] = $s.audience }
                }
            } catch {}
        }
        # Optional explicit override from the plan (filled after registration, if the manifest scan can't).
        if ($plan.customMcp.audiences) {
            if ($plan.customMcp.audiences.anon) { $audMap["ext_${mcpName}Anon"] = $plan.customMcp.audiences.anon }
            if ($plan.customMcp.audiences.auth) { $audMap["ext_${mcpName}Auth"] = $plan.customMcp.audiences.auth }
        }
    }

    foreach ($t in $exposeTypes) {
        if ($t -like '*-DW') { continue }  # DW never exposed via the SPA
        $ag = $plan.agents | Where-Object { $_.type -eq $t } | Select-Object -First 1
        if (-not $ag) { continue }
        $entry = switch ($t) {
            'ACA-OBO' { [ordered]@{ id='obo'; kind='aca'; name="$($ag.name) (ACA, OBO)"; description='OBO agent; /chat sends mail from your mailbox.'; apiBase='https://<YOUR_ACA_OBO_FQDN>'; scope='ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/McpServers.Mail.All' } }
            'ACA-S2S' { [ordered]@{ id='s2s'; kind='aca'; name="$($ag.name) (ACA, S2S)"; description='S2S blueprint agent; own identity.'; apiBase='https://<YOUR_ACA_S2S_FQDN>'; scope='api://<YOUR_ACA_S2S_APP_ID>/access_agent_as_user' } }
            'FH-OBO'  { [ordered]@{ id='obo-fh'; kind='foundry-invocations'; name="$($ag.name) (FH, OBO)"; description='Foundry Hosted OBO; gateway auth + mail_token.'; endpoint='https://<ACCOUNT>.services.ai.azure.com/api/projects/<PROJECT>/agents/'+$ag.name+'/endpoint/protocols/invocations?api-version=v1'; endpointScope='https://ai.azure.com/.default'; mailScope='ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/McpServers.Mail.All'; sessionPrefix='obo' } }
            'FH-S2S'  { [ordered]@{ id='s2s-fh'; kind='foundry-responses'; name="$($ag.name) (FH, S2S)"; description='Foundry Hosted S2S; own identity.'; endpoint='https://<ACCOUNT>.services.ai.azure.com/api/projects/<PROJECT>/agents/'+$ag.name+'/endpoint/protocols/openai/responses?api-version=v1'; endpointScope='https://ai.azure.com/.default' } }
            'FD-OBO'  { [ordered]@{ id='obo-fd'; kind='foundry-prompt'; name="$($ag.name) (FD, OBO)"; description='Foundry prompt OBO; project Responses + mail_token.'; endpoint='https://<ACCOUNT>.services.ai.azure.com/api/projects/<PROJECT>/openai/v1/responses'; endpointScope='https://ai.azure.com/.default'; agentName=$ag.name; mailScope='ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/McpServers.Mail.All' } }
            'FD-S2S'  { [ordered]@{ id='s2s-fd'; kind='foundry-prompt'; name="$($ag.name) (FD, S2S)"; description='Foundry prompt S2S; own identity.'; endpoint='https://<ACCOUNT>.services.ai.azure.com/api/projects/<PROJECT>/openai/v1/responses'; endpointScope='https://ai.azure.com/.default'; agentName=$ag.name } }
            default   { $null }
        }
        if ($entry) {
            # Attach the custom-MCP token wiring when this OBO agent is a custom-MCP target and its
            # ext_ server audiences are known (from the manifest scan above).
            if ($mcpEnabled -and ($mcpAttach -contains $t)) {
                $anonExt = "ext_${mcpName}Anon"; $authExt = "ext_${mcpName}Auth"
                if ($t -eq 'ACA-OBO' -or $t -eq 'FH-OBO') {
                    $cs = [ordered]@{}
                    foreach ($ext in @($anonExt, $authExt)) { if ($audMap[$ext]) { $cs[$audMap[$ext]] = "$($audMap[$ext])/Tools.ListInvoke.All" } }
                    if ($cs.Count -gt 0) { $entry['customScopes'] = $cs }
                } elseif ($t -eq 'FD-OBO') {
                    $ci = [ordered]@{}
                    if ($audMap[$anonExt]) { $ci['anon_token'] = "$($audMap[$anonExt])/Tools.ListInvoke.All" }
                    if ($audMap[$authExt]) { $ci['auth_token'] = "$($audMap[$authExt])/Tools.ListInvoke.All" }
                    if ($ci.Count -gt 0) { $entry['customInputs'] = $ci }
                }
            }
            $uiAgents.Add($entry)
        }
    }
    $appConfig = [ordered]@{
        msal   = [ordered]@{ clientId = $clientId; authority = "https://login.microsoftonline.com/$($plan.solution.tenantId)" }
        agents = $uiAgents
    }
    $json = $appConfig | ConvertTo-Json -Depth 8
    "// Generated by scaffold-from-plan.ps1 — fill <PLACEHOLDER> FQDNs/endpoints after each agent deploys.`nwindow.APP_CONFIG = $json;" |
        Set-Content -LiteralPath (Join-Path $uiDst 'config.js')
    Write-Host "  scaffolded UI ($($plan.ui.mode)) -> generated\$uiFolderName\config.js ($($uiAgents.Count) tab(s))" -ForegroundColor Cyan
    $nextCommands.Add("# UI: create SWA (az staticwebapp create -l eastus2 --sku Free; westeurope may reject new customers), register the SPA app (redirect https://<swa-host> + http://localhost:3000), fill config.js, deploy per docs/setup-web-ui.md, then set UI_ALLOWED_ORIGINS (+ UI_AUDIENCE=<s2s-app-id> for ACA-S2S) on the ACA containers.")
    if ($mcpEnabled -and (@($mcpAttach | Where-Object { $_ -eq 'ACA-OBO' -or $_ -eq 'FH-OBO' -or $_ -eq 'FD-OBO' }).Count -gt 0)) {
        $nextCommands.Add("# UI + custom MCP: after you ATTACH the ext_ servers to the OBO agents (add-mcp-servers) / deploy FD-OBO with CUSTOM_MCP_SERVERS_JSON, RE-RUN this scaffolder so config.js gains customScopes (ACA/FH-OBO) / customInputs (FD-OBO) read from each agent's ToolingManifest.json, then redeploy the SPA. Each user also creates the one-time Power Platform connection per ext_ server (make.powerapps.com) as themselves; OBO reuses that connection across ACA/FH/FD. If 'npx @azure/static-web-apps-cli deploy' fails (exit 1), run the StaticSitesClient.exe uploader directly from the repo root: & <hash>\StaticSitesClient.exe upload --app ui --apiToken <tok> --skipAppBuild true (see docs/setup-web-ui.md).")
    }
}
