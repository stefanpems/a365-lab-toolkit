---
name: "Agent 365 — Custom MCP"
description: "Deploy, register and attach the optional sample custom (bring-your-own) MCP server — one ACA container hosting an anonymous (/anon) and an authenticated (/auth) MCP server — to the ACA and FH sample agents, to test Agent 365 tool behavior. USE WHEN the user wants to add the sample MCP, register an ext_ server, attach a custom tool to an agent, or test caller identity / On-Behalf-Of Graph propagation. Trigger phrases: 'custom MCP', 'sample MCP', 'ext_ server', 'register MCP', 'attach a tool', 'propagate_to_graph', 'BYO MCP'. Sub-skill of the A365 Lab Provisioner."
---

# Agent 365 — Custom MCP

Thin orchestration for the optional sample custom MCP. **The canonical usage, tool list, local-run,
deploy, register and attach detail is in [custom-mcp/README.md](../../../custom-mcp/README.md) — do
not duplicate or renumber it here.**

## When to use
- Testing a bring-your-own MCP tool against the ACA / FH sample agents (FD is **excluded** — prompt
  agents wire tools via M365 app-manifest connectors, not `ToolingManifest.json`).

## What it owns
- The `customMcp.*` block of the plan and the scaffolded `generated/custom-mcp-<name>/` copy
  (module [scaffold.mcp.ps1](../agent365-wizard/scripts/modules/scaffold.mcp.ps1)).

## Mechanics (grounded in MS Learn)
- **Two servers, split by auth type** (auth type is per *registration*, not per tool): `/anon/mcp`
  → `ext_<Name>Anon` (`NoAuth`); `/auth/mcp` → `ext_<Name>Auth` (`EntraOAuth`).
- **Naming**: registered names start with `ext_` and are **≤ 20 chars** → ask `<Name>` **≤ 12 chars**
  (`^[A-Za-z][A-Za-z0-9]*$`); validate the length when asking.
- **`<Name>` is the unique per-copy key**: all Azure resources (`<name>-mcp-rg`/`-ca`/`-cae`,
  lowercased), the scaffold folder and both registrations derive from it. To create N coexisting
  copies, each run needs a **different** `<Name>`; check the tenant (`a365 develop list-available` /
  admin center) and ask again if `ext_<Name>*` already exists — never overwrite silently.
- **Order**: deploy the MCP container(s) → replace the per-server FQDN in the register JSON
  (`serverUrl` must be a single-segment root `https://<fqdn>/mcp`) → `a365 develop-mcp
  register-external-mcp-server` → a **tenant admin approves** each server in the M365 admin center
  (Agents → Tools → Requests; CLI approval was removed) → attach per agent.
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
- **Attach** (never hand-edit `ToolingManifest.json`): `a365 develop add-mcp-servers ext_<Name>Anon
  ext_<Name>Auth` in the agent folder, then `a365 setup permissions mcp` (Global Admin) — or
  `a365 setup all` before first setup. The scaffolder emits these next-commands.
- **`propagate_to_graph` (advanced)**: needs the `/auth` app to be a confidential client with Graph
  `User.Read` (delegated) + admin consent + a client secret (entered in the terminal, never chat).
  Graph `User.Read` does not conflict with Work IQ or the Mail MCP.

Full step-by-step and the advanced setup: [custom-mcp/README.md](../../../custom-mcp/README.md).
