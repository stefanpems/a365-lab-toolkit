# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

"""Agent 365 observability for the ACA OBO/S2S samples (SPA /chat and Bot Framework /api/messages).

Why this module exists
----------------------
The Agent 365 exporter only ships gen_ai spans (invoke_agent / chat / execute_tool) that carry BOTH
``microsoft.tenant.id`` and ``gen_ai.agent.id`` (the agent identity appId), and it needs a token that
the observability service accepts for that identity. The SPA ``/chat`` endpoint (web UI, Prompts
Sender) has no Bot Framework TurnContext, so it got neither: every span was dropped ("spans skipped
due to missing tenant or agent ID") and the Microsoft 365 admin center showed 0 users / 0 sessions.

What it does ("Agent 365-enabled using S2S",
https://learn.microsoft.com/microsoft-agent-365/developer/observability-authentication-setup)
1. The blueprint credentials (service connection) + ``fmi_path=<agent identity appId>`` mint an
   agentic application token (aud ``api://AzureAdTokenExchange``).
2. The agent identity presents it as ``client_assertion`` and gets an app-only token for the
   observability resource (``api://9b975845-388f-4429-889e-eab1ef63949c/.default``). The agent
   identity inherits the ``Agent365.Observability.OtelWrite`` app role granted to the blueprint.
3. The exporter posts to the S2S route (``/observabilityService/...``): pass
   ``a365_use_s2s_endpoint=True`` together with :func:`resolve_token`.
4. :func:`turn_baggage` stamps every span of a turn with the identity, the channel, a conversation id
   and the signed-in user (``user.id`` = Entra object id, the admin center's "active user").
5. :func:`bind_agent_identity` aligns Agent Framework's own ``gen_ai.agent.id`` (a random UUID per
   ``Agent`` by default, set AFTER span start so baggage cannot fix it) with the agent identity.

Configuration (environment)
- ``A365_AGENT_ID``    agent identity appId (the "Agent ID" of the agent in the admin center
                        registry, NOT the blueprint id). Without it nothing can be exported.
- ``A365_AGENT_NAME``  name stamped on the spans (default: the Container App name).
- ``CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID|CLIENTSECRET|TENANTID`` blueprint credentials.
- ``A365_OBSERVABILITY_LOG_LEVEL``  e.g. ``DEBUG`` to log span filtering and export results
                        (logger ``microsoft.opentelemetry.a365``).
"""

import asyncio
import logging
import os
import re
import threading
import time
import uuid
from collections import OrderedDict

logger = logging.getLogger(__name__)

OBSERVABILITY_SCOPE = "api://9b975845-388f-4429-889e-eab1ef63949c/.default"
_EXCHANGE_SCOPE = "api://AzureAdTokenExchange/.default"
_REFRESH_MARGIN_SECONDS = 300
_HTTP_TIMEOUT_SECONDS = 10
# Longest a turn waits for the token before running anyway (the exporter retries on its own thread).
_PRIME_WAIT_SECONDS = 5
# The admin center starts a new session after 30 minutes of inactivity.
_CONVERSATION_IDLE_SECONDS = 30 * 60
_MAX_TRACKED_USERS = 1000

_token_lock = threading.Lock()
_tokens: dict[tuple[str, str], tuple[str, float]] = {}
_conversation_lock = threading.Lock()
_conversations: "OrderedDict[str, tuple[str, float]]" = OrderedDict()


def configure_logging() -> None:
    """Apply ``A365_OBSERVABILITY_LOG_LEVEL`` to the distro's Agent 365 exporter logger."""
    level = os.getenv("A365_OBSERVABILITY_LOG_LEVEL", "").strip().upper()
    if level:
        logging.getLogger("microsoft.opentelemetry.a365").setLevel(level)


def agent_id() -> str:
    """The agent identity appId used as ``gen_ai.agent.id`` (from ``A365_AGENT_ID``)."""
    return os.getenv("A365_AGENT_ID", "").strip()


def agent_name() -> str:
    """Span/agent name. Agent Framework also uses it as message author, so keep ``[A-Za-z0-9_-]``."""
    raw = os.getenv("A365_AGENT_NAME") or os.getenv("CONTAINER_APP_NAME") or "agent"
    return re.sub(r"[^A-Za-z0-9_-]+", "-", raw.strip()).strip("-")[:64] or "agent"


def blueprint_id() -> str:
    return os.getenv("CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID", "").strip()


def tenant_id() -> str:
    return (
        os.getenv("CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID")
        or os.getenv("TENANT_ID")
        or ""
    ).strip()


def log_configuration() -> None:
    """One startup line that states whether Agent 365 export can work, and why not."""
    if agent_id():
        logger.info(
            "Agent 365 observability: S2S export as agent identity %s (name '%s', blueprint %s)",
            agent_id(),
            agent_name(),
            blueprint_id() or "?",
        )
    else:
        logger.warning(
            "Agent 365 observability: A365_AGENT_ID is not set - /chat spans cannot be attributed to "
            "the agent identity and will NOT reach Agent 365 (admin center shows no activity)."
        )


def _acquire(agent: str, tenant: str) -> tuple[str, float]:
    import msal

    client_id = blueprint_id()
    secret = os.getenv("CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET", "")
    if not (client_id and secret):
        raise RuntimeError("blueprint credentials (service connection) are not configured")
    authority = f"https://login.microsoftonline.com/{tenant}"
    # Fresh clients on purpose: MSAL's in-memory cache must not mix fmi_path-specific tokens.
    blueprint = msal.ConfidentialClientApplication(
        client_id, authority=authority, client_credential=secret, timeout=_HTTP_TIMEOUT_SECONDS
    )
    step1 = blueprint.acquire_token_for_client([_EXCHANGE_SCOPE], data={"fmi_path": agent})
    app_token = step1.get("access_token")
    if not app_token:
        raise RuntimeError(
            f"agentic application token: {step1.get('error')}: {step1.get('error_description')}"
        )
    identity = msal.ConfidentialClientApplication(
        agent,
        authority=authority,
        client_credential={"client_assertion": app_token},
        timeout=_HTTP_TIMEOUT_SECONDS,
    )
    step2 = identity.acquire_token_for_client([OBSERVABILITY_SCOPE])
    token = step2.get("access_token")
    if not token:
        raise RuntimeError(
            f"observability token: {step2.get('error')}: {step2.get('error_description')}"
        )
    return token, time.time() + int(step2.get("expires_in", 3600))


def resolve_token(agent: str, tenant: str) -> str | None:
    """Exporter token resolver ``(agent_id, tenant_id) -> token``.

    Runs in the exporter's worker thread (never on the event loop) and caches the app-only token
    until shortly before it expires. Returns ``None`` on failure: the exporter then drops the batch
    and logs "No token resolved", which never affects an agent turn.
    """
    if not agent or not tenant:
        return None
    key = (tenant, agent)
    with _token_lock:
        cached = _tokens.get(key)
        if cached and cached[1] - _REFRESH_MARGIN_SECONDS > time.time():
            return cached[0]
        try:
            token, expires_at = _acquire(agent, tenant)
        except Exception as e:  # noqa: BLE001 - telemetry must never break the agent
            logger.warning("Agent 365 observability token (S2S) failed for agent %s: %s", agent, e)
            return None
        _tokens[key] = (token, expires_at)
        logger.info("Agent 365 observability token (S2S) acquired for agent %s", agent)
        return token


async def prime_token(agent: str, tenant: str) -> bool:
    """Acquire/refresh the token before the turn creates spans, off the event loop and bounded:
    a slow identity endpoint never delays the user's reply by more than a few seconds."""
    if not agent or not tenant:
        return False
    try:
        return bool(
            await asyncio.wait_for(
                asyncio.to_thread(resolve_token, agent, tenant), timeout=_PRIME_WAIT_SECONDS
            )
        )
    except asyncio.TimeoutError:
        logger.warning("Agent 365 observability token still pending after %ss", _PRIME_WAIT_SECONDS)
        return False


def conversation_id(user_key: str, new_thread: bool) -> str:
    """Stable conversation id per user for the SPA (which sends no conversation id).

    A new id starts when the SPA starts a thread (empty history) or after 30 minutes of
    inactivity; otherwise the user's current id is reused so follow-ups join the same session.
    """
    now = time.monotonic()
    with _conversation_lock:
        current = _conversations.get(user_key)
        if current and not new_thread and now - current[1] < _CONVERSATION_IDLE_SECONDS:
            conv = current[0]
        else:
            conv = str(uuid.uuid4())
        _conversations[user_key] = (conv, now)
        _conversations.move_to_end(user_key)
        while len(_conversations) > _MAX_TRACKED_USERS:
            _conversations.popitem(last=False)
        return conv


def client_ip(request) -> str | None:
    """Caller IP behind the Container Apps ingress (first X-Forwarded-For hop)."""
    forwarded = request.headers.get("X-Forwarded-For", "")
    ip = forwarded.split(",")[0].strip() if forwarded else (request.remote or "")
    return ip.split("%")[0] or None


def turn_baggage(
    *,
    tenant: str,
    agent: str,
    channel: str,
    conversation: str | None = None,
    user_id: str | None = None,
    user_name: str | None = None,
    user_email: str | None = None,
    caller_ip: str | None = None,
    server_host: str | None = None,
):
    """Baggage scope that the distro's span processor copies onto every span of the turn."""
    from microsoft_agents_a365.observability.core.middleware.baggage_builder import (
        BaggageBuilder,
    )

    builder = (
        BaggageBuilder()
        .tenant_id(tenant or None)
        .agent_id(agent or None)
        .agent_name(agent_name())
        .agent_blueprint_id(blueprint_id() or None)
        .channel_name(channel or None)
        .conversation_id(conversation)
        .user_id(user_id)
        .user_name(user_name)
        .user_email(user_email)
        .user_client_ip(caller_ip)
    )
    if server_host:
        builder = builder.invoke_agent_server(server_host.split(":")[0], 443)
    return builder.build()


def bind_agent_identity(agent, identity_id: str | None = None):
    """Make Agent Framework's invoke_agent span report the agent identity instead of a random id."""
    identity = identity_id or agent_id()
    if agent is not None and identity:
        agent.id = identity
        agent.name = agent_name()
    return agent
