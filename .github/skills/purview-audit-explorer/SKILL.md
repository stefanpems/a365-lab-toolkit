# Skill: Purview Audit Explorer

READ-ONLY skill to read the **user↔agent message exchange** of Agent 365 / Lab Builder agents from
**Microsoft Purview**, and to discover/audit agent activity — a complement to the App Insights–based
Conversation Explorer. Verified against a live lab tenant on 2026-09-20.

Use this skill when the user wants to: read an agent's conversation from Purview; find which users chatted
with the lab agents; or audit what mail/files an agent touched — especially for **FH** (Foundry Hosted),
where App Insights only exposes session metadata but Purview returns the **full transcript**.

## Two read-only Graph data sources

| Purpose | Endpoint | Application permission |
|---------|----------|------------------------|
| **Full transcript** (prompt + response text), per user | `GET https://graph.microsoft.com/beta/copilot/users/{userId}/interactionHistory/getAllEnterpriseInteractions` | `AiEnterpriseInteraction.Read.All` |
| **Discovery + action auditing** (which users/agents interacted; the mail/files an agent read) | `POST https://graph.microsoft.com/beta/security/auditLog/queries` (recordType `copilotInteraction`) then `GET .../{id}/records` | `AuditLogsQuery.Read.All` |

### Interaction object shape (interaction history)
`id, sessionId, requestId, appClass, interactionType, conversationType, etag, createdDateTime, locale,
contexts, from{user|application}, body{content,contentType}, attachments, links, mentions`.

- **`appClass` = the agent key**:
  - `IPM.SkypeTeams.Message.ConnectedAIApp.AzureAI.<name>` — Foundry agent/project **or** an Azure OpenAI
    resource/deployment (direct model chat). For **Lab Builder** `<name>` is the Foundry **project** name =
    the lab prefix (verified: `lab12`). Other verified samples: `agentframeworkfh-obo-agent-dev`,
    `dwfhqkxepmnff2nsoproj` (a DW), `a09091aoai`, `a09091aoai_gpt-4.1`.
  - `IPM.SkypeTeams.Message.Copilot.ThirdPartyCopilot` — Copilot Studio / M365 Copilot surface (MCS).
- **Direction** = `interactionType`: `userPrompt` → USER, `aiResponse` → AGENT. Do **not** use
  `from.user.displayName` for the speaker — for Foundry it is the platform label ("Microsoft Foundry").
- **Group a conversation** by `sessionId`, order by `createdDateTime`. An `aiResponse` with empty
  `body.content` is a real no-text turn → render `(no text captured)`, never drop it.
- **Server-side `$filter` is NOT supported** on `interactionType`/`createdDateTime` (only `$top`). Filter
  by time and appClass **client-side** (the scripts do this).

### Audit record shape (discovery)
`createdDateTime, userPrincipalName, operation (CopilotInteraction), service (Copilot), auditData`.
`auditData.CopilotEventData` carries `AppHost` (e.g. `ThirdPartyCopilot`), `ConversationId`, `ThreadId`,
`AISystemPlugin`, and **`AccessedResources`** (emails/files/links the agent read — great for action
auditing). The audit query API is **async**: create → poll `status` until `succeeded` → GET records.

## Auth model — app-only is required (verified 2026-09-20)
The transcript endpoint `getAllEnterpriseInteractions` is **not supported in a delegated context** (returns
HTTP 412 `"Requested API is not supported in delegated context"`), and `AiEnterpriseInteraction.Read.All`
exists **only as an application permission** (there is a delegated `AiEnterpriseInteraction.Read`, but the
endpoint rejects delegated). So a plain `Connect-MgGraph` sign-in **cannot** read transcripts — an
**app-only** token is mandatory. The design therefore separates a one-time privileged **Setup** from a
deterministic, read-only **runtime**:

**One-time Setup** (`Setup-PurviewAudit.ps1`, idempotent, needs a Global/Application admin):
```pwsh
pwsh -File .github/skills/purview-audit-explorer/scripts/Setup-PurviewAudit.ps1              # Graph PowerShell (default, cross-platform)
pwsh -File .github/skills/purview-audit-explorer/scripts/Setup-PurviewAudit.ps1 -Method Az   # reuse an existing `az login` admin session
```
It creates/reuses app `a365-purview-audit-explorer` with three **read-only application** permissions —
`AiEnterpriseInteraction.Read.All`, `AuditLogsQuery.Read.All`, `User.Read.All` — grants admin consent,
mints a client secret, and caches the credential **outside the repo** at
`$HOME/.a365-purview-audit-explorer/cred.json` (never committed). `User.Read.All` lets the runtime resolve
UPN↔id without any Azure CLI dependency.

**Runtime** (`Get-PurviewToken`): reads only the cached credential and mints an app-only token. No
interactive sign-in, no Azure CLI, **no side effects** — identical behaviour on every run. If the
credential is missing/stale it instructs the user to run Setup once.

## Scripts (PowerShell 7)
Run from the repo root. **Run Setup once first**, then the read-only tools need no sign-in.

```pwsh
# 0) ONE-TIME setup (privileged admin; idempotent)
pwsh -File .github/skills/purview-audit-explorer/scripts/Setup-PurviewAudit.ps1

# 1) Discover which users/agents interacted (async audit query; tenant-wide)
pwsh -File .github/skills/purview-audit-explorer/scripts/Find-InteractionUsers.ps1 -SinceDays 7

# 2) List an agent's conversations from a user's interaction history
pwsh -File .github/skills/purview-audit-explorer/scripts/List-AgentConversations.ps1 `
     -UserUpn admin@<tenant>.onmicrosoft.com -SinceHours 168 [-AppClassLike '*lab12*'] [-AsJson]

# 3) Render the full ordered transcript of one conversation
pwsh -File .github/skills/purview-audit-explorer/scripts/Show-Conversation.ps1 `
     -UserUpn admin@<tenant>.onmicrosoft.com -SessionId <full-session-id> -SinceHours 168
```

- `Setup-PurviewAudit.ps1` — one-time privileged setup (`-Method GraphPowerShell` default, or `-Method Az`).
- `_common.ps1` — dot-sourced helpers: `Get-PurviewToken` (runtime, cache-only app-only token),
  `Register-PurviewApp` (setup), `Resolve-UserId`, `Get-EnterpriseInteractions` (page + client-side
  time/appClass filter), `Format-AgentName`, `Invoke-Graph`, `Get-ODataNext`.
- `List-AgentConversations.ps1` — one row per `appClass`+`sessionId`; `-AsJson` emits clean JSON (suppresses
  host diagnostics so stdout is parseable).
- `Show-Conversation.ps1` — ordered transcript, full millisecond timestamps, `(no text captured)` for empty
  bodies.
- `Find-InteractionUsers.ps1` — async audit query for `copilotInteraction`; prints distinct users and app
  hosts. Increase `-PollSeconds` if the query is slow (it can take a few minutes).

## Coverage (verified 2026-09-20)
- **FH / DW / Foundry project agents (incl. Lab Builder `lab12`)** and **MCS** → **full transcript** ✔.
- **FD** and **ACA/S2S** → verify per case (FD is a Foundry project so likely yes; ACA custom-SPA content
  reaches Purview only if it flows through the M365 substrate — otherwise use App Insights, or audit the
  agent's *actions* via `AccessedResources`).
- Audit discovery verified: a 30-day `copilotInteraction` query returned 115 records for the lab tester.

## Related
- App Insights transcripts (MCS/FD full, FH metadata only): **Conversation Explorer**
  (`.github/agents/conversation-explorer.agent.md`).
- Repo memory: `/memories/repo/conversation-explorer-fh-fd.md`.
