#requires -Version 5.1

function Get-Agent365TagAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9]{2,11}$')][string]$Prefix,
        [string]$TenantId
    )

    $tenant = if ([string]::IsNullOrWhiteSpace($TenantId)) {
        'confirm the target tenant from the archived lab plan before making changes'
    } else {
        "confirm tenant $TenantId before making changes"
    }

    [ordered]@{
        Key = 'agent365-lab-tag'
        Action = "Create or reuse the native Agent 365 tag '$Prefix' and add it to every registered agent belonging to this lab, including Copilot Studio and later-created agents. Preserve existing tags. No documented tag-write API is available; this is a manual action, NOT an applied tag."
        Where = "https://admin.microsoft.com/ ($tenant): Agents > Settings > Tags > Add only if '$Prefix' is absent (maximum 50 organization tags). Then Agents > All agents > Registry > select the verified lab agent > Add tag > select '$Prefix' alongside its existing tags (maximum five per agent). Do not remove other tags to make room. Reopen the agent details and filter the Registry by '$Prefix' to verify; keep this action pending until verified."
        NeededBy = 'Lab inventory and hand-over; reconcile after each agent registration and on resume'
        Blocking = $false
    }
}
