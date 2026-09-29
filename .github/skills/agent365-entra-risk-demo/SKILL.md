---
name: agent365-entra-risk-demo
description: 'Inspect and change Microsoft Entra Agent ID risk for demos. Use when setting an agent identity to high risk, dismissing or removing agent risk, confirming an agent safe, checking riskyAgents status, or demonstrating risk-based Conditional Access. Runs one script (MSAL browser sign-in, no WAM) against Microsoft Graph beta, for one or more agents.'
argument-hint: 'set-high | dismiss | confirm-safe | get <agent-object-id(s)> <tenant-id> [browser | device-code]'
---

# Microsoft Entra Agent Risk Demo

Run [scripts/Set-EntraAgentRisk.ps1](./scripts/Set-EntraAgentRisk.ps1) **once** to inspect or change the
risk of identities created through Microsoft Entra Agent ID. In a single run it signs in, checks the
tenant and the permission, resolves the targets, calls the `riskyAgents` API for all the agents in one
request, and prints the read-after-write state.

## Fast path

1. Collect, in one question and only when missing:
   - the agent **object ID(s)** from **Entra ID > Agents > Agent identities** (never the
     application/client ID);
   - the **tenant ID**;
   - the **action** (see [Actions](#actions));
   - the **sign-in method**: `Browser` (default) or `DeviceCode`, and optionally the admin account
     (`-LoginHint`).
2. Run the script. A request that names the action, the agents and the tenant is the confirmation:
   no pre-flight `Get`, no second question.

   ```powershell
   pwsh -NoProfile -File .\.github\skills\agent365-entra-risk-demo\scripts\Set-EntraAgentRisk.ps1 `
       -TenantId '<tenant-id>' -AgentId '<agent-object-id>[,<agent-object-id>]' -Action SetHigh `
       [-AuthMethod Browser|DeviceCode] [-LoginHint '<admin-upn>'] [-InstallDependencies]
   ```

   Allow at least 120 seconds: the first run opens a browser tab for the sign-in; later runs are silent.
3. Report the printed result. Do not explore the repository, inspect modules, or write wrappers or
   alternative sign-in code: if the script fails, report its error and the fix in
   [Troubleshooting](#troubleshooting).

## Actions

| `-Action` | Graph call | Result | Intended use |
| --- | --- | --- | --- |
| `Get` | `GET riskyAgents/{id}` | No mutation | Read the current state. No record normally means no active risk. |
| `SetHigh` | `confirmCompromised` | `riskLevel=high`, `riskState=confirmedCompromised` | Start a high-risk demo ("confirm compromise"). |
| `Dismiss` | `dismiss` | `riskLevel=none`, `riskState=dismissed` | Reset a demo without classifying the detection as incorrect. |
| `ConfirmSafe` | `confirmSafe` | `riskLevel=none`, `riskState=confirmedSafe` | Mark the event as a false positive. |

`low` and `medium` are detection-engine outputs and cannot be assigned manually. `-WhatIf` shows a
mutation without signing in or calling Microsoft Graph.

## Prerequisites

- Microsoft Entra ID Protection coverage for agents in the target tenant.
- A **Security Administrator** (or a custom role that supports the operation) with the delegated
  Microsoft Graph permission `IdentityRiskyAgent.ReadWrite.All` consented for Microsoft Graph Command
  Line Tools (the consent prompt appears at the first sign-in).
- PowerShell 7 and Python 3 with the `msal` package (`-InstallDependencies` installs it for the
  current user).

The `riskyAgents` API is under Microsoft Graph `/beta` and can change.

## Sign-in

The script does not use `Connect-MgGraph`: Microsoft Graph PowerShell 2.26+ always signs in with WAM
on Windows (`Set-MgGraphOption -DisableLoginByWAM` is ignored), WAM fails in agent and embedded hosts
without a console window (`A window handle must be configured`), and importing an older module next to
a newer one fails with an assembly conflict. [scripts/get_graph_token.py](./scripts/get_graph_token.py)
uses MSAL with the Microsoft Graph Command Line Tools public client instead:

| `-AuthMethod` | Sign-in | Notes |
| --- | --- | --- |
| `Browser` (default) | System browser tab, `localhost` redirect | Works from agent hosts. |
| `DeviceCode` | Code and URL printed on stderr | Often blocked by Conditional Access; run the script asynchronously and relay the code. |

The MSAL cache is `%LOCALAPPDATA%\agent365-lab\msal-graph-cache.bin`, encrypted with DPAPI;
`-CachePath` can reuse an existing plain lab cache (`*.json`). Tokens are never printed.

## Troubleshooting

| Message | Fix |
| --- | --- |
| `The token lacks the delegated scope` | Sign in as a Security Administrator and accept the consent for `IdentityRiskyAgent.ReadWrite.All`. |
| `Signed-in tenant ... does not match` | Rerun and pick an account of the target tenant (`-LoginHint`). |
| `Object ... was not found in tenant` | The value is not a directory object ID of that tenant (often an application/client ID). |
| `accepted, not visible yet` | The action was accepted; after `confirmCompromised` the record can take several minutes to appear. Rerun with `-Action Get`. |
| `The Python package 'msal' is missing` | Rerun with `-InstallDependencies`. |

## Operational notes

- A clean agent might not have a `riskyAgents` record and might therefore be absent from the portal
  report. `SetHigh` creates the admin-confirmed compromise signal
  (`riskDetail=adminConfirmedAgentCompromised`).
- Once the high-risk record reaches the portal, portal actions can be used on that report entry.
- In OBO activity, behavioral risk is normally attributed to the delegated user. Explicit
  `confirmCompromised` against the agent object ID targets the agent record itself.
- The script does not create or modify Conditional Access policies and does not disable identities.