# Setup — MAF-ACA-OBO (Agent Framework, Azure Container Apps, On-Behalf-Of)

> Build a blueprint agent that runs on **Azure Container Apps** and acts **on behalf of the
> signed-in user** (OBO). Mail is sent from the **user's mailbox**. Reference implementation
> in the first experiment: **`AgentFrameworkSample`** (blueprint app id
> `4b6b6f57-a212-4d0d-bd71-e0fa484f9aad`).

See [00-introduction.md](00-introduction.md) for concepts. Replace all example
tenant/subscription/region/name values with your own.

---

## 0. Prerequisites

- **Azure CLI** — sign in to the **target tenant** and confirm the active context before any
  command: `az login --tenant <YOUR_ENTRA_TENANT_ID>` then
  `az account show --query "{tenant:tenantId,sub:id,user:user.name}"`. Contributor on the
  target subscription (Owner for some variants — see the checklist).

  > **Pin the subscription — mandatory.** On a managed/corporate machine the default `az`
  > context is frequently a **different** tenant/subscription (and can revert silently), so
  > you can create resources in the wrong place. The `az` context is **shared on-disk state**:
  > a **parallel shell/CLI session** (or `az account set` elsewhere) can flip it mid-deploy.
  > Set it explicitly and re-verify:
  > `az account set --subscription <YOUR_SUBSCRIPTION_ID>` → `az account show`. Pass
  > **`--subscription <YOUR_SUBSCRIPTION_ID>` on every `az` command** (`deploy-aca.ps1` resolves
  > the target once and passes `--subscription` on **every** underlying `az` call, so a concurrent
  > context flip can't hijack it), and pass `-Subscription`
  > to `deploy-aca.ps1` (and `deploy-aca-S2S.ps1` / `deploy-aca-DW.ps1`)
  > with the target subscription id (or set `$env:DEPLOY_SUB`).
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
`aca/s2s/a365.config.json`, and `aca/dw/a365.config.json`, and set `tenantId` to your target
tenant in each. Leave the Microsoft first-party resource IDs (Agent 365 Tools `ea9ffc3e-…`,
etc.) unchanged — those are not lab tenant IDs.

> **These `a365.config.json` files are gitignored** (tenant-specific). Each ACA folder ships
> an `a365.config.json.example`; create your working copy from it, then fill in your values:
> `Copy-Item a365.config.json.example a365.config.json`.

#### Instantiate the first-party service principals (new tenant, once)

A brand-new tenant usually has **no service principal** for the Microsoft first-party apps the
sample uses. Unlike the `Agent 365 CLI` public client (which you register yourself, above),
these are real multi-tenant Microsoft apps, so you only need to **instantiate** their SP with
`az ad sp create --id <appId>` (idempotent — skip any that already exist):

```powershell
# Agent 365 Tools (Mail MCP audience). Required for OBO/DW Mail.
az ad sp create --id ea9ffc3e-8a23-4a7d-836d-234d7c7565c1 2>$null
# Usually already present in M365 tenants (create only if missing):
az ad sp create --id 5a807f24-c9de-44ee-a3a7-329e88a00ffc 2>$null  # Messaging Bot API
az ad sp create --id 9b975845-388f-4429-889e-eab1ef63949c 2>$null  # Agent365Observability
```

> `az ad sp create --id 3c5eabff-…` (the lab's Agent 365 CLI) **fails** with *"does not
> reference a valid application object"* — that app is not instantiable in your tenant, which
> is exactly why you register your own public client in the step above.
>
> During the later `a365 setup all` step the CLI **auto-detects any still-missing resource
> SPs** (e.g. per-server MCP audiences) and prompts you per resource to create them; accept
> (it shells out to `az ad sp create`). If you run it non-interactively it prints the exact
> `az ad sp create` commands to run instead.

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

> **What to expect during the sequence (first run in a new tenant):**
>
> - **Several WAM sign-ins in a row**: if your Windows default account differs from the
>   target-tenant admin (e.g. a corporate machine account vs. the demo tenant admin), the
>   silent probe uses the Windows account, never matches, and **each internal Graph call
>   re-prompts**. In our lab a single `a365 setup requirements` needed **~13 completed
>   interactive sign-ins with 0 tokens served from cache** before reaching `0 failed`. Pick the
>   **target-tenant admin** in every dialog; the sequence is finite (one per internal Graph
>   call), not an infinite loop. Ignore the transient `User canceled authentication` lines
>   caused by a hidden/late window.
> - **How to avoid the storm (recommended):** run the whole `a365` procedure from a machine or
>   user whose **default Windows (WAM) account is the target-tenant admin** — then the silent
>   cache matches and later calls need no prompt. If that is not possible, either clear the
>   a365 sign-in cache (`%LocalAppData%\Microsoft.Agents.A365.DevTools.Cli`) so the CLI stops
>   requesting the mismatched account, or simply complete the finite sequence once. **Never run
>   two `a365 setup …` at the same time** — concurrent processes each open their own WAM window
>   and multiply the prompts.
> - A separate **"Microsoft Graph Command Line Tools — Permissions requested"** dialog appears
>   (it is the Graph PowerShell client the check uses). A **Global Administrator** must tick
>   **"Consent on behalf of your organization"** and **Accept**.
> - Immediately after, the CLI prints the app-registration changes it will apply to your
>   `Agent 365 CLI` client (add redirect URIs `http://localhost:8400/` and the WAM broker URI,
>   add the `wids` optional claim) and asks in the terminal:
>   **`Do you want to proceed? (y/N):`** — answer **`y`**. Without the `wids` claim the CLI
>   cannot detect the Global Administrator role and would skip the AllPrincipals OAuth2 grants.

## 1. Get the sources

```powershell
git clone https://github.com/<your-org>/a365-agent-lab.git
cd a365-agent-lab/aca/obo
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

> **Governed subscriptions — API-key auth may be disabled.** If an Azure Policy enforces
> `disableLocalAuth=true` on Cognitive Services, `az cognitiveservices account keys list`
> fails with *"disableLocalAuth is set to be true"* and the setting reverts even if you try to
> turn it off. In that case the key-based env above **cannot** be used: switch to **Entra ID
> auth** — assign the Container App's managed identity (or your dev identity for local tests)
> the **`Cognitive Services OpenAI User`** role on the Azure OpenAI account, and have the agent
> acquire an AAD token (`DefaultAzureCredential`) instead of a key. Pick an Azure OpenAI
> resource/subscription **without** that policy if you must use key auth unchanged.
>
> **How the agent wires Entra ID (important — agent-framework 1.0.0 detail).** In
> [`agent.py`](../aca/obo/agent.py) `_create_chat_client()`, when no API key is present the
> agent builds the underlying `openai.AsyncAzureOpenAI` client **itself**, passing an
> `azure_ad_token_provider` from
> `azure.identity.get_bearer_token_provider(DefaultAzureCredential(), "https://cognitiveservices.azure.com/.default")`,
> and hands it to `OpenAIChatCompletionClient(model=deployment, async_client=azure_client)`.
> Do **not** rely on passing `credential=DefaultAzureCredential()` to the agent-framework
> client: **agent-framework 1.0.0 silently ignores it** (the `credential`→token-provider
> wiring only exists in newer builds), so the client is created with no auth and the container
> crashes at startup with `openai.OpenAIError: Missing credentials`.

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

### 4.1 What `a365 setup all` does (first run — expect this exact flow)

Running `a365 setup all --m365 --agent-name "AgentFrameworkSample"` performs, in order:

1. **Requirements re-check** — a **Frontier** warning ("Tenant enrollment cannot be verified
   automatically") is normal for OBO/S2S; it must still end `… 0 failed`.
2. **Creates the blueprint app + service principal** and prints a summary with the
   **Blueprint ID** and **service principal ID**.
3. **Prints the blueprint client secret exactly once** — *"Copy this value now — it will not
   be shown again automatically."* Record it now (you pass it to `deploy-aca.ps1` later) and
   **do not commit it**; recover it with `a365 setup blueprint --show-secret` from the same
   folder/machine/user.
4. Possible warning: **"Could not add access_agent_as_user scope to blueprint. Add it
   manually: Entra portal > App registrations > Expose an API."** Not blocking for ACA-OBO;
   this scope is used by the **Web UI** for the S2S agent — add it later when wiring the SPA.
5. **Configures inheritable permissions** (Microsoft Graph, Agent 365 Tools, Messaging Bot
   API, Observability API, Power Platform API — `kind=allAllowed`).
6. **Application permission prompt**: *"Assign this application permission now? [y/N]"* for
   `Observability API: Agent365.Observability.OtelWrite` → answer **`y`**.
7. **Delegated admin consent (browser)**: an *"Allow agents created from this blueprint to
   access data?"* page (Mail MCP, read/write mail, send mail as you, chat, profiles, sites,
   files, channels…) → **Allow**. The CLI polls up to ~180s (*"Still waiting for admin
   consent…"*) then prints *"Consent granted (All permissions)."*
   - If the browser shows **"Try that again using a different browser — We couldn't connect
     to that service, likely because of settings put in place by your IT team"**, your
     default browser is blocked by Conditional Access: **open the same consent URL in a
     different browser** and Accept. Even if the tab shows an error after Accept, the CLI
     usually still detects the consent.
8. **Creates the agent identity** and **registers the agent** (prints their IDs).
9. **Messaging endpoint** prompt → **leave blank** (press Enter); it is a post-deploy artifact.
10. **Writes project settings**: creates/updates `aca/obo/.env` (stamps `TenantId`,
    `ServiceConnection`, `AgentBlueprint`, `Agent365Observability`) and
    `aca/obo/a365.generated.config.json` (blueprint ids + DPAPI-encrypted secret). Both are
    **gitignored**.

It ends with a **Setup Summary** (Prerequisites validated, Blueprint created, Inheritable
Permissions configured, Grants granted tenant-wide delegated, Agent identity created, Agent
registered, Messaging endpoint deferred, Project settings written) and **"Setup completed
successfully"**. **Next step:** register the messaging endpoint **after** the container deploy
with `a365 setup blueprint --endpoint-only --messaging-endpoint <https-url>` (see §7).

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
# The blueprint client secret is requested interactively (Read-Host), so it never lands in
# shell history. Pass the target subscription + Azure OpenAI resource as parameters:
.\deploy-aca.ps1 -Subscription '<TARGET_SUB_ID>' -AoaiRg '<AOAI_RG>' -AoaiAcc '<AOAI_ACCOUNT>'
```

> **Pass the target values as parameters — never commit tenant-specific ids.** `-Subscription`
> pins the **target subscription id** (so the deploy never runs against the wrong context; these
> three also read from env vars `DEPLOY_SUB` / `DEPLOY_AOAI_RG` / `DEPLOY_AOAI_ACC`). For
> **Entra ID auth** to Azure OpenAI (required when key auth is disabled — see §3), pass `-AoaiRg`
> and `-AoaiAcc` (your Azure OpenAI resource group and account name): the script then enables the
> Container App's **system-assigned managed identity** and grants it the
> **`Cognitive Services OpenAI User`** role on that account, and the agent authenticates with
> `DefaultAzureCredential` (leave `AZURE_OPENAI_API_KEY` empty). Omit `-AoaiRg`/`-AoaiAcc`
> only if you use key auth. If you prefer, pass `-ClientSecret '<cleartext>'` to skip the prompt.

> **Fast re-deploys — `-ReuseEnv`.** By default the script **deletes the whole resource group**
> and re-probes regions on every run; deleting an ACA **managed environment** takes **20–40 min**,
> so re-deploys are slow. Pass **`-ReuseEnv`** to **reuse the existing RG + environment** (no
> deletion, no region probe) and only rebuild/redeploy the Container App — much faster. It fails
> if the RG/environment don't exist yet, so use it only for the **2nd run onward**:
> `.\deploy-aca.ps1 -ReuseEnv -Subscription '<TARGET_SUB_ID>' -AoaiRg '<AOAI_RG>' -AoaiAcc '<AOAI_ACCOUNT>'`.

Required container env vars (**UPPERCASE** — Linux is case-sensitive):

```
HOST=0.0.0.0
PORT=3978
PYTHONUTF8=1
AZURE_OPENAI_ENDPOINT / AZURE_OPENAI_DEPLOYMENT / AZURE_OPENAI_API_VERSION
AZURE_OPENAI_API_KEY   # ONLY when key auth is used; OMITTED for Entra ID (see gotcha below)
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

> **Gotcha — never set `AZURE_OPENAI_API_KEY` to an empty string.** With Entra ID auth the key
> must be **absent**, not empty. `openai.AsyncAzureOpenAI` reads `AZURE_OPENAI_API_KEY` from the
> environment when no `api_key` is passed; a present-but-empty value (`""`) is treated as a
> real (invalid) key and the client raises `openai.OpenAIError: Missing credentials`, shadowing
> the managed-identity token provider. `deploy-aca.ps1` therefore adds `AZURE_OPENAI_API_KEY`
> to the container **only when `SECRET_AZURE_OPENAI_API_KEY` is non-empty**; and `agent.py`
> defensively removes an empty `AZURE_OPENAI_API_KEY` from the environment before creating the
> client. If you ever set this variable by hand, leave it **unset** for Entra ID.

> The `az acr build` **log stream** may crash with a cp1252 `UnicodeEncodeError` on Windows;
> this is harmless — the server-side build still succeeds (`az acr task list-runs`). Piping the
> command through `Select-Object` can **abort it before the image is pushed**; add `--no-logs`
> (and pipe through `Out-String -Stream`) if you need to trim the output.

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

> **Long-lived container — token refresh.** `setup_mcp_servers` rebuilds the MCP tools past a
> TTL (`MCP_TOKEN_TTL_SECONDS`, default 1800s) so the per-audience OAuth token baked into the
> tools' httpx client headers is re-acquired before it expires — otherwise an always-on replica
> eventually returns **HTTP 401** on every Mail/Work IQ call. See
> [setup-MAF-ACA-DW.md](setup-MAF-ACA-DW.md) §9 for the full diagnosis. Redeploy the image
> (`az acr build` + `az containerapp update --image`, no secret rotation) to pick up the fix.
