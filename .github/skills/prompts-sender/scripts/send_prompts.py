#!/usr/bin/env python3
"""Prompts Sender engine — send prompts to the Lab Builder agents and collect responses.

Reusable, lab-agnostic core for the "Prompts Sender" agent. It reads the endpoints and MSAL client
from a lab's generated `ui/config.js`, authenticates as the signed-in user via MSAL (the same SPA
public client the web UI uses), picks random prompts from the prompt library, sends them to the
selected agents, and records each response together with its success condition.

AUTH MODEL
  - Delegated user tokens are minted with MSAL using the SPA client id from config.js. That client is
    tenant-admin-consented for Mail (McpServers.Mail.All), the S2S API (access_agent_as_user), Foundry
    (https://ai.azure.com) and the custom BYO tool scopes. Azure CLI CANNOT mint Mail/S2S/custom tokens
    (first-party preauth / missing consent), so MSAL via the SPA client is required.
  - `login` performs a one-time interactive browser sign-in; tokens are cached in a serializable cache
    file and refreshed silently afterwards.
  - MULTI-CONTEXT (v2-ready): the cache can hold multiple accounts; `--user <upn>` selects which cached
    account mints the tokens, so a future version can iterate several users in one run. Seeding a new
    user still needs one interactive sign-in for that user (no password ⇒ no headless ROPC).

USAGE
  Login once (per user):
    python send_prompts.py login  --config <path-to-config.js> [--user <upn>]

  Unattended send (inputs from the command line — for Windows Task Scheduler / GHCP CLI):
    python send_prompts.py send  --config <path-to-config.js> \
        --agents obo,obo-fh,obo-fd --hello 1 --mail 1 --anon 1 --auth 1 \
        --anon-server ext_a09091Anon --auth-server ext_a09091Auth \
        --out results.json [--user <upn>]

  List the agents available in a config:
    python send_prompts.py agents --config <path-to-config.js>

Exit code of `send` is 0 only if every sent prompt passed the basic success check.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import re
import sys
import uuid

try:
    import msal
    import requests
except ImportError:
    sys.stderr.write("Missing deps. Install with: pip install msal requests\n")
    raise

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_LIBRARY = os.path.join(HERE, "..", "references", "prompt-library.md")
DEFAULT_CACHE = os.path.join(HERE, "token_cache.json")

TYPE_KEYS = ["hello", "MCP Mail access", "Custom MCP Anon access", "Custom MCP Auth access"]


# ----------------------------- config.js parsing -----------------------------
def load_config(path: str) -> dict:
    text = open(path, encoding="utf-8").read()
    # Strip the JS wrapper: window.APP_CONFIG = { ... };
    m = re.search(r"window\.APP_CONFIG\s*=\s*(\{.*\})\s*;?\s*$", text, re.S)
    raw = m.group(1) if m else text
    return json.loads(raw)


def lab_prefix_from_config(cfg: dict) -> str:
    # Derive the lab prefix from an agent name like "a09091-ACA-OBO (...)".
    for a in cfg.get("agents", []):
        mm = re.match(r"([a-z0-9]+)-", a.get("name", ""))
        if mm:
            return mm.group(1)
    return ""


# ----------------------------- MSAL auth -----------------------------
def _cache(path):
    c = msal.SerializableTokenCache()
    if os.path.exists(path):
        c.deserialize(open(path, encoding="utf-8").read())
    return c


def _save(cache, path):
    if cache.has_state_changed:
        with open(path, "w", encoding="utf-8") as f:
            f.write(cache.serialize())


def _app(cfg, cache):
    return msal.PublicClientApplication(
        cfg["msal"]["clientId"], authority=cfg["msal"]["authority"], token_cache=cache
    )


def _select_account(app, user):
    accounts = app.get_accounts()
    if not accounts:
        return None
    if user:
        for a in accounts:
            if a.get("username", "").lower() == user.lower():
                return a
        return None
    return accounts[0]


def login(cfg, cache_path, user):
    cache = _cache(cache_path)
    app = _app(cfg, cache)
    # Any consented scope works to seed the account; Mail requires admin consent already granted.
    scope = [cfg["agents"][0].get("scope") or "https://ai.azure.com/.default"]
    print(f"Opening a browser for interactive sign-in{f' as {user}' if user else ''}...", flush=True)
    result = app.acquire_token_interactive(
        scopes=scope, login_hint=user or None, prompt="select_account"
    )
    _save(cache, cache_path)
    if "access_token" in result:
        who = _select_account(app, None)
        print("LOGIN OK as " + (who.get("username") if who else "?"), flush=True)
        return 0
    print("LOGIN FAILED: " + json.dumps(result), flush=True)
    return 1


def get_token(cfg, cache_path, user, scope):
    cache = _cache(cache_path)
    app = _app(cfg, cache)
    acct = _select_account(app, user)
    if not acct:
        raise RuntimeError(
            f"No cached account{f' for {user}' if user else ''}. Run: send_prompts.py login"
            + (f" --user {user}" if user else "")
        )
    res = app.acquire_token_silent([scope], account=acct)
    _save(cache, cache_path)
    if not res or "access_token" not in res:
        raise RuntimeError(f"Silent token failed for {scope}: {json.dumps(res)}")
    return res["access_token"]


# ----------------------------- sending -----------------------------
def _responses_text(data: dict) -> str:
    if isinstance(data.get("output_text"), str) and data["output_text"]:
        return data["output_text"]
    texts = []
    for item in data.get("output", []) or []:
        for c in item.get("content", []) or []:
            if isinstance(c.get("text"), str):
                texts.append(c["text"])
    return "\n".join(texts)


def send_to_agent(cfg, cache_path, user, agent: dict, message: str) -> dict:
    """Dispatch a message to one agent (by config.js kind). Returns {status, reply, raw}."""
    kind = agent.get("kind")
    gt = lambda scope: get_token(cfg, cache_path, user, scope)

    def post(url, token, body):
        r = requests.post(
            url,
            headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
            json=body,
            timeout=180,
        )
        return r.status_code, r.text

    if kind == "aca":
        # OBO uses a Mail-scope token as bearer + a per-audience token map; S2S uses its API scope.
        if agent.get("customScopes") or "Mail" in (agent.get("scope") or ""):
            bearer = gt(agent["scope"])
            tokens = {}
            mail_aud = (agent["scope"] or "").split("/")[0]
            tokens[mail_aud] = bearer
            for aud, sc in (agent.get("customScopes") or {}).items():
                tokens[aud] = gt(sc)
            body = {"message": message, "history": [], "tokens": tokens}
        else:
            bearer = gt(agent["scope"])
            body = {"message": message, "history": []}
        st, txt = post(agent["apiBase"].rstrip("/") + "/chat", bearer, body)
        reply = _try(lambda: json.loads(txt).get("reply"), txt)
        return {"status": st, "reply": reply, "raw": txt}

    if kind == "foundry-invocations":  # FH-OBO
        ep = gt(agent["endpointScope"])
        body = {"message": message}
        if agent.get("mailScope"):
            body["mail_token"] = gt(agent["mailScope"])
        if agent.get("customScopes"):
            body["tokens"] = {aud: gt(sc) for aud, sc in agent["customScopes"].items()}
        sid = (agent.get("sessionPrefix", "obo")) + "-" + uuid.uuid4().hex[:8]
        st, txt = post(agent["endpoint"] + "&agent_session_id=" + sid, ep, body)
        reply = _try(lambda: (json.loads(txt).get("response") or json.loads(txt).get("reply")), txt)
        return {"status": st, "reply": reply, "raw": txt}

    if kind == "foundry-responses":  # FH-S2S
        ep = gt(agent["endpointScope"])
        st, txt = post(agent["endpoint"], ep, {"input": message, "stream": False})
        reply = _try(lambda: _responses_text(json.loads(txt)), txt)
        return {"status": st, "reply": reply, "raw": txt}

    if kind == "foundry-prompt":  # FD-OBO / FD-S2S
        ep = gt(agent["endpointScope"])
        body = {"input": message, "agent_reference": {"name": agent["agentName"], "type": "agent_reference"}}
        si = {}
        if agent.get("mailScope"):
            si["mail_token"] = "Bearer " + gt(agent["mailScope"])
        for name, sc in (agent.get("customInputs") or {}).items():
            si[name] = "Bearer " + gt(sc)
        if si:
            body["structured_inputs"] = si
        st, txt = post(agent["endpoint"], ep, body)
        reply = _try(lambda: _responses_text(json.loads(txt)), txt)
        return {"status": st, "reply": reply, "raw": txt}

    raise ValueError(f"Unsupported agent kind: {kind}")


def _try(fn, fallback):
    try:
        v = fn()
        return v if v is not None else fallback
    except Exception:
        return fallback


# ----------------------------- prompt library -----------------------------
def parse_library(path: str) -> dict:
    lib = {k: [] for k in TYPE_KEYS}
    current = None
    for line in open(path, encoding="utf-8"):
        h = re.match(r"^##\s+(.*)$", line.strip())
        if h:
            name = h.group(1).strip()
            current = name if name in lib else None
            continue
        if current and line.strip().startswith("- "):
            item = line.strip()[2:].strip()
            # Split trailing "(condition)" — the prompt is everything before it.
            mm = re.match(r"^(.*)\(([^()]*)\)\s*$", item)
            if mm:
                prompt, cond = mm.group(1).strip(), mm.group(2).strip()
            else:
                prompt, cond = item, ""
            lib[current].append({"prompt": prompt, "condition": cond})
    return lib


def substitute(prompt: str, anon_server: str, auth_server: str) -> str:
    return prompt.replace("{ANON_SERVER}", anon_server).replace("{AUTH_SERVER}", auth_server)


def basic_success(entry: dict) -> bool:
    """Deterministic first-pass check. The Prompts Sender agent does the authoritative semantic check
    of `condition` against `reply`; this only flags obvious failures for unattended exit codes."""
    if not (200 <= entry.get("status", 0) < 300):
        return False
    reply = (entry.get("reply") or "").strip().lower()
    if not reply:
        return False
    bad = ["sorry, i encountered an error", "i couldn't process", "error retrieving tool list",
           "missing user token", "invalid token", "unauthorized"]
    return not any(b in reply for b in bad)


# ----------------------------- orchestration -----------------------------
def build_plan(lib, counts, anon_server, auth_server):
    """counts: {type: n}. Returns a flat list of {type, prompt, condition}."""
    plan = []
    for t, n in counts.items():
        pool = lib.get(t, [])
        if not pool or n <= 0:
            continue
        picks = [random.choice(pool) for _ in range(n)]  # random with replacement (pool may be < n)
        for p in picks:
            plan.append({
                "type": t,
                "prompt": substitute(p["prompt"], anon_server, auth_server),
                "condition": substitute(p["condition"], anon_server, auth_server),
            })
    return plan


def run_send(args):
    cfg = load_config(args.config)
    prefix = lab_prefix_from_config(cfg)
    anon_server = args.anon_server or (f"ext_{prefix}Anon" if prefix else "{ANON_SERVER}")
    auth_server = args.auth_server or (f"ext_{prefix}Auth" if prefix else "{AUTH_SERVER}")
    lib = parse_library(args.library)

    agents_by_id = {a["id"]: a for a in cfg["agents"]}
    selected = [s.strip() for s in args.agents.split(",") if s.strip()]
    unknown = [s for s in selected if s not in agents_by_id]
    if unknown:
        sys.stderr.write(f"Unknown agent id(s): {unknown}. Available: {list(agents_by_id)}\n")
        return 2

    counts = {"hello": args.hello, "MCP Mail access": args.mail,
              "Custom MCP Anon access": args.anon, "Custom MCP Auth access": args.auth}
    plan = build_plan(lib, counts, anon_server, auth_server)

    results = []
    for agent_id in selected:
        agent = agents_by_id[agent_id]
        for item in plan:
            try:
                out = send_to_agent(cfg, args.cache, args.user, agent, item["prompt"])
            except Exception as e:
                out = {"status": 0, "reply": f"ENGINE ERROR: {e}", "raw": ""}
            entry = {
                "agent": agent_id, "agent_name": agent.get("name"), "type": item["type"],
                "prompt": item["prompt"], "condition": item["condition"],
                "status": out["status"], "reply": out["reply"],
            }
            entry["basic_pass"] = basic_success(entry)
            results.append(entry)
            mark = "PASS" if entry["basic_pass"] else "FAIL"
            print(f"[{mark}] {agent_id} <{item['type']}> :: {item['prompt'][:60]} => "
                  f"HTTP {entry['status']} :: {str(entry['reply'])[:120]}", flush=True)

    summary = {
        "total": len(results),
        "basic_pass": sum(1 for r in results if r["basic_pass"]),
        "basic_fail": sum(1 for r in results if not r["basic_pass"]),
        "user": _current_user(cfg, args.cache, args.user),
        "results": results,
    }
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=2, ensure_ascii=False)
        print(f"Wrote {args.out}", flush=True)
    print(f"SUMMARY: {summary['basic_pass']}/{summary['total']} passed the basic check.", flush=True)
    return 0 if summary["basic_fail"] == 0 else 1


def _current_user(cfg, cache_path, user):
    try:
        cache = _cache(cache_path)
        app = _app(cfg, cache)
        acct = _select_account(app, user)
        return acct.get("username") if acct else None
    except Exception:
        return None


def run_agents(args):
    cfg = load_config(args.config)
    for a in cfg["agents"]:
        print(f"{a['id']:10} | kind={a.get('kind'):20} | {a.get('name')}")
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description="Prompts Sender engine")
    sub = p.add_subparsers(dest="cmd", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--config", required=True, help="Path to a lab's ui/config.js")
    common.add_argument("--cache", default=DEFAULT_CACHE, help="MSAL token cache file")
    common.add_argument("--user", default=None, help="UPN of the cached account to use (multi-context)")

    pl = sub.add_parser("login", parents=[common])
    sub.add_parser("agents", parents=[common])

    ps = sub.add_parser("send", parents=[common])
    ps.add_argument("--agents", required=True, help="Comma-separated agent ids from config.js")
    ps.add_argument("--hello", type=int, default=0)
    ps.add_argument("--mail", type=int, default=0)
    ps.add_argument("--anon", type=int, default=0)
    ps.add_argument("--auth", type=int, default=0)
    ps.add_argument("--anon-server", default=None)
    ps.add_argument("--auth-server", default=None)
    ps.add_argument("--library", default=DEFAULT_LIBRARY)
    ps.add_argument("--out", default=None, help="Write JSON results to this file")

    args = p.parse_args(argv)
    if args.cmd == "login":
        return login(load_config(args.config), args.cache, args.user)
    if args.cmd == "agents":
        return run_agents(args)
    if args.cmd == "send":
        return run_send(args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
