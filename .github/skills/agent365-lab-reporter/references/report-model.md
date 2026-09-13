# Lab Reporter — report model (the consistency contract)

This defines the **fixed** structure of the lab-state dashboard so that every run produces the same
table shape, columns and status legend. `scripts/Get-LabState.ps1` renders `report.md` deterministically
from this model; the agent shows that file verbatim. Keep this in sync with the wizard naming rules
([agent365-wizard/references/naming-and-validation.md](../../agent365-wizard/references/naming-and-validation.md))
and the cleanup resource model
([agent365-cleanup/references/resource-model.md](../../agent365-cleanup/references/resource-model.md)).

## Status legend (identical every run)
| Emoji | Meaning |
|:--:|---|
| ✅ | present and healthy |
| 🟡 | present but provisioning / degraded |
| ❌ | expected but missing, or in a failed state |
| ⚪ | not part of this lab (not planned / not applicable) |
| 🔵 | informational (present but no single health verdict, e.g. a declarative agent with no Entra blueprint app) |

## Acronyms (fixed glossary, right after the legend)
The report opens with an **Acronyms** section covering exactly the acronyms that appear in it — the agent
taxonomy `<prefix>-<FRAMEWORK>-<HOSTING>-<IDENTITY>` (e.g. `MAF-ACA-OBO`):

| Acronym | Meaning |
|:--:|---|
| MAF | Microsoft Agent Framework (the framework the sample agents are currently built with) |
| ACA | Azure Container Apps (agent hosting) |
| FH | Foundry Hosted (agent hosting) |
| FD | Foundry Declarative (prompt/declarative agent) |
| MCS | Microsoft Copilot Studio (low-code agent platform; agents are Dataverse solutions) |
| OBO | On-Behalf-Of (agent acts with the signed-in user's delegated identity) |
| S2S | Service-to-Service (agent acts with its own application identity) |
| DW | Digital Worker (AI-teammate agent hired as an agent user; holds a Frontier / Agent 365 license) |
| OH | Old Harness (legacy Microsoft Copilot Studio agent runtime; MCS-OH) |
| NH | New Harness (new Microsoft Copilot Studio agent runtime, based on GitHub Copilot; MCS-NH) |
| GHCP | GitHub Copilot (the coding-assistant harness the New Harness agents build on) |

`Get-LabState.ps1` owns this glossary (defined once, emitted to `report.md` and stored in `state.json` as
`acronyms`); `Get-LabStateHtml.ps1` reuses `state.acronyms` verbatim (with a built-in fallback). Keep the
two in sync — do not add acronyms that are not present in the report, and do not drop any that are.

## Which object types are reported (and which are NOT)
The report lists only objects whose **existence or state is meaningful**. Supporting / detail resources
are intentionally **excluded as rows** (they are implied by their resource group): NICs, disks, public
IPs, Container Apps **environments** (`-cae`), **ACRs**, **Log Analytics** workspaces, **user-assigned
managed identities**, Bot Service internals, and the individual MCP **proxy** apps (summarized as a
count, not one row each).

### Fixed sections and columns
1. **Web UI** — columns `Object | Layer | Name | Exists | Status | Details`. Rows: the UI resource group
   (`<prefix>-ui-rg`), the Static Web App (`<prefix>-ui`, with its `https://…` URL), the SPA app
   registration (`<prefix>-ui-spa`).
2. **Custom MCP** — same 6 columns. Rows: the MCP resource group (`<prefix>-mcp-rg`), the anon + auth
   container apps (running status + FQDN), the `ext_<Name>Anon`/`ext_<Name>Auth` **registration** apps
   (they appear in Entra as `… - BYO`) and the `ext_<Name>Auth-Resource` auth resource app, a summarized
   **proxy apps** count, and a best-effort **Power Platform connector** count.
3. **Agents** — one **row per agent**, columns `Agent | Type | Resource group | Compute | Entra Agent ID
   | Overall`:
   - **Resource group** — the isolated `<agent-name>-rg` (⚪ when the agent has no dedicated RG, e.g. FD
     or an FH agent sharing `create-shared`).
   - **Compute** — ACA: the container app **runningStatus**; FH: the Foundry **account provisioningState**
     (isolated RG or the shared `create-shared` account); FD: 🔵 prompt agent (shared project, no
     dedicated Azure compute).
   - **Entra Agent ID** — the agent's **blueprint application** (`agentIdentityBlueprint`). It is
     resolved by the **durable appId** recorded in `generated/<lab>/<agent>/` (ACA:
     `a365.generated.config.json` `.agentBlueprintId`; FH: `.azure/<env>/.env`
     `AGENT_IDENTITY_BLUEPRINT_ID`) — **never** inferred from the agent name, which may be custom — and
     validated against the `a365lab:<prefix>` Entra tag. FD agents are declarative (defined in the
     Foundry project, no Entra blueprint app → 🔵); MCS agents live in Copilot Studio / Dataverse (⚪).
   - **Overall** — worst meaningful state across RG/compute/Entra; falls back to the compute state when
     only informational (so FD shows 🔵, MCS ⚪).
4. **Shared Foundry (create-shared)** — only when `solution.foundry.mode == create-shared`. Same 6
   columns. Rows: `<prefix>-foundry-rg` and its Cognitive Services account (provisioningState).
5. **Digital Worker instances & licenses** — only when the lab has ACA-DW / FH-DW. Columns
   `Instance (display name) | UPN | Enabled | Licenses`. Instances are agent users holding a Frontier /
   Agent 365 license, scoped to the lab by the **durable blueprint link** (`user.identityParentId` →
   `agentIdentity` SP → `agentIdentityBlueprintId` ∈ this lab's blueprint set) — **never** by name (an
   instance can be custom-named at hire time). Other agent-license holders in the tenant are summarized
   as a count (likely other labs).
6. **Entra recycle bin** — shown only if soft-deleted apps/SPs/users matching the prefix are pending
   purge (informational — a prior half-finished cleanup).
7. **Summary** — one-line counts (agents healthy, Web UI, Custom MCP, DW instances). Health ratios (X / Y)
   count only **significant** rows (✅/🟡/❌); informational (🔵) and not-part-of-this-lab (⚪) rows are
   excluded from the denominator, so e.g. MCP proxy-app / connector rows and FD/MCS agents never inflate
   the ratio.

## HTML rendering (same macro-structure, hosts any lab configuration)
`Get-LabStateHtml.ps1` renders a self-contained `report.html` from a `state.json` with a **fixed**
macro-structure, in this order: **header** (lab name, tenant, subscription, generated timestamp, plan
source) → **legend** → **acronyms** → **summary** (cards) → **Web UI** → **Custom MCP** → **Agents** →
**shared Foundry** (only when present) → **shared Azure OpenAI** (only when present) → **Digital Worker
instances & licenses** → **Entra recycle bin** (only when present) → **footer**. The same table columns,
status emoji and included/excluded object types apply. Core sections (Web UI, Custom MCP, Agents, DW)
always render — with an italic placeholder note when a lab does not include them — while the optional
sections render only when the state has data, so a single template holds any configuration. The HTML
makes no cloud calls; it is a pure projection of `state.json`.

## Expected vs actual
"Expected" objects come from the run's deployment plan when it is available
(`generated/<prefix>/a365-deployment-plan.json`, or `-PlanPath`, or the repo-root plan if its prefix
matches). Without a plan, the agent set is reconstructed from Entra blueprint apps
(`<prefix>-<FRAMEWORK>-<HOSTING>-<IDENTITY>`, e.g. `contoso-MAF-ACA-OBO`; OBO/S2S blueprint apps carry a
trailing `" Blueprint"`, DW apps do not). "Actual" is always live cloud state (`az … show/list/exists`
and Microsoft Graph GET). Everything is **read-only**.

## Known limitations (state them in the report footnotes, don't hide them)
- **Power Platform connectors** for BYO MCP live in a hidden *Compliant Container* environment the
  environment API does not enumerate, so a `0 listed` count is informational, not a failure.
- **FH hosted-agent version status** (active/failed/creating) is a Foundry data-plane object; this report
  covers the Azure account/model and the Entra footprint, not the per-version runtime status (check the
  Foundry portal for that).
- **FD prompt agents** have almost no queryable Azure/Entra footprint (the agent object is a Foundry
  data-plane object) — they are reported as 🔵, verify in the Foundry portal / M365 admin center.
- **Agent 365 Registry / admin-center** publish & approval state (for DW autopilots, approved MCP
  servers) is not queried here; the Entra blueprint/identity + instances are the queryable proxy for it.
