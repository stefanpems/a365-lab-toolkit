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
  `AcrImageNotFound`, `InvalidAcrPullCredentials`, `DeploymentNotFound`, `SubscriptionIsNotRegistered`); the
  `/agents` (assistants) LIST is empty for hosted agents.
- **⛔ Persistent generic `ProvisioningError` ("Please retry") = a per-account service-side hosted-agent
  build failure, NOT a plan/scaffolder/tooling/code bug — deploy into a KNOWN-GOOD project, and on failure
  retry the deploy and/or re-provision a fresh account.** Conclusive evidence (a09081, 2026-09-08). First,
  every LOCAL variable was isolated: the **identical** agent code (same `content_hash`) deploys `active` in
  ~90 s in an earlier project (h2256, 2026-09-06), while every version `failed` in the original a09081
  accounts — including one freshly provisioned with current azd 1.33 + agents beta.13 (so NOT old tooling),
  model bound, RBAC granted; account/project ARM config (kind/sku/identity/`allowProjectManagement`/
  capabilityHosts/connections), account-scope RBAC and project managed-identity roles were **byte-identical**
  between the working and failing projects. Then a clean-room **A→H bisection** in a hello-world (each step
  deployed to a good fresh account `hellofh2` and checked the single-version ITEM `.status`) took an echo
  agent and added, one layer at a time, the real deps, module-level imports, the per-turn client, the model
  call, the MCP handshake, a handler that returns **HTTP 500**, and finally the **full real agent under the
  exact failing name `a09081-FH-OBO`** (uppercase + hyphens) — **all went `active`**. So provisioning
  validates only **container startup** (any handler response 200/4xx/500 is tolerated) and the code, deps,
  handler, model call, MCP path, HTTP status **and the agent name are all exonerated**. The sole remaining
  variable is the **specific original account instance** being in a bad/transient service state — NOT "all
  new accounts" (the fresh `hellofh2` works) and NOT a date-based regression. Do **not** "fix"
  identical-to-working code, re-grant RBAC, change region, or wait for it to "activate later" (it never does
  — all original a09081 versions stayed `failed`). **Response:** deploy the FH agents into a known-good
  project via `foundry.mode: reuse-existing` (see the Foundry-resource strategy below); if provisioning a
  new account fails, retry the deploy or re-provision a fresh account (very likely fine) rather than
  treating new accounts as cursed.

## Foundry-resource strategy (`solution.foundry`)
All FH **and** FD agents share ONE Foundry footprint defined by the optional `solution.foundry` block —
so a lab creates a single account + project + model deployment instead of one account per agent (the
scaffolder resolves each agent's target from it; when the block is absent the legacy per-agent behaviour
is unchanged). Two modes:
- **`create-shared`** (default): the wizard provisions ONE Foundry account + ONE project (`<prefix>`) +
  ONE model deployment (`gpt-4.1`) in `<prefix>-foundry-rg`; the FIRST FH agent runs `azd provision`
  (creating the shared account/project) + creates the model + grants RBAC, and every other FH agent runs
  `azd deploy` into that same project. FD agents deploy into it too. The Lab Cleaner removes the whole
  `<prefix>-foundry-rg`.
- **`reuse-existing`**: every FH/FD agent deploys into an existing account+project you supply
  (`foundry.endpoint` / `foundry.account` / `foundry.existingResourceGroup`); the scaffolder writes that
  endpoint into each agent and emits **deploy-only** commands (no `azd provision`). This is the resilient
  workaround when a specific account's hosted-agent provisioning is failing, and the Lab Cleaner deletes
  only the lab's agent objects from that project — never the user-owned account/project.

## Tools
FH samples currently wire **only Mail** in code. Attaching a non-Mail Work IQ MCP also needs the code
generalization documented in
[workiq-mcp-integration.md](../agent365-wizard/references/workiq-mcp-integration.md) — reuse the
per-request/per-turn token lessons there; do not re-derive them.
