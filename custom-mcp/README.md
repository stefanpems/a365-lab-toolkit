# Agent 365 sample custom MCP server

A single container that hosts **two** Model Context Protocol (MCP) servers over streamable HTTP so you
can test how a **custom (bring-your-own) MCP tool** behaves when attached to the Agent 365 sample
agents in this repo (ACA-OBO, ACA-S2S, ACA-DW, FH-OBO, FH-S2S, FH-DW).

The two servers are split by **authentication type**, because in Agent 365 the auth type is chosen
**per registration**, not per tool:

| Path | Register with auth-type | Registered name | Purpose |
|------|-------------------------|-----------------|---------|
| `/anon/mcp` | `NoAuth` | `ext_<Name>Anon` | Anonymous calls, direct responses, outbound connectivity |
| `/auth/mcp` | `EntraOAuth` | `ext_<Name>Auth` | Caller-identity inspection + credential propagation |

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

The script is resource-safe (creates the RG / environment / registry if missing, never deletes) and
prints the public `/anon/mcp` and `/auth/mcp` endpoints. To enable `propagate_to_graph`, also pass
`-AuthClientId <appId> -AuthTenantId <tenantId>` (see the advanced section below).

## 3. Register in Agent 365

Registration uses the [`a365 develop-mcp register-external-mcp-server`](https://learn.microsoft.com/microsoft-agent-365/developer/reference/cli/develop-mcp)
command. The wizard fills `register-anon.json` / `register-auth.json` from the templates.

```powershell
# Anonymous server (NoAuth)
a365 develop-mcp register-external-mcp-server -f .\register-anon.json --dry-run
a365 develop-mcp register-external-mcp-server -f .\register-anon.json

# Authenticated server (EntraOAuth) — see the advanced setup below first
a365 develop-mcp register-external-mcp-server -f .\register-auth.json
```

After each registration, a **tenant administrator approves** the server in the Microsoft 365 admin
center (Agents → Requested). CLI-based approval was removed; approval is admin-center only.

> BYO MCP servers are in **preview**; republishing a new version of a registered server isn't
> currently supported. If you change the tool surface, register under a new `ext_` name.

## 4. Attach to an agent

Attaching a registered server to one of the sample agents uses the documented tooling flow — you do
**not** hand-edit `ToolingManifest.json`:

```powershell
cd generated\<agent-name>
a365 develop add-mcp-servers ext_<Name>Anon ext_<Name>Auth   # writes ToolingManifest.json (scope/audience from the catalog)
a365 setup permissions mcp                                    # Global Admin grants the OAuth2 grants to the blueprint
```

Run `a365 setup permissions mcp` **after** the blueprint exists; before initial setup, `a365 setup all`
already includes the MCP permissions step. The sample agents' runtime already registers every server
found in `ToolingManifest.json`, so no code change is needed.

> **FD (prompt) agents are not supported** for this flow. Foundry declarative/prompt agents attach
> tools via M365 app-manifest agent connectors, not `ToolingManifest.json`, so the wizard attaches the
> custom MCP only to ACA and FH agents.

## Advanced: `propagate_to_graph` setup

`propagate_to_graph` needs the `/auth` server's Entra app to be a **confidential client** that can
perform On-Behalf-Of to Microsoft Graph:

1. Register the `/auth` server with `EntraOAuth` (the CLI creates the app registrations and exposes the
   `api://<appId>/access_as_agent` scope used as `remoteScopes`).
2. On that app, add **Microsoft Graph → Delegated → `User.Read`** and grant **admin consent**.
3. Create a **client secret** on that app.
4. Deploy with the client id / tenant id and enter the secret in the terminal:
   ```powershell
   .\deploy-mcp.ps1 -Subscription <SUB> -AuthClientId <authAppId> -AuthTenantId <tenantId>
   ```
   The container reads `MCP_AUTH_CLIENT_ID`, `MCP_AUTH_TENANT_ID`, `MCP_AUTH_CLIENT_SECRET`.

Graph `User.Read` is a minimal, standalone scope on this dedicated app registration — it does not
overlap with the Mail MCP (`McpServers.Mail.All`) or WorkIQ.

## Project structure

```
custom-mcp/
├── server.py                    # both MCP servers (/anon, /auth) + combined ASGI app
├── requirements.txt             # fastmcp, httpx, uvicorn, msal
├── Dockerfile                   # image for ACA
├── .dockerignore
├── deploy-mcp.ps1               # resource-safe ACA deployment
├── register-anon.template.json  # NoAuth registration payload (filled by the wizard)
├── register-auth.template.json  # EntraOAuth registration payload (filled by the wizard)
└── README.md
```
