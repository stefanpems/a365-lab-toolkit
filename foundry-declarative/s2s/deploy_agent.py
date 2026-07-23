"""Deploy (create/update) the S2S Foundry *declarative* (prompt) agent — no manual portal steps.

Creates a new immutable agent **version** in the Foundry project with:
  * model        = FOUNDRY_MODEL_NAME (default gpt-4.1)
  * instructions = AGENT_PROMPT
  * NO tools     — pure conversational, acts with its own identity.

Auth to create the version uses DefaultAzureCredential (your `az login`). You need a role on
the Foundry project that allows agent authoring (e.g. Azure AI User / Cognitive Services User).
"""

from __future__ import annotations

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition
from azure.identity import DefaultAzureCredential

import agent_config as cfg


def main() -> None:
    project = AIProjectClient(endpoint=cfg.PROJECT_ENDPOINT, credential=DefaultAzureCredential())

    definition = PromptAgentDefinition(
        model=cfg.MODEL,
        instructions=cfg.AGENT_PROMPT,
    )

    agent = project.agents.create_version(agent_name=cfg.AGENT_NAME, definition=definition)
    print(f"Deployed prompt agent: name={agent.name} version={agent.version}")
    print(f"Project: {cfg.PROJECT_ENDPOINT}")
    print(f"Model:   {cfg.MODEL}")


if __name__ == "__main__":
    main()
