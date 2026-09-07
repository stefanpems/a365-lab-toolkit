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
      "foundryAccess": []                  // if any FH/FD agent is exposed
    }
  },
  "customMcp": {                            // optional sample custom MCP server (custom-mcp/)
    "enabled": false,
    "name": "<Name>",                       // <= 12 chars, starts with a letter, alphanumeric; UNIQUE per copy
    "publisher": "<Publisher>",             // registration metadata, e.g. Contoso
    "servers": ["anon", "auth"],           // which servers to register (subset of anon/auth)
    "resourceGroup": "<name>-mcp-rg",       // defaults to <name>-mcp-rg (derives from Name, not prefix)
    "region": "<azure-region>",
    "attachTo": [],                         // agent types to attach to (ACA-*/FH-* only; FD excluded)
    "propagateToGraph": false               // enable the advanced On-Behalf-Of Graph test
  }
}
```

## Rules
- `agents[].tools` lists the **registered MCP server uniqueNames** to attach to that agent via
  `a365 develop add-mcp-servers` (Work IQ `mcp_*`, custom `ext_*`, or any approved third-party). It
  defaults to `["mcp_MailTools"]` (Work IQ Mail — the samples' current behavior); set `[]` to make Mail
  optional, or add more servers. **FD agents keep it `[]`** (prompt agents wire tools in
  `agent_config.py`, not via the manifest). Reusing a non-Mail Work IQ tool follows the same auth/token
  lessons — see [workiq-mcp-integration.md](./workiq-mcp-integration.md).
- `customMcp.enabled` is optional and defaults to `false`. When `true`, `name` must be ≤ 12 chars,
  start with a letter and be alphanumeric — the registered names are `ext_<Name>Anon` / `ext_<Name>Auth`
  and must stay ≤ 20 chars. `attachTo` may list only ACA-* and FH-* agent types (FD is unsupported).
- **`customMcp.name` is the unique per-copy key.** The Azure resources `<name>-mcp-rg` / `<name>-mcp-ca` /
  `<name>-mcp-cae` and the `ext_<Name>Anon` / `ext_<Name>Auth` registrations derive from it (lowercased).
  The scaffold folder is `generated/<prefix>-mcp/` (from `solution.prefix`, like the UI folder). To run the
  wizard N times and create N coexisting copies, give each a **different `name`** (the wizard checks the
  tenant for an existing `ext_<Name>*` and asks for another if it collides).
- DW entries require `displayNames.blueprint` length ≤ 30 (see naming-and-validation.md).
- Anything discoverable post-deploy (FQDN, blueprint/app IDs, endpoints) is **omitted** from the plan
  and resolved at scaffold/deploy time.
- No secrets, ever. `auth: "api-key"` records only the *method*; the key is entered in the terminal.
