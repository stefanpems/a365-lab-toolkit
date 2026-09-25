# Variant matrix — inputs, tooling, hosting

**10** supported variants: the **8** Agent 365 code/prompt variants below, plus the **2 Microsoft Copilot
Studio (MCS)** variants (MCS-OH / MCS-NH — see "Microsoft Copilot Studio (MCS) family"). **FD-DW is not
supported**: a Digital Worker runs on a Bot Framework / Teams messaging surface (a hosted container
exposing `/api/messages`), but a Foundry declarative (prompt) agent is platform-run with no container,
code or endpoint and cannot host it — use ACA-DW or FH-DW.

| Variant | Hosting | Identity | Setup tool | Config | Endpoint | Needs Frontier | UI-exposable |
|---------|---------|----------|-----------|--------|----------|----------------|--------------|
| ACA-OBO | Container Apps | OBO (acts as user) | `a365` CLI | `a365.config.json` | Bot `/api/messages` + `/chat` | no | yes |
| ACA-S2S | Container Apps | S2S (own app) | `a365` CLI | `a365.config.json` | Bot + `/chat` | no | yes |
| ACA-DW  | Container Apps | Digital Worker | `a365` CLI | `a365.config.json` | Bot + Teams | **yes** | no (Teams/Outlook) |
| FH-OBO  | Foundry hosted | OBO | `azd` + Foundry ext | `azure.yaml` + `.env` | Invocations | no | yes |
| FH-S2S  | Foundry hosted | S2S | `azd` + Foundry ext | `azure.yaml` + `.env` | Responses | no | yes |
| FH-DW   | Foundry hosted | Digital Worker | `azd` + Foundry ext | `azure.yaml` + `.env` | Bot + Teams | **yes** | no (Teams/Outlook) |
| FD-OBO  | Prompt (platform) | OBO | Python SDK | `.env` | Project Responses | no | yes |
| FD-S2S  | Prompt (platform) | S2S | Python SDK | `.env` | Project Responses | no | yes |
| MCS-OH  | Copilot Studio (Dataverse) | maker/user (delegated) | `pac` CLI | Solution (Dataverse) | Copilot Studio / Teams | no | no (Copilot Studio/Teams) |
| MCS-NH  | Copilot Studio (Dataverse) | maker/user (delegated) | `pac` CLI | Solution (Dataverse) | Copilot Studio / Teams | no (needs Copilot Credits) | no (Copilot Studio/Teams) |

## Inputs the wizard MUST ask (grouped)

### Common (all variants)
- **Solution prefix** → derives all agent names as `<prefix>-<framework>-<hosting>-<identity>` (the
  `<framework>` segment is fixed — `MAF` today — e.g. `contoso-MAF-ACA-OBO`).
- **Tenant / Subscription** → auto-detected; user confirms or overrides.
- **Preferred region** → validated per service.
- **Resource-group strategy** → per-agent (`<agent>-rg`, default) or shared (`<prefix>-rg`).

### Any ACA
- **Azure OpenAI strategy** (`solution.azureOpenAI`), asked ONCE (all ACA agents share it): **create a
  new lab-owned account + deployment** (`create-shared`, **DEFAULT** — `<prefix>aoai` in
  `<prefix>-aoai-rg`, deleted by the Lab Cleaner) or **reuse an existing account + deployment**
  (`reuse-existing` — only then list which one).
- Auth: **Managed Identity (default)** or API key (fallback; entered in terminal, never chat).

### Any FH
- Foundry project: **new** (created by `azd provision`) or **existing** (verify endpoint).
- Chat model deployment name.

### Any FD
- Foundry project + deployed model. Resolve in this priority: (1) **reuse the FH project** if an FH
  variant is also selected; (2) **create one** (AIServices account + project + chat-model deployment)
  if the user has none; (3) **reuse an existing** project if the user prefers. A pre-existing project
  is NOT required — the wizard can create it.

### Any DW (ACA-DW / FH-DW)
- Confirm Frontier / Agent 365 enrollment + license capacity.
- Policy-template choice (portal step — surface as a checkpoint).

### Any MCS (Copilot Studio: MCS-OH / MCS-NH)
MCS agents are Power Platform **Solutions** imported into a **Copilot Studio environment** with `pac`
(not Azure/Entra agents). They are built by transforming a committed base solution zip
(`agent365-copilot-studio/assets/base-solutions/AgentOHSol.zip` = legacy harness, `AgentNHSol.zip` = GHCP
harness) — NOT regenerated per run. See the **agent365-copilot-studio** sub-skill.
- **pac CLI** is a prerequisite. If MCS is selected and `pac` is missing → install it
  (`dotnet tool install --global Microsoft.PowerApps.CLI.Tool`) or drop the MCS agent.
- **Target Copilot Studio tenant** (`solution.copilotStudio.targetTenantId`) — often NOT the usual az
  tenant; `pac auth create --tenant <id>` is explicit. Cross-tenant is the norm.
- **MCS-NH gate (required):** confirm the target PP **environment** is **PAYG-linked + Dataverse-enabled +
  Copilot Studio**, and capture its **Environment ID** (`solution.copilotStudio.targetEnvironmentId`).
  Verify with `Test-McsPrereqs.ps1 -Harness MCS-NH -EnvironmentId <id>`; without Copilot Credits the agent
  fails at preview with `EnforcementUsageCredits`. **MCS-OH has NO such prerequisite** (any Dataverse env).
- **Optional MCP integration** (`agents[].mcp` = subset of `mail` / `anon` / `auth`): wired via a custom
  Entra client app on the **Agent 365 tool gateway** (`New-McsMcpClientApp.ps1`) + a guided Copilot Studio
  MCP-tool step. **Mail** is the tested path; **anon/auth** are experimental (see the sub-skill's
  `references/mcp-integration-feasibility.md`).
- **Publish org-wide** (`agents[].publish`): after import, a guided maker-portal step (Availability options
  -> "Show to everyone in my org").

### UI (if selected)
- New UI: name (default `<prefix>-ui`), local-only or Azure Static Web App. **SWA region:** SWA Free is
  only offered in a few regions (`eastus2`/`centralus`/`eastasia`/`westeurope`/`westus2`) and the SPA is
  served from a global CDN, so it need not match the lab region. If the lab region is **not** one of them
  (e.g. `swedencentral`), **ask the user** whether it is OK to use a different region for the Free SWA
  (recommend the nearest allowed — `westeurope` in Europe, else the validated `eastus2`) or to pick
  another allowed region; write the choice to `ui.swaRegion`.
- Existing UI: SPA app registration + origin + existing SWA.
- Agents to expose: multi-select of the OBO/S2S agents.
- If exposing OBO → Mail consent `McpServers.Mail.All`.
- If exposing ACA-S2S → blueprint scope `api://<s2s-app-id>/access_agent_as_user` + `UI_AUDIENCE`.
- If exposing **FH or FD** (Foundry-based) → **who to authorize**: who gets **Cognitive Services User**
  on the shared Foundry account (the SPA calls the Foundry data plane, which checks Azure RBAC). The
  **default is just the signed-in user** (fine for a solo lab), but the answer **also accepts a
  comma-separated list of UPNs** (several testers) **and/or a group object id** (recommended for many
  testers — grant the role to the group once and manage membership there). Every entry is written to
  `ui.permissions.foundryAccess` and granted by the scaffolder (the signed-in deploy user is always
  granted too). **ACA agents need none** (they run on Container
  Apps, no Foundry) — do not ask this for an ACA-only UI.

### Custom MCP (optional — sample `custom-mcp/`)
Single-select: *None* / *Anonymous only* / *Authenticated only* / *Both*. If anything but None:
- **No name is asked.** The servers derive from the **solution prefix** (the same unique key as the web
  UI): registered as `ext_<prefix>Anon` / `ext_<prefix>Auth`, Azure resources `<prefix>-mcp-*`, scaffold
  folder `generated/<prefix>/<prefix>-mcp/`. The prefix must be ≤ 12 alphanumerics when the custom MCP is
  enabled (so `ext_<prefix>Anon/Auth` stays ≤ 20; validated by the scaffolder). For N coexisting copies use
  a different prefix each run and check the tenant (`a365 develop list-available`) for an existing
  `ext_<prefix>*` collision.
- **Publisher** name (registration metadata, e.g. `Contoso`).
- **Attach to**: multi-select of the deployed **OBO** agents only (`ACA-OBO` / `FH-OBO` / `FD-OBO`).
  S2S and DW are **not offered**: a BYO server needs a Power Platform connection owned by the invoking
  identity, and only an OBO agent invokes as the signed-in user who owns it — S2S (own app identity) and
  DW (projected `agentUser` identity) can neither own it nor be granted it (preview:
  `ConnectionSharingNotAllowed`), and S2S also can't mint the custom-audience token from the SPA
  (`AADSTS82001`/`82002`). Known preview limitation.
- **Integration mode** (single-select, asked right after the servers are registered — a BYO server must be
  **admin-approved** in the M365 admin center before it can be attached): *approve-first* (default) = approve the
  `ext_*` servers BEFORE creating the agents, so each OBO agent integrates them (with permissions)
  immediately as it is provisioned; *attach-when-approved* = start the agents now and integrate
  each OBO agent only if the servers are approved by the time it deploys, otherwise attach them manually
  later. Writes `customMcp.integrationMode`.
- **`propagate_to_graph`** (auth server only): enable the advanced On-Behalf-Of Graph test? **Default:
  enable.** If enabled, surface the Entra prerequisites (confidential client + Graph `User.Read` + admin
  consent) as a checkpoint.
- One ACA container hosts both servers on two paths; registration is per-server (auth type is
  per-registration): NoAuth for `/anon/mcp`, EntraOAuth for `/auth/mcp`. Admin approval of each
  registered server happens in the M365 admin center (not CLI).

### Registered MCP tools per agent (Work IQ / catalog / third-party)
For each **ACA-*/FH-*** agent, which registered MCP servers should it use? (This `add-mcp-servers`
multi-select is ACA/FH only — FD prompt agents wire tools in `agent_config.py`; for a custom BYO server,
FD-OBO uses `CUSTOM_MCP_SERVERS_JSON`, see **Custom MCP** above.)
- Source the choices **live** from `a365 develop list-available` (shows Work IQ `mcp_*`, approved custom
  `ext_*`, and third-party). **Show ALL Work IQ servers, but only `mcp_MailTools` is SELECTABLE today** —
  keep the rest **visible but disabled**, with the note: *"the solution is wired to add more Work IQ MCPs;
  for now only the tested ones (Mail) are enabled."* The delegated permission each Work IQ server needs is
  already mapped in [workiq-mcp-integration.md](./workiq-mcp-integration.md) and `scripts/modules/_common.ps1`
  (`$WORKIQ_MCP_CATALOG`), so enabling one later is a small, pre-scoped step.
- **Offer the Mail selection to OBO and DW agents only, and pre-select `mcp_MailTools` there** (they can
  use delegated Work IQ). ⛔ **EXCLUDE every S2S agent from the Mail choice entirely** — do NOT list S2S
  agents as options (not even unselected): pure S2S (app-only) cannot call delegated Work IQ tools
  (`AADSTS82001`), so Mail integration is **not available** for S2S today, and whether/how it could be
  supported is still to be determined. Deselect Mail on an OBO/DW agent to make it Mail-free.
- Allow a **free-text** entry for any additional registered `uniqueName` (must start with `mcp_` or
  `ext_`); warn if it is not in `list-available` (not registered/approved yet).
- Writes `agents[].tools`. The scaffolder makes each agent's `ToolingManifest.json` **authoritative =
  exactly these tools BEFORE `a365 setup all`**, so the granted MCP permissions follow the selection
  exactly (an agent without Mail gets **no** Mail permission). Custom `ext_*` servers are attached per
  agent immediately after it deploys, honoring `customMcp.integrationMode`.
- **Reuse the Work IQ token lessons** for any non-Mail Work IQ tool — see
  [workiq-mcp-integration.md](./workiq-mcp-integration.md). ACA-OBO/DW are manifest-driven (generic, it
  just works); ACA-S2S can't use delegated Work IQ tools (LLM-only); FH/FD samples wire only Mail in
  code today, so a non-Mail Work IQ tool needs the code generalization noted in that reference.

## Framework segment in the name (fixed today, multi-framework later)
Every **code/prompt** agent name carries a fixed **`<framework>`** segment:
`<prefix>-<framework>-<hosting>-<identity>` (e.g. `contoso-MAF-ACA-OBO`). Today the only framework is
**MAF**, so the plan writes `framework: "MAF"` on every code/prompt agent (default when omitted).

**Exception — MCS (Copilot Studio) uses a 3-part name with NO framework segment:**
`<prefix>-MCS-<OH|NH>` (e.g. `contoso-MCS-OH`). MCS is a Copilot Studio agent, not a code framework, so it
carries no `MAF`/framework token. The scaffolder validates MCS names as `<prefix>-MCS-OH` / `<prefix>-MCS-NH`.

The Agent 365 integration is framework-agnostic (identity, MCP gateway, messaging), so growing the lab to
other frameworks later means: per-framework source folders (e.g. `aca-langchain/…`), a new short framework
code (e.g. `LC`, `SK`) written to `agents[].framework`, and the scaffolder mapping `type` → the matching
source. ACA and FH are the natural hosts for code frameworks; FD (declarative prompt agents) is
framework-independent (still named with a framework segment for consistency). The token/auth lessons in
workiq-mcp-integration.md apply unchanged to any framework. Only **MAF** source folders exist today.

## Do NOT ask (discover / derive / fixed)
- Blueprint / identity / container / bot / app-reg names → derived from the prefix.
- Log Analytics workspace names, endpoints, app IDs, blueprint IDs → discovered post-deploy.
- Fixed first-party scopes: Mail `ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/McpServers.Mail.All`,
  Foundry `https://ai.azure.com/.default`.
- Localhost redirect URI `http://localhost:3000`, API versions, agent descriptions.
- **Web access (`fetch_url`)** → always on for the 8 code variants (never asked, no plan field); the
  FD web-fetch MCP names (`<prefix>-webfetch-rg` / `-cae` / `-ca`) are derived from the prefix. See
  [web-fetch-mcp/README.md](../../../../web-fetch-mcp/README.md).

## Credentials (never in chat, never in the plan)
| Secret | How the scripts get it |
|--------|------------------------|
| Blueprint client secret (ACA) | `Read-Host` in the deploy script, or `a365 setup blueprint --show-secret` |
| Azure OpenAI API key | terminal input into a gitignored `.env`, or use Managed Identity |
| Delegated Mail / Foundry token | acquired at runtime via MSAL / the `az` token cache |

## Endpoint / scope shapes (for `ui/config.js`)
- `kind: "aca"` → `apiBase` + `scope` (S2S: `api://<app-id>/access_agent_as_user`; OBO: Mail scope).
- `kind: "foundry-invocations"` (FH-OBO) → `endpoint` + `endpointScope` + `mailScope` + `sessionPrefix`.
- `kind: "foundry-responses"` (FH-S2S) → `endpoint` + `endpointScope`.
- `kind: "foundry-prompt"` (FD) → `endpoint` + `endpointScope` + `agentName` (+ `mailScope` for OBO).

Reference: [ui/config.js.example](../../../../ui/config.js.example),
[docs/setup-web-ui.md](../../../../docs/setup-web-ui.md).
