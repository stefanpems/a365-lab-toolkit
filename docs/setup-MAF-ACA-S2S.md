# Setup — MAF-ACA-S2S (Agent Framework, Azure Container Apps, Service-to-Service)

> Build a blueprint agent that runs on **Azure Container Apps** and acts with its **own
> application identity** (app-only / `client_credentials`) — **not** on behalf of a user and
> **not** as an AI teammate. Reference implementation: **`AgentFrameworkS2SSample`**
> (blueprint app id `894f3b9c-aa7b-450d-b3c4-20bf5c931022`).

See [00-introduction.md](00-introduction.md) for concepts. This guide only highlights the
differences from [setup-MAF-ACA-OBO.md](setup-MAF-ACA-OBO.md); steps 0–3 and the
Dockerfile/UTF-8 details are identical.

---

## What S2S can and cannot do

- **Can**: run autonomous/daemon logic and reasoning; call any API/service on which the
  blueprint has been granted an **application permission (app role)** with admin consent;
  access tenant/app-level resources.
- **Cannot**: access a specific user's data without OBO; use delegated-only Work IQ tools
  (e.g. Mail) — pure S2S is rejected with `AADSTS82001`; it has no mailbox, calendar, files,
  Teams presence, and needs **no Frontier program / no user licenses**.

## 1. Get the sources

```powershell
git clone https://github.com/<your-org>/agent365-agentframework-samples.git
cd agent365-agentframework-samples/aca/s2s
uv venv ; .\.venv\Scripts\Activate.ps1 ; uv pip install -e .
```

## 2. Configure the blueprint for S2S

`a365.config.json`:

```json
{
  "tenantId": "<tenant>",
  "clientAppId": "<your tenant-owned 'Agent 365 CLI' public client app id>",
  "agentIdentityDisplayName": "AgentFrameworkS2SSample Identity",
  "agentBlueprintDisplayName": "AgentFrameworkS2SSample Blueprint",
  "agentDescription": "AgentFrameworkS2SSample",
  "aiTeammate": false,
  "useBlueprint": true,
  "authMode": "s2s"
}
```

> `clientAppId` is **your tenant-owned public client** (see [setup-MAF-ACA-OBO.md](setup-MAF-ACA-OBO.md)
> §0.1) — the lab id `3c5eabff-…` will not exist in a new tenant.

Reset `a365.generated.config.json` to `{}` to force a **new** blueprint.

## 3. Create the blueprint + permissions (S2S)

```powershell
a365 setup all --authmode s2s --m365
```

This creates the blueprint, configures inheritable permissions (Graph, Agent 365 Tools,
Messaging Bot API, Observability, Power Platform), assigns the **application app-role**
`Agent365.Observability.OtelWrite` (answer `y` to the `[y/N]` prompt), creates the agent
identity, and registers the agent. Record the blueprint app id, SP id, and client secret.

> The Frontier prerequisite check may warn — **irrelevant for S2S**.

## 4. Deploy to Azure Container Apps (app-only env vars)

Use `deploy-aca-S2S.ps1`. The container env vars **omit** the agentic auth block; keep only
the service connection (the blueprint's app-only credentials):

```
USE_AGENTIC_AUTH=false
CONNECTIONSMAP__0__SERVICEURL=*
CONNECTIONSMAP__0__CONNECTION=service_connection
CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID=<blueprint app id>
CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET=secretref:blueprint-secret
CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID=<tenant>
ENABLE_A365_OBSERVABILITY_EXPORTER=true
```

**No** `AUTH_HANDLER_NAME=AGENTIC` and **no** `...HANDLERS__AGENTIC__*` (those are for
OBO/DW). At runtime the host logs *"No auth handler configured"* — correct for S2S.

```powershell
.\deploy-aca-S2S.ps1 -ClientSecret '<secret>'
```

Verify health directly: `curl https://<fqdn>/api/health`.

## 5. Register the messaging endpoint

```powershell
a365 setup blueprint --endpoint-only --messaging-endpoint "https://<fqdn>/api/messages"
```

Registration already happened in step 3; `a365 publish` is a **no-op**. The agent appears in
**All agents / Registry** as a **Shared agent / API-based** (no Instances tab).

## 6. Degrade-to-LLM fix for pure S2S

The stock sample always calls `setup_mcp_servers`; in pure S2S the Work IQ MCP connection
fails (root cause `AADSTS82001`) and **blocks the turn** (client sees `503`). Apply the fix in
`agent.py` `setup_mcp_servers`: when there is **no agentic auth, no bearer token, and no auth
handler**, **skip MCP tools and run LLM-only** so the agent still replies. Rebuild + update
the Container App.

## 7. Tool Gateway (Work IQ) in S2S

Delegated-only tools (Mail) are **not** reachable in pure S2S. To make a service reachable:
grant the blueprint an **application app-role** on that resource + **admin consent** (and, for
app-only mail send, an **application access policy** authorizing a sender mailbox). Then add
the tool in code with an app-only token for the resource's audience.

## 8. Custom web UI (`/chat`)

The S2S `/chat` endpoint validates the caller's Entra token and answers via the LLM (no user
data). SPA entry:

```js
{ id:"s2s", kind:"aca", name:"…",
  apiBase:"https://<fqdn>",
  scope:"api://894f3b9c-aa7b-450d-b3c4-20bf5c931022/access_agent_as_user" }
```

## 9. Verify end-to-end

```powershell
curl https://<fqdn>/api/health
$env:PYTHONUTF8=1 ; .venv\Scripts\python.exe verify_deploy.py --s2s
```

Use `verify_deploy.py --cloud` (POST to `/api/messages` with `deliveryMode=expectReplies`) to
hit the real ACA instance and read the buffered reply. Expected: a normal LLM answer to a
generic prompt; a mail-send prompt returns **not authorized** (`AADSTS82001`) — the correct,
expected S2S behavior.
