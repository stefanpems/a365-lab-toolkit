# Foundry Declarative / prompt family (FD-OBO / FD-S2S): fill .env with the PROJECT endpoint
# (deriving it read-only when only the account endpoint is known), the model, and the agent name;
# emit the RBAC grant + python deploy next-command. Reads $plan / $nextCommands from the router scope.

function Invoke-ScaffoldFdAgent {
    param($a, $m, $dst)

    $envPath = Join-Path $dst '.env'
    $ft = Resolve-FoundryTarget $plan $a
    if ($ft.mode -eq 'per-agent') {
        # Legacy: derive the PROJECT endpoint from the agent's own foundryProject (account or project URL).
        $fp = $a.foundryProject
        if ($fp -and $fp -notmatch '/api/projects/') {
            # Prompt-agent SDK needs the PROJECT endpoint (…/api/projects/<project>), not the account endpoint. Derive it (read-only az).
            $acctName = ([uri]$fp).Host.Split('.')[0]
            $proj = az rest --method get --url "https://management.azure.com/subscriptions/$($plan.solution.subscriptionId)/resourceGroups/$($a.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$acctName/projects?api-version=2025-04-01-preview" --query "value[0].name" -o tsv 2>$null
            if ($proj) { if ($proj -like '*/*') { $proj = $proj.Split('/')[-1] }; $fp = "https://$acctName.services.ai.azure.com/api/projects/$proj"; Write-Host "    FD project endpoint derived: $fp" -ForegroundColor DarkGray }
            else { Write-Host "    WARN $($a.name): set FOUNDRY_PROJECT_ENDPOINT manually to https://<acct>.services.ai.azure.com/api/projects/<project>" -ForegroundColor Yellow }
        }
    }
    else {
        # Shared Foundry (solution.foundry): reuse-existing = the known project endpoint; create-shared =
        # a token the agent substitutes with the shared project the first FH agent provisioned.
        $fp = $ft.endpoint
    }
    # The prompt-agent SDK requires the AI-services host, NOT the account's cognitiveservices.azure.com host
    # (the latter returns 404 at deploy). Normalize even when the plan already supplied /api/projects/.
    if ($fp -match 'cognitiveservices\.azure\.com') { $fp = $fp -replace '\.cognitiveservices\.azure\.com', '.services.ai.azure.com' }
    if ($fp) { Set-EnvValue -Path $envPath -Key 'FOUNDRY_PROJECT_ENDPOINT' -Value $fp }
    Set-EnvValue -Path $envPath -Key 'FOUNDRY_MODEL_NAME' -Value $ft.deployment
    Set-EnvValue -Path $envPath -Key 'AGENT_NAME' -Value $a.name
    if ($a.type -eq 'FD-OBO') {
        Set-EnvValue -Path $envPath -Key 'AZURE_TENANT_ID' -Value $plan.solution.tenantId
        Set-EnvValue -Path $envPath -Key 'CLIENT_APP_ID' -Value '<YOUR_AGENT365_CLI_PUBLIC_CLIENT_APP_ID>'
        # Custom (BYO) MCP servers attached to FD-OBO: declared here (label/url/input) so deploy_agent.py
        # builds one MCPTool + StructuredInputDefinition per server (Authorization header = {{<input>}}).
        # The SPA sends the matching tokens as structured_inputs (config.js obo-fd customInputs).
        if ($plan.customMcp -and $plan.customMcp.enabled -and (@($plan.customMcp.attachTo) -contains 'FD-OBO')) {
            $mcpName = $McpBaseName  # derived from the solution prefix (not asked)
            $srvs = @($plan.customMcp.servers); if (-not $srvs) { $srvs = @('anon', 'auth') }
            $parts = @()
            foreach ($srv in $srvs) {
                if ($srv -eq 'anon') { $parts += "{""label"":""ext_${mcpName}Anon"",""url"":""https://agent365.svc.cloud.microsoft/agents/servers/ext_${mcpName}Anon"",""input"":""anon_token""}" }
                elseif ($srv -eq 'auth') { $parts += "{""label"":""ext_${mcpName}Auth"",""url"":""https://agent365.svc.cloud.microsoft/agents/servers/ext_${mcpName}Auth"",""input"":""auth_token""}" }
            }
            if ($parts.Count -gt 0) { Set-EnvValue -Path $envPath -Key 'CUSTOM_MCP_SERVERS_JSON' -Value ('[' + ($parts -join ',') + ']') }
        }
    }
    # FD deploy authors an agent version -> needs Cognitive Services User on the Foundry account.
    if ($ft.mode -eq 'create-shared') {
        # The shared account name is only known after the first FH agent provisions it, and that step
        # already granted the signed-in user Cognitive Services User on it, so no separate grant here.
        # The agent substitutes the shared project endpoint (captured from the provisioning step) into .env.
        $nextCommands.Add("cd `"$dst`"; python -m venv .venv; .\.venv\Scripts\Activate.ps1; pip install -r requirements.txt; python deploy_agent.py   # create-shared: set FOUNDRY_PROJECT_ENDPOINT in .env to the captured shared project first (RBAC already granted by the shared-Foundry provisioner)")
    }
    else {
        $fdGrant = "az role assignment create --assignee-object-id (az ad signed-in-user show --query id -o tsv) --assignee-principal-type User --role `"Cognitive Services User`" --scope (az cognitiveservices account show -n $($ft.account) -g $($ft.resourceGroup) --query id -o tsv)"
        # Extra UI-tester grants (ui.permissions.foundryAccess: CSV of UPNs and/or a group object id).
        $g = if ($ft.account -and $ft.resourceGroup) { Get-FoundryAccessGrants $plan "(az cognitiveservices account show -n $($ft.account) -g $($ft.resourceGroup) --query id -o tsv)" } else { @() }
        $accessStr = if ($g) { ($g -join '; ') + '; ' } else { '' }
        $nextCommands.Add("cd `"$dst`"; $fdGrant; $accessStr" + "python -m venv .venv; .\.venv\Scripts\Activate.ps1; pip install -r requirements.txt; python deploy_agent.py   # RBAC propagates ~2-5min")
    }
    if ($a.type -eq 'FD-OBO' -and $plan.customMcp -and $plan.customMcp.enabled -and (@($plan.customMcp.attachTo) -contains 'FD-OBO')) {
        $nextCommands.Add("#   ^ FD-OBO custom MCP: the ext_ servers must be REGISTERED + admin-approved first (custom-mcp/), then 'python deploy_agent.py' bakes them into the agent version from CUSTOM_MCP_SERVERS_JSON. FD has NO server-side code, so BYO tools surface only when the one-time Power Platform connection already exists (OBO reuses the ACA/FH connection); the prompt asks the model to run 'initialize_server' first if a server still needs it. Re-run the UI scaffolder + redeploy the SPA so config.js obo-fd gets customInputs.")
    }
}
