# Copilot Studio agents

Portal: https://copilotstudio.microsoft.com, in the environment named by each agent below. The Lab Builder creates the
agents from the base solutions (agent365-copilot-studio skill); this card completes them by hand, as their owner.

## Rules (lessons of the reference lab)

- **New-harness agents (MCS-NH)** have no description field on the Build page and accept no BYO MCP server; their base
  solution enables the "Search all websites" knowledge and ships English instructions: remove that knowledge and
  paste the instructions below.
- **Preview** validates the configuration but creates no usage: after publishing, send one test prompt in Teams or
  Microsoft 365 Copilot as the owner (first real session, needed by the admin-center usage and map).
- **Install / pin by IT** needs the organization catalog: the owner publishes the agent to the organization ("available
  to everyone in my org"), the admin approves it in the Microsoft 365 admin center > Agents > Requests, then scopes the
  PUBLISHED entry (Available to + Installed for). The install-scope API is silently ignored: always use the admin center.
- **Policy template at approval**: the "Publish to store" wizard asks for one; use the default template until the custom
  template "{{governance.templates.productionTemplate}}" exists (admin-center card).
- The registry can show two entries per agent (shared + published version): expected.
- The owner column of new-harness agents refreshes only when the agent is republished.
- **Web search off** on every demo agent unless a demo needs it (Settings > Generative AI, and remove the "Search all
  websites" knowledge): otherwise real-world data shows up in the recordings. Only fictional data on screen.
- **Default environment**: a Global Administrator is NOT automatically System Administrator there. Power Platform admin
  center > Environments > the default environment > Membership > **Add me** before building an agent in it (symptoms:
  "Try that again" on the authentication settings, knowledge upload errors).
- **An agent without authentication**: FIRST remove the Microsoft channels (Teams and Microsoft 365 Copilot), THEN
  choose "No authentication": while a Microsoft channel is on, the option stays greyed and the tooltip does not say
  why. If it is still greyed, the environment setting Power Platform admin center > Security > Identity and access >
  Authentication for agents must allow it: change it only for the demo and restore it after the event.
- Verify the current configuration first (read-only) and give UI paths as "where the control is": portal menus move.

## Agents

<!-- AGENTS:copilotStudio -->
