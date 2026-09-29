# Defender

Portal: https://security.microsoft.com, as a Security Administrator ({name:socAnalyst}, {upn:socAnalyst}, has the role
from Set-DemoIdentities.ps1). Do this card at least one day before the rehearsals: inventory, alerts and incidents take
hours to appear. The protection demos are referred to by code only (D14, D16, D17); their test inputs are operator
slots (demo-packs/{cfg:pack}/OPERATOR-SLOTS.md).

## 1. Security for AI agents

Follow **Enable security for AI agents using Microsoft Defender**
(https://learn.microsoft.com/defender-xdr/security-for-ai/get-started-defender-security-for-ai): connect the
**Microsoft 365** app connector (without it, blocked actions raise no alerts or incidents in the portal) and connect
**Copilot Studio**.

## 2. Copilot Studio threat detection (D16)

Enable the external threat detection of Copilot Studio agents for the pay-as-you-go environment
({cfg:copilotStudio.paygEnvironmentId}), as described in
https://learn.microsoft.com/microsoft-copilot-studio/external-security-provider.

## 3. Real-time protection rule (D16)

Create the rule `{{governance.rtpRule}}` for the agent **{agent:recordsAssistant}** with the action **Block**, as
described in https://learn.microsoft.com/defender-xdr/security-for-ai/ai-agent-real-time-protection. Then run the
rehearsal test of D16 from the test hand-out (its prompt is an operator slot).

## 4. Saved hunting queries (D14, D17)

Save three advanced-hunting queries with these names, written from
https://learn.microsoft.com/defender-xdr/security-for-ai/ai-agent-detection-protection:

- `{{governance.huntingQueries.agentsLatestState}}`: latest state of every AI agent.
- `{{governance.huntingQueries.agentActivity24h}}`: activity of the AI agents in the last 24 hours.
- `{{governance.huntingQueries.promptInjectionAlerts}}`: alerts raised on AI agents.
