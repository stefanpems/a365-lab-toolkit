# Agent 365 agent lab (`a365-agent-lab`) — custom agents integrated with Microsoft Agent 365

A lab of custom agents integrated with **Microsoft Agent 365**, spanning three authentication models
(OBO, S2S, Digital Worker) across three hosting/dev models — **Azure Container Apps (ACA)**,
**Foundry Hosted (FH)**, and **Foundry Declarative / prompt agents (FD)** — plus a shared web UI.
The sample agents are currently built with the **Microsoft Agent Framework (MAF)** — a pragmatic
starting point, **not** the objective. The lab is **framework-agnostic by design** (see the vision below).

> Full concepts and step-by-step setup guides are in **[docs/](docs/README.md)**.

## What this lab is

This is a hands-on **lab** that provisions a set of **custom agents**, a shared web UI, and optional
**test MCP servers**, all integrated into **Microsoft Agent 365**. A provisioning wizard agent (the
**A365 Lab Provisioner**, see [.github/agents/](.github/agents)) scaffolds and deploys the whole thing.
It has two goals:

- **For IT admins** — exercise Agent 365 end to end with agents across different **hosting models**
  (ACA, Foundry Hosted, Foundry Declarative), **authentication models** (OBO, S2S, Digital Worker), and
  **tool integrations** (Work IQ MCP servers + custom test MCP servers).
- **For developers** — start from **modifiable agents already integrated with Agent 365** and grow them
  into more extensive prototypes.

> **Framework-agnostic by design (vision).** The Agent 365 integration — the agent identity/blueprint,
> the tooling/MCP gateway, and the messaging endpoint — does **not** depend on MAF. MAF was chosen
> opportunistically to get started; the intent is to extend the lab to provision agents built with
> **other frameworks** (e.g. **LangChain**, **Semantic Kernel**). The agent-type naming already carries
> a `<framework>` segment (today `MAF-…`), so new frameworks slot in as `LC-…`, `SK-…`, etc. under the
> same hosting/identity structure, reusing the same auth/token patterns
> ([workiq-mcp-integration.md](.github/skills/agent365-wizard/references/workiq-mcp-integration.md)).
> ACA and FH are the natural hosts for code frameworks; FD (declarative prompt agents) is
> platform-run and framework-independent by nature.

## Repository layout

```
a365-agent-lab/
├─ docs/                     # Documentation: intro + one setup guide per agent type + web UI
├─ ui/                       # MSAL web SPA (Azure Static Web Apps) for the OBO/S2S agents
├─ custom-mcp/               # Optional sample custom MCP server (anonymous + authenticated) for tool tests
├─ aca/                      # Azure Container Apps (A365-SDK-hosted) agents
│  ├─ obo/                   # MAF-ACA-OBO  — acts on behalf of the signed-in user
│  ├─ s2s/                   # MAF-ACA-S2S  — acts as its own application identity
│  └─ dw/                    # MAF-ACA-DW   — AI teammate (Digital Worker)
└─ foundry-hosted/           # Foundry Hosted agents
│  ├─ obo/                   # MAF-FH-OBO   — Invocations protocol
│  ├─ s2s/                   # MAF-FH-S2S   — Responses protocol
│  └─ dw/                    # MAF-FH-DW    — container hosted agent + Azure Bot Service
└─ foundry-declarative/      # Foundry Declarative (prompt) agents — platform-run, no container
   ├─ obo/                   # MAF-FD-OBO   — Mail MCP + per-request token (structured input)
   └─ s2s/                   # MAF-FD-S2S   — own identity, conversational
```

| Type | Folder | Setup guide |
| --- | --- | --- |
| MAF-ACA-OBO | [aca/obo](aca/obo) | [docs/setup-MAF-ACA-OBO.md](docs/setup-MAF-ACA-OBO.md) |
| MAF-ACA-S2S | [aca/s2s](aca/s2s) | [docs/setup-MAF-ACA-S2S.md](docs/setup-MAF-ACA-S2S.md) |
| MAF-ACA-DW  | [aca/dw](aca/dw)   | [docs/setup-MAF-ACA-DW.md](docs/setup-MAF-ACA-DW.md) |
| MAF-FH-OBO  | [foundry-hosted/obo](foundry-hosted/obo) | [docs/setup-MAF-FH-OBO.md](docs/setup-MAF-FH-OBO.md) |
| MAF-FH-S2S  | [foundry-hosted/s2s](foundry-hosted/s2s) | [docs/setup-MAF-FH-S2S.md](docs/setup-MAF-FH-S2S.md) |
| MAF-FH-DW   | [foundry-hosted/dw](foundry-hosted/dw)   | [docs/setup-MAF-FH-DW.md](docs/setup-MAF-FH-DW.md) |
| MAF-FD-OBO  | [foundry-declarative/obo](foundry-declarative/obo) | [docs/setup-MAF-FD-OBO.md](docs/setup-MAF-FD-OBO.md) |
| MAF-FD-S2S  | [foundry-declarative/s2s](foundry-declarative/s2s) | [docs/setup-MAF-FD-S2S.md](docs/setup-MAF-FD-S2S.md) |
| Web SPA UI  | [ui](ui) | [docs/setup-web-ui.md](docs/setup-web-ui.md) |

### Optional: custom MCP tool sample
[custom-mcp/](custom-mcp/README.md) is an optional **bring-your-own MCP server** sample you can attach
to the ACA and FH agents to test Agent 365 tool behavior. One container hosts two MCP servers, split
by authentication type (the auth type is chosen per registration): `/anon/mcp` (register as `NoAuth`)
for anonymous calls, direct responses and outbound connectivity, and `/auth/mcp` (register as
`EntraOAuth`) for caller-identity inspection (OBO / S2S / Digital Worker) and On-Behalf-Of credential
propagation to Microsoft Graph. The provisioning wizard can deploy, register and attach it; see
[custom-mcp/README.md](custom-mcp/README.md).

> **⛔ MAF-FD-DW is not available (platform limitation).** A Foundry **prompt/declarative agent
> cannot be published as an Agent 365 autopilot Digital Worker** — a hired instance is permanently
> silent in Teams by design. Per Microsoft Learn, **only Foundry _hosted_ agents can be published as
> autopilot blueprints**
> ([Supported agent types](https://learn.microsoft.com/azure/foundry/agents/concepts/agent-365-integration#supported-agent-types)).
> For a Teams Digital Worker use **[MAF-FH-DW](docs/setup-MAF-FH-DW.md)**; a declarative agent remains
> fully usable through the Responses API (**MAF-FD-OBO**, **MAF-FD-S2S**).

## Security & configuration

**No secrets are committed to this repository.** Local secrets and machine-generated
configuration are excluded via [.gitignore](.gitignore). Before running any agent you must
create the local configuration from the provided templates:

| Excluded (secret / generated) | Provide it from |
| --- | --- |
| `**/.env`, `**/env/.env.playground*`, `**/*.user` | copy the sibling `*.env.template` / `*.env.example` and fill in your values |
| `**/a365.generated.config*.json` (ACA) | regenerated by `a365 setup …`; see `a365.generated.config.template.json` for the shape |
| `**/.azure/` (Foundry) | regenerated by `azd provision` / `azd env set …` |
| `**/*.log`, `**/devTools/`, `**/manifest/manifest.zip` | build/tool artifacts — not needed |

The `.env.template` files document every required variable with example values and comments.
Never commit a real `.env`, client secret, API key, or bearer token.

## Getting started

1. Read [docs/00-introduction.md](docs/00-introduction.md).
2. Pick a type and follow its setup guide under [docs/](docs/README.md).
3. For the UI, follow [docs/setup-web-ui.md](docs/setup-web-ui.md).
