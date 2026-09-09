---
name: "Agent 365 — Web UI"
description: "Create, attach, configure and deploy the shared MSAL web SPA (Azure Static Web Apps) that exercises the OBO and S2S agents (ACA + Foundry). USE WHEN the user wants to add or wire the web UI, expose an agent as a tab, generate or fix ui/config.js, set UI_ALLOWED_ORIGINS / UI_AUDIENCE, or deploy the SPA. Trigger phrases: 'add the web UI', 'web SPA', 'config.js', 'expose agent in the UI', 'Static Web App', 'CORS for the agent'. Sub-skill of the Lab Builder."
---

# Agent 365 — Web UI

Thin orchestration for the shared web SPA. **All human setup detail is canonical in
[docs/setup-web-ui.md](../../../docs/setup-web-ui.md) — do not duplicate or renumber it here.**

## When to use
- Standing up a new SPA (`create`), or wiring the SPA to an existing app registration (`attach`).
- Adding a per-agent tab, regenerating `ui/config.js`, or fixing CORS after an agent deploys.

## What it owns
- The `ui.*` block of the deployment plan (mode, expose[], permissions).
- The generated `generated/<prefix>-ui/config.js` (one tab per exposed OBO/S2S agent — **DW is never exposed**;
  it routes via Teams/Outlook).

## Flow
1. **Scaffold** the config via the wizard router (no cloud writes):
   [scaffold-from-plan.ps1](../agent365-wizard/scripts/scaffold-from-plan.ps1) → module
   [scaffold.ui.ps1](../agent365-wizard/scripts/modules/scaffold.ui.ps1) emits
   `generated/<prefix>-ui/config.js`, where `<prefix>` is `solution.prefix` from the deployment plan.
2. **Deploy UI first, integrate incrementally.** Stand up the SWA shell with a placeholder `config.js`;
   then, as each OBO/S2S agent goes live, add its tab, redeploy, and wire origins.
3. **Follow the canonical steps** for the SPA app registration, Entra consent (AllPrincipals), Azure
   RBAC for Foundry agents, and the SWA deploy: [docs/setup-web-ui.md](../../../docs/setup-web-ui.md)
   §2–§6. Per-host permission specifics (Mail consent for OBO, `UI_AUDIENCE` for ACA-S2S, Foundry
   access for FH/FD) are in that guide.

## Guardrails
- `config.js` is gitignored (tenant-specific) — create it from `config.js.example`; never commit it.
- Always `node --check app.js ; node --check config.js` before deploying — one JS error breaks login.
- ⛔ **SWA region need not match the lab region.** SWA Free is only offered in `eastus2`/`centralus`/
  `eastasia`/`westeurope`/`westus2` and the SPA is served from a global CDN. If the lab region isn't one of
  these (e.g. `swedencentral`), ASK the user which allowed region to use for the Free SWA (nearest —
  `westeurope` in Europe, else the validated `eastus2`); the choice goes to `ui.swaRegion`.
- ⛔ **Deploy with `StaticSitesClient.exe` directly, from the repo root, with an absolute `--app` path** —
  the `npx @azure/static-web-apps-cli deploy` wrapper reliably exits 1 on Windows. Never pass `--app "."`
  from inside the UI folder (the uploader rejects an artifact folder equal to the cwd). See
  [docs/setup-web-ui.md](../../../docs/setup-web-ui.md).
- After deploy, set `UI_ALLOWED_ORIGINS` (+ `UI_AUDIENCE=<s2s-app-id>` for ACA-S2S) on the ACA
  containers so the browser origin is allowed (see [docs/setup-web-ui.md](../../../docs/setup-web-ui.md)).
- ⛔ **An OBO tab with a custom MCP attached MUST ship with `customScopes` (ACA/FH-OBO) or `customInputs`
  (FD-OBO) — never "Mail only".** The SPA acquires a delegated user token per BYO audience from those
  and the OBO host wires every manifest server, so the custom tools work from the first test. Fill the
  audiences from `plan.customMcp.audiences` (set right after registration) or the agent's
  `ToolingManifest.json`; wire them in the same `config.js` edit as the endpoint, then redeploy.
- ⛔ **Tell the user, up front, to create a SEPARATE one-time Power Platform connection for EACH ext_
  server (anon AND auth).** Each `ext_` server has its own connector; creating the anon connection is
  NOT enough. The **auth (`ext_<name>Auth`, EntraOAuth) connection needs an OAuth sign-in**. Open
  `https://make.powerapps.com/connectionsMcp` and create/authorize **both** as yourself. ⚠️ If
  `server_time`/`whoami_anon` work but an authenticated `whoami` request comes back from the *anon*
  server, the **auth connection is missing** (the auth server exposes only `initialize_server` until
  then). OBO reuses the connections across ACA/FH/FD.
