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
import os

from azure.ai.agentserver.invocations import InvocationAgentServerHost
from dotenv import load_dotenv
from starlette.requests import Request
from starlette.responses import JSONResponse, Response

from foundry_agent import MAIL_MCP_RESOURCE, run_obo_turn

load_dotenv()
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("obo-foundry-agent")

# Agent365Observability resource (appId); app-only .default scope for the exporter token.
_OBSERVABILITY_SCOPE = "9b975845-388f-4429-889e-eab1ef63949c/.default"
_obs_credential = None


def _resolve_observability_token(agent_id: str, tenant_id: str) -> str:
    """Best-effort app-only token for the A365 observability exporter.

    Uses the container's managed identity (``DefaultAzureCredential``). Returns "" on any
    failure so the exporter degrades to a no-op and never affects an agent turn. Requires
    the ``Agent365.Observability.OtelWrite`` application role on the agent identity SP.
    """
    global _obs_credential
    try:
        from azure.identity import DefaultAzureCredential

        if _obs_credential is None:
            _obs_credential = DefaultAzureCredential()
        return _obs_credential.get_token(_OBSERVABILITY_SCOPE).token
    except Exception as ex:  # noqa: BLE001 - telemetry must never break the agent
        logger.warning("Observability token acquisition failed: %s", ex)
        return ""


def _init_observability() -> None:
    """Initialize OpenTelemetry (Application Insights + A365 exporter).

    Fully guarded: any failure here must never affect an agent turn. Azure Monitor export
    runs when Foundry injects ``APPLICATIONINSIGHTS_CONNECTION_STRING``; the A365
    observability exporter uses an app-only managed-identity token (see
    :func:`_resolve_observability_token`).
    """
    conn = os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING") or os.getenv(
        "ApplicationInsights__ConnectionString"
    )
    if conn:
        try:
            from azure.monitor.opentelemetry import configure_azure_monitor

            configure_azure_monitor(connection_string=conn)
            logger.info("Application Insights configured for OTEL export.")
        except Exception as ex:  # noqa: BLE001 - telemetry must never break the agent
            logger.warning("Failed to configure Application Insights: %s", ex)
    try:
        from microsoft.opentelemetry import use_microsoft_opentelemetry

        use_microsoft_opentelemetry(
            enable_a365=True,
            enable_azure_monitor=False,
            a365_enable_observability_exporter=True,
            a365_token_resolver=_resolve_observability_token,
        )
    except Exception as ex:  # noqa: BLE001 - telemetry must never break the agent
        logger.warning("Microsoft OpenTelemetry distro not initialized: %s", ex)


_init_observability()

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
