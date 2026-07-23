"""Invoke the S2S Foundry declarative agent via the Responses API — no manual steps.

The agent acts with its OWN identity (no user token). The signed-in user's verified profile
(name) can be passed as context so the agent can personalize the tone, but it never
impersonates the user.

Usage:
  python invoke_agent.py --message "Hello, what can you do?"

Authentication to the Foundry gateway uses DefaultAzureCredential (your `az login`); you must
have RBAC on the Foundry account (e.g. Cognitive Services User) to invoke.
"""

from __future__ import annotations

import argparse

from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

import agent_config as cfg


def main() -> None:
    parser = argparse.ArgumentParser(description="Invoke the S2S declarative agent.")
    parser.add_argument("--message", required=True, help="User message to send.")
    args = parser.parse_args()

    project = AIProjectClient(endpoint=cfg.PROJECT_ENDPOINT, credential=DefaultAzureCredential())
    openai = project.get_openai_client()

    response = openai.responses.create(
        input=args.message,
        extra_body={"agent_reference": {"name": cfg.AGENT_NAME, "type": "agent_reference"}},
    )
    print(response.output_text)


if __name__ == "__main__":
    main()
