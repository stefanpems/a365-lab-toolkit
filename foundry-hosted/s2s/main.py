# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

"""
Foundry Hosted Agent entrypoint (S2S variant) — Responses protocol.

The Responses protocol is the recommended default: it exposes an OpenAI-compatible
/responses endpoint and the platform manages conversation history, streaming and
session lifecycle. The agent acts with its own identity, so no per-user token is
needed. See:
https://learn.microsoft.com/agent-framework/hosting/foundry-hosted-agent

Local run:  python main.py   ->   listens on http://localhost:8088/responses
"""

import logging

from agent_framework_foundry_hosting import ResponsesHostServer
from dotenv import load_dotenv

from foundry_agent import build_agent

load_dotenv()
logging.basicConfig(level=logging.INFO)

if __name__ == "__main__":
    server = ResponsesHostServer(build_agent())
    server.run()
