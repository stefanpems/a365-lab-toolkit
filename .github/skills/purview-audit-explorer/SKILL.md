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

## Auth model — device sign-in is BLOCKED in this workspace
Do **not** use `Connect-MgGraph -UseDeviceAuthentication`. The Azure CLI token also lacks the two target
scopes. Instead the scripts **bootstrap a dedicated app registration** and mint **app-only** tokens:

1. Reuse the operator's already-signed-in `az` **admin** session (holds `Application.ReadWrite.All` +
   `AppRoleAssignment.ReadWrite.All`). Because `az ad …` can hit a CAE loop, the scripts call Graph via
   **direct REST** with `az account get-access-token`.
2. Create/reuse app `a365-purview-audit-explorer` with the two **application** permissions, create its
   service principal, and **self-consent** (appRoleAssignedTo).
3. Mint a client secret and cache the credential **outside the repo** at
   `$HOME/.a365-purview-audit-explorer/cred.json` (never committed). Subsequent runs reuse it.
4. If `az` returns `InteractionRequired` / `TokenCreatedWithOutdatedPolicies`, run
   `az login --scope https://graph.microsoft.com/.default` (interactive **browser**) and retry.

All of this is encapsulated in `scripts/_common.ps1` (`Initialize-PurviewApp`).

## Scripts (all read-only, PowerShell 7)
Run from the repo root.

```pwsh
# 1) Discover which users/agents interacted (async audit query; tenant-wide)
pwsh -File .github/skills/purview-audit-explorer/scripts/Find-InteractionUsers.ps1 -SinceDays 7

# 2) List an agent's conversations from a user's interaction history
pwsh -File .github/skills/purview-audit-explorer/scripts/List-AgentConversations.ps1 `
     -UserUpn admin@<tenant>.onmicrosoft.com -SinceHours 168 [-AppClassLike '*lab12*'] [-AsJson]

# 3) Render the full ordered transcript of one conversation
pwsh -File .github/skills/purview-audit-explorer/scripts/Show-Conversation.ps1 `
     -UserUpn admin@<tenant>.onmicrosoft.com -SessionId <full-session-id> -SinceHours 168
```

- `_common.ps1` — dot-sourced helpers: `Initialize-PurviewApp` (bootstrap/reuse app + app-only token),
  `Resolve-UserId`, `Get-EnterpriseInteractions` (page + client-side time/appClass filter),
  `Format-AgentName`, `Invoke-Graph`, `Get-ODataNext`.
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
