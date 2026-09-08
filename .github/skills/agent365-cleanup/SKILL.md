---
name: agent365-cleanup
description: 'Delete resources created by the Lab Builder for a given run, in any state. Use when the user wants to clean up / tear down / remove a lab run: Web UI (Azure), Custom MCP servers (Azure + Entra registration), or Agents (Azure RG + Entra identity incl. recycle bin + M365 license assignments). Always discovers, shows a checkbox review, then deletes with a persistent log. Trigger phrases: clean up the lab, delete the run, tear down agents, remove the web UI, remove the custom MCP, release agent licenses.'
argument-hint: 'Describe what to clean up, or just say start'
---

# Agent 365 lab cleanup

Delete every resource the [Lab Builder](../../agents/a365-lab-provisioner.agent.md) created
for a run — **regardless of the state they are in** (fully deployed, half-deployed, or already
soft-deleted and waiting in the Entra recycle bin). Do **not** modify the provisioning tool; only read
it for the naming rules.

Write **English** in every file, log, and command you persist. Chat may be in the user's language.

## What can be cleaned (three categories)
See [references/resource-model.md](./references/resource-model.md) for the full mapping.
1. **Web UI** — Azure resources starting from the resource group (`<prefix>-ui-rg`, the Static Web App)
   and the Entra SPA app registration (`<prefix>-ui-spa`).
2. **Custom MCP servers** — Azure resources starting from the resource group (`<slug>-mcp-rg` with its
   containers/environment/registry) **and** the Entra registration (`ext_<Name>…` proxy/resource apps)
   and the Power Platform custom connectors.
3. **Agents** — Azure resources starting from the **dedicated** resource group (`<agent-name>-rg`, when
   isolated), the Entra identity components (blueprint + identity apps, agent instances, **including the
   recycle bin**), and — **critically** — the **M365 license assignments** on each agent instance
   (typically Frontier for Autopilots, Teams Enterprise, and M365 E7, but **verify all of them per
   agent and per instance** — they vary). License release must be **guaranteed**.

## Scripts (do not re-derive their logic)
- [scripts/Discover-CleanupResources.ps1](./scripts/Discover-CleanupResources.ps1) — **READ-ONLY**.
  Enumerates matching resources for the chosen categories and writes `discovered.json`.
- [scripts/Remove-CleanupResources.ps1](./scripts/Remove-CleanupResources.ps1) — **destructive**.
  Consumes the confirmed selection, deletes in dependency order, and writes a **persistent log**.
- [scripts/Remove-GeneratedFolders.ps1](./scripts/Remove-GeneratedFolders.ps1) — **destructive, local FS**.
  Recursively finds the outermost `generated/` folders whose name contains an agent / custom-MCP
  identifier and (after the same checkbox review) deletes them with all content. `-List` is read-only.

## Mandatory rules
- **Never delete without the checkbox review.** After discovery you ALWAYS present the identified
  resources and let the user pick exactly which to delete. Nothing is deleted until they confirm.
- **Use interactive input controls for every choice** (multi-select checkboxes, single-select), one
  question at a time — never ask the user to answer with free-form chat prose. The name-filter values
  are entered through the questions tool (an input control), not typed into chat.
- **Pin the subscription and verify the tenant** before any `az ad` / Microsoft Graph call — those
  ignore `--subscription` and use the active account, and a concurrent session can flip the shared az
  context. Both scripts assert this; confirm the tenant with the user first.
- **Persistent log.** Every deletion (and every skip/error) is appended to
  `generated/cleanup/<timestamp>/deletion.log`. Point the user to it.
- **License release is the priority.** A soft-delete does **not** free M365 licenses — only the purge
  does. The removal script removes each license explicitly, soft-deletes the agent user, purges it from
  the recycle bin, and verifies release. Do not skip the purge.
- **Shared resources.** Never delete a shared Foundry RG (e.g. `rg-a365-foundry-agent`, used by FD) or a
  shared agent RG unless every agent in it is in scope. The review screen shows RG contents so the user
  can judge. FD agents leave almost no Azure footprint — their cleanup is the blueprint app + instances.

## Flow (in order)
0. **Confirm the Copilot runtime model** — first action. Show the active chat model and, when VS Code
   exposes them, its runtime parameters (e.g. reasoning effort). Recommend **High** reasoning effort for
   this multi-step destructive workflow; if unavailable/unselected, warn and let the user acknowledge and
   continue. Single-select: **Confirm and continue** / **Change model** / **Cancel**.
1. **Confirm tenant + subscription explicitly** — run `az account show`; present the **tenant id +
   name** and **subscription id + name**, and **always ask the user to confirm those values or enter
   the correct target Tenant ID and Subscription ID** (as the provisioning scripts require) — never rely
   on the ambient `az` context alone. Pin the subscription and assert the tenant. If Graph later returns
   a CAE challenge (`InteractionRequired` / `TokenCreatedWithOutdatedPolicies`), have the user run
   `az logout` then `az login --tenant <id> --scope https://graph.microsoft.com/.default` and retry.
2. **Select categories** — multi-select checkbox: **Web UI**, **Custom MCP servers**, **Agents**.
3. **Name filter(s)** — via the questions tool (input control):
   - one filter for **Web UI + Agents** (usually the solution prefix, e.g. `h2256`);
   - a separate filter for **Custom MCP** (the `<Name>`), only if that category was selected.
4. **Discover** — run `Discover-CleanupResources.ps1` for the chosen categories, writing
   `generated/cleanup/<timestamp>/discovered.json`. Read it back.
5. **Checkbox review (mandatory human check)** — present the discovered items as a multi-select list,
   grouped by category, each labelled with kind + name + key detail (RG contents; instance UPN and the
   exact licenses it holds). The user selects the items to **delete**; anything left unselected is
   preserved. If the list is long, split into one multi-select per category. Show licenses explicitly so
   the user can verify each instance.
6. **Final confirmation** — single-select: **Delete N selected resource(s)** / **Cancel**. Restate the
   count and the tenant.
7. **Delete** — write the selected items to `generated/cleanup/<timestamp>/selection.json` and run
   `Remove-CleanupResources.ps1 -SelectionPath … -Subscription … -TenantId …`. It logs every action.
   Offer a **dry run first** with `-WhatIf` when the user is unsure. Resource-group deletion is async
   (`--no-wait`) by default; mention that RG deletion completes in the background (ACA environments can
   take 20-40 min) — pass `-WaitForRg` only if the user wants to block.
8. **Remove local `generated/` folders (optional)** — after the cloud deletion, ask (single-select
   Yes/No) whether to also delete the local scaffolding folders for the cleaned resources. If yes, run
   `Remove-GeneratedFolders.ps1 -List -Identifiers <NameFilter>[,<McpNameFilter>]` to discover the
   outermost `generated/` folders whose name contains those identifier strings (recursive — today
   directly under `generated/`, tomorrow inside grouping subfolders; the audit folder is excluded; the
   web-UI folder is a future identifier). Present the candidates in a **checkbox review**, write the
   confirmed subset to `folders.selection.json`, then run `Remove-GeneratedFolders.ps1 -SelectionPath …
   -Force` (logged to the same `deletion.log`). This is a hard, non-recoverable delete (`generated/` is
   gitignored). Offer `-WhatIf` if the user is unsure.
9. **Report** — summarize successes/errors, released licenses, and point to the persistent log and
   `result.json`. For async RG deletions, give the verification command (`az group exists -n <rg>`).

## Presenting instances and licenses
Discovery finds agent instances two ways — by name match **and** by the Frontier/Agent 365 license they
carry (because instances are often custom-named at hire time). Always show each instance's **UPN and the
list of licenses** in the checkbox label so the user verifies the exact identity before deleting. The
removal guarantees the licenses are released (explicit removal + purge + verification).

## Safety
- On Windows, `az`'s Graph calls that carry an OData `$filter`/`$select`/`--query` or a `&` can be
  corrupted by az.cmd/cmd.exe argument parsing, silently under-reporting. Both scripts therefore issue
  Graph filters URL-encoded as a single query parameter (no `&`); keep that pattern for any new call.
- Idempotent: re-running is safe; already-absent objects are logged as skipped.
- The removal script continues past individual errors (each logged) so one failure never blocks the
  rest; review the ERROR lines afterward.
- `generated/` is gitignored, so the discovery/selection/log files stay local (a persistent audit trail
  that never gets committed).
