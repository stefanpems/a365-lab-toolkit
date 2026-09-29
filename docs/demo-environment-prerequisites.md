# Demo environment prerequisites (agent-governance demo pack)

This page lists everything a tenant needs before the Demo Builder creates the full demo environment of the
[agent-governance demo pack](../demo-packs/agent-governance/README.md): licenses, tenant features, Power Platform,
Purview, Defender, Entra, Azure, workstation tools, people and lead times. The lab-level prerequisites of every agent
variant (Azure providers, `a365` CLI permissions, consent) stay in the
[central prerequisites checklist](./prerequisites-checklist.md): they are referenced here, not repeated.

**The license gate (section 1) is the first step of every build.** In this release the Demo Builder runs the
read-only check [Test-DemoPrereqs.ps1](../.github/skills/agent365-demo-builder/scripts/Test-DemoPrereqs.ps1) and, where
no API exists, asks you to confirm the manual checks listed below. Nothing is created until the gate passes.

> The Demo Builder is a **preview, not yet validated end to end**: this list comes from a reference lab built by hand.

## 1. License gate

The counts are derived from `demo-packs/agent-governance/pack.json` (`personas[].licenses`, `agents[].instance`). They
are **free seats** (purchased minus assigned) that the build assigns to the demo people; your own admin account is not
counted.

| License role | Default SKU (part number) | What it enables in the demo | Seats needed |
|---|---|---|---|
| Copilot user | `MICROSOFT_365_E7_NO_TEAMS` (or `MICROSOFT_365_E7`) | Microsoft 365 Copilot, Agent 365 user features, Exchange mailbox (also needed for the profile photo), Entra ID P2 and ID Governance for agents | **11** (see below) |
| Teams | `Microsoft_Teams_Enterprise_New` | Teams for the people whose Copilot SKU has no Teams | **9** (0 with a SKU that includes Teams) |
| Frontier agent | `MICROSOFT_AGENT_FRONTIER_NO_TEAMS` | the agent user of the AI-teammate instance (one per instance) | **1** |

How the Copilot-user seats add up:

| Who | Seats | When |
|---|---|---|
| the 8 people of the story (AI, identity, compliance and SOC administrators, maker, case officer, director, program lead) | 8 | for the whole life of the demo: every persona needs a mailbox (profile photo, approval and alert e-mails) and signs in to Microsoft 365 |
| the two "leavers" (creators of the ownerless-agent demos D1, D5, D8) | 2 | from creation until their permanent deletion (the day before the D8 rule); **1** again during every reset of D5 or D8 (temporary leaver, about 10 minutes) |
| the AI-teammate instance (mailbox of the agent user) | 1 | for the whole life of the demo |
| **Peak during the build** | **11** | keep **1** free afterwards for the resets |

Teams seats: the 8 people of the story and the AI-teammate instance (9); the leavers do not need Teams.

### 1.1 Check it automatically

```powershell
pwsh -File .github/skills/agent365-demo-builder/scripts/Test-DemoPrereqs.ps1 -Prefix <prefix>
```

It reads the SKUs of the tenant (`GET /subscribedSkus`), subtracts the seats already held by existing demo people,
checks that each SKU carries the expected service plans (for example `AGENT_365` in the Copilot SKU) and fails the gate
when a role lacks free seats. It changes nothing.

### 1.2 Check it manually (first releases)

1. Microsoft 365 admin center → **Billing → Licenses**.
2. For each SKU of the table open the product and read **Available licenses** (= purchased − assigned).
3. The gate passes when every value is at least the "Seats needed" of the table (Teams: 0 needed when your Copilot SKU
   already includes Teams).
4. Not enough seats? Free them with the **License Reclaimer** agent of this repo (it removes licenses from chosen users
   without deleting them, and handles the dependent add-ons that block a removal).
5. Assign the licenses at least **24 hours** before the rehearsal: the usage metrics of the registry (D1, D2) start
   only when real users hold the licenses.

## 2. Tenant features (manual checks — no API)

| Check | Where | Needed by | Lead time |
|---|---|---|---|
| **Copilot Frontier** enabled | Microsoft 365 admin center → Copilot → Settings → View all → Copilot Frontier | the AI teammate (D7, D13, D15) | up to 3 h |
| **Agent 365 Frontier** terms accepted (Global Administrator) | Microsoft 365 admin center → Agents → Overview → Try now → accept the terms | AI-teammate templates and instances (D7) | minutes |
| Agent 365 license active on real users | section 1 | custom templates (D7), management rules (D8), metrics (D1, D2) | 24 h for metrics |
| Registry privacy setting "Conceal user, group, and site names in all reports" **off** | Microsoft 365 admin center → Settings → Org settings → Reports | readable names in D1, D2 | minutes |
| Tags allowed (max 50 per organization) | Microsoft 365 admin center → Agents → Settings → Tags | D1 filter, D4 | minutes |

## 3. Power Platform and Copilot Studio

| Check | Why | How to verify |
|---|---|---|
| One **pay-as-you-go environment with Dataverse and Copilot Credits** (the "payg" environment of the pack) | the new-harness Copilot Studio agents (grants desk, pilot copy, site inspections) fail at preview without credits; it also hosts the communications assistant | `pwsh -File .github/skills/agent365-copilot-studio/scripts/Test-McsPrereqs.ps1 -Harness MCS-NH -EnvironmentId <id> -Tenant <tenant>` |
| The tenant **default environment** | the unauthenticated prototype of D14 lives there on purpose | Power Platform admin center → Environments |
| The operator is **System Administrator** of the default environment | a Global Administrator is NOT one by default there: authentication settings show "Try that again" and knowledge uploads fail | Power Platform admin center → Environments → the default environment → Membership → **Add me** |
| "No authentication" allowed for agents of the default environment | the prototype of D14 is unauthenticated on purpose (after its Microsoft channels are removed) | Power Platform admin center → Security → Identity and access → Authentication for agents; change it only for the demo and restore it after the event |
| Power Platform **IP firewall not enforced** on both environments | admin-center actions on Copilot Studio agents (D5) fail when it is enforced | Power Platform admin center → Security → Identity and access → IP firewall |
| `pac` CLI signed in to the tenant | solution import of the Copilot Studio agents | `pac auth list` |
| The demo people get **Environment Maker + Basic User** in the payg environment | maker and program lead build, publish and submit agents | done by the build (`pac admin assign-user`) |

## 4. Microsoft Purview

| Check | Needed by | Notes |
|---|---|---|
| Unified audit log ingestion **on** | D12 | on by default; Purview → Audit |
| An audit retention policy for `CopilotInteraction` and `AI*` (optional, shown as configuration) | D12 | depends on the licenses |
| **DSPM for AI** set up and its one-click policies created | D15 | at least **24 h** before the demo |
| Sensitivity label + DLP policy on the Microsoft 365 Copilot location | D12, D15 | the DLP policy must be active at least **4 h** before |
| Communication Compliance policy on Copilot interactions | D12 | matches appear after about 1 h; the Copilot Studio location needs Purview **pay-as-you-go billing** |
| eDiscovery case with the case officer and the AI-teammate mailbox | D13 | prepared the day before |
| Purview role groups for the compliance persona | D12, D13, D15 | eDiscovery Manager, Communication Compliance Investigators, Insider Risk Management Analysts, Content Explorer Content Viewer |

## 5. Microsoft Defender (protection demos C6, C7, D16, D17)

| Check | Notes |
|---|---|
| **Security for AI** turned on and the **Microsoft 365 connector** Connected | without the connector blocks still work but alerts and incidents do not appear |
| Copilot Studio **threat detection** set up on the payg environment | needs an Entra app with a federated credential and the Power Platform admin center setting (per environment) |
| The Agent 365 **real-time protection rule** of the pack on the records assistant | block mode |
| Saved advanced-hunting queries of the pack | shown in D17 |
| The operator slots of these demos filled locally | see [OPERATOR-SLOTS.md](../demo-packs/agent-governance/OPERATOR-SLOTS.md) |

## 6. Microsoft Entra

| Check | Why |
|---|---|
| **Security defaults disabled** | Conditional Access policies (D9, D11, D17) cannot coexist with security defaults |
| The operator account can create users, groups, role assignments, custom security attributes and entitlement-management objects | the build creates them; custom security attributes need **Attribute Definition / Assignment Administrator** even for a Global Administrator |
| Application permissions can be granted (admin consent) | agent-identity sponsors and attribute assignments are application-only APIs: the build uses a temporary app, deleted at the end |
| Device-code sign-in may be blocked by Conditional Access | the scripts use MSAL with the system browser instead |

## 7. Azure

Everything in sections 3–5 of the [central prerequisites checklist](./prerequisites-checklist.md) for the variants of
the pack (ACA-DW, ACA-OBO, ACA-S2S, FD-OBO, Copilot Studio), plus:
- quota for `gpt-4.1-mini` (Azure OpenAI, the ACA agents) and `gpt-4.1` (Foundry, the review agent) in the chosen region:
  the shared `gpt-4.1-mini` deployment is raised to the capacity of the pack (`solutionSizing.azureOpenAICapacity`, 600 =
  600K tokens per minute) by `Set-DemoAoaiCapacity.ps1`, because the Lab Builder default (20) returns HTTP 429 with the
  demo traffic; the regional GlobalStandard quota must allow it;
- a Static Web Apps Free region (`eastus2` is validated);
- Azure Container Registry + Container Apps for the demo MCP backends (one small container per backend).

## 8. Workstation

PowerShell 7, Azure CLI, the Agent 365 CLI (`a365`), the Power Platform CLI (`pac`), Git, Python 3.11+ with the packages
of [py/requirements.txt](../.github/skills/agent365-demo-builder/scripts/py/requirements.txt) (`msal`, `python-docx`,
`fpdf2`, `openpyxl`). No local Docker (images are built in the cloud with `az acr build`).

## 9. People, profile photos and browser profiles

One browser profile per persona (P1–P11 of the pack), each signed in once before the demo (MFA registration may be
requested), with its tabs open in demo order on the day. Passwords of the created people are written only to
`generated/<prefix>/demo/secrets/` (git-ignored).

Profile photos are **not shipped** with the repo. Put one JPEG or PNG per persona (at most 4 MB, square and at least
648 × 648 pixels recommended) in `generated/<prefix>/demo/photos/`, named `<personaKey>.jpg` or containing the
persona's given name and surname (for example `Portrait_Anna_Walsh.jpg`), then run
[Set-DemoPhotos.ps1](../.github/skills/agent365-demo-builder/scripts/Set-DemoPhotos.ps1). A photo needs the person's
mailbox (hence the Copilot-user license of every persona); set the leavers' photos before they are deleted — the reset
sets them again when it recreates a leaver.

## 10. Lead times (plan backwards from the demo day)

| Item | Lead time |
|---|---|
| Licenses assigned, first traffic | ≥ 24 h (better 3–5 days) |
| DSPM for AI one-click policies | ≥ 24 h |
| AI-teammate instance | minutes to hours; Teams can show it the next day |
| Copilot Frontier | up to 3 h |
| Share links of the shared Agent Builder agents opened by each recipient | right after sharing, before the creators leave |
| Permanent deletion of the leavers (ownerless agents) | at least two days before: the admin-center card can lag more than 12 hours or keep a ghost owner; the D8 rule itself is run live |
| BYO MCP server approval visible in Copilot Studio | up to 30 min |
| Agent install / pin to users | minutes to 6 h |
| DLP policy active | ≥ 4 h |
| Audit records of a live action | 60–90 min |
| Communication Compliance matches | about 1 h |
| Full reset of the demo state | the evening before every rehearsal and the live run |
