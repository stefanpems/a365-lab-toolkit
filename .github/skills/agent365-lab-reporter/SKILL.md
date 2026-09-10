---
name: agent365-lab-reporter
description: 'READ-ONLY reporting for Agent 365 lab runs created by the Lab Builder. Use when the user wants the web UI (Static Web App) URL of a lab identified by name (e.g. a09091), or a consistent dashboard of a lab''s state — which resources were created, whether they actually exist in Azure / Entra / Microsoft 365, and their status (with DW instances and the licenses on their agent users). Trigger phrases: lab report, lab status, lab state, SWA URL, web UI URL of the lab, what did I deploy for <lab>, is <lab> healthy, show me the lab dashboard.'
argument-hint: 'A lab name (solution prefix, e.g. a09091) and what you want: URL or full state'
---

# Agent 365 lab reporter

Produce **read-only** information about a lab run created by the
[Lab Builder](../../agents/a365-lab-provisioner.agent.md), identified by its **lab name** (the solution
**prefix**, e.g. `a09091`). Two capabilities:

1. **Web UI URL** — resolve the Static Web App URL of a lab.
2. **Lab state dashboard** — a consistent, colour-coded table report of every significant object the run
   can create, its actual existence in Azure / Entra / Microsoft 365, and its status.

This skill **never mutates** anything — only `az … list/show/exists` and Microsoft Graph GET calls. Do
**not** modify the Lab Builder or the deployed agents; only read them. Write **English** in every file
and command you persist; chat may be in the user's language.

## Scripts (do not re-derive their logic)
- [scripts/Get-LabSwaUrl.ps1](./scripts/Get-LabSwaUrl.ps1) — READ-ONLY. Prints the `https://<host>` URL of
  the lab's Static Web App (`<prefix>-ui`) from the live subscription.
- [scripts/Get-LabState.ps1](./scripts/Get-LabState.ps1) — READ-ONLY. Discovers the significant objects,
  checks existence + status, and writes `state.json` + a deterministic `report.md` dashboard under
  `generated/lab-reporter/<prefix>-<timestamp>/`.

## What is reported (and the fixed table shape)
The exact sections, columns, status legend and the list of **included vs excluded** object types (detail
resources such as NICs, Container Apps environments, ACRs, Log Analytics and the individual MCP proxy
apps are intentionally excluded) are the **consistency contract** in
[references/report-model.md](./references/report-model.md). Keep the report structure identical across
runs — the script renders it deterministically; present it verbatim.

Status legend: ✅ present & healthy · 🟡 present, provisioning/degraded · ❌ missing or failed · ⚪ not
part of this lab · 🔵 informational.

## Flow (in order)
0. **Confirm the Copilot runtime model** — first action. Show the active chat model and, when VS Code
   exposes them, its runtime parameters (e.g. reasoning effort). This is read-only reporting, so the
   effort recommendation is light; still let the user confirm / change / cancel via a single-select.
1. **Confirm tenant + subscription** — run `az account show`; present the tenant id + name and
   subscription id + name and **ask the user to confirm or enter** the correct target Tenant ID +
   Subscription ID (never rely on the ambient `az` context alone — it can flip between concurrent
   sessions). Pin the subscription and assert the tenant. If Graph returns a CAE challenge
   (`InteractionRequired` / `TokenCreatedWithOutdatedPolicies`), have the user run
   `az login --tenant <id> --scope https://graph.microsoft.com/.default` and retry.
2. **Ask the lab name** — the solution prefix (e.g. `a09091`), via the questions tool (input control).
   Offer the discovered `generated/<prefix>/` folders as a hint.
3. **Ask what to produce** — single-select: **Web UI URL** / **Full state dashboard** / **Both**.
4. **Run the script(s)** and **show the result**:
   - Web UI URL → run `Get-LabSwaUrl.ps1`; present the `https://…` URL in a copy-friendly fenced block +
     a clickable link.
   - Full state → run `Get-LabState.ps1`; then **display the generated `report.md` verbatim** in chat and
     point the user to the file paths (`report.md` + `state.json`).
5. **Report** — summarize (agents healthy, Web UI, Custom MCP, DW instances) and point to the artifacts.

## Guardrails
- **Read-only, always.** Never delete, update or create cloud resources. For teardown, that is the
  [Lab Cleaner](../../agents/a365-lab-cleanup.agent.md).
- **Pin the subscription and verify the tenant before any Graph call** — `az ad`/Graph ignore
  `--subscription` and use the active account; both scripts assert this.
- **Graph must be reachable** — every category has an Entra component; `Get-LabState.ps1` aborts loudly on
  a CAE/Conditional Access block rather than silently under-reporting.
- **Windows az.cmd quirk** — Graph `$filter` values are URL-encoded as the only query parameter (no `&`),
  the same pattern the cleanup discovery uses; keep it for any new Graph call.
- **pwsh 7.6 `@($list)` regression** — never write `@($someGenericList)` directly; use
  `@($list.ToArray())` (see [repo memory]; it throws "Argument types do not match").
- Artifacts land under `generated/lab-reporter/` (gitignored) — a local, uncommitted audit trail.
