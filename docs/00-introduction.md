# Building Agent 365 test agents (OBO, S2S, DW) on Azure Container Apps and Foundry

> **Where to start:** begin with [README.md](README.md). For a new tenant or subscription,
> complete the [central prerequisites checklist](prerequisites-checklist.md) before using this
> conceptual reference or an agent-specific setup guide.
>
> Introduction and conceptual reference for a family of **nine** test agents integrated with
> **Microsoft Agent 365**. The samples are currently built with the **Microsoft Agent Framework
> (MAF)** — the **starting** framework, not the objective; the lab is framework-agnostic and the
> `<framework>` naming segment (§1) anticipates other frameworks (e.g. LangChain, Semantic Kernel).
>
> This document is written to be **reusable**: it describes the agent types generically so
> the same patterns can be reproduced in other tenants/environments with different names. A
> mapping table links the generic names to the concrete sample agents built in the first
> experiment.
>
> Everything here is grounded in the work actually carried out in the companion workspaces
> and cross-checked against the official Microsoft Learn documentation (links inline).

---

## 1. Naming convention

Each agent **type** is identified as `<framework>-<env>-<auth>` (e.g. `MAF-ACA-OBO`). A **deployed
agent instance** additionally carries the **lab prefix** (the solution / lab name), so its full name is
`<lab-prefix>-<framework>-<env>-<auth>`, e.g. `a90902-MAF-ACA-OBO`. The `<framework>` segment is a
**fixed, mandatory** part of the name (only `MAF` today) so that a same-type agent built with a
different framework stays distinguishable. The three type segments are:

| Segment | Values | Meaning |
| --- | --- | --- |
| `<framework>` | **MAF** (today; `LC` / `SK` / … planned) | Agent framework used to build the agent. **MAF** (Microsoft Agent Framework, Python) is the current sample; the segment is framework-neutral by design because the Agent 365 integration (identity, MCP gateway, messaging) doesn't depend on it, so other frameworks (e.g. LangChain `LC`, Semantic Kernel `SK`) can be added later. |
| `<env>` | **ACA** \| **FH** \| **FD** | Hosting/dev model: **A**zure **C**ontainer **A**pps (A365-SDK-hosted), **F**oundry **H**osted (container), or **F**oundry **D**eclarative (prompt agent, platform-run) |
| `<auth>` | **OBO** \| **S2S** \| **DW** | Identity/authentication model: **O**n-**B**ehalf-**O**f a user, **S**ervice-**to**-**S**ervice (application), or **D**igital **W**orker (AI teammate with its own user identity) |

So the types are: `MAF-ACA-OBO`, `MAF-ACA-S2S`, `MAF-ACA-DW`, `MAF-FH-OBO`, `MAF-FH-S2S`,
`MAF-FH-DW`, plus the Foundry Declarative variants `MAF-FD-OBO` and `MAF-FD-S2S` (the
`MAF-FD-DW` autopilot variant is **not supported** — see the note below the mapping table).

### 1.1 Mapping to the first experiment

| Generic name | Sample agent (this lab) | Entra blueprint / app id | Hosting | Protocol / endpoint | Setup guide |
| --- | --- | --- | --- | --- | --- |
| **MAF-ACA-OBO** | `AgentFrameworkSample` | `<ACA_OBO_BLUEPRINT_APP_ID>` | Azure Container Apps | Bot Framework `/api/messages` + custom `/chat` | [setup-MAF-ACA-OBO.md](setup-MAF-ACA-OBO.md) |
| **MAF-ACA-S2S** | `AgentFrameworkS2SSample` | `<ACA_S2S_BLUEPRINT_APP_ID>` | Azure Container Apps | Bot Framework `/api/messages` + custom `/chat` | [setup-MAF-ACA-S2S.md](setup-MAF-ACA-S2S.md) |
| **MAF-ACA-DW** | `AgentFrameworkDWSample` (AI teammate) | `<ACA_DW_BLUEPRINT_APP_ID>` | Azure Container Apps | Bot Framework `/api/messages` (Teams) | [setup-MAF-ACA-DW.md](setup-MAF-ACA-DW.md) |
| **MAF-FH-OBO** | `agentframeworkFH-OBO-agent` | Foundry agent identity | Foundry Hosted | **Invocations** (`/invocations`) | [setup-MAF-FH-OBO.md](setup-MAF-FH-OBO.md) |
| **MAF-FH-S2S** | `agentframeworkFH-S2S-agent` | Foundry agent identity | Foundry Hosted | **Responses** (`/responses`) | [setup-MAF-FH-S2S.md](setup-MAF-FH-S2S.md) |
| **MAF-FH-DW** | `agentframeworkFH-DW*-agent` | Foundry agent (container) + Azure Bot Service | Foundry Hosted (container) | Bot Framework `/api/messages` via Bot Service (Teams) | [setup-MAF-FH-DW.md](setup-MAF-FH-DW.md) |
| **MAF-FD-OBO** | `agentframeworkFD-OBO-agent` | Foundry prompt agent (managed blueprint) | Foundry Declarative | project **Responses** (`/openai/v1/responses`) + Mail MCP | [setup-MAF-FD-OBO.md](setup-MAF-FD-OBO.md) |
| **MAF-FD-S2S** | `agentframeworkFD-S2S-agent` | Foundry prompt agent | Foundry Declarative | project **Responses** (own identity) | [setup-MAF-FD-S2S.md](setup-MAF-FD-S2S.md) |

> **⛔ MAF-FD-DW is not available (platform limitation).** A Foundry prompt/declarative agent
> cannot be published as an Agent 365 autopilot Digital Worker; a hired instance is permanently
> silent in Teams by design. Per Microsoft Learn, **only Foundry _hosted_ agents can be published
> as autopilot blueprints**
> ([Supported agent types](https://learn.microsoft.com/azure/foundry/agents/concepts/agent-365-integration#supported-agent-types)).
> Use [MAF-FH-DW](setup-MAF-FH-DW.md) for a Teams Digital Worker; a declarative agent remains fully
> usable through the Responses API ([MAF-FD-OBO](setup-MAF-FD-OBO.md), [MAF-FD-S2S](setup-MAF-FD-S2S.md)).

> The tenant/subscription/region values in the setup guides are the ones used in the first
> experiment. Treat them as **examples** and substitute your own. Host the Foundry agents (FH
> and FD) in a **neutral-named project** (no `FH`/`FD`/auth in the name) — one project serves
> all Foundry agent types; only the agent name carries the type.

---

## 2. The two building blocks: authentication model × hosting/dev model

The nine agents are the cross-product of **three authentication models** and **three
hosting/dev models**. It helps to understand each axis independently.

### 2.1 Authentication models (Agent 365)

Microsoft Agent 365 (Microsoft Entra Agent ID) defines two authentication *flows* and a
special *own-identity* pattern
([Agent 365 identity](https://learn.microsoft.com/microsoft-agent-365/developer/identity#authentication-flows),
[Types of agents](https://learn.microsoft.com/microsoft-agent-365/developer/get-started#types-of-agents)):

| Model | What the agent acts as | Token | Data access | Agent 365 classification |
| --- | --- | --- | --- | --- |
| **OBO** (On-Behalf-Of) | The **signed-in user** | Delegated user token, exchanged (OBO) for the target resource | The **user's** mailbox, calendar, files — only what the user can access | *Agent* (delegated) |
| **S2S** (Service-to-Service) | **Itself** (application) | App-only token via `client_credentials` (the blueprint's own service principal) | Only tenant/app resources for which an **application permission (app role)** was explicitly granted; **no** specific user's data | *Agent* (application) |
| **DW** (Digital Worker / **AI teammate**) | Its **own agent-user identity** in Microsoft 365 | Own identity + delegated/OBO for M365 workloads | Its **own** mailbox, OneDrive, Teams presence, directory entry (and the user's data via OBO where applicable) | **AI teammate** (Frontier preview only) |

Key consequences (all verified in the lab):

- **OBO** — the agent needs a **delegated user token** whose audience is the target tool
  (for Mail: **Agent 365 Tools** `ea9ffc3e-8a23-4a7d-836d-234d7c7565c1`, scope
  `McpServers.Mail.All`). Email is sent **from the user's mailbox**.
- **S2S** — the agent authenticates with the blueprint's client id/secret. The **Work IQ
  Mail MCP is *not* reachable in pure S2S** unless an application app-role is granted on that
  resource: Entra returns `AADSTS82001: Agentic application '<appId>' is not permitted to
  request app-only tokens for resource 'ea9ffc3e-…'`. S2S is ideal for **autonomous / daemon
  / background** logic that needs no specific user's data.
- **DW / AI teammate** — requires the **Frontier preview program** and **licensing** on the
  agent user (see §5.4). Only this type has its **own mailbox/Teams presence**, so it is the
  only one that can be **@mentioned, emailed, or added to a Teams chat**
  ([AI teammate](https://learn.microsoft.com/microsoft-agent-365/developer/get-started#types-of-agents)).

> A single agent app can participate in more than one flow (e.g., an AI teammate that also
> runs a nightly S2S batch)
> ([observability concepts](https://learn.microsoft.com/microsoft-agent-365/developer/observability-concepts#authentication)).

### 2.2 Hosting models

There are **two distinct hosting models** — do not confuse them
([Foundry hosted agents](https://learn.microsoft.com/azure/foundry/agents/how-to/deploy-hosted-agent)):

| | **ACA — A365-SDK-hosted** | **FH — Foundry Hosted** |
| --- | --- | --- |
| Entry point | aiohttp `GenericAgentHost` (`host_agent_server.py`) | Foundry hosting wrapper (`main.py`) |
| Protocol | Bot Framework **activity protocol** `/api/messages` (+ optional custom `/chat` for a web UI) | **Responses** (`/responses`, OpenAI-compatible) or **Invocations** (`/invocations`, custom payload) |
| Compute | Docker image on **Azure Container Apps** (you own it) | Managed container on the **Foundry hosted-agent platform** |
| Deploy | `az acr build` + `az containerapp create` (or `deploy-aca*.ps1`) | `azd ai agent init` → `azd provision` → `azd deploy` |
| Tool wiring | `microsoft_agents_a365.tooling.McpToolRegistrationService` (needs Bot Framework `TurnContext`/`Authorization`) | `agent_framework` `MCPStreamableHTTPTool` (explicit HTTP client + bearer) — the SDK tool-registration **cannot** be reused here |
| Identity | Blueprint client id/secret via `CONNECTIONS__SERVICE_CONNECTION` | Managed Entra **agent identity** provisioned by Foundry |
| App Insights | Opt-in (connection string) | **Auto-injected** (`APPLICATIONINSIGHTS_CONNECTION_STRING`) |

> **Foundry hosting does NOT auto-wire M365 tools.** The Foundry↔Agent 365 integration is
> registry sync, publishing, and telemetry only. Any Mail/Teams/SharePoint access must be
> wired by the agent code itself (an MCP tool + a token). This was a key lesson in the lab.

**Special case — MAF-FH-DW.** The Digital Worker on Foundry does **not** use the
Responses/Invocations protocols. It packages the **same Bot Framework `/api/messages` code**
as the ACA agents into a container, runs it as a **Foundry hosted (container) agent**, and
relays Teams traffic through an **Azure Bot Service**. It is published to Microsoft 365 as a
**hireable digital worker**. See §4.3.

---

## 3. Capability comparison at a glance

| Capability | MAF-ACA-OBO | MAF-ACA-S2S | MAF-ACA-DW | MAF-FH-OBO | MAF-FH-S2S | MAF-FH-DW |
| --- | :---: | :---: | :---: | :---: | :---: | :---: |
| Own Entra **agent-user identity** | — | — | ✅ | — | — | ✅ |
| Own **mailbox / OneDrive / Teams presence** | — | — | ✅ | — | — | ✅ |
| Can be assigned **M365 licenses** | — | — | ✅ (required) | — | — | ✅ (required) |
| Acts as the **signed-in user** (OBO) | ✅ | — | ✅¹ | ✅ | — | ✅¹ |
| Acts as **itself** (app-only) | — | ✅ | — | — | ✅ | — |
| Sends mail from **user's** mailbox | ✅ | — | — | ✅ | — | — |
| Sends mail from **agent's own** mailbox | — | — | ✅ | — | — | ✅ |
| Requires **Frontier** program | — | — | ✅ | — | — | ✅ |
| End-user interaction surface | Custom web UI (`/chat`) | Custom web UI (`/chat`) | **Teams / Outlook / Office** | Custom web UI (Invocations) | Custom web UI (Responses) | **Teams / Outlook / Office** |
| Registered in A365 (Registry) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Observable in A365 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Work IQ (Tool GW) Mail MCP | ✅ (OBO token) | ⚠️ needs app-role | ✅ (OBO/own) | ✅ (OBO token) | ⚠️ needs app-role | ✅ (OBO/own) |
| **Web access** (`fetch_url`: URL reachability + page text)² | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Short conversation memory** (last 3 exchanges)³ | ✅ (web UI) | ✅ (web UI) | ✅ (Teams, in-process) | ✅ (web UI) | ✅ (web UI) | ✅ (Teams, in-process) |

¹ A DW can also perform OBO actions for a requesting user in addition to acting as itself.
² Always on, no token needed. For these six it's an in-process tool. MAF-FD-OBO / MAF-FD-S2S get the same
tool from the per-lab web-fetch MCP; see §6.4.
³ Always on, no infrastructure. MAF-FD-OBO / MAF-FD-S2S have it too, carried by the web UI; see §6.5.

---

## 4. Architectures

### 4.1 ACA — A365-SDK-hosted (OBO, S2S, DW)

All three ACA agents share **the same code** (`agent.py`, `host_agent_server.py`,
`agent_interface.py`, `start_with_generic_host.py`); they differ only in **identity
configuration** and **registration flow**.

```
Client / Teams / Web UI
   │  POST /api/messages   (Bot Framework activity)   ── or ──   POST /chat (web UI)
   ▼
host_agent_server.py  (GenericAgentHost, aiohttp)
   │  • JWT auth middleware (/api/messages);  /chat validates the user token itself
   │  • activity de-dup, "typing" indicator, notification handler
   ▼
AgentFrameworkAgent.process_user_message()   (agent.py)
   │  • personalizes the system prompt with the user's display name
   │  • setup_mcp_servers() → registers MCP tools (once, cached per process)
   │  • agent.run(message)  → LLM + optional tool calls
   ▼
Azure OpenAI  ⇄  MCP tools via the A365 Tool Gateway (e.g. mcp_MailTools)
   │
   ▼
reply → context.send_activity() (channel) or the /chat HTTP response
```

- **Runtime**: aiohttp web server in a Docker container on **Azure Container Apps**. Health
  at `/api/health` (excluded from JWT).
- **LLM**: Azure OpenAI via `OpenAIChatCompletionClient` (`agent_framework.openai`),
  configured with env vars (`AZURE_OPENAI_*`). Use **Chat Completions**, not the Responses
  API (the endpoint returns `400 API version not supported` for the latter).
- **Identity wiring** differs by auth model:
  - **OBO / DW**: `AUTH_HANDLER_NAME=AGENTIC` +
    `AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__*` +
    `CONNECTIONS__SERVICE_CONNECTION__SETTINGS__{CLIENTID,CLIENTSECRET,TENANTID}`. OBO tokens
    are obtained with `Authorization.exchange_token(...)`.
  - **S2S**: **no** auth handler; only the `CONNECTIONS__SERVICE_CONNECTION` app-only
    credentials. `USE_AGENTIC_AUTH=false`, so `setup_mcp_servers` uses the non-agentic path
    (and degrades to LLM-only if no tool token is available).
- **Web UI path (`/chat`)**: added on top of the Bot Framework host so a browser SPA can
  talk to the agent directly. It **validates the caller's Entra token**, (for OBO) performs
  the Mail OBO exchange, then calls `run_obo_mail_chat` / the LLM.

> **Env-var case sensitivity**: on Linux containers env-var names are case-sensitive — use
> **UPPERCASE** `CONNECTIONS__…` / `AGENTAPPLICATION__…`. On Windows they are upper-cased
> automatically, which hides the bug locally.

### 4.2 FH — Foundry Hosted (OBO = Invocations, S2S = Responses)

```
Web UI (MSAL SPA)                                Foundry hosted-agent platform
   │  POST <endpoint>/protocols/invocations       ┌───────────────────────────┐
   │     Authorization: Bearer <ai.azure.com>      │  main.py  (host wrapper)   │
   │     body: { message, mail_token? }            │  foundry_agent.py          │
   │                                               │   • FoundryChatClient      │
   ├───────────────────────────────────────────►  │   • MCPStreamableHTTPTool  │
   │                                               │     (Mail MCP + bearer)    │
   │  ◄── { response }                             └───────────────────────────┘
```

- **OBO → Invocations protocol.** A custom `@app.invoke_handler` reads `message` and the
  caller's `mail_token`, builds a `FoundryChatClient` + a Mail `MCPStreamableHTTPTool` whose
  httpx client carries `Authorization: Bearer <mail_token>`, and returns `{ "response": ... }`.
  Invocations is required because OBO needs **per-request access to the caller's token**.
- **S2S → Responses protocol.** `ResponsesHostServer(build_agent()).run()`. The Mail MCP
  tool (if used) stamps a **fresh agent-identity token** (`DefaultAzureCredential` for
  `<resource>/.default`) per request. The agent acts with its **own identity**; no user token.
- **Two independent tokens for Invocations from a browser**:
  1. `Authorization: Bearer <token for https://ai.azure.com/.default>` — authenticates the
     call to the **Foundry gateway** (audience determined empirically: `https://ai.azure.com`
     is accepted; `https://cognitiveservices.azure.com` returns `403`).
  2. body `mail_token = <token for McpServers.Mail.All>` — the delegated Mail token (OBO only).
- **Per-user session id** is mandatory: Foundry sessions are bound to the creating identity,
  so a shared id returns `session_not_accessible (403)`. Derive it per user and **rotate per
  page load** (`obo-<oid>-<nonce>`) so each reload lands on the **latest** deployed version
  (Invocations sessions are version-pinned, and the handler is stateless).
- Always open the MCP tool with `async with mail_tool:` (otherwise `MCP server failed to
  initialize: Cancelled via cancel scope`).

Reference: [Host MAF agents as Foundry hosted agents](https://learn.microsoft.com/azure/foundry/how-to/develop/framework-hosted-agents),
[Deploy a hosted agent (azd)](https://learn.microsoft.com/azure/foundry/agents/how-to/deploy-hosted-agent).

### 4.3 FH — Foundry Hosted Digital Worker (container + Bot Service)

The MAF-FH-DW model is architecturally closer to the ACA-DW than to the FH-OBO/S2S agents:

```
Teams / Outlook / Office
   │  (activity protocol)
   ▼
Azure Bot Service  ──►  Foundry hosted (container) agent  ──►  /api/messages
   (relay, appId =            (same GenericAgentHost code            (agent.py:
    blueprint id)              as ACA, in a Docker image)             FoundryDigitalWorkerAgent)
```

- Provisioned with **`azd provision`** (not `azd ai agent init`). The `infra/` +
  `scripts/` orchestrate: a Foundry project, an **Azure Bot Service** (relay between M365 and
  the Foundry app, configured with the agent endpoint and the **blueprint identity as
  appId**), a Docker image built and registered as a **hosted agent**, and a **publish to
  Microsoft 365** step that creates a **hireable digital worker**.
- The container runs the **same `/api/messages` aiohttp host** as the ACA agents
  (`create_and_run_host(FoundryDigitalWorkerAgent)`); the difference is *where* it runs and
  *how* it is reached (Bot Service relay), not the agent logic.
- Requires **blueprint approval** in the Microsoft 365 admin center, **Teams Developer
  Portal** configuration (Bot ID = Blueprint ID), then **instance creation** in Teams — same
  lifecycle as any AI teammate.

Reference: [Quickstart: hosted agent (azd)](https://learn.microsoft.com/azure/foundry/agents/quickstarts/quickstart-hosted-agent?pivots=azd),
[container_agents_docs](https://github.com/microsoft/container_agents_docs).

---

## 5. How each actor interacts with the agents

### 5.1 End users

| Type | How users interact |
| --- | --- |
| MAF-ACA-OBO / MAF-ACA-S2S | Through a **custom web UI** (the SPA in `ui/`) that calls the ACA `/chat` endpoint with the user's Entra token. |
| MAF-FH-OBO / MAF-FH-S2S | Through the **custom web UI**, calling the Foundry **Invocations**/**Responses** endpoint. |
| MAF-ACA-DW / MAF-FH-DW | Through **Microsoft 365 surfaces** — Teams 1:1/group chat and @mentions, Outlook email, Word/Office comments — because a Digital Worker has its own mailbox and Teams presence. |

> S2S agents have no user context: the S2S web UI passes the signed-in user's *verified
> profile* as text context (so the agent can answer "who am I?"), but the agent still acts
> with its own application identity.

### 5.2 Administrators (Microsoft 365 admin center — Agent 365)

Admins manage all six agents from **Agents → All agents** in the
[Microsoft 365 admin center](https://admin.cloud.microsoft/#/agents/all):

- **Registry / inventory** — every registered agent (blueprint or AI teammate) appears here
  for visibility and governance.
- **Requests** — approval queue for agents that require admin consent/activation (e.g., the
  FH-DW blueprint appears here for **Approve request and activate**).
- **Activate** (AI teammate) — choose *who can create instances*, apply a **policy template**
  (which **automatically assigns the Agent 365 license**), and set state to active.
- **Instances** (AI teammate) — add/inspect instances; assign/adjust **licenses** per
  instance at **All agents → Registry → `<blueprint>` → Instances → `<instance>` → Licenses**
  (agent users are licensed here, **not** under *Users → Active users*).
- **Unified app management** — for AI teammates, availability/activation/instances/licenses
  are managed **only** in the M365 admin center; Teams admin center shows the agent but its
  Status/Available-to fields are read-only.

### 5.3 Registration vs publishing (what puts an agent where)

- `a365 setup all` (blueprint agents: OBO/S2S) → registers the agent → it appears in **All
  agents / Registry**. `a365 publish` is a **no-op** for blueprint agents.
- `a365 publish --aiteammate` (ACA-DW) → produces `manifest.zip` → uploaded in the M365 admin
  center → appears in **Registry** as *Not activated* → **Activate**.
- `azd provision` (FH-DW) → creates the blueprint + Bot Service + hosted agent and **publishes
  the digital worker**; the blueprint appears under **Requests** for approval.

### 5.4 Licensing (Digital Workers only)

AI teammates are a **Frontier** feature and need precise licensing, or activation fails with
*"Insufficient licenses available"*
([Frontier](https://learn.microsoft.com/microsoft-agent-365/frontier),
[Create agent instances](https://learn.microsoft.com/microsoft-agent-365/developer/create-instance#troubleshooting)):

| License | Scope | Necessity |
| --- | --- | --- |
| Tenant enrolled in **Frontier** + Agent 365 ToS accepted | tenant | **Required** |
| ≥ 1 **Microsoft 365 Copilot** *or* **Microsoft Agent 365** (incl. **M365 E7 / Frontier Suite**) | tenant | **Required** |
| **Agent 365 / "Frontier for AI Teammates"** on the agent user | instance | **Required** (creates the Entra identity, mailbox, OneDrive, Teams presence) |
| **Microsoft 365 E5**, **Teams Enterprise**, **Microsoft 365 Copilot** on the agent user | instance | **Recommended** for full functionality |

OBO and S2S agents need **no** Frontier enrollment and **no** agent-user licenses.

---

## 6. Interacting with the Agent 365 Tool Gateway (Work IQ tools)

All Work IQ tools (Mail, and custom MCP servers) are reached through the **same Tool
Gateway**: `https://agent365.svc.cloud.microsoft/agents/servers/<serverName>`. The external
backend URL behind the gateway is irrelevant to the agent.

### 6.1 What must be present

| Layer | What is needed |
| --- | --- |
| **Code** | An MCP tool pointed at the gateway URL, plus a **token for the server's audience**. On **ACA** this is done by `McpToolRegistrationService` (agentic path — **no code change** to add a catalog server) or explicit `MCPStreamableHTTPTool` in the `/chat` path. On **FH** it is always an explicit `MCPStreamableHTTPTool` with an httpx client that carries the bearer. |
| **Configuration** | `ToolingManifest.json` listing each server: `{ mcpServerName, url, scope, audience }`. Populated by `a365 develop add-mcp-servers <name>` from the catalog (do not hand-author scope/audience). In production the agentic path can also **discover** servers dynamically from the gateway (`GET .../agents/v2/{agenticAppId}/mcpServers`). |
| **Permissions** | Blueprint consent: `a365 setup permissions mcp` (grants `McpServers.Mail.All`, `McpServersMetadata.Read.All`, and — for custom servers — `Tools.ListInvoke.All`) followed by **admin consent**. The server must be **Available** in the admin center. |

### 6.2 Token models — the critical detail

| | Mail MCP (V1, shared audience) | Custom MCP (V2, per-server audience) |
| --- | --- | --- |
| Audience | `ea9ffc3e-8a23-4a7d-836d-234d7c7565c1` (Agent 365 Tools) | the **server's own app id** (different!) |
| Scope | `McpServers.Mail.All` | `Tools.ListInvoke.All` (+ `McpServersMetadata.Read.All`) |

A token minted for `ea9ffc3e-…` does **not** authorize a custom V2 server — you must acquire
a token for that server's specific audience. The agentic `McpToolRegistrationService` resolves
the per-audience token automatically; a hand-rolled `/chat`/Invocations path must acquire the
second token itself.

### 6.3 Per auth model

- **OBO** — delegated user token for the tool audience/scope (e.g. Mail `McpServers.Mail.All`).
  Works out of the box; mail is sent from the user's mailbox.
- **S2S** — the tool must expose an **application** app-role and it must be **granted +
  admin-consented** on the blueprint; otherwise `AADSTS82001`. Work IQ Mail is delegated-only,
  so **pure S2S cannot call it** without additional app-role + an application access policy for
  a sender mailbox.
- **DW** — can use OBO for a requesting user and/or its **own** identity token (own mailbox).

References: [Tooling servers overview](https://learn.microsoft.com/microsoft-agent-365/tooling-servers-overview),
[Grant Agent 365 permissions](https://learn.microsoft.com/azure/foundry/agents/how-to/grant-agent-365-permissions).

### 6.4 Web access (built in, independent of the Tool Gateway)
Every code agent (ACA/FH/FD × OBO/S2S/DW — not the Copilot Studio agents) has a `fetch_url` tool. It
checks whether a **public** URL is reachable (HTTP status) and returns the page's readable text. Example
prompt: *"Can you read the content of https://example.com/ or at least tell me whether it is reachable
(HTTP 200)?"*. The tool uses no Agent 365 gateway, token or connection, so it behaves the same for OBO,
S2S and DW. It is SSRF-hardened: every redirect hop must resolve to public IPs, so the Azure metadata
endpoint and private ranges are refused. Download size, time and returned text are bounded, and the
page content is treated as untrusted data.
- **ACA / FH**: an in-process Agent Framework function tool (`web_fetch.py`, shipped in each sample).
- **FD**: prompt agents run no code, so the Lab Builder deploys one small anonymous MCP server per lab
  ([web-fetch-mcp/](../web-fetch-mcp/README.md)) and attaches it directly to each FD agent as an
  `MCPTool` restricted to `fetch_url`.

### 6.5 Short conversation memory (built in, no infrastructure)
Every code agent (not the Copilot Studio agents) remembers the **last 3 user/assistant exchanges** of the
conversation, so follow-ups resolve: *"What is the capital of France?"* → *"How many districts does it
have?"* → *"Which one is the most populous?"*. No database or cache is involved:
- **Web UI agents (OBO / S2S)**: the browser tab keeps the conversation and sends the last 3 exchanges
  with every request.
  - **ACA and FH-OBO** receive it as `history`, which `conversation_memory.py` re-validates: only
    user/assistant roles, each message truncated, the window re-capped. It's then prepended to the turn.
  - **FH-S2S and FD** receive it as a Responses message list, handled natively.

  Stateless on the server, so it works with any number of replicas. Reloading the page starts over.
- **Digital Workers (Teams)**: Teams sends no history, so the agent keeps an **in-process** window per
  Teams chat and user: bounded, and idle entries expire after 1 hour. It is lost when the container
  restarts and assumes a single replica (the ACA-DW deploy uses min = max = 1). A durable store (Table /
  Cosmos DB) is the upgrade path if persistence is needed.

`MEMORY_TURNS` (environment variable, default 3; 0 disables it) sizes the window.

---

## 7. Observability

All six agents emit OpenTelemetry through the **Microsoft OpenTelemetry distro**
(`microsoft.opentelemetry`, `use_microsoft_opentelemetry(...)`), which supports **three
independent destinations**: **Agent 365 Observability** (exporter), **Azure Monitor /
Application Insights**, and **console** (dev).

Agent 365 observability authentication branches on the flow
([observability concepts](https://learn.microsoft.com/microsoft-agent-365/developer/observability-concepts#authentication)):

| Flow | OAuth | Token claim | URL route |
| --- | --- | --- | --- |
| S2S | client credentials | `roles` | `/observabilityService/...` |
| OBO / own-user | on-behalf-of | `scp` | `/observability/...` |

The `{agentId}` in the URL must equal the caller's **appId** (`appid`/`azp` claim), and every
span must set `gen_ai.agent.id` to the same appId, or the server returns `403`.

### 7.1 What each type needs for observability

| Type | What to configure |
| --- | --- |
| **MAF-ACA-OBO / -S2S / -DW** | The A365 exporter is enabled with `ENABLE_A365_OBSERVABILITY_EXPORTER=true` (or the `a365_enable_observability_exporter` kwarg). A **per-turn token** is obtained via `Authorization.exchange_token(...)` (OBO/DW) or app-only (S2S) and passed to the exporter via `a365_token_resolver`. `BaggageBuilder().tenant_id(...).agent_id(...)` tags each turn. Optionally set `APPLICATIONINSIGHTS_CONNECTION_STRING` for Azure Monitor. |
| **MAF-FH-OBO / -S2S / -DW** | App Insights is **auto-injected** (`APPLICATIONINSIGHTS_CONNECTION_STRING`). For the A365 exporter, assign the app role **`Agent365.Observability.OtelWrite`** (`8f71190c-00c8-461d-a63b-f74abde9ba52`) on the **Foundry agent identity SP**, resource = the **`Agent365Observability`** SP (appId `9b975845-388f-4429-889e-eab1ef63949c`). **Restart the container** after granting (the managed-identity token is cached from before the assignment). Inspect logs with `azd ai agent monitor` (or the `:logstream` REST endpoint for the container DW). |
| **MCS-OH / MCS-NH** (Copilot Studio) | Not OTEL code. Connect Application Insights **per agent in Copilot Studio**: agent → **Settings → Advanced → Application Insights** → paste the resource's **Connection string** → optionally enable logging → **Save** (documented for the standard harness / MCS-OH; MCS-NH is experimental). The **same** lab App Insights resource works cross-tenant (it is only an instrumentation key + ingestion endpoint). |
| **MAF-FD-OBO / -S2S** (prompt) | **No** OTEL/App Insights wiring — Foundry Declarative agents run the platform prompt loop and are deployed via the Azure AI Projects SDK, not the Agent Framework OTEL distro. |

> `enable_a365=True` alone only adds **span enrichment** (attributes `gen_ai.agent.id`,
> `microsoft.tenant.id`, `user.name`, …); it does **not** export to A365 until the exporter
> switch is on.

---

## 8. Governance & security in Agent 365 (common to all six)

Because every agent is registered on a **Microsoft Entra Agent ID / agent identity
blueprint**, it inherits the Agent 365 enterprise controls
([Microsoft Agent 365 feature availability](https://learn.microsoft.com/office365/servicedescriptions/microsoft-agent-365/microsoft-agent-365#feature-availability),
[Share](https://learn.microsoft.com/microsoft-agent-365/share)):

- **Microsoft Entra** — agent identities, admin consent, **Conditional Access** and identity
  protection extended to agents, and Entra lifecycle policies (sponsor/manager workflows).
- **Microsoft Purview** — audit logs of agent activity, eDiscovery/content search, data
  lifecycle management, DLP, sensitivity-label inheritance, insider-risk and compliance
  extended to agents.
- **Microsoft Defender** — detection of suspicious agent activity, misconfiguration/exposure
  remediation, shadow-AI discovery, and blocking of risky tool invocations.
- **Governed tool access** — Work IQ tools are reached only through the **Tool Gateway** with
  scoped, admin-consented permissions per blueprint; access is auditable.
- **Security hygiene applied in the lab** — treat user message content as untrusted
  (anti-prompt-injection rules in the system prompt); keep secrets out of the repo (client
  secrets stored as **ACA secrets** / `azd` env, never committed); protect `/api/messages`
  with JWT and validate the user token on `/chat`; grant end-user access to FH agents through
  **both** Entra consent (AllPrincipals) **and** Azure RBAC (**Cognitive Services User** on
  the Foundry account), ideally via a **group**.

---

## 9. Source layout & how to reproduce

The sources live in a public GitHub repository (suggested name
**`a365-lab-toolkit`**) with one folder per hosting model and a shared UI:

```
a365-lab-toolkit/
├─ README.md
├─ docs/                     ← this documentation set
├─ ui/                       ← the MSAL web SPA (agent365-UI)
├─ aca/
│  ├─ obo/                   ← MAF-ACA-OBO
│  ├─ s2s/                   ← MAF-ACA-S2S
│  └─ dw/                    ← MAF-ACA-DW  (AI teammate)
├─ foundry-hosted/
│  ├─ obo/                   ← MAF-FH-OBO  (Invocations)
│  ├─ s2s/                   ← MAF-FH-S2S  (Responses)
│  └─ dw/                    ← MAF-FH-DW   (container + Bot Service)
└─ foundry-declarative/
   ├─ obo/                   ← MAF-FD-OBO  (prompt agent, Mail MCP)
   └─ s2s/                   ← MAF-FD-S2S  (prompt agent, own identity)
```

Each setup guide starts by cloning this repo and `cd`-ing into the relevant folder. Follow
the guide for your target type:

- [setup-MAF-ACA-OBO.md](setup-MAF-ACA-OBO.md)
- [setup-MAF-ACA-S2S.md](setup-MAF-ACA-S2S.md)
- [setup-MAF-ACA-DW.md](setup-MAF-ACA-DW.md)
- [setup-MAF-FH-OBO.md](setup-MAF-FH-OBO.md)
- [setup-MAF-FH-S2S.md](setup-MAF-FH-S2S.md)
- [setup-MAF-FH-DW.md](setup-MAF-FH-DW.md)

The OBO and S2S agents are exercised from the shared web SPA — see
[setup-web-ui.md](setup-web-ui.md).
