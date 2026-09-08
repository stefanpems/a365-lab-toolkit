# Per-agent MCP tool integration, emitted GROUPED WITH THE AGENT (called from the agents loop right
# after the agent's setup/deploy command) so each agent is integrated immediately as it is created.
#
# Work IQ MAIL is handled up-front by Set-ToolingManifest (scaffold.aca/fh.ps1): the manifest is made
# authoritative = the plan's tools BEFORE `a365 setup all`, so permissions follow the manifest exactly
# (no Mail permission on an agent that didn't select Mail). This module therefore covers only:
#   - non-Mail Work IQ servers (future — today only mcp_MailTools is wizard-selectable): add to the
#     manifest + grant via `a365 develop add-mcp-servers` + `a365 setup permissions mcp`.
#   - custom BYO ext_ servers (OBO only), accumulated by the custom-MCP module into $attachByAgent,
#     honoring customMcp.integrationMode:
#       * approve-first        -> the servers were approved BEFORE the agents: attach immediately.
#       * attach-when-approved -> attach only once approved; otherwise do it manually later.
# Reads $plan / $nextCommands / $attachByAgent from the router scope.

function Add-AgentCustomAttach {
    param($a, $dst)
    if ($a.type -like 'FD-*') { return }  # FD wires tools in agent_config.py / CUSTOM_MCP_SERVERS_JSON (scaffold.fd.ps1)

    $tools = @($a.tools)
    # Non-Mail Work IQ tools (Mail is already authoritative in the manifest). Only Mail is selectable
    # today, so this is normally empty — kept so enabling another Work IQ tool later "just works".
    $wiqExtras = @($tools | Where-Object { $_ -like 'mcp_*' -and $_ -ne 'mcp_MailTools' })
    # Custom BYO ext_ servers to attach to THIS agent (OBO only), from the custom-MCP module.
    $customExtras = @()
    if ($attachByAgent.ContainsKey($a.name)) { $customExtras = @($attachByAgent[$a.name]) }
    if ($wiqExtras.Count -eq 0 -and $customExtras.Count -eq 0) { return }

    $redeploy = if ($a.type -like 'FH-*') { 'azd deploy' } else { 'rebuild the image (az acr build) + az containerapp update, or run the agent''s deploy-aca*.ps1' }

    if ($wiqExtras.Count -gt 0) {
        $note = if ($a.type -like 'FH-*') { '   # FH-OBO is manifest-driven for ext_ custom MCP; a non-Mail Work IQ tool may still need the code generalization in references/workiq-mcp-integration.md' } else { '   # ACA turn path is manifest-driven — Work IQ token/refresh lessons apply generically (references/workiq-mcp-integration.md)' }
        $nextCommands.Add("cd `"$dst`"; a365 develop add-mcp-servers $($wiqExtras -join ' '); a365 setup permissions mcp --agent-name `"$($a.name)`"$note")
        $nextCommands.Add("#   ^ then REDEPLOY $($a.name) so the runtime loads the new ToolingManifest.json (it is baked into the image at build time; a revision restart alone keeps the old manifest): $redeploy")
    }

    if ($customExtras.Count -gt 0) {
        $mode = if ($plan.customMcp.integrationMode) { $plan.customMcp.integrationMode } else { 'attach-when-approved' }
        $extJoin = ($customExtras -join ' ')
        if ($mode -eq 'approve-first') {
            # Custom MCP approved BEFORE the agents (see the MCP section) -> integrate this agent now.
            $nextCommands.Add("cd `"$dst`"; a365 develop add-mcp-servers $extJoin; a365 setup permissions mcp --agent-name `"$($a.name)`"   # custom MCP already approved -> integrate $($a.name) immediately (grants the ext_ servers' Tools.ListInvoke.All + McpServersMetadata.Read.All to the blueprint)")
        } else {
            # Agents started without waiting for approval -> attach once the servers are approved.
            $nextCommands.Add("# ONLY AFTER the ext_ servers are ADMIN-APPROVED (M365 admin center > Agents > Tools > Requests): cd `"$dst`"; a365 develop add-mcp-servers $extJoin; a365 setup permissions mcp --agent-name `"$($a.name)`"   # if they are not approved yet when $($a.name) deploys, run this manually later to integrate the custom MCP")
        }
        $nextCommands.Add("#   ^ 'setup permissions mcp' opens a BROWSER for admin consent: grant ALL 3 additional admin consents; IGNORE the final 'Try that again using a different browser / We couldn't connect to that service...' page — consent still succeeds and the CLI detects it (waits up to 180s). Watch for a BLOCKED POPUP (the approval silently stalls if the popup is blocked).")
        $nextCommands.Add("#   ^ then REDEPLOY $($a.name) so the runtime loads the new ToolingManifest.json (baked into the image at build time; a revision restart keeps the old manifest): $redeploy")
    }
}

