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
| 🔵 | informational (present but no single health verdict, e.g. Foundry-managed identity) |

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
   - **Entra Agent ID** — the named blueprint/identity objects. ACA agents create `<name> Blueprint`
     (app + SP) and (OBO/S2S) `<name> Identity` (SP). FH/FD agents use a **Foundry-managed identity**
     with no predictably-named blueprint app, so they show 🔵 (not ❌).
   - **Overall** — worst meaningful state across RG/compute/Entra; falls back to the compute state when
     only informational (so FD shows 🔵).
4. **Shared Foundry (create-shared)** — only when `solution.foundry.mode == create-shared`. Same 6
   columns. Rows: `<prefix>-foundry-rg` and its Cognitive Services account (provisioningState).
5. **Digital Worker instances & licenses** — only when the lab has ACA-DW / FH-DW. Columns
   `Instance (display name) | UPN | Enabled | Licenses`. Instances are agent users holding a Frontier /
   Agent 365 license whose name/UPN carries the lab prefix; other agent-license holders in the tenant are
   summarized as a count (they are likely other labs, since instances can be custom-named at hire time).
6. **Entra recycle bin** — shown only if soft-deleted apps/SPs/users matching the prefix are pending
   purge (informational — a prior half-finished cleanup).
7. **Summary** — one-line counts (agents healthy, Web UI, Custom MCP, DW instances).

## Expected vs actual
"Expected" objects come from the run's deployment plan when it is available
(`generated/<prefix>/a365-deployment-plan.json`, or `-PlanPath`, or the repo-root plan if its prefix
matches). Without a plan, the agent set is reconstructed from Entra blueprint apps
(`<prefix>-<HOSTING>-<IDENTITY> Blueprint`). "Actual" is always live cloud state (`az … show/list/exists`
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
