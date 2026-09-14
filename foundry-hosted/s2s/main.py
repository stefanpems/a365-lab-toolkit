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


def _init_observability() -> None:
    """Initialize OpenTelemetry (span enrichment + Application Insights only).

    Fully guarded: any failure here must never affect an agent turn. The A365
    observability *exporter* is intentionally left OFF (no OtelWrite role dependency);
    only span enrichment (``enable_a365``) and Azure Monitor export (when Foundry
    injects ``APPLICATIONINSIGHTS_CONNECTION_STRING``) are enabled.
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

        use_microsoft_opentelemetry(enable_a365=True, enable_azure_monitor=False)
    except Exception as ex:  # noqa: BLE001 - telemetry must never break the agent
        logger.warning("Microsoft OpenTelemetry distro not initialized: %s", ex)


_init_observability()

if __name__ == "__main__":
    server = ResponsesHostServer(build_agent())
    server.run()
