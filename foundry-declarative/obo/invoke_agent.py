"""Invoke the OBO Foundry declarative agent via the Responses API — no manual steps.

Usage:
  # Liveness / Q&A (no mail token needed):
  python invoke_agent.py --message "Hello, who are you?"

  # OBO mail action (supply a delegated Mail token; get one with get_mail_token.py):
  python invoke_agent.py --message "Send a test email to me@contoso.com saying hi" --mail-token "<jwt>"
  #  ...or set the MAIL_TOKEN env var instead of --mail-token.

Authentication to the Foundry gateway uses DefaultAzureCredential (your `az login`); you must
have RBAC on the Foundry account (e.g. Cognitive Services User) to invoke.
"""

from __future__ import annotations

import argparse
import os

from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

import agent_config as cfg


def main() -> None:
    parser = argparse.ArgumentParser(description="Invoke the OBO declarative agent.")
    parser.add_argument("--message", required=True, help="User message to send.")
    parser.add_argument(
        "--mail-token",
        default=os.environ.get("MAIL_TOKEN"),
        help="Delegated Mail token (raw JWT or 'Bearer <jwt>'). Optional for Q&A.",
    )
    args = parser.parse_args()

    project = AIProjectClient(endpoint=cfg.PROJECT_ENDPOINT, credential=DefaultAzureCredential())
    openai = project.get_openai_client()

    extra_body: dict = {"agent_reference": {"name": cfg.AGENT_NAME, "type": "agent_reference"}}
    if args.mail_token:
        token = args.mail_token.strip()
        if not token.lower().startswith("bearer "):
            token = f"Bearer {token}"
        extra_body["structured_inputs"] = {"mail_token": token}

    response = openai.responses.create(input=args.message, extra_body=extra_body)
    print(response.output_text)


if __name__ == "__main__":
    main()
