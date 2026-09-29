# Entra: Conditional Access for agents and the access package

Portal: https://entra.microsoft.com. Scripted before this card (Set-DemoGovernance.ps1): the attribute
{{governance.attributeSet.id}} / {{governance.attribute.name}} with its values, the owners, sponsors and attribute
values of the agent identities, and the catalog "{{governance.catalog.name}}" with the group {group:directoryReaders}.
Security defaults must be disabled.

**Who**: {name:identityAdmin} ({upn:identityAdmin}), the story owner of the Entra policies. Custom security attributes
are visible only to holders of the attribute roles (a Global Administrator does not see them by default), and
{name:identityAdmin} has Conditional Access Administrator + Attribute Definition/Assignment Administrator + Identity
Governance Administrator. Only step 3.3 needs a Global Administrator.

## 1. Policy "{{governance.conditionalAccess.blockHighRiskAgents}}" (D9, D17)

Entra ID > Conditional Access > Policies > New policy:

1. Name: `{{governance.conditionalAccess.blockHighRiskAgents}}`
2. Assignments > Users, agents (Preview) or workload identities > What does this policy apply to? **Agents (Preview)**
   > Include **All agent identities (Preview)**.
3. Target resources > Resources > Include **All resources**.
4. Conditions > **Agent risk (Preview)** > Configure **Yes** > **High**.
5. Access controls > Grant > **Block**.
6. Enable policy **Report-only** > Create. Check its report-only results, then switch it **On** before the rehearsals:
   this policy is ON during the demo.

## 2. Policy "{{governance.conditionalAccess.onlyApprovedAgents}}" (D11)

1. Name: `{{governance.conditionalAccess.onlyApprovedAgents}}`
2. Assignments > Users, agents or workload identities > **Agents** > Include **All agent identities** > Exclude >
   **Select agent identities based on attributes** > Configure **Yes** > attribute **{{governance.attribute.name}}**
   (set {{governance.attributeSet.id}}) > Operator **Equals** > Value **{{governance.attribute.values.approved}}** > Done.
3. Target resources > Include **All resources**.
4. Access controls > Grant > **Block**.
5. Enable policy **Report-only** > Create. It stays **Report-only**: the demo shows what it WOULD block.

## 3. Access package "{{governance.accessPackage.name}}" (D10)

ID Governance > Entitlement management > Access packages > New access package:

1. Basics: name `{{governance.accessPackage.name}}`, description `{{governance.accessPackage.description}}`, catalog
   **{{governance.catalog.name}}**. Resource roles: the group **{group:directoryReaders}** (Member).
2. Requests: Who can get access **For users, service principals, and agent identities in your directory** > Select
   specific scope **All agents**. Approval: **1** stage, approver **{name:identityAdmin}**. Lifecycle: assignments
   expire after **{pack:governance.entitlement.durationHours} hours**. Review + create.
3. Then a **Global Administrator** adds the API permission as a resource role of the package (it is NOT a catalog
   resource): the access package > Resource roles > **API Permissions** > Microsoft Graph > Application >
   **User.Read.All** > Update permissions. The catalog becomes "privileged" (expected). API permissions can be added
   only because the policy is scoped to agents (users cannot receive them).

In the demo, the sponsor {name:director} requests it at https://myaccess.microsoft.com > Access packages > Request >
**Requesting for Sponsored agent** > {agent:reportsMonitor}, justification `{{governance.accessPackage.justification}}`;
{name:identityAdmin} approves it.
