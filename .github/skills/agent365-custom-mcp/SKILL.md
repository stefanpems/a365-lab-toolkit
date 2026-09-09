---
name: "Agent 365 — Custom MCP"
description: "Deploy, register and attach the optional sample custom (bring-your-own) MCP server — one ACA container hosting an anonymous (/anon) and an authenticated (/auth) MCP server — to the ACA and FH sample agents, to test Agent 365 tool behavior. USE WHEN the user wants to add the sample MCP, register an ext_ server, attach a custom tool to an agent, or test caller identity / On-Behalf-Of Graph propagation. Trigger phrases: 'custom MCP', 'sample MCP', 'ext_ server', 'register MCP', 'attach a tool', 'propagate_to_graph', 'BYO MCP'. Sub-skill of the Lab Builder."
---

# Agent 365 — Custom MCP

Thin orchestration for the optional sample custom MCP. **The canonical usage, tool list, local-run,
deploy, register and attach detail is in [custom-mcp/README.md](../../../custom-mcp/README.md) — do
not duplicate or renumber it here.**

## When to use
- Testing a bring-your-own MCP tool against the **OBO** sample agents (`ACA-OBO` / `FH-OBO` / `FD-OBO`).
  **S2S and DW are blocked** (known preview limitation): a BYO server needs a one-time Power Platform
  connection owned by the invoking identity, and only an OBO agent invokes as the signed-in user who
  owns it — S2S (own app identity) / DW (projected `agentUser` identity) can't own or be granted it
  (`ConnectionSharingNotAllowed`); S2S also can't mint the custom-audience token from the SPA
  (`AADSTS82001`/`82002`).

## What it owns
- The `customMcp.*` block of the plan and the scaffolded `generated/<prefix>/<prefix>-mcp/` copy
  (module [scaffold.mcp.ps1](../agent365-wizard/scripts/modules/scaffold.mcp.ps1)).

## Mechanics (grounded in MS Learn)
- **Two servers, split by auth type** (auth type is per *registration*, not per tool): `/anon/mcp`
  → `ext_<prefix>Anon` (`NoAuth`); `/auth/mcp` → `ext_<prefix>Auth` (`EntraOAuth`).
- **Naming**: registered names start with `ext_` and are **≤ 20 chars**. **The name is NOT asked** — it
  derives from the **solution prefix** (lowercased, non-alphanumerics stripped), so the prefix must be
  **≤ 12 alphanumerics** when the custom MCP is enabled (the scaffolder validates this).
- **The prefix is the unique per-copy key**: all Azure resources (`<prefix>-mcp-rg`/`-ca`/`-cae`,
  lowercased), the scaffold folder `generated/<prefix>/<prefix>-mcp/` and both registrations derive from
  it. To create N coexisting copies, each run needs a **different prefix**; check the tenant
  (`a365 develop list-available` / admin center) and ask again if `ext_<prefix>*` already exists — never
  overwrite silently.
- **Integration mode** (`customMcp.integrationMode`, asked right after registration): *approve-first*
  (default) approves the servers before the agents (each OBO integrates immediately with permissions);
  *attach-when-approved* starts the agents first and integrates each OBO only if approved by
  the time it deploys, else attach later. The scaffolder folds the per-OBO attach right after each
  agent's deploy accordingly.
- **Order**: deploy the MCP container(s) → replace the per-server FQDN in the register JSON
  (`serverUrl` must be a single-segment root `https://<fqdn>/mcp`) → `a365 develop-mcp
  register-external-mcp-server` → **pre-empt the proxy consents** (`preempt-proxy-consents.ps1`) → a
  **tenant admin approves** each server in the M365 admin center (Agents → Tools → Requests; CLI
  approval was removed) → attach per agent.
- ⛔ **`register-external-mcp-server` PROMPTS `Proceed with registration? (y/N)` and WAITS — answer
  `y`, and NEVER pipe it through `| Out-String`.** `Out-String` (and `Tee-Object | Out-String`) buffers
  all output until the process exits, so the prompt is invisible and the command looks **hung for
  minutes** (this wasted a lot of time — an empty Enter defaults to **N** = "Registration cancelled",
  creating nothing). Run it streamed (no `Out-String`; `Tee-Object -FilePath <log>` alone is fine) and
  send `y`. There is no `--yes`/`--force` flag. The same applies to `a365 setup all`
  (`Assign this application permission now? [y/N]` → `y`) and any interactive `a365` command.
- ⛔ **Pre-empt the Approve consent with `preempt-proxy-consents.ps1` (emitted into `<prefix>-mcp/`).**
  Registration creates the backing proxy apps (A365Proxy / RemoteProxy / PublicClients / BYO) but NOT
  their service principals or the delegated grants, so the admin **Approve** fails with *"Couldn't
  complete consent for one or more apps backing this MCP server"*. Run
  `.\preempt-proxy-consents.ps1 -Name <prefix> -Subscription <sub>` AFTER both registrations and BEFORE
  Approve: it creates the missing proxy SPs + the AllPrincipals grants (anon/auth Proxy+PublicClients→BYO
  `Tools.ListInvoke.All`; BYO→Agent 365 Tools `PlatformRuntime.Internal.All`; auth RemoteProxy→Resource
  `access_as_agent`) idempotently. It uses a Graph token + `Invoke-RestMethod` — do **not** hand-roll
  this with `az rest --body @file` (mangles the JSON on Windows: `resourceId` seen as one character) or
  a `$filter clientId+resourceId` (Graph rejects it), and beware PowerShell array-of-arrays flattening
  (`@( @() @() )` without commas yields single-character elements).
- ⛔ **For the AUTH (EntraOAuth) server, the deploy → register order is load-bearing.** Agent 365
  captures the auth type into the Power Platform **connector at registration time** by probing the
  server. The auth server MUST already be serving its OAuth Protected Resource Metadata + `401`
  challenge when you register, or the connector is created **NoAuth** and the gateway forwards only
  `x-ms-client-*` identity headers (never a bearer token) forever — the only fix is re-registration.
  `deploy-mcp.ps1` enables this by default (`MCP_OAUTH_CHALLENGE` on + `MCP_AUTH_TENANT_ID` set on the
  auth container). Before running `register-external-mcp-server -f register-auth.json`, verify
  `Invoke-RestMethod https://<auth-fqdn>/.well-known/oauth-protected-resource` → `200`.
- ⛔ **`whoami` on an OBO agent MUST return `authorization_token_forwarded: true` — if it says `false`,
  it is a BUG, not a preview limitation.** The gateway DOES forward a delegated bearer token
  (`aud=api://<auth-app-id>`, `scp=access_as_agent`, the user's `upn`). Two conditions must both hold:
  (1) the connector is EntraOAuth (deploy → register order above); (2) the server reads headers with
  **`get_http_headers(include_all=True)`** — FastMCP strips `Authorization` by default, which hid the
  token and cost hours of debugging. `custom-mcp/server.py` (the template the scaffolder copies) already
  uses `include_all=True` in `_bearer_token`/`whoami`/`token_claims`/`whoami_anon` and logs each request's
  forwarded-token state as `[auth-diag]`. **Never remove `include_all=True`.** If a run still shows
  `false`, read the auth container log: `[auth-diag] … bearer forwarded aud=… scp=… upn=…` proves the
  token arrives (so the bug is header-reading), while `NO bearer token forwarded` means the connector is
  NoAuth (re-register).
- ⛔ **At Approve, warn the user LOUDLY about a blocked browser pop-up.** Admin consent opens
  popup(s); if the browser **blocks** them (a "pop-up blocked" icon in the address bar) the approval
  **silently hangs/fails and is easy to miss**. Tell the user in bold to allow pop-ups and retry.
- ⛔ **The AUTH (EntraOAuth) MCP approval shows 5 consent requests across 3 sign-in popups — say so up
  front so it isn't mistaken for an error.** Three logons grant five app consents: **(1)** `A365Proxy`
  + `BYO`, **(2)** `RemoteProxy` + `Resource`, **(3)** `BYO`. The user must accept **all** of them. The
  anonymous (NoAuth) MCP needs far fewer.
- **Approval gotchas (server-side validation runs on Approve):** one container **per server** at root
  `/mcp` (a multi-segment path like `/anon/mcp` fails registration with `HTTP 400` on the proxy
  connector); each container **single replica** (`min=max=1`, or the MCP session breaks with "Session
  not found" and Approve spins forever); the server must answer **`GET /` → 200** (the EntraOAuth
  validation probes root before `/mcp`); if Approve errors "Couldn't complete consent", a backing
  proxy app (e.g. `ext_<Name>*-PublicClients`) may lack a **service principal** — create it and grant
  admin consent for the delegated scopes. If `az ad` is CAE-blocked, use Microsoft Graph PowerShell.
  See [custom-mcp/README.md](../../../custom-mcp/README.md) "Troubleshooting".
- **Attach** (three steps — never hand-edit `ToolingManifest.json`), run in the agent folder:
  1. `a365 develop add-mcp-servers ext_<Name>Anon ext_<Name>Auth` — **local, safe** (updates
     `ToolingManifest.json` only, uses the cached token, no cloud mutation, no prompt). ⛔ **Run
     `a365 develop list-available` FIRST** (right before `add-mcp-servers`): the CLI reads a **cached**
     catalog, and if the last `list-available` ran BEFORE the servers were registered, `add-mcp-servers`
     logs *"Server 'ext_…' not found in catalog, adding with minimal configuration"* and writes an entry
     with **no `url`/`scope`/`audience`** — then permissions/token wiring are wrong. If you see minimal
     entries, `a365 develop remove-mcp-servers …` then `list-available` then `add-mcp-servers …` again
     so each entry gets its full `url` + `scope` (`Tools.ListInvoke.All`) + `audience` (the BYO app id).
  2. `a365 setup permissions mcp --agent-name <agent-name>` (Global Admin) — configures the
     blueprint's consent for the new servers' BYO resource apps (`Tools.ListInvoke.All`) and
     **opens a browser for admin consent**. ⛔ Tell the user explicitly: a **blocked popup** stalls
     this, and they must **grant all 3 additional admin consents** requested in that window. ⛔ Also
     tell them to **ignore the final page message** "Try that again using a different browser — We
     couldn't connect to that service, likely because of settings put in place by your IT team. Open
     Azure in a different Web browser to try again.": consent still succeeds and the CLI detects it
     (waits up to 180s). Allow popups, Accept, wait for "Consent granted". (Or `a365 setup all`
     before first setup.)
  3. **Redeploy the agent** so the runtime loads the new manifest (the manifest is baked into the
     image at build time): ACA → rebuild + `az containerapp update` (or the agent's `deploy-aca*.ps1`);
     FH → `azd deploy`. A revision restart alone is **not** enough — the old image still has the old
     manifest.
  - **ACA agents** work end-to-end (the runtime registers every server in `ToolingManifest.json`).
    **FH agents**: attach updates the manifest + consent, but the FH sample **code hardcodes only the
    Mail MCP** — a non-Mail custom server won't be called until the code is generalized (see
    `references/workiq-mcp-integration.md`). **FD agents are excluded** (no `ToolingManifest.json`).
  - The scaffolder emits these next-commands.
- **Attach count is per-agent 0/1/2**: each agent attaches the anon and/or auth server per the wizard
  choice, so an agent may expose the anon tools, the auth tools, both, or none (plus Mail). The
  runtime loads whatever is in `ToolingManifest.json`.
- **Testing the tools — OBO tabs DO exercise custom tools from the SPA (with `customScopes` wired);
  S2S/DW cannot.** For an **OBO** agent the SPA acquires a **delegated USER token per BYO audience**
  (from `config.js` `customScopes` = `{ <audience>: "<audience>/Tools.ListInvoke.All" }`) and sends
  them in the `/chat` body as `tokens`; the OBO host (`run_obo_mail_chat` / FH `run_obo_turn`) wires
  **every** `ToolingManifest.json` server with its per-audience token, so `server_time`, `whoami`, etc.
  run end-to-end through the Agent 365 gateway. This is verified (h2256, a09081). **So an OBO tab must
  be shipped WITH `customScopes` — never "Mail only".** The **S2S** and **DW** tabs still can't: S2S
  can't mint the custom-audience token from the SPA (`AADSTS82001`/`82002`) and DW isn't in the SPA at
  all — test those via the agentic / Bot Framework path (Teams / `/api/messages`) if ever needed.
  Tell-tale of a NON-call: `server_time` returns a **past** date or a wrong hash (the model
  hallucinated because the tool wasn't actually invoked — check `customScopes` + the Power Platform
  connection). ⛔ **Each `ext_` server needs its OWN Power Platform connection (anon AND auth
  separately); the auth one is EntraOAuth (OAuth sign-in).** If `whoami_anon` works but a request for
  the authenticated `whoami` returns the *anon* server's response, the **auth connection is missing**:
  the auth server exposes only `<server>_initialize_server` until the connection exists, so the auth
  `whoami` isn't in the tool set and the model substitutes the anon one. The OBO agent prompt now
  forbids that substitution and surfaces the auth setup URL instead. Note the model may still call the
  anon `whoami_anon` when asked **generically** for "whoami"; ask for the **`ext_<name>Auth`** server's
  `whoami` explicitly.
- **`Duplicate tool name 'initialize_server'` after attaching 2+ custom servers (agentic/Teams path).**
  The gateway exposes an `initialize_server` handshake tool for **every** `ext_*` server, so 2+ of them
  collide and the turn fails. Fix: unique `tool_name_prefix` per server **before it connects** — the
  ACA sample's `agent.py._namespace_mcp_tools()` (after `add_tool_servers_to_agent`) does this
  generically; rebuild the image after.
- **`propagate_to_graph` (advanced)**: needs the `/auth` app to be a confidential client with Graph
  `User.Read` (delegated) + admin consent + a client secret (entered in the terminal, never chat).
  Graph `User.Read` does not conflict with Work IQ or the Mail MCP.

Full step-by-step and the advanced setup: [custom-mcp/README.md](../../../custom-mcp/README.md).
