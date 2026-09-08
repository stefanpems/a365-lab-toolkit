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
- **`azd deploy` times out on "Polling agent status … (creating)" — read the SINGLE-VERSION item, not
  the versions LIST, and confirm with an actual invoke.**
  azd polls ~30×/6 min then reports "agent deployment timed out (last status: creating)". Check the real
  outcome on the **version item** (token for `https://ai.azure.com`):
  `GET {project-endpoint}/agents/<name>/versions/<N>?api-version=2025-05-15-preview` → `status` +
  `error.code`/`error.message`. ⛔ **The `/versions` LIST reports a misleading `status: active` (that is the
  traffic-selector state, NOT provisioning health); only the single-version item and an actual invoke tell
  the truth.** A version that provisioned OK is `active` on the ITEM endpoint; a failed one is `failed` with
  an `error`, and invoking the agent returns **HTTP 409 `agent_version_failed` "Agent version provisioning
  failed"**. Interpret the error: SPECIFIC codes are fixable config/RBAC (`image_pull_failed`,
  `AcrImageNotFound`, `InvalidAcrPullCredentials`, `DeploymentNotFound`, `SubscriptionIsNotRegistered`); a
  **generic `ProvisioningError` ("Please retry")** that persists across several `azd deploy` retries is a
  **server-side Foundry failure** (5xx → the docs say contact support), NOT a plan/scaffolder bug. Verified on
  a09081 (2026-09-08): FH-OBO/FH-S2S all versions stayed `ProvisioningError` and invoking returned 409, while
  the **identical** h2256 FH-OBO deployed the day before shows the version item `active` and works — the only
  difference was that the a09081 Foundry accounts were minutes old. Response: **retry later** (a freshly
  created Foundry account may need time to become hosted-agent-capable) or try another region; do not
  "fix" the identical-to-working code/plan. The `/agents` (assistants) LIST is empty for hosted agents.

## Tools
FH samples currently wire **only Mail** in code. Attaching a non-Mail Work IQ MCP also needs the code
generalization documented in
[workiq-mcp-integration.md](../agent365-wizard/references/workiq-mcp-integration.md) — reuse the
per-request/per-turn token lessons there; do not re-derive them.
