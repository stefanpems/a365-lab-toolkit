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
- [scripts/Remove-TenantLicenses.ps1](./scripts/Remove-TenantLicenses.ps1) — **destructive**. Consumes
  the confirmed selection JSON and removes the target SKUs per user via Graph `assignLicense`, honouring
  dependent add-ons, writing a **persistent log**. Supports `-WhatIf` and `-Force`.

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
6. **Checkbox review (mandatory human check)** — present the matched users as a multi-select list; each
   label = UPN + display name + the target SKUs to be removed (+ any dependent add-ons that may be
   removed if they block a base). The user selects who to act on; unselected users are untouched. If none
   were found, say so and offer to broaden the selector.
7. **Final confirmation** — single-select: **Remove licenses from N user(s)** / **Run a dry run first
   (-WhatIf)** / **Cancel**. Restate the count and the tenant.
8. **Remove** — write the confirmed subset to `selection.json`
   (`{ tenantId, allowDependents, targetSkuIds, users:[{ id, userPrincipalName, removeSkuIds,
   dependentSkuIds }] }`) and run `Remove-TenantLicenses.ps1 -SelectionPath … -Subscription … -TenantId
   …` (add `-Force` if the user already confirmed here, or `-WhatIf` for the dry run).
9. **Report** — summarize per user: removed / skipped (blocked by dependents, permission not granted) /
   errors, and point to the persistent `removal.log` and `result.json`.

## Progress visibility
- Keep the persistent artifacts under `generated/license-reclaimer/<timestamp>/`: `skus.json`,
  `users.json`, `selection.json`, `removal.log`, `result.json` (all gitignored, local-only).
- Tell the user: "Open `generated/license-reclaimer/<timestamp>/removal.log` to watch removals live."
- Never end a turn with a vague "I'll resume when it finishes." State the exact file to watch and the
  concrete next action.
