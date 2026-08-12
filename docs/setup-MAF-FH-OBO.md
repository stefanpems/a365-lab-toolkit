# Setup — MAF-FH-OBO (Agent Framework, Foundry Hosted, On-Behalf-Of, Invocations)

> Deploy a **Foundry Hosted Agent** that acts **on behalf of the signed-in user** using the
> **Invocations** protocol, consumed by a custom web UI. Mail is sent from the **user's
> mailbox**. Reference implementation: **`agentframeworkFH-OBO-agent`**.

See [00-introduction.md](00-introduction.md) for concepts. Example values from the lab:
tenant `863ee9e2-…`, subscription `d6116047-…`, region `eastus2`, model `gpt-4.1`.

---

## 0. Prerequisites & tooling

- **azd** (Azure Developer CLI) + the Foundry extension: `winget install Microsoft.Azd`,
  then `azd ext install microsoft.foundry`. Refresh PATH in the same shell after install.
- **Azure CLI**, **Node/npx** (for the SWA CLI), **Python 3.13+**.
- `azd auth login` (browser; token expires ~daily). `az login` and `azd auth login` are
  **separate** token stores. The **Foundry Project Manager** role is needed to deploy.

> **Target a specific tenant.** Sign both CLIs into the target tenant explicitly:
> `az login --tenant <YOUR_ENTRA_TENANT_ID>` and
> `azd auth login --tenant-id <YOUR_ENTRA_TENANT_ID>`. On a managed/corporate machine the `azd`
> **browser** login may hang or pick the wrong account; if so, use
> `azd auth login --tenant-id <YOUR_ENTRA_TENANT_ID> --use-device-code` and complete the code
> at `https://microsoft.com/devicelogin`. Verify with `azd auth login --check-status`.
>
> **Pin the subscription.** The default `az` context on a corporate machine is often a
> different subscription and can revert silently. Set it explicitly and verify before any
> provisioning: `az account set --subscription <YOUR_SUBSCRIPTION_ID>` → `az account show`;
> pin `azd` with `azd env set AZURE_SUBSCRIPTION_ID <YOUR_SUBSCRIPTION_ID>` and
> `azd env set AZURE_TENANT_ID <YOUR_ENTRA_TENANT_ID>`.

## 1. Get the sources

```powershell
git clone https://github.com/<your-org>/agent365-agentframework-samples.git
cd agent365-agentframework-samples/foundry-hosted/obo
```

Layout: `main.py` (host entry), `foundry_agent.py` (agent + Mail MCP tool),
`requirements.txt`, `azure.yaml`, `.env.template`, `ToolingManifest.json`.

## 2. Code shape (Invocations)

- `main.py`: `azure.ai.agentserver.invocations.InvocationAgentServerHost` with a custom
  `@app.invoke_handler` that reads `message` and `mail_token` (body) / the `Authorization`
  bearer and returns `{ "response": ... }`. OBO **requires** Invocations because it needs
  per-request access to the caller's token.
- `foundry_agent.py`: `run_obo_turn(message, mail_token)` builds a `FoundryChatClient` +
  `MCPStreamableHTTPTool(url=MAIL_MCP_URL, http_client=httpx.AsyncClient(headers={Authorization: "Bearer " + mail_token}))`,
  and runs the agent **inside `async with mail_tool:`**.
- Constants: `MAIL_MCP_URL = https://agent365.svc.cloud.microsoft/agents/servers/mcp_MailTools`,
  `MAIL_MCP_RESOURCE = ea9ffc3e-8a23-4a7d-836d-234d7c7565c1`.
- Read the model with a fallback: `os.environ.get("AZURE_AI_MODEL_DEPLOYMENT_NAME","gpt-4.1")`
  (the `env:` map is **not** injected by the current azd schema).

## 3. Dependencies (`requirements.txt`)

```
agent-framework-foundry
agent-framework-foundry-hosting>=1.0.0a260630
azure-identity
httpx>=0.24.0
python-dotenv
```

- **Do NOT** pin `agent-framework==1.0.0` (forces core 1.0.0, conflicts with
  foundry-hosting which needs core ≥ 1.11.0).
- **Do NOT** list `azure-ai-agentserver`/`starlette` — the `azure.ai.agentserver.invocations`
  namespace arrives transitively via `agent-framework-foundry-hosting`.

## 4. Init, provision, deploy

First authenticate `azd` to the **target tenant** and pin the subscription/tenant (separate from
`az login`; see §0):

```powershell
azd auth login --tenant-id <YOUR_ENTRA_TENANT_ID>
```

```powershell
azd ai agent init --src . --agent-name agentframeworkFH-OBO-agent `
  --deploy-mode code --runtime python_3_13 --entry-point main.py --protocol invocations --no-prompt
azd env set AZURE_SUBSCRIPTION_ID <YOUR_SUBSCRIPTION_ID>
azd env set AZURE_TENANT_ID <YOUR_ENTRA_TENANT_ID>
azd env set AZURE_RESOURCE_GROUP agentframeworkFH-OBO-rg
```

- **`--no-prompt` skips the interactive survey** (the `azd ai agent` extension, e.g.
  `v1.0.0-beta.5`, otherwise asks *"How do you want to initialize your agent?"* and *"How should
  dependencies be resolved?"*). With `--no-prompt` it uses the flags you passed plus the defaults:
  **initialize from the current directory** (thanks to `--src .`) and **remote build** (matching
  `dependencyResolution: remote_build` in `azure.yaml`). Omit `--no-prompt` only to review those
  prompts interactively — and never pick *"Start new from a template"*, which discards the
  sample's `main.py` / `foundry_agent.py`.
- **Fix `azure.yaml` protocol to `version: 2.0.0`** — init may generate a stale `1.0.0`.

```powershell
azd provision
```

- **`azd provision` asks *"Select location"*** (it sets `AZURE_LOCATION`). Pick a region that
  offers **`gpt-4.1` GlobalStandard** — **East US 2 (`eastus2`)** works (validated). You can also
  pre-set it non-interactively with `azd env set AZURE_LOCATION eastus2` before provisioning.
  Provisioning the Foundry project + account + connections takes a few minutes.

Deploy the model separately (the azd hosted-agent catalog may not offer gpt-4.1):

```powershell
az cognitiveservices account deployment create -g <RG> -n <ACCOUNT> `
  --deployment-name gpt-4.1 --model-name gpt-4.1 --model-version 2025-04-14 `
  --model-format OpenAI --sku-name GlobalStandard --sku-capacity 10
azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME gpt-4.1
azd deploy
```

Each `azd deploy` creates a new **agent version**; traffic routes to the latest. The output
gives the Playground URL and the **Invocations endpoint** (shape:
`https://<account>.services.ai.azure.com/api/projects/<project>/agents/<agent-name>/endpoint/protocols/invocations?api-version=v1`)
— copy it into the SPA `config.js` `obo-fh` entry (see [setup-web-ui.md](setup-web-ui.md) §5).

> **`azd deploy` → 403 Forbidden `…/AIServices/agents/read` (UserError).** Foundry agent
> create/read/write are **data-plane** actions; being subscription **Owner** is **not** enough
> (Owner grants control-plane `*` Actions, not the agent **DataActions**). Grant the **deploying
> identity** the **`Cognitive Services User`** role (dataActions `Microsoft.CognitiveServices/*`,
> which covers `AIServices/agents/*`) on the Foundry **account**, then re-run `azd deploy`
> (RBAC takes ~1–2 min to propagate):
>
> ```powershell
> $acct = az cognitiveservices account show -g <RG> -n <ACCOUNT> --query id -o tsv
> $me   = az ad signed-in-user show --query id -o tsv
> az role assignment create --assignee-object-id $me --assignee-principal-type User `
>   --role "Cognitive Services User" --scope $acct
> ```
>
> (In this tenant the classic *Azure AI User / Project Manager* roles are absent; `Cognitive
> Services User`'s wildcard is the reliable grant. The **web-UI users** who *call* the agent
> need the same role — or the narrower **`Foundry Agent Consumer`** — on the account.)

## 5. Observability

Foundry auto-injects `APPLICATIONINSIGHTS_CONNECTION_STRING`. For the A365 exporter, assign
the app role **`Agent365.Observability.OtelWrite`** (`8f71190c-00c8-461d-a63b-f74abde9ba52`) to
the **agent identity SP**, resource = the **`Agent365Observability`** SP
(objId, e.g. `4cc9c6a8-…`):

```powershell
az rest --method POST `
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/<AGENT_PRINCIPAL_ID>/appRoleAssignments" `
  --body '{ "principalId":"<AGENT_PRINCIPAL_ID>", "resourceId":"<Agent365Observability objId>", "appRoleId":"8f71190c-00c8-461d-a63b-f74abde9ba52" }'
```

The agent identity SP objId is the one named in the exporter's `403`. **Redeploy/restart** the
container afterward (its managed-identity token is cached from before the grant). Stream logs
with `azd ai agent monitor --session-id <id> --tail N`.

## 6. Custom web UI (SPA) — two tokens

The SPA calls the Invocations endpoint with:

- `Authorization: Bearer <token for https://ai.azure.com/.default>` — authenticates to the
  **Foundry gateway** (empirically: `https://ai.azure.com` is accepted; `cognitiveservices`
  → 403).
- body `mail_token = <token for McpServers.Mail.All>` — the delegated Mail token (OBO).

SPA config entry:

```js
{ id:"obo-fh", kind:"foundry-invocations", name:"…",
  endpoint:"https://<account>.services.ai.azure.com/api/projects/<project>/agents/agentframeworkFH-OBO-agent/endpoint/protocols/invocations?api-version=v1",
  endpointScope:"https://ai.azure.com/.default",
  mailScope:"ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/McpServers.Mail.All",
  sessionPrefix:"obo" }
```

Use a **per-user session id rotated per page load** (`obo-<oid>-<nonce>`) — Foundry sessions
are identity-bound (a shared id → `session_not_accessible 403`) and version-pinned (rotate so
each reload uses the latest version). Add a single **client-side retry on `status >= 500`**
(transient gateway 5xx). Run `node --check app.js` before every SWA deploy.

## 7. Entra consent (SPA app, AllPrincipals)

Admin-consent the SPA's delegated permissions tenant-wide so non-admins don't hit "Need admin
approval":

- Microsoft Graph `openid profile offline_access` (grant **AllPrincipals** explicitly)
- Azure Machine Learning Services `user_impersonation` (id `1a7925b5-…`, api
  `18a66f5f-dbdf-4c17-9dd7-1634712a9cbe`) → for `https://ai.azure.com/.default`
- Agent 365 Tools `McpServers.Mail.All`

```powershell
az ad app permission add --id <SPA_APPID> --api 18a66f5f-dbdf-4c17-9dd7-1634712a9cbe `
  --api-permissions 1a7925b5-f871-417a-9b8b-303f9f29fa10=Scope
az ad app permission admin-consent --id <SPA_APPID>
```

## 8. Azure RBAC (invocation authorization)

Beyond Entra consent, the Invocations gateway checks
`Microsoft.CognitiveServices/accounts/AIServices/agents/write`. Assign **Cognitive Services
User** (`a97b65f3-24c7-4388-baec-2e87135dc908`) on the **Foundry account** to an access
**group**, then add users:

```powershell
$gid = az ad group create --display-name "AgentFramework-OBO-Users" --mail-nickname "AgentFramework-OBO-Users" --query id -o tsv
az role assignment create --assignee-object-id $gid --assignee-principal-type Group `
  --role "Cognitive Services User" --scope <FOUNDRY_ACCOUNT_RESOURCE_ID>
az ad group member add --group $gid --member-id <USER_OBJID>
```

> Two independent gates: **Entra consent** (delegated scopes) **and** **Azure RBAC**
> (`agents/write`). Consent alone still returns 403. Group changes may require re-login.

## 9. Deploy the SPA & verify

```powershell
$tok = az staticwebapp secrets list --name <swa> -g <rg> --query "properties.apiKey" -o tsv
npx -y @azure/static-web-apps-cli deploy "<ui-folder>" --deployment-token $tok --env production
```

Verify: `azd ai agent invoke <agent> '{ "message": "hello" }'` for liveness; then send a mail
to an **internal** recipient from the SPA and confirm a real Exchange `messageId` in the
container logs (mail is sent from the user's mailbox). The Invocations handler is **stateless**
(no cross-turn memory) by design.
