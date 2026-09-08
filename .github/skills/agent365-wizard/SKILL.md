---
name: agent365-wizard
description: 'Provisioning wizard for the Agent 365 agent lab (the Lab Builder agent; sample agents currently built with MAF). Use when creating/planning one or more of the 8 supported variants (ACA-OBO, ACA-S2S, ACA-DW, FH-OBO, FH-S2S, FH-DW, FD-OBO, FD-S2S), adding the companion web UI, deploying/registering the sample custom MCP servers, or attaching registered MCP tools (Work IQ / custom) to agents. Provides the variant matrix, minimal-question interview flow, naming/validation rules, a secret-free deployment-plan schema, and a read-only discovery script.'
argument-hint: "start | plan | scaffold"
---

# Agent 365 Provisioning Wizard

Interview the user with the **minimum** questions, produce a **secret-free** deployment plan, then
generate per-variant scaffolding from templates. Companion agent:
[a365-lab-provisioner.agent.md](../../agents/a365-lab-provisioner.agent.md).

## Supported variants (exactly 8)
`ACA-OBO`, `ACA-S2S`, `ACA-DW`, `FH-OBO`, `FH-S2S`, `FH-DW`, `FD-OBO`, `FD-S2S`.
FD-DW is intentionally **not** supported (prompt agents cannot be published as autopilot Digital
Workers). See [references/variant-matrix.md](./references/variant-matrix.md) for per-variant inputs,
tooling, hosting and endpoint types.

## When to use
- "Create / provision / deploy an agent", "new Agent 365 agent", "add the web UI", "wizard".
- Planning a multi-variant rollout in one tenant/subscription.

## Sub-skills (load the ones the selection needs)
This wizard owns the interview, discovery, plan and validation. Family/component detail lives in
focused sub-skills; load each only when its area is in scope, and never duplicate the canonical docs:
- **[agent365-aca-agents](../agent365-aca-agents/SKILL.md)** — ACA-OBO/S2S/DW.
- **[agent365-foundry-hosted-agents](../agent365-foundry-hosted-agents/SKILL.md)** — FH-OBO/S2S/DW.
- **[agent365-foundry-prompt-agents](../agent365-foundry-prompt-agents/SKILL.md)** — FD-OBO/S2S.
- **[agent365-web-ui](../agent365-web-ui/SKILL.md)** — the shared web SPA.
- **[agent365-custom-mcp](../agent365-custom-mcp/SKILL.md)** — the optional sample custom MCP.

The scaffolder is a thin router ([scripts/scaffold-from-plan.ps1](./scripts/scaffold-from-plan.ps1))
that dot-sources per-family modules under [scripts/modules/](./scripts/modules); the sub-skills point
back to it as the single execution entry point.

**Verify the cross-reference web** after editing any skill, agent or doc:
[scripts/check-links.ps1](./scripts/check-links.ps1) (read-only) asserts every local Markdown link
across `docs/`, the skills and the agent resolves — run it before committing structural changes.

## Procedure

### 0. Confirm the Copilot runtime model
This is the **first action on `start`**, before repository reads, tool calls, progress-log setup,
environment discovery, or provisioning questions. Use one single-select question:
**Confirm and continue** / **Change model or parameters** / **Cancel**.

- Present the active chat LLM and relevant runtime parameters (such as reasoning effort) only when
  VS Code exposes their values. Mark unavailable values as unknown; never infer or fabricate them.
- State that **reasoning effort High is recommended** for this complex, long-running, multi-step
  provisioning and validation workflow. If High is unavailable or not selected, show an explicit
  warning and recommend selecting High, choosing a model that supports it, or using the highest
  available effort. Permit continuation only after the user explicitly acknowledges the warning.
- If the user chooses **Change model or parameters**, STOP. Direct them to the chat model picker and
  its model configuration controls, then have them invoke `start` again after making the change.
- A wizard instruction cannot programmatically replace the LLM of an already-running chat. The
  companion custom agent therefore does not pin `model` or `reasoning-effort` in frontmatter; the
  settings supported by the selected VS Code model/provider remain authoritative.
- Never treat a confirmation from before a model/settings change as valid for the restarted run.

### 1. Confirm the target tenant and subscription
Immediately after the runtime gate — before variant selection, discovery, or any other question —
**always explicitly ask the user for the target Tenant ID and Subscription ID**, exactly as the
provisioning scripts require (`AZURE_TENANT_ID` + `AZURE_SUBSCRIPTION_ID`). Do not rely on the ambient
`az` context alone: run `az account show`, PRESENT the detected tenant id+name and subscription id+name,
and have the user confirm those values or enter the correct ones. Then pin them (`az account set
--subscription <id>`) and assert the tenant (`az account show --query tenantId` == the entered id);
abort on mismatch. These values are written ONLY to the gitignored `a365-deployment-plan.json`. This
guards the shared, concurrently-flipping `az`/Graph context (see the parallel-session note in
[references/naming-and-validation.md](./references/naming-and-validation.md)).

### 2. Select what to create
Use the ask-questions tool (checkboxes, single-select). Do NOT ask fields one at a time.
1. **Variants** — multi-select of the 8 variants (mark DW/FH as "requires Frontier/Foundry").
2. **Companion UI** — single-select: *No UI* / *Create new UI* / *Attach to existing UI*.
3. If a UI is chosen — multi-select of the **OBO/S2S** agents to expose (exclude DW: they route via
   Teams/Outlook/Office, not the SPA — see [docs/setup-web-ui.md](../../../docs/setup-web-ui.md)).
4. **Custom MCP** (single-select): *None* / *Anonymous only* / *Authenticated only* / *Both* — the
   sample [custom-mcp/](../../../custom-mcp/README.md). If not None, **do NOT ask a name** (it derives
   from the solution prefix → `ext_<prefix>Anon` / `ext_<prefix>Auth`; the prefix must be ≤ 12
   alphanumerics), ask a publisher name, which **OBO** agents to attach to (`ACA-OBO`/`FH-OBO`/`FD-OBO`
   only — S2S/DW are blocked: they can't own the per-user Power Platform connection a BYO server needs;
   see custom-mcp/README.md), an **integration mode** (*approve-first* = approve the servers before the
   agents, integrate each OBO immediately; *attach-when-approved* (default) = agents first, integrate
   when approved else manually later), and whether to enable `propagate_to_graph` (advanced
   On-Behalf-Of Graph test). Writes `customMcp` in the plan. The **prefix** is the unique per-copy key
   (Azure resources `<prefix>-mcp-*`, folder `generated/<prefix>/<prefix>-mcp/`, registrations all
   derive from it) — for N coexisting copies use a different prefix each run; check the tenant
   (`a365 develop list-available`) and ask again if `ext_<prefix>*` collides.
5. **Registered MCP tools** (per ACA-*/FH-* agent) — multi-select from `a365 develop list-available`
   (Work IQ `mcp_*` + custom `ext_*` + third-party). **Show ALL Work IQ servers but make only
   `mcp_MailTools` selectable today** (the rest visible-but-disabled, noting only tested tools are
   enabled for now); **pre-select Mail for OBO/DW only** (not S2S). Free-text allows other registered
   `uniqueName`s. Writes `agents[].tools` (FD stays `[]`); the scaffolder makes each manifest
   authoritative = these tools before `a365 setup all`, so permissions match the selection. Reuse the
   token lessons + the per-server permission map in
   [references/workiq-mcp-integration.md](./references/workiq-mcp-integration.md).
### 3. Solution basics (one screen)
- **Solution prefix** (e.g. `contoso`) — single value; all agent names derive from it as
  `<prefix>-<hosting>-<identity>` where hosting ∈ {ACA, FH, FD}, identity ∈ {OBO, S2S, DW}.
  **Before asking, STATE the rules to the user**: start with a lowercase letter; lowercase letters and
  digits only (no hyphens/underscores/uppercase/symbols); **3–12 characters** (the 12 cap is set by the
  custom MCP `ext_<prefix>Anon/Auth ≤ 20`; it also satisfies ACA, RG, managed identity, Entra and SWA).
- **Preferred region** — one value; validated per service during discovery.
- **Resource-group strategy** — single-select:
  - *Isolated (default)*: one RG per agent, `<agent-name>-rg`.
  - *Shared*: one RG `<prefix>-rg` (editable). For ACA this is allowed ONLY with resource-safe
    scripts or `-ReuseEnv` — see [references/naming-and-validation.md](./references/naming-and-validation.md).

### 4. Conditional questions (ask only what the selection requires)
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
  scope + `UI_AUDIENCE`; if exposing **FH/FD** (Foundry-based, **not ACA**): which user(s)/**group** get
  **Cognitive Services User** on the Foundry account (multiple allowed; a group is recommended).

Do NOT ask for: Log Analytics names, endpoints, app/blueprint IDs, fixed first-party scopes,
localhost redirect URIs, API versions, descriptions — these are discovered, derived, or fixed.

### 5. Discover + review
Run the read-only [scripts/discover-environment.ps1](./scripts/discover-environment.ps1) to populate
defaults (tenant, subscription, AOAI accounts, Foundry projects, region capacity). Present ONE
review screen with every derived name and resource, all editable. Enforce naming/validation from
[references/naming-and-validation.md](./references/naming-and-validation.md) — especially the DW
blueprint/`name.short` **≤ 30 characters** hard rule.

### 6. Write the plan
Emit `a365-deployment-plan.json` at the repo root from
[assets/deployment-plan.template.json](./assets/deployment-plan.template.json). It is **secret-free**
(resource references only) and gitignored. Schema:
[references/deployment-plan-schema.md](./references/deployment-plan-schema.md).
Then ask: **Save plan** / **Generate scaffolding** / **Cancel**.

### 7. Scaffold (only on confirmation)
Run [scripts/scaffold-from-plan.ps1](./scripts/scaffold-from-plan.ps1) — a thin **router** that
dot-sources the per-family/component modules under [scripts/modules/](./scripts/modules). It validates
the plan (DW ≤30-char, lowercase container names, shared-RG/ACA safety, custom-MCP prefix ≤12-char +
`integrationMode`), and writes everything under one **per-run root `generated/<prefix>/`**: copies each
variant sample into `generated/<prefix>/<agent-name>/`, fills the tenant-specific config, **rewrites the
ACA deploy-script constants** (RG / region / app / env are hardcoded, not parameters), makes each
agent's `ToolingManifest.json` **authoritative = its `agents[].tools`** (so `a365 setup all` grants only
the selected servers' permissions — no Mail on an agent that didn't select it), generates
`generated/<prefix>/<prefix>-ui/config.js` when a UI is requested, and scaffolds
`generated/<prefix>/<prefix>-mcp/` with filled `register-anon.json` / `register-auth.json` (names derived
from the prefix) when `customMcp.enabled`. It prints the next commands in **execution order**: web UI →
custom MCP (deploy → register → approval-mode note) → agents, each with its custom-MCP attach
(`a365 develop add-mcp-servers` + `a365 setup permissions mcp`) folded in right after its deploy. It
performs **no cloud mutations and runs no deploys**. Use `-ValidateOnly` to check a plan without
writing. Print the next commands for the user to run; never auto-run destructive deploys.

## 8. Deployment execution (only after scaffolding is confirmed)
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
- **Parallelization.** Serial only: `a365 setup`, secret/y-N/endpoint prompts, browser consent. May
  overlap: `azd`/`az acr build`/RBAC waits/`pip install`. Gate by free RAM (≤ `floor((freeMB-300)/300)`
  concurrent units, keep ≥300 MB free) and ASK the user before parallelizing.

## Safety
- No secrets in chat or in the plan. See the "Credentials" section in
  [references/variant-matrix.md](./references/variant-matrix.md).
- Confirm before any cloud-mutating step. The generic `deploy-aca.ps1` deletes its RG by default.
- Everything written to disk (files, logs, configs, comments) is in **English**.
