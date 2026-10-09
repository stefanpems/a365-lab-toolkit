#requires -Version 7.0
<#
.SYNOPSIS
  Read-only, versioned inventory of a Demo Builder lab, in Markdown, HTML and JSON.
.DESCRIPTION
  Uses the existing persona reporter, lab state, deployment plan and selected pack metadata.
  Live reads verify users, group memberships, group directory roles, SharePoint metadata and Azure resources.
  Recorded configuration is not proof of current deployment, publication, consent or effective access.
  Never reads secret files, document bodies, operator slots or raw deployment logs.
  -SnapshotOnly makes no cloud calls and labels recorded/planned information accordingly.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Prefix, [switch]$SnapshotOnly, [switch]$AsJson)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_demo-common.ps1')
. (Join-Path $PSScriptRoot '_demo-inventory.ps1')
$cfg = Read-DemoConfig $Prefix
$dir = Get-DemoLabDir $Prefix
$state = Read-DemoLabState $Prefix
$pack = Get-DemoPack $cfg.pack
$loc = Get-DemoLocale -Locale $cfg.locale -Pack $cfg.pack
$knowledge = Get-Content (Join-Path (Get-DemoPackDir $cfg.pack) "locales\$($cfg.locale)\knowledge.json") -Raw | ConvertFrom-Json -AsHashtable
$planPath = Join-Path (Split-Path $dir -Parent) 'a365-deployment-plan.json'
$plan = if (Test-Path $planPath) { Get-Content $planPath -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
$warnings = [System.Collections.Generic.List[object]]::new()
$sections = New-DemoInventorySections
$G = 'https://graph.microsoft.com/v1.0'

function Read-InventoryGraph([string]$Label, [string]$Url, [switch]$All) {
    try { Invoke-DemoGraph GET $Url -All:$All }
    catch {
        Write-Warning "Inventory verification failed: $Label. $($_.Exception.Message)"
        $http = if ($_.Exception.Message -match 'failed \((\d{3})\)') { $Matches[1] } else { 'unknown' }
        $warnings.Add([ordered]@{ resource = $Label; detail = "Cloud read failed (HTTP $http); not verified. See the command warning for the API error." })
        return $null
    }
}
function Person([string]$Key) {
    if ($state.users[$Key].upn) { return [string]$state.users[$Key].upn }
    if ($loc.personas[$Key]) { return Get-DemoUpn $loc $cfg $Key }
    return $Key
}
function Names($Objects) {
    @($Objects | ForEach-Object {
        if ($_.userPrincipalName) { "$($_.displayName) - $($_.userPrincipalName)" }
        elseif ($_.displayName) { "$($_.displayName) [$($_.id)]" }
        else { [string]$_.id }
    }) -join '; '
}
function Add-Row([int]$Section, [object[]]$Cells) {
    $sections[$Section].rows.Add(@($Cells | ForEach-Object { ConvertTo-DemoInventoryText $_ }))
}
$live = -not $SnapshotOnly
if ($live) { Assert-DemoTenant $cfg }

# Reuse the original persona report rather than reimplementing its role read-back.
if ($live) {
    $json = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Get-DemoPersonas.ps1') -Prefix $Prefix -AsJson
    if ($LASTEXITCODE -ne 0) { throw 'Get-DemoPersonas failed. Complete the required interactive sign-in or resolve the API error before generating a live inventory.' }
    $people = @($json | Out-String | ConvertFrom-Json)
} else {
    $people = @($pack.personas | ForEach-Object {
        $p = $_; $lp = $loc.personas[$p.key]
        [pscustomobject]@{ persona = $p.key; profile = $p.profile; demoRole = $p.story
            name = "$($lp.givenName) $($lp.surname)"; upn = Person $p.key; jobTitle = $lp.jobTitle
            entraRoles = "Planned, not verified: $(ConvertTo-DemoInventoryText $p.entraRoles)"
            notes = "Power Platform planned: $(ConvertTo-DemoInventoryText $p.powerPlatformRoles); Purview manual: $(ConvertTo-DemoInventoryText $p.purviewRoleGroups)" }
    })
    if ($cfg.adminUpn) {
        $people += [pscustomobject]@{ persona = 'operator'; profile = ''; demoRole = 'Operator (existing build account, not created by this run)'
            name = ''; upn = $cfg.adminUpn; jobTitle = 'Not verified'; entraRoles = 'Not verified in snapshot mode'; notes = 'Existing demo-config adminUpn' }
    }
}
foreach ($p in $people) {
    Add-Row 0 @("$($p.profile) $($p.demoRole) ($($p.persona))", "$($p.name) - $($p.upn)", $p.jobTitle, $p.entraRoles, $p.notes,
        $(if ($live) { 'Verified: Graph user and direct directory roles; other roles are planned/manual' } else { 'Snapshot: planned roles' }))
}
$roleDefs = @{}
$azureRoles = @()
if ($live) {
    $roleJson = & az role assignment list --all --subscription $cfg.subscriptionId -o json 2>&1
    if ($LASTEXITCODE -eq 0) { $azureRoles = @($roleJson | Out-String | ConvertFrom-Json) }
    else {
        Write-Warning 'Azure role assignment read failed; group RBAC permissions are not verified.'
        $warnings.Add([ordered]@{ resource = 'Group Azure RBAC'; detail = 'Azure role assignment read failed; group RBAC permissions are not verified.' })
    }
}
if ($live) {
    foreach ($r in @(Read-InventoryGraph 'Directory role definitions' "$G/roleManagement/directory/roleDefinitions?`$select=id,displayName" -All)) {
        if ($r) { $roleDefs[[string]$r.id] = $r.displayName }
    }
}
foreach ($group in $pack.groups) {
    $record = $state.groups[$group.key]
    $members = @($group.members | ForEach-Object { Person $_ }) -join '; '
    $owners = @($group.owners | ForEach-Object { Person $_ }) -join '; '
    $roles = 'Planned purpose only; not an effective-access audit'
    $status = if ($record.id) { 'Recorded in lab state; membership is planned' } else { 'Planned; no creation evidence' }
    if ($live -and $record.id) {
        $actual = Read-InventoryGraph "Group $($record.displayName)" "$G/groups/$($record.id)?`$select=id,displayName"
        $m = Read-InventoryGraph "Members of $($record.displayName)" "$G/groups/$($record.id)/members?`$select=id,displayName,userPrincipalName" -All
        $o = Read-InventoryGraph "Owners of $($record.displayName)" "$G/groups/$($record.id)/owners?`$select=id,displayName,userPrincipalName" -All
        $ra = Read-InventoryGraph "Directory roles of $($record.displayName)" "$G/roleManagement/directory/roleAssignments?`$filter=principalId eq '$($record.id)'&`$select=roleDefinitionId" -All
        $apps = Read-InventoryGraph "Application grants of $($record.displayName)" "$G/groups/$($record.id)/appRoleAssignments" -All
        $members = Names $m; $owners = Names $o
        $roles = @($ra | ForEach-Object { $roleDefs[[string]$_.roleDefinitionId] }) -join '; '
        if (-not $roles) { $roles = 'No direct directory roles returned; app/SharePoint access not inferred' }
        $appRoles = @($apps | Where-Object { $_ } | ForEach-Object { "$($_.resourceDisplayName): appRoleId $($_.appRoleId)" })
        $rbac = @($azureRoles | Where-Object { $_.principalId -eq $record.id } | ForEach-Object { "$($_.roleDefinitionName) at $($_.scope)" })
        $roles += "; direct application grants: $(if ($appRoles.Count) { $appRoles -join '; ' } else { 'none returned; see read gaps' }); Azure RBAC: $(if ($rbac.Count) { $rbac -join '; ' } else { 'none returned; see read gaps' })"
        $status = if ($actual) { 'Verified existence; see verification warnings for membership/role read failures' } else { 'Not verified' }
    }
    Add-Row 1 @($(if ($record.displayName) { $record.displayName } else { $loc.groups[$group.key].displayName }), $group.kind, $record.id,
        $members, $owners, $roles, $group.purpose, $status)
}
if ($state.governance.attribute) {
    $a = $state.governance.attribute
    Add-Row 2 @('Custom security attribute', "$($a.set).$($a.name)", 'Recorded in lab state', $a.values,
        'Agent approval classification; values recorded, not read back by this report')
}
if ($state.governance.catalog) {
    $c = $state.governance.catalog
    Add-Row 2 @('Entitlement catalog', $c.name, 'Recorded in lab state', $c.id, $loc.governance.catalog.description)
}
# Do not infer manual governance objects from a completed card or a requested policy.
$catalogId = $state.governance.catalog.id
if ($live -and $catalogId) {
    $packages = @(Read-InventoryGraph 'Access packages in the lab catalog' "$G/identityGovernance/entitlementManagement/accessPackages?`$filter=catalog/id eq '$catalogId'" -All | Where-Object { $_ })
    foreach ($p in @($packages)) {
        if ($p) { Add-Row 2 @('Access package', $p.displayName, 'Verified: Graph', $p.id, $p.description) }
    }
    if (-not $packages.Count) {
        Add-Row 2 @('Access package', $loc.governance.accessPackage.name, 'No package returned; consult verification gaps for any read failure', '', 'Manual configuration; do not assume creation')
    }
} elseif ($loc.governance.accessPackage) {
    Add-Row 2 @('Access package', $loc.governance.accessPackage.name, 'Planned; not verified', '', $loc.governance.accessPackage.description)
}
Add-Row 2 @('Conditional Access / other manual governance', 'Manual Entra card', 'Not inventoried as created without object evidence', '',
    'Portal configuration is not proven by plan or card status. This report does not enumerate unrelated tenant policies.')
foreach ($key in @($state.governance.identities.Keys | Sort-Object)) {
    foreach ($identity in $state.governance.identities[$key]) {
        Add-Row 2 @('Agent identity configuration', $identity.displayName, 'Recorded in lab state', $identity.identityId,
            "Owners: $($identity.owners); sponsors: $($identity.sponsors); attribute: $($identity.attribute); direct User.Read.All: $($identity['appRole:User.Read.All'])")
    }
}
if ($state.knowledge.driveId) {
    $drive = if ($live) { Read-InventoryGraph 'SharePoint library' "$G/drives/$($state.knowledge.driveId)?`$select=id,name,webUrl" } else { $null }
    $permissions = if ($live) { Read-InventoryGraph 'SharePoint library root permissions' "$G/drives/$($state.knowledge.driveId)/root/permissions" -All } else { @() }
    $permText = @($permissions | ForEach-Object {
        "$($_.roles -join ', '): $(Names @($_.grantedToV2.group, $_.grantedToV2.user, $_.grantedTo.group, $_.grantedTo.user | Where-Object { $_ }))"
    }) -join '; '
    Add-Row 3 @('Site / document library', $state.groups.site.displayName, $state.knowledge.libraryUrl,
        $(if ($permText) { $permText } else { 'Not verified; site M365 group membership is listed separately' }),
        $(if ($drive) { 'Verified: Graph drive; root permissions only, not all unique item ACLs' } else { 'Recorded library; not verified' }))
}
foreach ($key in @($state.knowledge.folders.Keys | Sort-Object)) {
    $folder = $state.knowledge.folders[$key]
    Add-Row 3 @('Folder', $folder.name, $folder.webUrl, 'Inherited access expected; unique ACLs not verified', 'Recorded in lab state')
}
foreach ($doc in $pack.knowledge.documents) {
    $name = $knowledge.documents[$doc.key].file
    $folder = $state.knowledge.folders[$doc.folder]
    if ($name) {
        $url = if ($folder.webUrl) { "$($folder.webUrl)/$([uri]::EscapeDataString($name))" } else { '' }
        Add-Row 3 @("Document ($($doc.format))", $name, $url, 'Folder inheritance expected; not an effective-access audit',
            $(if ($state.knowledge.uploaded) { "Upload batch recorded $(ConvertTo-DemoInventoryText $state.knowledge.uploaded); per-file existence not checked" } else { 'Planned; upload not recorded' }))
    }
}
$resources = @()
if ($live) {
    $raw = & az resource list --subscription $cfg.subscriptionId -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Azure inventory read failed: $($raw -join ' ')"
        $warnings.Add([ordered]@{ resource = 'Azure resources'; detail = 'az resource list failed; Azure deployment not verified.' })
    } else { $resources = @($raw | Out-String | ConvertFrom-Json) }
}
$ownedRgs = @($plan.agents.resourceGroup | Where-Object { $_ })
foreach ($r in @($resources | Sort-Object resourceGroup, type, name)) {
    if ($r.tags.a365lab -eq $Prefix -or $ownedRgs -contains $r.resourceGroup -or $r.resourceGroup -eq "$Prefix-demomcp-rg" -or
        $r.resourceGroup -in "$Prefix-ui-rg", "$Prefix-aoai-rg", "$Prefix-appinsights-rg", "$Prefix-webfetch-rg") {
        Add-Row 6 @($r.name, $r.type, $r.resourceGroup, $r.location, 'Verified: Azure resource list',
            "https://portal.azure.com/#@$($cfg.tenantId)/resource$($r.id)",
            $(if ($r.resourceGroup -eq $cfg.foundry.existingResourceGroup) { 'Configured as reused, not claimed as created by this run' } else { 'Lab inventory; existence is not a health check or proof of creation provenance' }))
    }
}
if ($cfg.foundry.account) {
    Add-Row 6 @($cfg.foundry.account, 'Foundry account / project', $cfg.foundry.existingResourceGroup, '',
        'Configured reuse-existing', $cfg.foundry.endpoint, 'Reused resource, not claimed as created by this run')
}
if ($plan.solution.azureOpenAI.deployment) {
    $aoaiRg = if ($plan.solution.azureOpenAI.existingResourceGroup) { $plan.solution.azureOpenAI.existingResourceGroup } else { "$Prefix-aoai-rg" }
    Add-Row 6 @($plan.solution.azureOpenAI.deployment, 'Azure OpenAI model deployment', $aoaiRg, '',
        'Configured in deployment plan; model deployment not read back', '', 'Capacity, model version and effective quota not verified')
}
if ($cfg.foundry.deployment) {
    Add-Row 6 @($cfg.foundry.deployment, 'Foundry model deployment', $cfg.foundry.existingResourceGroup, '',
        'Configured in lab config; model deployment not read back', $cfg.foundry.endpoint, 'Reused Foundry target; capacity not verified')
}
foreach ($a in @($pack.agents | Sort-Object { [int]$_.buildOrder }, { $_.key })) {
    $la = $loc.agents[$a.key]
    $pa = $plan.agents | Where-Object { $_.name -eq $la.codeName } | Select-Object -First 1
    $variant = [string]$a.variant
    $tech = switch ($a.platform) {
        'code' { if ($variant -like 'ACA-*') { 'Azure Container Apps / MAF / Python' } elseif ($variant -like 'FD-*') { 'Foundry prompt agent / service-managed; Python deployment client' } else { 'Foundry hosted / MAF / Python' } }
        'copilotStudio' { "Copilot Studio / $variant / low-code" }
        'agentBuilder' { 'Microsoft 365 Copilot Agent Builder / declarative / low-code' }
        default { [string]$a.platform }
    }
    $auth = if ($variant -match '-(OBO|S2S|DW)$') { $Matches[1] } elseif ($a.platform -eq 'agentBuilder') { 'User-context platform authentication; not DW' } else { 'Platform-managed; connector authentication not verified' }
    $knowledgeText = 'None declared'
    $folderKey = if ($a.knowledgeFolder) { $a.knowledgeFolder } elseif ($a.sameConfigAs) { ($pack.agents | Where-Object { $_.key -eq $a.sameConfigAs }).knowledgeFolder } else { '' }
    if ($folderKey) { $knowledgeText = "Planned SharePoint source: $($knowledge.folders[$folderKey]); attachment not verified" }
    if ($a.knowledgePersonal) { $knowledgeText = 'Planned personal OneDrive source; manual upload/attachment not verified' }
    $overlayKnowledge = Join-Path $dir "overlays\$($a.key)\knowledge"
    if (Test-Path $overlayKnowledge) { $knowledgeText = "Local file-search inputs: $((Get-ChildItem $overlayKnowledge -File).Name -join '; '); remote index not verified" }
    $tools = if ($pa.tools) { @($pa.tools) -join '; ' } else { @($a.tools) -join '; ' }
    $toolEvidence = if ($pa.tools) { 'Configured in deployment plan' } else { 'Planned in demo pack' }
    if (-not $tools) { $tools = 'None declared in plan/pack; overlay tools listed separately when present' } else { $tools = "${toolEvidence}: $tools; runtime access not verified" }
    $overlayStrings = Join-Path $dir "overlays\$($a.key)\overlay_strings.json"
    if (Test-Path $overlayStrings) {
        $strings = Get-Content $overlayStrings -Raw | ConvertFrom-Json -AsHashtable
        $toolNames = @($strings.overlay.tools.Values | ForEach-Object { $_.name } | Where-Object { $_ } | Sort-Object -Unique)
        if ($toolNames.Count) { $tools += "; local overlay tool definitions: $($toolNames -join ', ')" }
    }
    $overlayAgent = Join-Path $dir "overlays\$($a.key)\agent_overlay.py"
    if (Test-Path $overlayAgent) {
        $labels = @([regex]::Matches((Get-Content $overlayAgent -Raw), '["'']label["'']\s*:\s*["'']([^"'']+)["'']') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        if ($labels.Count) { $tools += "; local overlay MCP labels: $($labels -join ', '); remote attachment not verified" }
    }
    $evidence = 'Planned; no deployment evidence'
    $url = ''
    if ($pa.resourceGroup) {
        $app = $resources | Where-Object { $_.resourceGroup -eq $pa.resourceGroup -and $_.type -eq 'Microsoft.App/containerApps' } | Select-Object -First 1
        if ($app) { $evidence = 'Verified: ACA resource exists; health not checked'; $url = "https://portal.azure.com/#@$($cfg.tenantId)/resource$($app.id)" }
    }
    if ($state.governance.identities[$a.key]) { if (-not $url) { $evidence = 'Recorded agent identity; runtime/publication not verified' } }
    $generatedPath = Join-Path (Split-Path $dir -Parent) "$($la.codeName)\a365.generated.config.json"
    if (Test-Path $generatedPath) {
        # Project only public identifiers; never include the raw config or secret fields.
        $generated = Get-Content $generatedPath -Raw | ConvertFrom-Json -AsHashtable
        $ids = @('agentBlueprintId', 'agentBlueprintObjectId', 'agenticAppId', 'agentRegistrationId' | ForEach-Object {
            if ($generated[$_]) { "$_=$($generated[$_])" }
        }) -join '; '
        if ($ids) { Add-Row 2 @('Agent registration / blueprint', $la.codeName, 'Recorded generated identifiers; not a live registry read', $ids, 'Identity lifecycle metadata; no credentials included') }
        if ($generated.messagingEndpoint) { $url = $generated.messagingEndpoint }
        $generated = $null
    }
    if ($a.platform -eq 'agentBuilder') { $evidence = 'Manual creation planned; not verified' }
    $surface = if ($a.variant -like '*-DW') { 'Teams instance; hiring not verified' } elseif ($plan.ui.expose.agentName -contains $la.codeName) { 'Lab web UI' }
        elseif ($a.platform -eq 'copilotStudio') { 'Copilot Studio / Teams / Microsoft 365 Copilot; publication not verified' } else { 'Microsoft 365 Copilot' }
    Add-Row 4 @($(if ($la.displayName) { $la.displayName } else { $la.codeName }), $variant, $tech, $auth, $knowledgeText, $tools, $surface, $evidence, $url)
}
foreach ($key in @($state.mcp.backends.Keys | Sort-Object)) {
    $b = $state.mcp.backends[$key]; $s = $state.mcp.servers[$key]
    if ($s.proxyAppId -or $s.publicClientsAppId) {
        Add-Row 2 @('MCP gateway Entra registrations', $s.name, 'Recorded in lab state', "Proxy appId=$($s.proxyAppId); public clients appId=$($s.publicClientsAppId); audience=$($s.audience)",
            'Gateway proxy/resource/public-client metadata; current grants not read back')
    }
    Add-Row 5 @($(if ($s.name) { $s.name } else { $b.app }), 'Demo MCP / Container Apps / Python', $b.url, $b.tools,
        $(if ($s.status) { "Recorded gateway status: $($s.status)" } else { 'Backend deployed in state; gateway registration not recorded' }),
        $s.audience, $(if ($s.connectionVerified) { 'Connection environment verified when recorded' } else { 'Per-user connection/environment not verified' }),
        "Backend health recorded: $($b.healthy); app: $($b.app); not a live tool invocation")
}
foreach ($key in @($state.mcp.servers.Keys | Sort-Object)) {
    if (-not $state.mcp.backends[$key]) {
        $s = $state.mcp.servers[$key]
        Add-Row 5 @($s.name, 'Custom MCP gateway registration', $s.url, $s.tools, "Recorded: $($s.status)", $s.audience, 'Not verified', 'No backend record')
    }
}
$uiConfig = Join-Path (Split-Path $dir -Parent) "$($plan.ui.name)\config.js"
if (Test-Path $uiConfig) {
    $swa = $resources | Where-Object { $_.name -eq $plan.ui.name -and $_.type -eq 'Microsoft.Web/staticSites' } | Select-Object -First 1
    $uiUrl = ''
    if ($live -and $swa) {
        $site = & az staticwebapp show --name $plan.ui.name --resource-group $swa.resourceGroup --subscription $cfg.subscriptionId --query defaultHostname -o tsv 2>&1
        if ($LASTEXITCODE -eq 0 -and $site) { $uiUrl = "https://$site" }
        else { $warnings.Add([ordered]@{ resource = 'Web UI URL'; detail = 'Static Web App hostname read failed; URL not verified.' }); Write-Warning 'Static Web App hostname read failed.' }
    }
    Add-Row 6 @($plan.ui.name, 'Web UI / MSAL SPA', "$Prefix-ui-rg", $plan.ui.swaRegion, 'Local config exists; Azure existence listed separately', $uiUrl,
        'UI deployment, enabled tabs and delegated consent are separate checks')
}
$personal = $knowledge.personal
foreach ($key in @($personal.Keys | Sort-Object)) {
    Add-Row 6 @($personal[$key].file, 'Personal knowledge file', 'User OneDrive (manual)', '', 'Planned; upload not verified', '', 'Not a SharePoint library upload')
}
foreach ($p in @($plan.agents | Where-Object { $_.type -like '*-DW' })) {
    Add-Row 6 @($p.name, 'Digital Worker instance', 'Teams / Entra agent user', '', 'Manual instance creation / licenses not verified', '', 'Blueprint deployment is not evidence of hiring an instance')
}
foreach ($name in 'cards', 'overlays', 'knowledge', 'mcp-registration') {
    $path = Join-Path $dir $name
    if (Test-Path $path) { Add-Row 6 @($name, 'Generated preparation assets', $path, '', 'Verified: local directory exists', '', 'File names/bodies not expanded; credentials and logs excluded') }
}
$actions = Read-DemoUserActions $Prefix
foreach ($a in $actions.actions) {
    Add-Row 7 @($a.id, $(if ($a.blocking -and $a.status -ne 'DONE') { 'BLOCKING' } else { $a.status }), $a.action, $a.where, $a.neededBy)
}
foreach ($w in $warnings) { Add-Row 8 @($w.resource, $w.detail) }
Add-Row 8 @('Recorded / planned configuration', 'Agent publication, tool execution, per-user MCP connections, manual portal objects, remote knowledge indexes and all unique item ACLs are not verified by this inventory. Check the Evidence column and user-actions register.')
if ($SnapshotOnly) { Add-Row 8 @('Snapshot mode', 'No cloud reads; recorded state may be stale. Use a live report to verify users, memberships and Azure resources.') }
$report = [ordered]@{
    schemaVersion = '1.0'; prefix = $Prefix; generatedAt = (Get-Date).ToString('o')
    tenantId = $cfg.tenantId; subscriptionId = $cfg.subscriptionId; pack = $cfg.pack; locale = $cfg.locale
    mode = $(if ($SnapshotOnly) { 'Snapshot only (no cloud verification)' } else { 'Live read-only with recorded/planned configuration' })
    scope = 'Lab inventory, not a tenant-wide audit. No secrets, document bodies or excluded demo material. Empty sections remain visible. Direct roles only; not effective access.'
    sections = $sections
}
$report = Remove-DemoInventoryExcludedRows $report
$jsonPath = Join-Path $dir 'inventory.json'
$mdPath = Join-Path $dir 'inventory.md'
$htmlPath = Join-Path $dir 'inventory.html'
$report | ConvertTo-Json -Depth 15 | Set-Content $jsonPath -Encoding utf8
$md = ConvertTo-DemoInventoryMarkdown $report
$md | Set-Content $mdPath -Encoding utf8
ConvertTo-DemoInventoryHtml $report | Set-Content $htmlPath -Encoding utf8
if ($AsJson) { $report | ConvertTo-Json -Depth 15 } else { $md }
