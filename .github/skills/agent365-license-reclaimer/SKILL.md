---
name: agent365-license-reclaimer
description: 'Reclaim (release) M365 license seats in the lab tenant by removing license assignments from users — without deleting the users. Use when the user wants to free up licenses such as Microsoft 365 Frontier for Autopilots, Teams Enterprise, E5, E7, Agent 365, or Teams. Interviews with input controls, discovers the tenant SKUs and the users holding them, shows a checkbox review, then removes the licenses (honouring dependent add-ons) with a persistent log. Trigger phrases: reclaim licenses, free licenses, release seats, remove licenses from users, License Reclaimer.'
argument-hint: 'Describe which licenses to free, or just say start'
---

# License Reclaimer

Release M365 license **seats** in the lab tenant by removing license assignments from users. This
**frees seats**; it does **not** delete users (that is the [Lab Cleaner](../agent365-cleanup/SKILL.md)'s
job for agent instances). Read the provisioning tool only for naming rules; never modify it.

Write **English** in every file, log, and command you persist. Chat may be in the user's language.

## Scripts (do not re-derive their logic)
- [scripts/Find-LicenseTargets.ps1](./scripts/Find-LicenseTargets.ps1) — **READ-ONLY**. Two actions:
  - `-Action ListSkus` — enumerate the tenant's subscribed SKUs and classify them into the six wizard
    categories (Frontier for Autopilots, Teams Enterprise, E5, E7, Agent 365, Teams), flagging which are
    pre-selected by default (**Frontier + Teams Enterprise**, when present).
  - `-Action FindUsers` — given the chosen SKU ids and a user selector (`ObjectId` / `Prefix` / `All`),
    return every user that **holds** a target SKU, with the exact target SKUs (and, with
    `-IncludeDependents`, the dependent add-on SKUs) each holds.
- [scripts/Resolve-RemovalPlan.ps1](./scripts/Resolve-RemovalPlan.ps1) — **READ-ONLY**. Turns the
  discovery file + the operator's checkbox selection (object ids) into the exact `selection.json` the
  removal consumes, and a human-readable `plan-summary.txt`. It records per user the target SKUs and
  (when `-AllowDependents`) the candidate dependent add-ons, and **flags CRITICAL accounts** — the
  signed-in operator and members of privileged directory roles (Global Administrator, Privileged Role
  Administrator, User Administrator). Always build the plan with this script — never hand-build
  `selection.json`.
- [scripts/Remove-TenantLicenses.ps1](./scripts/Remove-TenantLicenses.ps1) — **destructive**. Consumes
  the confirmed selection JSON and removes the target SKUs per user via Graph `assignLicense`, honouring
  dependent add-ons, writing a **persistent log** plus a concise `report.txt`. Supports `-WhatIf` and
  `-Force`.

Both scripts are tenant-agnostic (they enumerate SKUs and users from Graph at run time — no hard-coded
ids). Three invocation pitfalls are already handled inside the scripts, keep them that way:
- `pwsh -File … -SkuIds a,b,c` passes the comma-joined value as a **single string** (`-File` does not
  split on commas), and passing a PowerShell array (`-SkuIds $arr`) via `-File` fails with "positional
  parameter cannot be found". Always pass array params as ONE comma-joined string (`-SkuIds ($arr -join ',')`);
  the scripts normalize `-SkuIds` / `-SelectorValues` / `-SelectedObjectIds` by splitting on `[,\s]+`.
- On PowerShell 7.6.x, `@($list)` where `$list` is a `System.Collections.Generic.List[object]` throws
  `Argument types do not match`; use `$list.ToArray()` before `@(…)` (piping a list through
  `Where-Object`/`ForEach-Object` is unaffected).
- Inside a method call, `$list.Add("{0} {1}" -f $a, $b)` parses the comma as a **method-argument**
  separator, so `-f` gets only `$a` and fails with "index … less than the size of the argument list".
  Wrap the format expression in parentheses: `$list.Add(("{0} {1}" -f $a, $b))`.

Microsoft does **not** publish a machine-readable service-plan *dependency* graph (the
[licensing service plan reference](https://learn.microsoft.com/entra/identity/users/licensing-service-plan-reference)
is a product↔service-plan **name/GUID** map only). Candidate dependent add-ons are therefore pre-computed
from each user's **own held SKUs** (a documented classifier), never parsed from error messages; deeper
prerequisites (`servicePlanDependencyConflict`) are enforced only at runtime and are handled/reported by
the removal script.

## Mandatory rules
- **Use interactive input controls for every question** (single-select and multi-select), one clear
  question at a time — never a wall of free text and never ask the user to answer in chat prose. IDs and
  prefixes are entered through the questions tool (an input control). If (and only if) that tool is
  genuinely unavailable, say so once and fall back to numbered text.
- **The Copilot runtime-model gate is always first** (Flow step 0), before any tool or discovery.
- **Pin the subscription and verify the tenant** before any Microsoft Graph call — Graph uses the active
  az account, not `--subscription`, and a concurrent session can flip the shared az context. Both scripts
  assert this. If Graph returns a CAE challenge (`InteractionRequired` / `TokenCreatedWithOutdatedPolicies`),
  have the user run `az logout` then `az login --tenant <id> --scope https://graph.microsoft.com/.default`
  and retry.
- **Never remove a license without the checkbox review — no exceptions.** After discovery you ALWAYS
  present the matched users and the exact SKUs to be removed, and obtain a per-item selection plus a final
  confirmation. Removing a license can disable mailbox/Teams/app access for a real user — treat it as
  high-impact and irreversible in effect.
- **Offer a dry run.** When the user is unsure, run the removal with `-WhatIf` first.
- **Secrets never pass through chat.** This wizard needs none; never ask for or echo any.

## License dependencies
Microsoft enforces license **prerequisites** at the API: you cannot remove a base license while a
dependent add-on that requires it is still assigned (e.g. **MS Project**, **MS Teams Phone**, Visio,
Audio Conferencing, Power BI/Apps/Automate). The removal script:
1. tries to remove **only the target SKUs**;
2. on a prerequisite/dependency error, if the operator **granted permission**, also removes the user's
   dependent add-on SKUs and retries once; if permission was **not** granted, it leaves the base in place
   and logs which add-ons blocked it.

Add-ons are removed **only when they actually block a target removal and permission was granted** — never
pre-emptively.

Some bases cannot be freed at all: if an **unselected** license the user keeps (e.g. a Dynamics 365 /
Power Platform bundle) has a service plan that depends on a plan inside the base being removed, Graph
returns `servicePlanDependencyConflict`. Removing add-ons cannot resolve it, so the removal script leaves
that base **fully in place** and logs a readable `SKIP` naming the blocking retained license(s) and the
required service plan(s) — it never partially removes and never dumps a raw error blob. Report these as
"left in place — a retained license depends on them", not as failures.

## Flow (in order)
0. **Confirm the Copilot runtime model — first action.** Show the active chat model and, when VS Code
   exposes them, its runtime parameters (e.g. reasoning effort). Recommend **High** reasoning effort for
   this multi-step, effectively-irreversible workflow; if unavailable/unselected, warn and let the user
   acknowledge before continuing. Single-select: **Confirm and continue** / **Change model** / **Cancel**.
1. **Which tenant?** — run `az account show` and PRESENT the detected **tenant id + name**. Single-select:
   **Use this tenant `<id>`** (recommended) / **Specify another tenant by ID**. If another, collect the
   Tenant ID via the questions tool, then pin the subscription and assert the tenant.
2. **Which licenses to free?** — run `Find-LicenseTargets.ps1 -Action ListSkus`. Present a **multi-select
   checkbox** of ONLY the categories that exist in the tenant, with **Frontier for Autopilots** and
   **Teams Enterprise** pre-checked (recommended); E5, E7, Agent 365, Teams shown (unchecked) only when
   present. Map the selected categories back to their SKU ids.
3. **Remove dependent add-ons if needed?** — single-select: **Yes — also remove dependent add-ons (e.g.
   MS Project, MS Teams Phone) when they block a base removal** / **No — skip any base that is blocked by
   a dependent**. This sets `allowDependents`.
4. **How to identify the users?** — single-select: **By object ID / UPN (a specific list)** / **By a
   name / surname / UPN prefix** / **The entire list (all holders of the selected licenses)**.
5. **Selector value (depends on step 4)** — via the questions tool:
   - *By object ID / UPN* → collect the object ids or UPNs (comma/space separated).
   - *By prefix* → collect the single prefix string.
   - *The entire list* → no value needed; confirm the intent.
   Then run `Find-LicenseTargets.ps1 -Action FindUsers -SkuIds … -Selector … [-SelectorValues …]
   -IncludeDependents` (pass `-IncludeDependents` whenever `allowDependents` is Yes), writing
   `users.json` under `generated/license-reclaimer/<timestamp>/`.
6. **Checkbox review (mandatory human check)** — present the matched users as a multi-select list with
   **every entry DESELECTED by default** (never pre-check, never mark "recommended", no self-protection
   pre-selection); each label = UPN + display name + the target SKUs to be removed (+ any dependent
   add-ons that may be removed if they block a base). The user selects who to act on; unselected users
   are untouched. **If more than 100 users match, do NOT present the list** — tell the user it is too
   long to review safely and re-present step 4/5 to narrow by object ID / UPN or by a name / surname /
   UPN prefix, then re-run `FindUsers` and review again (the list already contains only holders of a
   target SKU, so it is pre-filtered to users with a license to remove). If none were found, say so and
   offer to broaden the selector.
7. **Build the removal plan (read-only) + FINAL CONFIRMATION (binding).** Run `Resolve-RemovalPlan.ps1`
   with the selected users' object ids to write `selection.json` + `plan-summary.txt`. The plan lists,
   per selected user, the exact target SKUs to remove and (when `allowDependents`) the candidate
   dependent add-ons, and flags **CRITICAL** accounts (signed-in operator + Global/Privileged/User
   Administrators). **Removal MUST NOT start without an explicit approval here** of a confirmation that
   shows all — and only — what will change:
   - If `allowDependents = No`: single-select **Approve — remove from N user(s)** / **Dry run first
     (-WhatIf)** / **Cancel**. The listed target SKUs are exactly what will change (no runtime dependency
     removals).
   - If `allowDependents = Yes`: present the **updated per-user list including the candidate dependent
     add-ons** as a multi-select, with every reviewed user checked and every **CRITICAL** account clearly
     flagged; the operator may **deselect** any user to exclude them. Rebuild `selection.json` from the
     still-selected users, then a final single-select **Approve** / **Dry run** / **Cancel**. The only
     changes allowed beyond the listed target SKUs are dependent add-ons discovered at runtime
     (`servicePlanDependencyConflict` / prerequisite) — and only because the operator approved dependents.
8. **Remove** — run `Remove-TenantLicenses.ps1 -SelectionPath selection.json -Subscription … -TenantId …`
   (`-Force` because the user already approved in step 7, or `-WhatIf` for the dry run). **After it
   returns you MUST verify it actually ran** by reading `removal.log` / `result.json` before reporting
   anything — never claim a removal happened based only on launching the command.
9. **Final report (mandatory — always at the end of a `start` session)** — present the concise report the
   script writes to `report.txt`: per user, which licenses were removed; plus any **left in place** (with
   the blocking retained license named) and any errors. Point to `removal.log` / `result.json` /
   `report.txt`.

## Progress visibility
- Keep the persistent artifacts under `generated/license-reclaimer/<timestamp>/`: `skus.json`,
  `users.json`, `selection.json`, `plan-summary.txt`, `removal.log`, `result.json`, `report.txt` (all
  gitignored, local-only).
- Tell the user: "Open `generated/license-reclaimer/<timestamp>/removal.log` to watch removals live."
- Never end a turn with a vague "I'll resume when it finishes." State the exact file to watch and the
  concrete next action.
