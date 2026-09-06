# Variant matrix — inputs, tooling, hosting

Exactly **8** supported variants. FD-DW is not supported.

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

## Inputs the wizard MUST ask (grouped)

### Common (all variants)
- **Solution prefix** → derives all agent names as `<prefix>-<hosting>-<identity>`.
- **Tenant / Subscription** → auto-detected; user confirms or overrides.
- **Preferred region** → validated per service.
- **Resource-group strategy** → per-agent (`<agent>-rg`, default) or shared (`<prefix>-rg`).

### Any ACA
- Azure OpenAI account + model deployment (list, or create new).
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
- ACA-DW `a365 setup` shows an `ext_UtilityInsights — Provision via 'az ad sp create'? [y/N]` prompt:
  answer **N** (optional custom MCP, usually absent; the `az ad sp create` failure is harmless).

### UI (if selected)
- New UI: name (default `<prefix>-ui`), local-only or Azure Static Web App (+ SWA region).
- Existing UI: SPA app registration + origin + existing SWA.
- Agents to expose: multi-select of the OBO/S2S agents.
- If exposing OBO → Mail consent `McpServers.Mail.All`.
- If exposing ACA-S2S → blueprint scope `api://<s2s-app-id>/access_agent_as_user` + `UI_AUDIENCE`.
- If exposing FH/FD → users/groups to grant Foundry access.

### Custom MCP (optional — sample `custom-mcp/`)
Single-select: *None* / *Anonymous only* / *Authenticated only* / *Both*. If anything but None:
- **`<Name>`** for the servers, **max 12 characters** (registered as `ext_<Name>Anon` /
  `ext_<Name>Auth`; `ext_` + name + `Anon`/`Auth` must stay ≤ 20). Validate length + `^[A-Za-z][A-Za-z0-9]*$`.
  `<Name>` is the **unique per-copy key** — Azure resources (`<name>-mcp-*`), the scaffold folder
  (`generated/custom-mcp-<name>/`) and the registrations all derive from it. For N coexisting copies use
  a different `<Name>` each run and check the tenant (`a365 develop list-available`) for collisions.
- **Publisher** name (registration metadata, e.g. `Contoso`).
- **Attach to**: multi-select of the deployed **ACA-*/FH-*** agents (FD excluded — prompt agents use a
  different tool-attachment mechanism).
- **`propagate_to_graph`** (auth server only): enable the advanced On-Behalf-Of Graph test? If yes,
  surface the Entra prerequisites (confidential client + Graph `User.Read` + admin consent) as a checkpoint.
- One ACA container hosts both servers on two paths; registration is per-server (auth type is
  per-registration): NoAuth for `/anon/mcp`, EntraOAuth for `/auth/mcp`. Admin approval of each
  registered server happens in the M365 admin center (not CLI).

## Do NOT ask (discover / derive / fixed)
- Blueprint / identity / container / bot / app-reg names → derived from the prefix.
- Log Analytics workspace names, endpoints, app IDs, blueprint IDs → discovered post-deploy.
- Fixed first-party scopes: Mail `ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/McpServers.Mail.All`,
  Foundry `https://ai.azure.com/.default`.
- Localhost redirect URI `http://localhost:3000`, API versions, agent descriptions.

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
