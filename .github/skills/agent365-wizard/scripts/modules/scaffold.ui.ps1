# Web SPA UI: copy ui/, drop the tenant-specific config.js, and regenerate it from the plan's
# exposed OBO/S2S agents (DW is never exposed). Emits the SWA create/deploy next-command.
# Reads $plan / $repoRoot / $RunRoot / $McpBaseName / $nextCommands from the router scope.

function Invoke-ScaffoldUi {
    $uiFolderName = "$($plan.solution.prefix)-ui"
    # SWA Free is only offered in a few regions (eastus2/centralus/eastasia/westeurope/westus2) and SWA
    # serves from a global CDN, so it need not match the lab region. Use the plan's swaRegion (the wizard
    # asks the user when the lab region isn't SWA-capable); a placeholder or a non-SWA value (e.g. the lab
    # region swedencentral) falls back to the validated eastus2 so the emitted command is never invalid.
    $swaAllowed = @('eastus2', 'centralus', 'eastasia', 'westeurope', 'westus2')
    $swaRegion  = if ($plan.ui.swaRegion -and ($plan.ui.swaRegion -in $swaAllowed)) { $plan.ui.swaRegion } else { 'eastus2' }
    if ($plan.ui.swaRegion -and ($plan.ui.swaRegion -notin $swaAllowed) -and ($plan.ui.swaRegion -notmatch '^<')) {
        Write-Host "  note: ui.swaRegion '$($plan.ui.swaRegion)' is not an SWA Free region; using '$swaRegion' (SWA serves from a global CDN, so region need not match the lab)." -ForegroundColor DarkYellow
    }
    $uiDst = Join-Path $RunRoot $uiFolderName
    if (Test-Path -LiteralPath $uiDst) { Remove-Item -LiteralPath $uiDst -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path $repoRoot 'ui') -Destination $uiDst -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $uiDst 'config.js') -Force -ErrorAction SilentlyContinue

    $clientId  = if ($plan.ui.mode -eq 'attach') { $plan.ui.existing.spaAppId } else { '<YOUR_SPA_APP_ID>' }
    $exposeTypes = @($plan.ui.expose | ForEach-Object { $_.agentType })
    $uiAgents = New-Object System.Collections.Generic.List[object]

    # Custom (BYO) MCP: each attached OBO agent reaches the ext_ servers through the Agent 365 gateway
    # with a per-server delegated user token. The SPA needs each server's token AUDIENCE (BYO resource
    # app id) to acquire that token. Sources, in order: (1) plan.customMcp.audiences (fill it with the
    # ext_<name>Anon/Auth BYO app ids right after registration -> customScopes are produced on the FIRST
    # scaffold, so EVERY OBO tab integrates the custom MCP immediately); (2) the attached agents'
    # ToolingManifest.json (written by 'a365 develop add-mcp-servers'), which requires re-running this
    # scaffolder after attaching. Prefer (1) so the custom tools are never left as "Mail only".
    $mcpEnabled = [bool]($plan.customMcp -and $plan.customMcp.enabled)
    $mcpName    = if ($mcpEnabled) { $McpBaseName } else { '' }  # derived from the solution prefix (not asked)
    $mcpAttach  = if ($mcpEnabled) { @($plan.customMcp.attachTo) } else { @() }
    $audMap = @{}
    if ($mcpEnabled) {
        foreach ($att in $mcpAttach) {
            $aag = $plan.agents | Where-Object { $_.type -eq $att } | Select-Object -First 1
            if (-not $aag) { continue }
            $mani = Join-Path $RunRoot (Join-Path $aag.name 'ToolingManifest.json')
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
            # Every tab is scaffolded HIDDEN (enabled:false): the sidebar link is revealed only when
            # the agent is live, by flipping this to true in the same config.js edit that fills the
            # agent's FQDN/endpoint after it deploys (see the incremental integration step).
            $entry['enabled'] = $false
            # FD reuses a KNOWN Foundry project, so resolve its Responses endpoint at scaffold time
            # (normalize the account host to services.ai.azure.com — the prompt-agent path 404s on the
            # cognitiveservices.azure.com host). FH accounts are created at provision, so they stay
            # <ACCOUNT>/<PROJECT> placeholders filled during the incremental post-deploy wiring.
            if (($t -eq 'FD-OBO' -or $t -eq 'FD-S2S') -and $ag.foundryProject) {
                $fpUi = $ag.foundryProject -replace '\.cognitiveservices\.azure\.com', '.services.ai.azure.com'
                if ($fpUi -match '/api/projects/') { $entry['endpoint'] = ($fpUi.TrimEnd('/')) + '/openai/v1/responses' }
            }
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
    $nextCommands.Add("# UI: create SWA (az staticwebapp create -l $swaRegion --sku Free; SWA Free is region-limited [eastus2/centralus/eastasia/westeurope/westus2] and served from a global CDN, so it need not match the lab region - westeurope may reject new customers, eastus2 is validated), register the SPA app (redirect https://<swa-host> + http://localhost:3000), fill config.js, deploy per docs/setup-web-ui.md (use StaticSitesClient.exe directly from the REPO ROOT with an absolute --app path - the 'npx @azure/static-web-apps-cli deploy' wrapper exits 1), then set UI_ALLOWED_ORIGINS (+ UI_AUDIENCE=<s2s-app-id> for ACA-S2S) on the ACA containers.")
    $nextCommands.Add("# UI sidebar reveal: every tab is scaffolded HIDDEN (enabled:false). As each OBO/S2S agent goes live, in the SAME config.js edit that fills its FQDN/endpoint set that entry's enabled:true to UNHIDE its left-sidebar link, then redeploy the SPA (static re-upload, no build). The shell deploys with all tabs hidden and reveals each one as its agent is wired.")
    if ($mcpEnabled -and (@($mcpAttach | Where-Object { $_ -eq 'ACA-OBO' -or $_ -eq 'FH-OBO' -or $_ -eq 'FD-OBO' }).Count -gt 0)) {
        $nextCommands.Add("# UI + custom MCP (MANDATORY, not optional - every OBO agent must integrate its MCP tools immediately): fill plan.customMcp.audiences with the ext_${mcpName}Anon/Auth BYO app ids right after registration so config.js gets customScopes (ACA/FH-OBO) / customInputs (FD-OBO) automatically; otherwise attach first (add-mcp-servers) then RE-RUN this scaffolder to read them from each agent's ToolingManifest.json. Redeploy the SPA after. then, EACH USER MUST create a SEPARATE one-time Power Platform connection for BOTH ext_${mcpName}Anon (NoAuth) AND ext_${mcpName}Auth (EntraOAuth = OAuth sign-in) at https://make.powerapps.com/connectionsMcp - creating only the anon one is NOT enough (if server_time works but the authenticated whoami comes back from the anon server, the auth connection is missing; the auth server exposes only initialize_server until then). The agent MUST proactively tell the user to create BOTH as themselves, then retry (OBO reuses both across ACA/FH/FD). deploy the SPA with StaticSitesClient.exe directly from the repo root (the 'npx @azure/static-web-apps-cli deploy' wrapper exits 1): & <hash>\StaticSitesClient.exe upload --app <ui-folder> --apiToken <tok> --skipAppBuild true (see docs/setup-web-ui.md).")
    }
}
