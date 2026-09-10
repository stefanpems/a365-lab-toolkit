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
    }
  },
  "agents": [
    {
      "type": "ACA-OBO",                  // one of the 8 supported variants (hosting-identity; the scaffolder $MAP key)
      "framework": "MAF",                 // FIXED name segment identifying the agent framework (default "MAF"); today only MAF exists
      "name": "<prefix>-<framework>-<hosting>-<identity>",  // e.g. contoso-MAF-ACA-OBO — the <framework> segment is mandatory
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
    }
  ],
  "ui": {
    "mode": "none",                        // "none" | "create" | "attach"
    "name": "<prefix>-ui",                 // create mode
    "hosting": "static-web-app",           // "local" | "static-web-app"
    "swaRegion": "<azure-region>",         // create + static-web-app
    "existing": {                          // attach mode
      "spaAppId": "<guid>",
      "origin": "https://<host>",
      "staticWebApp": "<name>"
    },
    "expose": [                            // OBO/S2S agents only (never DW)
      { "agentType": "ACA-OBO" }
    ],
    "permissions": {
      "mailConsent": false,                // true if any OBO agent is exposed
      "s2sAudience": false,                // true if ACA-S2S is exposed (sets UI_AUDIENCE)
      "foundryAccess": []                  // extra UI testers granted Cognitive Services User on the shared Foundry account (BEYOND the signed-in deploy user, who is always granted); FH/FD only (not ACA). Each entry is a UPN or a GROUP object id; a comma-separated list of UPNs in one entry is also accepted. A group is recommended for many testers.
    }
  },
  "customMcp": {                            // optional sample custom MCP server (custom-mcp/)
    "enabled": false,
    "publisher": "<Publisher>",             // registration metadata, e.g. Contoso
    "servers": ["anon", "auth"],           // which servers to register (subset of anon/auth)
    "resourceGroup": "<prefix>-mcp-rg",     // defaults to <prefix>-mcp-rg
    "region": "<azure-region>",
    "attachTo": [],                         // OBO agents only (ACA-OBO/FH-OBO/FD-OBO); S2S/DW blocked (see Rules)
    "integrationMode": "approve-first",     // "approve-first" (default) | "attach-when-approved" (see Rules)
    "propagateToGraph": true                // enable the advanced On-Behalf-Of Graph test (DEFAULT: true)
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
- **The scaffold folder is `generated/<prefix>/`** — every folder for a run (each `<agent-name>`, the
  `<prefix>-ui` web UI and the `<prefix>-mcp` custom MCP) lives under that single per-run root. To run the
  wizard N times and create N coexisting copies, give each run a **different prefix** (the wizard checks
  the tenant for an existing `ext_<prefix>*` and asks for another prefix if it collides).
- **Every agent name carries the fixed `<framework>` segment**: `name` = `<prefix>-<framework>-<hosting>-<identity>`
  (e.g. `contoso-MAF-ACA-OBO`). `framework` defaults to `MAF` (the only framework today); the scaffolder
  validates `name` == `<prefix>-<framework>-<type>`. The segment keeps a same-type agent built with another
  framework distinguishable. The prefix cap stays **12** (custom-MCP driven, independent of the agent name);
  a **DW** lab lowers it (e.g. 9 for `MAF-ACA-DW`) so `name.short` stays ≤ 30 — see naming-and-validation.md.
- DW entries: `displayNames.blueprint` = the agent name **without** a `" Blueprint"` suffix and length ≤ 30
  (see naming-and-validation.md); OBO/S2S keep `"<name> Blueprint"`.
- Anything discoverable post-deploy (FQDN, blueprint/app IDs, endpoints) is **omitted** from the plan
  and resolved at scaffold/deploy time.
- No secrets, ever. `auth: "api-key"` records only the *method*; the key is entered in the terminal.
