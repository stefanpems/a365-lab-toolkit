"""Deploy (create/update) the DW Foundry *declarative* (prompt) agent version.

This only creates the prompt-agent version (model + instructions). Publishing it as an
autopilot to Microsoft Agent 365 / Teams is a separate step — run publish_autopilot.py after.
"""

from __future__ import annotations

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition
from azure.identity import DefaultAzureCredential

import agent_config as cfg


def main() -> None:
    project = AIProjectClient(endpoint=cfg.PROJECT_ENDPOINT, credential=DefaultAzureCredential())
    definition = PromptAgentDefinition(model=cfg.MODEL, instructions=cfg.AGENT_PROMPT)
    agent = project.agents.create_version(agent_name=cfg.AGENT_NAME, definition=definition)
    print(f"Deployed prompt agent: name={agent.name} version={agent.version}")
    print(f"Project: {cfg.PROJECT_ENDPOINT}")
    print(f"Model:   {cfg.MODEL}")
    print("Next: run publish_autopilot.py to publish it as an Agent 365 autopilot in Teams.")


if __name__ == "__main__":
    main()
