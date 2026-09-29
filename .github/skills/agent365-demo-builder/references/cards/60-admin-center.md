# Microsoft 365 admin center: templates, approvals, installs, blocks

Portal: https://admin.microsoft.com > Agents. **Who**: {name:aiAdmin} ({upn:aiAdmin}), the story persona of every
admin-center governance action. Actions that a demo later SHOWS (approvals, blocks, their audit trail in D12) are done
by {name:aiAdmin} in the portal, never by script: scripts only verify by read-back. A preparation step that is itself
a demo moment (for example the D8 reassignment rule) is done live, on camera, not during the build.

## 1. Policy templates (D4, D7)

Prerequisites: the Entra policies of the Entra card exist; for custom security attribute policies both the Global
Administrator and {name:aiAdmin} need the **Attribute Assignment Administrator** role (a Global Administrator can
consent to assign it in the wizard). The AI Administrator can use access packages but not Conditional Access or
attributes: if a policy cannot be added, a Global Administrator completes the template.

Agents > Settings > Templates > **Add a new template**:

1. Name `{{governance.templates.productionTemplate}}` (the name carries the type, as the wizard shows it); type
   **Agents without their own identity**: every agent except the AI teammates (Copilot Studio, Agent Builder and code
   agents). It is the type that takes the Entra custom policies and the one offered when an agent request is approved
   (D4). "Agents with their own identity" means AI teammates (agent users): they take no custom policies yet.
2. Custom policies: the Conditional Access policy **{{governance.conditionalAccess.onlyApprovedAgents}}**, the access
   package **{{governance.accessPackage.name}}** and the attribute **{{governance.attribute.name}} =
   {{governance.attribute.values.approved}}**. A Conditional Access policy scoped to ALL agent identities is selected
   automatically and cannot be removed; only policies that include agent identities are offered.
3. Save template. A template applies to NEW activations only (agents approved before keep their policies).

AI teammate template `{{governance.templates.aiTeammateTemplate}}` (Frontier preview; custom policies are not
supported yet): the licenses of the Digital Worker instances (Digital Worker card) for
{agent:recordsColleague}.

Until the custom template exists, approvals use the **default template**. To verify during the preparation of D4:
open the approval wizard of {agent:siteInspections} up to the template step, without publishing.

Custom templates of earlier labs in the same tenant are visible in D7 (and may show personal names): remove or rename
them before D7, unless another lab still needs them.

## 2. Tags

Tags are registry metadata only (no effect on access, policies or runtime; no demo changes them). Agents > Settings >
**Tags**: create `{{governance.tags.department}}` ({{governance.tagDescriptions.department}}),
`{{governance.tags.production}}` ({{governance.tagDescriptions.production}}) and `{{governance.tags.pilot}}`
({{governance.tagDescriptions.pilot}}); tag names are short (keep them within 15 characters), max 50 per organization,
max 5 per agent. Apply them with the bulk **Tag agents** action (both entries of an agent that has a published copy):

- `{{governance.tags.department}}`: every catalog entry of the lab ({tagged:department});
- `{{governance.tags.production}}`: {tagged:production};
- `{{governance.tags.pilot}}`: {tagged:pilot}.

There is no tag filter in the list yet: in the demo show the **Tags** column (or search).

## 3. Approvals and installs (starting state)

- {agent:grantsDesk}: approve the organization-catalog request (default template), then on the PUBLISHED entry set
  Available to + **Installed for** the group {group:department}. The install-scope API is silently ignored.
- {agent:grantsDeskPilot}: approve and install it for {name:caseOfficer} only.
- {agent:siteInspections} and "{agent:personalContacts}": leave their requests **pending** (decided live in D4).

## 4. Blocks (the day before the run)

Agents > {agent:grantsDeskPilot} (published entry) > Block: reason **Not approved for use**; tick **Block agent**
before Confirm (the "Explain in more detail" box stays disabled). Blocking disables the agent's Entra identity (by
design) and removes existing installations: after any rehearsal that blocks an installed agent, re-install it when it
is unblocked (agent365-demo-reset lists it).
