"""Deploy (create/update) the S2S Foundry *declarative* (prompt) agent — no manual portal steps.

Creates a new immutable agent **version** in the Foundry project with:
  * model        = FOUNDRY_MODEL_NAME (default gpt-4.1)
  * instructions = AGENT_PROMPT
  * tools        = only the web-access 'fetch_url' MCP tool (when WEB_FETCH_MCP_URL is set);
                   no Mail / user-data tools — acts with its own identity.

Auth to create the version uses DefaultAzureCredential (your `az login`). You need a role on
the Foundry project that allows agent authoring (e.g. Azure AI User / Cognitive Services User).
"""

from __future__ import annotations

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import MCPTool, PromptAgentDefinition
from azure.identity import DefaultAzureCredential

import agent_config as cfg


def main() -> None:
    project = AIProjectClient(endpoint=cfg.PROJECT_ENDPOINT, credential=DefaultAzureCredential())

    tools = []
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
        tools=tools or None,
    )

    agent = project.agents.create_version(agent_name=cfg.AGENT_NAME, definition=definition)
    print(f"Deployed prompt agent: name={agent.name} version={agent.version}")
    print(f"Project: {cfg.PROJECT_ENDPOINT}")
    print(f"Model:   {cfg.MODEL}")


if __name__ == "__main__":
    main()
