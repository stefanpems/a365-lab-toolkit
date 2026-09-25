"""Deploy (create/update) the OBO Foundry *declarative* (prompt) agent — no manual portal steps.

Creates a new immutable agent **version** in the Foundry project with:
  * model            = FOUNDRY_MODEL_NAME (default gpt-4.1)
  * instructions     = AGENT_PROMPT
  * one MCP tool     = the Agent 365 Mail MCP, whose Authorization header is a template
                       ``{{mail_token}}`` supplied per request via a structured input.

Auth to create the version uses DefaultAzureCredential (i.e. your `az login`). You need a
role on the Foundry project that allows agent authoring (e.g. Azure AI User / Cognitive
Services User / project manager).

Docs:
  * Create a prompt agent with an MCP tool:
    https://learn.microsoft.com/azure/foundry/agents/how-to/tools/model-context-protocol?pivots=python
  * Structured inputs (per-request template values):
    https://learn.microsoft.com/azure/foundry/agents/how-to/structured-inputs?pivots=python
"""

from __future__ import annotations

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import (
    MCPTool,
    PromptAgentDefinition,
    StructuredInputDefinition,
)
from azure.identity import DefaultAzureCredential

import agent_config as cfg


def main() -> None:
    project = AIProjectClient(endpoint=cfg.PROJECT_ENDPOINT, credential=DefaultAzureCredential())

    # Mail MCP tool. The bearer is NOT baked into the version (it is per-user and short-lived):
    # the Authorization header is a template resolved at runtime from the `mail_token`
    # structured input. `require_approval="never"` lets the agent auto-invoke the tool.
    mail_tool = MCPTool(
        server_label="mcp_MailTools",
        server_url=cfg.MAIL_MCP_URL,
        require_approval="never",
        headers={"Authorization": "{{mail_token}}"},
    )

    tools = [mail_tool]
    structured_inputs = {
        # Optional so the agent can be invoked for pure Q&A without a token; required
        # (in practice) only when the user asks for a mail action. Optional inputs MUST
        # carry a default_value (else the API rejects with "Must be specified for optional
        # inputs"); the empty default yields an empty Authorization header when no token
        # is supplied — harmless because the Mail tool is only called for mail actions.
        "mail_token": StructuredInputDefinition(
            description=(
                "Delegated Microsoft 365 Mail token for the signed-in user, formatted "
                "as 'Bearer <jwt>'. Audience = Agent 365 Tools, scope McpServers.Mail.All."
            ),
            required=False,
            default_value="",
            schema={"type": "string"},
        ),
    }

    # Custom (BYO) MCP servers (cfg.CUSTOM_MCP_SERVERS from CUSTOM_MCP_SERVERS_JSON): one MCPTool
    # per server whose Authorization header is the per-request structured input {{<input>}}, plus
    # a matching StructuredInputDefinition. The SPA sends the same <input> names (config.js
    # obo-fd "customInputs"). All calls go through the Agent 365 gateway, on behalf of the user.
    for s in cfg.CUSTOM_MCP_SERVERS:
        label, url, token_input = s["label"], s["url"], s["input"]
        tools.append(
            MCPTool(
                server_label=label,
                server_url=url,
                require_approval="never",
                headers={"Authorization": "{{" + token_input + "}}"},
            )
        )
        structured_inputs[token_input] = StructuredInputDefinition(
            description=(
                f"Delegated user token (formatted as 'Bearer <jwt>') for the custom MCP server "
                f"'{label}', audience = its BYO resource app, scope Tools.ListInvoke.All."
            ),
            required=False,
            default_value="",
            schema={"type": "string"},
        )

    # Web access: the lab's web-fetch MCP server's 'fetch_url' (anonymous), attached directly (no token).
    if cfg.WEB_FETCH_MCP_URL:
        tools.append(
            MCPTool(
                server_label="web_fetch",
                server_url=cfg.WEB_FETCH_MCP_URL,
                server_description="Checks whether a public web page is reachable (HTTP status) and reads its text.",
                require_approval="never",
                allowed_tools=["fetch_url"],
            )
        )

    definition = PromptAgentDefinition(
        model=cfg.MODEL,
        instructions=cfg.AGENT_PROMPT,
        tools=tools,
        structured_inputs=structured_inputs,
    )

    agent = project.agents.create_version(agent_name=cfg.AGENT_NAME, definition=definition)
    print(f"Deployed prompt agent: name={agent.name} version={agent.version}")
    print(f"Project: {cfg.PROJECT_ENDPOINT}")
    print(f"Model:   {cfg.MODEL}")


if __name__ == "__main__":
    main()
