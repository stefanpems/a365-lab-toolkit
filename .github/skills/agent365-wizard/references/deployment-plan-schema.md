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
    "prefix": "<string>",                 // e.g. contoso-sales
    "tenantId": "<guid>",                 // discovered, confirmed
    "subscriptionId": "<guid>",           // discovered, confirmed
    "region": "<azure-region>",           // e.g. polandcentral
    "resourceGroupStrategy": "isolated",  // "isolated" | "shared"
    "sharedResourceGroup": "<name>"       // only when strategy = "shared"
  },
  "agents": [
    {
      "type": "ACA-OBO",                  // one of the 8 supported variants
      "name": "<prefix>-<hosting>-<identity>",
      "displayNames": {
        "blueprint": "<name> Blueprint",  // DW: MUST be <= 30 chars
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
      "foundryAccess": []                  // users/groups granted Cognitive Services User on the Foundry account; FH/FD only (not ACA); a group is recommended
    }
  },
  "customMcp": {                            // optional sample custom MCP server (custom-mcp/)
    "enabled": false,
    "publisher": "<Publisher>",             // registration metadata, e.g. Contoso
    "servers": ["anon", "auth"],           // which servers to register (subset of anon/auth)
    "resourceGroup": "<prefix>-mcp-rg",     // defaults to <prefix>-mcp-rg
    "region": "<azure-region>",
    "attachTo": [],                         // OBO agents only (ACA-OBO/FH-OBO/FD-OBO); S2S/DW blocked (see Rules)
    "integrationMode": "attach-when-approved", // "approve-first" | "attach-when-approved" (see Rules)
    "propagateToGraph": false               // enable the advanced On-Behalf-Of Graph test
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
- `customMcp.enabled` is optional and defaults to `false`. When `true`, the server names derive from
  `solution.prefix` (NOT a separate field): the registrations are `ext_<prefix>Anon` / `ext_<prefix>Auth`
  and must stay ≤ 20 chars, so the prefix must be ≤ 12 alphanumerics (lowercased, non-alphanumerics
  stripped). `attachTo` may list **only OBO agents** (`ACA-OBO` / `FH-OBO` / `FD-OBO`).
  A BYO server reached through the gateway needs a one-time Power Platform connection **owned by the
  invoking identity**, and only an OBO agent invokes as the signed-in user who owns it. **S2S** (own app
  identity) and **DW** (projected `agentUser` identity) invoke as a non-user identity that can't own — nor
  be granted (preview: `ConnectionSharingNotAllowed`) — that connection (S2S also can't mint the custom
  audience token from the SPA: `AADSTS82001`/`82002`). Known preview limitation, not an unfinished feature.
- `customMcp.integrationMode` (optional, default `attach-when-approved`) sets HOW the OBO agents pick up
  the custom MCP, since a BYO server must be **admin-approved** (M365 admin center) before it can be
  attached: `approve-first` = approve the `ext_*` servers BEFORE creating the agents, so each OBO agent
  integrates them immediately as it is provisioned (with permissions); `attach-when-approved` = start the
  agents right away and integrate each OBO agent only if the servers are approved by the time it deploys,
  otherwise run the per-agent attach later. The wizard asks this right after the custom MCP is registered.
- **The scaffold folder is `generated/<prefix>/`** — every folder for a run (each `<agent-name>`, the
  `<prefix>-ui` web UI and the `<prefix>-mcp` custom MCP) lives under that single per-run root. To run the
  wizard N times and create N coexisting copies, give each run a **different prefix** (the wizard checks
  the tenant for an existing `ext_<prefix>*` and asks for another prefix if it collides).
- DW entries require `displayNames.blueprint` length ≤ 30 (see naming-and-validation.md).
- Anything discoverable post-deploy (FQDN, blueprint/app IDs, endpoints) is **omitted** from the plan
  and resolved at scaffold/deploy time.
- No secrets, ever. `auth: "api-key"` records only the *method*; the key is entered in the terminal.
