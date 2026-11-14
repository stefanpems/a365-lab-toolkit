# Demo Cleaner catalog

Everything a Demo Builder lab can leave in a tenant, in deletion order, with the way it is deleted and what it means
for a later build in the same tenant, subscription and language. `Get-DemoCleanupPlan.ps1` turns this catalog into
the numbered plan of one run; the report shows the same order.

Legend of the **How** column: *Lab Cleaner* = an item executed by
[Remove-CleanupResources.ps1](../../agent365-cleanup/scripts/Remove-CleanupResources.ps1) (unchanged, one element per
call); *Graph*, *registry*, *Dataverse*, *Power Platform*, *ARM*, *Foundry* = a direct API call of
[Invoke-DemoCleanup.ps1](../scripts/Invoke-DemoCleanup.ps1); *SCC* / *EXO* = Security & Compliance or Exchange Online
PowerShell (module `ExchangeOnlineManagement`, otherwise the element becomes a manual action); *manual* = a portal
action guided in chat, confirmed by the operator and verified through an API when one exists.

## Hard deletion

Nothing must stay recoverable. Every step that soft-deletes is followed by its purge:

| Recycle bin | Purge |
|---|---|
| Entra deleted users, groups, applications, service principals | `DELETE /directory/deletedItems/{id}` after every deletion, verified on both `/directoryObjects` and `/deletedItems`; a final sweep purges what the platforms delete themselves (Copilot Studio and Foundry identities, and the deleted applications and service principals named `<prefix>-…`: the managed identities that Azure deletes with the resource groups) |
| Cognitive Services (Azure OpenAI, Foundry) | Lab Cleaner `purge-cognitiveservices` before the resource group; an account that is still live afterwards (a Foundry account with projects cannot be deleted on its own) is verified with `az cognitiveservices account show`, left *deletion still in progress* and purged after the resource-group wait |
| Log Analytics workspaces (14 days, recovered by a same-name workspace) | Lab Cleaner `purge-loganalytics` (`--force true`) before the resource group |
| Agent registry (Deleted view, 30 days) | Code agents: `DELETE /beta/copilot/agentRegistrations/{id}` (the Lab Builder's `agentRegistrationId`, permanent); others: admin center Delete agent, then Deleted > **Permanently delete** (no API) |
| SharePoint deleted sites (93 days) and retained OneDrive | SharePoint admin REST endpoint (undocumented, best effort), else `Remove-SPOSite` / `Remove-SPODeletedSite` as a guided manual step (a group site cannot be purged from the admin center UI) |
| Exchange soft-deleted mailboxes (30 days) | `Remove-Mailbox -PermanentlyDelete`; a mailbox on hold is inactive until the hold is removed |
| Copilot Studio agents | Dataverse bound action `PvaDeleteBot`, then the solution container: permanent; a Dataverse recycle bin, when enabled in the environment, is out of scope |

Objects that no platform can delete are **neutralized** and reported as *Could not delete - platform limitation*:
the `ext_` MCP servers (Blocked or Rejected; names reserved forever) and their platform-managed tool connectors
(`shared_tc-ext-…`, when the Power Apps admin API refuses them too), custom security attribute definitions and values
(deactivated), attribute sets (kept), Defender incidents and alerts (resolved), audit records (kept by design).

## Order

| Order | Element | Type | How | Notes |
|---|---|---|---|---|
| 1010 | Custom automation rules (`governance.rules.*`) | Configuration | manual | Admin center > Agents > Settings > Rules; created live |
| 1011 | Built-in ownerless-agent rule | Configuration | manual, kept by default | Turn it off only if it was turned on for the lab |
| 1020 | Policy templates (`governance.templates.*`) and templates created live | Configuration | manual | Before the Conditional Access policies, the access package and the attribute they reference |
| 1030 | Organization tags (`governance.tags.*`) and the native lab-name tag `<prefix>` | Configuration | manual | Agents > Settings > Tags |
| 1510 | Demo MCP servers `ext_*` (long-lived and pool) | Component | registry API Block (admin-center Block when the API refuses it), manual Reject; `Done` verified through the registry | Limitation: never deleted; names recorded in `generated/cleanup/tenant-<tenant>/reserved-ext-mcp-names.json` |
| 2010 | eDiscovery case | Resource | Graph | Holds deleted, case closed, then deleted (before the users: holds would make their mailboxes inactive) |
| 2020-2070 | Communication Compliance, DSPM one-click policies, DLP policy, label publishing policy, sensitivity label, audit retention policy | Configuration | SCC (DSPM manual) | Label after its publishing policy and the DLP policy |
| 2080 | Saved audit searches | Resource | manual | Purview > Audit > Search |
| 2090-2095 | Saved hunting queries, legacy real-time protection rule (kept by default) | Configuration | manual | Defender |
| 2100 | Defender incidents and alerts | Resource | manual | Limitation: resolved, not deleted |
| 2110 | Defender connectors for AI agents | Configuration | manual, kept by default | Tenant-wide security setting |
| 3010 | Conditional Access policies | Configuration | Graph | No recycle bin |
| 3020 | Access packages of the lab catalog | Configuration | Graph | Pending requests cancelled, assignments removed, policies deleted, then the package |
| 3030 | Entitlement catalog | Configuration | Graph | Resources removed first |
| 4010-4012 | Agent Builder agents, their custom skill, registry agents owned by a persona (additions) | Agent | manual + registry verification | Reject a pending request, Delete agent, Deleted > Permanently delete |
| 4030-4031 | Agents on third-party platforms (declared, or unclaimed candidates kept by default) | Agent | manual (AWS AI Manager, Google AI Manager) | Delete at the source, then the registry entry |
| 4035 | Connected-platform connections | Configuration | manual, kept by default | Agents > Connected platforms; source credentials too |
| 4040-4042 | Copilot Studio agents and prefix-derived solutions, agents owned by a persona (additions) | Agent | Dataverse (`Remove-McsAgent.ps1 -UseDataverseApi`: bound action `PvaDeleteBot`, then the solution) | No pac profile switch |
| 4045 | Copilot Studio agent identities left behind | Agent | Lab Cleaner (only if still present) | |
| 4060-4065 | Foundry prompt agent and custom content filter, only on a reused (not lab-owned) Foundry project | Agent / Configuration | Foundry / ARM | A lab-owned project goes with its resource group |
| 4515 | Power Platform connections of the personas and of the MCP connectors | Component | Power Platform admin API | Orphaned otherwise |
| 4520-4540 | MCP connectors, backing Entra apps, recycle-bin leftovers | Component | Lab Cleaner; Power Apps admin API for a platform-managed `shared_tc-` connector the maker API refuses | After the server is Blocked/Rejected; a refused tool connector is a limitation |
| 5050-5400 | Web UI tabs, agent instances (licenses first), blueprints and identities, Static Web App, Cognitive Services and Log Analytics purges, resource groups | Agent / Component | Lab Cleaner discovery and removal | Objects tagged by another lab, or matched by name only, are kept by default |
| 6010-6030 | Persona users (licenses removed, deleted, purged), users tagged with the lab, leavers left in the recycle bin | User | Lab Cleaner `remove-licenses-and-delete-user` | A persona tagged by another lab is kept by default |
| 6210-6230 | Demo groups, groups owned by a persona (additions), recycle-bin leftovers | Group | Graph | Microsoft 365 group purged; its site and mailbox go with it |
| 6211 | SharePoint knowledge site | Resource | with its group | |
| 7010-7030 | Custom security attribute values, definition, attribute set | Configuration | Graph | Limitation: deactivated (set kept) |
| 7040 | Operator directory roles added by the build | Configuration | Graph, kept by default | The build does not record whether they existed before |
| 7050-7060 | Default-environment authentication setting (legacy prototype), pay-as-you-go environment (kept by default) | Configuration | manual | |
| - | Azure resource-group deletions | - | awaited | Up to 60 minutes (`-RgTimeoutMinutes`) |
| 8010 | Foundry project identities left behind | Component | Lab Cleaner (only if still present) | |
| 8030 | Registry entries of the code and Copilot Studio agents | Agent | registry verification; agent registration DELETE for the code agents; manual if still listed | An entry whose detail answers 424 and that is no longer listed counts as gone |
| 8040 | Entra recycle bin sweep | Component | Graph | Every known lab object id, plus the deleted applications and service principals named `<prefix>-…` |
| 8050 | Soft-deleted mailboxes of the personas and agent users | Resource | EXO | |
| 8060-8070 | SharePoint deleted site, OneDrive of the personas | Resource | SharePoint admin REST (best effort), else manual | |
| 9010 | Local folder `generated/<prefix>/` (+ its Copilot Studio files) | Resource | `Remove-GeneratedFolders.ps1` | Last, only when nothing is left to retry; the audit folder `generated/cleanup/` stays |

## Manual rollback of what the runbook creates by hand

The cards, the user-actions register and the run of show ask the operator and the personas to create objects in the
portals. Each one is an element of the plan (*Manual rollback guide* section of the report, also in chat):

| Runbook step | What it creates | Rollback |
|---|---|---|
| Card 10 (Copilot Studio) | Completed agents, org-catalog publication and requests | Agents deleted through the API; registry entries verified (8030) |
| Card 11 (Agent Builder) | Agents of the personas, a custom skill, share links, org-catalog submissions | Admin center: Reject the request, Delete agent, Permanently delete (4010-4012) |
| Card 15 (Foundry) | Checks and publication of the prompt agent | With the lab-owned project, or 4060-4065 on a reused one |
| Card 20 (Digital Worker) | Template licenses, the prepared and the live instances | Instances found through their blueprint (licenses first); the template goes with the blueprint |
| Card 30 (Entra) | Two Conditional Access policies, the access package with its API permission | 3010-3030 |
| Card 40 (Purview) | Role groups, DSPM policies, audit retention, saved searches, label, DLP, Communication Compliance, eDiscovery case | 2010-2080; role-group membership goes with the users |
| Card 50 (Defender) | Connectors, hunting queries, incident evidence | 2090-2110 |
| Card 60 (admin center) | Templates, tags, approvals, installs, blocks, automation rules | 1010-1030; approvals and installs go with the agents |
| User actions `mcp-approve`, `mcp-connections` | Approved `ext_` servers, per-user connections | 1510, 4515 |
| User action `knowledge-personal-*` | The program lead's OneDrive file | With the OneDrive (8070) |
| User action `agent365-lab-tag` | The native tag `<prefix>` | 1031 |
| Third-party platforms (registry sync) | Agents on AWS, Google or other platforms, the connection | Declare them with `-ThirdPartyAgents`; 4030-4035 |
| Anything else added by hand | Extra agents, apps, users, groups | Objects owned or managed by a persona and users tagged with the lab are found automatically; name others with `-OtherAdditions` |

## Rebuilding in the same tenant, subscription and language

The localized names do not depend on the lab prefix: personas (`alias@domain`), groups and site, agent display names,
blueprints and `<code name>-rg` resource groups, MCP servers, governance objects. The report ends with the conflicts
that the run leaves, computed from the statuses:

| Topic | Expected problem | Solution |
|---|---|---|
| `ext_` MCP servers | Reserved forever; tool names must never be active twice | Reserved names are refused by `New-DemoMcpRegistration.ps1` (tenant memory); a long-lived server whose old servers the run verified as neutralized is registered as `<name><n>` automatically, otherwise `-ServerName`; Block/Reject every old server first |
| Lab name (prefix) | The stale `generated/<prefix>/` state would be resumed | Retired once the deletion started: `New-DemoConfig.ps1` and the build phases of `Invoke-DemoPhase.ps1` refuse it; build under another name |
| Custom security attribute | Same set and attribute, deactivated | `Set-DemoGovernance.ps1` reactivates the definition and its values |
| Registry entries (also the Deleted view) | Exact-name resolution of the Demo Builder becomes ambiguous | Permanently delete them |
| Users and groups not purged | UPN / mail nickname conflicts | Purge them |
| Soft-deleted mailboxes | Proxy-address conflict for the new persona mailbox | `Remove-Mailbox -PermanentlyDelete`, or wait 30 days |
| SharePoint deleted site, retained OneDrive | New site gets another URL | `Remove-SPODeletedSite`; the URL can take 24 hours |
| Resource groups still deleting | Same `<code name>-rg` names | Wait for `az group exists` to be false |
| Purview, admin-center and entitlement objects left | Unique names, catalog reused by name | Delete them; a deleted label name can stay reserved for a while |
| By design | Audit records, incidents, alerts, disabled Dataverse users remain | Resolve incidents and alerts, filter evidence by date |
| A second lab with the same language in the tenant | Shared personas and groups (same names) | Objects tagged by the other lab are kept by default |
