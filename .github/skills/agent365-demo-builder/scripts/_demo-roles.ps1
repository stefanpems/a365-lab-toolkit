# Shared persona directory-role resolution, assignment and read-back. No calls are made when dot-sourced.
# Built-in role names stay English in the pack; template IDs, not display names, identify these definitions.
$script:DemoEntraRoleTemplateIds = [ordered]@{
    'Global Secure Access Administrator' = 'ac434307-12b9-4fa1-a708-88bf58caabc1'
    'Identity Governance Administrator' = '45d8d3c5-c802-45c6-b32a-1d70b5e1e86e'
    'Lifecycle Workflows Administrator' = '59d46f88-662b-457b-bceb-5c3809e5908f'
}

function Get-DemoEntraRoleDefinitions {
    @(Invoke-DemoGraph GET 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?$select=id,displayName,templateId,isBuiltIn' -All)
}

function Resolve-DemoEntraRoleDefinition([string]$Name, [object[]]$Definitions) {
    $matches = if ($script:DemoEntraRoleTemplateIds.Contains($Name)) {
        @($Definitions | Where-Object { $_.isBuiltIn -eq $true -and $_.templateId -eq $script:DemoEntraRoleTemplateIds[$Name] })
    }
    else {
        # Preserve the existing exact-name convention for the other pack roles.
        @($Definitions | Where-Object { $_.displayName -ceq $Name })
    }
    if ($matches.Count -ne 1) { throw "Directory role '$Name' has $($matches.Count) exact definitions; expected one$(if ($script:DemoEntraRoleTemplateIds.Contains($Name)) { " built-in template $($script:DemoEntraRoleTemplateIds[$Name])" })." }
    return $matches[0]
}

function Get-DemoEntraRoleName($Definition) {
    foreach ($name in $script:DemoEntraRoleTemplateIds.Keys) {
        if ($Definition.isBuiltIn -eq $true -and $Definition.templateId -eq $script:DemoEntraRoleTemplateIds[$name]) { return $name }
    }
    return [string]$Definition.displayName
}

function Get-DemoPermanentEntraRoleAssignments([string]$UserId) {
    if (-not $UserId) { throw 'A persona user ID is required for directory-role read-back.' }
    $base = 'https://graph.microsoft.com/v1.0/roleManagement/directory'
    $filter = "principalId eq '$($UserId.Replace("'", "''"))'"
    $active = @(Invoke-DemoGraph GET "$base/roleAssignments?`$filter=$filter&`$select=id,principalId,roleDefinitionId,directoryScopeId,appScopeId" -All)
    # roleAssignments alone also contains active time-bound assignments. Require a matching permanent,
    # directly assigned schedule instance; eligibility, PIM activation and scoped assignments are not equivalent.
    # A denied schedule read must fail, never silently assume permanence.
    $instances = @(Invoke-DemoGraph GET "$base/roleAssignmentScheduleInstances?`$filter=$filter&`$select=principalId,roleDefinitionId,directoryScopeId,appScopeId,assignmentType,memberType,roleAssignmentOriginId,startDateTime,endDateTime" -All)
    $now = [datetimeoffset]::UtcNow
    foreach ($assignment in $active) {
        if (-not $assignment.id -or $assignment.principalId -ne $UserId -or $assignment.directoryScopeId -ne '/' -or $assignment.appScopeId) { continue }
        foreach ($instance in $instances) {
            $hasEnd = if ($instance -is [Collections.IDictionary]) { $instance.Contains('endDateTime') } else { $null -ne $instance.PSObject.Properties['endDateTime'] }
            $start = [datetimeoffset]::MinValue
            if ($instance.principalId -eq $UserId -and $instance.roleDefinitionId -eq $assignment.roleDefinitionId -and
                $instance.roleAssignmentOriginId -eq $assignment.id -and $instance.directoryScopeId -eq '/' -and
                -not $instance.appScopeId -and $instance.assignmentType -eq 'Assigned' -and $instance.memberType -eq 'Direct' -and
                $hasEnd -and $null -eq $instance.endDateTime -and
                [datetimeoffset]::TryParse([string]$instance.startDateTime, [ref]$start) -and $start -le $now) {
                $assignment
                break
            }
        }
    }
}

function Get-DemoPersonaEntraRoleStatus($Persona, [object[]]$Definitions, [object[]]$Assignments) {
    foreach ($name in @($Persona.entraRoles | Where-Object { $_ } | Select-Object -Unique)) {
        $definition = $null; $detail = ''
        try { $definition = Resolve-DemoEntraRoleDefinition $name $Definitions } catch { $detail = $_.Exception.Message }
        $held = @($Assignments | Where-Object { $definition -and $_.roleDefinitionId -eq $definition.id }) | Select-Object -First 1
        [pscustomobject]@{
            roleName = [string]$name
            roleTemplateId = $(if ($definition) { [string]$definition.templateId } else { [string]$script:DemoEntraRoleTemplateIds[$name] })
            roleDefinitionId = $(if ($definition) { [string]$definition.id } else { '' })
            assignmentId = $(if ($held) { [string]$held.id } else { '' })
            verified = [bool]$held
            detail = $detail
        }
    }
}

function Set-DemoPersonaEntraRoles {
    param([string]$Prefix, $Persona, [string]$UserId, [object[]]$Definitions, $State, [switch]$WhatIf)
    $assignments = @(Get-DemoPermanentEntraRoleAssignments $UserId)
    foreach ($name in @($Persona.entraRoles | Where-Object { $_ } | Select-Object -Unique)) {
        $definition = Resolve-DemoEntraRoleDefinition $name $Definitions
        $held = @($assignments | Where-Object { $_.roleDefinitionId -eq $definition.id }) | Select-Object -First 1
        $created = $false
        if (-not $held) {
            if ($WhatIf) { "would ASSIGN $($Persona.key) = $name (active, permanent, directory scope /)"; continue }
            # A direct unifiedRoleAssignment is active and permanent, not an eligible or scheduled activation.
            $result = Invoke-DemoGraph POST 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments' `
                -Body @{ principalId = $UserId; roleDefinitionId = $definition.id; directoryScopeId = '/' } -NoThrow
            $writeError = $result -and $result.PSObject.Properties['error']
            if ($writeError -and $result.status -ne 409) { throw "Role assignment failed for '$($Persona.key)' / '$name' ($($result.status)): $($result.error)" }
            for ($attempt = 0; $attempt -lt 6; $attempt++) {
                $assignments = @(Get-DemoPermanentEntraRoleAssignments $UserId)
                $held = @($assignments | Where-Object { $_.roleDefinitionId -eq $definition.id }) | Select-Object -First 1
                if ($held) { break }
                if ($attempt -lt 5) { Start-Sleep -Seconds 2 }
            }
            if (-not $held) {
                if ($writeError) { throw "Role assignment failed for '$($Persona.key)' / '$name' ($($result.status)): $($result.error); no equivalent active permanent root-scope assignment was verified." }
                throw "Role '$name' for '$($Persona.key)' was assigned but not verified by read-back as active, permanent, directory scope /."
            }
            $created = $true
        }
        if (-not $WhatIf) {
            if (-not $State.users.Contains($Persona.key)) { $State.users[$Persona.key] = [ordered]@{ id = $UserId } }
            if (-not $State.users[$Persona.key].roleAssignments) { $State.users[$Persona.key]['roleAssignments'] = [ordered]@{} }
            $State.users[$Persona.key].roleAssignments[$name] = [ordered]@{
                assignmentId = [string]$held.id; principalId = $UserId; roleDefinitionId = [string]$definition.id
                roleTemplateId = [string]$definition.templateId; directoryScopeId = '/'
                assignmentType = 'Assigned'; memberType = 'Direct'; endDateTime = $null
                verifiedAt = [datetimeoffset]::UtcNow.ToString('o')
            }
            # Retain verified evidence even if a later role fails. Preserve every other state entry.
            Save-DemoLabState $Prefix $State
        }
        "role $(if ($created) { 'ASSIGNED and ' })VERIFIED $($Persona.key) = $name (active, permanent, directory scope /)"
    }
}
