# Setup — MAF-ACA-OBO (Agent Framework, Azure Container Apps, On-Behalf-Of)

> Build a blueprint agent that runs on **Azure Container Apps** and acts **on behalf of the
> signed-in user** (OBO). Mail is sent from the **user's mailbox**. Reference implementation
> in the first experiment: **`AgentFrameworkSample`** (blueprint app id
> `4b6b6f57-a212-4d0d-bd71-e0fa484f9aad`).

See [00-introduction.md](00-introduction.md) for concepts. Replace all example
tenant/subscription/region/name values with your own.

---

## 0. Prerequisites

- **Azure CLI** (`az login`) with Contributor on a subscription.
- **Agent 365 CLI** (`a365`, ≥ v1.1.x) and **.NET** (its runtime).
- **Python 3.12+**, `uv` (`pip install uv`; ensure its Scripts dir is on PATH).
- Roles: **Global Administrator** (or *Agent ID Developer* + a Global Admin for consents).
- A **public client app** for local token acquisition (the "Agent 365 CLI" app,
  `3c5eabff-e557-4da1-a216-700d0d1e5bf7`) — used as `CLIENT_APP_ID`, **not** the agentic
  blueprint (an agentic app cannot mint a device-code/WAM user token → `AADSTS82006`).

## 1. Get the sources

```powershell
git clone https://github.com/<your-org>/agent365-agentframework-samples.git
cd agent365-agentframework-samples/aca/obo
uv venv ; .\.venv\Scripts\Activate.ps1 ; uv pip install -e .
```

## 2. Fix the Agent Framework dependencies (once)

The original sample targeted an old `agent-framework` API. Pin it and use the Chat
Completions client:

- `pyproject.toml`: pin `agent-framework==1.0.0` and `openai>=1.0.0`; **remove**
  `agent-framework-azure-ai` (its `AzureOpenAIChatClient` requires `BaseContextProvider`,
  removed in core ≥ 1.0.0, and is incompatible with the A365 tooling extension).
- `agent.py`: use `Agent(client=...)` (not `ChatAgent(chat_client=...)`) and
  **`OpenAIChatCompletionClient`** (from `agent_framework.openai`) — **not** `OpenAIChatClient`
  (Responses API → `400 API version not supported` on Azure OpenAI).

## 3. Configure the LLM (local test)

In `env/.env.playground.user` (gitignored):

```
AZURE_OPENAI_ENDPOINT=https://<your-aoai>.openai.azure.com/
AZURE_OPENAI_DEPLOYMENT_NAME=gpt-4o-mini
AZURE_OPENAI_API_VERSION=2024-12-01-preview
SECRET_AZURE_OPENAI_API_KEY=<key>
```

## 4. Create the blueprint + permissions

```powershell
a365 setup all --m365 --agent-name "AgentFrameworkSample"
a365 setup permissions mcp  --agent-name "AgentFrameworkSample"   # McpServers.Mail.All, McpServersMetadata.Read.All
a365 setup permissions bot  --agent-name "AgentFrameworkSample"   # Bot API + Observability + Power Platform
```

- `a365 setup all` creates the **agent identity**, registers the agent (appears in **All
  agents / Registry**), and defers the messaging endpoint.
- Each `permissions` step needs **admin consent** (browser); the observability app role
  (`Agent365.Observability.OtelWrite`) is granted via a `[y/N]` CLI prompt.
- Recover the client secret later with `a365 setup blueprint --show-secret` (in cleartext;
  the stored `agentBlueprintClientSecret` is DPAPI-encrypted and unusable in Linux).

## 5. (Optional) Local test in the Playground

Configure `CLIENT_APP_ID=3c5eabff-…` in `env/.env.playground`, run
`.vscode/scripts/refresh-bearer-token.ps1` to mint a delegated token, install the **Python
Debugger** extension, then **F5 → Debug in Microsoft 365 Agents Playground**.

## 6. Containerize & deploy to Azure Container Apps

`Dockerfile` (Python 3.12-slim) must set `ENV PYTHONUTF8=1` and `PYTHONIOENCODING=utf-8`
(the slim image uses C/ASCII locale and crashes on emoji `print()`), and start
`start_with_generic_host.py`. `host_agent_server.py` must bind
`host=os.environ.get("HOST","localhost")`.

Deploy with `deploy-aca.ps1` (auto-probes regions for ACA capacity — the lab landed on
`polandcentral`). It builds with `az acr build` and creates the Container App:

```powershell
.\deploy-aca.ps1 -ClientSecret '<blueprint client secret (cleartext)>'
```

Required container env vars (**UPPERCASE** — Linux is case-sensitive):

```
HOST=0.0.0.0
PORT=3978
PYTHONUTF8=1
AZURE_OPENAI_ENDPOINT / AZURE_OPENAI_DEPLOYMENT / AZURE_OPENAI_API_VERSION / AZURE_OPENAI_API_KEY
AUTH_HANDLER_NAME=AGENTIC
AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__TYPE=AgenticUserAuthorization
AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__SETTINGS__SCOPES=ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/.default
AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__SETTINGS__ALT_BLUEPRINT_NAME=SERVICE_CONNECTION
CONNECTIONSMAP__0__SERVICEURL=*
CONNECTIONSMAP__0__CONNECTION=SERVICE_CONNECTION
CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID=<blueprint app id>
CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET=secretref:blueprint-secret
CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID=<tenant>
ENABLE_A365_OBSERVABILITY_EXPORTER=true
```

Verify: `GET https://<fqdn>/api/health` → `{"status":"ok","agent_initialized":true}`.

> The `az acr build` **log stream** may crash with a cp1252 `UnicodeEncodeError` on Windows;
> this is harmless — the server-side build still succeeds (`az acr task list-runs`).

## 7. Register the messaging endpoint

```powershell
a365 setup blueprint --endpoint-only --agent-name "AgentFrameworkSample" `
  --messaging-endpoint "https://<fqdn>/api/messages"
```

`a365 publish` for a blueprint agent is a **no-op** ("Nothing to publish"); registration
already happened in step 4.

## 8. Tool Gateway (Work IQ) — OBO

- `ToolingManifest.json` already lists `mcp_MailTools` (audience
  `ea9ffc3e-8a23-4a7d-836d-234d7c7565c1`, scope `McpServers.Mail.All`).
- To add a **custom** MCP server: `a365 develop add-mcp-servers <name>` (populates the
  manifest with the server's own **V2 audience** + `Tools.ListInvoke.All`), then
  `a365 setup permissions mcp` + admin consent. The agentic path needs **no code change**;
  the `/chat` OBO path needs a second `MCPStreamableHTTPTool` with a token for the custom
  server's audience.

## 9. Custom web UI (`/chat`)

`host_agent_server.py` exposes a `POST /chat` (bypassing JWT, validating the user's Entra
token itself; `MAIL_TOKEN_MODE=direct` because agentic apps can't perform the OBO grant →
`AADSTS82002`) that calls `run_obo_mail_chat`. Wire it in the SPA (`ui/`) with:

```js
{ id:"obo", kind:"aca", name:"…", apiBase:"https://<fqdn>",
  scope:"ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/McpServers.Mail.All" }
```

## 10. Verify end-to-end

`verify_deploy.py` exercises the same code as the container:

```powershell
.venv\Scripts\python.exe verify_deploy.py --health --llm
powershell -File .\.vscode\scripts\refresh-bearer-token.ps1
$env:PYTHONUTF8=1 ; .venv\Scripts\python.exe verify_deploy.py --mcp --email <internal-recipient>
```

Expected: health `200`, LLM round-trip, and a **real email sent from the signed-in user's
mailbox** via the Mail MCP. Test with an **internal** recipient (external delivery from a
`.onmicrosoft.com` demo tenant can be blocked by anti-spam — not a code bug).
