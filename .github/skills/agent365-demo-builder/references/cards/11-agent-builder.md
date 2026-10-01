# Agent Builder agents

Each agent is created by the person named below, signed in as themselves at https://m365.cloud.microsoft (Microsoft 365
Copilot > Create agent). The knowledge files are published by Publish-DemoKnowledge.ps1 (personal files: the creator
uploads them to their own OneDrive first).

## Rules

- Create the agents of **leavers** well before their accounts are deleted (at least one day before the rehearsals: the
  admin-center card of ownerless agents lags). The interactive phase then runs `New-OrphanAgent.ps1` for each of them.
- **Sharing is not availability.** A shared agent is not listed in the recipients' agent picker or store: each
  recipient opens the share link once, signed in as themselves (`https://m365.cloud.microsoft/chat/?titleId=<package
  id>`, printed by the pre-flight), before the creator leaves and again after every orphan recreation.
- Test each agent once in Microsoft 365 Copilot right after creating it (first usage for the admin center).
- **Give new people time.** A user created minutes ago is not yet seen by the SharePoint permission trimming that grounds
  Copilot: create temporary creators hours ahead when their own test must answer from SharePoint knowledge. A newly
  shared agent can also refuse access to its recipients for about ten minutes: wait, do not change permissions.
- **Submitting to the organization catalog is not sharing.** An agent that must reach the admin center as a request is
  submitted, not shared: left pane, "…" next to the agent's name > Edit > the "…" of the editor header > **Submit to your
  org catalog** (enabled after the first publication). Fields: display name (max 30), short description (max 80),
  developer name (max 32), website, privacy and terms URLs (HTTPS: the demo SharePoint site). Turn **off** "Org-wide
  sharing for chat access" for that agent: the draft must not be usable before the decision. Fallback when the entry is
  missing in the current UI: create the draft in Copilot Studio (pay-as-you-go environment) and submit it from there.
- The admin approves or rejects the request live; after a rehearsal the creator submits again (a new request).

## Agents

<!-- AGENTS:agentBuilder -->
