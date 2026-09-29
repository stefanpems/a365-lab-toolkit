"""Acquire a delegated Microsoft Graph token for Set-EntraAgentRisk.ps1 with MSAL.

Sign-in uses the system browser (no WAM, so it works from agent and embedded hosts without a console
window) or the device code flow. The MSAL cache is persisted so later runs are silent: encrypted with
Windows DPAPI, except for paths ending in .json (plain MSAL JSON, to reuse an existing lab cache).
Prints ONE JSON line on stdout (token, tenant, account, scopes) for the caller to capture: never
display it. Messages and errors go to stderr.
"""

import argparse
import base64
import json
import os
import sys

import msal

CLIENT_ID = "14d82eec-204b-4c2f-b7e8-296a70dab67e"  # Microsoft Graph Command Line Tools (public client)


def _dpapi(data: bytes, protect: bool) -> bytes:
    import ctypes
    from ctypes import wintypes

    class Blob(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]

    buffer = ctypes.create_string_buffer(data, len(data))
    blob_in = Blob(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_char)))
    blob_out = Blob()
    crypt32 = ctypes.windll.crypt32
    function = crypt32.CryptProtectData if protect else crypt32.CryptUnprotectData
    if not function(ctypes.byref(blob_in), None, None, None, None, 0, ctypes.byref(blob_out)):
        raise ctypes.WinError()
    try:
        return ctypes.string_at(blob_out.pbData, blob_out.cbData)
    finally:
        local_free = ctypes.windll.kernel32.LocalFree
        local_free.argtypes = [ctypes.c_void_p]
        local_free.restype = ctypes.c_void_p
        local_free(ctypes.cast(blob_out.pbData, ctypes.c_void_p))


def _is_plain(path: str) -> bool:
    return path.lower().endswith(".json") or os.name != "nt"


def load_cache(path: str) -> msal.SerializableTokenCache:
    cache = msal.SerializableTokenCache()
    if os.path.exists(path):
        try:
            with open(path, "rb") as handle:
                data = handle.read()
            if data:
                cache.deserialize((data if _is_plain(path) else _dpapi(data, protect=False)).decode("utf-8"))
        except (OSError, ValueError) as error:
            print(f"WARNING: ignoring unreadable token cache ({type(error).__name__}).", file=sys.stderr)
    return cache


def save_cache(cache: msal.SerializableTokenCache, path: str) -> None:
    if not cache.has_state_changed:
        return
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    data = cache.serialize().encode("utf-8")
    with open(path, "wb") as handle:
        handle.write(data if _is_plain(path) else _dpapi(data, protect=True))
    if os.name != "nt":
        os.chmod(path, 0o600)


def acquire(app: msal.PublicClientApplication, scopes: list, tenant: str, auth: str, hint: str | None) -> dict | None:
    accounts = app.get_accounts(username=hint)
    # Prefer cached accounts of the target tenant; without a hint never pick an arbitrary account.
    accounts = [a for a in accounts if a.get("realm") == tenant] or (accounts if hint else [])
    if accounts:
        result = app.acquire_token_silent(scopes, account=accounts[0])
        if result and "access_token" in result:
            return result
    if auth == "devicecode":
        flow = app.initiate_device_flow(scopes=scopes)
        if "user_code" not in flow:
            return flow
        print(flow["message"], file=sys.stderr, flush=True)
        return app.acquire_token_by_device_flow(flow)
    print(">>> ACTION REQUIRED: complete the Microsoft Graph sign-in in the browser tab that opens.", file=sys.stderr, flush=True)
    return app.acquire_token_interactive(scopes, login_hint=hint, prompt="select_account", timeout=900)


def _claims(access_token: str) -> dict:
    try:
        payload = access_token.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except (IndexError, ValueError):
        return {}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tenant", required=True)
    parser.add_argument("--scopes", required=True, help="Comma-separated Microsoft Graph scopes")
    parser.add_argument("--cache", required=True)
    parser.add_argument("--auth", choices=("browser", "devicecode"), default="browser")
    parser.add_argument("--login-hint")
    args = parser.parse_args()

    scopes = [s if s.startswith("https://") else f"https://graph.microsoft.com/{s}" for s in args.scopes.split(",") if s]
    cache = load_cache(args.cache)
    app = msal.PublicClientApplication(CLIENT_ID, authority=f"https://login.microsoftonline.com/{args.tenant}", token_cache=cache)
    result = acquire(app, scopes, args.tenant.lower(), args.auth, args.login_hint)
    save_cache(cache, args.cache)
    if not result or "access_token" not in result:
        detail = {key: (result or {}).get(key) for key in ("error", "error_description")}
        print("ERROR: " + json.dumps(detail), file=sys.stderr)
        return 1
    claims = _claims(result["access_token"])
    print(json.dumps({
        "access_token": result["access_token"],
        "tenant_id": claims.get("tid"),
        "account": claims.get("upn") or claims.get("unique_name") or (result.get("id_token_claims") or {}).get("preferred_username"),
        "scopes": claims.get("scp") or result.get("scope", ""),
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())