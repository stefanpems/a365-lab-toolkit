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
import os

from agent_framework_foundry_hosting import ResponsesHostServer
from dotenv import load_dotenv

from foundry_agent import build_agent

load_dotenv()
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("s2s-foundry-agent")

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

if __name__ == "__main__":
    server = ResponsesHostServer(build_agent())
    server.run()
