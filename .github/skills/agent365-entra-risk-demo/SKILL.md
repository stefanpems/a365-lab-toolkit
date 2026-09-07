---
name: agent365-entra-risk-demo
description: 'Inspect and change Microsoft Entra Agent ID risk for demos. Use when setting an agent identity to high risk, dismissing or removing agent risk, confirming an agent safe, checking riskyAgents status, or demonstrating risk-based Conditional Access. Includes a PowerShell wrapper for Microsoft Graph beta.'
argument-hint: 'get | set-high | dismiss | confirm-safe <agent-object-id>'
---

# Microsoft Entra Agent Risk Demo

Use [scripts/Set-EntraAgentRisk.ps1](./scripts/Set-EntraAgentRisk.ps1) to inspect or change the risk
of an identity created through Microsoft Entra Agent ID.

## Supported transitions

| Action | Result | Intended use |
| --- | --- | --- |
| `Get` | No mutation | Read the current `riskyAgents` record. A missing record normally means no active risk. |
| `SetHigh` | `riskLevel=high`, `riskState=confirmedCompromised` | Start a high-risk demo. |
| `Dismiss` | `riskLevel=none`, `riskState=dismissed` | Reset a demo without classifying the detection as incorrect. |
| `ConfirmSafe` | `riskLevel=none`, `riskState=confirmedSafe` | Mark the event as a false positive. |

`low` and `medium` are detection-engine outputs and cannot be assigned manually.

## Prerequisites

- Microsoft Entra ID Protection coverage for agents in the target tenant.
- Microsoft Entra role **Security Administrator** or a custom role supporting the operation.
- Delegated Microsoft Graph permission `IdentityRiskyAgent.ReadWrite.All` for mutations.
- PowerShell module `Microsoft.Graph.Authentication`. The script can install it for the current user
  when invoked with `-InstallDependencies`.
- The directory **object ID** of the agent identity, agent user, or blueprint principal. Do not use
  the application/client ID.

The `riskyAgents` API is currently under Microsoft Graph `/beta` and can change.

## Procedure

1. Obtain the target object ID from **Entra ID > Agents > Agent identities**. Verify that the selected
   object is the intended demo identity.
2. Inspect the current state without mutation:

   ```powershell
   .\.github\skills\agent365-entra-risk-demo\scripts\Set-EntraAgentRisk.ps1 `
       -AgentId '<agent-object-id>' -Action Get -InstallDependencies
   ```

3. Before changing risk, show the signed-in tenant ID and ask the user to confirm all of the following:
   target tenant, agent object ID, operation, and whether a Conditional Access policy blocks high-risk
   agents. A block policy can stop new token issuance immediately.
4. After explicit confirmation, set high risk:

   ```powershell
   .\.github\skills\agent365-entra-risk-demo\scripts\Set-EntraAgentRisk.ps1 `
       -AgentId '<agent-object-id>' -Action SetHigh -Force
   ```

5. Reset the demo with `Dismiss`:

   ```powershell
   .\.github\skills\agent365-entra-risk-demo\scripts\Set-EntraAgentRisk.ps1 `
       -AgentId '<agent-object-id>' -Action Dismiss -Force
   ```

6. Use `ConfirmSafe` instead only when deliberately recording a false positive:

   ```powershell
   .\.github\skills\agent365-entra-risk-demo\scripts\Set-EntraAgentRisk.ps1 `
       -AgentId '<agent-object-id>' -Action ConfirmSafe -Force
   ```

The script prints a structured result and performs a read-after-write check. The Risky Agents report
can take time to reflect the API result.

## Operational notes

- A clean agent might not have a `riskyAgents` record and might therefore be absent from the portal
  report. Use `SetHigh` with its agent object ID to create the admin-confirmed compromise signal.
- Once the high-risk record reaches the portal, portal actions can be used on that report entry.
- In OBO activity, behavioral risk is normally attributed to the delegated user. Explicit
  `confirmCompromised` against the agent object ID targets the agent record itself.
- The script does not create or modify Conditional Access policies and does not disable identities.