# Map Explainer — skill

READ-ONLY tooling that explains the numbers on the **Microsoft Admin Center / Agent 365 "Map"** for a
**Copilot Studio (MCS)** agent by reproducing them from the agent's **Application Insights** resource and
listing the underlying **sessions / tool calls / exceptions** with meaningful detail.

Use this skill together with the **Map Explainer** agent
([`.github/agents/map-explainer.agent.md`](../../agents/map-explainer.agent.md)). The agent runs the
interactive wizard; this skill documents the verified data model and the helper scripts.

## When to use
- The user is on **MAC → Agent 365 → Map**, selected an MCS agent, and wants to know **which** sessions /
  calls / exceptions are behind the counters (the Map's **"View connections"** only redraws the graph).
- The user asks to "explain the map numbers", "list the sessions behind the map", or "drill into a tool /
  user / connected-agent edge".

Not for Foundry (FH/FD) or ACA agents — use the **Conversation Explorer** or **Purview Audit Explorer**.

## Verified data model (2026-09-20, lab16-appinsights)
The Map for an MCS agent is backed by the lab's Application Insights. Only three tables carry the data:
`customEvents`, `dependencies`, `pageViews` (no `exceptions`/`traces` table).

### Agent identity — the critical column
- Per-event agent = **`cloud_RoleInstance`** (e.g. `lab16-MCS-OH-1`). `cloud_RoleName` is always
  "Microsoft Copilot Studio". One App Insights resource typically serves **several** agents, so you must
  attribute every row to an agent via `cloud_RoleInstance`.
- Direct `where cloud_RoleInstance == '<agent>'` and `summarize by cloud_RoleInstance` **work** (Portal
  *Logs* and CLI). The scripts still **project** it and aggregate **client-side** on purpose — to parse
  `customDimensions` once and to survive transient API throttling, which surfaces as a misleading
  `BadArgumentError` (just retry the same query). Use direct KQL for the manual "How-to" path.

### Query hygiene
- Always pass **`--offset 30d`** (the CLI default window is 1h).
- KQL must be a **single line** for the CLI; multi-line/heredoc KQL gets mangled into `BadArgumentError`
  or a raw dump. In the Portal *Logs* blade multi-line KQL is fine.
- Use single-quote KQL literals (`'x'`), never the bracketed double-quote form.
- A repeated `BadArgumentError` on a query that should work is almost always **throttling** — retry.

### Map node → source mapping
| Map edge / node | Source | Aggregation | Notes |
|-----------------|--------|-------------|-------|
| **USER** — *sessions* | `customEvents` | distinct `session_Id` for the agent, per resolved user | Teams uses **one** stable `session_Id` per user thread; `pva-studio` / `pva-published-engine-direct` mint a **new** `session_Id` per conversation. |
| **USER** — turns / transcript | `customEvents` `BotMessageReceived` (user→bot; `text`=ask, `fromName`=user, `recipientName`=agent) / `BotMessageSend` (bot→user; `text`=reply) | ordered by `timestamp` | `OnErrorLog` = agent-level error (`ErrorCode`, `ErrorMessage`, `ConversationId`). |
| **TOOL** — *calls* / *exceptions* | `dependencies` | group by `target` (= `shared_<connector>/<Action>`); exceptions = `success == false` | Targets seen: `…a365outlookmailmcp/mcp_MailTools` (Mail), `…zzrigelanon…/InvokeServer` (Custom MCP Anon), `…zzrigelauth…/InvokeServer` (Custom MCP Auth). `resultCode`/`duration` present; **`data` is empty**. |
| **CONNECTED AGENT** | `pageViews` | `name` matches `…InvokeConnectedAgentTaskAction.<callee>` | The callee's own turns live in the **same** App Insights under `cloud_RoleInstance == <callee>`. |

### User resolution
The user identity is not stored as a UPN. Resolve per session:
- Teams turns carry `fromName` (display name, e.g. "MOD Administrator").
- `pva-*` turns carry the user's **AAD object id** inside `user_Id` (channel-prefixed). Extract the GUID
  and resolve it best-effort with `az ad user show --id <guid> --query displayName -o tsv`, so the same
  user's Teams and Studio sessions **merge** into one node (matching the Map).

### Why counts can differ from the Map (state this to the user)
1. The Map is served by **Copilot Studio / Agent 365 analytics**, which retains history from **before**
   this App Insights was wired → its **session** count is usually a little **higher**. Very recent
   activity may be in App Insights before it appears on the Map. Tool-call counts match closely (same
   connector-call stream).
2. The Map's fine-grained MCP sub-tools (`InvokeServer.server_time`, `InvokeServer.propagate_to_graph`,
   `DataverseSearch`) are **not** in App Insights `dependencies` (empty `data`). Reproduce tool calls at
   the **connector/target** granularity only; never fabricate sub-tool counts.

## Scripts (`scripts/`)
All are READ-ONLY, dot-source `_common.ps1`, take `-App` / `-Rg` and default to `-OffsetDays 30`.

| Script | Purpose | Key params |
|--------|---------|------------|
| `_common.ps1` | Shared helpers: `Invoke-AiQuery` (single-line KQL + `--offset` + retry), `Get-MapCustomEvents` / `Get-MapDependencies` / `Get-MapPageViews` (project + client-side parse), `Resolve-AadName`, formatting. | — |
| `Get-MapAgents.ps1` | List agents in a resource with `sessions / users / toolCalls / exceptions / agentErrors / last`. | `-Filter <prefix>` (e.g. `lab`), `-Json` |
| `Get-MapConnections.ps1` | For one agent, list its USER / TOOL / CONNECTED-AGENT connections with the Map's counters. | `-Agent`, `-Json` |
| `Show-MapConnectionDetails.ps1` | Drill into one connection and print the fixed meaningful details. | `-Agent`, `-Kind USER\|TOOL\|AGENT`, `-Key`, `-OnlyExceptions`, `-Full`, `-Max` |

### Examples
```pwsh
# 1) Agents in a lab's App Insights (Lab Builder agents only)
pwsh -File scripts/Get-MapAgents.ps1 -App lab16-appinsights -Rg lab16-appinsights-rg -Filter lab

# 2) One agent's connections
pwsh -File scripts/Get-MapConnections.ps1 -App lab16-appinsights -Rg lab16-appinsights-rg -Agent lab16-MCS-OH-1

# 3) Drill-downs
pwsh -File scripts/Show-MapConnectionDetails.ps1 -App lab16-appinsights -Rg lab16-appinsights-rg -Agent lab16-MCS-OH-1 -Kind USER  -Key "MOD Administrator" -Full
pwsh -File scripts/Show-MapConnectionDetails.ps1 -App lab16-appinsights -Rg lab16-appinsights-rg -Agent lab16-MCS-OH-1 -Kind TOOL  -Key Mail -OnlyExceptions
pwsh -File scripts/Show-MapConnectionDetails.ps1 -App lab16-appinsights -Rg lab16-appinsights-rg -Agent lab16-MCS-OH-1 -Kind AGENT -Key lab16-MCS-OH-2
```

## The fixed "meaningful details" (by design)
| Connection | Per-item details | Why |
|------------|------------------|-----|
| **USER** (sessions) | start→end (UTC) + duration; channel (Teams / Studio / published-test); #user & #bot turns; **first ask**; **last outcome**; any `OnErrorLog`. `-Full` = full transcript. | *When*, *what asked*, *what happened*, errors. |
| **TOOL** (calls / exceptions) | timestamp; **OK/FAIL + HTTP resultCode**; duration(ms); **triggering prompt**; **resulting reply**; failures → nearest `OnErrorLog` (cause). | *Why* called, **outcome**, **error cause**. |
| **CONNECTED AGENT** | timestamp; **user prompt** that triggered the hand-off; **caller's reply**; **callee's** received message + reply. | The agent-to-agent exchange and result. |

## Two modes per connection: Results vs How-to
When drilling into a connection the wizard offers a choice:
- **Results** — run `Show-MapConnectionDetails.ps1` and show the items (default automated path).
- **How-to** — output the manual **Portal procedure + KQL** so the user reproduces it themselves.

### Manual "Where" preamble (every connection)
1. Azure Portal → Application Insights resource **`<App>`**.
2. **Monitoring → Logs** (KQL editor).
3. Time range → **Last 30 days** (or match the Map window).
4. Paste a query → **Run**. (Same KQL runs via `az monitor app-insights query --app <App> -g <Rg>
   --offset 30d --analytics-query "<single line>"`.)

Repeat the caveats: App Insights can be **lower** than the Map (pre-wiring history) and **higher** for very
recent activity; tool-call counts line up closely.

### Manual KQL library (verified 2026-09-20)
**USER — sessions of one user**
```kql
customEvents
| where timestamp > ago(30d) and cloud_RoleInstance == '<agent>'
| where tostring(customDimensions.fromName) == '<Display Name>' or user_Id contains '<user AAD object id>'
| summarize Sessions = dcount(session_Id),
            UserTurns = countif(name == 'BotMessageReceived' and tostring(customDimensions.type) == 'message'),
            FirstSeen = min(timestamp), LastSeen = max(timestamp)
```
Use `contains` (not `has`) for the object id — Studio/published `user_Id` = `<channel><objectId>` with no
word boundary, so `has` misses it. Per-session list: same filter, `summarize … by session_Id`. Read one
session: `customEvents | where session_Id == '<id>' and name in ('BotMessageReceived','BotMessageSend')`.

**TOOL (connector level) — calls & exceptions**
```kql
dependencies
| where timestamp > ago(30d) and cloud_RoleInstance == '<agent>' and target == '<target>'
| summarize Calls = count(), Exceptions = countif(success == false), Last = max(timestamp)
```
Targets: `shared_a365outlookmailmcp/mcp_MailTools` (Mail), `…zzrigelanon…/InvokeServer` (Custom MCP Anon),
`…zzrigelauth…/InvokeServer` (Custom MCP Auth). Per-call list / failures-only: drop the summarize and
`project timestamp, success, resultCode, duration, conversationId=tostring(customDimensions.conversationId)`
(add `and success == false` for exceptions). See the prompt/answer via the transcript query keyed by
`conversationId`.

**TOOL (fine MCP sub-tool: `server_time`, `propagate_to_graph`, `DataverseSearch`)**
Not countable from App Insights — `dependencies.data` is empty; the Map's number comes from the Copilot
Studio / Agent 365 backend. Point the user to the Map node / Copilot Studio analytics. Best-effort context:
```kql
customEvents
| where timestamp > ago(30d) and cloud_RoleInstance == '<agent>' and name in ('BotMessageReceived','BotMessageSend')
| where tostring(customDimensions.text) contains '<sub-tool name>'
| project timestamp, name, conversationId = tostring(customDimensions.conversationId), text = tostring(customDimensions.text)
| order by timestamp asc
```

**CONNECTED AGENT — hand-offs**
```kql
pageViews
| where timestamp > ago(30d) and cloud_RoleInstance == '<agent>' and name contains 'InvokeConnectedAgentTaskAction.<callee>'
| summarize Invocations = count(), Last = max(timestamp)
```
The callee's own turns are in the SAME resource under `cloud_RoleInstance == '<callee>'`.

## Prerequisites
- Azure CLI with the Application Insights extension. If a query fails with a missing-command error:
  `az extension add --name application-insights`.
- Read access to the subscription holding the App Insights resource; `az ad user show` is best-effort and
  degrades gracefully to `oid:<guid>` if directory read is unavailable.
