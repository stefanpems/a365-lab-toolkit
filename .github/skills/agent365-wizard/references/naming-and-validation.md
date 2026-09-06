# Naming & validation rules

## Agent name scheme
Derive every agent name from a single **solution prefix**:

```
<prefix>-<hosting>-<identity>
   hosting  ∈ { ACA, FH, FD }
   identity ∈ { OBO, S2S, DW }
```

Examples for prefix `contoso-sales`: `contoso-sales-ACA-OBO`, `contoso-sales-FH-S2S`,
`contoso-sales-FD-OBO`.

### Derived names (never ask — show on the review screen, editable)
| Derived | Rule | Example |
|---------|------|---------|
| Blueprint display name | `<agent-name> Blueprint` | `contoso-sales-ACA-OBO Blueprint` |
| Identity display name  | `<agent-name> Identity`  | `contoso-sales-ACA-OBO Identity` |
| Container app name (ACA) | lowercase, hyphens | `contoso-sales-aca-obo` |
| Resource group (isolated) | `<agent-name>-rg` | `contoso-sales-ACA-OBO-rg` |
| Resource group (shared)   | `<prefix>-rg` | `contoso-sales-rg` |
| SPA app registration | `<prefix>-ui-spa` | `contoso-sales-ui-spa` |
| Static Web App | `<prefix>-ui` | `contoso-sales-ui` |

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
`agentframeworkFH-DW2-agent`) is reused instead of a clean provision, the Registry will show the old
name — verify the deployed agent matches the planned `<prefix>-FH-DW`.

## HARD validation rules (block, don't warn)
1. **DW ≤ 30 characters.** The blueprint display name and Teams/M365 `name.short` are **rejected
   above 30 chars**. Verified in [docs/setup-MAF-ACA-DW.md](../../../../docs/setup-MAF-ACA-DW.md).
   For any DW variant, validate the display name length and offer a short form (drop " Blueprint",
   shorten the prefix) before proceeding.
1a. **Prefix must start with a lowercase letter** (`^[a-z]`). Azure Container Apps and managed
   identities **reject** names starting with a digit or symbol, so a prefix like `1730` produces the
   invalid container app `1730-aca-obo`. Enforced in `scaffold-from-plan.ps1`.
2. **Container App names must be lowercase**, hyphen-separated (Azure rejects uppercase).
3. **Region capacity** — validate the chosen region supports Container Apps (ACA), the Foundry
   account + model (FH), and Free-tier Static Web Apps (UI) before committing.
4. **Custom MCP name (`customMcp.name`) ≤ 12 characters**, starts with a letter, alphanumeric only.
   Agent 365 registered server names must start with `ext_` and be **≤ 20 chars**; the sample derives
   `ext_<Name>Anon` and `ext_<Name>Auth`, so `4 (ext_) + <Name> + 4 (Anon/Auth) ≤ 20` → `<Name> ≤ 12`.
   The wizard MUST ask for `<Name>` telling the user the max length is 12. `customMcp.attachTo` may
   contain only ACA-* / FH-* agent types (FD prompt agents attach tools via a different mechanism).
   `<Name>` is the **unique per-copy key**: all Azure resources (`<name>-mcp-rg` / `-ca` / `-cae`,
   lowercased), the scaffold folder (`generated/custom-mcp-<name>/`) and the registrations derive from
   it. For N coexisting copies each run needs a **different, unique `<Name>`** — the wizard checks the
   tenant (`a365 develop list-available`, or the M365 admin center Agents → Tools) and asks for another
   name if `ext_<Name>Anon`/`ext_<Name>Auth` already exists.

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
