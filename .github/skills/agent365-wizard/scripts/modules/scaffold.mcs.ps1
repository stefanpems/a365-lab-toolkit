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
    #    pac if missing; the target-tenant sign-in is interactive (browser).
    $nextCommands.Add("pwsh -File `"$csScripts\New-McsAgent.ps1`" -Harness $($a.type) -DisplayName `"$($a.name)`" -Tenant `"$tenant`" -EnvironmentId `"$envId`" -InstallPac$pubFlag   # transform base zip + pac solution import --publish-changes (browser sign-in to the target tenant)")

    # 3) Optional MCP tool integration via the A365 tool gateway (Entra client app + guided Copilot Studio step).
    if ($mcp) {
        $toolArgs = ($mcp | ForEach-Object { switch ($_) { 'mail' { 'Mail' } 'anon' { 'Anon' } 'auth' { 'Auth' } } }) -join ' '
        $prefixArg = if (($mcp -contains 'anon') -or ($mcp -contains 'auth')) { " -McpPrefix `"$McpBaseName`"" } else { '' }
        $nextCommands.Add("pwsh -File `"$csScripts\New-McsMcpClientApp.ps1`" -Tools $toolArgs -Tenant `"$tenant`"$prefixArg   # creates the Entra client app + ATG scope + admin consent; prints OAuth values for the Copilot Studio MCP wizard (az must be logged into the target tenant)")
        $nextCommands.Add("#   ^ then in Copilot Studio: agent '$($a.name)' -> Tools -> Add a tool -> Model Context Protocol -> OAuth 2.0 Manual, using the printed values (Mail is tested; Anon/Auth are experimental — see agent365-copilot-studio/references/mcp-integration-feasibility.md).")
    }

    # 4) Guided org-wide publication (maker-portal action; import already ran Publish All Customizations).
    if ($a.publish) {
        $nextCommands.Add("#   ^ publish '$($a.name)': Copilot Studio -> agent -> (reconfigure user auth if prompted) -> Publish -> Channels -> Teams and Microsoft 365 Copilot -> Availability options -> 'Show to everyone in my org'.")
    }

    # 5) App Insights observability gate (optional). MCS connects App Insights PER-AGENT in Copilot Studio
    #    (Settings > Advanced > Application Insights) -- NOT via an Azure env var / Foundry-project connection
    #    like ACA/FH. The resource lives in the AZURE tenant; the agent in the Copilot Studio TARGET tenant
    #    (cross-tenant is fine: the connection string is just an instrumentation key + ingestion endpoint).
    $aiTarget = Resolve-AppInsightsTarget $plan
    if ($aiTarget.mode -ne 'none') {
        # Ensure the create-shared resource is created even in an MCS-ONLY lab (no ACA/FH agent runs the
        # create command). Get-AppInsightsCreateCommand is run-once guarded, so a mixed lab emits it just once.
        foreach ($c in (Get-AppInsightsCreateCommand $plan)) { $nextCommands.Add($c) }
        $connCmd = "az monitor app-insights component show --app $($aiTarget.name) -g $($aiTarget.resourceGroup) --query connectionString -o tsv"
        $nextCommands.Add("# APP INSIGHTS (MCS MANUAL GATE for '$($a.name)', do ONCE per agent): 1) in the AZURE tenant get the connection string -> $connCmd  2) in Copilot Studio (https://copilotstudio.microsoft.com, target tenant $tenant) open agent '$($a.name)' -> Settings -> Advanced -> Application Insights, paste the Connection string, optionally enable 'Enable logging' / 'Log conversation details', Save. This per-agent portal step is how an MCS agent gets telemetry (there is NO Azure env var / project connection for MCS). Documented for the standard harness (MCS-OH); MCS-NH (new GitHub Copilot harness) is experimental. The resource '$($aiTarget.name)' can be the SAME lab App Insights used by ACA/FH.")
    }
}
