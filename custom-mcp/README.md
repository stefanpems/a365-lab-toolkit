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
(`generated/<prefix>-mcp/`, from `solution.prefix`) and both registrations from it. To run the wizard multiple times and
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

> ⛔ **Deploy the auth server BEFORE registering it, and confirm it already serves the OAuth
> Protected Resource Metadata.** Agent 365 captures the auth type into the Power Platform **connector
> at registration time** by probing the server. If the `EntraOAuth` server isn't serving its PRM +
> `401` challenge when you register, the connector is created **NoAuth** and the gateway will forever
> forward only `x-ms-client-*` identity headers (never a bearer token) — re-registration is then the
> only fix. `deploy-mcp.ps1` enables the challenge by default (`MCP_OAUTH_CHALLENGE` defaults to on for
> the auth container) and sets `MCP_AUTH_TENANT_ID`, so the correct order is simply **deploy → verify
> → register**. Verify before registering:
>
> ```powershell
> # Must return 200 with "authorization_servers" pointing at your tenant's v2.0 issuer:
> Invoke-RestMethod "https://<auth-fqdn>/.well-known/oauth-protected-resource"
> ```

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

### Testing the attached tools — the connection model (READ THIS)

Depending on the wizard choice each agent attaches **0, 1, or 2** custom servers (anon and/or auth),
so a given agent may expose the anon tools, the auth tools, both, or none — plus Mail. Whatever is in
`ToolingManifest.json` is what the runtime loads.

**How a BYO custom tool is reached (Agent 365 gateway + Power Platform connection):**

1. The agent calls the server through the **Agent 365 gateway**
   (`https://agent365.svc.cloud.microsoft/agents/servers/<name>`) with a token whose **audience is that
   server's BYO app** (from `ToolingManifest.json`: anon `f828a86c…`, auth `898a9ac6…`, scope
   `Tools.ListInvoke.All`) — **not** the Mail audience `ea9ffc3e…`.
2. Each registered `ext_*` server is backed by a **Power Platform connector** (`shared_tc-ext_<name>…`).
   Before the tools work, a **one-time connection** must exist, **owned by the identity that invokes**.
   On the first call the gateway exposes a single `initialize_server` handshake tool whose response is:
   *"This server is not yet set up. Ask the user to visit the following URL to complete setup:
   `https://make.powerapps.com/connectionsMcp?connectorIds=shared_tc-ext_<name>…&environmentName=…`"*.
   The user opens that URL once and creates the connection; then the real tools surface
   (`tools/list_changed`).

**Which agents can use custom tools — and why (verified with hard evidence):**

| Agent kind | Invokes the gateway as… | Custom tools? |
|---|---|---|
| **OBO** (ACA/FH/FD) | the **signed-in user's own delegated token** (the SPA acquires one per audience) | ✅ **Works** — the user owns the connection they created, so identities match |
| **S2S** (ACA/FH/FD) | its **own agent application** | ❌ Blocked in preview |
| **DW** (ACA/FH) | an **`#microsoft.graph.agentUser`** (a projection of the user, e.g. `4ee6a63d…`) — **not** the regular user | ❌ Blocked in preview |

The block for DW/S2S is **not a bug in this repo**: the Power Platform connection is owned by whoever
signs in at `make.powerapps.com` (the **regular user**, e.g. `745ff0eb…`), but a DW invokes as the
**agentUser** and an S2S as the **agent app** — different identities with **no** connection, and these
connectors **cannot be shared** (`modifyPermissions` → `403 ConnectionSharingNotAllowed`). An agent
identity also can't sign in to `make.powerapps.com` to create its own. So **OBO is the demonstrable
path**: the agent invokes as the user, and the user owns the connection. (This matches the Microsoft
docs, whose supported BYO surfaces — Copilot Studio, VS Code, Claude Code, GitHub Copilot CLI — are all
user-driven.)

**How the OBO SPA path is wired** (so a user can exercise custom tools from the web UI):

- `ui/config.js` gives each OBO agent a `customScopes` map (`{ <audience>: "<audience>/Tools.ListInvoke.All" }`).
- `ui/app.js` (`callAcaChat`) acquires a **delegated user token per custom audience** and sends them in
  the request body as `tokens` (audience → token), alongside the Mail token.
- The ACA-OBO host `/chat` builds the `{audience: token}` map; `agent.run_obo_mail_chat` reads
  `ToolingManifest.json` and wires **every** server with the user's per-audience token (unique
  `tool_name_prefix` so the per-server `initialize_server` handshakes don't collide), then activates
  each BYO server via `initialize_server`. FH-OBO (`main.py` + `foundry_agent.py`) uses the same
  `tokens` map.

⚠️ **Multiple consent prompts on first use — tell the user.** The SPA acquires one token per custom
audience; each new scope triggers an MSAL **consent redirect** that reloads the page and **clears the
chat**. With two custom servers the user may need to **re-enter the same prompt up to three times**
(anon consent → auth consent → answer). After the first consent the tokens are cached and it stops. A
future improvement is to request all custom scopes at login.

**Auth (EntraOAuth) server — caller identity comes from gateway headers.** The gateway forwards the
caller identity as `x-ms-client-*` headers (`x-ms-client-principal-id`, `x-ms-client-app-id`,
`x-ms-client-tenant-id`), not always as an `Authorization` bearer token. The sample `whoami` /
`token_claims` tools therefore report the caller from those headers when no token is forwarded.

> **Why the gateway forwards identity headers but not a bearer token (verified).** Per the Microsoft
> docs ([Secure an MCP server with Entra ID](https://learn.microsoft.com/entra/agent-id/secure-mcp-server-with-entra-id)),
> the Agent 365 Tooling Gateway attaches a caller token only when the MCP server drives the standard
> OAuth flow: it must serve **OAuth 2.0 Protected Resource Metadata** (RFC 9728) at
> `/.well-known/oauth-protected-resource` and answer **`401` with a `WWW-Authenticate: Bearer
> resource_metadata="…"`** header on unauthenticated requests. Only then does the gateway request a
> token (performing the On-Behalf-Of exchange for the server's `remoteScopes` resource) and re-call
> with `Authorization: Bearer`.
>
> **Root cause (verified with runtime logs).** Adding the PRM + `401` to the *running* server is **not
> enough**: the auth type is captured **at registration time** into the Power Platform **connector**
> that the gateway actually talks to. Because this sample server did **not** serve the PRM when it was
> first registered, its connector was created effectively **NoAuth** (the connection shows an empty
> `authenticatedUser`), so at runtime the gateway/connector calls `/mcp` and gets `200` **without ever
> issuing the `401` OAuth handshake** — it just forwards the `x-ms-client-*` identity headers. `whoami`
> still reports the correct caller from those headers (for OBO, the signed-in user's object id).
>
> **To get a real forwarded token** you must: (1) make the server serve the PRM + `401` challenge
> (this repo does, behind `MCP_OAUTH_CHALLENGE=true` on the auth container — see `build_single` /
> `_wrap_oauth_challenge` in [`server.py`](server.py)); **then** (2) **re-register** the server with
> `a365 develop-mcp register-external-mcp-server` so a fresh **EntraOAuth** connector is built against
> the now-discoverable PRM; (3) re-approve it; (4) re-create the Power Platform connection (which now
> performs the OAuth sign-in). Only after the connector is EntraOAuth does the gateway do the OBO and
> forward `Authorization: Bearer`.



#### `smoke-test.py` — invoke a server's tools directly from a script (isolation test)

[`smoke-test.py`](smoke-test.py) is a small MCP client (the Python equivalent of
`rg-mcp-demo/smoke-test.mjs`): it opens a Streamable HTTP session to a `/mcp` endpoint, lists the
tools and calls each with sample arguments. It reaches the server's **own** container directly (not the
gateway), so it isolates the tool implementation from the gateway/connection path — useful to confirm a
server is healthy independently of Agent 365.

```powershell
$py = "C:\ghcp_nosync\a365sdk\agent365-agentframework-python\.venv\Scripts\python.exe"

# Anonymous (NoAuth) server — works immediately, no token:
& $py smoke-test.py --url https://<anon-fqdn>/mcp

# Authenticated (EntraOAuth) server — needs a token for its resource:
& $py smoke-test.py --url https://<auth-fqdn>/mcp --client-id <public-client-id> --scope api://<auth-app-id>/access_as_agent --tenant <tenant-id>
```

> This direct call is a health check only; it bypasses the Agent 365 gateway and its governance. The
> lab's goal is to exercise the tools **through the gateway** from the app the user interacts with — use
> the OBO SPA tab for that.



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
- **After attaching, the agent turn fails with `Duplicate tool name 'initialize_server'` (agentic /
  Teams path).** The Agent 365 gateway exposes a handshake tool named `initialize_server` for **every**
  registered external (`ext_*`) MCP server, so attaching **2+** custom servers gives duplicate function
  names and `agent_framework` rejects the run (first-party servers like Mail expose real tool names, so
  the collision only appears once 2+ `ext_*` are attached). Fix: give each MCP server a unique
  `tool_name_prefix` **before it connects/lists tools**. The ACA sample does this in
  `agent.py._namespace_mcp_tools()` (called right after `add_tool_servers_to_agent`, iterating
  `tool_service._connected_servers`); it is generic for 0/1/2 attached servers. Rebuild the agent image
  after the code change.

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
