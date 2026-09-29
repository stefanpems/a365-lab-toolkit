---
name: agent365-demo-reset
description: 'Verify and restore the starting conditions of a demo lab built by the Demo Builder, before every rehearsal or live run, so that each demo (D1-D17 of the agent-governance pack) can be repeated. Read-only pre-flight per demo; automatic reset of what the APIs allow (registry owners, unblocks, Entra owners/sponsors/attributes/enabled, agent risk, access-package assignments, the reserve-name MCP pool, orphan agents recreated through a temporary leaver); guided list of the manual resets. Trigger phrases: reset the demo, demo pre-flight, demo readiness, restore the starting conditions, repeat a demo, recreate the orphan agent, prepare the rehearsal.'
argument-hint: 'A lab prefix and the demos to check or reset (default: all)'
---

# Agent 365 demo reset

Keeps a demo lab built by the [Demo Builder](../agent365-demo-builder/SKILL.md) repeatable. The starting conditions
are not a separate baseline file: they come from the demo pack (`pack.json` agents[].registryOwner / entraOwner /
sponsor / attribute / baseline, governance, mcp, operatorSlots, demos[].manualReset), the lab locale (names), the lab
state (`generated/<prefix>/demo/state.json`) and the Lab Builder configs of the code agents. The scripts dot-source the
Demo Builder helpers (`_demo-common.ps1`, `_demo-entra.ps1`) plus `scripts/_demo-registry.ps1`.

> **Preview, not yet validated end to end**: the pre-flight has run read-only against a real tenant; the reset with
> `-Apply` and the orphan recreation have not been run by these scripts yet. Dry-run first.

## Scripts

| Script | Does | Changes |
|---|---|---|
| `Get-DemoState.ps1 -Prefix <p> [-Demo D5,D10]` | pre-flight: OK / KO / WARN / MANUAL / INFO per demo, with the fix; report `generated/<p>/demo/demo-state.md` | nothing (remembers catalog package ids in state.json) |
| `Reset-DemoState.ps1 -Prefix <p> [-Demo ...] [-Apply] [-SkipOrphan]` | restores what the APIs allow, then prints the manual resets | only with `-Apply` |
| `New-OrphanAgent.ps1 -Prefix <p> -Agent <key> [-Apply] [-Force] [-KeepLeaver] [-HoldMinutes 30]` | temporary leaver: the Agent Builder agent becomes ownerless again (about 45 min with the default hold); prints the share link to open again | only with `-Apply` |

`-Demo` takes demo codes and the areas `People`, `Registry`, `Entra`, `Mcp`. The reserve-name MCP pool itself is
managed by the Demo Builder's `New-DemoMcpRegistration.ps1` (Register, Confirm, Retire); the reset prepares the next
pool name and tells what to do with a consumed instance.

## Rules (lessons of the reference lab)

- **Always pre-flight first, dry run second, `-Apply` third, pre-flight again.** Run the full reset the evening before
  a run: blocks, installs and owner changes need time to propagate.
- **A block that a demo shows is never scripted**: the story persona (the AI administrator) blocks the agent in the
  admin center, so the audit trail of the demos shows that person. The reset only UNBLOCKS, and then reminds to
  re-install the agent for its group: a block removes existing installations.
- **Blocked agents keep their agent ID disabled by design**: the reset never re-enables them and the pre-flight does
  not flag them.
- **Ownerless** means that the owner is empty or no longer resolves: a soft delete of the creator is not enough, the
  user must be permanently deleted. The API counts an unresolvable owner as ownerless, but the admin-center card
  "Agents without owners" (and the D8 rule's "Agents to review") can lag for hours or keep a ghost owner for days: verify
  the CARD as the AI administrator, keep the plan B ready (the empty Owner column; "Assign new owner" works anyway),
  and prepare the leavers at least two days ahead. `New-OrphanAgent.ps1 -Force` re-runs the cycle when the API already
  says ownerless; `-KeepLeaver` stops after the reassignment (diagnostic). The package owner cannot be cleared by API
  (a PATCH of `ownerId` is ignored).
- **Leavers are never recreated by accident**: once a leaver was deleted, the identity build skips it unless the
  persona is named explicitly (as `New-OrphanAgent.ps1` does).
- **Shared agents are reachable only through their share link**: after every orphan recreation the recipients open
  the link again (the pre-flight prints it).
- **Never reassign the D8 agent before D8**: its starting condition is "ownerless"; the reset recreates it with the
  temporary leaver, never with a reassignment.
- **A preparation step that is itself a demo moment is done live** (for example the rule that reassigns ownerless
  agents to the manager in D8): the reset only recreates the conditions (New-OrphanAgent.ps1) and says so.
- **Copilot Studio agents published to the organization catalog have two registry entries**: the shared one (owner)
  and the published one (install scope, block). The install-scope API is silently ignored: installs are manual.
- **MCP pool**: names are never reused; at most one non-retired instance per base; the live base needs exactly one
  PENDING instance. After any approval (rehearsal or live), Block the server in the admin center, record it with
  `New-DemoMcpRegistration.ps1 -Action Retire -Name <n> -Confirmed`, then run the reset for D6.
- **Operator slots**: the pre-flight only checks that the document built with a slot is present; it never prints the
  slot values. Protection demos are referred to by code.
- Every script logs to `generated/<prefix>/wizard-progress.log`; delegated calls use one MSAL sign-in per lab (system
  browser on first use), application-only calls a temporary app deleted at the end.

## Lead times (plan the reset accordingly)

| Item | Lead time |
|---|---|
| Orphan agent (temporary leaver) | about 45 minutes with the default hold, then the admin-center card can lag for hours |
| Unblock / re-install / owner change | minutes to an hour before users see it |
| New pool instance (registration + consents) | minutes; approval is live |
| Agent risk dismissed | minutes |
| Traffic (usage, map, exceptions) | 24-72 hours of activity before the run |
