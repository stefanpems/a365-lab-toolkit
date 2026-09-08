---
name: "Agent 365 — ACA agents"
description: "Provision, scaffold, deploy and verify the Azure Container Apps (A365-SDK-hosted) sample agents: ACA-OBO (on-behalf-of the user), ACA-S2S (own app identity), ACA-DW (AI-teammate Digital Worker). USE WHEN the user wants to create/deploy an ACA agent, configure the a365 blueprint for a container agent, publish an ACA Digital Worker, or troubleshoot the ACA turn/tool path. Trigger phrases: 'ACA agent', 'Container Apps agent', 'deploy ACA', 'ACA-OBO/S2S/DW', 'AI teammate on ACA'. Sub-skill of the Lab Builder."
---

# Agent 365 — ACA agents (ACA-OBO / ACA-S2S / ACA-DW)

Thin orchestration for the Azure Container Apps family. **Canonical, field-verified setup detail is in
the per-variant guides — do not duplicate or renumber them:**
[setup-MAF-ACA-OBO.md](../../../docs/setup-MAF-ACA-OBO.md),
[setup-MAF-ACA-S2S.md](../../../docs/setup-MAF-ACA-S2S.md),
[setup-MAF-ACA-DW.md](../../../docs/setup-MAF-ACA-DW.md).

## What it owns
- ACA family scaffolding (module [scaffold.aca.ps1](../agent365-wizard/scripts/modules/scaffold.aca.ps1)):
  fill `a365.config.json`, rewrite the **hardcoded** deploy-script constants (RG / app / env / region),
  and emit the `a365 setup all` + `deploy-aca*.ps1` (+ DW publish) next-commands.

## Flow
1. Scaffold via the router: [scaffold-from-plan.ps1](../agent365-wizard/scripts/scaffold-from-plan.ps1).
2. Run the printed next-commands: `a365 setup all --agent-name <name>` → the variant's
   `deploy-aca*.ps1`. Auth to Azure OpenAI = Managed Identity (default) or API key (terminal only).
3. Register the messaging endpoint after the container is up; verify `/api/health`.

## Known corrections (apply these)
- **`ext_UtilityInsights` prompt** (`Provision via 'az ad sp create'? [y/N]`) → answer **N** (optional
  custom MCP usually absent; the `az ad sp create` failure is harmless).
- **`" Agent"` suffix** in the Registry (e.g. `<name> Agent`) is cosmetic CLI behavior — do not "fix" it.
- **ACA-DW is not auto-listed** like OBO/S2S: after deploy, `a365 publish --aiteammate --agent-name
  "<name>"` regenerates `manifest/manifest.zip`; upload it in the M365 admin center (Agents → Upload
  custom agent), then a user hires it in Teams.
- **Shared-RG is unsafe for ACA-OBO**: the generic `deploy-aca.ps1` deletes its RG. Use isolated RGs,
  or `-ReuseEnv`. (The scaffolder blocks shared-RG + ACA-OBO.)

## Tools
The ACA turn path is **manifest-driven**, so attaching any Work IQ MCP works generically. Token/refresh
lessons (token-TTL rebuild, `x-ms-agentid` stamping, benign teardown-DELETE, S2S degrade-to-LLM) are in
[workiq-mcp-integration.md](../agent365-wizard/references/workiq-mcp-integration.md) — reuse, don't re-derive.
