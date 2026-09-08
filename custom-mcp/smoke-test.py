"""Smoke-test a custom Agent 365 MCP server by connecting directly to its Streamable
HTTP ``/mcp`` endpoint (the Python equivalent of ``rg-mcp-demo/smoke-test.mjs``): it
initializes an MCP session, lists the server's tools, and invokes each with sensible
sample arguments, printing the real results.

This hits the server's OWN endpoint directly (bypassing the Agent 365 gateway), so it
validates the tool implementations and the server's own auth, independent of any agent.
Use it to confirm the custom tools work and to compare against what an agent returns.

Examples (PowerShell):
    $py = ".\\.venv\\Scripts\\python.exe"

    # Anonymous (NoAuth) server — no token needed:
    & $py smoke-test.py --url https://<anon-fqdn>/mcp

    # Authenticated (EntraOAuth) server — supply a Bearer token for its resource:
    & $py smoke-test.py --url https://<auth-fqdn>/mcp --token "<jwt>"

    # ...or acquire a user token interactively (device code) for the auth resource:
    & $py smoke-test.py --url https://<auth-fqdn>/mcp `
        --client-id <public-client-app-id> --scope api://<auth-app-id>/access_as_agent `
        --tenant <tenant-id>

    # Call only one tool:
    & $py smoke-test.py --url https://<fqdn>/mcp --tool server_time
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys

# Sensible sample arguments for the known sample tools (both this repo's server.py and
# the rg-mcp-demo UtilityInsights server). Tools not listed here are called with no args.
SAMPLE_ARGS: dict[str, dict] = {
    "hash_text": {"text": "hello world"},
    "slugify": {"text": "Citta di Milano!"},
    "get_weather": {"city": "Rome"},
    "convert_currency": {"from": "EUR", "to": "USD", "amount": 10},
}


def _bearer(token: str) -> str:
    return token if token.lower().startswith("bearer ") else f"Bearer {token}"


async def run(url: str, token: str | None, only: str | None) -> int:
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    headers = {"Authorization": _bearer(token)} if token else None
    async with streamablehttp_client(url, headers=headers) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            listed = await session.list_tools()
            names = [t.name for t in listed.tools]
            print(f"[OK] connected to {url}")
            print(f"[OK] {len(names)} tool(s) exposed: {names}")

            failures = 0
            for name in ([only] if only else names):
                if name not in names:
                    print(f"[SKIP] '{name}' is not exposed by this server")
                    continue
                args = SAMPLE_ARGS.get(name, {})
                try:
                    res = await session.call_tool(name, args)
                    payload = [
                        c.text if hasattr(c, "text") else str(c) for c in (res.content or [])
                    ]
                    flag = "ERR" if getattr(res, "isError", False) else "CALL"
                    print(f"[{flag}] {name}({args}) -> {json.dumps(payload)[:800]}")
                    if getattr(res, "isError", False):
                        failures += 1
                except Exception as e:  # noqa: BLE001 - report and continue
                    failures += 1
                    print(f"[FAIL] {name}({args}) -> {type(e).__name__}: {e}")
            print(f"\nDONE: {len(names)} tool(s), {failures} failure(s).")
            return 1 if failures else 0


def acquire_token(client_id: str, scope: str, tenant: str) -> str:
    """Interactive device-code token for the given resource scope (public client)."""
    import msal

    app = msal.PublicClientApplication(
        client_id, authority=f"https://login.microsoftonline.com/{tenant}"
    )
    flow = app.initiate_device_flow(scopes=[scope])
    if "user_code" not in flow:
        raise SystemExit(f"device flow error: {flow.get('error_description')}")
    print(flow["message"], flush=True)
    result = app.acquire_token_by_device_flow(flow)
    if "access_token" not in result:
        raise SystemExit(f"token error: {result.get('error_description')}")
    return result["access_token"]


def main() -> int:
    p = argparse.ArgumentParser(description="Smoke-test a custom MCP server's /mcp endpoint.")
    p.add_argument("--url", required=True, help="Full /mcp Streamable HTTP endpoint URL.")
    p.add_argument("--token", default=None, help="Bearer token for an EntraOAuth server.")
    p.add_argument("--client-id", default=None, help="Public client app id for device-code login.")
    p.add_argument("--scope", default=None, help="Resource scope, e.g. api://<appId>/access_as_agent.")
    p.add_argument("--tenant", default="organizations", help="Tenant id/domain for device-code login.")
    p.add_argument("--tool", default=None, help="Call only this tool (default: call all).")
    a = p.parse_args()

    token = a.token
    if not token and a.client_id and a.scope:
        token = acquire_token(a.client_id, a.scope, a.tenant)

    return asyncio.run(run(a.url, token, a.tool))


if __name__ == "__main__":
    sys.exit(main())
