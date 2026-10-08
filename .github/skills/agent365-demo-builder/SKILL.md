---
name: agent365-demo-builder
description: 'Build a complete, repeatable Agent 365 demo environment from a demo pack (default: agent-governance) in any tenant and in a selectable language (en, it, fr, es, de): personas, groups, photos, knowledge, demo MCP servers, the lab agents (through the Lab Builder engine), governance objects, guided manual cards and the test hand-out. Use when the user wants to recreate the governance demo, build the demo environment, set up the demo in another tenant or language, or prepare the demo before a rehearsal. Trigger phrases: build the demo, recreate the demo, demo environment, demo pack, Demo Builder, set up the governance demo.'
argument-hint: 'A lab prefix (max 9 lowercase letters/digits), the pack (default agent-governance) and the language'
---

# Agent 365 Demo Builder

Recreates a whole demo (people, content, agents, governance, starting conditions) from a **demo pack** in
[demo-packs/](../../../demo-packs/): a language-neutral `pack.json` plus one folder of visible texts per language
(`locales/<lang>/core.json`, `knowledge.json`, `tests.json`). The skill is thin on purpose: every agent is built by the
**Lab Builder engine** ([lab-builder.agent.md](../../agents/lab-builder.agent.md) and the
[agent365-wizard](../agent365-wizard/SKILL.md) skill) from a plan that this skill generates; the demo-specific parts
(identities, knowledge, demo MCP servers, governance, cards) are the scripts below. Sibling skills:
[agent365-demo-reset](../agent365-demo-reset/SKILL.md) (starting conditions, rehearsals) and
[agent365-demo-guide](../agent365-demo-guide/SKILL.md) (running the demo).

> **Preview, not yet validated end to end**: checked offline and read-only against a real tenant; a complete build with
> `-Apply` in a new tenant has not been run yet. Dry-run every phase first.

## Binding rules

- **Every persisted file is in English.** The only exception are the locale files of a pack, which hold the visible
  texts of the demo; generated cards are English instructions with the localized values inserted.
- **The license gate is first** (`Test-DemoPrereqs.ps1`, [docs/demo-environment-prerequisites.md](../../../docs/demo-environment-prerequisites.md)):
  nothing is created in a tenant that fails it.
- **Operator slots are never printed.** A few test inputs of the protection demos are not part of the repository:
  they are operator slots (`slot-1`...`slot-5`), filled by the operator in `generated/<prefix>/demo/operator-slots.json`
  from [OPERATOR-SLOTS.md](../../../demo-packs/agent-governance/OPERATOR-SLOTS.md). Scripts only check that the file
  is complete; chat, logs and cards refer to those demos by code (C6, C7, D16, D17) and to the inputs by slot id.
- **Iron naming rules** of the Lab Builder ([text-limits.json](../agent365-wizard/references/text-limits.json),
  `Test-A365Names.ps1`) are checked before anything is registered; `Test-DemoPack.ps1` validates a whole locale.
- **Demo MCP server and tool names are tenant-wide.** One demo lab per tenant and language; a second lab in the same
  tenant uses `-ServerName` and blocks the first lab's servers first (New-DemoMcpRegistration.ps1 header).
- **Actions that a demo shows are done by the story persona in the portal** (approvals, blocks, their audit trail);
  scripts do only the setup that no demo shows and verify by read-back. A preparation step that is itself a demo
  moment (for example the D8 reassignment rule) is done live.
- **Blocking vs non-blocking user actions.** Stop and ask (questions tool) ONLY for a blocking action: one without
  which the next automated step cannot run (an interactive sign-in or consent in progress, the admin approval of the
  demo MCP servers before they are attached to agents, a terminal prompt, missing information). Every other user
  action is recorded in the **user-actions register** (below) with the step that first needs it, and the build goes
  on. Guided card steps are still given **one step per turn** when the user asks to be guided through a card.
- **User-actions register** `generated/<prefix>/demo/USER-ACTIONS.md` (English, gitignored), WRITTEN BY THE SCRIPTS
  from `user-actions.json` (helpers in `_demo-common.ps1`), so it is the same whatever agent or model runs the build:
  - `Invoke-DemoPhase.ps1 -Apply` records every `manual`/`terminal` step of bootstrap, setup and interactive, with
    `neededBy` (cards: the pack demos of their agents or portal) and `blocking`; `-Done <step>` marks the row DONE.
  - The scripts record their own manual actions: `Test-DemoPrereqs.ps1` (one row with the MANUAL checks),
    `Set-DemoIdentities.ps1` (Purview role groups), `Publish-DemoKnowledge.ps1` (personal file),
    `New-DemoMcpRegistration.ps1` (the BLOCKING approval row, DONE when no long-lived server is pending; the per-user
    connection URLs), `New-DemoLabPlan.ps1` (row `agent-smoke-tests`: one test prompt per lab-built agent on its
    surface, because the Lab Builder per-agent test gate is not a blocker in a demo build).
  - The agent adds ONLY what no script knows (for example a Lab Builder package to upload, a
    check found during the build) with `Set-DemoUserAction.ps1 -Prefix <p> -Key <key> -Action ... -Where ...
    -NeededBy ... [-Blocking]`, and marks such rows with `-Status DONE` after the verification. Never edit the Markdown
    file by hand; `Set-DemoUserAction.ps1 -List` prints the register.
  - Format: header (tenant, subscription, web UI URL, legend, cards) and one table `| # | Status | Action | Where /
    how | Needed by |`; ids `A1`, `A2`... are never renumbered and DONE rows are kept; status TODO, DONE or
    **BLOCKING**; exact URLs, file paths and accounts, never a secret and never the content of an operator slot.
  - At the end of the build, and whenever the user asks, present the whole register in chat (in the user's
    language), after the summary of what exists.
- **Never duplicate the Lab Builder.** Extend it generically (overlays, `ext_` tools, display names, `-Server`
  options of the custom-mcp helpers) and reference its documents instead of copying them.
- **The Lab Builder is not changed for a demo's needs** (user rule, 28/09): it only gets generic, backward-compatible
  extension points and fixes of its own bugs. Everything demo-specific lives here: for example
  `Set-DemoAoaiCapacity.ps1` resizes the shared Azure OpenAI deployment after the Lab Builder created it with its
  default capacity. The web-UI telemetry of the ACA agents (usage, exceptions and map in the registry) needs the Lab
  Builder samples with the observability fix of the `/chat` path (in `main` since PR #1).
- **Verify first.** Before every configuration step read the existing configuration of the tenant (read-only) and
  reuse what is already there; after it, verify by read-back.
- **Announce every interactive sign-in** before it starts (a browser tab will open) and say which account got signed in.
- **Setup or demo moment.** Cards and scripts are setup (not recorded); the steps of the run of show are demo moments,
  done live by the story persona.
- Secrets never reach the repository: MSAL caches live in `generated/<prefix>/demo/secrets/` (gitignored), the
  temporary automation app is deleted at the end of each run.

## Scripts (`scripts/`)

| Script | Does | Writes to the tenant |
|---|---|---|
| `New-DemoConfig.ps1` | per-lab config (tenant, language, domain, environments, license SKUs or bundles `SKU1+SKU2`, Teams for all, lab-private az profile; an event date is optional and informational) | no |
| `Test-DemoPrereqs.ps1` | license gate (seats per SKU, bundles) + prerequisites + operator roles + prefix collision (read-only) | no |
| `Test-DemoPack.ps1` | validates the pack and the locale; `-OperatorSlots` checks the operator file | no |
| `Set-DemoIdentities.ps1` | personas, groups, licenses, Entra roles, managers (`-WhatIf` first) | yes |
| `Set-DemoPhotos.ps1` | profile photos of the personas | yes |
| `New-DemoKnowledge.ps1` / `Publish-DemoKnowledge.ps1` | fictional documents (docx/pdf/xlsx) and their SharePoint library | yes (publish) |
| `Deploy-DemoMcp.ps1` | demo MCP backends on Container Apps (`<prefix>-demomcp-rg`) | Azure |
| `New-DemoMcpRegistration.ps1` | registration payloads + command, consents, BYO audiences, connection URLs, pool | yes (Confirm) |
| `New-DemoLabPlan.ps1` | Lab Builder plan + agent overlays (`-ValidateOnly`, `-Scaffold`) | no |
| `Set-DemoGovernance.ps1` | custom security attribute, owners/sponsors/attributes of agent identities, catalog | yes |
| `New-DemoCards.ps1` | guided cards (`references/cards/`) + test hand-out, in `generated/<prefix>/demo/cards` | no |
| `Invoke-DemoPhase.ps1` | runs a phase in order (dry run unless `-Apply`), keeps the progress in state.json, `-Done <step>` for manual steps | as its steps |
| `Set-DemoAoaiCapacity.ps1` | sizes the shared Azure OpenAI deployment for the demo traffic (quota pre-check); `-Check429` counts throttled requests | Azure |
| `Publish-DemoMcsAgent.ps1` | checks that the Copilot Studio agents are really published (Dataverse `publishedon`, synchronization state); `-Publish` publishes through Dataverse when Copilot Studio silently did not (never the agents whose starting state is a pending request or a block, unless `-Force`) | only with `-Publish` |
| `Set-DemoUserAction.ps1` | adds/updates one row of the user-actions register (actions no script knows), `-List` prints it | no |
| `Install-DemoPythonDeps.ps1` | bootstrap step `python-deps`: installs the missing packages of `py/requirements.txt` (user site) | no |
| `Set-DemoFoundry.ps1` | bootstrap step `foundry`: Foundry project for FD-only packs (Lab Builder `New-FoundryProject.ps1`), config switched to reuse-existing | Azure |
| `Get-DemoPersonas.ps1` | read-only table of the demo people (persona, user, job title, Entra roles read back, other roles) → `personas.md`; required in the hand-over | no |

Shared helpers: `_demo-common.ps1` (pack, locale, config, state, tokens, Graph, user-actions register), `_demo-entra.ps1` (agent identities,
temporary app-only session). Offline tests: `test-demo-user-actions.ps1` (register) and `test-demo-helpers.ps1`
(license bundles, lab-private az profile, config persistence, reserved knowledge folder names): run them after changing
those helpers.

## The localization dictionary

Everything the audience or the tenant sees is localized: organization, departments, offices, job titles, persona names
and aliases, group and site names, agent names, descriptions and instructions, Digital Worker instance, MCP server,
tool and parameter names and their data, governance object names (attribute set and values, Conditional Access
policies, catalog, access package, labels, policies, templates, tags), knowledge folders and documents, prompts and
expected results. The dictionary is the locale folder of the pack (`core.json`, `knowledge.json`, `tests.json`); the
default locale (`defaultLocale` of pack.json) is the reference. `Test-DemoPack.ps1` fails when a locale misses a key of
the reference or adds one, when a placeholder does not resolve, or when a name breaks the iron rules. Only operator
texts (cards, logs, run of show) stay in English.

## Phases of a demo lab

The first question of the interview is the **language**: every generated name comes from it. The phases are run with
`Invoke-DemoPhase.ps1 -Prefix <p> -Phase <phase>` (dry run first, then `-Apply`); `-Phase status` shows the progress.
Start at least **five days** before the first event or rehearsal that uses the lab: several effects need hours or a day
(`timeline` of pack.json). A lab is often the base of several events: no event date is asked.

| Phase | What | Who |
|---|---|---|
| 0. Interview | runtime-model gate; **language**; tenant + subscription (confirm, pin, assert, as the Lab Builder does); **lab-private az profile** (recommended when other sessions run on the machine: `-IsolatedAzProfile`, then the interactive `az login` in that profile); prefix (`^[a-z][a-z0-9]{2,8}$`; the bootstrap gate refuses a prefix contained in foreign resource group names), domain, admin UPN, region, Copilot Studio environments (pay-as-you-go and default), Foundry mode, license SKUs (a bundle `SKU1+SKU2+...` when the tenant has no single SKU for a role; `-TeamsForAllPersonas`) → `New-DemoConfig.ps1` | agent + user |
| 1. bootstrap | license gate and prerequisites (operator roles, prefix collision); pack and locale check; Python packages; Foundry project (FD-only packs); users, licenses (bundles, conflicting mailbox plans disabled), roles (the operator's attribute roles too), managers, groups; photos (lab or shared folder, missing = a user action) | scripts |
| 2. setup | knowledge (build, publish); demo MCP backends; registrations (automatic: `-Run` answers the a365 prompt and confirms); **admin approval of the demo MCP servers (BLOCKING: the runner stops there)**; agents through the Lab Builder engine (plan, scaffold, then a Lab Builder **resume** of the prefix; the runner stops there too; the agent outside the plan uses `outside-plan.json`); Azure OpenAI sizing; governance by script; cards and run of show | scripts + agent |
| 3. interactive | per-user connection URLs BEFORE the tests, the portal cards (Copilot Studio, Agent Builder agents created by their personas, Digital Worker instance created from Teams, Foundry, Entra, Purview, Defender, admin center), identities refresh, the test hand-out, the pre-flight | user + personas, verified by script |
| 4. use | the demo itself, outside this agent: [agent365-demo-guide](../agent365-demo-guide/SKILL.md) | presenters |
| 5. restore | pre-flight, reset of what the demos change (owners, blocks, assignments, the MCP pool; leavers recreated and deleted again), manual resets: [agent365-demo-reset](../agent365-demo-reset/SKILL.md) | scripts + user |
| 6. teardown | the Lab Cleaner, then the extras of the pack README (see below) | user |

Log every step with `Write-DemoLog` (it also appends to `generated/<prefix>/wizard-progress.log`).

## Where things are

- Per lab (gitignored): `generated/<prefix>/demo/` → `demo-config.json`, `USER-ACTIONS.md` (user-actions register),
  `state.json` (users, groups, knowledge, MCP
  backends/servers/pool, governance), `overlays/`, `outside-plan.json`, `knowledge/`, `mcp-build/`, `mcp-registration/`,
  `cards/`, `operator-slots.json`, `secrets/`; the Lab Builder plan is `generated/<prefix>/a365-deployment-plan.json`.
- Azure: the lab resource groups tagged `a365lab=<prefix>`; the demo MCP backends in `<prefix>-demomcp-rg`
  (`a365component=demo-mcp`, not `custom-mcp`: that tag means the Lab Builder sample pair).

## Teardown

The [Lab Cleaner](../../agents/lab-cleaner.agent.md) removes everything tagged with the lab (resource groups,
including `<prefix>-demomcp-rg`, Entra apps, agents, licenses). The demo extras are listed in
[demo-packs/agent-governance/README.md](../../../demo-packs/agent-governance/README.md#teardown): personas and groups,
the catalog and the access package, the Conditional Access policies, the admin-center templates and tags, and the
`ext_` servers, which cannot be deleted (Reject or Block them). Custom security attributes cannot be deleted either:
deactivate their values.
