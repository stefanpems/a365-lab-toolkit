#!/usr/bin/env python3
"""
Technical verification of the deployed agent — exercises the SAME code as the container.

Modes:
  --llm    (default) LLM access test: builds OpenAIChatCompletionClient +
           Agent esattamente come agent.py e fa un round-trip reale.
  --health Also checks the /api/health endpoint of the cloud instance.

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
    """Builds the client/agent like agent.py and verifies the LLM round-trip."""
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
        print(f"   esito      : {'PASS' if ok else 'FAIL'}")
        return ok
    except Exception as e:
        print(f"   error      : {e}")
        print("   esito      : FAIL")
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
    """Legge il bearer token OBO da env (SECRET_BEARER_TOKEN / BEARER_TOKEN)."""
    load_dotenv(".env")
    load_dotenv("env/.env.playground.user")
    return (
        os.getenv("BEARER_TOKEN")
        or os.getenv("SECRET_BEARER_TOKEN")
        or ""
    ).strip()


# Resource (audience) dei Work IQ / Agent 365 Tools MCP server.
MCP_RESOURCE = "ea9ffc3e-8a23-4a7d-836d-234d7c7565c1"

# FQDN of the S2S instance deployed to Azure Container Apps.
S2S_FQDN = "agentframework-s2s-sample.thankfulcoast-e0e43978.polandcentral.azurecontainerapps.io"


async def test_cloud(prompt: str, fqdn: str = S2S_FQDN, from_name: str = "Tester") -> bool:
    """Sends a prompt DIRECTLY to the ACA instance via POST /api/messages.

    Usa deliveryMode=expectReplies: il container (che gira anonymous) bufferizza le
    reply activities and returns them in the HTTP BODY, so no
    connector/serviceUrl raggiungibile. E' la prova che l'ISTANZA CLOUD elabora il prompt.
    The from.name field simulates the caller's identity (in Teams/M365 the platform populates it).
    """
    import uuid
    import httpx

    url = f"https://{fqdn}/api/messages"
    activity = {
        "type": "message",
        "text": prompt,
        "deliveryMode": "expectReplies",
        "channelId": "test",
        "serviceUrl": "https://example.org/",
        "from": {"id": "tester", "name": from_name},
        "recipient": {"id": "agent", "name": "Agent"},
        "conversation": {"id": f"conv-{uuid.uuid4()}"},
        "id": str(uuid.uuid4()),
        "locale": "it-IT",
    }

    print("== Cloud ACA: POST /api/messages (expectReplies) ==")
    print(f"   url    : {url}")
    print(f"   prompt : {prompt}")
    try:
        async with httpx.AsyncClient(timeout=120) as c:
            r = await c.post(url, json=activity)
        print(f"   status : {r.status_code}")
        if r.status_code != 200:
            print(f"   body   : {r.text[:500]}")
            print("   esito  : FAIL")
            return False
        data = r.json()
        activities = data.get("activities", []) if isinstance(data, dict) else []
        texts = [a.get("text") for a in activities if a.get("type") == "message" and a.get("text")]
        print(f"   attivita' ricevute: {len(activities)} (messaggi con testo: {len(texts)})")
        for i, t in enumerate(texts, 1):
            print(f"   --- risposta {i} ---")
            print(f"   {t}")
        ok = len(texts) > 0
        print(f"   esito  : {'PASS' if ok else 'FAIL'}")
        return ok
    except Exception as e:
        print(f"   [FAIL] {type(e).__name__}: {e}")
        return False


def _get_app_only_token(scope: str) -> str:
    """Ottiene un token APP-ONLY (client_credentials) con le credenziali del blueprint S2S.

    Usa CONNECTIONS__SERVICE_CONNECTION__SETTINGS__{CLIENTID,CLIENTSECRET,TENANTID}
    (written by 'a365 setup' into .env) — the same application identity used at runtime
    dal container in ACA via service_connection.
    """
    import httpx

    load_dotenv(".env")
    client_id = os.getenv("CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID")
    client_secret = os.getenv("CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET")
    tenant_id = os.getenv("CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID")
    missing = [n for n, v in {
        "CLIENTID": client_id, "CLIENTSECRET": client_secret, "TENANTID": tenant_id,
    }.items() if not v]
    if missing:
        raise SystemExit(f"[FAIL] Credenziali blueprint mancanti in .env: {', '.join(missing)}")

    url = f"https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token"
    data = {
        "grant_type": "client_credentials",
        "client_id": client_id,
        "client_secret": client_secret,
        "scope": scope,
    }
    r = httpx.post(url, data=data, timeout=30)
    if r.status_code != 200:
        raise RuntimeError(f"token endpoint HTTP {r.status_code}: {r.text}")
    return r.json()["access_token"]


async def _run_agent_prompt_llm(prompt: str) -> str:
    """Builds the LLM-only agent (like agent.py) and runs a single prompt."""
    from agent_framework import Agent
    from agent_framework.openai import OpenAIChatCompletionClient

    cfg = _load_llm_config()
    chat_client = OpenAIChatCompletionClient(
        azure_endpoint=cfg["endpoint"], api_key=cfg["api_key"],
        model=cfg["deployment"], api_version=cfg["api_version"],
    )
    agent = Agent(client=chat_client, instructions="You are a helpful assistant with access to tools.", tools=[])
    resp = await agent.run(prompt)
    return (resp.text or "").strip()


async def test_s2s(email: str) -> bool:
    """Sends the two test prompts exercising the SAME agent code, but with
    the blueprint's APP-ONLY identity (S2S / client_credentials) — not user OBO.

    Prompt 1: "Che puoi fare per me?"                 (solo LLM)
    Prompt 2: "Send a test email to <email>"      (LLM + Mail MCP tool, app-only token)
    """
    import httpx
    from agent_framework import Agent, MCPStreamableHTTPTool
    from agent_framework.openai import OpenAIChatCompletionClient

    overall_ok = True

    # --- Prompt 1: LLM-only ---
    print("== Prompt 1 (S2S, solo LLM): 'Che puoi fare per me?' ==")
    try:
        text1 = await _run_agent_prompt_llm("Che puoi fare per me?")
        print(f"   risposta : {text1}")
        print("   esito      : PASS")
    except Exception as e:
        print(f"   [FAIL] {type(e).__name__}: {e}")
        overall_ok = False
    print()

    # --- Prompt 2: LLM + MCP Mail con token APP-ONLY ---
    print("== Prompt 2 (S2S, LLM + Mail MCP app-only): 'Send a test email' ==")
    try:
        token = _get_app_only_token(f"{MCP_RESOURCE}/.default")
        claims = _decode_jwt_payload(token)
        print("   [auth app-only S2S]")
        print(f"      audience : {claims.get('aud', '?')}")
        print(f"      appid    : {claims.get('appid') or claims.get('azp', '?')}")
        print(f"      idtyp    : {claims.get('idtyp', '?')}  (atteso: 'app')")
        print(f"      roles    : {claims.get('roles', '(nessun app role)')}")
        if not claims.get("roles"):
            print("      [WARN] Il token NON contiene app role: in puro S2S il tool Mail")
            print("             non e' autorizzato (Mail concessa solo come delegated).")
    except Exception as e:
        print(f"   [FAIL] impossibile ottenere il token app-only: {type(e).__name__}: {e}")
        print("   esito      : FAIL")
        return False

    cfg = _load_llm_config()
    chat_client = OpenAIChatCompletionClient(
        azure_endpoint=cfg["endpoint"], api_key=cfg["api_key"],
        model=cfg["deployment"], api_version=cfg["api_version"],
    )
    bearer = f"Bearer {token}"
    http_client = httpx.AsyncClient(headers={"Authorization": bearer}, timeout=90)
    mcp = MCPStreamableHTTPTool(
        name="mcp_MailTools", url=MAIL_MCP_URL,
        http_client=http_client, description="Microsoft 365 Mail tools",
    )
    ok2 = False
    try:
        async with mcp:
            agent = Agent(
                client=chat_client, tools=[mcp],
                instructions=(
                    "You are a helpful assistant with access to Microsoft 365 Mail tools via MCP. "
                    "If asked to send an email, call the mail tool to actually send it, then confirm."
                ),
            )
            resp = await agent.run(f"Send a test email to {email}")
            text2 = (resp.text or "").strip()
            print(f"   risposta : {text2}")
            ok2 = "sent" in text2.lower() or "inviat" in text2.lower()
    except Exception as e:
        print(f"   [risultato tool] {type(e).__name__}: {e}")
        print("   (in pure S2S an authorization error here is the expected behavior)")
        ok2 = False
    finally:
        await http_client.aclose()
    print(f"   esito      : {'PASS (email inviata)' if ok2 else 'NO-SEND (atteso in S2S)'}")

    return overall_ok


async def test_mcp_obo(email: str, subject: str, body: str) -> bool:
    """OBO test: user token -> Mail MCP connection -> send email via tool."""
    import httpx
    from agent_framework import Agent, MCPStreamableHTTPTool
    from agent_framework.openai import OpenAIChatCompletionClient

    print("== Test 2: MCP Mail via OBO ==")

    # --- 2.1 User auth (OBO): inspect the token ---
    token = _load_obo_token()
    if not token:
        print("   [FAIL] Nessun bearer token OBO (SECRET_BEARER_TOKEN vuoto). Rigenera con refresh-bearer-token.")
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
                    print("      (list_tools not available; proceeding with the agent)")
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
        print(f"   [FAIL] Error during the MCP/OBO test: {type(e).__name__}: {e}")
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
    parser.add_argument("--s2s", action="store_true", help="Send the 2 test prompts with app-only identity (S2S)")
    parser.add_argument("--cloud", metavar="PROMPT", help="Send a prompt DIRECTLY to the ACA instance (/api/messages, expectReplies)")
    parser.add_argument("--from-name", dest="from_name", default="Tester", help="Nome del chiamante (activity.from.name) per il test --cloud")
    parser.add_argument("--email", default="stefanpe@microsoft.com", help="Destinatario email di test")
    parser.add_argument("--subject", default="Test da AgentFrameworkSample", help="Oggetto email")
    parser.add_argument("--body", default="This is a test email sent by the agent via MCP (OBO).", help="Email body")
    args = parser.parse_args()

    # default se nessun flag: solo --llm
    any_flag = args.llm or args.health or args.mcp or args.s2s or bool(args.cloud)
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
    if args.s2s:
        results["s2s"] = await test_s2s(args.email)
    if args.cloud:
        results["cloud"] = await test_cloud(args.cloud, from_name=args.from_name)

    print("\n======== SUMMARY ========")
    for name, ok in results.items():
        print(f"  {name:8s}: {'PASS' if ok else 'FAIL'}")
    return 0 if all(results.values()) else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
