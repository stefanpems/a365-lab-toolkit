"""Programmatic invocation harness for the 8 Lab Builder agents (lab a09091).

Authenticated as admin@ via MSAL. Auth strategy:
  - Foundry endpoint auth (https://ai.azure.com): acquired via MSAL as the user; az can also mint it.
  - Mail (ea9ffc3e/McpServers.Mail.All), S2S (api://7d2ac498/access_agent_as_user), and custom BYO
    tool scopes: acquired via MSAL using the SPA public client d83393e4 (device-code the first time,
    then silent from the serialized cache). az cannot mint these (first-party preauth / no consent).

Usage:
  python agent_client.py login            # one-time device-code sign-in (admin@)
  python agent_client.py whoami           # show cached account
  python agent_client.py send <target> "<message>"   # target: aca-obo aca-s2s fh-obo fh-s2s fd-obo fd-s2s
"""
import json
import os
import sys
import uuid

import msal
import requests

TENANT = "17bced19-f481-4ac1-b7a9-56cf8adea989"
CLIENT_ID = "d83393e4-97db-4caf-8a74-289625e8e1bd"  # SPA app registration (a09091-ui-spa)
AUTHORITY = f"https://login.microsoftonline.com/{TENANT}"
CACHE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "token_cache.json")

# Scope groups (each request targets a single resource; .default only for Foundry).
SC_MAIL = ["ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/McpServers.Mail.All"]
SC_S2S = ["api://7d2ac498-2784-46e0-8137-cbfbd66229ff/access_agent_as_user"]
SC_FOUNDRY = ["https://ai.azure.com/.default"]
SC_ANON = ["34e73118-e529-4dd4-84d9-20db246e9c86/Tools.ListInvoke.All"]
SC_AUTH = ["3f1baf71-de2c-4fef-ae38-facc4dd5fcc2/Tools.ListInvoke.All"]

AUD_MAIL = "ea9ffc3e-8a23-4a7d-836d-234d7c7565c1"
AUD_ANON = "34e73118-e529-4dd4-84d9-20db246e9c86"
AUD_AUTH = "3f1baf71-de2c-4fef-ae38-facc4dd5fcc2"

# Endpoints (from generated/a09091/a09091-ui/config.js).
ACA_OBO = "https://a09091-aca-obo.purpleground-0b1004e3.polandcentral.azurecontainerapps.io"
ACA_S2S = "https://a09091-aca-s2s.mangobush-3324b337.polandcentral.azurecontainerapps.io"
FH_OBO = "https://cog-d4s4rg74gv74k.services.ai.azure.com/api/projects/a09091/agents/a09091-FH-OBO/endpoint/protocols/invocations?api-version=v1"
FH_S2S = "https://cog-d4s4rg74gv74k.services.ai.azure.com/api/projects/a09091/agents/a09091-FH-S2S/endpoint/protocols/openai/responses?api-version=v1"
FD_ENDPOINT = "https://cog-d4s4rg74gv74k.services.ai.azure.com/api/projects/a09091/openai/v1/responses"


def _load_cache():
    cache = msal.SerializableTokenCache()
    if os.path.exists(CACHE_FILE):
        cache.deserialize(open(CACHE_FILE, encoding="utf-8").read())
    return cache


def _save_cache(cache):
    if cache.has_state_changed:
        with open(CACHE_FILE, "w", encoding="utf-8") as f:
            f.write(cache.serialize())


def _app(cache):
    return msal.PublicClientApplication(CLIENT_ID, authority=AUTHORITY, token_cache=cache)


def login():
    cache = _load_cache()
    app = _app(cache)
    flow = app.initiate_device_flow(scopes=SC_MAIL)
    if "user_code" not in flow:
        raise RuntimeError("Failed to start device flow: " + json.dumps(flow))
    print("=== DEVICE CODE LOGIN (admin@diax88497452.onmicrosoft.com) ===", flush=True)
    print(flow["message"], flush=True)
    print("=== waiting for you to complete the sign-in in a browser ===", flush=True)
    result = app.acquire_token_by_device_flow(flow)  # blocks until completed / expires
    _save_cache(cache)
    if "access_token" in result:
        acct = app.get_accounts()
        who = acct[0]["username"] if acct else "?"
        print(f"LOGIN OK as {who}", flush=True)
    else:
        print("LOGIN FAILED: " + json.dumps(result), flush=True)
        sys.exit(1)


def ilogin():
    """Interactive browser sign-in (loopback). Opens the default browser; the user signs in."""
    cache = _load_cache()
    app = _app(cache)
    print("=== INTERACTIVE LOGIN (admin@diax88497452.onmicrosoft.com) ===", flush=True)
    print("A browser window is opening. Sign in as admin@diax88497452.onmicrosoft.com.", flush=True)
    result = app.acquire_token_interactive(
        scopes=SC_MAIL,
        login_hint="admin@diax88497452.onmicrosoft.com",
        prompt="select_account",
    )
    _save_cache(cache)
    if "access_token" in result:
        acct = app.get_accounts()
        who = acct[0]["username"] if acct else "?"
        print(f"LOGIN OK as {who}", flush=True)
    else:
        print("LOGIN FAILED: " + json.dumps(result), flush=True)
        sys.exit(1)


def _get_token(scopes):
    cache = _load_cache()
    app = _app(cache)
    accounts = app.get_accounts()
    if not accounts:
        raise RuntimeError("No cached account. Run: python agent_client.py login")
    result = app.acquire_token_silent(scopes, account=accounts[0])
    _save_cache(cache)
    if not result or "access_token" not in result:
        raise RuntimeError(f"Silent token failed for {scopes}: {json.dumps(result)}")
    return result["access_token"]


def whoami():
    cache = _load_cache()
    app = _app(cache)
    for a in app.get_accounts():
        print(a.get("username"), a.get("home_account_id"))


def _post(url, token, body):
    r = requests.post(
        url,
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
        json=body,
        timeout=180,
    )
    return r.status_code, r.text


def _responses_text(data):
    if isinstance(data.get("output_text"), str) and data["output_text"]:
        return data["output_text"]
    texts = []
    for item in data.get("output", []) or []:
        for c in item.get("content", []) or []:
            if isinstance(c.get("text"), str):
                texts.append(c["text"])
    return "\n".join(texts)


def send(target, message, want_mail=False, want_custom=False):
    result = {"target": target, "message": message}
    if target == "aca-obo":
        mail = _get_token(SC_MAIL)
        body = {"message": message, "history": []}
        tokens = {AUD_MAIL: mail}
        if want_custom:
            tokens[AUD_ANON] = _get_token(SC_ANON)
            tokens[AUD_AUTH] = _get_token(SC_AUTH)
        body["tokens"] = tokens
        st, txt = _post(ACA_OBO + "/chat", mail, body)
        result["status"] = st
        result["reply"] = _try(lambda: json.loads(txt).get("reply"), txt)
    elif target == "aca-s2s":
        tok = _get_token(SC_S2S)
        st, txt = _post(ACA_S2S + "/chat", tok, {"message": message, "history": []})
        result["status"] = st
        result["reply"] = _try(lambda: json.loads(txt).get("reply"), txt)
    elif target == "fh-obo":
        ep = _get_token(SC_FOUNDRY)
        body = {"message": message, "mail_token": _get_token(SC_MAIL)}
        if want_custom:
            body["tokens"] = {AUD_ANON: _get_token(SC_ANON), AUD_AUTH: _get_token(SC_AUTH)}
        sid = "obo-cli-" + uuid.uuid4().hex[:8]
        st, txt = _post(FH_OBO + "&agent_session_id=" + sid, ep, body)
        result["status"] = st
        result["reply"] = _try(lambda: (json.loads(txt).get("response") or json.loads(txt).get("reply")), txt)
    elif target == "fh-s2s":
        ep = _get_token(SC_FOUNDRY)
        st, txt = _post(FH_S2S, ep, {"input": message, "stream": False})
        result["status"] = st
        result["reply"] = _try(lambda: _responses_text(json.loads(txt)), txt)
    elif target in ("fd-obo", "fd-s2s"):
        ep = _get_token(SC_FOUNDRY)
        name = "a09091-FD-OBO" if target == "fd-obo" else "a09091-FD-S2S"
        body = {"input": message, "agent_reference": {"name": name, "type": "agent_reference"}}
        si = {}
        if target == "fd-obo":
            si["mail_token"] = "Bearer " + _get_token(SC_MAIL)
            # FD-OBO's definition wires all 3 MCP servers; Foundry lists ALL of them at request
            # time, so the custom tokens must always be supplied or the request 400s.
            si["anon_token"] = "Bearer " + _get_token(SC_ANON)
            si["auth_token"] = "Bearer " + _get_token(SC_AUTH)
        if si:
            body["structured_inputs"] = si
        st, txt = _post(FD_ENDPOINT, ep, body)
        result["status"] = st
        result["reply"] = _try(lambda: _responses_text(json.loads(txt)), txt)
        result["rawbody"] = txt[:2000]
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "last_fd_raw.json"), "w", encoding="utf-8") as f:
            f.write(txt)
    else:
        raise SystemExit("unknown target " + target)
    result["ok"] = 200 <= result.get("status", 0) < 300
    print(json.dumps(result, indent=2, ensure_ascii=False))


def _try(fn, fallback):
    try:
        v = fn()
        return v if v is not None else fallback
    except Exception:
        return fallback


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "whoami"
    if cmd == "login":
        login()
    elif cmd == "ilogin":
        ilogin()
    elif cmd == "whoami":
        whoami()
    elif cmd == "send":
        target = sys.argv[2]
        message = sys.argv[3]
        want_custom = "--custom" in sys.argv[4:]
        send(target, message, want_custom=want_custom)
    elif cmd == "batch":
        targets = sys.argv[2].split(",")
        message = sys.argv[3]
        want_custom = "--custom" in sys.argv[4:]
        for t in targets:
            print(f"\n===== {t} =====", flush=True)
            try:
                send(t.strip(), message, want_custom=want_custom)
            except Exception as e:
                print(json.dumps({"target": t, "ok": False, "error": str(e)}))
    else:
        print(__doc__)
