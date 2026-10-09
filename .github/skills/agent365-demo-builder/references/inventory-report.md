# Demo inventory contract (schema 1.0)

Run `Get-DemoInventory.ps1 -Prefix <prefix>` at hand-over and whenever the operator asks what was created,
configured, deployed or remains to be done. The phase runner exposes the same command with
`Invoke-DemoPhase.ps1 -Prefix <prefix> -Phase report`. Neither command provisions or changes cloud resources.
Reports always overwrite `generated/<prefix>/demo/inventory.html`, `inventory.md`, and `inventory.json`.
Use `-SnapshotOnly` explicitly when offline; never silently replace live verification with a snapshot.

## Fixed sections and columns

Every section remains present, including when empty. Order and columns are defined in `_demo-inventory.ps1`,
not invented by the chat agent. Markdown, HTML and JSON are rendered from the same data.

1. **Users:** Demo role (persona); User (name - UPN); Job title; Entra roles assigned; Other roles / notes; Evidence.
   Reuses `Get-DemoPersonas.ps1`, including its operator row and missing-role flags. The operator is not
   described as a user created by this run. Non-Entra roles are planned/manual unless explicitly verified.
2. **Groups:** Group; Type; Object ID; Members; Owners; Assigned permissions / roles; Purpose; Evidence.
   Live direct membership, owners, direct directory roles, application grants and subscription-visible Azure RBAC.
   Application role ids are preserved when a role name is not resolved. Nested membership and effective
   SharePoint/Azure access are not inferred from the purpose or group name.
3. **Entra configuration:** Type; Name; Evidence / status; ID / values; Description / assignments.
   Recorded security attributes, entitlement catalog, access packages in that catalog, agent owners/sponsors
   and public registration/blueprint identifiers. Manual policies without object evidence are not claimed as created.
4. **SharePoint resources:** Type; Name; URL; Permissions; Evidence.
   Site/library, folders and document metadata only. A recorded upload batch is not per-file read-back.
   Live library-root permissions do not prove effective access or absence of unique folder/item ACLs.
5. **Agents:** Name; Variant; Platform / framework / language; Authentication; Knowledge; Tools; Surface; Evidence; URL.
   Keep planned manual agents visible, labelled as such. DW deployment is not evidence of instance hiring.
   Framework/runtime values follow this toolkit's samples; service-managed agents are not labelled Python runtimes
   merely because the deployment client uses Python. Pack/plan tools, localized overlay tool definitions and
   overlay MCP labels are distinguished; source metadata is not proof of remote attachment.
6. **Custom MCP servers:** Name; Type; Endpoint; Tools; Registration / approval; Audience; Connections; Evidence / notes.
   Include deployed backends without gateway registrations. Recorded approval is not a current live registry read.
7. **Infrastructure and other assets:** Name; Type; Resource group / location; Region; Evidence; URL; Notes.
   Azure resources in lab-owned groups or with the lab tag, reused Foundry infrastructure, web UI, personal
   knowledge, Digital Worker instance requirements and generated preparation directories.
8. **User actions:** ID; Status; Action; Where / how; Needed by.
   Uses the existing register without changing ids or statuses.
9. **Verification gaps:** Resource; Gap.
   API errors are warnings and explicit report gaps, not empty-success fallbacks.

## Evidence and delivery

- Distinguish **Verified**, **Recorded**, **Planned**, **Not verified** and **Reused**. Existence is not proof
  of who created a resource, its health, publication, consent, successful tool invocation or complete readiness.
- Assert the lab tenant before live reads and use the existing lab-private Azure profile. Do not switch machine
  defaults. If authentication needs intervention, request an interactive browser sign-in; never device code.
- In chat, present all nine sections in the same order and with the same columns, translating labels and
  explanations to the operator's language if appropriate. Do not omit rows or collapse multiple resources into
  a claim of completeness. Link the HTML report. If the report exceeds one message, split it into consecutively
  numbered messages with unchanged tables.
- Persisted reports and labels are English; localized resource names remain their real names.
- Never expose passwords, tokens, raw generated configuration, secret directories, document bodies or operator
  inputs. Local content exclusions remove whole rows before all three renderers.
- HTML is self-contained, escaped, searchable, printable and theme-aware. No external scripts, network
  requests, storage of tokens or cloud-write controls.
