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

## HARD validation rules (block, don't warn)
1. **DW ≤ 30 characters.** The blueprint display name and Teams/M365 `name.short` are **rejected
   above 30 chars**. Verified in [docs/setup-MAF-ACA-DW.md](../../../../docs/setup-MAF-ACA-DW.md).
   For any DW variant, validate the display name length and offer a short form (drop " Blueprint",
   shorten the prefix) before proceeding.
2. **Container App names must be lowercase**, hyphen-separated (Azure rejects uppercase).
3. **Region capacity** — validate the chosen region supports Container Apps (ACA), the Foundry
   account + model (FH), and Free-tier Static Web Apps (UI) before committing.

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
