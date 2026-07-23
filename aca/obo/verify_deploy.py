#!/usr/bin/env python3
"""
Verifica tecnica dell'agente deployato — esercita lo STESSO codice del container.

Modalità:
  --llm    (default) Test di accesso all'LLM: costruisce OpenAIChatCompletionClient +
           Agent esattamente come agent.py e fa un round-trip reale.
  --health Controlla anche l'endpoint /api/health dell'istanza cloud.

Uso:
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

CLOUD_FQDN = "agentframework-sample.icybush-c1787b58.polandcentral.azurecontainerapps.io"
MAIL_MCP_URL = "https://agent365.svc.cloud.microsoft/agents/servers/mcp_MailTools"


def _load_llm_config() -> dict:
    """Risolve la config Azure OpenAI con gli stessi nomi usati dal container.

    Prova prima .env (creato dal deploy task, nomi AZURE_OPENAI_*),
    poi env/.env.playground.user (nomi SECRET_/_NAME) come fallback.
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
    """Costruisce il client/agent come agent.py e verifica il round-trip LLM."""
    from agent_framework import Agent
    from agent_framework.openai import OpenAIChatCompletionClient

    cfg = _load_llm_config()
    print("== Test 1: accesso LLM (Azure OpenAI) ==")
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
    print(f"   risposta   : {text!r}")

    ok = "LLM-OK-42" in text
    print(f"   esito      : {'PASS' if ok else 'FAIL'}")
    return ok


async def test_health() -> bool:
    """Verifica /api/health dell'istanza cloud."""
    import httpx

    url = f"https://{CLOUD_FQDN}/api/health"
    print("== Test 0: health dell'istanza cloud ==")
    print(f"   url        : {url}")
    try:
        async with httpx.AsyncClient(timeout=25) as c:
            r = await c.get(url)
        ok = r.status_code == 200
        print(f"   status     : {r.status_code}")
        print(f"   body       : {r.text}")
        print(f"   esito      : {'PASS' if ok else 'FAIL'}")
        return ok
    except Exception as e:
        print(f"   errore     : {e}")
        print("   esito      : FAIL")
        return False


def _decode_jwt_payload(token: str) -> dict:
    """Decodifica (senza verifica) il payload di un JWT per ispezione."""
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
    """Legge il bearer token OBO da env (SECRET_BEARER_TOKEN / BEARER_TOKEN)."""
    load_dotenv(".env")
    load_dotenv("env/.env.playground.user")
    return (
        os.getenv("BEARER_TOKEN")
        or os.getenv("SECRET_BEARER_TOKEN")
        or ""
    ).strip()


async def test_mcp_obo(email: str, subject: str, body: str) -> bool:
    """Test OBO: token utente -> connessione Mail MCP -> invio email via tool."""
    import httpx
    from agent_framework import Agent, MCPStreamableHTTPTool
    from agent_framework.openai import OpenAIChatCompletionClient

    print("== Test 2: MCP Mail via OBO ==")

    # --- 2.1 Auth utente (OBO): ispeziona il token ---
    token = _load_obo_token()
    if not token:
        print("   [FAIL] Nessun bearer token OBO (SECRET_BEARER_TOKEN vuoto). Rigenera con refresh-bearer-token.")
        return False
    claims = _decode_jwt_payload(token)
    upn = claims.get("preferred_username") or claims.get("upn") or claims.get("unique_name") or "?"
    aud = claims.get("aud", "?")
    scp = claims.get("scp", "?")
    print("   [2.1 auth utente OBO]")
    print(f"      utente   : {upn}")
    print(f"      audience : {aud}")
    print(f"      scopes   : {scp}")
    if "McpServers.Mail" not in str(scp):
        print("      [WARN] Lo scope non contiene McpServers.Mail — il tool Mail potrebbe non essere accessibile.")

    # --- 2.2/2.3 Connessione MCP + agente + invio email ---
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
            print("   [2.2 accesso tool OBO]")
            try:
                tools = await mcp.list_tools() if hasattr(mcp, "list_tools") else None
                if tools:
                    names = [getattr(t, "name", str(t)) for t in tools]
                    print(f"      tool disponibili: {names}")
                else:
                    print("      (list_tools non disponibile; procedo con l'agente)")
            except Exception as le:
                print(f"      [WARN] list_tools: {le}")

            # 2.3 LLM + tool: invio email
            print("   [2.3 LLM + tool: invio email]")
            agent = Agent(client=chat_client, tools=[mcp], instructions=instructions)
            prompt = (
                f"Send an email to {email} with subject \"{subject}\" and body \"{body}\". "
                f"Use the mail tool to actually send it, then reply with 'EMAIL-SENT' followed by a short confirmation."
            )
            print(f"      prompt   : {prompt}")
            resp = await agent.run(prompt)
            text = (resp.text or "").strip()
            print(f"      risposta : {text}")
            ok = "EMAIL-SENT" in text.upper() or "sent" in text.lower()
    except Exception as e:
        print(f"   [FAIL] Errore durante il test MCP/OBO: {type(e).__name__}: {e}")
        ok = False
    finally:
        await http_client.aclose()

    print(f"   esito      : {'PASS' if ok else 'FAIL'}")
    return ok


async def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--llm", action="store_true", help="Test accesso LLM")
    parser.add_argument("--health", action="store_true", help="Test /api/health cloud")
    parser.add_argument("--mcp", action="store_true", help="Test MCP Mail via OBO (invio email)")
    parser.add_argument("--email", default="stefanpe@microsoft.com", help="Destinatario email di test")
    parser.add_argument("--subject", default="Test da AgentFrameworkSample", help="Oggetto email")
    parser.add_argument("--body", default="Questa e' un'email di test inviata dall'agente via MCP (OBO).", help="Corpo email")
    args = parser.parse_args()

    # default se nessun flag: solo --llm
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

    print("\n======== RIEPILOGO ========")
    for name, ok in results.items():
        print(f"  {name:8s}: {'PASS' if ok else 'FAIL'}")
    return 0 if all(results.values()) else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
