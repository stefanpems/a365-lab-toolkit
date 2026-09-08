# Naming & validation rules

## Agent name scheme
Derive every agent name from a single **solution prefix**:

```
<prefix>-<hosting>-<identity>
   hosting  ∈ { ACA, FH, FD }
   identity ∈ { OBO, S2S, DW }
```

Examples for prefix `contoso`: `contoso-ACA-OBO`, `contoso-FH-S2S`, `contoso-FD-OBO`.

### Derived names (never ask — show on the review screen, editable)
| Derived | Rule | Example |
|---------|------|---------|
| Blueprint display name | `<agent-name> Blueprint` | `contoso-ACA-OBO Blueprint` |
| Identity display name  | `<agent-name> Identity`  | `contoso-ACA-OBO Identity` |
| Container app name (ACA) | lowercase, hyphens | `contoso-aca-obo` |
| Resource group (isolated) | `<agent-name>-rg` | `contoso-ACA-OBO-rg` |
| Resource group (shared)   | `<prefix>-rg` | `contoso-rg` |
| SPA app registration | `<prefix>-ui-spa` | `contoso-ui-spa` |
| Static Web App | `<prefix>-ui` | `contoso-ui` |

> **Scaffold output lives under one per-run root: `generated/<prefix>/`.** Every folder for a run — each
> `<agent-name>`, the `<prefix>-ui` web UI and the `<prefix>-mcp` custom MCP — is created under it (e.g.
> `generated/contoso/contoso-ACA-OBO/`). The wizard's own `generated/wizard-progress.log`
> and `generated/cleanup/` stay at the `generated/` root.

### Registry display name — the `" Agent"` suffix (cosmetic, not controllable)
The a365 CLI lists ACA agents in the Registry with a trailing `" Agent"` (e.g. `a1730-ACA-OBO` is
shown as **`a1730-ACA-OBO Agent`**). This is added by the CLI at registration time, not by our
`a365.config.json`, and does not affect the blueprint (`… Blueprint`) or identity (`… Identity`)
names. Do not attempt to strip it via the plan — it cannot be set there.

### DW visibility in the Registry
ACA-DW and FH-DW do **not** auto-appear in the Registry like OBO/S2S. ACA-DW becomes visible only
after `a365 publish --aiteammate --agent-name "<name>"` regenerates `manifest/manifest.zip` for THIS
blueprint and the user uploads it in the M365 admin center (Agents → Upload custom agent), then a user
hires it in Teams. FH-DW appears after the admin-center approval of its azd-published request.

### FH-DW naming (different from the others)
The FH-DW sample hardcodes the agent name in **Bicep and scripts** (not `azure.yaml`). The scaffolder
rewrites every occurrence to `<prefix>-FH-DW`. If a pre-existing lab agent (e.g.
`sample-fh-dw-agent`) is reused instead of a clean provision, the Registry will show the old
name — verify the deployed agent matches the planned `<prefix>-FH-DW`.

## HARD validation rules (block, don't warn)
1. **DW ≤ 30 characters.** The blueprint display name and Teams/M365 `name.short` are **rejected
   above 30 chars**. Verified in [docs/setup-MAF-ACA-DW.md](../../../../docs/setup-MAF-ACA-DW.md).
   For any DW variant, validate the display name length and offer a short form (drop " Blueprint",
   shorten the prefix) before proceeding.
1a. **Prefix: lowercase letter first, lowercase alphanumeric only, 3–12 chars** (`^[a-z][a-z0-9]{2,11}$`,
   enforced in `scaffold-from-plan.ps1`). It is reused for every resource, so it must satisfy the
   strictest consumer — the **custom MCP**: Agent 365 registers `ext_<prefix>Anon` / `ext_<prefix>Auth`,
   which must stay **≤ 20 chars** (`4 + prefix + 4`) and are **alphanumeric** (no hyphens/underscores).
   That also covers Azure Container Apps (2–32, lowercase, start-with-a-letter — a prefix like `1730`
   would make the invalid container `1730-aca-obo`), managed identities, resource groups, the Entra apps
   and the Static Web App. **State these rules to the user before asking for the prefix.** MS Learn:
   [Azure resource naming rules](https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules#microsoftapp).
2. **Container App names must be lowercase**, hyphen-separated (Azure rejects uppercase).
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
   (default `attach-when-approved`) — a BYO server must be admin-approved before it can attach, so this
   controls whether the wizard approves the `ext_*` servers before creating the agents (integrate each
   OBO agent immediately) or starts the agents first (integrate only if approved by deploy time).

## ACA deploy-script facts (critical for scaffolding)
Verified in the sample scripts — the wizard must account for these:
- **RG, environment and region are HARDCODED constants inside each `deploy-aca*.ps1`**, not
  parameters. Only `-ClientSecret`, `-Subscription`, `-AoaiRg`, `-AoaiAcc`, `-ReuseEnv` are params.
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
