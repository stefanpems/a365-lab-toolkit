---
name: "Agent 365 — Foundry prompt agents"
description: "Provision, scaffold, deploy and verify the Foundry Declarative (prompt) sample agents: FD-OBO (on-behalf-of, Mail MCP via per-request token) and FD-S2S (own identity, conversational). USE WHEN the user wants to create/deploy a Foundry declarative/prompt agent, wire its project endpoint, or expose it in the SPA. Trigger phrases: 'Foundry declarative', 'prompt agent', 'FD agent', 'FD-OBO/S2S', 'declarative agent', 'Responses API agent'. Sub-skill of the Lab Builder."
---

# Agent 365 — Foundry prompt agents (FD-OBO / FD-S2S)

Thin orchestration for the Foundry Declarative / prompt family. **Canonical setup detail is in the
per-variant guides — do not duplicate or renumber them:**
[setup-MAF-FD-OBO.md](../../../docs/setup-MAF-FD-OBO.md),
[setup-MAF-FD-S2S.md](../../../docs/setup-MAF-FD-S2S.md).

## What it owns
- FD family scaffolding (module [scaffold.fd.ps1](../agent365-wizard/scripts/modules/scaffold.fd.ps1)):
  fill `.env` with the **project** endpoint (`…/api/projects/<project>`, derived read-only when only the
  account endpoint is known), the model, the agent name, and (FD-OBO) the tenant/client app id; emit the
  RBAC grant + `python deploy_agent.py` next-command.

## Flow
1. Scaffold via the router: [scaffold-from-plan.ps1](../agent365-wizard/scripts/scaffold-from-plan.ps1).
2. Grant **Cognitive Services User** on the reused Foundry account, then `python deploy_agent.py`.
3. Expose in the SPA via a `foundry-prompt` tab (see [setup-web-ui.md](../../../docs/setup-web-ui.md)).

## Platform limitation (do not attempt)
- **FD-DW is not available.** A Foundry prompt agent **cannot** be published as an Agent 365 autopilot
  Digital Worker — a hired instance is permanently silent in Teams by design. Only Foundry **hosted**
  agents can be autopilot blueprints ([Supported agent types](https://learn.microsoft.com/azure/foundry/agents/concepts/agent-365-integration#supported-agent-types)).
  For a Teams Digital Worker use the FH family (FH-DW).

## Tools
FD prompt agents attach tools via `agent_config.py` (M365 app-manifest connectors), **not** via
`add-mcp-servers` / `ToolingManifest.json`. For a custom BYO MCP server, **FD-OBO** declares each server
in `deploy_agent.py` from `CUSTOM_MCP_SERVERS_JSON` (the SPA passes the per-server token as a structured
input). **FD-S2S** ships with no tools and can't use custom MCP (own identity can't own the Power
Platform connection). The Mail token lessons are in
[workiq-mcp-integration.md](../agent365-wizard/references/workiq-mcp-integration.md).
