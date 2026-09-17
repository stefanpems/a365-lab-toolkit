#!/usr/bin/env python3
"""Prompts Sender — MCS (Copilot Studio) send path (prototype, no browser automation).

WHY A SEPARATE MODULE
  The base engine (send_prompts.py) targets the six SPA-callable OBO/S2S agents described in a web UI's
  `config.js` over plain HTTP. Copilot Studio (MCS-OH / MCS-NH) agents are NOT HTTP/SPA agents and are
  absent from `config.js`. They are reached over the Power Platform "Direct-to-Engine" API, which the
  Microsoft 365 Agents SDK wraps in its Copilot Studio client. This module adds that path WITHOUT any CDP
  / browser automation, reusing the same delegated-token model as the base engine (MSAL public client).

AUTH MODEL (documented, non-browser)
  - Delegated user token minted with MSAL against the TARGET tenant, scope
    `https://api.powerplatform.com/.default` (audience = Power Platform API).
  - The public-client app registration used to mint it must have the delegated permission
    Power Platform API -> Copilot Studio -> `Copilot Studio.Copilots.Invoke` (+ admin consent).
  - `login` performs a one-time interactive browser SIGN-IN (this is user auth, not page automation);
    tokens are cached and refreshed silently afterwards. `--user <upn>` selects a cached account.

AGENT ADDRESSING
  Each MCS agent is addressed by (environment_id, agent_identifier) where agent_identifier is the bot
  SCHEMA name (Copilot Studio -> Settings -> Advanced -> Metadata -> Schema name; e.g. an isolated
  `new_agentoh2_XXXX`). Alternatively a `directConnectUrl` (Channels -> Web app connection string) can be
  supplied and takes precedence.

MANIFEST (JSON) — the MCS analogue of config.js
  {
    "msal":   { "clientId": "<public-client-app-id>",
                "authority": "https://login.microsoftonline.com/<target-tenant-id>" },
    "scope":  "https://api.powerplatform.com/.default",
    "agents": [
      { "id": "mcs-oh", "name": "<lab>-MCS-OH", "harness": "OH",
        "environmentId": "<cs-env-guid>", "agentIdentifier": "<bot schema name>",
        "directConnectUrl": null, "tools": [] }
    ]
  }
  `tools` (optional) is an ALLOW-LIST of BYO tools the agent has wired ("mail" / "anon" / "auth").
  EMPTY (the discover default) means unrestricted: every requested category is sent and its real result
  recorded (the Lab Builder MCS-OH typology ships those tools, and this API can't reliably detect them).
  A NON-empty list restricts sending to the declared tools. Only the STANDARD harness (MCS-OH) is
  supported; NH agents are auto-skipped.

USAGE
  Build a manifest from a LIVE Copilot Studio env (needs `az login` into the target tenant):
    python send_prompts_mcs.py discover --env-id <guid> --env-url <orgUrl> --tenant <tid> \
        --client-id <appId-with-Copilots.Invoke> --name-filter MCS-OH --oh-only --out mcs.json

  Login once (per user, against the target tenant):
    python send_prompts_mcs.py login  --manifest <mcs.json> [--user <upn>]

  List agents / print the Direct-to-Engine URL (offline, proves the wiring without a token):
    python send_prompts_mcs.py agents --manifest <mcs.json>
    python send_prompts_mcs.py url    --manifest <mcs.json> --agents mcs-oh

  Send prompts (delegated token; --dry-run resolves the plan without any network call):
    python send_prompts_mcs.py send   --manifest <mcs.json> --agents mcs-oh --hello 1 \
        --out results.json [--user <upn>] [--dry-run]

Exit code of `send` is 0 only if every sent prompt passed the basic success check.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

# Reuse the base engine's prompt library + plan builder + basic check so the two paths stay consistent.
from send_prompts import (  # noqa: E402
    DEFAULT_CACHE,
    DEFAULT_LIBRARY,
    basic_success,
    build_plan,
    parse_library,
)

try:
    import msal  # noqa: E402
except ImportError:
    sys.stderr.write("Missing dep 'msal'. Install with: pip install -r requirements-mcs.txt\n")
    raise

DEFAULT_SCOPE = "https://api.powerplatform.com/.default"

# The Direct-to-Engine / Copilots.Invoke API serves the STANDARD harness only. A GitHub Copilot harness
# (MCS-NH) agent answers any prompt with this notice instead of a real reply — treat it as unsupported.
NH_UNSUPPORTED_MARKER = "doesn't support agents built with the github copilot harness"

# Map a prompt category to the tool an MCS agent must have wired for that category to be coherent.
# `hello` needs no tool. Mail / anon / auth are coherent only if the agent declares the tool in its
# manifest `tools` list (e.g. ["mail","anon","auth"]) — mirrors the base engine's S2S coherence guard.
TOOL_CATEGORY_KEY = {
    "MCP Mail access": "mail",
    "Custom MCP Anon access": "anon",
    "Custom MCP Auth access": "auth",
}


def _slug(name: str) -> str:
    import re

    return re.sub(r"[^a-z0-9]+", "-", (name or "").lower()).strip("-")


def category_supported_mcs(agent: dict, category: str) -> bool:
    """`hello` is always coherent. For a tool category, the agent's `tools` list is an ALLOW-LIST:
    an EMPTY list means unrestricted (the Lab Builder MCS-OH typology ships Mail + custom Anon/Auth,
    and this API can't reliably detect wired tools), so all requested categories are sent and their
    real result is recorded; a NON-empty list restricts to the declared tools (`"mail"/"anon"/"auth"`).
    """
    key = TOOL_CATEGORY_KEY.get(category)
    if key is None:
        return True
    tools = [str(t).lower() for t in (agent.get("tools") or [])]
    if not tools:
        return True
    return key in tools


# ----------------------------- manifest -----------------------------
def load_manifest(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
    cfg.setdefault("scope", DEFAULT_SCOPE)
    return cfg


def lab_prefix_from_manifest(cfg: dict) -> str:
    import re

    for a in cfg.get("agents", []):
        mm = re.match(r"([a-z0-9]+)-", a.get("name", ""))
        if mm:
            return mm.group(1)
    return ""


# ----------------------------- MSAL auth (same cache/pattern as the base engine) -----------------------------
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
    scope = [cfg["scope"]]
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


def get_token(cfg, cache_path, user):
    cache = _cache(cache_path)
    app = _app(cfg, cache)
    acct = _select_account(app, user)
    if not acct:
        raise RuntimeError(
            f"No cached account{f' for {user}' if user else ''}. Run: send_prompts_mcs.py login"
            + (f" --user {user}" if user else "")
        )
    res = app.acquire_token_silent([cfg["scope"]], account=acct)
    _save(cache, cache_path)
    if not res or "access_token" not in res:
        raise RuntimeError(f"Silent token failed for {cfg['scope']}: {json.dumps(res)}")
    return res["access_token"]


def _current_user(cfg, cache_path, user):
    try:
        app = _app(cfg, _cache(cache_path))
        acct = _select_account(app, user)
        return acct.get("username") if acct else None
    except Exception:
        return None

def _settings_for(agent: dict):
    from microsoft_agents.copilotstudio.client import AgentType, ConnectionSettings, PowerPlatformCloud

    return ConnectionSettings(
        environment_id=agent.get("environmentId"),
        agent_identifier=agent.get("agentIdentifier"),
        cloud=PowerPlatformCloud.PROD,
        copilot_agent_type=AgentType.PUBLISHED,
        direct_connect_url=agent.get("directConnectUrl") or None,
    )


def connection_url(agent: dict) -> str:
    """Resolve the Direct-to-Engine connection URL for an agent (offline; no token needed)."""
    from microsoft_agents.copilotstudio.client import (
        AgentType,
        PowerPlatformCloud,
        PowerPlatformEnvironment,
    )

    return PowerPlatformEnvironment.get_copilot_studio_connection_url(
        settings=_settings_for(agent),
        agent_type=AgentType.PUBLISHED,
        cloud=PowerPlatformCloud.PROD,
        direct_connect_url=agent.get("directConnectUrl") or None,
    )


def _is_message_text(act) -> str | None:
    if act is not None and getattr(act, "type", None) == "message" and getattr(act, "text", None):
        return act.text
    return None


async def _ask_once(agent: dict, token: str, message: str) -> dict:
    """Open a conversation, ask one question, and collect the agent's message text.

    The greeting text arrives on the start-conversation stream; the answer arrives on the ask stream.
    We keep both: the answer is authoritative, and the greeting is the fallback (a 'hello' smoke test is
    satisfied by the greeting even when the agent has no generative/topic answer for the free-form prompt).
    """
    from microsoft_agents.copilotstudio.client import CopilotClient

    client = CopilotClient(_settings_for(agent), token)

    conversation_id = None
    greeting: list[str] = []
    async for act in client.start_conversation(emit_start_conversation_event=True):
        if conversation_id is None and getattr(act, "conversation", None) is not None:
            conversation_id = act.conversation.id
        t = _is_message_text(act)
        if t:
            greeting.append(t)

    answer: list[str] = []
    async for act in client.ask_question(message, conversation_id):
        t = _is_message_text(act)
        if t:
            answer.append(t)

    reply_answer = "\n".join(answer).strip()
    reply_greeting = "\n".join(greeting).strip()
    reply = reply_answer or reply_greeting
    # greeting_only = the agent produced NO real answer and we fell back to the start-conversation
    # greeting. That satisfies a `hello` smoke test but NOT a tool/mail category (the tool never ran).
    greeting_only = (not reply_answer) and bool(reply_greeting)
    return {"status": 200 if reply else 502, "reply": reply or None, "raw": "",
            "greeting_only": greeting_only}


def send_to_mcs(agent: dict, token: str, message: str) -> dict:
    try:
        return asyncio.run(_ask_once(agent, token, message))
    except Exception as e:  # network / auth / protocol errors surface as an engine error entry
        return {"status": 0, "reply": f"ENGINE ERROR: {e}", "raw": ""}


# ----------------------------- orchestration -----------------------------
def run_agents(cfg):
    for a in cfg.get("agents", []):
        print(f"{a.get('id', '?'):10} | harness={a.get('harness', '?'):3} | "
              f"env={a.get('environmentId', '?')} | schema={a.get('agentIdentifier', '?')} | {a.get('name')}")
    return 0


def run_url(cfg, agents_arg):
    by_id = {a["id"]: a for a in cfg.get("agents", [])}
    for aid in [s.strip() for s in agents_arg.split(",") if s.strip()]:
        if aid not in by_id:
            sys.stderr.write(f"Unknown agent id: {aid}. Available: {list(by_id)}\n")
            return 2
        print(f"{aid}: {connection_url(by_id[aid])}")
    return 0


def run_send(args):
    cfg = load_manifest(args.manifest)
    prefix = lab_prefix_from_manifest(cfg)
    anon_server = args.anon_server or (f"ext_{prefix}Anon" if prefix else "{ANON_SERVER}")
    auth_server = args.auth_server or (f"ext_{prefix}Auth" if prefix else "{AUTH_SERVER}")
    lib = parse_library(args.library)

    by_id = {a["id"]: a for a in cfg.get("agents", [])}
    selected = [s.strip() for s in args.agents.split(",") if s.strip()]
    unknown = [s for s in selected if s not in by_id]
    if unknown:
        sys.stderr.write(f"Unknown agent id(s): {unknown}. Available: {list(by_id)}\n")
        return 2

    counts = {"hello": args.hello, "MCP Mail access": args.mail,
              "Custom MCP Anon access": args.anon, "Custom MCP Auth access": args.auth}
    plan = build_plan(lib, counts, anon_server, auth_server)

    token = None if args.dry_run else get_token(cfg, args.cache, args.user)

    results = []
    for agent_id in selected:
        agent = by_id[agent_id]
        for item in plan:
            if not category_supported_mcs(agent, item["type"]):
                entry = {"agent": agent_id, "agent_name": agent.get("name"), "type": item["type"],
                         "prompt": item["prompt"], "condition": item["condition"],
                         "status": None, "reply": None, "skipped": True,
                         "skip_reason": f"MCS agent has no '{TOOL_CATEGORY_KEY[item['type']]}' tool "
                                        "wired for this category",
                         "basic_pass": None}
                results.append(entry)
                print(f"[SKIP] {agent_id} <{item['type']}> :: no matching tool wired - not sent",
                      flush=True)
                continue
            if args.dry_run:
                out = {"status": None, "reply": "[dry-run: not sent]", "raw": ""}
                entry = {"agent": agent_id, "agent_name": agent.get("name"), "type": item["type"],
                         "prompt": item["prompt"], "condition": item["condition"],
                         "status": None, "reply": out["reply"], "skipped": False, "basic_pass": None}
                results.append(entry)
                print(f"[DRY] {agent_id} <{item['type']}> :: {item['prompt'][:60]}", flush=True)
                continue
            out = send_to_mcs(agent, token, item["prompt"])
            reply_l = (out.get("reply") or "").lower()
            if NH_UNSUPPORTED_MARKER in reply_l:
                entry = {"agent": agent_id, "agent_name": agent.get("name"), "type": item["type"],
                         "prompt": item["prompt"], "condition": item["condition"],
                         "status": out["status"], "reply": out["reply"], "skipped": True,
                         "skip_reason": "GitHub Copilot harness (MCS-NH) not supported by the "
                                        "Direct-to-Engine API; use the standard harness (MCS-OH)",
                         "basic_pass": None}
                results.append(entry)
                print(f"[SKIP] {agent_id} <{item['type']}> :: NH harness not supported by this API",
                      flush=True)
                continue
            entry = {"agent": agent_id, "agent_name": agent.get("name"), "type": item["type"],
                     "prompt": item["prompt"], "condition": item["condition"],
                     "status": out["status"], "reply": out["reply"], "skipped": False}
            entry["basic_pass"] = basic_success(entry)
            # A bare greeting (empty answer stream) does NOT satisfy a tool/mail category: the agent has
            # no such tool wired (or didn't invoke it), so record it as a failure rather than a false PASS.
            if item["type"] != "hello" and out.get("greeting_only"):
                entry["basic_pass"] = False
                entry["note"] = "greeting-only reply (tool not invoked / not wired)"
            results.append(entry)
            mark = "PASS" if entry["basic_pass"] else "FAIL"
            print(f"[{mark}] {agent_id} <{item['type']}> :: {item['prompt'][:60]} => "
                  f"HTTP {entry['status']} :: {str(entry['reply'])[:120]}", flush=True)

    sent = [r for r in results if r.get("basic_pass") is not None]
    summary = {
        "total": len(results),
        "sent": len(sent),
        "skipped": sum(1 for r in results if r.get("skipped")),
        "basic_pass": sum(1 for r in sent if r["basic_pass"]),
        "basic_fail": sum(1 for r in sent if not r["basic_pass"]),
        "user": None if args.dry_run else _current_user(cfg, args.cache, args.user),
        "results": results,
    }
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=2, ensure_ascii=False)
        print(f"Wrote {args.out}", flush=True)
    print(f"SUMMARY: {summary['basic_pass']}/{summary['sent']} sent passed the basic check; "
          f"{summary['skipped']} skipped.", flush=True)
    return 0 if summary["basic_fail"] == 0 else 1


def _infer_harness(name: str) -> str:
    n = (name or "").upper()
    if "MCS-NH" in n or n.endswith("-NH") or "-NH-" in n:
        return "NH"
    if "MCS-OH" in n or n.endswith("-OH") or "-OH-" in n:
        return "OH"
    return "?"


def run_discover(args):
    """Build an MCS manifest from a live Copilot Studio environment (Dataverse bots query, no browser).

    Uses an Azure CLI access token for the environment's org URL to read published bots, then writes a
    manifest ready for `login` / `send`. Requires `az login` into the TARGET tenant beforehand.
    """
    import subprocess

    import requests

    env_url = args.env_url.rstrip("/")
    tok = subprocess.run(
        ["az", "account", "get-access-token", "--resource", env_url, "--query", "accessToken", "-o", "tsv"],
        capture_output=True, text=True, shell=(os.name == "nt"),
    )
    if tok.returncode != 0 or not tok.stdout.strip():
        sys.stderr.write(f"az token failed for {env_url}: {tok.stderr.strip()}\n"
                         "Run 'az login' into the target tenant first.\n")
        return 2
    headers = {"Authorization": "Bearer " + tok.stdout.strip(), "Accept": "application/json"}
    r = requests.get(f"{env_url}/api/data/v9.2/bots?$select=name,schemaname,statecode", headers=headers,
                     timeout=60)
    if r.status_code >= 300:
        sys.stderr.write(f"Dataverse bots query failed: HTTP {r.status_code} {r.text[:300]}\n")
        return 2

    name_filter = (args.name_filter or "").lower()
    agents = []
    for b in r.json().get("value", []):
        name = b.get("name") or ""
        if b.get("statecode") != 0:  # only published/active bots
            continue
        if name_filter and name_filter not in name.lower():
            continue
        harness = _infer_harness(name)
        if args.oh_only and harness == "NH":
            continue
        agents.append({
            "id": _slug(name),
            "name": name,
            "harness": harness,
            "environmentId": args.env_id,
            "agentIdentifier": b.get("schemaname"),
            "directConnectUrl": None,
            "tools": [],
        })

    agents.sort(key=lambda a: a["id"])
    manifest = {
        "msal": {"clientId": args.client_id,
                 "authority": f"https://login.microsoftonline.com/{args.tenant}"},
        "scope": DEFAULT_SCOPE,
        "agents": agents,
    }
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
    print(f"Wrote {args.out} with {len(agents)} agent(s):", flush=True)
    for a in agents:
        print(f"  {a['id']:24} | harness={a['harness']:2} | schema={a['agentIdentifier']} | {a['name']}",
              flush=True)
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description="Prompts Sender — MCS (Copilot Studio) path")
    sub = p.add_subparsers(dest="cmd", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--manifest", required=True, help="Path to the MCS manifest JSON")
    common.add_argument("--cache", default=DEFAULT_CACHE, help="MSAL token cache file")
    common.add_argument("--user", default=None, help="UPN of the cached account to use")

    sub.add_parser("login", parents=[common])
    sub.add_parser("agents", parents=[common])

    pd = sub.add_parser("discover", help="Build a manifest from a live Copilot Studio environment")
    pd.add_argument("--env-id", required=True, help="Power Platform environment GUID (pac env list)")
    pd.add_argument("--env-url", required=True, help="Environment org URL (e.g. https://orgXXXX.crm.dynamics.com)")
    pd.add_argument("--tenant", required=True, help="Target tenant id")
    pd.add_argument("--client-id", required=True, help="Public-client app id with Copilots.Invoke consent")
    pd.add_argument("--name-filter", default=None, help="Only include bots whose name contains this substring")
    pd.add_argument("--oh-only", action="store_true", help="Exclude NH-harness bots (unsupported by this API)")
    pd.add_argument("--out", required=True, help="Write the manifest JSON to this path")

    pu = sub.add_parser("url", parents=[common])
    pu.add_argument("--agents", required=True, help="Comma-separated agent ids")

    ps = sub.add_parser("send", parents=[common])
    ps.add_argument("--agents", required=True, help="Comma-separated agent ids from the manifest")
    ps.add_argument("--hello", type=int, default=0)
    ps.add_argument("--mail", type=int, default=0)
    ps.add_argument("--anon", type=int, default=0)
    ps.add_argument("--auth", type=int, default=0)
    ps.add_argument("--anon-server", default=None)
    ps.add_argument("--auth-server", default=None)
    ps.add_argument("--library", default=DEFAULT_LIBRARY)
    ps.add_argument("--out", default=None, help="Write JSON results to this file")
    ps.add_argument("--dry-run", action="store_true", help="Resolve the plan without any network call")

    args = p.parse_args(argv)
    if args.cmd == "login":
        return login(load_manifest(args.manifest), args.cache, args.user)
    if args.cmd == "agents":
        return run_agents(load_manifest(args.manifest))
    if args.cmd == "discover":
        return run_discover(args)
    if args.cmd == "url":
        return run_url(load_manifest(args.manifest), args.agents)
    if args.cmd == "send":
        return run_send(args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
