# Cleanup resource model

What the Lab Builder creates per category, and how the cleanup agent finds and deletes it.
This mirrors the provisioning wizard's naming rules
([agent365-wizard/references/naming-and-validation.md](../../agent365-wizard/references/naming-and-validation.md))
— it is read-only reference for cleanup and must stay in sync if the wizard's naming changes.

The two discovery filters:
- **Name filter** (WebUI + Agents) — usually the solution **prefix** (e.g. `h2256`). Resource names
  begin with it (`<prefix>-…`).
- **MCP name filter** (Custom MCP) — the custom MCP **`<Name>`** (e.g. `h2256`). Azure resources use its
  lowercased alphanumeric **slug**; Entra apps and connectors use `ext_<Name>…`.

### Custom-named labs — the durable lab tag (folder-independent anchor)
When the Lab Builder ran with `solution.namingMode = custom`, a code agent (ACA/FH/FD) can have a name
that does **not** contain the prefix, so the name filter alone would miss it. The Lab Builder therefore
stamps a **durable tag** on every **lab-owned** resource, and discovery matches it in addition to the name:
- **Azure** resource groups → tag `a365lab=<prefix>` (`az group list --query "[?tags.a365lab=='<prefix>']"`).
- **Entra** app registrations + their service principals → the multi-valued `tags` entry `a365lab:<prefix>`
  (`$filter=tags/any(t:t eq 'a365lab:<prefix>')`).
The tag is written by [agent365-wizard/scripts/Set-LabTags.ps1](../../agent365-wizard/scripts/Set-LabTags.ps1)
(idempotent; lab-owned only — a `reuse-existing`/user-owned shared account is never tagged). Discovery also
accepts the archived plan (`-PlanPath generated/<prefix>/a365-deployment-plan.json`) to seed the **exact**
resource names (the folder-primary path, which also catches a resource created before it could be tagged in
an interrupted run). The three paths (name / tag / plan) are unioned and de-duplicated. **MCS agents are
never custom-named**, so they stay discoverable by their prefix-derived solution unique name.

## 1. Web UI

| Layer | Resource | Naming | Cleanup action |
|-------|----------|--------|----------------|
| Azure | Resource group | `<prefix>-ui-rg` | `delete-rg` (async) |
| Azure | Static Web App | `<prefix>-ui` | covered by the RG delete; also matched directly (`delete-swa`) |
| Entra | SPA app registration (+ its SP) | `<prefix>-ui-spa` | `delete-app` (deletes app, cascades SP) + purge |

## 2. Custom MCP servers

| Layer | Resource | Naming | Cleanup action |
|-------|----------|--------|----------------|
| Azure | Resource group | `<slug>-mcp-rg` | `delete-rg` (async) |
| Azure | Container apps (anon/auth) | `<slug>-mcp-anon-ca`, `<slug>-mcp-auth-ca` | covered by the RG delete |
| Azure | Container apps environment | `<slug>-mcp-cae` | covered by the RG delete |
| Azure | Container registry (ACR) | auto-named | covered by the RG delete |
| Entra | Registration + proxy/resource apps | `ext_<Name>Anon`, `ext_<Name>Auth`, `…-A365Proxy`, `…-PublicClients`, `…-RemoteProxy`, `ext_<Name>Auth-Resource` | `delete-app` + purge |
| Power Platform | Custom connectors | `ext_<Name>…` (incl. the `…P` proxy connector) | `delete-connector` |
| Entra recycle bin | Any of the above left soft-deleted | matches `ext_<Name>` | `purge-deleted-item` |

> The CLI does **not** roll back the Entra proxy apps on a failed registration and sometimes leaves the
> connectors — the same leftovers [custom-mcp/cleanup-registration.ps1](../../../../custom-mcp/cleanup-registration.ps1)
> targets. This cleanup covers them too, plus the Azure container resources.

## 3. Agents

Agent name scheme: `<prefix>-<hosting>-<identity>` (hosting ∈ ACA/FH/FD; identity ∈ OBO/S2S/DW).

| Layer | Resource | Naming | Cleanup action |
|-------|----------|--------|----------------|
| Azure | **Dedicated** resource group (isolated strategy) | `<agent-name>-rg` | `delete-rg` (async) |
| Azure | ACA container app / env / ACR / Log Analytics | inside the agent RG | covered by the RG delete |
| Azure | FH Foundry account / project / ACR / model / Bot Service (DW) / UAMI | inside the agent RG | ACR/model/Bot/UAMI covered by the RG delete; the **Cognitive Services account** (+ its project) is **delete+purged first** (order 39) so it does not linger soft-deleted |
| Azure | **Shared** Foundry account + project + model (`solution.foundry` `create-shared`) | `<prefix>-foundry-rg` | account **delete+purged** (order 39), then `delete-rg` removes the RG — both matched by the prefix filter (lab-owned) |
| Azure | **Shared** Azure OpenAI account + deployment (`solution.azureOpenAI` `create-shared`) | `<prefix>-aoai-rg` (account `<prefix>aoai`) | account **delete+purged** (order 39), then `delete-rg` removes the RG — both matched by the prefix filter (lab-owned) |
| Entra | Blueprint app (+ its SP) | `<agent-name> Blueprint` | `delete-app` + purge |
| Entra | Agent identity app / SP | `<agent-name> Identity` | `delete-app` + purge |
| Entra | **Agent instances** (agent users) | custom names given at hire (may NOT contain the prefix) | `remove-licenses-and-delete-user` |
| M365 | **Licenses on each instance** | Frontier for Autopilots (no Teams), Teams Enterprise, M365 E7 (verify all — they vary per instance) | removed explicitly + released by purge |
| Entra recycle bin | Any app / SP / user left soft-deleted from a prior attempt | matches the filter | `purge-deleted-item` |

### Shared resources that must NOT be deleted wholesale
- **`solution.foundry` `reuse-existing`** points the FH/FD agents at a **pre-existing, user-owned** Foundry
  account + project (supplied via `foundry.endpoint`/`account`/`existingResourceGroup`). Its RG is not
  prefix-named, so the prefix filter will not match it — and it must **not** be deleted. Cleanup is limited
  to the lab's blueprint/identity apps + instances (+ the Foundry **agent object**, a data-plane object;
  delete it in the portal/admin center or via the Foundry API if required). This is the same treatment as FD
  below. (`create-shared` is the opposite: its `<prefix>-foundry-rg` **is** lab-owned and IS deleted.)
- **`solution.azureOpenAI` `reuse-existing`** points the ACA agents at a **pre-existing, user-owned** Azure
  OpenAI account (supplied via `account`/`existingResourceGroup`). Its RG is not prefix-named, so the prefix
  filter will not match it — and it must **not** be deleted. (`create-shared` is the opposite: its
  `<prefix>-aoai-rg` + account `<prefix>aoai` **are** lab-owned and ARE deleted + purged by the prefix filter.)
- **FD (prompt) agents** reuse a **shared** Foundry account/project (e.g. `rg-a365-foundry-agent` /
  `a365f-…`). It is pre-existing and shared — a prefix filter will not match it, and it must not be
  deleted. FD cleanup is limited to the blueprint app + instances (+ the Foundry agent object, which
  is a data-plane object; delete it in the portal/admin center if required).
- A **shared** agent resource group (`<prefix>-rg`, shared strategy) holds several agents at once. If
  it appears in discovery, the review screen shows its full contents — keep it unless every agent in
  it is being removed.

### Cognitive Services accounts soft-delete — purge them (frees name + quota)
Deleting a resource group only **soft-deletes** the Cognitive Services accounts inside it (Foundry
`AIServices` accounts, Azure OpenAI accounts). A soft-deleted account keeps **blocking its name** and
**counts against the regional Cognitive Services quota** until it is **purged** — and a same-name
re-provision fails with *"account already exists"* / *"Soft-deleted workspace exists"*. Discovery therefore
adds a `purge-cognitiveservices` item (order **39**, just before `delete-rg`) that **deletes the live
account then purges it**, and also **sweeps `az cognitiveservices account list-deleted`** for accounts whose
original RG matches the prefix (leftovers a prior cleanup deleted the RG for but never purged). Purging the
account also removes its child **project** — the *"workspace"* the Foundry azd provider projects via the
`Microsoft.MachineLearningServices` compat API — so there is **no separate AML-workspace resource to purge**.
Only prefix-named (lab-owned) accounts are purged; a shared/user-owned account (`reuse-existing`, the FD
project, the ACA-shared Azure OpenAI account) is never prefix-matched and is left intact.

### Why instances need special handling (the license guarantee)
An autopilot is **one blueprint → many instances**, and **each hired instance gets its own agent
identity + agent user** with its own **M365 licenses**. Instances are frequently named arbitrarily at
hire time (e.g. `AFDHDW3I1`), so a name filter can miss them — discovery therefore also lists every
user holding a **Frontier / Agent 365** license as a candidate. A **soft-delete does not release
licenses; only the purge does**, so removal (a) removes every license explicitly, (b) soft-deletes the
user, (c) purges it from the recycle bin, and (d) verifies it is gone. Every step is logged.

## Delete order (dependencies)
`10` agent instances (licenses first) → `20` Entra apps (cascade SPs) → `24` recycle-bin purge →
`30` Power Platform connectors → `38` Static Web Apps → `40` Azure resource groups (async, last).
