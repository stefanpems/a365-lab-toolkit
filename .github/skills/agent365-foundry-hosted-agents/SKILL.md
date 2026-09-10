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
  scaffolder rewrites every occurrence to `<prefix>-MAF-FH-DW`. Verify the deployed agent uses the planned
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
- **⛔ Persistent generic `ProvisioningError` ("Please retry") is a REAL hosted-agent BUILD/STARTUP failure
  of THAT specific package version — it never "activates later" — and the evidence points to the PACKAGED
  CODE/CONTENT of the failing version, NOT to the current lab code and NOT to a universal account/service
  defect.** Investigation (a09081, 2026-09-08/09). Two earlier conclusions were reached and then CORRECTED —
  recorded here so the mistakes are not repeated:
  * **Symptom:** deploying `a09081-FH-OBO` to its own newly-created account (`cog-6czcacgtxvu6e`) produced
    versions v1–v7 all `failed` with `ProvisioningError`, while the same-named agent deployed `active` in an
    earlier project (h2256). ⛔ First (wrong) guess: "service-side regression on newly-created accounts /
    creation date" — REFUTED: a fresh account `hellofh2` provisions hosted agents fine.
  * **A→H bisection** on the good `hellofh2` (echo agent, then one layer added per step: real deps → module
    imports → per-turn client → model call → MCP handshake → a handler returning **HTTP 500** → the full
    real agent under the exact name `a09081-FH-OBO`): **all `active`**. This established a solid fact —
    provisioning validates only **container STARTUP** (any handler response 200/4xx/500 is tolerated), so no
    handler/logic/model/MCP/name path can cause `ProvisioningError` — but it did **not reproduce** the
    failure. ⛔ Second (premature) conclusion: "specific account-instance defect, code exonerated."
  * **The `content_hash` twist (decisive correction):** re-deploying to the ORIGINAL failing account NOW,
    the **current** package (`content_hash e75cd935`) went `active` and stable (12/12 item reads) — that
    account CAN provision a hosted agent. But the versions that actually failed were **two different OLDER
    packages** (`aa98f426` for v1–v3, `fc0727fd` for v4–v7); the working version is a **third, non
    byte-identical** package (the current lab folder differs — e.g. no `.agentignore`/`README`/
    `.env.template` packaged, and/or the code changed since). So the A→H "exoneration" was built on the
    CURRENT code, not on the artifact that failed. ⛔ **Never compare "the same agent" by name — compare
    `content_hash`.**
  * **Best-supported conclusion:** the failure most likely came from the **old package's content**
    (dependency / remote-build / startup, or stray packaged files) which the current lab code no longer has:
    the **same account** fails with the old packages and succeeds with the current one, and **two distinct**
    old packages both failed. It is **NOT 100 % conclusive** — the code AND ~8.5 h of elapsed time changed
    together, so a transient account condition during v1–v7 cannot be fully excluded. **The one clean
    disambiguator:** deploy a **byte-identical OLD failing package** (reproduce hash `aa98f426`/`fc0727fd`
    from git history) onto a **known-good** account → `failed` there ⇒ CODE/PACKAGE; `active` there ⇒ the
    v1–v7 failures were a transient account condition.
  * **Response / resilience (holds either way):** the CURRENT lab code provisions cleanly on every account
    tried (including the one that first failed), so (1) **re-deploy with the current code**; (2) if a fresh
    account still fails, **retry the deploy** and/or re-provision, or deploy into a known-good project via
    `foundry.mode: reuse-existing` (below); (3) do **not** wait for "activate later" (it never does — all
    original a09081 versions stayed `failed`). Read the single-version ITEM `.status`/`.error`, never the
    LIST. If it recurs and you need a new root cause, run the playbook below.
- **External root-cause playbook (run OUTSIDE the lab-creation session — reproduce FIRST, then bisect):**
  1. **Reproduce fully, first.** In a standalone azd Foundry hosted-agent harness, deploy the **exact failing
     artifact** (same `content_hash` — the deployed package, or the matching git commit) to the same target
     and confirm `failed` on the single-version ITEM. Do not proceed until the failure reproduces — building
     UP from a hello-world with *current* code (what we did) can silently use a different package and produce
     a false "exonerated".
  2. **Cross the two variables in two deploys.** Deploy that SAME failing artifact to a **known-good** account,
     and the **current** artifact to the failing account. This separates CODE from ACCOUNT directly.
  3. **Only then bisect** the confirmed-failing artifact in SMALL steps (strip stray packaged files / pin or
     remove deps / simplify startup / `dependencyResolution`) until it flips to `active`; the last change that
     flips it is the cause.
  4. **Always record `content_hash`** at every deploy and read the ITEM `.status`/`.error`, so "works vs
     fails" is compared on identical bytes, not on the agent name.

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
