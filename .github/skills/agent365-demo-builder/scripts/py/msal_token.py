"""Delegated token for the Demo Builder scripts: MSAL public client, system browser on first use (no WAM, no device
code), persistent per-lab cache. Prints ONLY the access token on stdout (captured by the caller, never displayed).
Scopes without a resource prefix are Microsoft Graph scopes.
Usage: python msal_token.py --tenant <id> --client <appId> --scopes a,b --cache <file> [--hint <upn>]
"""
import argparse
import json
import os
import sys

import msal


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tenant", required=True)
    ap.add_argument("--client", required=True)
    ap.add_argument("--scopes", required=True)
    ap.add_argument("--cache", required=True)
    ap.add_argument("--hint", default="")
    a = ap.parse_args()
    scopes = [s if ("://" in s or "/" in s) else f"https://graph.microsoft.com/{s}" for s in a.scopes.split(",") if s]
    cache = msal.SerializableTokenCache()
    if os.path.exists(a.cache):
        with open(a.cache, "r", encoding="utf-8") as f:
            cache.deserialize(f.read())
    app = msal.PublicClientApplication(a.client, authority=f"https://login.microsoftonline.com/{a.tenant}", token_cache=cache)
    accounts = app.get_accounts(username=a.hint) if a.hint else app.get_accounts()
    result = app.acquire_token_silent(scopes, account=accounts[0]) if accounts else None
    if not result:
        print(">>> ACTION REQUIRED: a browser tab opens for the sign-in (system browser).", file=sys.stderr)
        result = app.acquire_token_interactive(scopes, login_hint=a.hint or None, prompt="select_account", timeout=900)
    if cache.has_state_changed:
        os.makedirs(os.path.dirname(os.path.abspath(a.cache)), exist_ok=True)
        with open(a.cache, "w", encoding="utf-8") as f:
            f.write(cache.serialize())
    if not result or "access_token" not in result:
        print("ERROR: " + json.dumps({k: (result or {}).get(k) for k in ("error", "error_description")}), file=sys.stderr)
        return 1
    print(result["access_token"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
