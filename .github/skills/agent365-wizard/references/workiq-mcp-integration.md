# Work IQ MCP integration — reusable lessons (any Work IQ MCP)

Getting the **Work IQ Mail** MCP (`mcp_MailTools`) working was hard, and **each agent variant hit a
different difficulty**. Every Work IQ MCP (Calendar, Teams, SharePoint, OneDrive, User, Word, Copilot,
Dataverse, …) uses the **same auth model** as Mail (the Agent 365 tooling gateway
`agent365.svc.cloud.microsoft`, resource/audience `ea9ffc3e-8a23-4a7d-836d-234d7c7565c1`, per-server
scope `McpServers.<Tool>.All` supplied by the catalog). So **these lessons apply unchanged to any
Work IQ MCP** — the wizard MUST reuse them when it attaches a Work IQ tool other than Mail.

> This file **consolidates and generalizes** the per-variant lessons; it does **not** replace them.
> The original, variant-specific detail stays in each `docs/setup-MAF-*.md` — do not delete it.

## Supportability by identity model (grounded in MS Learn)
Which identity type can call which MCP is a **platform/permission** concern — it is the **same across
ACA, FH and FD**; only the *token-wiring mechanism* differs by hosting. The three Agent 365 execution
modes ([Agent 365 identity](https://learn.microsoft.com/microsoft-agent-365/developer/identity#permissions-and-runtime-flow)):
- **OBO** — delegated, acts for a signed-in user (`scp` claim). No agent user needed.
- **S2S** — app-only, acts as its own agent identity (`roles` claim). No user context.
- **Agentic-User (= Digital Worker)** — the agent's **own Entra user account** (mailbox/Teams/Word);
  requires the **Frontier** program.

**Work IQ is delegated-only.** Official, repeated across the Work IQ docs: *"Work IQ uses Microsoft
Entra ID delegated authentication … Application-only (app-only) authentication isn't supported. Only
Bring your own Entra app (On-Behalf-Of) is supported"*
([Work IQ auth](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/work-iq#authentication-and-security))
and *"Work IQ tooling requires a delegated permission model, so this step is skipped automatically if
you chose S2S"* ([Get started](https://learn.microsoft.com/microsoft-agent-365/developer/get-started)).

| Identity | Any A365 MCP? | Work IQ (or WorkIQ-like delegated-only) MCP? |
|----------|---------------|-----------------------------------------------|
| **OBO** | ✅ delegated MCPs; ✅ app MCPs only if it also holds app perms | ✅ yes (delegated) — the canonical Work IQ path |
| **Agentic-User / DW** | ✅ (acts as its own user) | ✅ yes (delegated, own mailbox) — needs Frontier + M365 Copilot license |
| **S2S** | ✅ **only** MCPs that expose **application** permissions/app-roles | ❌ **no** — Work IQ (and any delegated-only MCP) rejects app-only |

So, to answer directly:
- **Can all three access A365 MCPs?** Not universally. It depends on the MCP's permission model: a
  delegated-only MCP (Work IQ and anything WorkIQ-like) is reachable by **OBO** and **DW** but **not
  pure S2S**; an MCP that exposes **application** permissions can also be reached by **S2S**.
- **Work IQ / WorkIQ-like (by auth):** delegated-only → **OBO + DW yes, S2S no** (`WorkIQAgent.Ask` is
  a delegated permission granted to a "bring-your-own" Entra app).
- **Differences by hosting (ACA/FH/FD)?** None for *who* can access — same platform rule. Only *how*
  the delegated token is wired differs: ACA = agentic auth handler / SPA OBO; FH = per-request
  `DefaultAzureCredential` or caller-supplied token; FD = declarative header template + `structured_inputs`
  (Foundry "OAuth identity passthrough"). Plus a **sample-code** difference: ACA is manifest-driven
  (generic), FH/FD wire only Mail today.

## Golden rule
The **token lifecycle** (how the agent obtains, refreshes and stamps the gateway token) is the hard
part, and it is **identical for every Work IQ MCP** because they share one resource
(`ea9ffc3e-…`). The *per-server* `scope`/`audience`/`url` differ only by the server's catalog entry and
are filled automatically by `a365 develop add-mcp-servers` into `ToolingManifest.json`. So once an
agent variant handles Mail correctly, adding another Work IQ MCP is a **catalog + manifest** change —
provided the agent attaches tools **manifest-driven** (see the support matrix below).

## Per-server permission catalog (what to grant for each Work IQ MCP)
Every Work IQ MCP uses the **legacy shared model** (Agent 365 CLI `setup permissions mcp`): one shared
resource app **`ea9ffc3e-8a23-4a7d-836d-234d7c7565c1`** ("Agent 365 Tools"), a **per-server delegated
scope** `McpServers.<Workload>.All`, plus a shared **`McpServersMetadata.Read.All`** granted alongside
any server. So an agent's MCP permissions = one scope per attached server **+** the shared metadata
scope, and **nothing** when it attaches no server — which is exactly why an agent that did not select
Mail must not receive `McpServers.Mail.All`. `a365 develop add-mcp-servers` fills the precise
`scope`/`audience` into `ToolingManifest.json` from the live catalog; the scaffolder mirrors this mapping
in [scripts/modules/_common.ps1](../scripts/modules/_common.ps1) (`$WORKIQ_MCP_CATALOG`) so it knows the
right permission per tool without hardcoding a grant.

**Delegated-only** — usable by OBO and Agentic-User/DW, never pure S2S.

**Today only `mcp_MailTools` is wizard-selectable and validated end-to-end.** The rest are listed so
enabling one later is a small, pre-scoped step; **confirm each server's `uniqueName` live with
`a365 develop list-available`** (a display name does not always map 1:1 to the `uniqueName`). The scopes
below are verified against the A365 blueprint OAuth2 grant reference
([foundry-hosted/dw/scripts/create-blueprintsp-oauth2-grants.ps1](../../../../foundry-hosted/dw/scripts/create-blueprintsp-oauth2-grants.ps1)).

| Work IQ server (workload) | `uniqueName` | Delegated scope | Wizard-selectable |
|---------------------------|--------------|-----------------|-------------------|
| Mail | `mcp_MailTools` | `McpServers.Mail.All` | ✅ today |
| Calendar | confirm via list-available | `McpServers.Calendar.All` | mapped |
| Teams | confirm via list-available | `McpServers.Teams.All` | mapped |
| Copilot | confirm via list-available | `McpServers.CopilotMCP.All` | mapped |
| OneDrive / SharePoint | confirm via list-available | `McpServers.OneDriveSharepoint.All` | mapped |
| SharePoint Lists | confirm via list-available | `McpServers.SharepointLists.All` | mapped |
| User | confirm via list-available | `McpServers.Me.All` | mapped |
| Word | confirm via list-available | `McpServers.Word.All` | mapped |
| Excel | confirm via list-available | `McpServers.Excel.All` | mapped |
| PowerPoint | confirm via list-available | `McpServers.PowerPoint.All` | mapped |
| Files | confirm via list-available | `McpServers.Files.All` | mapped |
| Knowledge | confirm via list-available | `McpServers.Knowledge.All` | mapped |
| Dataverse | confirm via list-available | `McpServers.Dataverse.All` | mapped |
| Dataverse (custom) | confirm via list-available | `McpServers.DataverseCustom.All` | mapped |
| D365 Sales | confirm via list-available | `McpServers.D365Sales.All` | mapped |
| D365 Service | confirm via list-available | `McpServers.D365Service.All` | mapped |
| ERP Analytics | confirm via list-available | `McpServers.ERPAnalytics.All` | mapped |
| MCP Management | confirm via list-available | `McpServers.Management.All` | mapped |
| Developer | confirm via list-available | `McpServers.Developer.All` | mapped |
| M365 Admin | confirm via list-available | `McpServers.M365Admin.All` | mapped |
| Admin 365 Graph | confirm via list-available | `McpServers.Admin365Graph.All` | mapped |
| Discovery/Answers search | confirm via list-available | `McpServers.DASearch.All` | mapped |
| Web Search | confirm via list-available | `McpServers.WebSearch.All` | mapped |
| *(any server, shared)* | — | `McpServersMetadata.Read.All` | always |

The scaffolder does **not** hand-write these scopes into the manifest for non-Mail servers (to stay
correct on any tenant / permission model): `Set-ToolingManifest` keeps or removes the **shipped** Mail
entry, and for a future non-Mail Work IQ server it emits `a365 develop add-mcp-servers <uniqueName>` so
the CLI writes the catalog-authoritative `scope`/`audience`, then `a365 setup all`/`setup permissions mcp`
grants exactly those. **Custom BYO `ext_*` servers** instead use the **per-server model**
(`Tools.ListInvoke.All` on each server's own resource app) + the same shared `McpServersMetadata.Read.All`.

## Per-variant difficulty → fix (all reusable for any Work IQ MCP)

| Variant | Token acquisition | Difficulty hit | Fix (generic to any Work IQ MCP) | Doc |
|---------|-------------------|----------------|----------------------------------|-----|
| **ACA-OBO** | Agentic auth handler (`AUTH_HANDLER_NAME=AGENTIC`, scope `ea9ffc3e-…/.default`); per-turn `add_tool_servers_to_agent` (manifest-driven). SPA `/chat` uses an OBO-exchanged `mail_token`. | Memoized `setup_mcp_servers` froze the token in the httpx headers → **HTTP 401** after ~60–90 min on a long-lived replica. | **Token-TTL rebuild**: rebuild the MCP tools (calling `tool_service.cleanup()` first) once older than `MCP_TOKEN_TTL_SECONDS` (default 1800s). Generic — refreshes **all** manifest servers. | [setup-MAF-ACA-OBO.md](../../../../docs/setup-MAF-ACA-OBO.md) §8/§10 |
| **ACA-S2S** | App-only bearer (blueprint confidential client); manifest-driven. | Pure S2S (app-only) **cannot call delegated Work IQ tools** → `AADSTS82001`, blocks the turn. | **Degrade to LLM-only** when no agentic auth / bearer / handler is present (skip `add_tool_servers_to_agent`). A permanent constraint of delegated tools, not a bug. | [setup-MAF-ACA-S2S.md](../../../../docs/setup-MAF-ACA-S2S.md) §6/§7 |
| **ACA-DW** | Same as ACA-OBO (agentic handler). | (1) Same token freeze → 401. (2) SDK omits **`x-ms-agentid`** on per-server tool calls → gateway 401 (`x-ms-agentid=None`). (3) Session-teardown **DELETE returns 401** (token already gone). | (1) Token-TTL rebuild. (2) `mcp_diag.py` patches `httpx` to **stamp `x-ms-agentid`** (from JWT `xms_par_app_azp`>`appid`>`azp`) on gateway calls. (3) Treat teardown **DELETE 401 as benign** so `_tools_broken` never latches. All generic across servers. | [setup-MAF-ACA-DW.md](../../../../docs/setup-MAF-ACA-DW.md) §9 |
| **FH-OBO** | **Caller-supplied** per-request `mail_token` (the SPA acquires a delegated token; the agent stamps `Authorization: Bearer`). | Agentic apps **cannot mint their own OBO token** (`AADSTS82002`); the token must come from the caller. | **Per-request token supply**: never cache; re-acquire per UI→agent request. Generic — any Work IQ token can be supplied the same way. | [setup-MAF-FH-OBO.md](../../../../docs/setup-MAF-FH-OBO.md) §2 |
| **FH-S2S** | Per-request agent-identity token via `_AgentTokenAuth` (calls `DefaultAzureCredential.get_token(ea9ffc3e-…/.default)` on **every request**). | Without a provisioned **agent user + mailbox**, attaching Mail fails hard and breaks every response. | **Per-request token refresh** (no memoization → no freeze) **+ conditional attach** (`S2S_ENABLE_MAIL`, only when the agent user exists). Generic pattern; gate any Work IQ MCP that needs a mailbox/user. | [setup-MAF-FH-S2S.md](../../../../docs/setup-MAF-FH-S2S.md) §2/§6 |
| **FH-DW** | Per-turn `auth.exchange_token(scopes=[ea9ffc3e-…/.default])`; `_AgentTokenAuth` wraps the per-turn token as a callable. | Each hired autopilot **instance** has its own identity with **no model RBAC** → model 401 `PermissionDenied` (distinct from the MCP token, but same "per-instance identity" trap). | **Per-turn re-exchange** (fresh token every turn) **+ route model calls via the Foundry project endpoint** (implicit access) instead of the account endpoint (which needs a per-instance role). Generic to any per-instance identity. | [setup-MAF-FH-DW.md](../../../../docs/setup-MAF-FH-DW.md) §6.2 |
| **FD-OBO** | Declarative MCP tool with `headers={"Authorization":"{{mail_token}}"}`; the SPA supplies `mail_token` via `structured_inputs`. | Wrong/typo'd audience GUID makes the platform reject the tool. | **Centralize the canonical resource** `ea9ffc3e-…` and build the scope from it. The platform fills the header template per request — generic for any Work IQ MCP tool. | [setup-MAF-FD-OBO.md](../../../../docs/setup-MAF-FD-OBO.md) §2/§3 |
| **FD-S2S** | None (no tools; own identity). | Delegated Work IQ tools unreachable app-only (as ACA-S2S), no mailbox. | Publish **with no Work IQ tools**; state the limitation in the agent instructions. | [setup-MAF-FD-S2S.md](../../../../docs/setup-MAF-FD-S2S.md) §2 |

## Generic lessons (reuse for ANY Work IQ MCP)
1. **Never memoize a baked-in token** — the gateway token is stamped into the MCP tool's httpx headers
   at build time and is not auto-refreshed. Use one of: token-TTL rebuild (ACA), per-request refresh
   via `DefaultAzureCredential` (FH-S2S), per-turn `exchange_token` (ACA-OBO/DW, FH-DW), or
   caller-supplied per-request token (FH-OBO, FD-OBO).
2. **Stamp `x-ms-agentid`** on gateway calls when the SDK omits it (ACA-DW `mcp_diag.py`). Applies to
   every server behind `agent365.svc.cloud.microsoft`, not just Mail.
3. **Teardown DELETE 401 is benign** — session termination happens after the token is gone; do not let
   it latch a "tools broken" state.
4. **Delegated-only tools need a user context** — pure S2S/app-only identities can't call them
   (`AADSTS82001`). Degrade to LLM-only (ACA-S2S) or gate the attach behind a provisioned agent
   user/mailbox (FH-S2S). This is true for most Work IQ MCPs (Mail, Calendar, Teams, …).
5. **Agentic apps can't self-mint OBO** (`AADSTS82002`) — the delegated token must be supplied by the
   caller (SPA) for OBO variants.
6. **One resource for all Work IQ** — the agentic-auth scope `ea9ffc3e-…/.default` already covers every
   Work IQ MCP; only the per-server `McpServers.<Tool>.All` (in the manifest, from the catalog) differs.
7. **Per-instance identity trap (DW)** — hired autopilot instances have their own identity; prefer
   implicit access (project endpoint) or grant per-instance RBAC.

## Support matrix — can the wizard attach an extra Work IQ MCP without code changes?
| Variant | Turn-path attach | Extra Work IQ MCP via wizard (`add-mcp-servers`) |
|---------|------------------|--------------------------------------------------|
| ACA-OBO | **manifest-driven** (generic) | ✅ works: token/refresh lessons already generic |
| ACA-DW  | **manifest-driven** (generic) | ✅ works (agentic user; Teams/Outlook surface) |
| ACA-S2S | manifest-driven, but delegated tools need a user | ⚠️ only app-role-consented tools; delegated Work IQ stays LLM-only |
| FH-OBO / FH-S2S / FH-DW | **Mail is hardcoded** in `foundry_agent.py` / `agent.py` (`MAIL_MCP_URL/RESOURCE/SCOPE`, explicit `mcp_MailTools`) | ⚠️ manifest/permissions update works, but the sample **code wires only Mail** — attaching another Work IQ MCP needs the same constants + attach block generalized in code (see hardcoded inventory) |
| FD-OBO | declarative tool with templated header | ⚠️ add a second MCP tool entry in `agent_config.py` (same header template + a second `structured_inputs` token) |
| FD-S2S | none | ❌ delegated Work IQ tools not usable app-only |

> **Wizard policy:** for **ACA-OBO / ACA-DW** the tool selection is fully generic — attach any Work IQ
> MCP with `a365 develop add-mcp-servers <uniqueName>` + `a365 setup permissions mcp`. For **FH/FD**
> the wizard still updates the manifest/permissions, but warn the user that the sample code currently
> wires only Mail, so a non-Mail Work IQ tool needs the code generalization below before the agent
> actually calls it.

## Hardcoded Mail-specific points (parameterize these to generalize FH/FD in code)
Keep the ACA manifest-driven path as-is (already generic). The FH/FD samples hardcode Mail:
- `foundry-hosted/obo/foundry_agent.py` — `MAIL_MCP_URL`, `MAIL_MCP_RESOURCE`, tool `name="mcp_MailTools"`.
- `foundry-hosted/s2s/foundry_agent.py` — `MAIL_MCP_URL`, `MAIL_MCP_RESOURCE`, `MAIL_MCP_SCOPE`, `name="mcp_MailTools"`.
- `foundry-hosted/dw/src/hello_world_a365_agent/agent.py` — `MAIL_MCP_URL`, `MAIL_MCP_RESOURCE`, `MAIL_MCP_SCOPE`, `name="mcp_MailTools"`.
- `foundry-declarative/obo/agent_config.py` — `MAIL_MCP_URL`, `MAIL_MCP_RESOURCE`, `MAIL_MCP_SCOPE`.
- ACA: `aca/obo/agent.py` (`run_obo_mail_chat` SPA path) + `aca/*/verify_deploy.py` hardcode the Mail
  URL/name for the standalone verifier; the turn path itself is manifest-driven.

Generalization pattern (future code change, not required for ACA): replace the single `MAIL_MCP_*`
constants with a small list of `{ url, resource, scope, name }` built from `ToolingManifest.json`
(or an env list), and loop the attach. The **token handling stays identical** — that is the whole
point: the hard part (tokens) is already solved and reusable.
