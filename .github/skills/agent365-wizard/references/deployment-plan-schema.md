# Deployment-plan schema (`a365-deployment-plan.json`)

The plan is **secret-free** JSON (parsed natively by PowerShell — no module needed): resource
references only, no keys/secrets/tokens. It is the single source of truth for scaffolding and (later)
execution. Tenant/subscription IDs are not secrets but are tenant-specific, so the plan file is
gitignored.

## Shape
```jsonc
{
  "version": 1,
  "solution": {
    "prefix": "<string>",                 // the LAB NAME (asked early) — e.g. contoso — lowercase letter first, lowercase alphanumeric only, 3-12 chars (custom MCP ext_ cap); must be UNIQUE per run (no existing generated/<prefix>/ or ext_<prefix>*)
    "tenantId": "<guid>",                 // discovered, confirmed
    "subscriptionId": "<guid>",           // discovered, confirmed
    "region": "<azure-region>",           // e.g. polandcentral
    "secretHandling": "manual",           // "manual" (default; the user handles secrets, the agent never reads/echoes them) | "assisted" (opt-in, THROWAWAY test labs only; the agent may read the blueprint secret from the setup log / 'a365 setup blueprint --show-secret' and supply it to the deploy; never echoed in chat; rotate after)
    "resourceGroupStrategy": "isolated",  // "isolated" | "shared"
    "sharedResourceGroup": "<name>",      // only when strategy = "shared"
    "namingMode": "default",              // OPTIONAL — "default" (or omit): enforce <prefix>-<framework>-<hosting>-<identity>. "custom": each ACA/FH/FD agent carries a free-form "name" (+ matching displayNames/resourceGroup); the wizard stamps a durable tag a365lab=<prefix> (Azure) / a365lab:<prefix> (Entra) on every lab-owned resource (Set-LabTags.ps1) so the Lab Cleaner still finds the lab. In custom mode MCS agents may carry a free-form DISPLAY name; their solution unique name stays prefix-derived (<prefix>MCS<OH|NH>[<n>]) so the Lab Cleaner's prefix fallback is unaffected.
    "foundry": {                          // OPTIONAL — shared Foundry footprint for ALL FH + FD agents
      "mode": "create-shared",            // "create-shared" (one account+project+model for the lab) | "reuse-existing"
      "resourceGroup": "<prefix>-foundry-rg", // create-shared: dedicated RG for the shared account
      "project": "<prefix>",              // create-shared: the single project name
      "deployment": "gpt-4.1",            // the single model deployment shared by all FH/FD agents
      "modelVersion": "2025-04-14",       // optional (defaults to 2025-04-14)
      "endpoint": "https://<account>.services.ai.azure.com/api/projects/<project>", // reuse-existing
      "account": "<name>",                // reuse-existing: account name (model check + cleanup scope)
      "existingResourceGroup": "<name>"   // reuse-existing: RG of the existing account
    },
    "azureOpenAI": {                      // OPTIONAL — shared Azure OpenAI footprint for ALL ACA agents (default create-shared)
      "mode": "create-shared",            // "create-shared" (DEFAULT — lab-owned NEW account+deployment, deleted by the Lab Cleaner) | "reuse-existing"
      "resourceGroup": "<prefix>-aoai-rg",// create-shared: dedicated lab-owned RG (the prefix filter discovers + purges it)
      "account": "<prefix>aoai",          // account name (create-shared: derived from prefix; reuse-existing: the chosen existing account)
      "deployment": "gpt-4.1-mini",       // model deployment shared by all ACA agents
      "modelVersion": "2025-04-14",       // optional (defaults to 2025-04-14)
      "auth": "managed-identity",         // "managed-identity" (default) | "api-key"
      "existingResourceGroup": "<name>"   // reuse-existing: RG of the chosen existing account
    },
    "observability": {                    // OPTIONAL — wire the sample agents' OpenTelemetry to Application Insights
      "appInsights": {
        "mode": "none",                   // "none" (default/omit = no wiring) | "create-shared" (lab-owned resource) | "reuse-existing" (existing user-owned resource)
        "resourceGroup": "<prefix>-appinsights-rg", // create-shared: dedicated lab-owned RG (deleted by the Lab Cleaner via the prefix)
        "name": "<prefix>-appinsights",   // create-shared: the Application Insights resource name
        "existingResourceGroup": "<name>",// reuse-existing: RG of the existing resource
        "existingName": "<name>"          // reuse-existing: the existing Application Insights resource name
      }
    },
    "copilotStudio": {                    // REQUIRED when any MCS agent is planned (Copilot Studio target)
      "targetTenantId": "<guid>",         // the Copilot Studio target tenant (often NOT the az tenant; cross-tenant is the norm)
      "targetEnvironmentId": "<guid>"     // the target PP environment GUID — REQUIRED for MCS-NH (must be PAYG + Dataverse + Copilot Studio); MCS-OH can use any Dataverse env
    }
  },
  "agents": [
    {
      "type": "ACA-OBO",                  // one of the 10 supported variants (8 code/prompt + MCS-OH/MCS-NH); the scaffolder $MAP key
      "framework": "MAF",                 // FIXED name segment identifying the agent framework (default "MAF"); today only MAF exists
      "name": "<prefix>-<framework>-<hosting>-<identity>",  // e.g. contoso-MAF-ACA-OBO — the <framework> segment is mandatory. A lab may hold N INSTANCES of a type: when a type has >1 instance EVERY instance name carries a 1-based '-<n>' suffix (contoso-MAF-ACA-OBO-1, -2); a single instance carries NO suffix.
      "displayNames": {
        "blueprint": "<name> Blueprint",  // OBO/S2S: "<name> Blueprint". DW: "<name>" (NO " Blueprint" suffix — a365 publish derives name.short from it and Teams/M365 rejects name.short > 30 chars)
        "identity": "<name> Identity"
      },
      "resourceGroup": "<name>",          // <agent>-rg (isolated) or the shared RG
      "ai": {
        "kind": "azure-openai",           // "azure-openai" (ACA) | "foundry" (FH/FD)
        "account": "<name>",
        "deployment": "<model>",          // e.g. gpt-4.1
        "auth": "managed-identity"        // "managed-identity" | "api-key" (key NEVER stored here)
      },
      "foundryProject": "<endpoint-or-name>", // FH (new/existing) / FD (existing) only
      "frontier": {                        // DW only
        "enrollmentConfirmed": false,
        "policyTemplate": "<name-or-todo>"
      },
      "tools": ["mcp_MailTools"]           // registered MCP server uniqueNames to attach (ACA/FH).
                                             // Defaults to ["mcp_MailTools"] (Work IQ Mail, today's behavior);
                                             // add other Work IQ (mcp_*) / custom (ext_*) servers, or [] to drop Mail.
                                             // FD agents leave this [] (they wire tools in agent_config.py).
    },
    {
      "type": "MCS-NH",                    // Copilot Studio variant: MCS-OH (legacy harness) | MCS-NH (GHCP harness)
      "name": "<prefix>-MCS-<OH|NH>",      // 3-part name, NO framework segment — e.g. contoso-MCS-NH. In custom naming mode the DISPLAY name may be free-form; the solution unique name stays prefix-derived. With >1 instance of the harness the name is suffixed '-<n>' (contoso-MCS-NH-1) and the solution unique name becomes <prefix>MCS<NH><n>.
      "mcp": ["mail"],                     // OPTIONAL A365 tool-gateway MCP: subset of "mail" (tested) / "anon" / "auth" (experimental); [] for none
      "publish": true                      // OPTIONAL — after import, guide the org-wide publication (Availability options -> Show to everyone in my org)
    }
  ],
  "ui": {
    "mode": "none",                        // "none" | "create" | "attach" (attach = SHARED UI: surgical per-agent Add-WebUiTab.ps1 merge, config.js NOT regenerated)
    "name": "<prefix>-ui",                 // create mode
    "hosting": "static-web-app",           // "local" | "static-web-app"
    "swaRegion": "<azure-region>",         // create + static-web-app
    "existing": {                          // attach mode — the wizard fills this by picking a SWA tagged a365component=web-ui (never a raw typed name)
      "spaAppId": "<guid>",
      "origin": "https://<host>",
      "staticWebApp": "<name>"             // REQUIRED in attach mode; Add-WebUiTab.ps1 -SwaName targets it, tags it a365ref_<prefix>
    },
    "expose": [                            // OBO/S2S agents only (never DW). Prefer "agentName" (one specific INSTANCE, unambiguous); "agentType" is back-compat = every instance of that type.
      { "agentName": "<prefix>-MAF-ACA-OBO" }
    ],
    "permissions": {
      "mailConsent": false,                // true if any OBO agent is exposed
      "s2sAudience": false,                // true if ACA-S2S is exposed (sets UI_AUDIENCE)
      "foundryAccess": []                  // extra UI testers granted Cognitive Services User on the shared Foundry account (BEYOND the signed-in deploy user, who is always granted); FH/FD only (not ACA). Each entry is a UPN or a GROUP object id; a comma-separated list of UPNs in one entry is also accepted. A group is recommended for many testers.
    }
  },
  "customMcp": {                            // optional sample custom MCP server (custom-mcp/)
    "enabled": false,
    "mode": "create",                       // "create" (DEFAULT/omit — deploy+register a NEW ext_<prefix>Anon/Auth pair) | "attach" (reuse an EXISTING pair: no deploy/register, just attach it to the OBO agents)
    "publisher": "<Publisher>",             // registration metadata, e.g. Contoso (create mode only; ignored in attach)
    "servers": ["anon", "auth"],           // which servers to register (create) / attach (attach) — subset of anon/auth
    "resourceGroup": "<prefix>-mcp-rg",     // create mode: defaults to <prefix>-mcp-rg
    "region": "<azure-region>",
    "existing": {                           // attach mode — the wizard fills this by PICKING a discovered pair (a custom MCP instance tagged a365component=custom-mcp = Custom MCP Creator standalone, or another existing ext_ pair in Azure)
      "name": "<BaseName>",                 // REQUIRED in attach mode; the servers are ext_<BaseName>Anon / ext_<BaseName>Auth (<= 12 alphanumeric)
      "servers": ["anon", "auth"],          // which servers the existing pair actually has
      "resourceGroup": "<name>-mcp-rg",     // optional (informational — the existing MCP's RG, if in Azure)
      "source": "custom-mcp-creator"        // "custom-mcp-creator" (standalone, tagged) | "azure" (another existing custom MCP)
    },
    "attachTo": [],                         // OBO agents only (ACA-OBO/FH-OBO/FD-OBO). Each entry is an agent NAME (one instance) or an agent TYPE (all its instances). S2S/DW blocked (see Rules)
    "integrationMode": "approve-first",     // "approve-first" (default) | "attach-when-approved" (see Rules)
    "propagateToGraph": true,               // create: enable the advanced On-Behalf-Of Graph test (DEFAULT: true). attach: reflects the EXISTING pair's capability (not configured here)
    "audiences": { "anon": "<app-id>", "auth": "<app-id>" }  // optional — the ext_ BYO resource app ids; lets the SPA wire customScopes immediately (else resolved from ToolingManifest.json after attach)
  }
}
```

> The custom MCP server name is **not** a plan field: it derives from `solution.prefix` (the same
> unique key as the web UI), so the registrations are `ext_<prefix>Anon` / `ext_<prefix>Auth` and the
> Azure resources are `<prefix>-mcp-*`. The prefix must therefore be ≤ 12 alphanumerics when the
> custom MCP is enabled (so `ext_<prefix>Anon/Auth` stays ≤ 20).

## Rules
- `agents[].tools` lists the **registered MCP server uniqueNames** to attach to that agent via
  `a365 develop add-mcp-servers` (Work IQ `mcp_*`, custom `ext_*`, or any approved third-party). It
  defaults to `["mcp_MailTools"]` (Work IQ Mail — the samples' current behavior); set `[]` to make Mail
  optional, or add more servers. **FD agents keep it `[]`** (prompt agents wire tools in
  `agent_config.py`, not via the manifest). Reusing a non-Mail Work IQ tool follows the same auth/token
  lessons — see [workiq-mcp-integration.md](./workiq-mcp-integration.md).
- `solution.foundry` (optional) makes **all FH + FD agents share ONE Foundry account + project + model
  deployment** instead of one account per agent. `create-shared` = the wizard provisions the single
  account + project (`<prefix>`) + model (`gpt-4.1`) in `<prefix>-foundry-rg` (the first FH-OBO/FH-S2S
  agent runs `azd provision`; the rest and all FD agents `azd deploy` into it — the shared account name is
  azd-generated, so the scaffolder emits placeholder tokens the agent substitutes with the captured
  endpoint/project-id). `reuse-existing` = every FH/FD agent deploys into an existing account+project you
  supply (`endpoint`/`account`/`existingResourceGroup`), with **no** `azd provision` — the resilient path
  when new-account hosted-agent provisioning is degraded service-side. **FH-DW always keeps its own
  account** (it bundles a Bot Service + managed-agent-identity blueprint bicep). When the block is
  **absent**, the legacy per-agent behaviour is unchanged. FD-only labs must use `reuse-existing` (a prompt
  agent has no azd project to provision a shared account from).
- `solution.azureOpenAI` (optional) makes **all ACA agents share ONE Azure OpenAI account + model
  deployment** instead of per-agent `ai` fields (the ACA mirror of `solution.foundry`). `create-shared` =
  **the DEFAULT** — the wizard creates a **lab-owned** account (`<prefix>aoai`) + deployment in
  `<prefix>-aoai-rg` before the ACA deploys (the first ACA-* agent emits the create command, the rest reuse
  it); the Lab Cleaner deletes+purges it via the prefix, exactly like `<prefix>-foundry-rg`. `reuse-existing`
  = every ACA agent deploys against an existing account the user supplies (`account` +
  `existingResourceGroup`), with **no** creation, and cleanup never touches it. Each deploy grants the app's
  managed identity **Cognitive Services OpenAI User** on the resolved account. When the block is **absent**,
  the legacy per-agent `ai.account`/`ai.deployment` behaviour is unchanged.
- `solution.observability.appInsights` (optional) wires the sample agents' **OpenTelemetry** to an
  **Application Insights** resource (the agents already read `APPLICATIONINSIGHTS_CONNECTION_STRING` at
  startup). `mode` = `none` (**default**, or omit the block — no wiring, backward compatible) | `create-shared`
  (the wizard creates a **lab-owned** resource `<prefix>-appinsights` in `<prefix>-appinsights-rg`, tagged
  `a365lab` and deleted by the Lab Cleaner via the prefix like `<prefix>-foundry-rg`) | `reuse-existing`
  (wire to an existing **user-owned** resource `existingName`/`existingResourceGroup`; cleanup never touches
  it). The wiring is host-specific (grounded in Microsoft Learn): **ACA** agents get the connection string
  injected into the container as a normal env var (resolved at deploy time via `az monitor app-insights
  component show`; **never** stored in the secret-free plan). **FH** agents get the *platform-reserved*
  `APPLICATIONINSIGHTS_CONNECTION_STRING` **only when the resource is CONNECTED to the Foundry project**
  (project monitoring) — that project connection has **no supported az one-liner** (portal-only), so the
  scaffolder emits a **manual gate** (Foundry portal → project → Agents → Traces → **Connect**). For
  `reuse-existing` **Foundry** the project is user-owned, so the gate warns that connecting App Insights
  modifies it. **MCS** (Copilot Studio) agents have telemetry on **two** independent sinks: **Agent 365
  observability is ALREADY ON automatically** (no action; M365 admin center / Defender / Purview; needs an
  E7 or Agent 365 license) and, **optionally**, **Application Insights** in one of two scopes — **GLOBAL**
  (environment-level, *preview*; covers **both** OH **and** NH; **requires a Managed Environment**;
  configured once in PPAC as an export package of type Copilot Studio) or **LOCAL** (per-agent → Settings →
  Advanced → Application Insights; **MCS-OH only**). The scaffolder emits a durable MCS telemetry decision
  block that invites the user to first check whether the env is Managed / already globally instrumented,
  then pick global / local / none (cross-tenant-safe). **FD** agents
  have no observability wiring. `mode: none` (or omitting the block) preserves all existing labs.
- **Web access has NO plan field — it is always on** for the 8 code variants (not MCS): ACA/FH carry
  `fetch_url` in-process; when the plan has FD agents the scaffolder also emits the per-lab web-fetch MCP
  (`<prefix>-webfetch-rg`, derived from `solution.prefix` + `solution.region`) and the FD `.env` key
  `WEB_FETCH_MCP_URL` (filled by `deploy-web-fetch.ps1`). Existing plans need no change.
- `customMcp.enabled` is optional and defaults to `false`. When `true`, the server names derive from
  `solution.prefix` (NOT a separate field): the registrations are `ext_<prefix>Anon` / `ext_<prefix>Auth`
  and must stay ≤ 20 chars, so the prefix must be ≤ 12 alphanumerics (lowercased, non-alphanumerics
  stripped). `attachTo` may list **only OBO agents** (`ACA-OBO` / `FH-OBO` / `FD-OBO`).
  A BYO server reached through the gateway needs a one-time Power Platform connection **owned by the
  invoking identity**, and only an OBO agent invokes as the signed-in user who owns it. **S2S** (own app
  identity) and **DW** (projected `agentUser` identity) invoke as a non-user identity that can't own — nor
  be granted (preview: `ConnectionSharingNotAllowed`) — that connection (S2S also can't mint the custom
  audience token from the SPA: `AADSTS82001`/`82002`). Known preview limitation, not an unfinished feature.
- `customMcp.integrationMode` (optional, default `approve-first`) sets HOW the OBO agents pick up
  the custom MCP, since a BYO server must be **admin-approved** (M365 admin center) before it can be
  attached: `approve-first` = approve the `ext_*` servers BEFORE creating the agents, so each OBO agent
  integrates them immediately as it is provisioned (with permissions); `attach-when-approved` = start the
  agents right away and integrate each OBO agent only if the servers are approved by the time it deploys,
  otherwise run the per-agent attach later. The wizard asks this right after the custom MCP is registered.
- `customMcp.mode` (optional, default `create`) chooses between **deploying a new pair** and **reusing an
  existing one** — the symmetric counterpart of `ui.mode` `create`/`attach`. `create` (or omitting `mode`)
  is byte-identical to before: the wizard copies `custom-mcp/`, deploys the containers and registers
  `ext_<prefix>Anon` / `ext_<prefix>Auth`. `attach` reuses an **existing** pair (`customMcp.existing.name` →
  `ext_<name>Anon`/`ext_<name>Auth`): **nothing is deployed, registered or consent-pre-empted** — the
  scaffolder only accumulates the existing `ext_` servers for the per-OBO attach (`a365 develop
  add-mcp-servers`) and reminds the operator that the pair must already be admin-approved in this tenant and
  that each user still creates the one-time Power Platform connections. The candidate pairs come **primarily
  from the Custom MCP Creator** (standalone instances tagged `a365component=custom-mcp`, discoverable by
  `discover-environment.ps1` / `Find-StandaloneComponents.ps1 -Kind custom-mcp`) and **secondarily** from any
  other existing `ext_*Anon`/`ext_*Auth` pair (`a365 develop list-available`). In attach mode the prefix
  need **not** encode the MCP name (the ext_ names come from `existing.name`), and `publisher` is ignored.
  `attach` normally requires a non-empty `attachTo`, **except in an MCS-only lab**: when the plan has no
  OBO agents but has **MCS agents whose `mcp` requests `anon`/`auth`**, `attachTo` may be `[]` — the reused
  pair is there only to source the ext_ prefix for the Copilot Studio MCP wizard (`New-McsMcpClientApp
  -McpPrefix <existing.name>`) and to emit the per-user Power Platform connection URLs; MCS agents wire the
  tool in Copilot Studio, not via `add-mcp-servers`.
- **The scaffold folder is `generated/<prefix>/`** — every folder for a run (each `<agent-name>`, the
  `<prefix>-ui` web UI and the `<prefix>-mcp` custom MCP) lives under that single per-run root. To run the
  wizard N times and create N coexisting copies, give each run a **different prefix** (the wizard checks
  the tenant for an existing `ext_<prefix>*` and asks for another prefix if it collides).
- **Every agent name carries the fixed `<framework>` segment**: `name` = `<prefix>-<framework>-<hosting>-<identity>`
  (e.g. `contoso-MAF-ACA-OBO`). `framework` defaults to `MAF` (the only framework today); the scaffolder
  validates `name` == `<prefix>-<framework>-<type>`. The segment keeps a same-type agent built with another
  framework distinguishable. The prefix cap stays **12** (custom-MCP driven, independent of the agent name);
  a **DW** lab lowers it (e.g. 9 for `MAF-ACA-DW`) so `name.short` stays ≤ 30 — see naming-and-validation.md.
- **Instances (N per type).** A lab may hold **N instances** of the same agent type — each is just another
  `agents[]` entry. The naming rule: a type with a **single** instance carries **no** suffix (byte-identical
  to before); a type with **more than one** instance suffixes **every** instance with a 1-based `-<n>`
  (`contoso-MAF-ACA-OBO-1`, `-2`, …). Every instance name must be **unique**. The suffix flows into the
  derived resources (RG, container app, blueprint/identity) and the SPA tab id, so instances never collide.
  In **custom** naming mode the user gives each instance a distinct free-form name instead. To disambiguate
  a specific instance in `ui.expose` / `customMcp.attachTo`, reference it by **`agentName`** (a bare type
  there means "every instance of that type"). ("Instance" is the same word the Digital-Worker blueprint uses
  for its projected agent users — here it means a whole distinct agent copy in the lab.)
- **`solution.namingMode` = `custom`** relaxes the previous rule for **code agents (ACA/FH/FD)**: each may
  carry a free-form `name` (with matching `displayNames`/`resourceGroup`), validated only structurally
  (start with a letter; letters/digits/hyphens only; the ACA-lowercase and DW ≤ 30 rules still apply). The
  wizard then runs `Set-LabTags.ps1` to stamp `a365lab=<prefix>` (Azure RGs) / `a365lab:<prefix>` (Entra apps
  + SPs) on every **lab-owned** resource, so the Lab Cleaner discovers the lab by **tag** even when a custom
  name does not contain the prefix. `default` (or omitting `namingMode`) is byte-identical to before. **In
  `custom` mode MCS agents may carry a free-form DISPLAY name**, but the scaffolder keeps their **solution
  unique name prefix-derived** (`<prefix>MCS<OH|NH>[<n>]`) and the bot schema isolated, so the Lab Cleaner's
  prefix fallback (solutions matching `<prefix>MCS*`) still finds + deletes them from the lab name alone; in
  `default` mode display == solution (`<prefix>-MCS-<OH|NH>`).
- DW entries: `displayNames.blueprint` = the agent name **without** a `" Blueprint"` suffix and length ≤ 30
  (see naming-and-validation.md); OBO/S2S keep `"<name> Blueprint"`.
- **MCS (Copilot Studio) entries** use a 3-part name `<prefix>-MCS-<OH|NH>` with **no** `framework`,
  `displayNames`, `resourceGroup`, `ai`, or `tools` fields (in `custom` naming mode the `name` may be a
  free-form display name; the solution unique name is still pinned to `<prefix>MCS<OH|NH>[<n>]`). They add an optional `mcp` (subset of
  `mail`/`anon`/`auth`) and optional `publish` (bool). `solution.copilotStudio.targetTenantId` is required
  for any MCS agent; `solution.copilotStudio.targetEnvironmentId` is additionally required for **MCS-NH**
  (must be a PAYG + Dataverse + Copilot Studio env, else `EnforcementUsageCredits`). MCS agents are NOT
  exposed in the web UI (`ui.expose`) — they live in Copilot Studio / Teams. See the
  **agent365-copilot-studio** sub-skill.
- Anything discoverable post-deploy (FQDN, blueprint/app IDs, endpoints) is **omitted** from the plan
  and resolved at scaffold/deploy time.
- No secrets, ever. `auth: "api-key"` records only the *method*; the key is entered in the terminal.
