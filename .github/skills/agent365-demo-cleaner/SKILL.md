---
name: agent365-demo-cleaner
description: 'Roll back a lab built by the Demo Builder: discover everything the run created, and what was added by hand following its runbook, in deletion order; show it in a live HTML report; apply the operator''s exceptions; then delete it hard (purges included, nothing left in a recycle bin), reusing the Lab Cleaner for the Azure/Entra components and agents. Ends with statistics, the problems that prevented a deletion and their solutions, the manual rollback guide and the conflicts expected when a new lab is built in the same tenant, subscription and language. Trigger phrases: remove the demo, delete the demo lab, roll back the Demo Builder, demo teardown, Demo Cleaner, clean up the demo environment.'
argument-hint: 'A lab prefix (for example cts2); add no-discovery-gate to skip the first gate'
---

# Agent 365 demo cleaner

Removes a lab built by the [Demo Builder](../agent365-demo-builder/SKILL.md): users, groups, resources (SharePoint,
mailboxes, OneDrive, eDiscovery), configurations (Conditional Access, entitlement management, custom security
attributes, Purview and admin-center objects), components (demo MCP servers and their registrations, connectors,
web UI, Entra apps) and agents of every kind (code agents, Copilot Studio, Foundry, Agent Builder, third-party
platforms), with their Azure and Entra objects. Every object is one numbered element of the **cleanup plan**, in
deletion order; the plan is shown in a live HTML report from the start of the discovery to the final summary.

The Azure/Entra components and agents are found and deleted by the [Lab Cleaner](../agent365-cleanup/SKILL.md)
scripts, called as they are (one element per call). Every object type, its order, the API used, its purge, its manual
steps and its rebuild conflicts are listed in [references/cleanup-catalog.md](./references/cleanup-catalog.md).

> **Preview, validated on one live lab.** Checked offline (`test-demo-cleaner.ps1`, report rendering) and on a real
> agent-governance lab (EN): live discovery and deletion of users, groups, mailboxes, Entra apps and identities with
> their purges, resource groups with the Cognitive Services and Log Analytics purges, Copilot Studio agents
> (`PvaDeleteBot`), agent registrations, registry entries, access package and catalog, the Purview existence checks,
> the attribute deactivation and the `ext_` neutralization. Not exercised live yet: Conditional Access, eDiscovery,
> Foundry data-plane and OneDrive deletions, the SharePoint purge endpoint (refused there: manual step), the
> third-party heuristic. Run the dry run (`-WhatIf`) first and report what fails.

Write every file, log and command in English; the chat follows the operator's language. Never read or process the
demo excluded by local workspace rules: the cleaner is generic and never needs per-demo content.

## Scripts

| Script | Does | Changes the tenant |
|---|---|---|
| `Get-DemoCleanupPlan.ps1 -Prefix <p> -InitOnly` | creates the run folder and the empty report, prints `REPORT: <file URI>`, `RUNDIR: <folder>` and the read-only check `AUTH: OK <account>` / `AUTH: SIGN-IN NEEDED <login command>` / `AUTH: ERROR <message>` | no |
| `Get-DemoCleanupPlan.ps1 -Prefix <p> -RunDir <run> [-AuthMode lab\|session] [-ThirdPartyAgents a,b] [-OtherAdditions x,y]` | discovery, section by section (the report updates after each one); ends in phase `review` | no |
| `Set-DemoCleanupSelection.ps1 -RunDir <run> [-Exclude <spec>] [-Include <spec>] [-ManualMode pause\|defer] [-Confirm] [-AsJson]` | second gate: exceptions, dependency closure; `-Confirm` records the confirmation, a call without it withdraws an earlier one | no |
| `Invoke-DemoCleanup.ps1 -RunDir <run>` | status only (counts, failures, report link) | no |
| `Invoke-DemoCleanup.ps1 -RunDir <run> -WhatIf` | dry run: what each element would do (`whatif.log`), also on the previewed selection before the confirmation | no |
| `Invoke-DemoCleanup.ps1 -RunDir <run> -Apply [-Done <spec>] [-Absent <spec>] [-Defer <spec>] [-Retry] [-Only <spec>] [-ManualMode ...] [-RgTimeoutMinutes 60] [-NoWait]` | deletion in order, manual checkpoints, resource-group wait, final checks, summary | yes |
| `test-demo-cleaner.ps1` | offline checks (plan model, specs, closure, statistics, report, page scripts) | no |
| `_demo-cleaner.ps1` | shared helpers (dot-sourced after the Demo Builder's `_demo-common.ps1`) | - |

**Reconstruction mode**: when `generated/<prefix>/demo/` is gone, pass `-TenantId -SubscriptionId -Locale -Domain
-AdminUpn` (and `-PaygEnvironmentId` / `-DefaultEnvironmentId` for the Copilot Studio environments): names are
rebuilt from the pack and the locale, without the recorded IDs, with session authentication. A call with `-RunDir`
reuses the authentication mode, the tenant, subscription and reconstruction values and the declared additions of the
run when they are not passed again. `-SnapshotOnly` makes a preview without cloud reads; a snapshot plan can never be
confirmed or applied.

## Flow

1. **Interview** (the agent): runtime-model gate, lab prefix (the local labs with a `demo-config.json`, or
   reconstruction), tenant and subscription confirmation, authentication context, additions made by hand
   (third-party platform agents, other objects).
2. **Gate 1** (on by default): proceed with the read-only discovery? Skipped when the request says
   `no-discovery-gate`.
3. **Discovery**: `-InitOnly` first, so the report link is given at once; then the discovery with `-RunDir` in the
   background. The report shows the phase, the current section and the elements found so far.
4. **Gate 2** (always): the operator reviews the report and gives the exceptions; the agent previews them
   (`Set-DemoCleanupSelection.ps1` without `-Confirm`), shows what the closure adds, then confirms with `-Confirm`.
5. **Dry run** (recommended): `Invoke-DemoCleanup.ps1 -WhatIf`, on the previewed selection, before `-Confirm`.
6. **Deletion**: `Invoke-DemoCleanup.ps1 -Apply` in the background; manual checkpoints are answered one at a time.
7. **Summary**: the run ends with `summary.md` and the summary sections of the report; `-Retry` tries again what could
   not be deleted.

## Plan and report

Run folder: `generated/cleanup/demo-<prefix>-<yyyyMMdd-HHmmss>/` (gitignored, kept after the run as the audit trail).

| File | Content |
|---|---|
| `cleanup-report.html` | the live report: open it in the browser (file URI printed as `REPORT:`) |
| `cleanup-data.js` | the data the report reloads (`Refresh` button, auto-refresh every 60 s, can be turned off) |
| `cleanup-plan.json` | the plan: context, items, selection, summary, manual guide, rebuild notes, runbook coverage |
| `cleanup.log` | timestamped log of discovery and deletion |
| `lab-cleaner/` | the Lab Cleaner's `discovered.json`, `discovery.log`, per-element selections, `deletion.log`, `result.json` |
| `pending-manual.json` | the manual actions of the current checkpoint |
| `whatif.log`, `summary.md` | dry run; final summary |
| `auth/` | session authentication (az profile and MSAL caches), only in session mode; removed when nothing is left to retry |

**Element types**: `User`, `Group`, `Resource`, `Configuration`, `Component`, `Agent`.

| Status | Reasons (shown with the status) |
|---|---|
| To be deleted | - |
| Deleted successfully | notes only when something matters later |
| Could not delete | `error`, `platform limitation`, `manual action pending`, `blocked by a dependency`, `deletion still in progress` (the notes explain the problem and the next action) |
| Excluded (kept) | `kept at the review gate`, `kept by default`, `shared with another lab`, `kept because a prerequisite is kept` |

The report has one table (index, element and detail, type, status, last updated, notes with the manual steps),
filters by type and status, a text search, *Show all*, counters, a print view, and the sections *Warnings*, *Summary*
(statistics by type, problems with their solutions), *Manual rollback guide* (when and how), *Runbook coverage* and
*Rebuilding a lab in the same tenant, subscription and language*. In phase `review` a *Keep* checkbox column and the
*Copy exception list* button produce the text for gate 2 (`exclude: 3-5, 7`).

## Gate 2: exceptions

Specs: indexes `3`, ranges `7-9`, `#12`, whole types `type:User` (plural accepted); separators `,` `;` or spaces;
`none`. A leading `exclude:`, `keep:` or `include:` label is ignored. `-Exclude` keeps elements; `-Include` deletes
elements kept by default. Every call starts again from the discovery's default selection. A call without `-Confirm`
withdraws an earlier confirmation, so `-Apply` runs only on the selection confirmed last; `-WhatIf` works on the
previewed one. `-Retry -Only <spec>` reopens only the listed elements (deferred manual actions stay deferred).

**Kept by default** (include them only on purpose): built-in admin-center rules, unclaimed third-party registry agents,
connected-platform connections, Defender connectors, legacy real-time protection rule, operator directory roles,
pay-as-you-go environment and default-environment settings that are prerequisites, objects tagged with **another**
lab (personas and groups shared by two labs of the same language), resource groups matched by name only.

**Closure**: an element whose prerequisite is kept is kept too (`dependsOn`: what must be deleted before it;
`coveredBy`: removed together with another element). The local lab folder is kept when lab objects are kept (it holds
their state, passwords and caches), unless it is included explicitly.

## Manual actions

Admin-center, Purview and Defender actions without an API are plan elements with *where*, *steps* and *verify*:

- `-ManualMode pause` (default): the run stops at the first manual element together with the manual elements that
  follow it (a checkpoint), writes `pending-manual.json`, sets phase `paused` and exits with **code 10**. Answer with
  `-Apply -Done <spec>` (done), `-Absent <spec>` (did not exist) or `-Defer <spec>` (later); the run goes on.
- `-ManualMode defer`: manual elements become *Could not delete - manual action pending* and the run goes on; the
  summary lists them with the command to close them later.
- `-Done` is verified when an API can read the object (registry packages must return 404; an approved demo MCP server
  must be Blocked, a pending request Rejected). The `ext_` MCP servers and other objects that cannot be deleted end as
  *platform limitation* after the operator neutralized them.

## Hard deletion and order

Nothing is left in a recycle bin: Entra objects are purged (and checked on `/directoryObjects` and
`/directory/deletedItems`, and a final sweep purges the `<prefix>-…` managed identities that Azure deletes with the
resource groups), Microsoft 365 groups are purged, Cognitive Services accounts purged (before their resource group, or
after it when a Foundry account with projects goes with it) and Log Analytics workspaces force-deleted before their
resource group, registry agents permanently deleted, soft-deleted mailboxes, deleted sites and OneDrives purged,
Copilot Studio agents deleted through the Dataverse action `PvaDeleteBot`. What no platform deletes is neutralized and
reported as a limitation. Order and details: [the catalog](./references/cleanup-catalog.md).

Stages: admin-center objects that reference others → demo MCP servers neutralized → Purview and Defender →
Conditional Access and entitlement management → registry, Copilot Studio and Foundry agents, connections, MCP
connectors → Lab Cleaner components and agents (licenses first, purges, resource groups asynchronous) → users and
groups → attributes, roles and prerequisites → after the resource groups are gone: leftover identities, registry and
recycle-bin checks, mailboxes, sites, OneDrives → the local lab folder, only when nothing is left to retry.

An element runs only when everything in its `dependsOn` is deleted (or a limitation); otherwise it becomes *blocked by
a dependency*. Resource-group deletions run in parallel and are awaited up to `-RgTimeoutMinutes` (default 60);
`-NoWait` leaves them to a later `-Retry`.

## Additions made by hand

- **Runbook steps** (the cards and the user-actions register): each one is a plan element; the *Runbook coverage*
  section maps every step to the elements that remove it.
- **Found automatically**: registry agents and Copilot Studio agents owned by a persona, groups owned by a persona,
  users tagged with the lab, agent users managed by a persona, `Unmanaged` registry entries changed after the lab
  started (possible third-party agents, kept by default).
- **Declared**: `-ThirdPartyAgents` (registry names of agents on AWS, Google or other platforms: delete them at the
  source first, with the AWS AI Manager or Google AI Manager delete skills, then their registry entry) and
  `-OtherAdditions` (exact names of other registry agents, Entra apps, users or groups).

## Rebuilding in the same tenant, subscription and language

Localized names do not depend on the prefix, so a new lab of the same language reuses them. The report and the
summary list the conflicts left by the run, computed from the final statuses. Three are prevented structurally:

- `ext_` MCP server names: the names are recorded in
  `generated/cleanup/tenant-<tenant id>/reserved-ext-mcp-names.json`; `New-DemoMcpRegistration.ps1` refuses them (the
  pool takes the next free number). The servers this run verifies as Blocked, Rejected or gone are marked neutralized
  there (`state`), and a long-lived server whose whole family is neutralized is registered as its successor
  `<name><n>` without `-ServerName` (when the tenant's `ext_` servers can be read and no other lab on the machine, same
  tenant and language, still has the same tools registered).
- Custom security attributes: `Set-DemoGovernance.ps1` reactivates a deactivated definition and its values.
- Lab name: once the deletion started, the prefix is retired (`New-DemoConfig.ps1` and the build phases of
  `Invoke-DemoPhase.ps1` refuse it), so a stale `generated/<prefix>/` is never resumed: the new lab takes another name.

## Authentication

- **lab**: the build's lab-private az profile (`azConfigDir` of `demo-config.json`); **session**: a dedicated
  directory of the run (`<run>\auth`, through `DEMO_SESSION_AUTH_DIR`) for the az profile and the MSAL caches. The
  runner switches to session mode by itself when the lab folder is gone.
- Never the shared default contexts: no default az profile, no pac profile switch (`Remove-McsAgent.ps1
  -UseDataverseApi`), Exchange and Security & Compliance PowerShell with `-DisableWAM` (in-memory tokens).
- Interactive browser sign-in only, never device code. Check the session with `Test-DemoAzSession` before asking
  for a sign-in; the login command is `Get-CleanupLoginCommand` (az profile variables + `az login --tenant`).
- Delegated Graph scopes not available to az are requested once through MSAL (Microsoft Graph Command Line Tools
  client): Conditional Access, entitlement management, custom security attributes, Copilot packages, agent
  registration, eDiscovery, sites, files, role management, groups.
- Sign in with the admin of the build (`adminUpn`): it needs the same rights the build used (Entra, Purview,
  Exchange, SharePoint, Power Platform, Agent 365) and Owner or Contributor on the subscription.

## Tests

```powershell
pwsh -File .github/skills/agent365-demo-cleaner/scripts/test-demo-cleaner.ps1
```

## Known limits

- No API (manual, verified when possible): registry Delete agent / Permanently delete (except the code agents: their
  agent registration, found through the Lab Builder's `agentRegistrationId`, is deleted with `DELETE
  /beta/copilot/agentRegistrations/{id}`), approval rejection of pending
  MCP servers, admin-center rules, templates and tags, DSPM one-click policies, saved audit searches, hunting queries,
  Defender connectors. The registry API can refuse the Block of an approved `ext_` server (HTTP 422): the run then asks
  for the Block in the admin center and verifies it. A registry entry whose detail answers 424 after its agent was
  deleted counts as gone when the registry lists no longer contain it.
- Cannot be deleted (limitation): `ext_` MCP servers, custom security attributes (deactivated), attribute sets,
  Defender incidents and alerts (resolved), audit records, and the platform-managed tool connectors
  (`shared_tc-ext-…`) of the `ext_` servers when the Power Apps admin API refuses them too (the maker API refuses
  them even to the admin), and the managed identities that Azure deletes with the resource groups (they stay in the
  Entra recycle bin until Entra purges them, 30 days after the deletion; customers can neither purge nor restore them).
- Copilot Studio agents are deleted through the Dataverse bound action `PvaDeleteBot` (`Remove-McsAgent.ps1
  -UseDataverseApi`): the Power Platform API *Bots - Delete Copilot Agent* supports only Agent Builder agents and needs
  an app registration with the `CopilotStudio.AdminActions.Invoke` scope.
- Implemented from the documentation, not yet exercised against a tenant: the Foundry data-plane agent delete, the
  third-party candidate heuristic (registry entries with governance metadata `Unmanaged` changed after the lab
  started).
- Best effort through an undocumented endpoint: the SharePoint purges (`/_api/SPO.Tenant/RemoveSite` and
  `RemoveDeletedSite` on the admin site with an az token). When they fail the element becomes a manual action with
  the supported commands (`Remove-SPOSite`, `Remove-SPODeletedSite`).
