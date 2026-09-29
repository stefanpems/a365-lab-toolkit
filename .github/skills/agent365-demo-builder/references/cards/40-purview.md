# Purview

Portal: https://purview.microsoft.com, as a Global Administrator (or Compliance Administrator). Lead times: DSPM needs
about one day before data shows; a new sensitivity label takes 30-60 minutes to appear in the pickers and up to 24 hours
to reach the apps; the DLP policy must be active at least {pack:governance.purview.dlp.activeHoursBefore} hours before
the run. Name each recommendation by what it does: the portal labels change often.

## 1. Roles of {name:complianceOfficer}

Purview > Roles and scopes > Role groups: add {upn:complianceOfficer} to **eDiscovery Manager**, **Communication
Compliance Investigators**, **Insider Risk Management Analysts** and **Content Explorer Content Viewer**.

## 2. DSPM and the one-click policies (D15)

1. Solutions > **DSPM** (the new one, not the "classic" entries) > accept the first-time setup tasks.
2. DSPM > Tasks and actions > Remediation actions: create **Detect risky interactions in AI apps** (Insider Risk
   Management) and **Detect unethical behavior in AI apps** (communication insights).

## 3. Audit (D12)

1. Solutions > Audit: if a "Start recording user and admin activity" banner shows, turn recording on.
2. Audit > Audit retention policies > New: name `{{governance.auditRetentionPolicy}}`, record types
   **CopilotInteraction** and the **AI\*** types offered by the picker, duration **1 year**, priority 1.
3. At T-1, save two audit searches: `{{governance.auditSearches.agentInteractions}}` (interactions with
   {agent:grantsDesk}) and `{{governance.auditSearches.agentAdminActions}}` (admin actions on agents).

## 4. Sensitivity label and DLP (D12, D15)

1. Information protection > Labels > Create: name `{{governance.sensitivityLabel.name}}`, tooltip
   `{{governance.sensitivityLabel.tooltip}}`, scope **Files & other data assets** + **Email**, no protection and no
   marking. Publish it with a new label policy to all users.
2. When the label shows in the picker: DSPM recommendation **Protect items from Microsoft 365 Copilot and agent
   processing** > check ONLY "Restrict Copilot from accessing knowledge sources with sensitivity labels" = the label
   (leave the external-e-mail option unchecked: not part of the story). Name it `{{governance.dlpPolicy}}` if asked.
3. Apply the label to **{{knowledge.documents.confidentialCase.file}}** (folder {folder:cases}) in Word for the web >
   Sensitivity; otherwise the DLP rule has nothing to act on.

## 5. Communication Compliance (D12)

Communication Compliance > Policies > Create a custom policy: name `{{governance.communicationCompliancePolicy}}`;
users {name:caseOfficer}, {name:maker} and the Digital Worker instance `{{agents.recordsColleague.instance.alias}}`;
locations: the Microsoft 365 Copilot and AI app interactions; condition: the message contains any of
`{{governance.communicationComplianceKeywords}}`; reviewer {name:complianceOfficer}.

## 6. eDiscovery (D13)

eDiscovery > Cases > Create: `{{governance.ediscoveryCase}}`; data sources {name:caseOfficer} and the Digital Worker
instance mailbox `{{agents.recordsColleague.instance.alias}}`; add {name:complianceOfficer} as a case member.
