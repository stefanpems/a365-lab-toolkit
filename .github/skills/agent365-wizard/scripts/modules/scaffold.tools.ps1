# Unified MCP tool attachment (Work IQ / catalog / custom). For each ACA-*/FH-* agent, attach the
# selected registered MCP servers via the documented flow:
#   a365 develop add-mcp-servers <uniqueName...>   (writes ToolingManifest.json; scope/audience from the catalog)
#   a365 setup permissions mcp --agent-name <name> (Global Admin grants the OAuth2 grants to the blueprint)
# The samples ship ToolingManifest.json with mcp_MailTools; if the plan's tools omit it, remove it.
# Reuse the Work IQ MCP token lessons (references/workiq-mcp-integration.md) for any non-Mail Work IQ tool.
# Reads $plan / $OutRoot / $nextCommands / $attachByAgent from the router scope.

function Invoke-ScaffoldToolAttachment {
    foreach ($a in $plan.agents) {
        if ($a.type -like 'FD-*') { continue }  # FD prompt agents wire tools in agent_config.py, not via add-mcp-servers
        $tools = @($a.tools)
        $extras = @($tools | Where-Object { $_ -and $_ -ne 'mcp_MailTools' })
        if ($attachByAgent.ContainsKey($a.name)) { $extras += @($attachByAgent[$a.name] | Where-Object { $extras -notcontains $_ }) }
        $agentDir = Join-Path $OutRoot $a.name
        if ($extras.Count -gt 0) {
            $note = if ($a.type -like 'FH-*') { '   # FH sample code currently wires only Mail — a non-Mail Work IQ tool also needs the code generalization in references/workiq-mcp-integration.md' } else { '   # ACA turn path is manifest-driven — Work IQ token/refresh lessons already apply generically' }
            $nextCommands.Add("cd `"$agentDir`"; a365 develop add-mcp-servers $($extras -join ' '); a365 setup permissions mcp --agent-name `"$($a.name)`"$note")
        }
        # Mail is shipped in the sample manifest; drop it if the plan explicitly excludes it.
        if (($tools.Count -gt 0) -and ($tools -notcontains 'mcp_MailTools')) {
            $nextCommands.Add("cd `"$agentDir`"; a365 develop remove-mcp-servers mcp_MailTools; a365 setup permissions mcp --agent-name `"$($a.name)`"   # Mail deselected for this agent")
        }
    }
}
