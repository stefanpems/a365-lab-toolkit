# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

"""MCP / outbound-HTTP diagnostics.

Purpose
-------
Calls to the Agent 365 MCP tool servers (e.g. ``mcp_MailTools`` at
``https://agent365.svc.cloud.microsoft/agents/servers/...``) can fail with an
HTTP 4xx/5xx. The underlying ``httpx`` INFO log only records the status line
(e.g. ``"HTTP/1.1 400 Bad Request"``) and NOT the response body, so the actual
reason is invisible in the container logs.

This module patches ``httpx.AsyncClient.send`` so that, for any response with
status >= 400 coming from the Agent 365 service host, it:
  1. logs the full response body (truncated) at ERROR level, and
  2. records the error in a small in-process ring buffer so the message
     handler can surface it to the user in the reply.

Only error responses (status >= 400) are inspected, so normal 2xx (including
SSE/streaming) traffic is left untouched.

Import ``apply_httpx_diagnostics()`` once at startup, before any tool call.
"""

import collections
import json
import base64
import logging
import time
from typing import Optional

import httpx

logger = logging.getLogger("mcp_diag")

# Host of the Agent 365 tool/MCP gateway. Only errors from this host are captured.
_A365_HOST = "agent365.svc.cloud.microsoft"

# Ring buffer of recent tool/HTTP errors. Each entry:
#   {"mono": float, "when": str, "url": str, "status": int, "body": str, "server": str}
_recent_errors: "collections.deque[dict]" = collections.deque(maxlen=50)

_MAX_BODY = 800


def _server_name_from_url(url: str) -> str:
    """Best-effort extraction of the MCP server name from the request URL."""
    # e.g. .../agents/servers/mcp_MailTools -> mcp_MailTools
    try:
        tail = url.rstrip("/").rsplit("/", 1)[-1]
        return tail or url
    except Exception:
        return url


def record_error(url: str, status: int, body: str) -> None:
    """Record a tool/HTTP error into the ring buffer."""
    _recent_errors.append(
        {
            "mono": time.monotonic(),
            "when": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "url": url,
            "status": status,
            "body": (body or "")[:_MAX_BODY],
            "server": _server_name_from_url(url),
        }
    )


def errors_since(mono_ts: float) -> list[dict]:
    """Return tool/HTTP errors recorded at/after the given monotonic timestamp."""
    return [e for e in _recent_errors if e["mono"] >= mono_ts]


def now() -> float:
    """Monotonic clock helper (call at turn start, pass to errors_since)."""
    return time.monotonic()


def _log_mcp_request(request) -> None:
    """Log the JSON-RPC method (and tool name) of an outbound MCP POST request."""
    try:
        raw = request.content  # buffered bytes; does not consume a stream
        if not raw:
            return
        data = json.loads(raw.decode("utf-8", "replace"))
    except Exception:
        return
    items = data if isinstance(data, list) else [data]
    for item in items:
        if not isinstance(item, dict):
            continue
        method = item.get("method")
        if not method:
            continue
        params = item.get("params") or {}
        tool_name = params.get("name") if isinstance(params, dict) else None
        if tool_name:
            logger.info("MCP call → method=%s tool=%s", method, tool_name)
        else:
            logger.info("MCP call → method=%s", method)


def _decode_jwt_claims(auth_header: Optional[str]) -> dict:
    """Decode selected, non-secret claims from a Bearer JWT for diagnostics.

    Never logs the token itself — only routing/identity claims that explain a
    'tenant/agent id is invalid' style rejection.
    """
    if not auth_header:
        return {"authorization": "(missing)"}
    token = auth_header.split(" ", 1)[-1].strip()
    parts = token.split(".")
    if len(parts) < 2:
        return {"token": "(not a JWT)"}
    try:
        payload = parts[1]
        payload += "=" * (-len(payload) % 4)  # pad base64url
        claims = json.loads(base64.urlsafe_b64decode(payload).decode("utf-8", "replace"))
        return {
            "tid": claims.get("tid"),
            "aud": claims.get("aud"),
            "appid": claims.get("appid") or claims.get("azp"),
            "xms_par_app_azp": claims.get("xms_par_app_azp"),
            "roles": claims.get("roles"),
            "scp": claims.get("scp"),
            "idtyp": claims.get("idtyp"),
        }
    except Exception:
        return {"token": "(undecodable)"}


def _agent_id_from_auth_header(auth_header: Optional[str]) -> Optional[str]:
    """Extract the agent identifier from a Bearer JWT, mirroring the SDK's own
    ``x-ms-agentid`` resolution order: ``xms_par_app_azp`` > ``appid`` > ``azp``.

    Returns None when no token / no usable claim is present.
    """
    if not auth_header:
        return None
    token = auth_header.split(" ", 1)[-1].strip()
    parts = token.split(".")
    if len(parts) < 2:
        return None
    try:
        payload = parts[1]
        payload += "=" * (-len(payload) % 4)  # pad base64url
        claims = json.loads(base64.urlsafe_b64decode(payload).decode("utf-8", "replace"))
    except Exception:
        return None
    for claim in ("xms_par_app_azp", "appid", "azp"):
        value = claims.get(claim)
        if value:
            return str(value)
    return None


def _ensure_agent_id_header(request) -> None:
    """Stamp the ``x-ms-agentid`` header on outbound Agent 365 MCP tool calls.

    The Agent 365 SDK adds ``x-ms-agentid`` to the discovery (gateway) request but
    NOT to the per-server MCP tool calls, so those requests reach the tool gateway
    with no agent identifier. When the gateway requires it, the call fails with
    HTTP 401. We derive the same value the SDK would use (from the Authorization
    JWT) and attach it when missing. No-op if the header is already present or the
    id cannot be resolved.
    """
    try:
        if request.headers.get("x-ms-agentid"):
            return
        agent_id = _agent_id_from_auth_header(request.headers.get("authorization"))
        if agent_id:
            request.headers["x-ms-agentid"] = agent_id
            logger.info("Stamped x-ms-agentid=%s on MCP tool request", agent_id)
    except Exception as exc:  # pragma: no cover - never break the request path
        logger.debug("Could not stamp x-ms-agentid: %s", exc)


def apply_httpx_diagnostics() -> None:
    """Patch httpx.AsyncClient.send to capture bodies of Agent 365 error responses."""
    if getattr(httpx.AsyncClient, "_a365_diag_patched", False):
        return

    original_send = httpx.AsyncClient.send

    async def patched_send(self, request, **kwargs):  # type: ignore[no-untyped-def]
        # Log which MCP JSON-RPC method / tool the agent invokes (safe: request
        # content is already buffered). Reveals e.g. tools/list vs which tool
        # (createDraft vs sendMail) the LLM actually calls.
        try:
            if (request.method or "").upper() == "POST" and _A365_HOST in str(request.url):
                _log_mcp_request(request)
                _ensure_agent_id_header(request)
        except Exception:  # pragma: no cover - never break the request path
            pass

        response = await original_send(self, request, **kwargs)
        try:
            url = str(request.url)
            if response.status_code >= 400 and _A365_HOST in url:
                method = (request.method or "").upper()
                body = "(body unavailable)"
                try:
                    raw = await response.aread()
                    body = raw.decode("utf-8", "replace").strip()
                except Exception:  # pragma: no cover - defensive
                    pass
                # Benign MCP transport negotiation: the streamable-HTTP client
                # probes the endpoint with GET (SSE); this server answers 405
                # ("use POST for MCP JSON-RPC") and the client then POSTs fine.
                # Do NOT treat that as a tool failure.
                benign = method == "GET" or response.status_code == 405
                if benign:
                    logger.info(
                        "Agent 365 benign HTTP %s %s from %s (transport negotiation; ignored)",
                        response.status_code,
                        method,
                        url,
                    )
                else:
                    claims = _decode_jwt_claims(request.headers.get("authorization"))
                    agent_id_header = request.headers.get("x-ms-agentid")
                    logger.error(
                        "Agent 365 tool call failed — HTTP %s %s from %s | body: %s | "
                        "x-ms-agentid=%r | token_claims=%s",
                        response.status_code,
                        method,
                        url,
                        body[:_MAX_BODY],
                        agent_id_header,
                        json.dumps(claims, default=str),
                    )
                    record_error(url, response.status_code, body)
        except Exception as exc:  # pragma: no cover - never break the request path
            logger.debug("httpx diagnostics hook error: %s", exc)
        return response

    httpx.AsyncClient.send = patched_send  # type: ignore[method-assign]
    httpx.AsyncClient._a365_diag_patched = True  # type: ignore[attr-defined]
    logger.info("httpx Agent 365 error diagnostics enabled")


def format_tool_error_notice(errors: list[dict], app_name: Optional[str] = None) -> str:
    """Build a user-facing notice describing captured tool errors + where to look."""
    if not errors:
        return ""
    # Summarize distinct (server, status) pairs.
    seen: dict[tuple[str, int], dict] = {}
    for e in errors:
        seen.setdefault((e["server"], e["status"]), e)
    lines = ["", "⚠️ **A tool error occurred while handling your request.**"]
    for (server, status), e in seen.items():
        detail = e["body"].replace("\n", " ").strip()
        if len(detail) > 300:
            detail = detail[:300] + "…"
        lines.append(f"• **What failed:** MCP tool `{server}`")
        lines.append(f"• **Error type:** HTTP {status} ({_http_reason(status)}) from `{e['url']}`")
        if detail:
            lines.append(f"• **Detail:** {detail}")
    lines.append(_where_to_look(app_name))
    return "\n".join(lines)


def format_exception_notice(exc: BaseException, stage: str, app_name: Optional[str] = None) -> str:
    """Build a user-facing notice for an unhandled exception + where to look."""
    lines = [
        "",
        "⚠️ **An error occurred while processing your request.**",
        f"• **What failed:** {stage}",
        f"• **Error type:** {type(exc).__name__}",
        f"• **Detail:** {str(exc)[:300]}",
        _where_to_look(app_name),
    ]
    return "\n".join(lines)


def _http_reason(status: int) -> str:
    return {
        400: "Bad Request",
        401: "Unauthorized",
        403: "Forbidden",
        404: "Not Found",
        408: "Request Timeout",
        429: "Too Many Requests",
        500: "Internal Server Error",
        502: "Bad Gateway",
        503: "Service Unavailable",
        504: "Gateway Timeout",
    }.get(status, "HTTP error")


def _where_to_look(app_name: Optional[str]) -> str:
    app = app_name or "the agent host"
    return (
        f"• **Where to investigate:** container logs of `{app}` (stderr). "
        "In Log Analytics run: "
        "`ContainerAppConsoleLogs_CL | where Log_s has \"agent365.svc.cloud.microsoft\" "
        "or Log_s has \"Agent 365 tool call failed\" | order by TimeGenerated desc` "
        "— the `mcp_diag` ERROR line contains the failing URL, status and response body."
    )
