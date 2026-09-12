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
        $toolArgs = ($mcp | ForEach-Object { switch ($_) { 'mail' { 'Mail' } 'anon' { 'Anon' } 'auth' { 'Auth' } } }) -join ','
        $prefixArg = if (($mcp -contains 'anon') -or ($mcp -contains 'auth')) { " -McpPrefix `"$McpBaseName`"" } else { '' }
        $nextCommands.Add("pwsh -File `"$csScripts\New-McsMcpClientApp.ps1`" -Tools $toolArgs -Tenant `"$tenant`"$prefixArg   # creates the Entra client app + ATG scope + admin consent; prints OAuth values for the Copilot Studio MCP wizard (az must be logged into the target tenant)")
        $nextCommands.Add("#   ^ then in Copilot Studio: agent '$($a.name)' -> Tools -> Add a tool -> Model Context Protocol -> OAuth 2.0 Manual, using the printed values (Mail is tested; Anon/Auth are experimental — see agent365-copilot-studio/references/mcp-integration-feasibility.md).")
    }

    # 4) Guided org-wide publication (maker-portal action; import already ran Publish All Customizations).
    if ($a.publish) {
        $nextCommands.Add("#   ^ publish '$($a.name)': Copilot Studio -> agent -> (reconfigure user auth if prompted) -> Publish -> Channels -> Teams and Microsoft 365 Copilot -> Availability options -> 'Show to everyone in my org'.")
    }
}
