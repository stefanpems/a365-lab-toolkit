#!/usr/bin/env python3
"""
Technical verification of the deployed agent — exercises the SAME code as the container.

Modes:
  --llm    (default) LLM access test: builds OpenAIChatCompletionClient +
           Agent exactly like agent.py and performs a real round-trip.
  --health Also checks the /api/health endpoint of the cloud instance.

Usage:
  .venv\\Scripts\\python.exe verify_deploy.py --llm
"""
import argparse
import asyncio
import base64
import json
import os
import sys
import warnings

warnings.filterwarnings("ignore")

from dotenv import load_dotenv

CLOUD_FQDN = os.getenv("ACA_CLOUD_FQDN", "<your-aca-app>.<env-suffix>.<region>.azurecontainerapps.io")
MAIL_MCP_URL = "https://agent365.svc.cloud.microsoft/agents/servers/mcp_MailTools"


def _load_llm_config() -> dict:
    """Resolve the Azure OpenAI config using the same names as the container.

    Tries .env first (created by the deploy task, AZURE_OPENAI_* names),
    then env/.env.playground.user (SECRET_/_NAME names) as a fallback.
    """
    load_dotenv(".env")
    load_dotenv("env/.env.playground.user")

    endpoint = os.getenv("AZURE_OPENAI_ENDPOINT")
    deployment = os.getenv("AZURE_OPENAI_DEPLOYMENT") or os.getenv("AZURE_OPENAI_DEPLOYMENT_NAME")
    api_version = os.getenv("AZURE_OPENAI_API_VERSION")
    api_key = os.getenv("AZURE_OPENAI_API_KEY") or os.getenv("SECRET_AZURE_OPENAI_API_KEY")

    missing = [n for n, v in {
        "AZURE_OPENAI_ENDPOINT": endpoint,
        "AZURE_OPENAI_DEPLOYMENT": deployment,
        "AZURE_OPENAI_API_VERSION": api_version,
        "AZURE_OPENAI_API_KEY": api_key,
    }.items() if not v]
    if missing:
        raise SystemExit(f"[FAIL] Config LLM mancante: {', '.join(missing)}")

    return {
        "endpoint": endpoint,
        "deployment": deployment,
        "api_version": api_version,
        "api_key": api_key,
    }


async def test_llm() -> bool:
    """Builds the client/agent like agent.py and verifies the LLM round-trip."""
    from agent_framework import Agent
    from agent_framework.openai import OpenAIChatCompletionClient

    cfg = _load_llm_config()
    print("== Test 1: LLM access (Azure OpenAI) ==")
    print(f"   endpoint   : {cfg['endpoint']}")
    print(f"   deployment : {cfg['deployment']}")
    print(f"   api_version: {cfg['api_version']}")

    # Stessa costruzione di agent.py::_create_chat_client (auth via API key)
    chat_client = OpenAIChatCompletionClient(
        azure_endpoint=cfg["endpoint"],
        api_key=cfg["api_key"],
        model=cfg["deployment"],
        api_version=cfg["api_version"],
    )
    # Stessa costruzione di agent.py::_create_agent
    agent = Agent(client=chat_client, instructions="You are a concise assistant.", tools=[])

    prompt = "Reply with exactly this token and nothing else: LLM-OK-42"
    print(f"   prompt     : {prompt}")
    resp = await agent.run(prompt)
    text = (resp.text or "").strip()
    print(f"   reply      : {text!r}")

    ok = "LLM-OK-42" in text
    print(f"   result     : {'PASS' if ok else 'FAIL'}")
    return ok


async def test_health() -> bool:
    """Checks /api/health of the cloud instance."""
    import httpx

    url = f"https://{CLOUD_FQDN}/api/health"
    print("== Test 0: cloud instance health ==")
    print(f"   url        : {url}")
    try:
        async with httpx.AsyncClient(timeout=25) as c:
            r = await c.get(url)
        ok = r.status_code == 200
        print(f"   status     : {r.status_code}")
        print(f"   body       : {r.text}")
        print(f"   result     : {'PASS' if ok else 'FAIL'}")
        return ok
    except Exception as e:
        print(f"   error      : {e}")
        print("   result     : FAIL")
        return False


def _decode_jwt_payload(token: str) -> dict:
    """Decodes (without verification) a JWT payload for inspection."""
    t = token.strip()
    if t.lower().startswith("bearer "):
        t = t[7:]
    parts = t.split(".")
    if len(parts) < 2:
        return {}
    payload = parts[1]
    payload += "=" * (-len(payload) % 4)  # padding base64url
    try:
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return {}


def _load_obo_token() -> str:
    """Read the OBO bearer token from env (SECRET_BEARER_TOKEN / BEARER_TOKEN)."""
    load_dotenv(".env")
    load_dotenv("env/.env.playground.user")
    return (
        os.getenv("BEARER_TOKEN")
        or os.getenv("SECRET_BEARER_TOKEN")
        or ""
    ).strip()


async def test_mcp_obo(email: str, subject: str, body: str) -> bool:
    """OBO test: user token -> Mail MCP connection -> send email via tool."""
    import httpx
    from agent_framework import Agent, MCPStreamableHTTPTool
    from agent_framework.openai import OpenAIChatCompletionClient

    print("== Test 2: MCP Mail via OBO ==")

    # --- 2.1 User auth (OBO): inspect the token ---
    token = _load_obo_token()
    if not token:
        print("   [FAIL] No OBO bearer token (SECRET_BEARER_TOKEN empty). Regenerate with refresh-bearer-token.")
        return False
    claims = _decode_jwt_payload(token)
    upn = claims.get("preferred_username") or claims.get("upn") or claims.get("unique_name") or "?"
    aud = claims.get("aud", "?")
    scp = claims.get("scp", "?")
    print("   [2.1 OBO user auth]")
    print(f"      user     : {upn}")
    print(f"      audience : {aud}")
    print(f"      scopes   : {scp}")
    if "McpServers.Mail" not in str(scp):
        print("      [WARN] The scope does not contain McpServers.Mail — the Mail tool may not be accessible.")

    # --- 2.2/2.3 MCP connection + agent + send email ---
    cfg = _load_llm_config()
    chat_client = OpenAIChatCompletionClient(
        azure_endpoint=cfg["endpoint"], api_key=cfg["api_key"],
        model=cfg["deployment"], api_version=cfg["api_version"],
    )
    bearer = token if token.lower().startswith("bearer ") else f"Bearer {token}"
    http_client = httpx.AsyncClient(headers={"Authorization": bearer}, timeout=90)

    mcp = MCPStreamableHTTPTool(
        name="mcp_MailTools",
        url=MAIL_MCP_URL,
        http_client=http_client,
        description="Microsoft 365 Mail tools",
    )

    instructions = (
        "You are an assistant with access to Microsoft 365 Mail tools via MCP. "
        "When asked to send an email, you MUST call the appropriate mail tool to actually send it. "
        "After sending, confirm succinctly with the tool result."
    )

    ok = False
    try:
        async with mcp:
            # 2.2 list tools
            print("   [2.2 OBO tool access]")
            try:
                tools = await mcp.list_tools() if hasattr(mcp, "list_tools") else None
                if tools:
                    names = [getattr(t, "name", str(t)) for t in tools]
                    print(f"      available tools: {names}")
                else:
                    print("      (list_tools not available; proceeding with the agent)")
            except Exception as le:
                print(f"      [WARN] list_tools: {le}")

            # 2.3 LLM + tool: send email
            print("   [2.3 LLM + tool: send email]")
            agent = Agent(client=chat_client, tools=[mcp], instructions=instructions)
            prompt = (
                f"Send an email to {email} with subject \"{subject}\" and body \"{body}\". "
                f"Use the mail tool to actually send it, then reply with 'EMAIL-SENT' followed by a short confirmation."
            )
            print(f"      prompt   : {prompt}")
            resp = await agent.run(prompt)
            text = (resp.text or "").strip()
            print(f"      reply    : {text}")
            ok = "EMAIL-SENT" in text.upper() or "sent" in text.lower()
    except Exception as e:
        print(f"   [FAIL] Error during the MCP/OBO test: {type(e).__name__}: {e}")
        ok = False
    finally:
        await http_client.aclose()

    print(f"   result     : {'PASS' if ok else 'FAIL'}")
    return ok


async def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--llm", action="store_true", help="LLM access test")
    parser.add_argument("--health", action="store_true", help="Cloud /api/health test")
    parser.add_argument("--mcp", action="store_true", help="MCP Mail via OBO test (send email)")
    parser.add_argument("--email", default="stefanpe@microsoft.com", help="Test email recipient")
    parser.add_argument("--subject", default="Test from AgentFrameworkSample", help="Email subject")
    parser.add_argument("--body", default="This is a test email sent by the agent via MCP (OBO).", help="Email body")
    args = parser.parse_args()

    # default if no flag: --llm only
    any_flag = args.llm or args.health or args.mcp
    run_llm = args.llm or not any_flag

    results = {}
    if args.health:
        results["health"] = await test_health()
        print()
    if run_llm:
        results["llm"] = await test_llm()
        print()
    if args.mcp:
        results["mcp"] = await test_mcp_obo(args.email, args.subject, args.body)

    print("\n======== SUMMARY ========")
    for name, ok in results.items():
        print(f"  {name:8s}: {'PASS' if ok else 'FAIL'}")
    return 0 if all(results.values()) else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
