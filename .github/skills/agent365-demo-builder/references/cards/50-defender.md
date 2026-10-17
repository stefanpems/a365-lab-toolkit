# Defender

Portal: https://security.microsoft.com, as a Security Administrator ({name:socAnalyst}, {upn:socAnalyst}, has the role
from Set-DemoIdentities.ps1). Do this card at least one day before the rehearsals: inventory, alerts and incidents take
hours to appear. The protection demos are referred to by code only (D14); their test inputs are operator
slots (demo-packs/{cfg:pack}/OPERATOR-SLOTS.md).

## 1. Security for AI agents

Follow **Enable security for AI agents using Microsoft Defender**
(https://learn.microsoft.com/defender-xdr/security-for-ai/get-started-defender-security-for-ai): connect the
**Microsoft 365** app connector (without it, blocked actions raise no alerts or incidents in the portal) and connect
**Copilot Studio**.

## D15. Prepare the data-security evidence

**Who**: {name:complianceOfficer} in Purview and Defender; {name:director} in Microsoft 365 Copilot.

1. After the DLP policy is active, verify that {agent:casesAssistant} answers for an ordinary application but cannot
   retrieve the labeled confidential application. Use DL-01 and DL-02 from the test hand-out.
2. In Microsoft Defender > Incidents, verify that the related DLP incident and its alerts are already visible.
   Allow for propagation; do not promise an immediate incident after the first test.
3. In Purview > DSPM > AI observability, prepare the risky {agent:circularsAssistant} entry. In Insider Risk Management,
   verify the agent policies, the related alert, and the interactions and accessed files available for investigation.
4. Keep this evidence in D15. Risk-based Conditional Access belongs to D9.
