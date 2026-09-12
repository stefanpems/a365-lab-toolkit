---
name: agent365-wizard
description: 'Provisioning wizard for the Agent 365 agent lab (the Lab Builder agent; sample agents currently built with MAF). Use when creating/planning one or more of the 10 supported variants (ACA-OBO, ACA-S2S, ACA-DW, FH-OBO, FH-S2S, FH-DW, FD-OBO, FD-S2S, plus the Microsoft Copilot Studio agents MCS-OH and MCS-NH), adding the companion web UI, deploying/registering the sample custom MCP servers, or attaching registered MCP tools (Work IQ / custom) to agents. Provides the variant matrix, minimal-question interview flow, naming/validation rules, a secret-free deployment-plan schema, and a read-only discovery script.'
argument-hint: "start | plan | scaffold"
---

# Agent 365 Provisioning Wizard

Interview the user with the **minimum** questions, produce a **secret-free** deployment plan, then
generate per-variant scaffolding from templates. Companion agent:
[a365-lab-provisioner.agent.md](../../agents/a365-lab-provisioner.agent.md).

## Supported variants (10)
`ACA-OBO`, `ACA-S2S`, `ACA-DW`, `FH-OBO`, `FH-S2S`, `FH-DW`, `FD-OBO`, `FD-S2S`, and the Microsoft
Copilot Studio agents `MCS-OH` (legacy harness) and `MCS-NH` (GitHub Copilot harness).
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
- **[agent365-copilot-studio](../agent365-copilot-studio/SKILL.md)** — MCS-OH/MCS-NH (Copilot Studio).
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

### 1a. Choose the lab name (the solution prefix) — ask this EARLY
Ask the **lab name** up front (right after tenant/subscription, before selecting what to create). The lab
name IS the `solution.prefix`: it derives every agent name, every resource name, the custom-MCP
registrations and the per-run scaffold root `generated/<prefix>/`. State the rules BEFORE asking:
**lowercase letter first, lowercase alphanumeric only, 3–12 chars** (`^[a-z][a-z0-9]{2,11}$`), and it must
be **UNIQUE** — not a name a previous lab already used. Check for collisions before accepting it: an
existing `generated/<prefix>/` folder (a prior run on this machine), and — when the custom MCP is in
scope — an existing `ext_<prefix>*` in the tenant (`a365 develop list-available` / admin center). If taken,
ask for a different lab name. See [references/naming-and-validation.md](./references/naming-and-validation.md).

### 1b. Choose the secret-handling mode
Ask once, single-select, how the run should handle secrets (blueprint client secret, Azure OpenAI key):
- **Manual (default)** — you (the agent) never read, request, or echo any secret; you walk the user through
  fetching it (`a365 setup blueprint --show-secret`) and pasting it into the waiting terminal.
- **Assisted** (opt-in, for THROWAWAY test labs in test tenants) — the user authorizes you to obtain the
  blueprint secret non-interactively (from the `a365 setup all` log or `a365 setup blueprint --show-secret`)
  and supply it to the deploy without the manual paste. Even then you **never print a secret value in
  chat**, and you hand the user the rotation steps afterward.
Write `solution.secretHandling` (`manual` | `assisted`) and follow it exactly for the whole run.

### 2. Select what to create
Use the ask-questions tool (checkboxes, single-select). Do NOT ask fields one at a time.
1. **Variants** — multi-select of the 10 variants (mark DW/FH as "requires Frontier/Foundry"; MCS as "Copilot Studio, needs pac + a target env — MCS-NH needs PAYG/Copilot Credits").
2. **Companion UI** — single-select: *No UI* / *Create new UI* / *Attach to existing UI*.
   For **Attach to existing UI**, discover the existing web UIs by the `a365component=web-ui` tag
   (`az staticwebapp list` → keep `tags.a365component == 'web-ui'`) and let the user PICK one (record it
   into `ui.existing.staticWebApp`/`origin`/`spaAppId`); the scaffolder then merges each agent's tab
   surgically with `Add-WebUiTab.ps1` instead of regenerating `config.js`. If none is tagged, point the
   user to the **Web UI Creator** (or `Set-ComponentTags.ps1 -Retro`). See
   [agent365-web-ui/SKILL.md](../agent365-web-ui/SKILL.md).
3. If a UI is chosen — multi-select of the **OBO/S2S** agents to expose (exclude DW: they route via
   Teams/Outlook/Office, not the SPA — see [docs/setup-web-ui.md](../../../docs/setup-web-ui.md)).
4. **Custom MCP** (single-select): *None* / *Anonymous only* / *Authenticated only* / *Both* — the
   sample [custom-mcp/](../../../custom-mcp/README.md). If not None, **do NOT ask a name** (it derives
   from the solution prefix → `ext_<prefix>Anon` / `ext_<prefix>Auth`; the prefix must be ≤ 12
   alphanumerics), ask a publisher name, which **OBO** agents to attach to (`ACA-OBO`/`FH-OBO`/`FD-OBO`
   only — S2S/DW are blocked: they can't own the per-user Power Platform connection a BYO server needs;
   see custom-mcp/README.md), an **integration mode** (*approve-first* (default) = approve the servers before the
   agents, integrate each OBO immediately; *attach-when-approved* = agents first, integrate
   when approved else manually later), and whether to enable `propagate_to_graph` (advanced
   On-Behalf-Of Graph test; **default: enable**). Writes `customMcp` in the plan. The **prefix** is the unique per-copy key
   (Azure resources `<prefix>-mcp-*`, folder `generated/<prefix>/<prefix>-mcp/`, registrations all
   derive from it) — for N coexisting copies use a different prefix each run; check the tenant
   (`a365 develop list-available`) and ask again if `ext_<prefix>*` collides.
5. **Registered MCP tools** (per ACA-*/FH-* agent) — multi-select from `a365 develop list-available`
   (Work IQ `mcp_*` + custom `ext_*` + third-party). **Show ALL Work IQ servers but make only
   `mcp_MailTools` selectable today** (the rest visible-but-disabled, noting only tested tools are
   enabled for now); **offer Mail to OBO/DW agents only and pre-select it there**. **EXCLUDE every S2S
   agent from the Mail selection entirely** (do NOT list them as options) — state Mail / delegated Work IQ
   is **not available** for S2S today (`AADSTS82001`; feasibility still to be determined). Free-text allows other registered
   `uniqueName`s. Writes `agents[].tools` (FD stays `[]`); the scaffolder makes each manifest
   authoritative = these tools before `a365 setup all`, so permissions match the selection. Reuse the
   token lessons + the per-server permission map in
   [references/workiq-mcp-integration.md](./references/workiq-mcp-integration.md).
### 3. Solution basics (one screen)
- **Solution prefix / lab name** (e.g. `contoso`) — single value; all agent names derive from it as
  `<prefix>-<framework>-<hosting>-<identity>` where framework = `MAF` (fixed today), hosting ∈ {ACA, FH, FD},
  identity ∈ {OBO, S2S, DW}. **Before asking, EXPLAIN how the selected agents' names are composed** —
  show the structure and at least **two concrete examples** (e.g. `contoso-MAF-ACA-OBO`,
  `contoso-MAF-FH-S2S`) so the user sees the fixed framework segment — **and STATE the length rules**:
  start with a lowercase letter; lowercase letters and digits only (no hyphens/underscores/uppercase/symbols);
  **3–12 characters**. The 12-char cap is set by the custom MCP (`ext_<prefix>Anon/Auth ≤ 20`) and is
  **independent of the agent name** (it also satisfies ACA, RG, managed identity, Entra and SWA). **A
  Digital Worker lab lowers the cap** (e.g. **9** for `MAF-ACA-DW`) so the Teams `name.short` stays ≤ 30
  once the framework segment is added.
- **Naming mode** — single-select **Default names** / **Custom names** (`solution.namingMode`, default
  `default`). *Default* keeps the convention above. *Custom* lets you rename each **code** agent
  (ACA/FH/FD): present ONE screen listing every selected code agent with its **default name pre-filled**
  and an editable field to override it. ⛔ **STATE the naming rules to the user BEFORE the field** (a
  priori) — a custom agent name must:
  - **start with a letter**; contain **only letters, digits and hyphens** (no spaces/underscores/symbols);
  - have **no consecutive hyphens (`--`) and no trailing hyphen**;
  - for an **ACA** agent, keep the derived **Container App name (the lowercased name) 2–32 chars**;
  - for a **DW** agent (ACA-DW/FH-DW), be **≤ 20 chars** so the derived Teams `name.short` (`"<name> Blueprint"`)
    stays **≤ 30**.
  Write each override to `agents[].name` (and matching `displayNames`/`resourceGroup`). **MCS agents are
  NOT renamable** — they keep `<prefix>-MCS-<OH|NH>` so the Lab Cleaner can always compute + delete them.
  ⛔ **After collecting the names, verify them a posteriori**: run
  [scripts/scaffold-from-plan.ps1](./scripts/scaffold-from-plan.ps1) `-ValidateOnly` and, if it reports a
  name error, **show the offending name + rule and re-ask** — do not proceed until validation passes. The
  scaffolder ALWAYS emits a `Set-LabTags.ps1` command (durable lab tag, see step 8) — essential with custom
  names, still applied with default names for a consistent tag scheme.
- **Preferred region** — one value; validated per service during discovery.
- **Resource-group strategy** — single-select:
  - *Isolated (default)*: one RG per agent, `<agent-name>-rg`.
  - *Shared*: one RG `<prefix>-rg` (editable). For ACA this is allowed ONLY with resource-safe
    scripts or `-ReuseEnv` — see [references/naming-and-validation.md](./references/naming-and-validation.md).

### 4. Conditional questions (ask only what the selection requires)
Driven by [references/variant-matrix.md](./references/variant-matrix.md):
- Any **ACA** → **Azure OpenAI strategy** (`solution.azureOpenAI`), asked ONCE for the whole lab since
  all ACA agents share it: **(A) create one shared account + deployment** (`create-shared`, **the
  DEFAULT** — a lab-owned account `<prefix>aoai` + model in `<prefix>-aoai-rg`, deleted by the Lab
  Cleaner via the prefix like `<prefix>-foundry-rg`) **or (B) reuse an existing account + deployment**
  (`reuse-existing` — and ONLY then ask which existing account/deployment from discovery). Auth =
  **Managed Identity (default)** or API key (fallback, entered in the terminal, never chat). Omit
  `solution.azureOpenAI` to keep the legacy per-agent `ai` fields.
- Any **FH or FD** → **Foundry-resource strategy** (`solution.foundry`), asked ONCE for the whole lab
  since all FH + FD agents share it: **(A) create one shared account + project + model** (`create-shared`,
  the clean default — account/project `<prefix>` + `gpt-4.1` in `<prefix>-foundry-rg`, all FH/FD agents
  deploy into it) **or (B) reuse an existing account + project** (`reuse-existing` — the user gives the
  project endpoint; no provision). Prefer **reuse-existing** as a resilient fallback if a new-account
  hosted-agent deploy fails provisioning (`ProvisioningError`) — deploying into a known-good project
  sidesteps both a bad package build and a transient account state; see the FH skill's ProvisioningError
  note for the full root-cause analysis and the external reproduction playbook. **FH-DW keeps its own
  account** (Bot Service + blueprint bicep). FD-only labs must use reuse-existing. Legacy per-agent
  accounts still work if `solution.foundry` is omitted.
- Any **DW** (ACA-DW / FH-DW) → confirm Frontier/Agent 365 enrollment, license capacity, policy
  template choice. Surface the portal steps as verifiable checkpoints.
- **UI** → if exposing OBO: Mail consent (`McpServers.Mail.All`); if exposing ACA-S2S: blueprint
  scope + `UI_AUDIENCE`; if exposing **FH/FD** (Foundry-based, **not ACA**): who gets **Cognitive
  Services User** on the shared Foundry account. **Default: just the signed-in user** (convenient for a
  solo lab). **Explicitly signal that the answer also accepts a comma-separated list of UPNs** (multiple
  testers) **and/or a group object id** (recommended for many testers — grant once, manage membership in
  the group). Writes each entry to `ui.permissions.foundryAccess`; the scaffolder grants every one (the
  signed-in deploy user is always granted regardless).

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
[references/deployment-plan-schema.md](./references/deployment-plan-schema.md). The scaffolder also
**archives the plan per-run** to `generated/<prefix>/a365-deployment-plan.json`, so overwriting the root
plan on the next run never loses earlier plans (each unique lab name keeps its own copy).
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
- **⛔ ACA `a365 setup all` + `deploy-aca*.ps1` must run FROM the agent folder.** `a365 setup all`
  writes `a365.generated.config.json` (blueprint ids + secret) and stamps `.env` only via its "project
  settings" step, which runs **only when the CLI detects the project in the current directory** — run
  it from elsewhere and it prints *"No … project detected … skipping project settings"*, so the deploy
  can't find the blueprint id and `--show-secret` fails. A leading `cd` in an **async** terminal is
  silently dropped (runs from the repo root): set the cwd first (`Set-Location <agent-folder>`), run
  these sync, and verify `$PWD`. (The deploy scripts self-heal the blueprint id by display-name lookup
  as a backstop, but the correct cwd is still needed for `.env`/secret persistence.)
- **⛔ Detect `a365 setup` completion from the ARTIFACT, not the terminal.** After the browser admin
  consent, `a365 setup all` can **linger without flushing/exiting** — the terminal shows the same last
  line for minutes though it already succeeded. Do **not** keep re-reading the terminal buffer (it makes
  you look stuck). The authoritative signal is `a365.generated.config.json` in the agent folder: done
  when it exists with every `resourceConsents[].consentGranted == true`. Run `a365 setup all` async with
  `Tee-Object -FilePath <log>`, announce the browser gate once, then poll the **file** (not the buffer).
  A missing `.env`/`completed:false` does **not** block the deploy.
- **UI first, then integrate incrementally.** Stand up the SPA shell first (SWA + SPA app reg +
  placeholder `config.js`); then, as each OBO/S2S agent goes live, add its tab, redeploy the UI, wire
  `UI_ALLOWED_ORIGINS` (+ `UI_AUDIENCE` for ACA-S2S), and tell the user they can test it now.
- **⛔ MANDATORY BLOCKING test gate after each agent (HARD STOP, not optional).** The moment an agent
  is live (and, for OBO/S2S, its tab is wired), and **before touching the next agent in any way**
  (env setup, `azd`, `a365 setup`, `Set-Location`, or even a "next I'll deploy X" message), present the
  **interactive** single-select gate `[ Test now | Continue ]` and WAIT for the answer. **One gate per
  agent, every agent** (OBO/S2S/DW) — N agents ⇒ N gates. Never batch or skip: before the FIRST command
  of the next agent, confirm the current agent's gate was shown and answered; if not, STOP and show it.
  (Violated once with FH-S2S — must not recur.) Skip ONLY when no test surface exists: OBO/S2S only if a
  UI is present for that agent (UI mode `create`/`attach` + exposed as a tab); DW always (Teams). On
  **Test now**, print the exact per-MCP test prompts for THIS agent (from its `tools` +
  `customMcp.attachTo`, using the library [references/test-prompts.md](./references/test-prompts.md)) and
  where to run them — see the agent's "After each agent goes live" section (OBO custom-auth `whoami` must
  return `authorization_token_forwarded: true`; **S2S: never ask the LLM to describe its own identity —
  it hallucinates — use an identity-agnostic prompt**).
- **Progress log.** Append timestamped English lines to `generated/wizard-progress.log` (gitignored)
  at every state change; tell the user to watch that file. Never end a turn with a vague "I'll resume."
- **Durable lab tag (ALWAYS).** Run
  [scripts/Set-LabTags.ps1](./scripts/Set-LabTags.ps1) **after each agent's deploy AND again on resume**
  (it is idempotent): it stamps `a365lab=<prefix>` on lab-owned Azure RGs and `a365lab:<prefix>` on
  lab-owned Entra apps + SPs so the Lab Cleaner discovers the lab **by tag**. It is ESSENTIAL with custom
  names (which may not contain the prefix) and still applied with default names so the tag scheme is
  consistent (a lab-owned UI/MCP carries `a365lab`, so the "standalone = `a365component` without
  `a365lab`" discriminator is always correct). Tag as EARLY as each resource exists — do not defer to
  "when the whole lab is live" — because the Lab Cleaner must also delete half-created labs. It never tags
  a `reuse-existing` / user-owned shared account.
- **Blocking prompts (secret / y-N / endpoint / azd login).** Beep (`[console]::beep(880,400)`),
  show a bold ⛔ ACTION REQUIRED banner naming which terminal (and how to focus it via the Terminal
  panel dropdown / `N Hidden Terminals`), what to type, and where to get the value
  (`a365 setup blueprint --show-secret`). Secrets are typed by the user, never relayed. ⛔ **Never pipe
  an interactive `a365` command through `| Out-String`** — it buffers all output and hides the `y/N`
  prompt, so the command looks hung for minutes (the top time-waster). Stream it (no pipe, or
  `Tee-Object -FilePath` alone) and answer: `register-external-mcp-server` → `Proceed? (y/N)` = `y`
  (empty Enter = **N** = cancelled); `setup all` → `Assign … [y/N]` = `y`. No `--yes` flag exists.
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
