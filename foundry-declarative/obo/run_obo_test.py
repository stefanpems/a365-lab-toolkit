"""End-to-end OBO test: acquire a delegated Mail token, then invoke the declarative agent.

Runs in one process so you complete the sign-in (device code) only once. The acquired
delegated Mail token (audience Agent 365 Tools, scope McpServers.Mail.All) is passed to the
agent as the `mail_token` structured input, which fills the Mail MCP Authorization header —
so any mail the agent sends goes from YOUR mailbox (OBO).

Usage:
  python run_obo_test.py --message "Send a short test email to <you@tenant> with subject 'FD OBO test'."
"""

from __future__ import annotations

import argparse
import sys

from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

import agent_config as cfg
from get_mail_token import acquire


def main() -> None:
    parser = argparse.ArgumentParser(description="OBO end-to-end test for the declarative agent.")
    parser.add_argument("--message", required=True, help="User message to send to the agent.")
    args = parser.parse_args()

    print("Acquiring a delegated Mail token (complete the sign-in shown below)...", file=sys.stderr)
    token = acquire()
    print("Mail token acquired. Invoking the agent...", file=sys.stderr)

    project = AIProjectClient(endpoint=cfg.PROJECT_ENDPOINT, credential=DefaultAzureCredential())
    openai = project.get_openai_client()

    response = openai.responses.create(
        input=args.message,
        extra_body={
            "agent_reference": {"name": cfg.AGENT_NAME, "type": "agent_reference"},
            "structured_inputs": {"mail_token": f"Bearer {token}"},
        },
    )
    print("=== AGENT RESPONSE ===")
    print(response.output_text)


if __name__ == "__main__":
    main()
