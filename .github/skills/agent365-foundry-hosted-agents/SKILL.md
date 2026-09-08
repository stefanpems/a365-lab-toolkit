---
name: "Agent 365 — Foundry Hosted agents"
description: "Provision, scaffold, deploy and verify the Foundry Hosted (azd-driven) sample agents: FH-OBO (Invocations protocol), FH-S2S (Responses protocol), FH-DW (container + Azure Bot Service Digital Worker). USE WHEN the user wants to create/deploy a Foundry Hosted agent, run azd provision/deploy for an agent, create the chat model deployment, or troubleshoot the FH gateway/model/tool path. Trigger phrases: 'Foundry Hosted', 'FH agent', 'FH-OBO/S2S/DW', 'azd agent', 'Invocations/Responses protocol', 'hosted Digital Worker'. Sub-skill of the Lab Builder."
---

# Agent 365 — Foundry Hosted agents (FH-OBO / FH-S2S / FH-DW)

Thin orchestration for the Foundry Hosted family. **Canonical, field-verified setup detail is in the
per-variant guides — do not duplicate or renumber them:**
[setup-MAF-FH-OBO.md](../../../docs/setup-MAF-FH-OBO.md),
[setup-MAF-FH-S2S.md](../../../docs/setup-MAF-FH-S2S.md),
[setup-MAF-FH-DW.md](../../../docs/setup-MAF-FH-DW.md).

## What it owns
- FH family scaffolding (module [scaffold.fh.ps1](../agent365-wizard/scripts/modules/scaffold.fh.ps1)):
  rename `azure.yaml`, fill `.env` (OBO/S2S), rewrite the FH-DW agent name in Bicep/scripts, and emit
  the `azd` provision/deploy next-commands.

## Flow
1. Scaffold via the router: [scaffold-from-plan.ps1](../agent365-wizard/scripts/scaffold-from-plan.ps1).
2. FH-OBO/S2S: `azd provision` → **create the model deployment + grant RBAC** → `azd deploy`.
3. FH-DW (governed subscription): `azd provision` → out-of-band blueprint (Solution A) →
   `azd provision` again → admin-center publish + Teams Developer Portal Bot ID = blueprint.

## Known corrections (apply these)
- **FH-OBO/FH-S2S 404 `DeploymentNotFound`**: `azd provision` does **not** create the model deployment
  nor grant data-plane RBAC. The generated next-command creates the model (`az cognitiveservices
  account deployment create … gpt-4.1`) and grants **Cognitive Services User** before `azd deploy`.
- **FH-DW naming**: the sample hardcodes the agent name in Bicep/scripts (not `azure.yaml`); the
  scaffolder rewrites every occurrence to `<prefix>-FH-DW`. Verify the deployed agent uses the planned
  name and is not reusing a pre-existing lab agent.
- **FH-DW governed subscription**: the ARM deploymentScript that creates the blueprint needs shared-key
  storage (may be policy-blocked). Use **Solution A** (out-of-band blueprint via
  `scripts/create-agent-blueprint.ps1`), not a policy waiver — see
  [setup-MAF-FH-DW.md](../../../docs/setup-MAF-FH-DW.md) §3 Path B.
- **FH-DW per-instance identity**: route inference via the **project endpoint** (implicit access) so
  each hired instance can call the model without a per-instance role — see §6.2 of that guide.

## Tools
FH samples currently wire **only Mail** in code. Attaching a non-Mail Work IQ MCP also needs the code
generalization documented in
[workiq-mcp-integration.md](../agent365-wizard/references/workiq-mcp-integration.md) — reuse the
per-request/per-turn token lessons there; do not re-derive them.
