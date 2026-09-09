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
- **⛔ `a365 setup all` + `deploy-aca*.ps1` must run FROM the agent folder.** `a365 setup all` writes
  `a365.generated.config.json` (blueprint ids + DPAPI secret) and stamps `.env` only via its "project
  settings" step, which runs **only when it detects the project in the current directory**; run it
  elsewhere and it prints *"No … project detected … skipping project settings"* — then the deploy
  can't find the blueprint id and `--show-secret` fails. An automation runner's leading `cd` in an
  **async** shell can be dropped (runs from the repo root): set the cwd first (`Set-Location
  <agent-folder>`), run sync, verify `$PWD`. The deploy scripts self-heal (resolve the blueprint by
  display name, write a minimal config) as a backstop, but the correct cwd is still needed for
  `.env`/secret persistence.
- **⛔ `a365 setup all` completion = the ARTIFACT, not the terminal.** After the browser admin consent,
  the command can **linger without flushing/exiting** — the terminal keeps showing the same last line
  (e.g. "Configuring application permissions … Observability API") for minutes though it already
  succeeded. Do NOT keep re-reading the terminal buffer. Done = `a365.generated.config.json` exists with
  every `resourceConsents[].consentGranted == true`. Run it async with `Tee-Object -FilePath <log>`,
  announce the browser gate once, then poll the **file**. A missing `.env`/`completed:false` does not
  block `deploy-aca-*.ps1`.
- **`" Agent"` suffix** in the Registry (e.g. `<name> Agent`) is cosmetic CLI behavior — do not "fix" it.
- **ACA-DW is not auto-listed** like OBO/S2S: after deploy, `a365 publish --aiteammate --agent-name
  "<name>"` regenerates `manifest/manifest.zip`; upload it in the M365 admin center (Agents → Upload
  custom agent), then a user hires it in Teams. ⛔ **`a365 publish --aiteammate` is INTERACTIVE — never
  pipe it** (a `Tee-Object | Select-String` pipe hides the prompts and blocks stdin, hanging it). Run it
  with no pipe and answer: `Open manifest in your default editor now? (Y/n)` → **`n`** (keep lab
  defaults); `Press Enter … to continue:` → **Enter**; success = `Package created: …manifest.zip`.
- **Shared-RG is unsafe for ACA-OBO**: the generic `deploy-aca.ps1` deletes its RG. Use isolated RGs,
  or `-ReuseEnv`. (The scaffolder blocks shared-RG + ACA-OBO.)
- **⛔ AOAI endpoint comes from `env/.env.playground.user`, which the scaffolder copies from the
  sample = a PRIOR lab's account.** The deploy stamps the container `AZURE_OPENAI_ENDPOINT` /
  `AZURE_OPENAI_DEPLOYMENT` from that file, so a stale value points the container at the wrong Azure
  OpenAI account — where its managed identity has no role → **`401 PermissionDenied … chat/completions`
  even though the role is correctly assigned on the plan's account** (the misleading part). Fixed in the
  scaffolder (it now overwrites `env/.env.playground.user` `AZURE_OPENAI_ENDPOINT` +
  `AZURE_OPENAI_DEPLOYMENT_NAME` from `plan.agents[].ai.account/deployment`) and the deploy scripts (they
  force `AZURE_OPENAI_ENDPOINT` from `-AoaiAcc`). If you still see this 401, verify
  `az containerapp show … --query "properties.template.containers[0].env"` points at the plan's account,
  not a prior one; `az containerapp update --set-env-vars AZURE_OPENAI_ENDPOINT=https://<acct>.openai.azure.com/
  AZURE_OPENAI_DEPLOYMENT=<deployment>` fixes a live container.
- **AcrPull race on ACA-OBO's first deploy.** `deploy-aca.ps1` uses `az containerapp up`, which can
  create the app before the system MI has AcrPull on the auto-created ACR → the first revision falls
  back to `mcr.microsoft.com/k8se/quickstart` (health may 200 but it's the placeholder, not your agent).
  The script now detects this and remediates (grant AcrPull + set the real image). S2S/DW use admin
  registry creds and are unaffected.

## Tools
The ACA turn path is **manifest-driven**, so attaching any Work IQ MCP works generically. Token/refresh
lessons (token-TTL rebuild, `x-ms-agentid` stamping, benign teardown-DELETE, S2S degrade-to-LLM) are in
[workiq-mcp-integration.md](../agent365-wizard/references/workiq-mcp-integration.md) — reuse, don't re-derive.
