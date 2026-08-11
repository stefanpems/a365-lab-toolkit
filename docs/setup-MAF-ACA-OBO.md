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

> **First run in a new tenant — admin consent is requested.** The `3c5eabff-…` app is a
> reference from the original lab and may **not** exist in your tenant. In that case
> `a365 setup requirements` fails with *"Client app not found in tenant"*. Register your own
> **public client** named `Agent 365 CLI` (fallback public client, redirect URIs
> `https://login.microsoftonline.com/common/oauth2/nativeclient` and `http://localhost`),
> create its service principal, and put its **Application (client) ID** in `clientAppId`.
>
> On the first authenticated command the CLI opens an interactive sign-in. A
> **"Permissions requested"** dialog appears (e.g. *Microsoft Graph Command Line Tools* and
> the Agent 365 CLI app): a **Global Administrator** must tick **"Consent on behalf of your
> organization"** and **Accept**. The CLI also adds the required Graph permissions to the
> client app and prints an `/adminconsent` URL — admin consent (AllPrincipals) on that app is
> **mandatory**, because a per-user grant is not sufficient and agents inherit no permissions
> without it.
>
> When you open the `/adminconsent` URL, the tenant-owned client shows a **"Review for your
> organization"** dialog with a *"This application is not published by Microsoft."* banner
> (expected — it is your own app, not a first-party one). The scopes listed are the Agent 365
> blueprint/registration/identity permissions plus `User.Read`. After **Accept**, the browser
> redirects to the native-client URI and lands on a Microsoft page reading **"This is not the
> right page / You have reached the wrong page. Please close this app or window and try
> again."** — this is the **expected, harmless** end of the consent redirect; consent has been
> recorded. Close the tab and re-run `a365 setup requirements` until it reports **0 failed**.

### 0.1 Register the tenant-owned client app (new tenant, once)

If `a365 setup requirements` reports *"Client app not found in tenant"*, create your own
public client and point all three ACA configs at it:

```powershell
# Create a tenant-owned "Agent 365 CLI" public client + its service principal
$app = az ad app create --display-name 'Agent 365 CLI' `
  --is-fallback-public-client true `
  --public-client-redirect-uris 'https://login.microsoftonline.com/common/oauth2/nativeclient' 'http://localhost' `
  --query appId -o tsv
az ad sp create --id $app | Out-Null
Write-Host "clientAppId = $app"
```

Put the printed `appId` in the `clientAppId` field of `aca/obo/a365.config.json`,
`aca/s2s/a365.config.json`, and `aca/dw/a365.config.json`. Leave the Microsoft first-party
resource IDs (Agent 365 Tools `ea9ffc3e-…`, etc.) unchanged — those are not lab tenant IDs.

> **These `a365.config.json` files are gitignored** (tenant-specific). Each ACA folder ships
> an `a365.config.json.example`; create your working copy from it, then fill in your values:
> `Copy-Item a365.config.json.example a365.config.json`.

### 0.2 Authenticate once, up front (avoid the WAM prompt storm)

This applies to the **ACA** variants only (they use the `a365` CLI). Foundry Hosted (FH) and
Foundry Declarative (FD) authenticate with `az login` / `azd auth login` instead and are not
affected.

`a365` signs in with the Windows **Web Account Manager (WAM)**. Two rules keep this smooth:

1. **Run `a365` in a real, external terminal window for the first sign-in — not the VS Code
   integrated terminal.** In an embedded terminal the WAM pop-up opens *behind* other windows,
   loses focus, and is auto-cancelled; MSAL then retries, producing a **repeating sequence of
   sign-in prompts**. A normal PowerShell/Windows Terminal window shows the pop-up in the
   foreground and completes cleanly.
2. **Never run more than one `a365 setup …` at a time.** Each process opens its **own** WAM
   window, so concurrent runs multiply the prompts. Wait for one command to finish before
   starting the next.

Do the one-time preventive sign-in in an external window, from **any one** of the ACA agent
folders you intend to deploy (`aca/obo`, `aca/s2s`, or `aca/dw` — they share the same tenant
and client app, so a single sign-in seeds the cache for all of them):

```powershell
# Replace <repo> with your clone path and <variant> with obo | s2s | dw
cd <repo>\aca\<variant>
a365 setup requirements
```

Complete the single WAM dialog. `a365` stores the token in a shared, DPAPI-encrypted MSAL
cache under `%LocalAppData%\Microsoft.Agents.A365.DevTools.Cli`, so **every subsequent `a365`
command — in any terminal, for any ACA variant — reuses it silently**. Re-run until it reports
**0 failed**.

> After the CLI adds the `wids` optional claim (first run), one more interactive sign-in is
> expected so the new token carries that claim; it is cached afterwards. If your host blocks
> WAM, the CLI falls back to **device code** (`https://login.microsoft.com/device` + a code).

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
