---
name: agent365-copilot-studio
description: >-
  Provision, publish and remove the Microsoft Copilot Studio (MCS) sample agents — MCS-OH (legacy
  standard harness) and MCS-NH (new GitHub Copilot harness) — from committed base solution zips, via the
  Power Platform CLI (pac), including cross-tenant import. USE WHEN the user wants to create/deploy an MCS
  agent, re-extract the base solutions from a source tenant, verify a target Copilot Studio environment's
  prerequisites (Dataverse / PAYG / Copilot Credits), optionally attach A365 tool-gateway MCP tools
  (Mail / custom Anon-Auth), publish org-wide, or tear an MCS agent down. Trigger phrases: 'Copilot Studio
  agent', 'MCS-OH/MCS-NH', 'import solution to Copilot Studio', 'new harness / legacy harness agent',
  'pac solution import', 're-extract base solution'. Sub-skill of the Lab Builder.
---

# Microsoft Copilot Studio (MCS) agents — sub-skill

MCS agents are **not** Azure/Entra agents. They are **Power Platform Solutions** (Dataverse) imported into
a **Copilot Studio environment** with the Power Platform CLI (`pac`). Two harnesses:

| Variant | Harness | Template | Base zip | Prerequisites |
|---------|---------|----------|----------|---------------|
| **MCS-OH** | legacy standard | `default-2.1.0` | `AgentOHSol.zip` | **none** beyond a Dataverse env |
| **MCS-NH** | GitHub Copilot | `cliagent-1.0.0` | `AgentNHSol.zip` | Dataverse **+ PAYG / Copilot Credits** |

Naming (Lab Builder): `<lab-name>-MCS-OH`, `<lab-name>-MCS-NH` (3-part: `<prefix>-MCS-<OH|NH>`; MCS carries
**no** `MAF` framework segment — it is not a code framework).

The two **base solution zips** in [assets/base-solutions/](assets/base-solutions/) are the creation base
for every MCS agent (captured from a source tenant; re-extract with `Export-McsBaseSolution.ps1`). We do
**not** regenerate them per run — we transform (rename) and import them.

## Golden rules
- **`pac` is required.** Install once: `dotnet tool install --global Microsoft.PowerApps.CLI.Tool`
  (`Get-PacCli -Install`). If the user selects an MCS agent and pac is missing → install it or drop MCS.
- **Cross-tenant = two pac auth profiles** (`pac auth create --name <n> --tenant <id>`, `--tenant` explicit
  because the source tenant is often NOT the usual one).
- **Import target env MUST have Dataverse.** An env showing "Add Dataverse" in PPAC has none — `pac env
  list` won't show it and import fails. Add Dataverse (PPAC), wait Ready, retry.
- **MCS-NH gate:** before creating an NH agent, confirm the target PP environment is **PAYG + Dataverse +
  Copilot Studio** and get its **Environment ID**; verify with `Test-McsPrereqs.ps1 -Harness MCS-NH
  -EnvironmentId <id>`. Without credits the agent fails at preview with `EnforcementUsageCredits`. **MCS-OH
  has no such prerequisite.**
- **Rename the DISPLAY name + the bot SCHEMA token.** The Lab Builder wizard now passes `-IsolateSchemaName`
  so every MCS agent gets a UNIQUE bot schema (derived from its solution unique name) — required so 2+
  same-harness agents in ONE environment become distinct bots instead of colliding on the shared base
  token (`new_AgentOH2` / `cr47b_agentnh2_URxM4c`) at import. The solution unique+friendly name is always
  rewritten too. (Manual `New-McsAgent.ps1` runs still default to display-name-only unless you pass
  `-IsolateSchemaName`; this only governs the bot schema, NOT where Copilot Studio stores per-env settings
  such as the Application Insights connection string, which live at environment/service scope.)
- **Secrets never in chat.** The MCP client-app secret is written to a gitignored `*.secret.txt` file, never
  printed. Do not read it back.
- **STOP before any cross-tenant import** and confirm the target tenant/environment with the user.

## Scripts (durable — do NOT regenerate agent code each run)
All under [scripts/](scripts/); dot-source `_mcs-common.ps1` for shared helpers.
- **`_mcs-common.ps1`** — base catalog (`$MCS_BASE`), `Get-PacCli`/`Assert-PacCli` (install-or-fail),
  `New-RenamedMcsSolution` (unpack -> rename display/solution [+optional schema] -> pack).
- **`New-McsAgent.ps1`** — the engine: transform a base zip -> `pac solution import --publish-changes` into
  the target env; runs the NH prereq gate; `-Publish` prints the guided org-wide publication step;
  `-ScaffoldOnly` produces the zip without importing; `-InstallPac` installs pac.
- **`Test-McsPrereqs.ps1`** — given an Environment ID + harness, verify Dataverse (hard), PAYG billing
  policy (NH, via `pac licensing get-environment-billing-policy`), Copilot Studio (best-effort).
- **`Export-McsBaseSolution.ps1`** — RE-EXTRACT the base zips from a source tenant (`pac solution export`,
  which bypasses the maker-portal "Async operations disabled" error). Uses the solution UNIQUE name.
- **`New-McsMcpClientApp.ps1`** — create the Entra client app + ATG delegated permission + admin consent
  for the optional MCP tool integration; prints OAuth values for the Copilot Studio MCP wizard.
- **`Remove-McsAgent.ps1`** — delete the solution (`pac solution delete`) and the agent. Pass
  `-DisplayName <agent>` and it **auto-discovers the bot GUID** (Dataverse `bots` query with an az token —
  az must be logged into the target tenant) then runs `pac copilot-studio delete-copilot-agent`; or pass
  `-BotId` directly. Removal is **surgical** (single agent) and supports `-WhatIf`. Used by the Lab
  Cleaner.

## Create an MCS agent (end to end)
1. Ensure pac (`Get-PacCli -Install`).
2. **MCS-NH only:** confirm + verify the target env: `Test-McsPrereqs.ps1 -Harness MCS-NH -EnvironmentId
   <id> -Tenant <target>`. Abort if BLOCKED.
3. Create: `New-McsAgent.ps1 -Harness MCS-OH|MCS-NH -DisplayName <name> -Tenant <target> -EnvironmentId
   <id> [-Publish]`. It transforms the base zip, auths to the target tenant (browser sign-in), imports +
   publishes, and (with `-Publish`) prints the org-wide availability step.
4. **Optional MCP tools** (guided): `New-McsMcpClientApp.ps1 -Tools Mail[,Anon,Auth] -Tenant <target>
   [-McpPrefix <prefix>]`, then add the MCP tool in Copilot Studio (Tools -> Add a tool -> Model Context
   Protocol -> OAuth 2.0 Manual) with the printed values. Mail is tested; Anon/Auth are experimental
   (see [references/mcp-integration-feasibility.md](references/mcp-integration-feasibility.md)).
5. **Publish org-wide:** in Copilot Studio open the agent -> reconfigure user auth if prompted -> Publish
   -> Channels -> Teams and Microsoft 365 Copilot -> **Availability options -> Show to everyone in my org**.

## Post-import manual steps (do NOT transfer with the solution)
Reconfigure user authentication per agent, re-add icon/description if needed, republish for channels,
and (NH) confirm PAYG covers the env.

## Observability (Application Insights)
MCS agents are **not** OTEL code agents — they get telemetry by **connecting an Azure Application Insights
resource to each agent IN Copilot Studio** (a per-agent portal step; there is NO Azure env var / Foundry
project connection like the ACA/FH families). This is wired only when the Lab Builder plan sets
`solution.observability.appInsights` (mode `create-shared` | `reuse-existing`); with `none` (default) it
is skipped, and the scaffolder emits a durable **MCS manual gate** next-command per agent:
1. In the **Azure** tenant, read the resource's connection string:
   `az monitor app-insights component show --app <name> -g <rg> --query connectionString -o tsv`.
2. In **Copilot Studio** ([copilotstudio.microsoft.com](https://copilotstudio.microsoft.com), the **target**
   tenant), open the agent → **Settings → Advanced → Application Insights** → paste the **Connection string**
   → optionally enable **Enable logging** / **Log conversation details** → **Save**.
- **Cross-tenant is fine**: the App Insights resource lives in the Azure tenant while the agent lives in the
  Copilot Studio target tenant — the connection string is just an instrumentation key + ingestion endpoint,
  so the **same lab App Insights** can serve ACA/FH **and** MCS.
- **Harness support**: connecting App Insights via **Settings → Advanced** is documented for the **standard
  harness (MCS-OH)**; for **MCS-NH** (new GitHub Copilot harness) it is **experimental** (same caveat as the
  custom MCP tools).
- For richer dashboards, the connected resource also feeds the Copilot Agent Kit **Agent Insights Hub**
  (an optional Dataverse/Power Platform add-on, out of scope here).

## Lessons (verified this session — keep)
- Maker-portal export error "Async operations are currently disabled for this organization" ->
  `pac solution export` bypasses it (synchronous path).
- `pac solution export/import --name` uses the solution UNIQUE name (`AgentOHSol`), not the friendly name.
- Display-name occurrences: OH = bot.xml `<name>` + the `.gpt.default` botcomponent.xml `<name>` + its
  `data` `displayName:`; NH = bot.xml `<name>` only. Schema tokens: OH `new_AgentOH2`, NH
  `cr47b_agentnh2_URxM4c` (never change unless `-IsolateSchemaName`).
- `pac solution import --path <zip> --environment <orgUrl> --publish-changes` imports without switching the
  active profile.
- MCS-NH `EnforcementUsageCredits` = env not linked to PAYG / no Copilot Credits. MCS-OH never hits this.

Canonical references: [references/system-instructions.md](references/system-instructions.md),
[references/mcp-integration-feasibility.md](references/mcp-integration-feasibility.md). The cross-tenant
lessons also live in workspace memory `repo/copilot-studio-cross-tenant.md`.
