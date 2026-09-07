# Agent 365 sample custom MCP server

One image that provides **two** Model Context Protocol (MCP) servers (anonymous + authenticated) over
streamable HTTP, so you can test how a **custom (bring-your-own) MCP tool** behaves when attached to
the Agent 365 sample agents in this repo (ACA-OBO, ACA-S2S, ACA-DW, FH-OBO, FH-S2S, FH-DW).

The two servers are split by **authentication type** (in Agent 365 the auth type is chosen **per
registration**, not per tool). Each server is deployed as its **own container** and exposed at the
**root path `/mcp`** — Agent 365 registration builds a proxy connector from the server URL and fails
with `HTTP 400: Bad Request` when the MCP endpoint sits under a multi-segment path such as `/anon/mcp`.
The binary selects which server to host via the `MCP_SERVER_MODE` environment variable
(`anon` | `auth`; unset serves both under `/anon/mcp` + `/auth/mcp` for LOCAL exploration only — that
layout is **not** registerable in Agent 365).

| Container (`MCP_SERVER_MODE`) | Endpoint | Register with auth-type | Registered name |
|-------------------------------|----------|-------------------------|-----------------|
| `anon` | `https://<anon-fqdn>/mcp` | `NoAuth` | `ext_<Name>Anon` |
| `auth` | `https://<auth-fqdn>/mcp` | `EntraOAuth` | `ext_<Name>Auth` |

Each container runs a **single replica** (`min=max=1`): FastMCP streamable-HTTP keeps the MCP session
in memory per replica, so 2+ replicas break the approval's server validation with `Session not found`.

`<Name>` is chosen by the provisioning wizard. Registered server names must start with `ext_` and be
**≤ 20 characters**, so `<Name>` is limited to **≤ 12 characters** (`ext_` = 4 + `Anon`/`Auth` = 4).

`<Name>` is also the **unique per-copy key**: the wizard derives the Azure resources
(`<name>-mcp-rg` / `<name>-mcp-ca` / `<name>-mcp-cae`, lowercased), the scaffold folder
(`generated/custom-mcp-<name>/`) and both registrations from it. To run the wizard multiple times and
keep several copies side by side, give each a **different `<Name>`** (the wizard checks the tenant for
an existing `ext_<Name>*` before registering).

> **Lab only.** The ingress is public and the server performs no authorization of its own. Do not
> expose real data. The `/auth` tools decode the incoming token **without** verifying its signature —
> a production server must validate signature, issuer and audience.

## Tools

### `/anon/mcp` — NoAuth
| Tool | What it tests |
|------|---------------|
| `server_time()` | Direct, self-contained response (no network, no auth) — "what day/time is it now". |
| `hash_text(text, algo?)` | Direct self-contained compute (sha256 default; sha1/sha512/md5). |
| `outbound_connectivity_check(target?)` | HTTPS GET to a public endpoint; reports status + latency (egress test). |
| `whoami_anon()` | Confirms that **no** caller token arrives for a NoAuth server. |

### `/auth/mcp` — EntraOAuth
| Tool | What it tests |
|------|---------------|
| `whoami()` | Decodes the Entra token and reports **who authenticates**: OBO user, S2S app, or Digital Worker. |
| `token_claims()` | Full decoded claim set for deeper inspection. |
| `propagate_to_graph()` | On-Behalf-Of exchange to Microsoft Graph `User.Read` + `GET /me` — proves the **delegated credential propagates** to a downstream Entra service as the caller. App-only (S2S) tokens report that OBO is not applicable. |

`whoami()` lets you observe, empirically, the identity model per agent:
- **OBO** → delegated token carrying the signed-in user's claims.
- **S2S** → app-only token (app roles, no user).
- **Digital Worker** → delegated token carrying the agent's **own** user identity.

## 1. Run locally

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python server.py
```

- Anonymous server: `http://localhost:8000/anon/mcp`
- Authenticated server: `http://localhost:8000/auth/mcp`
- Health: `http://localhost:8000/health`

Test with MCP Inspector (`npx @modelcontextprotocol/inspector`) using the **Streamable HTTP** transport.

## 2. Deploy to Azure Container Apps

```powershell
.\deploy-mcp.ps1 -Subscription <SUBSCRIPTION_ID>
```

The script is resource-safe (creates the RG / environment / registry if missing, never deletes). It
builds one image and deploys **one container per server** (`anon`, `auth`), each a **single replica**
serving its MCP server at root `/mcp`, and prints each server's `https://<fqdn>/mcp` endpoint. To
enable `propagate_to_graph`, also pass `-AuthClientId <appId> -AuthTenantId <tenantId>` (the secret is
entered in the terminal and applied to the **auth** container only — see the advanced section below).

## 3. Register in Agent 365

Registration uses the [`a365 develop-mcp register-external-mcp-server`](https://learn.microsoft.com/microsoft-agent-365/developer/reference/cli/develop-mcp)
command. The wizard fills `register-anon.json` / `register-auth.json` from the templates.

```powershell
# Anonymous server (NoAuth): set serverUrl = https://<anon-fqdn>/mcp in register-anon.json
a365 develop-mcp register-external-mcp-server -f .\register-anon.json --dry-run
a365 develop-mcp register-external-mcp-server -f .\register-anon.json

# Authenticated server (EntraOAuth): FIRST create the resource app (see the advanced section),
# set remoteScopes = api://<resource-appId>/access_as_agent and serverUrl = https://<auth-fqdn>/mcp
a365 develop-mcp register-external-mcp-server -f .\register-auth.json
```

After each registration, a **tenant administrator approves** the server in the Microsoft 365 admin
center (Agents → Requested). CLI-based approval was removed; approval is admin-center only.

> BYO MCP servers are in **preview**; republishing a new version of a registered server isn't
> currently supported. If you change the tool surface, register under a new `ext_` name.

## 4. Attach to an agent

Attaching a registered server to one of the sample agents uses the documented tooling flow — you do
**not** hand-edit `ToolingManifest.json`. Three steps, run from the agent folder:

```powershell
cd generated\<agent-name>

# 1. Local, safe: updates ToolingManifest.json only (cached token, no cloud mutation, no prompt).
a365 develop add-mcp-servers ext_<Name>Anon ext_<Name>Auth

# 2. Global Admin: configures the blueprint's consent for the new servers' BYO resource apps
#    (Tools.ListInvoke.All) and OPENS A BROWSER for admin consent.
#    Watch for a BLOCKED POPUP. Grant ALL 3 additional admin consents requested in that window.
#    IGNORE the final page message "Try that again using a different browser / We couldn't connect
#    to that service..." — consent still succeeds and the CLI detects it (waits up to 180s).
#    Allow popups, Accept, wait for "Consent granted".
a365 setup permissions mcp --agent-name <agent-name>

# 3. Redeploy the agent so the runtime loads the new manifest (baked into the image at build):
#    ACA -> az acr build + az containerapp update (or the agent's deploy-aca*.ps1)
#    FH  -> azd deploy
#    A revision restart alone is NOT enough — the old image still has the old manifest.
```

Run `a365 setup permissions mcp` **after** the blueprint exists; before initial setup, `a365 setup all`
already includes the MCP permissions step. What each step does (validated):

- Step 1 fetches the MCP server catalog and adds the servers to `ToolingManifest.json`
  (`Successfully updated ToolingManifest.json / Total servers in manifest: N`).
- Step 2 configures permissions for the resource apps it finds — the Mail resource plus each attached
  server's **BYO** app (`Tools.ListInvoke.All`) — and grants delegated consent via the browser.
- **ACA agents work end-to-end**: the runtime registers every server in `ToolingManifest.json`, so no
  code change is needed. **FH agents**: attach updates the manifest + consent, but the FH sample
  **code hardcodes only the Mail MCP** — a non-Mail custom server isn't called until the code is
  generalized (see the FH integration reference). Redeploy is required either way.

> **FD (prompt) agents are not supported** for this flow. Foundry declarative/prompt agents attach
> tools via M365 app-manifest agent connectors, not `ToolingManifest.json`, so the wizard attaches the
> custom MCP only to ACA and FH agents.

### Testing the attached tools (and why the SPA tabs can't)

Depending on the wizard choice each agent attaches **0, 1, or 2** custom servers (anon and/or auth),
so a given agent may expose the anon tools, the auth tools, both, or none — plus Mail. Whatever is in
`ToolingManifest.json` is what the runtime loads.

⚠️ **The shared web UI (SPA) tabs do NOT exercise the custom tools — this is a hard Entra constraint,
not a bug.** The SPA `/chat` endpoints use simplified, TurnContext-free paths (OBO wires only the Mail
MCP; S2S wires no MCP tools) because:

- Each custom server is reached through the Agent 365 gateway
  (`https://agent365.svc.cloud.microsoft/agents/servers/<name>`) with a token whose **audience is that
  server's BYO app** (from `ToolingManifest.json`: anon `f828a86c…`, auth `898a9ac6…`, scope
  `Tools.ListInvoke.All`) — **not** the Mail audience `ea9ffc3e…`. The Mail `mail_token` does not
  cover the custom servers.
- The SDK mints that per-audience token via `auth.exchange_token()` — the **agentic** flow — which
  requires a **Bot Framework `TurnContext`**. The SPA endpoints have none.
- The blueprint is an **agentic application**, so it **cannot** mint app-only
  (`client_credentials` → `AADSTS82001`) or On-Behalf-Of (`jwt-bearer` → `AADSTS82002`) tokens for
  those audiences either. There is no SPA-side shortcut.

**So custom tools are exercised via the AGENTIC / Bot Framework path** (`process_user_message` →
`McpToolRegistrationService.add_tool_servers_to_agent`, which does the per-audience agentic exchange
with the `TurnContext`). Test them by messaging the agent on its Bot Framework surface (Teams / the
`/api/messages` endpoint), e.g. the Digital Worker in Teams — not from the SPA tabs.

**To sanity-check a custom server in isolation**, call its standalone container `/mcp` directly (the
`/anon` server is `NoAuth`, so no token is needed) — a healthy anon server lists its tools and
`server_time` returns the **real current** UTC time. If the SPA answers with a past date or a wrong
hash, the tool was **not** called (the model hallucinated) — expected on the SPA tabs.

## Advanced: `propagate_to_graph` setup

`propagate_to_graph` needs the `/auth` server's Entra app to be a **confidential client** that can
perform On-Behalf-Of to Microsoft Graph:

1. Create the **resource app** that `remoteScopes` points at — the CLI does **not** create it (it only
   creates the proxy / public-client apps). Expose the `access_as_agent` scope on it and put
   `api://<appId>/access_as_agent` in `register-auth.json` `remoteScopes`:
   ```powershell
   $appId = az ad app create --display-name "ext_<Name>Auth-Resource" --sign-in-audience AzureADMyOrg --query appId -o tsv
   az ad sp create --id $appId
   # then set identifierUris = api://$appId and expose an oauth2PermissionScope 'access_as_agent'
   # (Entra portal > Expose an API, or a Graph PATCH of the application).
   ```
   If `az ad` is blocked by Continuous Access Evaluation (`TokenCreatedWithOutdatedPolicies`) in a
   hardened tenant, use Microsoft Graph PowerShell instead: `Connect-MgGraph -Scopes
   Application.ReadWrite.All,Directory.ReadWrite.All` then `Invoke-MgGraphRequest` (higher-level
   `Get-MgApplication` may hit an assembly-version conflict — raw `Invoke-MgGraphRequest` avoids it).
2. Add **Microsoft Graph → Delegated → `User.Read`** to that resource app and **grant admin consent**.
   Portal: App registrations → the resource app → API permissions → Add → Microsoft Graph → Delegated →
   `User.Read` → Add → **Grant admin consent**. Or via Graph PowerShell (works when `az ad` is
   CAE-blocked): `PATCH` the app's `requiredResourceAccess` to add Graph
   (`00000003-0000-0000-c000-000000000000`) scope `User.Read`
   (`e1fe6dd8-ba31-4d61-89e7-88639da4683d`), then create an **AllPrincipals** `oauth2PermissionGrant`
   from the resource app's SP to the Graph SP with `scope: "User.Read"`.
3. Create a **client secret** on the resource app (Certificates & secrets → New client secret). Copy the
   value **once** — you paste it into the terminal at deploy time; **never commit it**.
4. Apply the client id / tenant id / secret to the **auth** container. On a fresh scaffold, re-run the
   deploy (the secret is entered via `Read-Host`, never on the command line):
   ```powershell
   .\deploy-mcp.ps1 -Subscription <SUB> -AuthClientId <resourceAppId> -AuthTenantId <tenantId>
   ```
   For an **already-deployed** auth container (updating in place, without recreating), store the secret
   as a container secret and reference it — paste the secret value directly into the first command:
   ```powershell
   az containerapp secret set -n <auth-app> -g <mcp-rg> --secrets mcp-auth-secret=<PASTE-SECRET-HERE>
   az containerapp update -n <auth-app> -g <mcp-rg> --set-env-vars `
     "MCP_AUTH_CLIENT_ID=<resourceAppId>" "MCP_AUTH_TENANT_ID=<tenantId>" `
     "MCP_AUTH_CLIENT_SECRET=secretref:mcp-auth-secret"
   ```
   The server reads `MCP_AUTH_CLIENT_ID` / `MCP_AUTH_TENANT_ID` / `MCP_AUTH_CLIENT_SECRET`.

`propagate_to_graph` is **optional** — `whoami` and `token_claims` inspect the caller identity without
it. Graph `User.Read` is a minimal, standalone scope on this dedicated app registration — it does not
overlap with the Mail MCP (`McpServers.Mail.All`) or Work IQ.

## Troubleshooting registration & approval

- **`HTTP 400: Bad Request` — "Failed to create connector shared_ext_<Name>...P"** at registration.
  The Agent 365 backend builds a proxy connector from the server URL and rejects a **multi-segment**
  path. Register each server at a single-segment **root `/mcp`** (this repo deploys one container per
  server for exactly this reason). The MCP handshake succeeding at `/anon/mcp` is **not** enough — the
  connector build still fails.
- **`Short description exceeds the maximum length of 80 characters`.** Keep `description` ≤ 80 chars in
  `register-*.json` (the templates already are).
- **Approve spins forever (no error).** The container had **> 1 replica**. FastMCP keeps the MCP
  session in memory per replica, so the approval's `initialize` + follow-up calls hit different
  replicas → `Session not found`. `deploy-mcp.ps1` pins each container to a single replica
  (`--min-replicas 1 --max-replicas 1`); if you deployed manually, set it too.
- **"Couldn't complete consent for one or more apps backing this MCP server."** One of the apps the
  CLI created (typically `ext_<Name>Anon-PublicClients`) may have **no service principal**, so the
  portal cannot record its admin consent. Create the missing SP and grant admin consent for the
  backing apps' delegated scopes (`Tools.ListInvoke.All` on the BYO app, `PlatformRuntime.Internal.All`
  on Agent Tools), then retry Approve. If `az ad` is CAE-blocked, do it via Microsoft Graph PowerShell
  (`Invoke-MgGraphRequest` to `POST /servicePrincipals` and `POST /oauth2PermissionGrants` with
  `consentType: AllPrincipals`).
- **Failed registration leaves orphans.** On failure the CLI prints "All created resources have been
  cleaned up" but does **not** roll back the Entra proxy apps (and sometimes leaves Power Platform
  connectors), which then cause a retry `400`. Run `cleanup-registration.ps1 -Name <Name>
  -Subscription <sub> -TenantId <tenant>` before retrying.
- **EntraOAuth (`auth`) Approve fails with a generic "Couldn't approve … Try again", and the container
  log shows only `GET / … 404`.** The EntraOAuth approval validation probes the server **root `/`** for
  reachability before `/mcp`; if root returns 404 it gives up. The server must answer **`GET / → 200`**
  (this repo registers `/` and `/health` via FastMCP `custom_route`; note that inserting a route into
  the app returned by `http_app()` does **not** register the root route).
- ⛔ **Blocked browser pop-up at Approve — check the address bar.** Approving opens admin-consent
  popup(s). If the browser **blocks** them (a "pop-up blocked" icon/notice appears in the address bar),
  the approval **silently hangs or fails** and it is easy to miss. **Allow pop-ups for the site and
  retry.**
- **Authenticated (EntraOAuth) approval = 5 consent requests in 3 sign-in popups — this is expected.**
  Approving the `auth` server walks through **three** admin-consent popups granting **five** app
  consents: (1) `A365Proxy` + `BYO`, (2) `RemoteProxy` + `Resource`, (3) `BYO`. Accept every one (and
  allow blocked pop-ups). The `anon` (NoAuth) server needs far fewer.

## Project structure

```
custom-mcp/
├── server.py                    # anon + auth MCP servers; MCP_SERVER_MODE selects one at root /mcp
├── requirements.txt             # fastmcp, httpx, uvicorn, msal
├── Dockerfile                   # image for ACA
├── .dockerignore
├── deploy-mcp.ps1               # resource-safe ACA deployment (one container per server, single replica)
├── cleanup-registration.ps1     # remove orphaned proxy apps/connectors from a failed registration
├── register-anon.template.json  # NoAuth registration payload (filled by the wizard)
├── register-auth.template.json  # EntraOAuth registration payload (filled by the wizard)
└── README.md
```
