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
      "tools": []                          // RESERVED — future custom MCP tool registration
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
  }
}
```

## Rules
- `agents[].tools` stays `[]` until the future MCP step; keep the field so plans are forward-compatible.
- DW entries require `displayNames.blueprint` length ≤ 30 (see naming-and-validation.md).
- Anything discoverable post-deploy (FQDN, blueprint/app IDs, endpoints) is **omitted** from the plan
  and resolved at scaffold/deploy time.
- No secrets, ever. `auth: "api-key"` records only the *method*; the key is entered in the terminal.
