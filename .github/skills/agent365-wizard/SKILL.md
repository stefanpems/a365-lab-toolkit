---
name: agent365-wizard
description: 'Provisioning wizard for the Agent 365 Agent Framework samples. Use when creating/planning one or more of the 8 supported variants (ACA-OBO, ACA-S2S, ACA-DW, FH-OBO, FH-S2S, FH-DW, FD-OBO, FD-S2S), adding the companion web UI, attaching OBO/S2S agents to a new or existing UI, or (future) registering a custom MCP tool in Agent 365. Provides the variant matrix, minimal-question interview flow, naming/validation rules, a secret-free deployment-plan schema, and a read-only discovery script.'
argument-hint: "start | plan | scaffold"
---

# Agent 365 Provisioning Wizard

Interview the user with the **minimum** questions, produce a **secret-free** deployment plan, then
generate per-variant scaffolding from templates. Companion agent:
[agent365-provisioner.agent.md](../../agents/agent365-provisioner.agent.md).

## Supported variants (exactly 8)
`ACA-OBO`, `ACA-S2S`, `ACA-DW`, `FH-OBO`, `FH-S2S`, `FH-DW`, `FD-OBO`, `FD-S2S`.
FD-DW is intentionally **not** supported (prompt agents cannot be published as autopilot Digital
Workers). See [references/variant-matrix.md](./references/variant-matrix.md) for per-variant inputs,
tooling, hosting and endpoint types.

## When to use
- "Create / provision / deploy an agent", "new Agent 365 agent", "add the web UI", "wizard".
- Planning a multi-variant rollout in one tenant/subscription.

## Procedure

### 1. Select what to create
Use the ask-questions tool (checkboxes, single-select). Do NOT ask fields one at a time.
1. **Variants** — multi-select of the 8 variants (mark DW/FH as "requires Frontier/Foundry").
2. **Companion UI** — single-select: *No UI* / *Create new UI* / *Attach to existing UI*.
3. If a UI is chosen — multi-select of the **OBO/S2S** agents to expose (exclude DW: they route via
   Teams/Outlook/Office, not the SPA — see [docs/setup-web-ui.md](../../../docs/setup-web-ui.md)).
4. Note only: a **custom MCP tool** registration in Agent 365 is a planned future step; reserve the
   `tools:` field in the plan but do not ask about it yet.

### 2. Solution basics (one screen)
- **Solution prefix** (e.g. `contoso-sales`) — single value; all agent names derive from it as
  `<prefix>-<hosting>-<identity>` where hosting ∈ {ACA, FH, FD}, identity ∈ {OBO, S2S, DW}.
- **Tenant / Subscription** — run `az account show`, **present the detected tenant id+name and
  subscription id+name, and have the user confirm or pick another**. Never proceed silently; these
  values are written ONLY to the gitignored `a365-deployment-plan.json` — never hard-coded elsewhere.
- **Preferred region** — one value; validated per service in step 4.
- **Resource-group strategy** — single-select:
  - *Isolated (default)*: one RG per agent, `<agent-name>-rg`.
  - *Shared*: one RG `<prefix>-rg` (editable). For ACA this is allowed ONLY with resource-safe
    scripts or `-ReuseEnv` — see [references/naming-and-validation.md](./references/naming-and-validation.md).

### 3. Conditional questions (ask only what the selection requires)
Driven by [references/variant-matrix.md](./references/variant-matrix.md):
- Any **ACA** → Azure OpenAI account + model deployment; auth = **Managed Identity (default)** or
  API key (fallback, entered in the terminal, never chat).
- Any **FH** → Foundry project new/existing + chat model deployment.
- Any **FD** → Foundry project: **the wizard can CREATE one** (AIServices account + project + model)
  if none is selected; reuse the FH project if an FH variant is also chosen; or reuse an existing one
  if the user prefers. FD does not strictly require a pre-existing project.
- Any **DW** (ACA-DW / FH-DW) → confirm Frontier/Agent 365 enrollment, license capacity, policy
  template choice. Surface the portal steps as verifiable checkpoints.
- **UI** → if exposing OBO: Mail consent (`McpServers.Mail.All`); if exposing ACA-S2S: blueprint
  scope + `UI_AUDIENCE`; if exposing FH/FD: which users/groups get Foundry access.

Do NOT ask for: Log Analytics names, endpoints, app/blueprint IDs, fixed first-party scopes,
localhost redirect URIs, API versions, descriptions — these are discovered, derived, or fixed.

### 4. Discover + review
Run the read-only [scripts/discover-environment.ps1](./scripts/discover-environment.ps1) to populate
defaults (tenant, subscription, AOAI accounts, Foundry projects, region capacity). Present ONE
review screen with every derived name and resource, all editable. Enforce naming/validation from
[references/naming-and-validation.md](./references/naming-and-validation.md) — especially the DW
blueprint/`name.short` **≤ 30 characters** hard rule.

### 5. Write the plan
Emit `a365-deployment-plan.json` at the repo root from
[assets/deployment-plan.template.json](./assets/deployment-plan.template.json). It is **secret-free**
(resource references only) and gitignored. Schema:
[references/deployment-plan-schema.md](./references/deployment-plan-schema.md).
Then ask: **Save plan** / **Generate scaffolding** / **Cancel**.

### 6. Scaffold (only on confirmation)
Run [scripts/scaffold-from-plan.ps1](./scripts/scaffold-from-plan.ps1). It validates the plan
(DW ≤30-char, lowercase container names, shared-RG/ACA safety), copies each variant sample into
`generated/<agent-name>/`, fills the tenant-specific config, **rewrites the ACA deploy-script
constants** (RG / region / app / env are hardcoded, not parameters), generates `generated/ui/config.js`
when a UI is requested, and prints the exact next commands. It performs **no cloud mutations and runs
no deploys**. Use `-ValidateOnly` to check a plan without writing. Print the next commands for the
user to run; never auto-run destructive deploys.

## 7. Deployment execution (only after scaffolding is confirmed)
- **UI first, then integrate incrementally.** Stand up the SPA shell first (SWA + SPA app reg +
  placeholder `config.js`); then, as each OBO/S2S agent goes live, add its tab, redeploy the UI, wire
  `UI_ALLOWED_ORIGINS` (+ `UI_AUDIENCE` for ACA-S2S), and tell the user they can test it now.
- **Progress log.** Append timestamped English lines to `generated/wizard-progress.log` (gitignored)
  at every state change; tell the user to watch that file. Never end a turn with a vague "I'll resume."
- **Blocking prompts (secret / y-N / endpoint / azd login).** Beep (`[console]::beep(880,400)`),
  show a bold ⛔ ACTION REQUIRED banner naming which terminal (and how to focus it via the Terminal
  panel dropdown / `N Hidden Terminals`), what to type, and where to get the value
  (`a365 setup blueprint --show-secret`). Secrets are typed by the user, never relayed.
- **Browser sign-in + admin consent** happens for ACA `a365 setup`, `azd auth login`, SPA consent,
  and first UI-tab use. Announce it each time; the post-accept "We couldn't connect to that service"
  page is expected and safe to ignore.
- **`ext_UtilityInsights` prompt** during ACA/DW setup → answer **N** (optional MCP absent in tenant;
  `az ad sp create` failure is harmless).
- **Parallelization.** Serial only: `a365 setup`, secret/y-N/endpoint prompts, browser consent. May
  overlap: `azd`/`az acr build`/RBAC waits/`pip install`. Gate by free RAM (≤ `floor((freeMB-300)/300)`
  concurrent units, keep ≥300 MB free) and ASK the user before parallelizing.

## Safety
- No secrets in chat or in the plan. See the "Credentials" section in
  [references/variant-matrix.md](./references/variant-matrix.md).
- Confirm before any cloud-mutating step. The generic `deploy-aca.ps1` deletes its RG by default.
- Everything written to disk (files, logs, configs, comments) is in **English**.
