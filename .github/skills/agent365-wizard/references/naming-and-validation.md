# Naming & validation rules

## Agent name scheme
Derive every agent name from a single **solution prefix** plus a **fixed `<framework>` segment**:

```
<prefix>-<framework>-<hosting>-<identity>
   framework ∈ { MAF, … }   (fixed segment; today only MAF — LangChain/Semantic Kernel/… later)
   hosting   ∈ { ACA, FH, FD }
   identity  ∈ { OBO, S2S, DW }
```

The `<framework>` segment is **mandatory** and part of the name for **every** agent: it keeps a
same-type agent built with a different framework (e.g. a LangChain `ACA-OBO`) distinguishable from the
MAF one. In the plan it is `agents[].framework` (default `MAF`); the plan `type` stays the hosting-identity
variant (`ACA-OBO`, …) and the name is composed as `<prefix>-<framework>-<type>`.

Examples for prefix `contoso`: `contoso-MAF-ACA-OBO`, `contoso-MAF-FH-S2S`, `contoso-MAF-FD-OBO`.

### Derived names (never ask — show on the review screen, editable)
| Derived | Rule | Example |
|---------|------|---------|
| Blueprint display name (OBO/S2S) | `<agent-name> Blueprint` | `contoso-MAF-ACA-OBO Blueprint` |
| Blueprint display name (**DW**) | `<agent-name>` (**no** `" Blueprint"` suffix; `name.short` ≤ 30) | `contoso-MAF-ACA-DW` |
| Identity display name  | `<agent-name> Identity`  | `contoso-MAF-ACA-OBO Identity` |
| Container app name (ACA) | lowercase, hyphens | `contoso-maf-aca-obo` |
| Resource group (isolated) | `<agent-name>-rg` | `contoso-MAF-ACA-OBO-rg` |
| Resource group (shared)   | `<prefix>-rg` | `contoso-rg` |
| SPA app registration | `<prefix>-ui-spa` | `contoso-ui-spa` |
| Static Web App | `<prefix>-ui` | `contoso-ui` |
| Web-fetch MCP (only when the plan has FD agents) | RG `<prefix>-webfetch-rg`, env `<prefix>-webfetch-cae`, app `<prefix>-webfetch-ca` | `contoso-webfetch-ca` |

> **Scaffold output lives under one per-run root: `generated/<prefix>/`.** Every folder for a run — each
> `<agent-name>`, the `<prefix>-ui` web UI, the `<prefix>-mcp` custom MCP and (FD labs) the
> `<prefix>-webfetch` web-fetch MCP with its verified URL file `web-fetch-mcp-url.txt` — is created under it (e.g.
> `generated/contoso/contoso-MAF-ACA-OBO/`). The run's plan (`a365-deployment-plan.json`) and its
> progress log (`wizard-progress.log`) are **also per-lab, under `generated/<prefix>/`**, so parallel
> runs never collide. Only cross-run outputs (`generated/cleanup/`, `generated/lab-reporter/`) stay at
> the `generated/` root.

### Registry display name — the `" Agent"` suffix (cosmetic, not controllable)
The a365 CLI lists ACA agents in the Registry with a trailing `" Agent"` (e.g. `a1730-MAF-ACA-OBO` is
shown as **`a1730-MAF-ACA-OBO Agent`**). This is added by the CLI at registration time, not by our
`a365.config.json`, and does not affect the blueprint (`… Blueprint`) or identity (`… Identity`)
names. Do not attempt to strip it via the plan — it cannot be set there.

### DW visibility in the Registry
ACA-DW and FH-DW do **not** auto-appear in the Registry like OBO/S2S. ACA-DW becomes visible only
after `a365 publish --aiteammate --agent-name "<name>"` regenerates `manifest/manifest.zip` for THIS
blueprint and the user uploads it in the M365 admin center (Agents → Upload custom agent), then a user
hires it in Teams. FH-DW appears after the admin-center approval of its azd-published request.

### FH-DW naming (different from the others)
The FH-DW sample hardcodes the agent name in **Bicep and scripts** (not `azure.yaml`). The scaffolder
rewrites every occurrence to the planned name `<prefix>-MAF-FH-DW`. If a pre-existing lab agent (e.g.
`sample-fh-dw-agent`) is reused instead of a clean provision, the Registry will show the old
name — verify the deployed agent matches the planned `<prefix>-MAF-FH-DW`.

## HARD validation rules (block, don't warn)
1. **DW `name.short` ≤ 30 characters.** Teams/M365 rejects a `name.short` **above 30 chars**, and
   `a365 publish` derives `name.short` from the blueprint display name — while `a365 setup all
   --agent-name <name>` auto-derives that display name as **`"<name> Blueprint"`**. Verified in
   [docs/setup-MAF-ACA-DW.md](../../../../docs/setup-MAF-ACA-DW.md). So for a DW agent: (a) set
   `displayNames.blueprint` = the agent name **without** the `" Blueprint"` suffix (`<prefix>-<framework>-<hosting>-DW`),
   and (b) keep the prefix short enough that even the auto-derived `"<name> Blueprint"` stays ≤ 30 —
   this is enforced by the **dynamic prefix cap** in rule 1a. With the fixed `<framework>` segment the
   worst case is `<prefix>-MAF-ACA-DW Blueprint`, so an ACA-DW lab caps the prefix at **9**.
1a. **Lab name (the solution prefix): lowercase letter first, lowercase alphanumeric only, 3–12 chars**
   by default (`^[a-z][a-z0-9]{2,11}$`), **lowered dynamically for a DW lab** (see below), enforced in
   `scaffold-from-plan.ps1`. Presented to the user as the **lab
   name** and asked **early** (right after tenant/subscription), because it derives every agent name,
   every resource name, the custom-MCP registrations and the per-run root `generated/<prefix>/`. The
   **12-char base cap is set by the custom MCP** — it is **independent of the agent name** (adding the
   `<framework>` segment does NOT change it): Agent 365
   registers `ext_<prefix>Anon` / `ext_<prefix>Auth`, which must stay **≤ 20 chars** (`4 + prefix + 4`)
   and are **alphanumeric** (no hyphens/underscores). That also covers Azure Container Apps (2–32,
   lowercase, start-with-a-letter — a prefix like `1730` would make the invalid container `1730-maf-aca-obo`),
   managed identities, resource groups, the Entra apps and the Static Web App. **A DW lab lowers the cap**
   so the DW `name.short` (rule 1) stays ≤ 30 once the `<framework>` segment is added: the scaffolder
   computes `30 − len("-<framework>-<hosting>-DW Blueprint")` per DW agent and takes the strictest
   (e.g. **9** for `MAF-ACA-DW`, **10** for `MAF-FH-DW`). It must also be **UNIQUE**
   — not a name a previous lab used: check for an existing `generated/<prefix>/` folder (a prior run on
   this machine) and, when the custom MCP is in scope, an existing `ext_<prefix>*` in the tenant
   (`a365 develop list-available` / admin center); ask for a different lab name if taken. **State these
   rules to the user before asking for the lab name.** MS Learn:
   [Azure resource naming rules](https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules#microsoftapp).
1b. **Naming mode (`solution.namingMode`): `default` (or omitted) vs `custom`.** `default` enforces the
   fixed convention `<prefix>-<framework>-<hosting>-<identity>` (rule 1a — byte-identical to before).
   `custom` lets each **code** agent (ACA/FH/FD) carry a **free-form `name`** (with matching
   `displayNames`/`resourceGroup`). A custom name is validated against **every rule the derived resource
   names impose** (the wizard MUST state these to the user *before* asking, and re-check them *after* via
   `scaffold-from-plan.ps1 -ValidateOnly`):
   - **starts with a letter**; **letters, digits and hyphens only** (no spaces/underscores/symbols);
   - **no consecutive hyphens (`--`) and no trailing hyphen** (Azure Container Apps / resource names reject them);
   - **ACA**: the derived Container App name (the lowercased name) is **2–32 characters**;
   - **DW** (ACA-DW/FH-DW): the name is **≤ 20 characters** so the derived Teams `name.short`
     (`"<name> Blueprint"`, from `a365 setup all --agent-name <name>`) stays **≤ 30** (rule 1). In `custom`
     mode the scaffolder omits `--agent-name` (it would make a365 ignore `a365.config.json` and derive
     `"<name> Blueprint"` / `"<name> Identity"` / `"<name> Agent"`): a365 then uses `displayNames.blueprint`
     (≤ 30, no `" Blueprint"` suffix for a DW) and `displayNames.identity` from the agent folder's config. Without
     `--agent-name` a365 does not resolve `clientAppId` either: the emitted command runs
     `Set-A365ClientAppId.ps1` first (the tenant's "Agent 365 CLI" app id, read-only, current az profile).
   **MCS agents are renamable in `custom` mode, but only the Copilot Studio DISPLAY name is free-form**
   (validated for structure: starts with a letter; letters/digits/hyphens only; no `--`/trailing hyphen).
   The scaffolder keeps the **solution unique name prefix-derived** (`<prefix>MCS<OH|NH>[<n>]`) and the bot
   schema isolated, so the Lab Cleaner's **prefix fallback** (solutions matching `<prefix>MCS*`) still finds
   and deletes them from the lab name alone — even without the `generated/<prefix>/` folder. In `default`
   mode MCS keep `<prefix>-MCS-<OH|NH>` (display == solution). Because a code-agent custom name need not
   contain the prefix, the name-based discovery the Lab Cleaner/Reporter use would miss it, so in custom mode
   the wizard stamps a **durable cloud tag** — `a365lab=<prefix>` on lab-owned Azure resource groups and
   `a365lab:<prefix>` on lab-owned Entra app registrations + their service principals (via
   [scripts/Set-LabTags.ps1](../scripts/Set-LabTags.ps1)) — the stable, folder-independent association the
   Lab Cleaner discovers by tag. Only **lab-owned** resources are tagged; a `reuse-existing`/user-owned
   shared account is never tagged.
2. **Container App names must be lowercase**, hyphen-separated (Azure rejects uppercase).
1d. **Instances (N per type) — the `-<n>` suffix rule.** A lab may hold **N instances** of the same agent
   type (each is a separate `agents[]` entry). A type with a **single** instance keeps the plain name (no
   suffix — byte-identical to a single-instance lab); a type with **more than one** instance suffixes
   **every** instance with a 1-based `-<n>` in plan order (`<prefix>-<framework>-<hosting>-<identity>-<n>`,
   e.g. `contoso-MAF-ACA-OBO-1`, `-2`). Instance names must be **unique**; the suffix flows into every
   derived resource (RG `<name>-rg`, container app, blueprint/identity apps) and the SPA tab id, so
   instances never collide. **MCS** instances are suffixed too (`<prefix>-MCS-OH-1`; solution unique name
   `<prefix>MCSOH1`). A **DW** instance suffix is included in the `name.short` ≤ 30 check, so the dynamic
   prefix cap (rule 1a) subtracts it. In **custom** naming mode the user supplies a distinct name per
   instance instead. Reference a specific instance in `ui.expose`/`customMcp.attachTo` by **`agentName`**;
   a bare `agentType` there resolves to **every** instance of that type. (The word *instance* also names a
   Digital-Worker blueprint's projected agent users — here it means a whole distinct agent copy in the lab.)
3. **Region capacity** — validate the chosen region supports Container Apps (ACA), the Foundry
   account + model (FH), and Free-tier Static Web Apps (UI) before committing.
4. **Custom MCP name IS the solution prefix — it is NOT asked.** Agent 365 registered server names must
   start with `ext_` and be **≤ 20 chars**; the servers are `ext_<prefix>Anon` / `ext_<prefix>Auth`
   (the prefix is already lowercase alphanumeric ≤ 12 per rule 1a, used verbatim — `4 + prefix + 4 ≤ 20`).
   `customMcp.attachTo` may contain
   **only OBO agent types** (`ACA-OBO` / `FH-OBO` / `FD-OBO`); S2S and DW are blocked because a BYO
   server needs a Power Platform connection owned by the invoking identity and only an OBO agent invokes
   as the connection-owning user (known preview limitation — see the schema Rules). The **prefix is the
   unique per-copy key**: all Azure resources (`<prefix>-mcp-rg` / `-ca` / `-cae`, lowercased) and the
   registrations derive from it. For N coexisting copies each run needs a **different, unique prefix** —
   the wizard checks the tenant (`a365 develop list-available`, or the M365 admin center Agents → Tools)
   and asks for another prefix if `ext_<prefix>Anon`/`ext_<prefix>Auth` already exists.
5. **Custom MCP integration mode.** `customMcp.integrationMode` ∈ { `approve-first`, `attach-when-approved` }
   (default `approve-first`) — a BYO server must be admin-approved before it can attach, so this
   controls whether the wizard approves the `ext_*` servers before creating the agents (integrate each
   OBO agent immediately) or starts the agents first (integrate only if approved by deploy time).

## Iron rules for every registered or published text (Lab Builder, Demo Builder, every wizard)
The limits live in ONE machine-readable file, [text-limits.json](./text-limits.json), and are enforced by
[scripts/Test-A365Names.ps1](../scripts/Test-A365Names.ps1) (dot-source it; `-SelfTest` replays the real
failures). `max` is the ENFORCED limit (platform limit minus a safety margin); `platformMax` is the platform
itself. A NEW name is checked against `max` (error); an EXISTING name (`-PlatformOnly`) only against
`platformMax` (above `max` = warning). **Validate BEFORE anything is created or registered** — a failed
registration is not free: it can leave orphan Entra apps and reserve a display name forever.

| Object | Rule (enforced / platform) | Why (evidence) |
|---|---|---|
| BYO MCP server name | `ext_` + letters/digits only, **no `_` after `ext_`**; ≤ 18 / 20 | `_` is encoded `-5f` (+2 chars) in the connector id |
| BYO proxy connector id `tc-ext-5f<rest>p-5f<16 hex>-5f<16 hex>` | ≤ 62 / 64 | 65 chars: gateway exposed a single `Error` tool, blank `connectionsMcp` page, undeletable server |
| BYO MCP server description | ≤ 70 / 80 | 93 chars failed the registration and burnt the name |
| Re-registered servers (resets) | `ext_<Base><NN>`, NN 01–99 checked at 99, numbers never reused | a failed name can stay reserved forever |
| MCP tool name | lowercase ASCII snake_case, 3–40 chars, not `initialize_server`, declared by ONE active server only | duplicate tools confuse the gateway and the agents |
| MCP tool / parameter description | ≤ 100 | safety margin |
| Backend vs registration | the backend exposes EXACTLY the declared tools (MCP `tools/list` before registering) | a mismatch registers tools that never work |
| AI-teammate / Teams manifest | `name.short` ≤ 30, `name.full` ≤ 100, `description.short` ≤ 80, `description.full` ≤ 4000, `developer.name` ≤ 32 | an 81+ `description.short` made the manifest upload fail |
| AI-teammate instance | display name ≤ 30 / 32; alias lowercase ASCII | instance form limit |
| Copilot Studio agent | display name ≤ 30, short description ≤ 80, instructions ≤ 8000 | Teams / Microsoft 365 channel details |
| Agent Builder agent | name ≤ 30 / 100, description ≤ 1000, instructions ≤ 8000 | declarative-agent manifest |
| Entra | alias lowercase ASCII (diacritics removed) ≤ 40 / 64; attribute set / attribute names alphanumeric ≤ 32 (**cannot be deleted**) | directory rules |
| Purview / admin center | label, policy, case, template, RTP-rule names ≤ 64; tags ≤ 30 | safety margin |
| SharePoint folder / file names | no `" * : < > ? / \ \| # %`, no leading/trailing space or dot | upload failures |

The scaffolder applies these checks to the custom MCP pair (`ext_<prefix>Anon/Auth`, platform-only: a
12-char prefix reaches the 64-char connector limit exactly), to every `ext_*` server listed in an agent's
`tools`, and to the AI-teammate manifest overrides of an agent overlay.

## ACA deploy-script facts (critical for scaffolding)
Verified in the sample scripts — the wizard must account for these:
- **RG, environment and region are HARDCODED constants inside each `deploy-aca*.ps1`**, not
  parameters. Only `-ClientSecret`, `-ClientSecretFromA365` (assisted mode: the script reads the secret with
  `a365 setup blueprint --show-secret`, run from the agent folder), `-Subscription`, `-AoaiRg`, `-AoaiAcc`,
  `-ReuseEnv` (OBO/S2S) are params.
  To honor the user's chosen names/region the script must be **rewritten from a template**, not just
  invoked with arguments.
  - [aca/obo/deploy-aca.ps1](../../../../aca/obo/deploy-aca.ps1) — `$RG`, `$REGIONS`, `$APP` constants.
- **The generic `deploy-aca.ps1` DELETES its entire resource group by default**
  (`az group delete -n $RG --yes`) unless `-ReuseEnv` is passed. Never point it at a shared RG that
  holds other resources.
  - [aca/obo/deploy-aca.ps1](../../../../aca/obo/deploy-aca.ps1), [aca/dw/deploy-aca.ps1](../../../../aca/dw/deploy-aca.ps1).
- The newer named scripts are **resource-safe** (create RG if absent, reuse env):
  - [aca/s2s/deploy-aca-S2S.ps1](../../../../aca/s2s/deploy-aca-S2S.ps1),
    [aca/dw/deploy-aca-DW.ps1](../../../../aca/dw/deploy-aca-DW.ps1).

**Shared-RG strategy for ACA** is therefore allowed ONLY when using a resource-safe script or when
`-ReuseEnv` is enforced. FH/FD can safely share one Foundry account/project + RG.
