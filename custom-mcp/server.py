"""
Agent 365 sample custom MCP server
==================================

A single container that hosts TWO Model Context Protocol (MCP) servers over
streamable HTTP, mounted on two different paths so each can be registered in
Agent 365 with a DIFFERENT authentication type (the auth type is per
registration, not per tool):

  /anon/mcp  -> register in Agent 365 with auth-type NoAuth      (ext_<Name>Anon)
               No caller token is forwarded by the Agent 365 gateway. Tools test
               anonymous invocation, direct responses and outbound connectivity.

  /auth/mcp  -> register in Agent 365 with auth-type EntraOAuth   (ext_<Name>Auth)
               The Agent 365 gateway forwards an Entra ID bearer token. Tools
               inspect the caller identity (OBO vs S2S vs Digital Worker) and
               propagate the delegated credential to Microsoft Graph (On-Behalf-Of).

This is a LAB sample: the ingress is public and the server itself performs no
authorization. Do not expose real data. See README.md for deployment and
registration steps.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import time
from datetime import datetime, timezone
from typing import Any

import httpx
from fastmcp import FastMCP
from fastmcp.server.dependencies import get_http_headers

# msal is only needed by the auth server's propagate_to_graph tool. Import lazily
# so the anonymous server keeps working even if the dependency is missing.
try:
    import msal  # type: ignore
except Exception:  # pragma: no cover - optional at runtime
    msal = None  # type: ignore


GRAPH_ME_URL = "https://graph.microsoft.com/v1.0/me"
GRAPH_ORG_URL = "https://graph.microsoft.com/v1.0/organization"
GRAPH_USER_READ_SCOPE = "https://graph.microsoft.com/User.Read"
GRAPH_DEFAULT_SCOPE = "https://graph.microsoft.com/.default"


# ===========================================================================
# Shared helpers
# ===========================================================================

def _bearer_token() -> str | None:
    """Return the raw bearer token from the incoming Authorization header, if any."""
    headers = get_http_headers()
    auth = headers.get("authorization") or headers.get("Authorization")
    if not auth:
        return None
    parts = auth.split(" ", 1)
    if len(parts) == 2 and parts[0].lower() == "bearer":
        return parts[1].strip()
    return auth.strip()


def _decode_jwt_claims(token: str) -> dict[str, Any]:
    """Decode the payload of a JWT WITHOUT verifying its signature.

    For a lab sample this is enough to display who is calling. A production
    server should validate the signature, issuer and audience against the
    tenant's JWKS before trusting any claim.
    """
    try:
        payload_b64 = token.split(".")[1]
        payload_b64 += "=" * (-len(payload_b64) % 4)  # pad to a multiple of 4
        return json.loads(base64.urlsafe_b64decode(payload_b64))
    except Exception as exc:  # pragma: no cover - malformed token
        return {"_decode_error": str(exc)}


def _classify_identity(claims: dict[str, Any]) -> dict[str, Any]:
    """Describe which identity model the token represents (OBO / S2S / DW)."""
    idtyp = str(claims.get("idtyp", "")).lower()
    has_user = bool(claims.get("upn") or claims.get("preferred_username") or claims.get("name"))
    has_scopes = bool(claims.get("scp"))
    has_roles = bool(claims.get("roles"))

    if idtyp == "app" or (has_roles and not has_scopes and not has_user):
        kind = "app-only"
        acting_as = "the application itself (service-to-service, e.g. an S2S agent)"
    elif has_scopes or has_user:
        kind = "delegated"
        acting_as = (
            "a user on whose behalf the agent acts (OBO), or the agent's own "
            "user identity (Digital Worker) — see 'user' below"
        )
    else:
        kind = "unknown"
        acting_as = "could not be determined from the token claims"

    return {
        "token_type": kind,
        "acting_as": acting_as,
        "app_id": claims.get("appid") or claims.get("azp"),
        "object_id": claims.get("oid"),
        "subject": claims.get("sub"),
        "user_principal_name": claims.get("upn") or claims.get("preferred_username"),
        "user_display_name": claims.get("name"),
        "tenant_id": claims.get("tid"),
        "audience": claims.get("aud"),
        "issuer": claims.get("iss"),
        "scopes": claims.get("scp"),
        "app_roles": claims.get("roles"),
    }


# ===========================================================================
# ANONYMOUS server  ->  register with auth-type NoAuth  (ext_<Name>Anon)
# ===========================================================================

anon_mcp = FastMCP(
    name="Agent 365 sample tools (anonymous)",
    instructions=(
        "Anonymous test tools for an Agent 365 custom MCP server registered with "
        "auth-type NoAuth. Use 'server_time' and 'hash_text' to test direct, "
        "self-contained responses; 'outbound_connectivity_check' to test that the "
        "tool host can reach the public internet; and 'whoami_anon' to confirm that "
        "no caller token is forwarded when a server is registered as NoAuth."
    ),
)


@anon_mcp.tool
def server_time() -> dict[str, Any]:
    """Return the current date and time from the server clock.

    Self-contained (no network, no authentication). Use this to verify that an
    anonymous tool call reaches the server and returns a direct response.
    """
    now = datetime.now(timezone.utc)
    return {
        "utc_iso8601": now.isoformat(),
        "unix_epoch_seconds": int(now.timestamp()),
        "weekday": now.strftime("%A"),
        "note": "Direct, self-contained response — no network egress, no auth.",
    }


@anon_mcp.tool
def hash_text(text: str, algo: str = "sha256") -> dict[str, Any]:
    """Return the hexadecimal digest of a text.

    Self-contained compute (no network, no authentication). Use this as a second
    direct-response test.

    Args:
        text: The text to hash.
        algo: Hash algorithm. One of sha256 (default), sha1, sha512, md5.
    """
    algo_key = algo.strip().lower()
    if algo_key not in {"sha256", "sha1", "sha512", "md5"}:
        return {"error": f"Unsupported algo '{algo}'. Use sha256, sha1, sha512 or md5."}
    digest = hashlib.new(algo_key, text.encode("utf-8")).hexdigest()
    return {"algo": algo_key, "input_length": len(text), "hex_digest": digest}


@anon_mcp.tool
async def outbound_connectivity_check(target: str | None = None) -> dict[str, Any]:
    """Test that the tool host can reach the public internet (egress).

    Performs a single HTTPS GET to a public endpoint and reports the HTTP status
    and round-trip latency. Use this to test tool-to-internet connectivity and to
    observe network-egress governance policies in Agent 365.

    Args:
        target: (Optional) HTTPS URL to probe. Defaults to https://www.microsoft.com.
    """
    url = (target or "https://www.microsoft.com").strip()
    if not url.lower().startswith("https://"):
        return {"error": "Only HTTPS targets are allowed.", "target": url}
    started = time.perf_counter()
    try:
        async with httpx.AsyncClient(timeout=15.0, follow_redirects=True) as client:
            response = await client.get(url)
        elapsed_ms = round((time.perf_counter() - started) * 1000, 1)
        return {
            "target": url,
            "reachable": True,
            "http_status": response.status_code,
            "latency_ms": elapsed_ms,
            "note": "Egress worked from the tool host.",
        }
    except httpx.HTTPError as exc:
        elapsed_ms = round((time.perf_counter() - started) * 1000, 1)
        return {
            "target": url,
            "reachable": False,
            "latency_ms": elapsed_ms,
            "error": f"Could not reach the target: {exc}",
        }


@anon_mcp.tool
def whoami_anon() -> dict[str, Any]:
    """Report whether a caller token was forwarded to this (NoAuth) server.

    For a server registered as NoAuth, the Agent 365 gateway forwards NO
    Authorization header. This tool confirms that and lists the headers that did
    arrive, as a contrast to the '/auth' server's 'whoami' tool.
    """
    headers = get_http_headers()
    has_auth = bool(headers.get("authorization") or headers.get("Authorization"))
    return {
        "authorization_header_present": has_auth,
        "expected_for_noauth": False,
        "explanation": (
            "This server is meant to be registered with auth-type NoAuth, so no "
            "caller token should arrive. To inspect an actual caller identity, use "
            "the 'whoami' tool on the EntraOAuth ('/auth') server."
        ),
        "received_header_names": sorted(headers.keys()),
    }


# ===========================================================================
# AUTHENTICATED server  ->  register with auth-type EntraOAuth  (ext_<Name>Auth)
# ===========================================================================

auth_mcp = FastMCP(
    name="Agent 365 sample tools (authenticated)",
    instructions=(
        "Authenticated test tools for an Agent 365 custom MCP server registered "
        "with auth-type EntraOAuth. Use 'whoami' to see which identity is calling "
        "(OBO user, S2S application, or Digital Worker), 'token_claims' for the raw "
        "decoded claims, and 'propagate_to_graph' to test delegated credential "
        "propagation to Microsoft Graph via the On-Behalf-Of flow."
    ),
)


@auth_mcp.tool
def whoami() -> dict[str, Any]:
    """Report which identity is calling this tool, decoded from the Entra token.

    The Agent 365 gateway forwards an Entra ID bearer token when the server is
    registered with auth-type EntraOAuth. This tool decodes that token and
    summarizes the caller so you can see, empirically, who authenticates for each
    agent identity model:
      - OBO agent          -> delegated token, carries the signed-in user's claims
      - S2S agent          -> app-only token (app roles, no user)
      - Digital Worker     -> delegated token carrying the agent's OWN user identity
    """
    token = _bearer_token()
    if not token:
        return {
            "error": "No Authorization header was forwarded.",
            "hint": (
                "Register this server with auth-type EntraOAuth so the Agent 365 "
                "gateway attaches a caller token."
            ),
        }
    claims = _decode_jwt_claims(token)
    return _classify_identity(claims)


@auth_mcp.tool
def token_claims() -> dict[str, Any]:
    """Return the full set of decoded claims from the incoming Entra token.

    Companion to 'whoami' for deeper inspection. The signature is NOT verified
    (lab sample); a production server must validate it.
    """
    token = _bearer_token()
    if not token:
        return {"error": "No Authorization header was forwarded."}
    return {"claims": _decode_jwt_claims(token)}


@auth_mcp.tool
async def propagate_to_graph() -> dict[str, Any]:
    """Propagate the caller's credential to Microsoft Graph and read the identity.

    Flagship credential-propagation test. If the incoming token is a DELEGATED
    token (OBO agent, or a Digital Worker's own user), this tool performs an
    On-Behalf-Of (OBO) exchange for the minimal Microsoft Graph scope 'User.Read'
    and calls GET /me, proving the delegated credential propagates end-to-end to a
    downstream Entra-protected service AS the caller.

    If the incoming token is an APP-ONLY token (S2S agent), OBO does not apply
    (there is no user to impersonate); the tool then makes a best-effort app-only
    Graph call and reports the application context instead.

    Requires the auth server's Entra app to be a confidential client configured via
    the environment variables MCP_AUTH_CLIENT_ID, MCP_AUTH_CLIENT_SECRET and
    MCP_AUTH_TENANT_ID, with Microsoft Graph 'User.Read' (delegated) granted and
    admin-consented. See README.md ("Advanced: propagate_to_graph setup").
    """
    token = _bearer_token()
    if not token:
        return {"error": "No Authorization header was forwarded."}

    client_id = os.environ.get("MCP_AUTH_CLIENT_ID")
    client_secret = os.environ.get("MCP_AUTH_CLIENT_SECRET")
    tenant_id = os.environ.get("MCP_AUTH_TENANT_ID")
    if not (client_id and client_secret and tenant_id):
        return {
            "configured": False,
            "error": (
                "propagate_to_graph is not configured. Set MCP_AUTH_CLIENT_ID, "
                "MCP_AUTH_CLIENT_SECRET and MCP_AUTH_TENANT_ID on the container."
            ),
        }
    if msal is None:
        return {"configured": False, "error": "The 'msal' package is not installed."}

    claims = _decode_jwt_claims(token)
    identity = _classify_identity(claims)
    app = msal.ConfidentialClientApplication(
        client_id,
        authority=f"https://login.microsoftonline.com/{tenant_id}",
        client_credential=client_secret,
    )

    # Delegated token (OBO / Digital Worker) -> On-Behalf-Of exchange to Graph /me.
    if identity["token_type"] == "delegated":
        result = app.acquire_token_on_behalf_of(
            user_assertion=token, scopes=[GRAPH_USER_READ_SCOPE]
        )
        if "access_token" not in result:
            return {
                "flow": "on-behalf-of",
                "success": False,
                "error": result.get("error"),
                "error_description": result.get("error_description"),
                "caller": identity,
            }
        me = await _graph_get(GRAPH_ME_URL, result["access_token"])
        return {
            "flow": "on-behalf-of",
            "success": True,
            "downstream_service": "Microsoft Graph GET /me",
            "resolved_identity": me,
            "caller": identity,
            "note": "The delegated credential propagated to Graph as the caller.",
        }

    # App-only token (S2S) -> OBO not applicable; best-effort app-only Graph call.
    result = app.acquire_token_for_client(scopes=[GRAPH_DEFAULT_SCOPE])
    if "access_token" not in result:
        return {
            "flow": "client-credentials",
            "success": False,
            "obo_applicable": False,
            "error": result.get("error"),
            "error_description": result.get("error_description"),
            "caller": identity,
        }
    org = await _graph_get(GRAPH_ORG_URL, result["access_token"])
    return {
        "flow": "client-credentials",
        "success": True,
        "obo_applicable": False,
        "reason": "The caller is an app-only (S2S) identity; there is no user to impersonate.",
        "downstream_service": "Microsoft Graph GET /organization (app-only)",
        "organization": org,
        "caller": identity,
    }


async def _graph_get(url: str, access_token: str) -> Any:
    """GET a Microsoft Graph URL with a bearer token; return JSON or an error dict."""
    try:
        async with httpx.AsyncClient(timeout=20.0) as client:
            response = await client.get(url, headers={"Authorization": f"Bearer {access_token}"})
            response.raise_for_status()
            return response.json()
    except httpx.HTTPError as exc:
        return {"graph_error": str(exc)}


# ===========================================================================
# Combined ASGI app: mount both MCP servers under /anon and /auth
# ===========================================================================

def build_app():
    """Build a Starlette app mounting both MCP servers with a combined lifespan."""
    import contextlib

    from starlette.applications import Starlette
    from starlette.routing import Mount, Route
    from starlette.responses import JSONResponse

    anon_app = anon_mcp.http_app(path="/mcp")
    auth_app = auth_mcp.http_app(path="/mcp")

    @contextlib.asynccontextmanager
    async def lifespan(app):
        async with contextlib.AsyncExitStack() as stack:
            await stack.enter_async_context(anon_app.router.lifespan_context(anon_app))
            await stack.enter_async_context(auth_app.router.lifespan_context(auth_app))
            yield

    async def health(_request):
        return JSONResponse({"status": "ok", "servers": ["/anon/mcp", "/auth/mcp"]})

    return Starlette(
        routes=[
            Route("/health", health),
            Mount("/anon", app=anon_app),
            Mount("/auth", app=auth_app),
        ],
        lifespan=lifespan,
    )


def build_single(server, label):
    """Serve ONE MCP server at the ROOT path '/mcp' (plus '/health').

    Agent 365 registration builds a proxy connector from the serverUrl and fails with
    'HTTP 400: Bad Request' when the MCP endpoint is under a multi-segment path such as
    '/anon/mcp'. A single-segment root '/mcp' (as used by the reference servers) works, so
    each server is deployed in its OWN container at '/mcp' — selected via MCP_SERVER_MODE.
    """
    from starlette.routing import Route
    from starlette.responses import JSONResponse

    single = server.http_app(path="/mcp")

    async def health(_request):
        return JSONResponse({"status": "ok", "server": label, "path": "/mcp"})

    single.router.routes.insert(0, Route("/health", health))
    return single


# MCP_SERVER_MODE selects which server this container hosts (registration needs a single
# '/mcp' path — see build_single): 'anon' -> anon at /mcp, 'auth' -> auth at /mcp. Any other
# value (default) serves BOTH at /anon/mcp + /auth/mcp for local exploration only (NOT
# registerable in Agent 365).
_mode = os.environ.get("MCP_SERVER_MODE", "").strip().lower()
if _mode == "anon":
    app = build_single(anon_mcp, "anon")
elif _mode == "auth":
    app = build_single(auth_mcp, "auth")
else:
    app = build_app()


if __name__ == "__main__":
    import uvicorn

    port = int(os.environ.get("PORT", "8000"))
    uvicorn.run(app, host="0.0.0.0", port=port)
