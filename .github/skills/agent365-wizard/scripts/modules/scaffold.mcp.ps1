# Optional sample custom MCP (custom-mcp/): copy the sample to the per-run folder <prefix>-mcp,
# rewrite the deploy-mcp.ps1 constants, fill the register-*.json from the templates,
# and emit deploy/register next-commands. Accumulates ext_ servers into $attachByAgent for the
# per-agent attach (Add-AgentCustomAttach). Reads $plan / $repoRoot / $RunRoot / $McpBaseName /
# $nextCommands / $attachByAgent from the router scope.

function Invoke-ScaffoldCustomMcp {
    # The custom MCP name is NOT asked: it derives from the solution prefix (the same unique key as the
    # web UI), so ext_<Name>Anon/Auth and the <name>-mcp-* Azure resources are unique per run without a
    # separate question. $McpBaseName = slugified prefix (set by the router).
    $name      = $McpBaseName
    $mcpSlug   = $McpBaseName
    $mcpFolderName = "$($plan.solution.prefix)-mcp"
    $mcpSrc = Join-Path $repoRoot 'custom-mcp'
    $mcpDst = Join-Path $RunRoot $mcpFolderName
    if (Test-Path -LiteralPath $mcpDst) { Remove-Item -LiteralPath $mcpDst -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $mcpDst | Out-Null
    $null = robocopy $mcpSrc $mcpDst /E /XD '.venv' '__pycache__' /XF '*.pyc' '.env' /NFL /NDL /NJH /NJS /NP /NC /NS

    $publisher = if ($plan.customMcp.publisher) { $plan.customMcp.publisher } else { 'Contoso' }
    $mcpRegion = if ($plan.customMcp.region) { $plan.customMcp.region } else { $plan.solution.region }
    $mcpRg     = if ($plan.customMcp.resourceGroup) { $plan.customMcp.resourceGroup } else { "$mcpSlug-mcp-rg" }
    $mcpAppAnon = "$mcpSlug-mcp-anon-ca"
    $mcpAppAuth = "$mcpSlug-mcp-auth-ca"
    $mcpEnv     = "$mcpSlug-mcp-cae"
    $servers    = @($plan.customMcp.servers); if (-not $servers) { $servers = @('anon', 'auth') }
    $serversLit = '@(' + (($servers | ForEach-Object { "'$_'" }) -join ', ') + ')'

    # Rewrite the hardcoded constants in deploy-mcp.ps1.
    $depPath = Join-Path $mcpDst 'deploy-mcp.ps1'
    if (Test-Path -LiteralPath $depPath) {
        $txt = Get-Content -LiteralPath $depPath -Raw
        $txt = [regex]::Replace($txt, '(\$RG\s*=\s*)"[^"]*"',        "`$1`"$mcpRg`"")
        $txt = [regex]::Replace($txt, '(\$APP_ANON\s*=\s*)"[^"]*"',  "`$1`"$mcpAppAnon`"")
        $txt = [regex]::Replace($txt, '(\$APP_AUTH\s*=\s*)"[^"]*"',  "`$1`"$mcpAppAuth`"")
        $txt = [regex]::Replace($txt, '(\$ENVNAME\s*=\s*)"[^"]*"', "`$1`"$mcpEnv`"")
        $txt = [regex]::Replace($txt, '(\$LOC\s*=\s*)"[^"]*"',     "`$1`"$mcpRegion`"")
        $txt = [regex]::Replace($txt, '(\$IMAGE\s*=\s*)"[^"]*"',   "`$1`"$mcpSlug-mcp:1.0.0`"")
        $txt = [regex]::Replace($txt, '(\$SERVERS\s*=\s*)@\([^)]*\)', "`$1$serversLit")
        Set-Content -LiteralPath $depPath -Value $txt
    }

    # Fill the registration JSON files from the templates (the FQDN is filled after the container deploys).
    foreach ($srv in $servers) {
        $tmpl = Join-Path $mcpDst "register-$srv.template.json"
        if (-not (Test-Path -LiteralPath $tmpl)) { continue }
        $j = (Get-Content -LiteralPath $tmpl -Raw).Replace('<NAME>', $name).Replace('<PUBLISHER>', $publisher)
        Set-Content -LiteralPath (Join-Path $mcpDst "register-$srv.json") -Value $j
    }
    Write-Host "  scaffolded custom MCP -> generated\$mcpFolderName (servers: $($servers -join ', '))" -ForegroundColor Cyan

    # Next-commands: deploy -> register (after admin approval) -> attach per agent.
    $graphArgs = if ($plan.customMcp.propagateToGraph) { " -AuthClientId <AUTH_APP_ID> -AuthTenantId $($plan.solution.tenantId)" } else { '' }
    $nextCommands.Add("cd `"$mcpDst`"; .\deploy-mcp.ps1 -Subscription $($plan.solution.subscriptionId)$graphArgs   # deploys one container per server (single replica) and prints each server's /mcp FQDN")
    $nextCommands.Add("# If a registration fails partway (HTTP 400 on the proxy connector, or leftover proxy apps/connectors), run before retrying: cd `"$mcpDst`"; .\cleanup-registration.ps1 -Name $name -Subscription $($plan.solution.subscriptionId) -TenantId $($plan.solution.tenantId)")
    foreach ($srv in $servers) {
        if ($srv -eq 'anon') {
            $nextCommands.Add("cd `"$mcpDst`"; # edit register-anon.json: replace <MCP_ANON_FQDN> with the deployed anon FQDN, then: a365 develop-mcp register-external-mcp-server -f .\register-anon.json --dry-run; a365 develop-mcp register-external-mcp-server -f .\register-anon.json   # ANSWER 'y' at the 'Proceed with registration? (y/N)' prompt. Do NOT pipe through '| Out-String' - it buffers all output and HIDES the prompt, so the command looks hung for minutes. tenant admin approves 'ext_${name}Anon' (Agents > Requested). If Approve errors on consent, run preempt-proxy-consents.ps1 (below).")
        } else {
            $nextCommands.Add("cd `"$mcpDst`"; # AUTH: (1) create the resource app exposing api://<appId>/access_as_agent (see custom-mcp/README.md), put it in register-auth.json remoteScopes, replace <MCP_AUTH_FQDN> with the deployed auth FQDN. (2) BEFORE registering, verify the auth server already serves the OAuth PRM (Invoke-RestMethod https://<MCP_AUTH_FQDN>/.well-known/oauth-protected-resource must return 200) - deploy-mcp.ps1 enables MCP_OAUTH_CHALLENGE by default so the connector is created EntraOAuth (a NoAuth connector never forwards a bearer token and can't be fixed without re-registering). Then: a365 develop-mcp register-external-mcp-server -f .\register-auth.json --dry-run; a365 develop-mcp register-external-mcp-server -f .\register-auth.json   # ANSWER 'y' at 'Proceed with registration? (y/N)'; do NOT pipe through '| Out-String' (it hides the prompt). tenant admin approves 'ext_${name}Auth'")
        }
    }
    # Pre-empt the admin-center Approve consent: registration creates the backing proxy apps but NOT
    # their service principals or the delegated grants, so Approve fails with "Couldn't complete
    # consent". This emitted helper creates the missing SPs + AllPrincipals grants (idempotent) so the
    # admin Approve succeeds on the first try. Run it AFTER both registrations, BEFORE the admin clicks
    # Approve. It uses a Graph token + Invoke-RestMethod (az rest --body @file mangles the JSON on
    # Windows) and skips existing grants.
    $nextCommands.Add("cd `"$mcpDst`"; .\preempt-proxy-consents.ps1 -Name $name -Subscription $($plan.solution.subscriptionId)   # create the missing proxy SPs + AllPrincipals grants BEFORE the admin Approve (prevents 'Couldn't complete consent')")
    # After approval + attach, EACH USER must create a one-time Power Platform connection per ext_ server.
    # This helper prints the exact make.powerapps.com/connectionsMcp URLs (anon AND auth) so the agent can
    # hand them to the user instead of a vague instruction. The connectors live in a hidden 'Compliant
    # Container' environment that the environment APIs don't list, so pass -EnvironmentId (the
    # environmentName from any ext_ initialize_server URL) if auto-discovery can't find it.
    $nextCommands.Add("cd `"$mcpDst`"; .\print-connection-urls.ps1 -Name $name   # prints the exact make.powerapps.com/connectionsMcp URLs for BOTH ext_${name}Anon and ext_${name}Auth - GIVE BOTH to the user (auth = OAuth sign-in), then present the CONNECTION GATE [Done / I'll do it later] BEFORE any custom-tool test. Resolution order: -EnvironmentId, then a per-tenant cache (%LOCALAPPDATA%\a365-lab\pp-compliant-env.<tenantId>.txt), then a scan EXCLUDING the tenant Default (a Default match is a false positive - shared_ connectors are visible there but the connection must live in the hidden Compliant Container). FIRST time in a fresh tenant: ask an OBO agent 'Give me the Power Platform setup URL for the ext_${name}Anon server', copy environmentName=<id>, run once with -EnvironmentId <id> (it caches per tenant). The connections are per-user -> created ONCE, reused by ACA/FH/FD-OBO; S2S/DW never need them.")
    # Integration mode (asked by the wizard right after the MCP is registered): approve-first (approve
    # the ext_ servers NOW, before the agents, so each OBO agent integrates them immediately as it is
    # created) or attach-when-approved (start the agents now; each OBO agent integrates the custom MCP
    # only if it is already approved by the time it deploys, else attach it manually later).
    $mode = if ($plan.customMcp.integrationMode) { $plan.customMcp.integrationMode } else { 'approve-first' }
    if ($mode -eq 'approve-first') {
        $nextCommands.Add("# INTEGRATION MODE = approve-first: have the tenant admin APPROVE ext_${name}Anon/Auth NOW (M365 admin center > Agents > Tools > Requests), BEFORE creating the agents, so each OBO agent's provisioning below integrates the custom MCP immediately (add-mcp-servers + setup permissions mcp are emitted inline per OBO agent). Watch for a BLOCKED POPUP at Approve.")
    } else {
        $nextCommands.Add("# INTEGRATION MODE = attach-when-approved: you may start creating the agents now and approve ext_${name}Anon/Auth in parallel (M365 admin center > Agents > Tools > Requests). Each OBO agent integrates the custom MCP only if the servers are already approved when it deploys; otherwise run the per-agent add-mcp-servers + setup permissions mcp block (emitted below) manually once approval completes. Watch for a BLOCKED POPUP at Approve.")
    }
    $extList = (@($servers | ForEach-Object { if ($_ -eq 'anon') { "ext_${name}Anon" } else { "ext_${name}Auth" } }))
    foreach ($t in @($plan.customMcp.attachTo)) {
        $ag = $plan.agents | Where-Object { $_.type -eq $t } | Select-Object -First 1
        if (-not $ag) { continue }
        # Accumulate the custom ext_ servers; the unified attach section emits one command per agent.
        if (-not $attachByAgent.ContainsKey($ag.name)) { $attachByAgent[$ag.name] = New-Object System.Collections.Generic.List[string] }
        $extList | ForEach-Object { if ($attachByAgent[$ag.name] -notcontains $_) { $attachByAgent[$ag.name].Add($_) } }
    }
    if ($plan.customMcp.propagateToGraph) {
        $nextCommands.Add("# propagate_to_graph: on the ext_${name}Auth app add Microsoft Graph delegated 'User.Read' + admin consent + a client secret, then redeploy deploy-mcp.ps1 with -AuthClientId/-AuthTenantId (secret entered in the terminal). See custom-mcp/README.md.")
    }
}
