# Lab-name tags in Agent 365

Lab Builder and Demo Builder associate lab resources with the lab name (`solution.prefix`) in three
distinct places. These tags are not interchangeable.

| Store | Lab association | How it is applied |
|---|---|---|
| Azure resource groups | `a365lab=<prefix>` | Automatically by [Set-LabTags.ps1](../.github/skills/agent365-wizard/scripts/Set-LabTags.ps1) |
| Lab-owned Entra applications and service principals | `a365lab:<prefix>` in `tags` | Automatically by the same script |
| Agent 365 agent registry | Native organization tag named exactly `<prefix>` | Manual portal action, emitted by the shared lab workflow |

Existing Azure/Entra ownership tags remain authoritative for the Lab Cleaner. A native Agent 365 tag
is an organizational label, not an access grant or a replacement for those ownership tags.
Reused, user-owned infrastructure must not acquire this lab's ownership tags.

## API capability boundary

Checked against Microsoft Learn on **2026-10-18**: native tag creation and assignment are documented
as portal operations, but no supported tag-write API or PowerShell command is documented.
The documented [Update Copilot package API](https://learn.microsoft.com/en-us/microsoft-365-copilot/extensibility/api/admin-settings/package/copilotpackagedetail-update)
only accepts `allowedUsersAndGroups`, `acquireUsersAndGroups`, `availableTo` and `deployedTo`.
Do not send an invented `tags` PATCH, use package `categories`, or create an Entra agent collection as
a substitute. Do not automate an undocumented admin-center endpoint.

The shared [Get-Agent365TagAction.ps1](../.github/skills/agent365-wizard/scripts/Get-Agent365TagAction.ps1)
returns a pending, non-blocking manual action. It performs no authentication, cloud reads or writes.
The scaffolder includes it in the next steps; `Set-LabTags.ps1` prints it separately from the
Azure/Entra tagging summary. Neither output means that a native Agent 365 tag has been applied.
No new plan field is required: the native tag name is always `solution.prefix`, including custom-name
and multi-instance labs.

## After registration, and again on resume

1. In the external work-profile browser, open the [Microsoft 365 admin center](https://admin.microsoft.com/)
   and verify that its tenant matches the archived deployment plan. Follow the session's interactive
   sign-in and authentication-isolation rules; never switch a shared CLI context for this action.
2. Open **Agents > Settings > Tags**. Reuse the tag named exactly `<prefix>` if it exists; otherwise
   select **Add** and create it. The organization limit is **50 tags**. If it is reached, leave the
   action pending for administrator review; do not delete another tag automatically.
3. Open **Agents > All agents > Registry**. For every registered agent belonging to the lab, open
   its details and select **Add tag**, then select `<prefix>` while retaining its existing tags.
   Verify the package/agent identifier against deployment evidence where available; a display-name
   match alone is not sufficient when names are ambiguous. Include Copilot Studio agents and
   subsequently created agent instances. Never infer ownership from an arbitrary partial name.
4. An agent can have at most **five tags**. If it already has five and lacks the lab tag, leave the
   action pending for administrator review rather than evicting an existing tag. If the agent is not
   yet visible in the registry, keep its action pending and retry after registration/ingestion.
5. Reopen each agent's details and verify the native tag. Then filter the registry by `<prefix>`
   and reconcile the result against the lab's registered-agent inventory. Record the verified
   identifiers and any still-pending agents. Do not report success from Azure/Entra tag read-back.
6. Repeat this reconciliation after each new registration and on resume. Reuse the existing tag;
   do not create duplicates or replace unrelated tags.

## Demo Builder

[New-DemoLabPlan.ps1](../.github/skills/agent365-demo-builder/scripts/New-DemoLabPlan.ps1) registers the
same action under key `agent365-lab-tag` in the existing per-lab user-actions register, unless running
with `-ValidateOnly`. It starts as **TODO**, is non-blocking, and re-registration preserves its id and
an explicitly recorded completion. Demo Builder inherits the Lab Builder step rather than a separate
tagging implementation.

Complete the action only after portal verification. Include out-of-plan and interactive-created
agents when they actually exist. If another agent is added after completion, reopen the action with
[Set-DemoUserAction.ps1](../.github/skills/agent365-demo-builder/scripts/Set-DemoUserAction.ps1):

```powershell
pwsh -File .\.github\skills\agent365-demo-builder\scripts\Set-DemoUserAction.ps1 -Prefix <prefix> -Key agent365-lab-tag -Status TODO
```

## Official references

- [Tag an agent](https://learn.microsoft.com/en-us/microsoft-365/admin/manage/agent-details?view=o365-worldwide#tag-an-agent)
- [Manage organization tags](https://learn.microsoft.com/en-us/microsoft-365/admin/manage/agent-settings?view=o365-worldwide#manage-tags)
- [Agent 365 registry Graph APIs](https://learn.microsoft.com/en-us/microsoft-agent-365/admin/graph-api)
