# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

"""
Foundry Hosted Agent entrypoint (OBO variant) — Invocations protocol.

The Invocations protocol is used (instead of Responses) because OBO requires
per-request access to the caller's delegated token, which the custom invoke
handler can read from the request. See:
https://learn.microsoft.com/agent-framework/hosting/foundry-hosted-agent

Local run:  python main.py   ->   listens on http://localhost:8088/invocations
"""

import logging

from azure.ai.agentserver.invocations import InvocationAgentServerHost
from dotenv import load_dotenv
from starlette.requests import Request
from starlette.responses import JSONResponse, Response

from foundry_agent import MAIL_MCP_RESOURCE, run_obo_turn

load_dotenv()
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("obo-foundry-agent")

app = InvocationAgentServerHost()


@app.invoke_handler
async def handle_invoke(request: Request):
    """Handle one OBO turn.

    The invocation supplies the user's delegated MCP token(s) and the user text
    (`message` or `input`). Tokens can be provided as:
      1. `tokens`: a JSON object mapping each MCP resource AUDIENCE to a delegated user
         token (preferred when custom ext_* servers are attached — each server has its
         own audience in ToolingManifest.json), or
      2. `mail_token`: a single delegated Agent 365 Tools token (Mail only, back-compat), or
      3. the `Authorization: Bearer <token>` header (treated as the Mail-audience token).
    """
    try:
        data = await request.json()
    except Exception:
        return Response("Invalid JSON body", status_code=400)

    user_message = data.get("message") or data.get("input")
    if not user_message:
        return Response("Missing 'message' in request body", status_code=400)

    # Preferred: an audience->token map covering Mail and any attached custom servers.
    tokens = data.get("tokens") if isinstance(data.get("tokens"), dict) else {}
    tokens = {k: v for k, v in tokens.items() if v}

    # Back-compat: a single Mail token in the body or the Authorization header.
    mail_token = data.get("mail_token")
    if not mail_token:
        authz = request.headers.get("Authorization", "")
        if authz.lower().startswith("bearer "):
            mail_token = authz[7:].strip()
    if mail_token:
        tokens.setdefault(MAIL_MCP_RESOURCE, mail_token)

    if not tokens:
        return Response(
            "Missing user token: provide 'tokens' (audience->delegated token map) or "
            "'mail_token' (delegated Agent 365 Tools token) in the body, or an "
            "Authorization bearer header.",
            status_code=401,
        )

    try:
        reply = await run_obo_turn(user_message, tokens)
        return JSONResponse({"response": reply})
    except Exception as e:  # noqa: BLE001 - surface a clean error to the caller
        logger.error("OBO turn failed: %s", e)
        return JSONResponse({"error": str(e)}, status_code=500)



if __name__ == "__main__":
    app.run()
