# Setup — MAF-ACA-S2S (Agent Framework, Azure Container Apps, Service-to-Service)

> Build a blueprint agent that runs on **Azure Container Apps** and acts with its **own
> application identity** (app-only / `client_credentials`) — **not** on behalf of a user and
> **not** as an AI teammate. Reference implementation: **`AgentFrameworkS2SSample`**
> (blueprint app id `<ACA_S2S_BLUEPRINT_APP_ID>`).

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
git clone https://github.com/<your-org>/a365-lab-toolkit.git
cd a365-lab-toolkit/aca/s2s
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

> ### ⚠️ Expect a very long manual authentication sequence
> On a machine where the **Windows default (WAM) account is NOT the tenant admin** you are
> onboarding (e.g. a corporate laptop signed in as `you@corp.com` while the target admin is
> `admin@contoso.onmicrosoft.com`), `a365 setup all` prints **`Authenticating via Windows
> Account Manager…` before almost every directory call and each one pops an interactive
> sign-in**. In this lab run the single `a365 setup all --authmode s2s --m365` triggered
> **~12–13 WAM authentications** (matching the ~13 seen for the OBO `a365 setup requirements`)
> **plus 1 interactive browser admin-consent** — one per phase below:
>
> 1. initial context, 2. requirements check, 3. "verifying consent for blueprint operations",
> 4–6. creating the blueprint application (Graph sign-in → authenticated → current user),
> 7. creating the blueprint service principal, 8. creating the blueprint client secret,
> 9. creating the agent identity, 10. registering the agent — **plus** the delegated
> **admin-consent page** in the browser.
>
> **How to avoid the storm:** run on a machine/profile whose **default Windows/WAM account IS
> the target-tenant admin** (then MSAL silently reuses the cached token and the prompts
> collapse to one or two). Otherwise, just power through — it is finite, not a loop. **Never**
> launch a second `a365 setup …` in parallel (each opens its own WAM window → unmanageable).

This creates the blueprint, configures inheritable permissions (Graph, Agent 365 Tools,
Messaging Bot API, Observability, Power Platform), then prompts twice with `[y/N]` (answer
**`y`** to both): once to **assign the application app-role** `Agent365.Observability.OtelWrite`,
and once to **add the delegated permissions** to the blueprint. It then creates the agent
identity and registers the agent. **Record the printed Blueprint ID, service-principal ID,
agent-identity ID and the client secret** (shown once — recover later with
`a365 setup blueprint --show-secret`).

> The Frontier prerequisite check may warn — **irrelevant for S2S**.

### 3.1 Two failures you will likely hit (and how to fix them)

The CLI can create the blueprint/identity/registration but **still finish with "Setup
completed — action required before proceeding"**. Two steps commonly do not complete
automatically:

1. **Delegated admin consent "not detected" — usually a *cosmetic* error, the consent IS
   granted.** The browser opens the *"Allow agents created from this blueprint to access
   data?"* page; after **Allow** it redirects to **entra.microsoft.com/TokenAuthorize** which
   often shows **"Try that again using a different browser — We couldn't connect to that
   service, likely because of settings put in place by your IT team."** This is **Conditional
   Access** blocking the *redirect target* (`entra.microsoft.com`), **not** the consent itself:
   the redirect URL contains **`admin_consent=True`**, i.e. **the grant was already recorded
   when you clicked Allow**. The CLI only reports *"Consent was not detected"* because it never
   received the redirect back. **Do NOT keep retrying in different browsers** — instead
   **verify** the grants directly (run as a target-tenant admin; remember `az ad`/Graph ignore
   `--subscription`, so re-pin and re-check `az ad signed-in-user`):

   ```powershell
   $blueprintSpId = '<blueprint service principal id>'   # printed by a365 setup
   az rest --method GET --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$blueprintSpId'" `
     --query "value[].{resourceId:resourceId, consentType:consentType, scope:scope}" -o json
   ```

   If you see `AllPrincipals` grants for Microsoft Graph (Mail/Chat/Sites/Files/Channel),
   Agent 365 Tools (`McpServers.Mail.All`), Messaging Bot API (`AgentData.ReadWrite`),
   Observability (`Agent365.Observability.OtelWrite`) and Power Platform — **consent is done**;
   ignore the browser error. (Only if the grants are genuinely missing, open the admin-consent
   URL from the Summary in a browser that is NOT blocked by Conditional Access.)

2. **S2S Observability app-role not assigned.** `Assigning S2S app roles…` fails with
   `Request_ResourceNotFound` (the just-created SP has not propagated / needs
   *Application Administrator*). The Summary prints a `Connect-MgGraph` remediation, but the
   fastest fix is a single `az rest` call as a tenant admin (no Graph PowerShell module needed):

   ```powershell
   $agentSp = '<agent identity SP id>'                    # printed by a365 setup
   $obsSp   = az ad sp show --id '9b975845-388f-4429-889e-eab1ef63949c' --query id -o tsv   # Observability API SP
   $roleId  = az rest --method GET --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$obsSp" --query "appRoles[?value=='Agent365.Observability.OtelWrite'].id | [0]" -o tsv
   $body = @{ principalId = $agentSp; resourceId = $obsSp; appRoleId = $roleId } | ConvertTo-Json
   $tmp = New-TemporaryFile; $body | Set-Content $tmp -Encoding utf8
   az rest --method POST --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$agentSp/appRoleAssignments" --headers "Content-Type=application/json" --body "@$tmp"
   Remove-Item $tmp
   ```

> **These two are not blocking for the ACA-S2S `/chat` web-UI test.** A pure S2S agent replies
> with the LLM using its **own** identity (Azure OpenAI via managed identity) and does **not**
> use the delegated Mail permissions or the Observability telemetry, so the container runs and
> answers even before you complete them. Complete them anyway for a correct, telemetry-enabled
> blueprint.

### 3.2 Messaging endpoint — leave it blank

At *"Messaging endpoint URL:"* press **Enter** (leave blank). It is a **post-deploy** artifact:
register it after §4 with
`a365 setup blueprint --endpoint-only --messaging-endpoint "https://<fqdn>/api/messages"`.
The Summary correctly lists it as **"Messaging endpoint deferred"**.

`a365 setup all` writes `aca/s2s/.env` and `aca/s2s/a365.generated.config.json` (both
**gitignored**) — these are what `deploy-aca-S2S.ps1` reads in §4.


## 4. Deploy to Azure Container Apps (app-only env vars)

> **Prerequisite — create `aca/s2s/env/.env.playground.user`** (gitignored) with the Azure
> OpenAI config **before** deploying; `deploy-aca-S2S.ps1` reads it for the LLM env vars. Same
> shape as the OBO agent (leave the key **empty** for Entra ID auth):
>
> ```
> AZURE_OPENAI_ENDPOINT=https://<your-aoai>.openai.azure.com/
> AZURE_OPENAI_DEPLOYMENT_NAME=gpt-4.1-mini
> AZURE_OPENAI_API_VERSION=2024-12-01-preview
> SECRET_AZURE_OPENAI_API_KEY=
> ```
>
> Missing this file makes the deploy fail at `Get-Content env/.env.playground.user` (*"Cannot
> find path …"*). Note this is **separate** from the `aca/s2s/.env` that `a365 setup` writes.

> **`az acr build` can crash the deploy with a cp1252 `UnicodeEncodeError`** (colorama log
> stream on Windows). `deploy-aca-S2S.ps1` builds with **`--no-logs`** to avoid it (the build
> still runs server-side). If you build manually, add `--no-logs` too.

Use `deploy-aca-S2S.ps1` (pass the target subscription + Azure OpenAI resource for the
managed-identity role, like the OBO deploy; the blueprint secret is requested interactively):

```powershell
cd aca/s2s
.\deploy-aca-S2S.ps1 -Subscription '<TARGET_SUB_ID>' -AoaiRg '<AOAI_RG>' -AoaiAcc '<AOAI_ACCOUNT>'
```

The container env vars **omit** the agentic auth block; keep only
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
  scope:"api://<ACA_S2S_BLUEPRINT_APP_ID>/access_agent_as_user" }
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

> **Long-lived container — token refresh.** When agentic auth is enabled, `setup_mcp_servers`
> rebuilds the MCP tools past a TTL (`MCP_TOKEN_TTL_SECONDS`, default 1800s) so the per-audience
> OAuth token baked into the tools' httpx client headers is re-acquired before it expires —
> otherwise an always-on replica eventually returns **HTTP 401** on every Work IQ tool call. The
> pure-S2S LLM-only path (no tools) is unaffected. See [setup-MAF-ACA-DW.md](setup-MAF-ACA-DW.md)
> §9 for the full diagnosis. Redeploy the image (`az acr build` + `az containerapp update
> --image`, no secret rotation) to pick up the fix.
