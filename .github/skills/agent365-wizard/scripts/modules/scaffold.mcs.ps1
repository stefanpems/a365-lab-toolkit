# Microsoft Copilot Studio (MCS) family (MCS-OH / MCS-NH): NO code to scaffold — the agent is built by
# transforming a committed base solution zip (agent365-copilot-studio/assets/base-solutions) and importing
# it with pac. This module emits the next-commands that call the durable MCS scripts (it does NOT
# regenerate any agent code). Reads $plan / $repoRoot / $nextCommands / $McpBaseName from the router scope.

function Invoke-ScaffoldMcsAgent {
    param($a, $m, $dst)

    $harness   = if ($m.harness) { $m.harness } else { ($a.type -replace '^MCS-', '') }   # OH | NH
    $csScripts = Join-Path $repoRoot '.github\skills\agent365-copilot-studio\scripts'
    $cs        = $plan.solution.copilotStudio
    $tenant    = if ($cs) { $cs.targetTenantId } else { $null }
    $envId     = if ($cs) { $cs.targetEnvironmentId } else { $null }
    $pubFlag   = if ($a.publish) { ' -Publish' } else { '' }
    $mcp       = @($a.mcp)

    # A per-agent marker so generated/<prefix>/<agent>/ documents what will be created (parity with other families).
    $readme = @(
        "# $($a.name) ($($a.type))",
        "",
        "Microsoft Copilot Studio agent, $(if ($harness -eq 'NH') { 'GitHub Copilot (new) harness' } else { 'legacy standard harness' }).",
        "Built by importing the base solution '$(if ($harness -eq 'OH') { 'AgentOHSol' } else { 'AgentNHSol' })' (renamed) into the target Copilot Studio environment.",
        "",
        "Target tenant     : $tenant",
        "Target environment: $envId",
        "MCP integration   : $(if ($mcp) { $mcp -join ', ' } else { 'none' })",
        "Publish org-wide  : $([bool]$a.publish)",
        "",
        "See .github/skills/agent365-copilot-studio/SKILL.md for the full flow."
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $dst 'README.md') -Value $readme -Encoding UTF8

    # 1) MCS-NH prerequisite gate (Dataverse + PAYG/Copilot Credits). MCS-OH has no prerequisite.
    if ($harness -eq 'NH') {
        $nextCommands.Add("pwsh -File `"$csScripts\Test-McsPrereqs.ps1`" -Harness MCS-NH -EnvironmentId `"$envId`" -Tenant `"$tenant`"   # NH gate: must be OK (Dataverse + PAYG/Copilot Credits) before import, else EnforcementUsageCredits")
    }

    # 2) Build + import the agent (transform base zip -> pac import --publish-changes). -InstallPac installs
    #    pac if missing; the target-tenant sign-in is interactive (browser). -IsolateSchemaName rewrites the
    #    bot SCHEMA token (default 'new_AgentOH2' / 'cr47b_agentnh2_URxM4c') to one derived from this agent's
    #    unique solution name, so 2+ same-harness MCS agents in ONE environment become DISTINCT bots instead
    #    of colliding on the shared base schema at import (the base token is identical across the base zip).
    #    Pin the SOLUTION unique name to the prefix-derived <prefix>MCS<OH|NH>[<n>] EVEN when the display
    #    name is custom, so the Lab Cleaner's prefix fallback (solutions matching '<prefix>MCS*') still finds
    #    the agent without the archived plan. For DEFAULT names this equals ConvertTo-SolutionUniqueName($a.name)
    #    (byte-identical to before); for CUSTOM names it decouples the visible display name from cleanup discovery.
    $prefixSlug = ($plan.solution.prefix -replace '[^A-Za-z0-9]', '')
    $sameType   = @($plan.agents | Where-Object { $_.type -eq $a.type })
    $ordinal    = ([Array]::IndexOf(@($sameType | ForEach-Object { $_.name }), $a.name)) + 1
    $solUnique  = if ($sameType.Count -gt 1) { "${prefixSlug}MCS${harness}${ordinal}" } else { "${prefixSlug}MCS${harness}" }
    # BROWSER SIGN-IN gate (#2): make it explicit WHY a browser may open and WITH WHICH identity.
    $nextCommands.Add("# BROWSER SIGN-IN (pac) for '$($a.name)': the import below authenticates to the TARGET Copilot Studio tenant ($tenant). A browser window opens ONLY when there is no valid pac profile for that tenant yet (typically just the FIRST MCS agent of the run, or after a profile expires); later imports reuse the profile SILENTLY. When it opens, sign in as an ADMIN of the TARGET Copilot Studio tenant (the Power Platform / Dataverse admin of env '$envId') -- NOT your Azure/corp account if they differ. This is expected, not an error.")
    $nextCommands.Add("pwsh -File `"$csScripts\New-McsAgent.ps1`" -Harness $($a.type) -DisplayName `"$($a.name)`" -SolutionUniqueName `"$solUnique`" -Tenant `"$tenant`" -EnvironmentId `"$envId`" -IsolateSchemaName -InstallPac$pubFlag   # transform base zip (display name '$($a.name)', solution '$solUnique', UNIQUE bot schema) + pac solution import --publish-changes (browser sign-in to the target tenant on first use)")

    # 3) Optional MCP tool integration via the A365 tool gateway (Entra client app + guided Copilot Studio step).
    if ($mcp) {
        # Comma-join (NOT space): a [string[]] param passed via `pwsh -File` only binds the FIRST space-separated
        # token and treats the rest as positional args (Anon -> -AppName, Auth -> -Tenant), silently dropping tools.
        $toolArgs = ($mcp | ForEach-Object { switch ($_) { 'mail' { 'Mail' } 'anon' { 'Anon' } 'auth' { 'Auth' } } }) -join ','
        $prefixArg = if (($mcp -contains 'anon') -or ($mcp -contains 'auth')) { " -McpPrefix `"$McpBaseName`"" } else { '' }
        # A lab-specific -AppName keeps each lab's MCS MCP client app isolated (never clobbers another lab's app or its secret).
        $nextCommands.Add("pwsh -File `"$csScripts\New-McsMcpClientApp.ps1`" -Tools $toolArgs -Tenant `"$tenant`" -AppName `"$($plan.solution.prefix) MCS MCP Client (ATG)`"$prefixArg   # creates the Entra client app + ATG scope + admin consent; prints OAuth values for the Copilot Studio MCP wizard (az must be logged into the target tenant). RUN ONCE per lab (it RESETS the secret each run) - reuse the same client id+secret for every agent's wizard.")
        # MCP tool ADD — explicit, per-harness guidance (#4). Always filter the picker by 'Model Context
        # Protocol' first (so you pick MCP servers, not similarly-named connectors), then search per tool.
        $nextCommands.Add("#   ^ ADD MCP TOOLS to '$($a.name)' in Copilot Studio (Tools -> Add a tool). ALWAYS filter the picker by 'Model Context Protocol' FIRST so you pick MCP SERVERS, NOT connectors with a similar name. Use OAuth 2.0 Manual with the printed client id/secret + scope.")
        if ($mcp -contains 'mail') {
            if ($harness -eq 'OH') {
                $nextCommands.Add("#      - MAIL: search 'Work IQ' and select EXACTLY 'Mail MCP' (this is the OH label). During Add it asks to CREATE A CONNECTION (sign in) -> do it.")
            }
            else {
                $nextCommands.Add("#      - MAIL: search 'Work IQ' and select EXACTLY 'Work IQ' (this is the NH label). During Add it asks to CREATE A CONNECTION (sign in) -> do it.")
            }
        }
        if (($mcp -contains 'anon') -or ($mcp -contains 'auth')) {
            if ($harness -eq 'OH') {
                $nextCommands.Add("#      - CUSTOM ext_ (OH only): search 'ext_' (or paste the full name, e.g. ext_${McpBaseName}Anon / ext_${McpBaseName}Auth) and add each one. During Add it asks to CREATE A CONNECTION; for ext_ servers this prompt MAY REPEAT several times -> create the connection each time it asks.")
                $nextCommands.Add("#      - ACTIVATION for ext_ (OH, do ONCE per server) (#5): the ext_ tools stay INERT until activated. In a FIRST test chat with '$($a.name)', explicitly ask the agent to call the 'initialize_server' tool of the ext_ server (anon or auth); THEN, when that tool asks, RE-CREATE the Power Platform connection it points to. Only AFTER this sequence does the ext_ server return data on later turns.")
            }
            else {
                $nextCommands.Add("#      - CUSTOM ext_ on NH: NOT SUPPORTED TODAY. MCS-NH (GitHub Copilot harness) BLOCKS adding custom ext_ MCP servers from the Agent 365 tool gateway. Skip anon/auth for '$($a.name)' -> only Mail ('Work IQ') works on NH.")
            }
        }
        # Shared-connection note (#4): connections are per-USER, per-connector, per-environment (not per-agent).
        $nextCommands.Add("#      - SHARED CONNECTIONS: the Power Platform connections created here are OWNED BY THE SIGNING-IN USER and scoped to (connector, environment), NOT to the agent. Every agent in THIS lab that uses the same tool as the same user REUSES the same connection, so you create each connection ONCE for the whole lab. This is the normal Power Platform per-user connection-reuse model, NOT a symptom of a problem.")
        $nextCommands.Add("#   ^ see agent365-copilot-studio/references/mcp-integration-feasibility.md (Mail is tested; ext_ Anon likely works after activation, ext_ Auth experimental; NH cannot use ext_).")
    }

    # 4) Guided org-wide publication (maker-portal action; import already ran Publish All Customizations).
    if ($a.publish) {
        $nextCommands.Add("#   ^ publish '$($a.name)': Copilot Studio -> agent -> (reconfigure user auth if prompted) -> Publish -> Channels -> Teams and Microsoft 365 Copilot -> Availability options -> 'Show to everyone in my org'.")
    }

    # 5) Telemetry / observability communication (MCS-specific). MCS agents have TWO independent sinks:
    #    (a) Agent 365 observability is ALREADY ON automatically (no action) -- visible in M365 admin center /
    #        Defender / Purview; needs an E7 or Agent 365 license in the tenant.
    #    (b) Azure Application Insights is OPTIONAL/additional, in two mutually-exclusive scopes:
    #        GLOBAL = environment-level (preview): covers BOTH harnesses (OH+NH), requires a MANAGED ENVIRONMENT,
    #        configured ONCE in PPAC (export package type 'Copilot Studio'); LOCAL = per-agent, MCS-OH ONLY.
    $envLevelDocs = 'https://learn.microsoft.com/microsoft-copilot-studio/advanced-environment-level-agent-telemetry'
    $nextCommands.Add("# TELEMETRY for '$($a.name)' ($($a.type)): Agent 365 observability is ALREADY ACTIVE automatically -- no action needed (view it in M365 admin center / Defender / Purview; requires an E7 or Agent 365 license in the tenant). Application Insights below is OPTIONAL and ADDITIONAL.")
    $nextCommands.Add("#   ^ App Insights -- FIRST EVALUATE: is the target Copilot Studio environment '$envId' a MANAGED ENVIRONMENT, and is ENVIRONMENT-LEVEL (global) App Insights telemetry ALREADY configured for it? If YES -> this agent is ALREADY covered (OH and NH) -- do NOTHING. If NOT, choose ONE option below:")
    if ($harness -eq 'NH') {
        $nextCommands.Add("#     - GLOBAL (env-level; the ONLY App Insights option for MCS-NH): requires a Managed Environment. Configure ONCE in Power Platform admin center -> environment '$envId' -> Export to Application Insights (export package type 'Copilot Studio'). Covers every agent (OH+NH) in the env. Docs: $envLevelDocs")
        $nextCommands.Add("#     - NONE: skip App Insights and keep ONLY the Agent 365 telemetry above. (Per-agent LOCAL telemetry is NOT available for the GitHub Copilot harness / MCS-NH.)")
    }
    else {
        $nextCommands.Add("#     - GLOBAL (env-level, preview): requires a Managed Environment; covers OH+NH at once. Configure ONCE in PPAC -> environment '$envId' -> Export to Application Insights (package type 'Copilot Studio'). Docs: $envLevelDocs")
        $nextCommands.Add("#     - LOCAL (per-agent, MCS-OH only): connect THIS agent to App Insights in Copilot Studio (concrete steps below, if a lab App Insights resource is configured).")
        $nextCommands.Add("#     - NONE: skip App Insights and keep ONLY the Agent 365 telemetry above.")
    }
    # Concrete commands only when a lab App Insights resource exists (create-shared / reuse-existing). The
    # SAME resource serves the LOCAL per-agent connection (OH) and the GLOBAL env-level export target.
    $aiTarget = Resolve-AppInsightsTarget $plan
    if ($aiTarget.mode -ne 'none') {
        # Ensure the create-shared resource is created even in an MCS-ONLY lab (no ACA/FH agent runs the
        # create command). Get-AppInsightsCreateCommand is run-once guarded, so a mixed lab emits it just once.
        foreach ($c in (Get-AppInsightsCreateCommand $plan)) { $nextCommands.Add($c) }
        $connCmd = "az monitor app-insights component show --app $($aiTarget.name) -g $($aiTarget.resourceGroup) --query connectionString -o tsv"
        if ($harness -eq 'OH') {
            $nextCommands.Add("# APP INSIGHTS -- LOCAL (per-agent) for '$($a.name)' [MCS-OH], do ONCE: 1) in the AZURE tenant get the connection string -> $connCmd  2) in Copilot Studio (https://copilotstudio.microsoft.com, target tenant $tenant) open agent '$($a.name)' -> Settings -> Advanced -> Application Insights, paste the Connection string, optionally enable 'Enable logging' / 'Log conversation details', Save. Resource '$($aiTarget.name)' can be the SAME lab App Insights used by ACA/FH and the SAME target for the GLOBAL env-level export.")
        }
        else {
            $nextCommands.Add("# APP INSIGHTS -- for '$($a.name)' [MCS-NH] use the GLOBAL env-level export only; point the PPAC export package at the lab resource. Get its connection string with -> $connCmd  (per-agent LOCAL is NOT available for NH).")
        }
    }
}
