# User-interaction points during provisioning

This document lists **exactly where a human must act** when planning and deploying the Agent 365
samples with the provisioning wizard (`.github/skills/agent365-wizard`) and the generated
next-commands. It is organized as a **common pre-flight** followed by **per-variant** steps
(ACA / FH / FD × OBO / S2S / DW) plus the **web UI**.

> **Golden rule on secrets.** Every *blueprint client secret* / API key is **typed directly into
> the terminal** at the prompt — never pasted into chat, because secrets must not pass through the
> assistant. Retrieve a blueprint secret later with `a365 setup blueprint --show-secret` (same
> folder, user, machine).

---

## 0. Common pre-flight (once per solution)

| Step | Where / how | Notes |
| --- | --- | --- |
| **Wizard interview** — variants, UI mode, solution prefix, region, RG strategy, Azure OpenAI account + model, ACA auth (MI/key), Foundry new/reuse + model, DW enrollment, UI-exposed agents, Foundry-access grantees | **Chat** (answer the questions) | Minimal questions; everything else is discovered/derived |
| **`az login`** into the **target** tenant, then confirm subscription + tenant | **Terminal** (interactive browser) | On multi-tenant machines re-pin `az account set --subscription <TARGET>` and verify `az ad signed-in-user show` before every `az ad`/Graph call |
| Tooling present: `a365`, `azd`, `python`, `npx` | Automatic check | Install anything missing |
| **Plan review + approval** (derived names, blockers such as prefix/DW-length/shared-RG) | **Chat** ("Go") | Prefix must start with a lowercase letter; DW blueprint display name ≤ 30 chars |
| **Scaffold confirmation** | **Chat** | Generates `generated/<agent>/` + `generated/<prefix>-ui/config.js`; no cloud changes |

---

## 1. ACA variants (`a365` CLI + `deploy-aca*.ps1`)

### Common to ACA-OBO / ACA-S2S / ACA-DW
| Step | Where / how |
| --- | --- |
| `a365 setup all` first sign-in (WAM) | Popup / device-code (usually served from the DPAPI token cache) |
| **Delegated admin-consent** for the blueprint | **Browser → Accept** (auto-detected; often completes from cache) |
| Prompt **`Assign this application permission now? [y/N]`** (Observability) | Answer **y** |
| **Deploy** prompts for the **blueprint client secret** | **Type the secret directly in the terminal** — OBO via `Read-Host`, S2S/DW as a PowerShell mandatory parameter |

### ACA-DW extra (Digital Worker / AI teammate)
| Step | Where / how |
| --- | --- |
| Prompt **`ext_UtilityInsights — Provision via 'az ad sp create'? [y/N]`** | Answer **N** — it is an **optional custom MCP** that may be absent in the tenant; add it explicitly only when wiring that tool |
| **Messaging endpoint URL** prompt | Leave **blank** the first time (container not deployed yet); after deploy re-run `a365 setup all --aiteammate` and paste the real `https://<fqdn>/api/messages` |
| **Publish the manifest** | Run `a365 publish --aiteammate --agent-name "<agent-name>"` (the `--agent-name` flag is **required**; answer **n** then **Enter** at the manifest prompts) to regenerate `manifest/manifest.zip` for **this** blueprint, then in **M365 admin center → Copilot → Agents → + Add agent / Upload custom agent** upload `manifest.zip` (wizard: Upload → Publish to users/Activate → Apply template → Accept permissions → Review & finish → Publish) |
| **Hire + license + policy** | **Portal / Teams** (manual) — the instance appears under **Instances** (or **Requests** if pending) only *after* publish + a user hire |

---

## 2. FH variants (`azd` + Foundry extension)

### Common to FH-OBO / FH-S2S / FH-DW
| Step | Where / how |
| --- | --- |
| `azd auth login` if the azd credential is stale (`AzureDeveloperCLICredential exit 1`) | **Browser** |
| `azd provision` / `azd deploy` | Non-interactive (`--no-prompt`); needs model **quota** in the region |
| **Model deployment + RBAC** (FH-OBO/S2S) | The generated next-command **creates the model deployment** (azd does *not*) and grants **Cognitive Services User** on the Foundry account before `azd deploy` (RBAC propagates ~2–5 min) |

### FH-DW extra (governed-subscription / Solution A)
| Step | Where / how |
| --- | --- |
| **Out-of-band blueprint** between two provisions | Terminal: `azd provision` (blueprint deployment-script step fails under a shared-key-storage policy — expected) → `scripts/create-agent-blueprint.ps1` (creates the MAIB via an Entra ID call, grants the role, sets `AGENT_IDENTITY_BLUEPRINT_CLIENT_ID`) → `azd provision` again. **No policy waiver.** |
| **Admin approval + hire/license** | **M365 admin center → Agents → Requested** (the publish is automatic via azd), then hire in Teams |
| **No client secret** to type | — |

---

## 3. FD variants (Python SDK — prompt/declarative agents)

| Step | Where / how |
| --- | --- |
| `az login` (DefaultAzureCredential) + **RBAC grant** | Terminal — the next-command grants **Cognitive Services User** on the reused Foundry account before `python deploy_agent.py` |
| `python deploy_agent.py` | Non-interactive — **no secret, no portal** |
| **FD-OBO** mail testing only | `python get_mail_token.py` performs an interactive sign-in to obtain a delegated Mail token (used only when exercising the mail path) |

> FD agents are **not** Digital Workers (prompt agents cannot be autopilot-published); they are used
> via the Responses API / the web UI.

---

## 4. Web UI (SPA on Azure Static Web Apps)

| Step | Where / how |
| --- | --- |
| Create the SWA (Free tier) | Terminal — use a supported region (e.g. `eastus2`; `westeurope` may reject new customers) |
| Register the **SPA app** (`<prefix>-ui-spa`), set redirect URIs (`https://<swa-host>` + `http://localhost:3000`), add permissions, **admin-consent** | Terminal (`az ad` / `az rest`) — run as the target-tenant admin |
| Fill `config.js` with the real endpoints, deploy to the SWA | Terminal (`npx @azure/static-web-apps-cli deploy`) |
| Wire ACA agents: `UI_ALLOWED_ORIGINS` (CORS) on OBO/S2S + `UI_AUDIENCE=<s2s-app-id>` on ACA-S2S | Terminal (`az containerapp update`) |
| **First use of each tab** — one-time **incremental consent** (Mail for OBO; `ai.azure.com/.default` for Foundry tabs) | **Browser** (expected, per user) |
