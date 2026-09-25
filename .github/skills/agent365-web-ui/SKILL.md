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
- **Sidebar visibility**: every scaffolded tab carries `enabled: false` so its left-sidebar link is
  **hidden until the agent is live**. `app.js` renders a tab only when `enabled !== false`; the
  incremental integration step flips it to `true` to unhide it (see Flow §2).
- **Conversation memory (always on).** `app.js` sends each tab's last 3 exchanges with every request.
  ACA and FH-OBO get them as `history`; FH-S2S and FD as a Responses `input` message list. See
  [docs/setup-web-ui.md](../../../docs/setup-web-ui.md) §0. It's backward-compatible: an older agent just
  ignores `history`. A redeployed shared web UI therefore needs no per-agent change. Bump `app.js?v=` in
  `index.html` whenever `app.js` changes.

## Flow
1. **Scaffold** the config via the wizard router (no cloud writes):
   [scaffold-from-plan.ps1](../agent365-wizard/scripts/scaffold-from-plan.ps1) → module
   [scaffold.ui.ps1](../agent365-wizard/scripts/modules/scaffold.ui.ps1) emits
   `generated/<prefix>-ui/config.js`, where `<prefix>` is `solution.prefix` from the deployment plan.
2. **Deploy UI first, integrate incrementally.** Stand up the SWA shell with a placeholder `config.js`
   (all tabs `enabled: false`, so the sidebar starts empty); then, as each OBO/S2S agent goes live, in the
   SAME `config.js` edit fill its FQDN/endpoint **and** set its `enabled: true` to **unhide** its
   left-sidebar link, redeploy, and wire origins.
   - ⛔ **The moment the SWA exists, give the user its URL copy-friendly (a fenced code block with the
     bare `https://<swa-host>` on its own line, plus a clickable link) and set expectations**: the web UI
     is already live and openable, but the **left sidebar starts empty** — each agent's tab is **hidden
     until that agent is created, deployed and wired** (its `enabled` flag flips to true). Every tab
     appears and starts working as its agent goes live. Say this BEFORE moving on, so the empty sidebar
     isn't mistaken for a broken UI.
3. **Follow the canonical steps** for the SPA app registration, Entra consent (AllPrincipals), Azure
   RBAC for Foundry agents, and the SWA deploy: [docs/setup-web-ui.md](../../../docs/setup-web-ui.md)
   §2–§6. Per-host permission specifics (Mail consent for OBO, `UI_AUDIENCE` for ACA-S2S, Foundry
   access for FH/FD) are in that guide.

## Standalone / shared web UIs, association scripts, and tags
A web UI can be **lab-owned** (created inside a lab run, mode `create`) or **standalone/shared** (created
by the **Web UI Creator** agent). The difference is entirely in the tags:
- **`a365component=web-ui`** (on the SWA + its RG + the `<name>-spa` app) marks any web UI instance of this
  solution. It is what the Lab Builder filters on to list existing UIs for *Attach to an existing web UI*,
  and what the *Web UI & MCP Remover* filters on to find standalone instances. Add it with
  `az staticwebapp create ... --tags a365component=web-ui` or later with
  [Set-ComponentTags.ps1](../agent365-wizard/scripts/Set-ComponentTags.ps1) (`-SwaName <name>` or `-Retro`).
- **`a365lab=<prefix>`** marks a **lab-owned** UI (deleted by the Lab Cleaner). A **standalone** UI has
  `a365component` but **no** `a365lab`, so the Lab Cleaner never deletes it.
- **`a365ref_<prefix>=<yyyyMMdd>`** (on a SHARED SWA) records that lab `<prefix>` has agents integrated
  here. The Lab Cleaner uses it to find shared UIs and **deregister** that lab's tabs (never delete the UI).

**Attach mode is a SURGICAL MERGE, never a regeneration.** The scaffolder's UI module regenerates
`config.js` from the plan's `expose[]` — running it in `attach` mode would wipe other labs' tabs, so the
scaffolder **skips regeneration in attach mode** and instead emits one
[Add-WebUiTab.ps1](./scripts/Add-WebUiTab.ps1) command per exposed agent. Use these two scripts (both fetch
the LIVE `config.js` from the SWA as the source of truth, edit ONLY the `agents[]` array, validate with
`node --check`, and redeploy via `StaticSitesClient.exe`):
- **[Add-WebUiTab.ps1](./scripts/Add-WebUiTab.ps1)** — ASSOCIATE one agent: merge one tab (unique id
  `<typeShortId>-<labPrefix>`, `enabled:true`, correct endpoints + `customScopes`/`customInputs`,
  `labPrefix`), tag the SWA `a365ref_<prefix>`, and (ACA) append the origin to `UI_ALLOWED_ORIGINS`
  (+ `UI_AUDIENCE` for S2S). Used by Lab Builder (attach mode) and the Web UI Creator flow. For one of **N
  instances** of the same type, pass `-InstanceSuffix -<n>` so the id becomes `<typeShortId>-<n>-<labPrefix>`
  (still ends `-<labPrefix>`, so `Remove-TabsByLab` still finds it) and the FH session prefix stays unique.
- **[Remove-WebUiTab.ps1](./scripts/Remove-WebUiTab.ps1)** — DEREGISTER: remove a whole lab's tabs
  (`-LabPrefix`) or one agent's tab (`-TabId`), redeploy, and clear `a365ref_<prefix>` when the last tab of
  that lab goes. Used by the Lab Cleaner (per lab); the `-TabId` form detaches a single agent's tab.
The pure config transform lives in [_webui-config.ps1](./scripts/_webui-config.ps1) (cloud-free, unit-tested
offline in `tmp/test-webui-config.ps1`); cloud helpers in [_webui-cloud.ps1](./scripts/_webui-cloud.ps1).

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
