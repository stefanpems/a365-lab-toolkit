"""Acquire a delegated Microsoft 365 Mail token for local OBO testing (device-code flow).

Prints a bearer token whose audience is Agent 365 Tools (ea9ffc3e-…) with scope
McpServers.Mail.All — the token the declarative OBO agent needs as `mail_token`.

Uses the public client "Agent 365 CLI" (3c5eabff-…), which is consented for the Mail scope.
Run:
  python get_mail_token.py                 # prints the token
  $env:MAIL_TOKEN = (python get_mail_token.py)   # capture it for invoke_agent.py
"""

from __future__ import annotations

import sys

import msal

import agent_config as cfg


def acquire() -> str:
    app = msal.PublicClientApplication(
        client_id=cfg.CLIENT_APP_ID,
        authority=f"https://login.microsoftonline.com/{cfg.TENANT_ID}",
    )
    scopes = [cfg.MAIL_MCP_SCOPE]

    # Try a cached account first, then fall back to interactive device code.
    result = None
    accounts = app.get_accounts()
    if accounts:
        result = app.acquire_token_silent(scopes, account=accounts[0])
    if not result:
        flow = app.initiate_device_flow(scopes=scopes)
        if "user_code" not in flow:
            raise RuntimeError(f"Failed to start device flow: {flow}")
        print(flow["message"], file=sys.stderr)  # instructions go to stderr
        result = app.acquire_token_by_device_flow(flow)

    if "access_token" not in result:
        raise RuntimeError(f"Token acquisition failed: {result.get('error_description', result)}")
    return result["access_token"]


if __name__ == "__main__":
    print(acquire())
