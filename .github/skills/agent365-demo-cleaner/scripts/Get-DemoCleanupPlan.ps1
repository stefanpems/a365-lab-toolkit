#requires -Version 7.0
<#
.SYNOPSIS
  READ-ONLY discovery of everything a Demo Builder lab created (and what was added by hand following its runbook), in
  deletion order: writes the cleanup plan and its live HTML report under generated/cleanup/demo-<prefix>-<timestamp>/.
.DESCRIPTION
  Nothing is deleted or changed in the tenant. Sources, unioned: the lab state (state.json: the authoritative object
  index of the build), the demo pack and its locale (every localized name), the user-actions register (the manual
  runbook steps), the Lab Builder plan, and live reads: Microsoft Graph, the Agent 365 registry, Dataverse, Power
  Platform and Azure. The Azure/Entra components and agents are discovered by the Lab Cleaner's own discovery script
  (Discover-CleanupResources.ps1), reused unchanged. Objects tagged by ANOTHER lab (personas and groups shared by two
  labs in the same tenant and language) are kept by default. The report is written at the start and after every
  section, so the operator can open it while the discovery is running.
  Reconstruction mode: when generated/<prefix>/demo/ is gone, pass -TenantId, -SubscriptionId, -Locale, -Domain and
  -AdminUpn; names are rebuilt from the pack and the locale (no recorded IDs), with session authentication.
.PARAMETER RunDir          An existing run folder (created with -InitOnly) to continue in; default: a new one.
.PARAMETER AuthMode        lab (the lab-private az profile of the build) or session (a dedicated directory of this run).
.PARAMETER ThirdPartyAgents Exact registry names of agents created on third-party platforms (AWS, Google...) for the lab.
.PARAMETER OtherAdditions  Exact names of other objects added by hand (registry agents, Entra apps, users or groups).
.PARAMETER InitOnly        Create the run folder and the empty report, print its link and the read-only authentication check
                           (AUTH: OK <account> | AUTH: SIGN-IN NEEDED <login command> | AUTH: ERROR <message>), and stop.
.PARAMETER SnapshotOnly    No cloud reads: a preview from state, pack and locale only (cannot be used for a deletion).
.EXAMPLE
  pwsh -File .\Get-DemoCleanupPlan.ps1 -Prefix cts2 -InitOnly
  pwsh -File .\Get-DemoCleanupPlan.ps1 -Prefix cts2 -RunDir <run folder>
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)][string]$Prefix,
    [string]$RunDir,
    [ValidateSet('lab', 'session')][string]$AuthMode,
    [string]$TenantId, [string]$SubscriptionId, [string]$Locale, [string]$Domain, [string]$AdminUpn,
    [string]$Pack = 'agent-governance', [string]$PaygEnvironmentId, [string]$DefaultEnvironmentId,
    [string[]]$ThirdPartyAgents = @(), [string[]]$OtherAdditions = @(),
    [switch]$InitOnly, [switch]$SnapshotOnly
)
$ErrorActionPreference = 'Stop'
$builder = Join-Path $PSScriptRoot '..\..\agent365-demo-builder\scripts'
. (Join-Path $builder '_demo-common.ps1')
. (Join-Path $builder '_demo-entra.ps1')
. (Join-Path $PSScriptRoot '..\..\agent365-demo-reset\scripts\_demo-registry.ps1')
. (Join-Path $PSScriptRoot '_demo-cleaner.ps1')
$ThirdPartyAgents = @($ThirdPartyAgents | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$OtherAdditions = @($OtherAdditions | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$G = 'https://graph.microsoft.com/v1.0'
$labDir = Get-DemoLabDir $Prefix
$labRoot = Split-Path -Parent $labDir
$cfgFile = Join-Path $labDir 'demo-config.json'

# ------------------------------------------------------------------------------------------------- context
# A run folder created with -InitOnly supplies what this call does not repeat (authentication mode, reconstruction
# values, declared additions).
$prev = $null
if ($RunDir) {
    $RunDir = (Resolve-Path -LiteralPath $RunDir).Path
    $prev = (Read-CleanupPlan $RunDir).context
    if ($prev -and [string]$prev.prefix -and [string]$prev.prefix -ne $Prefix) { throw "Run $RunDir belongs to lab '$($prev.prefix)', not '$Prefix'." }
}
if ($prev) {
    if (-not $ThirdPartyAgents.Count -and $prev.additions) { $ThirdPartyAgents = @($prev.additions.thirdPartyAgents | Where-Object { $_ }) }
    if (-not $OtherAdditions.Count -and $prev.additions) { $OtherAdditions = @($prev.additions.otherAdditions | Where-Object { $_ }) }
}
$fromConfig = Test-Path -LiteralPath $cfgFile
$raw = if ($fromConfig) { Get-Content -LiteralPath $cfgFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } else { [ordered]@{} }
if ($prev) {
    # The values confirmed when the run was created (corrections included) win over the demo configuration.
    if (-not $TenantId) { $TenantId = [string]$prev.tenantId }
    if (-not $SubscriptionId) { $SubscriptionId = [string]$prev.subscriptionId }
    if (-not $Locale) { $Locale = [string]$prev.locale }
    if (-not $Domain) { $Domain = [string]$prev.domain }
    if (-not $AdminUpn) { $AdminUpn = [string]$prev.adminUpn }
    if (-not $PaygEnvironmentId -and $prev.copilotStudio) { $PaygEnvironmentId = [string]$prev.copilotStudio.paygEnvironmentId }
    if (-not $DefaultEnvironmentId -and $prev.copilotStudio) { $DefaultEnvironmentId = [string]$prev.copilotStudio.defaultEnvironmentId }
}
if (-not $fromConfig) {
    foreach ($p in 'TenantId', 'SubscriptionId', 'Locale', 'Domain', 'AdminUpn') {
        if (-not (Get-Variable $p -ValueOnly)) { throw "generated/$Prefix/demo/demo-config.json is missing (reconstruction mode): pass -$p." }
    }
}
$mode = if ($AuthMode) { $AuthMode } elseif ($prev -and [string]$prev.auth.mode) { [string]$prev.auth.mode } elseif ($fromConfig -and $raw.azConfigDir) { 'lab' } else { 'session' }
if ($mode -eq 'lab' -and -not $raw.azConfigDir) { throw 'The build has no lab-private az profile: use -AuthMode session.' }
$cs = if ($raw.copilotStudio) { $raw.copilotStudio } else { [ordered]@{} }
if ($PaygEnvironmentId) { $cs['paygEnvironmentId'] = $PaygEnvironmentId }
if ($DefaultEnvironmentId) { $cs['defaultEnvironmentId'] = $DefaultEnvironmentId }
$context = [ordered]@{
    prefix = $Prefix; pack = $(if ($raw.pack) { $raw.pack } else { $Pack }); locale = $(if ($Locale) { $Locale } else { $raw.locale })
    tenantId = $(if ($TenantId) { $TenantId } else { $raw.tenantId }); subscriptionId = $(if ($SubscriptionId) { $SubscriptionId } else { $raw.subscriptionId })
    domain = $(if ($Domain) { $Domain } else { $raw.domain }); adminUpn = $(if ($AdminUpn) { $AdminUpn } else { $raw.adminUpn })
    region = $raw.region; copilotStudio = $cs; foundry = $(if ($raw.foundry) { $raw.foundry } else { [ordered]@{} }); licenseSkus = $raw.licenseSkus
    labDir = $labDir; labRoot = $labRoot; fromConfig = $fromConfig; planPath = (Join-Path $labRoot 'a365-deployment-plan.json')
    auth = [ordered]@{ mode = $mode; azConfigDir = [string]$raw.azConfigDir; sessionDir = '' }
    additions = [ordered]@{ thirdPartyAgents = @($ThirdPartyAgents); otherAdditions = @($OtherAdditions) }
}

# ------------------------------------------------------------------------------------------------- run folder
if ($RunDir) {
    $cp = Read-CleanupPlan $RunDir
    if ($cp.phase -notin 'discovery', 'snapshot', 'review') { throw "Run $RunDir is already in phase '$($cp.phase)': start a new discovery without -RunDir." }
    $context.auth.sessionDir = $(if ($cp.context.auth.sessionDir) { $cp.context.auth.sessionDir } else { Join-Path $RunDir 'auth' })
    $cp['context'] = $context
    $cp['items'] = @(); $cp['warnings'] = @(); $cp['runbook'] = @(); $cp['summary'] = $null; $cp['rebuild'] = @()
}
else {
    $RunDir = New-CleanupRunDir $Prefix
    $context.auth.sessionDir = Join-Path $RunDir 'auth'
    $cp = New-CleanupPlan $Prefix $RunDir $context
}
$cp['phase'] = 'discovery'
$cp['mode'] = $(if ($SnapshotOnly) { 'snapshot' } else { 'live' })
$cp.discovery = [ordered]@{ section = 'starting'; sections = @(); startedAt = (Get-Date).ToString('o'); finishedAt = $null }
Save-CleanupPlan $cp
Write-Host "REPORT: $(Get-CleanupReportUri $RunDir)"
Write-Host "RUNDIR: $RunDir"
if ($InitOnly) {
    # Read-only check of the isolated az context, so that the agent asks for a sign-in BEFORE the background discovery.
    if (-not $SnapshotOnly) {
        $authLine = try {
            $s0 = Test-DemoAzSession (Use-CleanupAuth $context)
            if ($s0.tenantOk -and $s0.graphOk -and $s0.armOk) { "AUTH: OK $($s0.account)" } else { "AUTH: SIGN-IN NEEDED $(Get-CleanupLoginCommand $context)" }
        }
        catch {
            $why = $_.Exception.Message
            $cmd = try { Get-CleanupLoginCommand $context } catch { '' }
            if ($cmd) { "AUTH: SIGN-IN NEEDED $cmd ($why)" } else { "AUTH: ERROR $why" }
        }
        Write-Host $authLine
    }
    return
}

# Reconstruction mode: the Demo Builder helpers must not recreate the deleted lab folder (state, progress log).
if (-not (Test-Path -LiteralPath $labDir)) {
    function Save-DemoLabState([string]$Prefix, $State) { }
    function Write-DemoLog([string]$Prefix, [string]$Message, [string]$Level = 'INFO') { Write-CleanupLog $RunDir $Message $Level }
}
$cfg = Use-CleanupAuth $context
$packDef = Get-DemoPack $context.pack
$LOC = Get-DemoLocale -Locale $context.locale -Pack $context.pack
$state = Read-DemoLabState $Prefix
$lbPlan = if (Test-Path -LiteralPath $context.planPath) { Get-Content -LiteralPath $context.planPath -Raw | ConvertFrom-Json } else { $null }
$live = -not $SnapshotOnly
$gov = $LOC.governance
$slug = ($Prefix -replace '[^A-Za-z0-9]', '')
$labStart = $null
foreach ($ph in @($state.phases.Values)) { foreach ($s in @($ph.Values)) { if ($s.at) { $d = [datetime]$s.at; if (-not $labStart -or $d -lt $labStart) { $labStart = $d } } } }
if (-not $labStart -and $fromConfig) { $labStart = (Get-Item -LiteralPath $cfgFile).CreationTime }
if (-not $labStart) { $labStart = (Get-Date).AddDays(-60) }

function Start-Section([string]$Name) { $cp.discovery.section = $Name; $cp.discovery.sections = @($cp.discovery.sections) + @($Name); Update-CleanupIndexes $cp; Write-CleanupLog $RunDir "Discovery: $Name"; Save-CleanupPlan $cp }
function Add-Item($Item) { Add-CleanupItem $cp $Item | Out-Null }
function Warn([string]$Topic, [string]$Detail) { Add-CleanupWarning $cp $Topic $Detail; Write-CleanupLog $RunDir "$Topic - $Detail" 'WARN' }
function Try-Read([string]$What, [scriptblock]$Read) {
    if (-not $live) { return }
    try { & $Read | Where-Object { $null -ne $_ } } catch { Warn "Not verified: $What" $_.Exception.Message }
}
function Add-Manual {
    param([string]$Id, [string]$Name, [string]$Type, [int]$Order, [string]$Kind, [string]$Detail, [string]$Where, [string[]]$Steps,
          [string]$Verify = 'No API: confirm it in the chat when done, or say that it does not exist.', [string]$Source = '',
          [string]$Notes = '', [switch]$DefaultExcluded, [string]$ConfirmAs = 'deleted', [string[]]$DependsOn = @(), $Data)
    $m = [ordered]@{ where = $Where; steps = @($Steps); verify = $Verify; source = $Source; confirmAs = $ConfirmAs }
    Add-Item (New-CleanupItem -Id $Id -Name $Name -Type $Type -Order $Order -Executor 'manual' -Action 'manual' -Kind $Kind -Detail $Detail `
        -Manual $m -Notes $Notes -Origin 'runbook' -DefaultExcluded:$DefaultExcluded -DependsOn $DependsOn -Data $Data)
}
# A Lab Cleaner-compatible item (executed by Remove-CleanupResources.ps1, unchanged).
function New-LabItem([string]$Category, [string]$Kind, [string]$Id, [string]$ObjectId, [string]$DisplayName, [string]$Detail, [string]$Action, [int]$DeleteOrder, [hashtable]$Extra) {
    $o = [ordered]@{ category = $Category; kind = $Kind; id = $Id; objectId = $ObjectId; displayName = $DisplayName; detail = $Detail; action = $Action; deleteOrder = $DeleteOrder }
    if ($Extra) { foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] } }
    return $o
}
function Get-LabItemId($LabItem) { "lab:$($LabItem.kind):$(if ($LabItem.objectId) { $LabItem.objectId } else { $LabItem.id })" }
function Test-HasLabObject([string]$ObjectId, [string]$AppId) {
    @($cp.items | Where-Object { $_.data.labItem -and (($ObjectId -and $_.data.labItem.objectId -eq $ObjectId) -or ($AppId -and $_.data.labItem.id -eq $AppId -and $_.data.labItem.kind -eq 'entra-app')) }).Count -gt 0
}

if ($live) {
    $tid = ([string](az account show --query tenantId -o tsv 2>$null)).Trim()
    if ($tid -ne $context.tenantId) {
        throw "The isolated az context is not signed in to tenant $($context.tenantId) (current: '$tid'). Sign in interactively (browser, never device code): $(Get-CleanupLoginCommand $context)"
    }
    az account set --subscription $context.subscriptionId 2>$null | Out-Null
    $session = Test-DemoAzSession $cfg
    if (-not ($session.graphOk -and $session.armOk)) { throw "$($session.message)" }
    Write-CleanupLog $RunDir "Authentication: $($session.message) (mode $mode)"
}
foreach ($other in @(Get-ChildItem -LiteralPath (Join-Path $script:DemoRepoRoot 'generated') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $Prefix })) {
    $f = Join-Path $other.FullName 'demo\demo-config.json'
    if (-not (Test-Path -LiteralPath $f)) { continue }
    $o = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
    if ($o.tenantId -eq $context.tenantId -and $o.locale -eq $context.locale) {
        Warn 'Another lab in the same tenant and language' "Lab '$($other.Name)' uses tenant $($o.tenantId) and locale $($o.locale): personas, groups, agent names and ext_ servers have the same names. Objects tagged by that lab are kept by default."
    }
}

# ------------------------------------------------------------------------------------------------- people (ids first)
$personaIds = @{}
$userItems = @{}
foreach ($p in $packDef.personas) {
    $upn = Get-DemoUpn $LOC $cfg $p.key
    $rec = $state.users[$p.key]
    $u = Try-Read "user $upn" {
        $ref = if ($rec.id) { $rec.id } else { [uri]::EscapeDataString($upn) }
        $x = Get-CleanupObject "$G/users/$ref`?`$select=id,displayName,userPrincipalName,mail,assignedLicenses,onPremisesExtensionAttributes"
        if (-not $x -and $rec.id) { $x = Get-CleanupObject "$G/users/$([uri]::EscapeDataString($upn))?`$select=id,displayName,userPrincipalName,mail,assignedLicenses,onPremisesExtensionAttributes" }
        $x
    }
    if ($u) { $personaIds[$p.key] = [string]$u.id }
    $userItems[$p.key] = [ordered]@{ upn = $upn; user = $u; record = $rec }
}

# ------------------------------------------------------------------------------------------------- 1. admin center
Start-Section 'Microsoft 365 admin center objects (manual)'
$adminWhere = 'Microsoft 365 admin center (https://admin.microsoft.com) > Agents > Settings'
foreach ($r in @($packDef.governance.adminCenter.rules)) {
    if ($r.nameKey) {
        $n = [string]$gov.rules[$r.nameKey]
        Add-Manual -Id "admin-rule:$($r.key)" -Name $n -Type Configuration -Order 1010 -Kind 'admin-center-object' -Detail 'Custom automation rule (created live during the runs)' `
            -Where "$adminWhere > Rules" -Steps @("Open the rule '$n' (it exists only if it was created during a run).", 'Delete it; if only Turn off is offered, turn it off.') -Source 'Card 60-admin-center: custom automation rules'
    }
    else {
        Add-Manual -Id "admin-rule:$($r.key)" -Name "Built-in rule '$($r.key)'" -Type Configuration -Order 1011 -Kind 'admin-center-object' -Detail 'Built-in ownerless-agent rule' `
            -Where "$adminWhere > Rules" -Steps @('Turn the built-in ownerless-agent rule off again only if it was turned on for this lab.') -Source 'Card 60-admin-center' `
            -DefaultExcluded -Notes 'Kept by default: a built-in rule is a tenant setting, not a lab object. Include it only if it was turned on for this lab.'
    }
}
foreach ($t in @($packDef.governance.adminCenter.templates)) {
    $n = [string]$gov.templates[$t.key]
    Add-Manual -Id "admin-template:$($t.key)" -Name $n -Type Configuration -Order 1020 -Kind 'admin-center-object' -Detail 'Agent policy template' `
        -Where "$adminWhere > Templates" -Steps @("Select '$n' > Delete.", 'If it is still applied to agents, it is removed from them; agents approved with it keep their policies until they are deleted later in this run.') `
        -Source 'Card 60-admin-center: policy templates'
}
Add-Manual -Id 'admin-template:live' -Name 'Other custom templates created during rehearsals or runs' -Type Configuration -Order 1021 -Kind 'admin-center-object' -Detail 'Templates created live (names chosen on camera)' `
    -Where "$adminWhere > Templates" -Steps @('Delete every custom template created during the rehearsals or the runs of this lab (not the ones of other labs).') -Source 'Run of show: manual resets'
foreach ($t in @($packDef.governance.adminCenter.tags)) {
    $n = [string]$gov.tags[$t]
    Add-Manual -Id "admin-tag:$t" -Name $n -Type Configuration -Order 1030 -Kind 'admin-center-object' -Detail 'Organization tag of the agent registry' `
        -Where "$adminWhere > Tags" -Steps @("Select the tag '$n' > Delete (it is removed from every agent that has it).") -Source 'Card 60-admin-center: tags'
}
Add-Manual -Id 'admin-tag:lab' -Name $Prefix -Type Configuration -Order 1031 -Kind 'admin-center-object' -Detail 'Native Agent 365 lab-name tag (docs/agent365-lab-tags.md)' `
    -Where "$adminWhere > Tags" -Steps @("Select the tag named exactly '$Prefix' > Delete (it exists only if the lab-name tag action was done).") -Source 'User action agent365-lab-tag'

# ------------------------------------------------------------------------------------------------- 2. demo MCP servers
Start-Section 'Demo MCP servers (ext_ registrations, backing apps, connectors, connections)'
$mcpEntries = @()
foreach ($k in @($state.mcp.servers.Keys)) { $s = $state.mcp.servers[$k]; if ($s.name) { $mcpEntries += [pscustomobject]@{ name = [string]$s.name; key = $k; status = [string]$s.status; role = '' } } }
foreach ($s in @($state.mcp.pool)) { if ($s.name) { $mcpEntries += [pscustomobject]@{ name = [string]$s.name; key = [string]$s.key; status = [string]$s.status; role = [string]$s.role } } }
if (-not $mcpEntries.Count -and -not $fromConfig) {
    foreach ($k in @($LOC.mcp.servers.Keys)) { $n = [string]$LOC.mcp.servers[$k].name; if ($n) { $mcpEntries += [pscustomobject]@{ name = $n; key = $k; status = 'unknown'; role = '' } } }
}
$mcpPackages = @(Try-Read 'registry MCP servers' { Invoke-DemoGraph GET "$script:DemoG/beta/copilot/admin/catalog/packages?`$filter=$([uri]::EscapeDataString("elementTypes/any(e:e eq 'MCPServers')"))" -Token (Get-DemoRegToken $cfg) -All })
$ppEnv = [string]$state.mcp.environmentId
$ppToken = if ($live) { Try-Read 'Power Platform token' { Get-DemoAzToken -Resource 'https://service.powerapps.com/' -TenantId $context.tenantId } } else { $null }
$connectors = @()
if ($ppEnv -and $ppToken) {
    $connectors = @(Try-Read "connectors of environment $ppEnv" { Invoke-DemoGraph GET "https://api.powerapps.com/providers/Microsoft.PowerApps/apis?api-version=2016-11-01&`$filter=environment eq '$ppEnv'" -Token $ppToken -All })
}
$reserved = @()
$deletedApps = @(Try-Read 'Entra recycle bin (applications)' { @(Invoke-DemoGraph GET "$G/directory/deletedItems/microsoft.graph.application?`$select=id,appId,displayName" -All) })
$deletedSps = @(Try-Read 'Entra recycle bin (service principals)' { @(Invoke-DemoGraph GET "$G/directory/deletedItems/microsoft.graph.servicePrincipal?`$select=id,appId,displayName" -All) })
foreach ($m in @($mcpEntries | Where-Object { $_.status -notin 'payload', 'abandoned' })) {
    $id = "mcp-server:$($m.name)"
    $pkg = @($mcpPackages | Where-Object { $_.displayName -eq $m.name }) | Select-Object -First 1
    $statusText = if ($pkg) { "registry: $(if ($pkg.isBlocked) { 'blocked' } elseif ($pkg.requestStatus -eq 'pending') { 'pending request' } else { 'available' })" } else { "recorded status: $($m.status)" }
    $exec = if ($m.status -eq 'failed' -and -not $pkg) { 'record-only' } else { 'mcp-neutralize' }
    Add-Item (New-CleanupItem -Id $id -Name $m.name -Type Component -Order 1510 -Executor $exec -Action 'neutralize-mcp-server' -Kind 'mcp-server' `
        -Detail "Demo MCP server ($(if ($m.role) { "pool, $($m.role)" } else { "long-lived, $($m.key)" })) · $statusText" `
        -Data ([ordered]@{ name = $m.name; packageId = $(if ($pkg) { [string]$pkg.id } else { '' }); recordedStatus = $m.status }) `
        -Limitation 'No platform API deletes an ext_ registration: it is Blocked (approved) or Rejected (pending) and its name stays reserved in the tenant.' `
        -Manual ([ordered]@{ where = 'Microsoft 365 admin center > Agents > Tools'; source = 'User action mcp-approve; pack README: teardown'; confirmAs = 'limitation'
            steps = @("If '$($m.name)' is a pending request: Tools > Requests > $($m.name) > Reject.", "If it is approved: Tools > $($m.name) > Block.", 'It cannot be deleted: its name stays reserved in the tenant.')
            verify = 'Verified through the registry API when the server is listed there.' }) `
        -Notes 'Cannot be deleted (platform limitation): it is neutralized (Block, or Reject for a pending request) before its Entra apps and connectors are deleted.' -Origin 'state')
    $reserved += [ordered]@{ name = $m.name; state = $m.status }
    $apps = @(Try-Read "Entra apps of $($m.name)" { Invoke-DemoGraph GET "$G/applications?`$filter=$([uri]::EscapeDataString("startswith(displayName,'$($m.name)')"))&`$select=id,appId,displayName" -All })
    foreach ($a in @($apps | Where-Object { $_.displayName -eq $m.name -or $_.displayName -like "$($m.name)-*" -or $_.displayName -like "$($m.name) *" })) {
        $li = New-LabItem 'CustomMcp' 'entra-app' $a.appId $a.id $a.displayName "Backing Entra app of the MCP server $($m.name) (deleted + purged)" 'delete-app' 20
        Add-Item (New-CleanupItem -Id (Get-LabItemId $li) -Name $a.displayName -Type Component -Order 4530 -Executor 'lab-cleaner' -Action 'delete-app' -Kind 'mcp-app' `
            -Detail "Entra app of $($m.name) · appId $($a.appId)" -Data ([ordered]@{ labItem = $li }) -DependsOn @($id) -Origin 'discovery')
    }
    foreach ($c in @($connectors | Where-Object { $_.properties.displayName -eq $m.name -or $_.properties.displayName -eq "$($m.name)P" -or [string]$_.properties.displayName -like "$($m.name)*" })) {
        $connections = @(Try-Read "connections of $($c.name)" { Invoke-DemoGraph GET "https://api.powerapps.com/providers/Microsoft.PowerApps/scopes/admin/environments/$ppEnv/apis/$($c.name)/connections?api-version=2016-11-01" -Token $ppToken -All })
        foreach ($cn in $connections) {
            $who = [string]$cn.properties.createdBy.userPrincipalName
            Add-Item (New-CleanupItem -Id "pp-connection:$ppEnv/$($c.name)/$($cn.name)" -Name "Connection of $who to $($c.properties.displayName)" -Type Component -Order 4515 `
                -Executor 'powerapps' -Action 'delete-pp-connection' -Kind 'pp-connection' -Detail "Power Platform connection in environment $ppEnv (created from the per-user connection URL)" `
                -Data ([ordered]@{ environment = $ppEnv; api = [string]$c.name; connection = [string]$cn.name }) -Origin 'discovery')
        }
        $managed = [string]$c.name -like 'shared_tc-*'
        $li = New-LabItem 'CustomMcp' 'powerplatform-connector' $c.name $null $c.properties.displayName "Power Platform connector of $($m.name) in environment $ppEnv" 'delete-connector' 30 @{ environment = $ppEnv }
        Add-Item (New-CleanupItem -Id (Get-LabItemId $li) -Name $c.properties.displayName -Type Component -Order 4520 -Executor 'lab-cleaner' -Action 'delete-connector' -Kind 'mcp-connector' `
            -Detail $(if ($managed) { "Platform-managed tool connector of $($m.name) (environment $ppEnv): the maker API refuses it, the admin API is tried, otherwise it stays with the blocked server (platform limitation)" } else { "Connector of $($m.name) (environment $ppEnv)" }) `
            -Data ([ordered]@{ labItem = $li }) -DependsOn @($id) -Origin 'discovery')
    }
    foreach ($d in @(@($deletedApps) + @($deletedSps) | Where-Object { [string]$_.displayName -like "$($m.name)*" })) {
        $li = New-LabItem 'CustomMcp' 'deleted-item' $d.id $d.id $d.displayName 'In the Entra recycle bin: permanently purged' 'purge-deleted-item' 24
        Add-Item (New-CleanupItem -Id (Get-LabItemId $li) -Name $d.displayName -Type Component -Order 4540 -Executor 'lab-cleaner' -Action 'purge-deleted-item' -Kind 'mcp-app' `
            -Detail 'Soft-deleted object of the MCP server registration (recycle bin)' -Data ([ordered]@{ labItem = $li }) -Origin 'discovery')
    }
}
if ($reserved.Count -and $live) {
    $memo = Add-DemoReservedMcpNames -TenantId $context.tenantId -Prefix $Prefix -Names $reserved
    Write-CleanupLog $RunDir "Reserved ext_ names recorded for future builds: $memo"
}

# ------------------------------------------------------------------------------------------------- 3. Purview + Defender
Start-Section 'Purview and Defender objects'
$sccOk = [bool](Get-Module -ListAvailable ExchangeOnlineManagement)
if (-not $sccOk) { Warn 'Security & Compliance PowerShell' 'The ExchangeOnlineManagement module is not installed: the Purview policies become manual actions (Install-Module ExchangeOnlineManagement -Scope CurrentUser to automate them).' }
$purview = 'Microsoft Purview (https://purview.microsoft.com)'
$caseName = [string]$gov.ediscoveryCase
$cases = @(Try-Read 'eDiscovery cases' { @((Get-CleanupObject "$G/security/cases/ediscoveryCases?`$filter=$([uri]::EscapeDataString("displayName eq '$($caseName.Replace("'", "''"))'"))" (Get-CleanupGraphToken $cfg)).value) })
if ($cases.Count) {
    foreach ($c in $cases) {
        Add-Item (New-CleanupItem -Id "ediscovery:$($c.id)" -Name $c.displayName -Type Resource -Order 2010 -Executor 'graph' -Action 'delete-ediscovery-case' -Kind 'ediscovery-case' `
            -Detail "eDiscovery case (status $($c.status)): its holds are removed, the case is closed, then deleted" -Data ([ordered]@{ id = [string]$c.id }) -Origin 'discovery')
    }
}
elseif (-not $live) { Add-Item (New-CleanupItem -Id 'ediscovery:name' -Name $caseName -Type Resource -Order 2010 -Executor 'graph' -Action 'delete-ediscovery-case' -Kind 'ediscovery-case' -Detail 'eDiscovery case (snapshot: not verified)' -Data ([ordered]@{ name = $caseName })) }
$scc = [ordered]@{
    'cc' = @{ name = [string]$gov.communicationCompliancePolicy; action = 'remove-cc-policy'; order = 2020; what = 'Communication Compliance policy'; where = "$purview > Communication Compliance > Policies" }
    'dlp' = @{ name = [string]$gov.dlpPolicy; action = 'remove-dlp-policy'; order = 2040; what = 'DLP policy (DSPM recommendation)'; where = "$purview > Data loss prevention > Policies" }
    'labelPolicy' = @{ name = "Label policy publishing '$($gov.sensitivityLabel.name)'"; label = [string]$gov.sensitivityLabel.name; action = 'remove-label-policy'; order = 2050; what = 'Sensitivity label publishing policy'; where = "$purview > Information protection > Publishing policies" }
    'label' = @{ name = [string]$gov.sensitivityLabel.name; action = 'remove-label'; order = 2060; what = 'Sensitivity label'; where = "$purview > Information protection > Sensitivity labels" }
    'auditRetention' = @{ name = [string]$gov.auditRetentionPolicy; action = 'remove-audit-retention'; order = 2070; what = 'Audit retention policy'; where = "$purview > Audit > Audit retention policies" }
}
foreach ($k in $scc.Keys) {
    $d = $scc[$k]
    $kind = switch ($k) { 'label' { 'sensitivity-label' } 'labelPolicy' { 'label-policy' } default { 'scc-policy' } }
    $deps = switch ($k) { 'label' { @('scc:labelPolicy', 'scc:dlp') } default { @() } }
    $steps = switch ($k) {
        'labelPolicy' { @("Open the label publishing policy that publishes '$($d.label)' (created for the demo).", 'If it publishes only that label, delete the policy; otherwise remove the label from it.') }
        'label' { @("Select '$($d.name)' > Delete label (after its publishing policy and the DLP policy are gone).") }
        default { @("Select '$($d.name)' > Delete.") }
    }
    $m = [ordered]@{ where = $d.where; steps = $steps; verify = 'Verified with Security & Compliance PowerShell when available; otherwise confirm it in the chat.'; source = 'Card 40-purview'; confirmAs = 'deleted' }
    Add-Item (New-CleanupItem -Id "scc:$k" -Name $d.name -Type Configuration -Order $d.order -Executor $(if ($sccOk) { 'scc' } else { 'manual' }) -Action $d.action -Kind $kind `
        -Detail "$($d.what) · existence checked at deletion time" -Data ([ordered]@{ name = $d.name; label = [string]$d.label }) -Manual $m -DependsOn $deps -Origin 'runbook')
}
Add-Manual -Id 'purview:dspm' -Name 'DSPM one-click policies created for the demo' -Type Configuration -Order 2030 -Kind 'scc-policy' -Detail 'Insider Risk Management "Detect risky interactions in AI apps" and communication insights "Detect unethical behavior in AI apps"' `
    -Where "$purview > Data Security Posture Management (the new DSPM)" -Steps @('Open the policies created from the DSPM remediation actions for the demo.', 'Delete them (Insider Risk Management > Policies, Communication Compliance > Policies), only if no other workload of the tenant relies on them.') -Source 'Card 40-purview: DSPM'
foreach ($k in @($gov.auditSearches.Keys)) {
    $n = [string]$gov.auditSearches[$k]
    Add-Manual -Id "audit-search:$k" -Name $n -Type Resource -Order 2080 -Kind 'audit-search' -Detail 'Saved audit search' -Where "$purview > Audit > Search" -Steps @("Select the search '$n' > Delete.") -Source 'Card 40-purview: audit'
}
foreach ($k in @($gov.huntingQueries.Keys)) {
    $n = [string]$gov.huntingQueries[$k]
    Add-Manual -Id "hunting:$k" -Name $n -Type Configuration -Order 2090 -Kind 'hunting-query' -Detail 'Saved advanced hunting query' -Where 'Microsoft Defender (https://security.microsoft.com) > Investigation & response > Hunting > Advanced hunting > Queries' `
        -Steps @("Find '$n' in Shared queries or My queries > Delete (it exists only if it was saved).") -Source 'Card 50-defender'
}
if ($gov.rtpRule) {
    Add-Manual -Id 'defender:rtp' -Name ([string]$gov.rtpRule) -Type Configuration -Order 2095 -Kind 'hunting-query' -Detail 'Legacy real-time protection rule (only for an explicitly requested legacy setup)' `
        -Where 'Microsoft Defender > the agent real-time protection rules' -Steps @('Delete the rule if the legacy setup was requested.') -Source 'Pack README: compatibility objects' `
        -DefaultExcluded -Notes 'Kept by default: legacy compatibility object, created only when the legacy setup was requested. Include it if it exists.'
}
Add-Manual -Id 'defender:incidents' -Name 'Defender incidents and alerts of the demo' -Type Resource -Order 2100 -Kind 'defender-evidence' -Detail 'DLP incident, alerts, Insider Risk and Communication Compliance alerts generated by the tests' `
    -Where 'Microsoft Defender > Incidents & alerts; Purview > Insider Risk Management and Communication Compliance > Alerts' -Steps @('Resolve (close) the incidents and alerts generated by the lab tests: they cannot be deleted.') `
    -ConfirmAs 'limitation' -Verify 'No API used: confirm it in the chat. It stays "Could not delete" (platform limitation) because incidents and alerts are only resolved.' -Source 'Card 50-defender'
Add-Manual -Id 'defender:connectors' -Name 'Defender connectors for AI agents' -Type Configuration -Order 2110 -Kind 'tenant-setting' -Detail 'Microsoft 365 app connector and Copilot Studio connection (security for AI agents)' `
    -Where 'Microsoft Defender > Settings > Cloud apps > Connected apps / App connectors' -Steps @('Disconnect them only if they were connected only for this lab and nothing else in the tenant uses them.') -Source 'Card 50-defender' `
    -DefaultExcluded -Notes 'Kept by default: tenant-wide security settings that other workloads may need. Include them only if they were enabled for this lab.'

# ------------------------------------------------------------------------------------------------- 4. Entra governance
Start-Section 'Entra governance (Conditional Access, access packages, catalog)'
$caItems = @()
foreach ($ca in @($packDef.governance.conditionalAccess)) {
    $n = [string]$gov.conditionalAccess[$ca.key]
    $found = @(Try-Read "Conditional Access policy $n" { @((Get-CleanupObject "$G/identity/conditionalAccess/policies?`$filter=$([uri]::EscapeDataString("displayName eq '$($n.Replace("'", "''"))'"))" (Get-CleanupGraphToken $cfg)).value) })
    if (-not $live) { $found = @([pscustomobject]@{ id = ''; displayName = $n; state = 'not verified' }) }
    foreach ($f in $found) {
        $id = "ca:$(if ($f.id) { $f.id } else { $ca.key })"
        $caItems += $id
        Add-Item (New-CleanupItem -Id $id -Name $f.displayName -Type Configuration -Order 3010 -Executor 'graph' -Action 'delete-ca-policy' -Kind 'ca-policy' `
            -Detail "Conditional Access policy (state $($f.state))" -Data ([ordered]@{ id = [string]$f.id; name = $n }) -Origin 'runbook')
    }
    if ($live -and -not $found.Count) { Write-CleanupLog $RunDir "Conditional Access policy '$n' not found (never created or already deleted)" }
}
$catName = [string]$gov.catalog.name
$catalogs = @()
if ($state.governance.catalog.id) {
    $c = Try-Read 'entitlement catalog' { Get-CleanupObject "$G/identityGovernance/entitlementManagement/catalogs/$($state.governance.catalog.id)" (Get-CleanupGraphToken $cfg) }
    if ($c) { $catalogs += $c }
}
if (-not $catalogs.Count) {
    $catalogs = @(Try-Read 'entitlement catalog by name' { @((Get-CleanupObject "$G/identityGovernance/entitlementManagement/catalogs?`$filter=$([uri]::EscapeDataString("displayName eq '$($catName.Replace("'", "''"))'"))" (Get-CleanupGraphToken $cfg)).value) })
}
if (-not $live) { $catalogs = @([pscustomobject]@{ id = [string]$state.governance.catalog.id; displayName = $catName }) }
foreach ($c in $catalogs) {
    $pkgIds = @()
    $aps = @(Try-Read "access packages of $($c.displayName)" { @(Invoke-DemoGraph GET "$G/identityGovernance/entitlementManagement/accessPackages?`$filter=$([uri]::EscapeDataString("catalog/id eq '$($c.id)'"))" -Token (Get-CleanupGraphToken $cfg) -All) })
    if (-not $live -and $state.governance.accessPackage.id) { $aps = @([pscustomobject]@{ id = [string]$state.governance.accessPackage.id; displayName = [string]$state.governance.accessPackage.name }) }
    foreach ($ap in $aps) {
        $pid_ = "access-package:$($ap.id)"; $pkgIds += $pid_
        Add-Item (New-CleanupItem -Id $pid_ -Name $ap.displayName -Type Configuration -Order 3020 -Executor 'graph' -Action 'delete-access-package' -Kind 'access-package' `
            -Detail 'Access package: its assignments are removed, pending requests cancelled and policies deleted first' -Data ([ordered]@{ id = [string]$ap.id }) -Origin 'runbook')
    }
    Add-Item (New-CleanupItem -Id "catalog:$($c.id)" -Name $c.displayName -Type Configuration -Order 3030 -Executor 'graph' -Action 'delete-catalog' -Kind 'catalog' `
        -Detail 'Entitlement management catalog: its resources are removed first' -Data ([ordered]@{ id = [string]$c.id }) -DependsOn $pkgIds -Origin 'state')
}

# ------------------------------------------------------------------------------------------------- 5. agents outside Azure
Start-Section 'Agents: registry, Agent Builder, Copilot Studio, third-party platforms'
$personaIdList = @($personaIds.Values)
$knownPackages = @{}
$registryVerify = [System.Collections.Generic.List[object]]::new()
foreach ($a in @($packDef.agents | Sort-Object { [int]$_.buildOrder })) {
    $name = Get-DemoAgentName -Locale $LOC -Key $a.key
    if ($live) { try { Initialize-DemoAgentState $cfg $LOC $state $a } catch { } }
    $pk = $null
    if ($a.catalog -ne $false) {
        $pk = Try-Read "registry packages of $name" { Get-DemoAgentPackages $cfg $LOC $state $a }
    }
    $ids = @(@($pk.all) | Where-Object { $_ } | ForEach-Object { [string]$_.id })
    if (-not $live) { $ids = @($state.agents[$a.key].packages | Where-Object { $_ }) }
    foreach ($i in $ids) { $knownPackages[$i] = $a.key }
    if ($a.platform -eq 'agentBuilder') {
        $creator = if ($a.creator) { "$(Get-DemoPersonaDisplayName $LOC $a.creator) ($(Get-DemoUpn $LOC $cfg $a.creator))" } else { 'a persona' }
        if (-not $ids.Count -and $live) { Write-CleanupLog $RunDir "Agent Builder agent '$name' not found in the registry (not created or already deleted)"; continue }
        Add-Item (New-CleanupItem -Id "agent-builder:$($a.key)" -Name $name -Type Agent -Order 4010 -Executor 'manual' -Action 'registry-delete' -Kind 'agent-builder-agent' `
            -Detail "Agent Builder agent created by $creator · registry packages: $($ids -join ', ')" -Data ([ordered]@{ packageIds = $ids }) `
            -Manual ([ordered]@{ where = 'Microsoft 365 admin center > Agents > All agents'; source = 'Card 11-agent-builder'; confirmAs = 'deleted'
                steps = @("If '$name' has a pending request: Requests > select it > Reject submission.", "All agents > select '$name' > Delete agent (every entry of it, shared and published).", "All agents > Deleted > select '$name' > Permanently delete (otherwise it stays recoverable for 30 days).")
                verify = 'Verified through the registry API: every package must be gone.' }) -Origin 'runbook')
        if ($a.customSkill -and $LOC.skills[$a.customSkill]) {
            $skill = [string]$LOC.skills[$a.customSkill].name
            $skills = @(Try-Read "registry skill $skill" { @(Invoke-DemoGraph GET "$script:DemoG/beta/copilot/admin/catalog/packages?`$filter=$([uri]::EscapeDataString("elementTypes/any(e:e eq 'AgentSkills')"))" -Token (Get-DemoRegToken $cfg) -All | Where-Object { $_.displayName -eq $skill }) })
            Add-Item (New-CleanupItem -Id "agent-skill:$($a.customSkill)" -Name $skill -Type Agent -Order 4011 -Executor 'manual' -Action 'registry-delete' -Kind 'agent-skill' `
                -Detail "Custom Agent Builder skill of $name" -Data ([ordered]@{ packageIds = @($skills | ForEach-Object { [string]$_.id }) }) `
                -Manual ([ordered]@{ where = 'Microsoft 365 admin center > Agents > All agents (tools and skills)'; source = 'Card 11-agent-builder'; confirmAs = 'deleted'
                    steps = @("Find the skill '$skill' > Delete, then Deleted > Permanently delete. If it is listed only inside the agent, it goes with the agent.")
                    verify = 'Verified through the registry API when the skill is listed; otherwise confirm it in the chat.' }) -Origin 'runbook')
        }
        continue
    }
    if ($ids.Count) { $registryVerify.Add([pscustomobject]@{ key = $a.key; name = $name; ids = $ids }) }
    if ($a.platform -eq 'copilotStudio') {
        $envId = if ($a.environment -eq 'default') { [string]$cfg.copilotStudio.defaultEnvironmentId } else { [string]$cfg.copilotStudio.paygEnvironmentId }
        $rec = $state.agents[$a.key]
        if (-not $envId) { if ($rec.botId) { Warn "Copilot Studio agent $name" 'No environment id in the configuration: pass -PaygEnvironmentId / -DefaultEnvironmentId.' }; continue }
        if ($a.outsideLabPlan -and -not $rec.botId -and -not $live) { continue }
        $bot = Try-Read "Copilot Studio agent $name" { Resolve-DemoCopilotStudioBot $cfg $LOC $state $a }
        if (-not $bot -and $live) {
            if (-not $a.outsideLabPlan) { Write-CleanupLog $RunDir "Copilot Studio agent '$name' not found in environment $envId (not created or already deleted)" }
            continue
        }
        $botId = if ($bot) { [string]$bot.botid } else { [string]$rec.botId }
        $org = if ($live) { Try-Read "Dataverse URL of $envId" { Get-DemoCopilotStudioOrgUrl $cfg $envId } } else { [string]$rec.dataverseUrl }
        # Only the lab's own unmanaged solutions are candidates (never the system or default solutions of Dataverse):
        # the prefix-derived <prefix>MCS* names of the Lab Builder, the code-name-derived name of older builds and the
        # zip name of the scaffold. The one that really contains the bot is preferred.
        $codeName = [string]$LOC.agents[$a.key].codeName
        $candidates = @(@(Get-ChildItem -LiteralPath (Join-Path $labRoot "$codeName\solution") -Filter '*.zip' -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName }) +
            @($codeName -replace '[^A-Za-z0-9]', '') | Where-Object { $_ } | Select-Object -Unique)
        $sol = ''
        if ($live -and $org) {
            $tok = Try-Read 'Dataverse token' { Get-DemoAzToken -Resource $org -TenantId $context.tenantId }
            $linked = @()
            if ($tok -and $botId) {
                $linked = @(Try-Read "solutions of $name" {
                    foreach ($sc in @((Invoke-DemoGraph GET "$org/api/data/v9.2/solutioncomponents?`$select=_solutionid_value&`$filter=$([uri]::EscapeDataString("objectid eq $botId"))" -Token $tok).value)) {
                        $s = Get-CleanupObject "$org/api/data/v9.2/solutions($($sc._solutionid_value))?`$select=uniquename,ismanaged" $tok
                        if ($s -and -not $s.ismanaged) { [string]$s.uniquename }
                    }
                })
            }
            $sol = @($linked | Where-Object { $_ -like "$($slug)MCS*" -or $candidates -contains $_ }) | Select-Object -First 1
            if (-not $sol -and $tok) {
                foreach ($c in $candidates) {
                    $hit = Try-Read "solution $c" { @((Invoke-DemoGraph GET "$org/api/data/v9.2/solutions?`$select=uniquename,ismanaged&`$filter=$([uri]::EscapeDataString("uniquename eq '$c'"))" -Token $tok).value) | Where-Object { -not $_.ismanaged } }
                    if ($hit) { $sol = $c; break }
                }
            }
        }
        Add-Item (New-CleanupItem -Id "mcs:$($a.key)" -Name (Get-DemoAgentName -Locale $LOC -Key $a.key -Surface copilotStudio) -Type Agent -Order 4040 -Executor 'mcs' -Action 'delete-mcs-agent' -Kind 'mcs-agent' `
            -Detail "Copilot Studio agent ($($a.variant)) in environment $envId · bot $botId$(if ($sol) { " · solution $sol" })" `
            -Data ([ordered]@{ environmentId = $envId; orgUrl = [string]$org; botId = $botId; solution = [string]$sol; displayName = (Get-DemoAgentName -Locale $LOC -Key $a.key -Surface copilotStudio) }) -Origin 'state')
        $spId = [string]$rec.identityId
        $sp = if ($spId) { Try-Read "identity of $name" { Find-CleanupEntraObject servicePrincipals $spId } } else { $null }
        if ($sp) {
            $li = New-LabItem 'Agents' 'entra-sp' $sp.appId $sp.id $sp.displayName 'Copilot Studio agent identity (normally removed with the agent): deleted + purged' 'delete-sp' 22
            Add-Item (New-CleanupItem -Id (Get-LabItemId $li) -Name $sp.displayName -Type Agent -Order 4045 -Executor 'lab-cleaner' -Action 'delete-sp' -Kind 'mcs-identity' `
                -Detail "Entra agent identity of $name (verified after the agent deletion)" -Data ([ordered]@{ labItem = $li; skipIfAbsent = $true }) -DependsOn @("mcs:$($a.key)") -Origin 'state')
        }
    }
}
# Prefix-derived Copilot Studio solutions without a resolved agent (an interrupted import, an out-of-plan agent).
foreach ($envId in @(@($cfg.copilotStudio.paygEnvironmentId, $cfg.copilotStudio.defaultEnvironmentId) | Where-Object { $_ } | Select-Object -Unique)) {
    if (-not $live) { break }
    $org = Try-Read "Dataverse URL of $envId" { Get-DemoCopilotStudioOrgUrl $cfg $envId }
    if (-not $org) { continue }
    $tok = Try-Read 'Dataverse token' { Get-DemoAzToken -Resource $org -TenantId $context.tenantId }
    if (-not $tok) { continue }
    $listed = @($cp.items | Where-Object { $_.kind -eq 'mcs-agent' } | ForEach-Object { $_.data.solution })
    $sols = @(Try-Read "solutions $slug* in $envId" { @((Invoke-DemoGraph GET "$org/api/data/v9.2/solutions?`$select=uniquename,friendlyname,ismanaged&`$filter=$([uri]::EscapeDataString("startswith(uniquename,'$($slug)MCS')"))" -Token $tok).value) })
    foreach ($s in @($sols | Where-Object { -not $_.ismanaged -and $listed -notcontains $_.uniquename })) {
        Add-Item (New-CleanupItem -Id "mcs-solution:$envId/$($s.uniquename)" -Name $s.friendlyname -Type Agent -Order 4041 -Executor 'mcs' -Action 'delete-mcs-agent' -Kind 'mcs-agent' `
            -Detail "Copilot Studio solution $($s.uniquename) without a resolved agent (environment $envId)" -Data ([ordered]@{ environmentId = $envId; orgUrl = $org; botId = ''; solution = [string]$s.uniquename; displayName = '' }) -Origin 'discovery')
    }
    # Additions: agents owned by a persona in the lab's environments.
    foreach ($personaObjId in $personaIdList) {
        $su = @(Try-Read 'Dataverse user of a persona' { @((Invoke-DemoGraph GET "$org/api/data/v9.2/systemusers?`$select=systemuserid&`$filter=$([uri]::EscapeDataString("azureactivedirectoryobjectid eq $personaObjId"))" -Token $tok).value) }) | Select-Object -First 1
        if (-not $su) { continue }
        $bots = @(Try-Read 'agents owned by a persona' { @((Invoke-DemoGraph GET "$org/api/data/v9.2/bots?`$select=botid,name&`$filter=$([uri]::EscapeDataString("_ownerid_value eq $($su.systemuserid)"))" -Token $tok).value) })
        foreach ($b in $bots) {
            if (@($cp.items | Where-Object { $_.data.botId -eq $b.botid }).Count) { continue }
            Add-Item (New-CleanupItem -Id "mcs-extra:$($b.botid)" -Name $b.name -Type Agent -Order 4042 -Executor 'mcs' -Action 'delete-mcs-agent' -Kind 'mcs-agent' `
                -Detail "Copilot Studio agent owned by a lab persona, not in the pack (added by hand) · environment $envId" -Data ([ordered]@{ environmentId = $envId; orgUrl = $org; botId = [string]$b.botid; solution = ''; displayName = $b.name }) -Origin 'addition')
        }
    }
}
# Additions in the registry: agents owned by a persona, modified since the lab started, not in the pack.
$allPackages = @(Try-Read 'registry packages' { Get-DemoPackageList $cfg })
$since = $labStart.ToUniversalTime()
foreach ($pkg in @($allPackages | Where-Object { -not $knownPackages.ContainsKey([string]$_.id) -and $_.lastModifiedDateTime -and ([datetime]$_.lastModifiedDateTime).ToUniversalTime() -ge $since })) {
    $detail = Try-Read "registry package $($pkg.id)" { Get-DemoPackageDetail $cfg ([string]$pkg.id) }
    if ($detail -and $detail.ownerId -and $personaIdList -contains [string]$detail.ownerId) {
        Add-Item (New-CleanupItem -Id "registry-extra:$($pkg.id)" -Name $pkg.displayName -Type Agent -Order 4012 -Executor 'manual' -Action 'registry-delete' -Kind 'agent-builder-agent' `
            -Detail "Agent owned by a lab persona, not in the pack (added by hand) · package $($pkg.id) · type $($pkg.type)" -Data ([ordered]@{ packageIds = @([string]$pkg.id) }) `
            -Manual ([ordered]@{ where = 'Microsoft 365 admin center > Agents > All agents'; source = 'Additions by hand'; confirmAs = 'deleted'
                steps = @("Select '$($pkg.displayName)' > Delete agent.", "All agents > Deleted > select it > Permanently delete.")
                verify = 'Verified through the registry API.' }) -Origin 'addition')
        $knownPackages[[string]$pkg.id] = 'addition'
    }
}
# Third-party platforms (registry sync): the agents declared by the operator, and unclaimed candidates kept by default.
foreach ($n in $ThirdPartyAgents) {
    $hits = @($allPackages | Where-Object { $_.displayName -eq $n })
    Add-Item (New-CleanupItem -Id "third-party:$n" -Name $n -Type Agent -Order 4030 -Executor 'manual' -Action 'registry-delete' -Kind 'third-party-agent' `
        -Detail "Agent on a third-party platform (registry sync)$(if ($hits.Count) { " · package $(@($hits.id) -join ', ')" } else { ' · not found in the registry' })" `
        -Data ([ordered]@{ packageIds = @($hits | ForEach-Object { [string]$_.id }) }) `
        -Manual ([ordered]@{ where = 'The source platform, then the Microsoft 365 admin center'; source = 'Runbook: agents on third-party platforms'; confirmAs = 'deleted'
            steps = @("Delete the agent at the source: AWS agents with the AWS AI Manager (skill aws-ai-agent-delete), Google agents with the Google AI Manager (skill google-ai-agent-delete); other platforms in their own console. They use their own isolated sign-in and exact confirmation.", 'Wait for the registry sync to remove the entry; if it stays, Microsoft 365 admin center > Agents > All agents > select it > Delete agent, then Deleted > Permanently delete.', 'The AWS AI Manager keeps IAM roles, S3 objects and logs: delete them at the source if they were created only for this lab.')
            verify = 'Verified through the registry API when the entry was found.' }) -Origin 'addition')
    foreach ($h in $hits) { $knownPackages[[string]$h.id] = 'third-party' }
}
foreach ($pkg in @($allPackages | Where-Object { -not $knownPackages.ContainsKey([string]$_.id) -and [string]$_.governanceMetadata -eq 'Unmanaged' -and $_.lastModifiedDateTime -and ([datetime]$_.lastModifiedDateTime).ToUniversalTime() -ge $since })) {
    Add-Item (New-CleanupItem -Id "third-party-candidate:$($pkg.id)" -Name $pkg.displayName -Type Agent -Order 4031 -Executor 'manual' -Action 'registry-delete' -Kind 'third-party-agent' `
        -Detail "Unmanaged registry entry added since the lab started (publisher $($pkg.publisher)): possibly a third-party agent of the lab" -Data ([ordered]@{ packageIds = @([string]$pkg.id) }) `
        -Manual ([ordered]@{ where = 'The source platform, then the Microsoft 365 admin center'; source = 'Runbook: agents on third-party platforms'; confirmAs = 'deleted'
            steps = @('Delete it at the source (AWS AI Manager, Google AI Manager or the platform console).', 'If the registry entry stays: Agents > All agents > Delete agent, then Deleted > Permanently delete.'); verify = 'Verified through the registry API.' }) `
        -DefaultExcluded -Notes 'Kept by default: not provably part of this lab. Include it if you created it for this lab.' -Origin 'discovery')
}
Add-Manual -Id 'third-party:connection' -Name 'Connected-platform connections (registry sync)' -Type Configuration -Order 4035 -Kind 'tenant-setting' -Detail 'Amazon Bedrock, Google Vertex AI or other connections created for the registry sync' `
    -Where 'Microsoft 365 admin center > Agents > Connected platforms' -Steps @('Delete the connection only if it was created for this lab.', 'At the source, delete the credentials created for it (AWS IAM role or user, Google service account) if they served only this lab.') `
    -Source 'Runbook: connected platforms' -DefaultExcluded -Notes 'Kept by default: a tenant-level connection that other labs may use. Include it if it was created for this lab.'
foreach ($n in $OtherAdditions) {
    $hits = @($allPackages | Where-Object { $_.displayName -eq $n })
    $apps = @(Try-Read "Entra app $n" { @((Get-CleanupObject "$G/applications?`$filter=$([uri]::EscapeDataString("displayName eq '$($n.Replace("'", "''"))'"))&`$select=id,appId,displayName").value) })
    foreach ($h in $hits) {
        Add-Item (New-CleanupItem -Id "registry-extra:$($h.id)" -Name $h.displayName -Type Agent -Order 4012 -Executor 'manual' -Action 'registry-delete' -Kind 'agent-builder-agent' `
            -Detail "Registry entry named by the operator · package $($h.id)" -Data ([ordered]@{ packageIds = @([string]$h.id) }) `
            -Manual ([ordered]@{ where = 'Microsoft 365 admin center > Agents > All agents'; source = 'Additions by hand'; confirmAs = 'deleted'; steps = @("Select '$($h.displayName)' > Delete agent, then Deleted > Permanently delete."); verify = 'Verified through the registry API.' }) -Origin 'addition')
    }
    foreach ($a in $apps) {
        $li = New-LabItem 'Agents' 'entra-app' $a.appId $a.id $a.displayName 'Entra app named by the operator (deleted + purged)' 'delete-app' 20
        Add-Item (New-CleanupItem -Id (Get-LabItemId $li) -Name $a.displayName -Type Component -Order 5200 -Executor 'lab-cleaner' -Action 'delete-app' -Kind 'lab-entra-app' -Detail "Entra app named by the operator · appId $($a.appId)" -Data ([ordered]@{ labItem = $li }) -Origin 'addition')
    }
    if (-not $hits.Count -and -not $apps.Count) { Warn 'Addition not found' "'$n' is neither a registry entry nor an Entra application: remove it by hand." }
}
# Power Platform connections created by the personas in the lab environments (orphaned when the users go).
foreach ($envId in @(@($cfg.copilotStudio.paygEnvironmentId, $cfg.copilotStudio.defaultEnvironmentId, $ppEnv) | Where-Object { $_ } | Select-Object -Unique)) {
    if (-not $ppToken) { break }
    $conns = @(Try-Read "connections in environment $envId" { Invoke-DemoGraph GET "https://api.powerapps.com/providers/Microsoft.PowerApps/scopes/admin/environments/$envId/connections?api-version=2016-11-01" -Token $ppToken -All })
    foreach ($cn in @($conns | Where-Object { $personaIdList -contains [string]$_.properties.createdBy.id })) {
        $api = ([string]$cn.properties.apiId -split '/')[-1]
        Add-Item (New-CleanupItem -Id "pp-connection:$envId/$api/$($cn.name)" -Name "Connection of $($cn.properties.createdBy.userPrincipalName) to $api" -Type Component -Order 4515 -Executor 'powerapps' -Action 'delete-pp-connection' -Kind 'pp-connection' `
            -Detail "Power Platform connection created by a persona in environment $envId" -Data ([ordered]@{ environment = $envId; api = $api; connection = [string]$cn.name }) -Origin 'discovery')
    }
}
# Foundry prompt agent and content filter, only when the Foundry project is NOT lab-owned (a lab-owned one is purged).
$fRg = [string]$cfg.foundry.existingResourceGroup
if ($cfg.foundry.endpoint -and $fRg) {
    $labOwned = $fRg -eq "$Prefix-foundry-rg"
    if (-not $labOwned -and $live) { $tags = Try-Read "tags of $fRg" { az group show -n $fRg --subscription $context.subscriptionId --query tags -o json 2>$null | ConvertFrom-Json }; $labOwned = [string]$tags.a365lab -eq $Prefix }
    if (-not $labOwned) {
        foreach ($a in @($packDef.agents | Where-Object { [string]$_.variant -like 'FD-*' })) {
            $fa = [string]$state.agents[$a.key].foundryAgentId; if (-not $fa) { $fa = [string]$LOC.agents[$a.key].codeName }
            Add-Item (New-CleanupItem -Id "foundry-agent:$fa" -Name $fa -Type Agent -Order 4060 -Executor 'foundry' -Action 'delete-foundry-agent' -Kind 'foundry-agent' `
                -Detail "Foundry prompt agent in the reused project $($cfg.foundry.endpoint) (the project is not lab-owned: only the agent is deleted)" -Data ([ordered]@{ endpoint = [string]$cfg.foundry.endpoint; agent = $fa }) -Origin 'state' `
                -Notes 'Its knowledge files and vector stores in the reused project are not deleted automatically: remove them in the Foundry portal if they served only this lab.')
        }
        $dep = [string]$cfg.foundry.deployment
        if ($dep -and $live) {
            $d = Try-Read "deployment $dep" { az cognitiveservices account deployment show -n $cfg.foundry.account -g $fRg --deployment-name $dep --subscription $context.subscriptionId -o json 2>$null | ConvertFrom-Json }
            $rai = [string]$d.properties.raiPolicyName
            if ($rai -and $rai -notlike 'Microsoft.*') {
                Add-Item (New-CleanupItem -Id "foundry-rai:$($cfg.foundry.account)/$dep" -Name "Content filter '$rai' of deployment $dep" -Type Configuration -Order 4065 -Executor 'arm' -Action 'restore-rai-policy' -Kind 'foundry-rai' `
                    -Detail "Custom content filter on the reused Foundry account $($cfg.foundry.account): the deployment goes back to Microsoft.DefaultV2, then the custom filter is deleted" `
                    -Data ([ordered]@{ account = [string]$cfg.foundry.account; resourceGroup = $fRg; deployment = $dep; policy = $rai }) -Origin 'discovery')
            }
        }
    }
}

# ------------------------------------------------------------------------------------------------- 6. Lab Cleaner discovery
Start-Section 'Azure and Entra components and agents (Lab Cleaner discovery)'
$lcDir = Join-Path $RunDir 'lab-cleaner'
New-Item -ItemType Directory -Force -Path $lcDir | Out-Null
$labItems = @()
if ($live) {
    $disc = Join-Path $script:DemoRepoRoot '.github\skills\agent365-cleanup\scripts\Discover-CleanupResources.ps1'
    $out = Join-Path $lcDir 'discovered.json'
    # -Categories is a [string[]] with a ValidateSet: 'pwsh -File' would pass 'WebUI,CustomMcp,Agents' as ONE string, so the
    # script runs through an encoded command where the list is a real array (and no quoting can break).
    $q = { param([string]$s) "'" + $s.Replace("'", "''") + "'" }
    $cmd = "& $(& $q $disc) -Categories WebUI,CustomMcp,Agents -NameFilter $(& $q $Prefix) -McpNameFilter $(& $q $Prefix) " +
        "-Subscription $(& $q $context.subscriptionId) -TenantId $(& $q $context.tenantId) -OutFile $(& $q $out)"
    if (Test-Path -LiteralPath $context.planPath) { $cmd += " -PlanPath $(& $q $context.planPath)" }
    pwsh -NoProfile -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))) *> (Join-Path $lcDir 'discovery.log')
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $out)) { throw "Lab Cleaner discovery failed (exit $LASTEXITCODE): see $(Join-Path $lcDir 'discovery.log')." }
    $labItems = @(Get-Content -LiteralPath $out -Raw | ConvertFrom-Json)
}
$agentRgs = @($lbPlan.agents | Where-Object { $_.resourceGroup } | ForEach-Object { [string]$_.resourceGroup })
# The Lab Cleaner matches names by substring and prefix: an object tagged by ANOTHER lab, or a resource group matched only by
# its name (no lab tag, not in the plan, not '<prefix>-...'), is kept by default and shown for an explicit decision.
function Get-ForeignReason($LabItem) {
    if (-not $live) { return '' }
    $lab = ''
    switch ($LabItem.kind) {
        'azure-rg' {
            $t = Try-Read "tags of $($LabItem.id)" { az group show -n $LabItem.id --subscription $context.subscriptionId --query tags -o json 2>$null | ConvertFrom-Json }
            if ($t -and $t.a365lab) { $lab = [string]$t.a365lab }
            elseif ($agentRgs -notcontains [string]$LabItem.id -and -not ([string]$LabItem.id).StartsWith("$Prefix-", [StringComparison]::OrdinalIgnoreCase)) {
                return "Kept by default: matched by its name only (no a365lab tag, not in the lab plan). Include it only if it belongs to this lab."
            }
        }
        { $_ -in 'entra-app', 'entra-sp' } {
            $coll = if ($LabItem.kind -eq 'entra-app') { 'applications' } else { 'servicePrincipals' }
            $o = if ($LabItem.objectId) { Try-Read "tags of $($LabItem.displayName)" { Get-CleanupObject "$G/$coll/$($LabItem.objectId)?`$select=tags" } } else { $null }
            $tag = @($o.tags | Where-Object { [string]$_ -like 'a365lab:*' }) | Select-Object -First 1
            if ($tag) { $lab = ([string]$tag).Substring(8) }
        }
    }
    if ($lab -and $lab -ne $Prefix) { return "Kept by default: tagged for lab '$lab'. Include it only if that lab is gone too." }
    return ''
}
$foreignRgs = @()
foreach ($li in @($labItems | Sort-Object { if ($_.kind -eq 'azure-rg') { 0 } else { 1 } })) {
    if ($li.kind -eq 'webui-registration' -or $li.action -eq 'deregister-webui-tab') { $type = 'Component' }
    elseif ($li.kind -eq 'agent-instance') { $type = 'Agent' }
    elseif ($li.kind -in 'azure-rg', 'cognitiveservices-account', 'cognitiveservices-deleted', 'loganalytics-workspace', 'azure-swa') {
        $rg = if ($li.kind -eq 'azure-rg') { [string]$li.id } else { [string]$li.resourceGroup }
        $type = if ($agentRgs -contains $rg) { 'Agent' } else { 'Component' }
    }
    elseif ($li.category -in 'WebUI', 'CustomMcp' -or [string]$li.displayName -match '(?i)demo-automation \(temporary\)|-ui-spa$') { $type = 'Component' }
    else { $type = 'Agent' }
    $order = 5000 + [int]$li.deleteOrder * 10
    $foreign = Get-ForeignReason $li
    if ($li.kind -eq 'azure-rg' -and $foreign) { $foreignRgs += [string]$li.id }
    elseif (-not $foreign -and $li.resourceGroup -and $foreignRgs -contains [string]$li.resourceGroup) { $foreign = "Kept by default: it is inside the resource group '$($li.resourceGroup)', which is kept by default." }
    Add-Item (New-CleanupItem -Id (Get-LabItemId $li) -Name ([string]$li.displayName) -Type $type -Order $order -Executor 'lab-cleaner' -Action ([string]$li.action) -Kind "lab-$($li.kind)" `
        -Detail ([string]$li.detail) -Data ([ordered]@{ labItem = $li }) -Origin 'lab-cleaner' -DefaultExcluded:([bool]$foreign) -ExcludedReason 'shared' -Notes $foreign)
}
# Objects recorded in state.json that the Lab Cleaner scans did not return (Foundry-generated blueprints, custom names).
foreach ($a in @($packDef.agents | Where-Object { $_.platform -eq 'code' })) {
    $rec = $state.agents[$a.key]; if (-not $rec -or -not $live) { continue }
    $nm = Get-DemoAgentName -Locale $LOC -Key $a.key
    $bp = $null; foreach ($i in @($rec.blueprintId, $rec.blueprintAppId) | Where-Object { $_ } | Select-Object -Unique) { if (-not $bp) { $bp = Try-Read "blueprint of $nm" { Find-CleanupEntraObject applications $i } } }
    if ($bp -and -not (Test-HasLabObject $bp.id $bp.appId)) {
        $li = New-LabItem 'Agents' 'entra-app' $bp.appId $bp.id $bp.displayName 'Agent blueprint recorded by the build (deleted + purged)' 'delete-app' 20
        Add-Item (New-CleanupItem -Id (Get-LabItemId $li) -Name $bp.displayName -Type Agent -Order 5200 -Executor 'lab-cleaner' -Action 'delete-app' -Kind 'lab-entra-app' -Detail "Blueprint of $nm (recorded in state.json)" -Data ([ordered]@{ labItem = $li }) -Origin 'state')
    }
    $idents = @(@($rec.identityId, $rec.identityAppId) + @($rec.instanceIdentityIds) | Where-Object { $_ } | Select-Object -Unique)
    $seenSp = @{}
    foreach ($i in $idents) {
        $sp = Try-Read "identity of $nm" { Find-CleanupEntraObject servicePrincipals $i }
        if (-not $sp -or $seenSp.ContainsKey($sp.id)) { continue }
        $seenSp[$sp.id] = $true
        if (Test-HasLabObject $sp.id $sp.appId) { continue }
        $li = New-LabItem 'Agents' 'entra-sp' $sp.appId $sp.id $sp.displayName 'Agent identity recorded by the build (deleted + purged)' 'delete-sp' 22
        Add-Item (New-CleanupItem -Id (Get-LabItemId $li) -Name $sp.displayName -Type Agent -Order 5220 -Executor 'lab-cleaner' -Action 'delete-sp' -Kind 'lab-entra-sp' -Detail "Agent identity of $nm (recorded in state.json)" -Data ([ordered]@{ labItem = $li }) -Origin 'state')
    }
    foreach ($uid in @($rec.instanceUserId, $rec.liveInstanceUserId) | Where-Object { $_ }) {
        if (Test-HasLabObject $uid '') { continue }
        $u = Try-Read 'agent instance user' { Get-CleanupObject "$G/users/$uid`?`$select=id,displayName,userPrincipalName,assignedLicenses" }
        if (-not $u) { continue }
        $li = New-LabItem 'Agents' 'agent-instance' $u.id $u.id $u.displayName "UPN $($u.userPrincipalName) (recorded in state.json)" 'remove-licenses-and-delete-user' 10 @{ userPrincipalName = $u.userPrincipalName }
        Add-Item (New-CleanupItem -Id (Get-LabItemId $li) -Name $u.displayName -Type Agent -Order 5100 -Executor 'lab-cleaner' -Action 'remove-licenses-and-delete-user' -Kind 'lab-agent-instance' -Detail "Agent instance user $($u.userPrincipalName)" -Data ([ordered]@{ labItem = $li }) -Origin 'state')
    }
    foreach ($pair in @(@{ id = $rec.projectBlueprintId; c = 'applications'; k = 'entra-app'; a = 'delete-app'; o = 20 }, @{ id = $rec.projectIdentityId; c = 'servicePrincipals'; k = 'entra-sp'; a = 'delete-sp'; o = 22 })) {
        if (-not $pair.id) { continue }
        $obj = Try-Read 'Foundry project identity' { Find-CleanupEntraObject $pair.c $pair.id }
        if (-not $obj -or (Test-HasLabObject $obj.id $obj.appId)) { continue }
        $li = New-LabItem 'Agents' $pair.k $obj.appId $obj.id $obj.displayName 'Foundry project identity (normally removed with the Foundry project; deleted here if it remains)' $pair.a $pair.o
        Add-Item (New-CleanupItem -Id (Get-LabItemId $li) -Name $obj.displayName -Type Component -Order 8010 -Executor 'lab-cleaner' -Action $pair.a -Kind "lab-$($pair.k)" -Detail 'Foundry project identity, checked after the Foundry resource group is gone' -Data ([ordered]@{ labItem = $li; skipIfAbsent = $true }) -Origin 'state')
    }
}
# Agent users managed by a persona that are not instances of a lab blueprint (created by hand from other templates).
foreach ($personaObjId in $personaIdList) {
    $reports = @(Try-Read 'direct reports of a persona' { @(Invoke-DemoGraph GET "https://graph.microsoft.com/beta/users/$personaObjId/directReports?`$select=id,displayName,userPrincipalName" -All) })
    foreach ($r in @($reports | Where-Object { $_.'@odata.type' -match 'agentUser' -or $_.userPrincipalName })) {
        if ($personaIdList -contains [string]$r.id -or (Test-HasLabObject $r.id '')) { continue }
        $full = Try-Read 'agent user' { Get-CleanupObject "https://graph.microsoft.com/beta/users/$($r.id)?`$select=id,displayName,userPrincipalName,identityParentId" }
        if (-not $full -or -not $full.identityParentId) { continue }
        $li = New-LabItem 'Agents' 'agent-instance' $full.id $full.id $full.displayName "UPN $($full.userPrincipalName) | managed by a lab persona" 'remove-licenses-and-delete-user' 10 @{ userPrincipalName = $full.userPrincipalName }
        Add-Item (New-CleanupItem -Id (Get-LabItemId $li) -Name $full.displayName -Type Agent -Order 5100 -Executor 'lab-cleaner' -Action 'remove-licenses-and-delete-user' -Kind 'lab-agent-instance' -Detail "Agent instance managed by a lab persona (added by hand) · $($full.userPrincipalName)" -Data ([ordered]@{ labItem = $li }) -Origin 'addition')
    }
}
# Direct application permissions granted to agent identities (removed with the identity).
foreach ($k in @($state.governance.identities.Keys)) {
    foreach ($row in @($state.governance.identities[$k])) {
        foreach ($prop in @($row.Keys | Where-Object { $_ -like 'appRole:*' })) {
            $cover = @($cp.items | Where-Object { $_.data.labItem -and ($_.data.labItem.objectId -eq $row.identityId -or $_.data.labItem.id -eq $row.identityId) }) | Select-Object -First 1
            if (-not $cover) { continue }
            Add-Item (New-CleanupItem -Id "app-role:$($row.identityId)/$prop" -Name "$($prop.Substring(8)) application permission of $($row.displayName)" -Type Configuration -Order ([int]$cover.order + 1) `
                -Executor 'covered' -Action 'covered' -Kind 'app-role' -Detail 'Direct application permission granted by the build' -CoveredBy $cover.id -Origin 'state' `
                -Notes "Removed together with the agent identity '$($cover.name)'.")
        }
    }
}

# ------------------------------------------------------------------------------------------------- 7. users and groups
Start-Section 'Users and groups'
$labTag = "a365lab:$Prefix"
foreach ($p in $packDef.personas) {
    $e = $userItems[$p.key]; $u = $e.user
    $nm = Get-DemoPersonaDisplayName $LOC $p.key
    if ($u -or -not $live) {
        $tag = [string]$u.onPremisesExtensionAttributes.extensionAttribute15
        $lic = @($u.assignedLicenses).Count
        $li = New-LabItem 'Agents' 'agent-instance' $(if ($u) { $u.id } else { $e.upn }) $(if ($u) { $u.id } else { $null }) $nm "UPN $($e.upn)" 'remove-licenses-and-delete-user' 10 @{ userPrincipalName = $e.upn }
        $shared = $tag -and $tag -ne $labTag
        Add-Item (New-CleanupItem -Id "user:$($p.key)" -Name $nm -Type User -Order 6010 -Executor 'lab-cleaner' -Action 'remove-licenses-and-delete-user' -Kind 'persona-user' `
            -Detail "$($e.upn) · persona $($p.key)$(if ($p.leaver) { ' (leaver)' }) · $lic license(s)$(if ($u.mail) { ' · mailbox' })" `
            -Data ([ordered]@{ labItem = $li; upn = $e.upn; hasMailbox = [bool]$u.mail }) -Origin 'state' `
            -DefaultExcluded:$shared -ExcludedReason 'shared' -Notes $(if ($shared) { "Kept by default: tagged '$tag' by another lab (same language and domain). Include it only if that lab is gone too." } else { 'Licenses removed explicitly, then deleted and purged from the recycle bin (no soft-deleted copy left).' }))
        continue
    }
    $rid = [string]$e.record.id
    if ($rid) {
        $d = Try-Read "recycle bin entry of $nm" { Get-CleanupObject "$G/directory/deletedItems/$rid" }
        if ($d) {
            $li = New-LabItem 'Agents' 'deleted-user' $rid $rid $nm 'Soft-deleted user (recycle bin): permanently purged' 'purge-deleted-item' 24
            Add-Item (New-CleanupItem -Id "deleted-user:$rid" -Name $nm -Type User -Order 6030 -Executor 'lab-cleaner' -Action 'purge-deleted-item' -Kind 'deleted-user' -Detail "$($e.upn) in the Entra recycle bin" -Data ([ordered]@{ labItem = $li; upn = $e.upn }) -Origin 'state')
        }
    }
}
$tagged = @(Try-Read 'users tagged with the lab' { @(Invoke-DemoGraph GET "$G/users?`$filter=$([uri]::EscapeDataString("onPremisesExtensionAttributes/extensionAttribute15 eq '$labTag'"))&`$count=true&`$select=id,displayName,userPrincipalName,mail,assignedLicenses" -Headers @{ ConsistencyLevel = 'eventual' } -All) })
foreach ($u in @($tagged | Where-Object { $personaIdList -notcontains [string]$_.id })) {
    $li = New-LabItem 'Agents' 'agent-instance' $u.id $u.id $u.displayName "UPN $($u.userPrincipalName)" 'remove-licenses-and-delete-user' 10 @{ userPrincipalName = $u.userPrincipalName }
    Add-Item (New-CleanupItem -Id "user-extra:$($u.id)" -Name $u.displayName -Type User -Order 6020 -Executor 'lab-cleaner' -Action 'remove-licenses-and-delete-user' -Kind 'tagged-user' `
        -Detail "$($u.userPrincipalName) · tagged $labTag but not a persona of the pack (added later)" -Data ([ordered]@{ labItem = $li; upn = $u.userPrincipalName; hasMailbox = [bool]$u.mail }) -Origin 'addition')
}
$groupItems = @{}
$deletedGroups = @(Try-Read 'deleted groups' { @(Invoke-DemoGraph GET "$G/directory/deletedItems/microsoft.graph.group?`$select=id,displayName,mailNickname" -All) })
foreach ($gd in $packDef.groups) {
    $lg = $LOC.groups[$gd.key]; $rec = $state.groups[$gd.key]
    $grp = Try-Read "group $($lg.displayName)" {
        $x = if ($rec.id) { Get-CleanupObject "$G/groups/$($rec.id)?`$select=id,displayName,mailNickname,groupTypes" } else { $null }
        if (-not $x) { $x = @((Get-CleanupObject "$G/groups?`$filter=$([uri]::EscapeDataString("mailNickname eq '$($lg.mailNickname)'"))&`$select=id,displayName,mailNickname,groupTypes").value) | Select-Object -First 1 }
        $x
    }
    if ($grp -or -not $live) {
        $ext = if ($grp) { Try-Read 'group lab extension' { Get-CleanupObject "$G/groups/$($grp.id)/extensions/com.a365lab.lab" } } else { $null }
        $shared = $ext -and $ext.lab -and [string]$ext.lab -ne $Prefix
        $gid = if ($grp) { [string]$grp.id } else { [string]$rec.id }
        $groupItems[$gd.key] = "group:$($gd.key)"
        $deps = @(if ($gd.key -eq 'directoryReaders') { @($cp.items | Where-Object { $_.kind -eq 'catalog' } | ForEach-Object { $_.id }) })
        Add-Item (New-CleanupItem -Id "group:$($gd.key)" -Name $(if ($grp) { $grp.displayName } else { $lg.displayName }) -Type Group -Order 6210 -Executor 'graph' -Action 'delete-group' -Kind 'group' `
            -Detail "$($gd.kind) group · mail nickname $($lg.mailNickname)$(if ($gd.kind -eq 'm365') { ' · with its SharePoint site and mailbox' })" -Data ([ordered]@{ id = $gid; kind = [string]$gd.kind; mailNickname = [string]$lg.mailNickname }) `
            -DependsOn $deps -Origin 'state' -DefaultExcluded:$shared -ExcludedReason 'shared' `
            -Notes $(if ($shared) { "Kept by default: it belongs to lab '$($ext.lab)' as well. Include it only if that lab is gone too." } elseif ($gd.kind -eq 'm365') { 'Deleted, then purged from the recycle bin (a Microsoft 365 group is otherwise recoverable for 30 days).' } else { '' }))
    }
    foreach ($dg in @($deletedGroups | Where-Object { ($rec.id -and $_.id -eq $rec.id) -or $_.mailNickname -eq $lg.mailNickname })) {
        if ($grp -and $dg.id -eq $grp.id) { continue }
        $li = New-LabItem 'Agents' 'deleted-group' $dg.id $dg.id $dg.displayName 'Soft-deleted group (recycle bin): permanently purged' 'purge-deleted-item' 24
        Add-Item (New-CleanupItem -Id "deleted-group:$($dg.id)" -Name $dg.displayName -Type Group -Order 6230 -Executor 'lab-cleaner' -Action 'purge-deleted-item' -Kind 'deleted-group' -Detail 'Microsoft 365 group in the Entra recycle bin' -Data ([ordered]@{ labItem = $li }) -Origin 'discovery')
    }
}
foreach ($personaObjId in $personaIdList) {
    $owned = @(Try-Read 'groups owned by a persona' { @(Invoke-DemoGraph GET "$G/users/$personaObjId/ownedObjects/microsoft.graph.group?`$select=id,displayName,mailNickname,groupTypes" -All) })
    foreach ($og in $owned) {
        if (@($cp.items | Where-Object { $_.kind -eq 'group' -and $_.data.id -eq $og.id }).Count) { continue }
        Add-Item (New-CleanupItem -Id "group-extra:$($og.id)" -Name $og.displayName -Type Group -Order 6220 -Executor 'graph' -Action 'delete-group' -Kind 'group' `
            -Detail "Group owned by a lab persona, not in the pack (added by hand) · $($og.mailNickname)" -Data ([ordered]@{ id = [string]$og.id; kind = $(if (@($og.groupTypes) -contains 'Unified') { 'm365' } else { 'security' }); mailNickname = [string]$og.mailNickname }) -Origin 'addition')
    }
}

# ------------------------------------------------------------------------------------------------- 8. resources
Start-Section 'Resources: SharePoint, OneDrive, mailboxes'
$siteUrl = ''
if ($state.knowledge.libraryUrl) { $siteUrl = ([string]$state.knowledge.libraryUrl -replace '/[^/]+$', '') }
if ($live -and $groupItems['site']) {
    $gi = Get-CleanupItem $cp $groupItems['site']
    $root = Try-Read 'knowledge site' { Get-CleanupObject "$G/groups/$($gi.data.id)/sites/root?`$select=webUrl" (Get-CleanupGraphToken $cfg) }
    if ($root.webUrl) { $siteUrl = [string]$root.webUrl }
}
if ($siteUrl -and $groupItems['site']) {
    Add-Item (New-CleanupItem -Id 'sharepoint:site' -Name $siteUrl -Type Resource -Order 6211 -Executor 'covered' -Action 'covered' -Kind 'sharepoint-site' `
        -Detail "SharePoint site of the knowledge ($($state.knowledge.files) file(s) in $(@($state.knowledge.folders.Keys).Count) folder(s), incl. the labeled confidential document)" -CoveredBy $groupItems['site'] -Origin 'state' `
        -Notes 'Deleted with its Microsoft 365 group; the site then sits in the SharePoint recycle bin until the permanent deletion below.')
    Add-Item (New-CleanupItem -Id 'sharepoint:deleted-site' -Name "$siteUrl (SharePoint recycle bin)" -Type Resource -Order 8060 -Executor 'spo' -Action 'purge-deleted-site' -Kind 'sharepoint-deleted-site' `
        -Detail 'Permanent deletion of the deleted knowledge site (otherwise kept 93 days and its URL stays taken)' -Data ([ordered]@{ url = $siteUrl }) -DependsOn @($groupItems['site']) -Origin 'state' `
        -Manual ([ordered]@{ where = 'SharePoint Online Management Shell (a group-connected site cannot be purged from the admin center UI)'; source = 'Hard deletion'; confirmAs = 'deleted'
            steps = @("Connect-SPOService -Url https://<tenant>-admin.sharepoint.com (interactive sign-in)", "Remove-SPODeletedSite -Identity $siteUrl -NoWait", "If it says the site is still connected to a group: Set-SPOSite -Identity $siteUrl -ClearGroupId, then Remove-SPOSite and Remove-SPODeletedSite.")
            verify = 'Used only when the automatic purge through the SharePoint admin API is refused.' }))
}
foreach ($ui in @($cp.items | Where-Object { $_.kind -in 'persona-user', 'tagged-user', 'lab-agent-instance' })) {
    $uid = [string]$ui.data.labItem.objectId
    if ($live -and $uid) {
        $drive = Try-Read "OneDrive of $($ui.name)" { Get-CleanupObject "$G/users/$uid/drive?`$select=webUrl" (Get-CleanupGraphToken $cfg) }
        if ($drive.webUrl) {
            $url = ([string]$drive.webUrl -replace '/Documents$', '')
            Add-Item (New-CleanupItem -Id "onedrive:$uid" -Name "OneDrive of $($ui.name)" -Type Resource -Order 8070 -Executor 'spo' -Action 'purge-onedrive' -Kind 'onedrive' `
                -Detail "$url (retained after the user deletion; for the program lead it holds the personal knowledge file)" -Data ([ordered]@{ url = $url }) -DependsOn @($ui.id) -Origin 'discovery' `
                -Manual ([ordered]@{ where = 'SharePoint Online Management Shell'; source = 'Hard deletion'; confirmAs = 'deleted'
                    steps = @('Connect-SPOService -Url https://<tenant>-admin.sharepoint.com', "Remove-SPOSite -Identity $url -NoWait", "Remove-SPODeletedSite -Identity $url -NoWait")
                    verify = 'Used only when the automatic purge through the SharePoint admin API is refused.' }))
        }
    }
    if ($ui.data.hasMailbox -or $ui.kind -eq 'lab-agent-instance') {
        Add-Item (New-CleanupItem -Id "mailbox:$($ui.id)" -Name "Mailbox of $($ui.name)" -Type Resource -Order 8050 -Executor 'exo' -Action 'purge-soft-deleted-mailbox' -Kind 'mailbox' `
            -Detail "$($ui.data.labItem.userPrincipalName): Exchange keeps it soft-deleted for 30 days after the user purge" -Data ([ordered]@{ upn = [string]$ui.data.labItem.userPrincipalName }) -DependsOn @($ui.id) -Origin 'discovery' `
            -Manual ([ordered]@{ where = 'Exchange Online PowerShell'; source = 'Hard deletion'; confirmAs = 'deleted'
                steps = @('Connect-ExchangeOnline (interactive sign-in)', "Get-Mailbox -SoftDeletedMailbox -Identity $($ui.data.labItem.userPrincipalName) | Remove-Mailbox -PermanentlyDelete -Confirm:`$false", 'A mailbox on hold is inactive instead: remove the hold, then repeat.')
                verify = 'Used only when the ExchangeOnlineManagement module is not available.' }))
    }
}

# ------------------------------------------------------------------------------------------------- 9. tenant configuration
Start-Section 'Tenant configuration (custom security attribute, roles, environments)'
$setId = [string]$gov.attributeSet.id; $attrName = [string]$gov.attribute.name; $defId = "${setId}_$attrName"
$def = if ($live) { Try-Read "custom security attribute $defId" { Get-CleanupObject "$G/directory/customSecurityAttributeDefinitions/$defId" (Get-CleanupGraphToken $cfg) } } else { [pscustomobject]@{ id = $defId; status = 'not verified' } }
if ($def) {
    $vals = @($packDef.governance.attribute.values | ForEach-Object { [string]$gov.attribute.values[$_] } | Where-Object { $_ })
    if (-not $vals.Count -and $state.governance.attribute.values) { $vals = @($state.governance.attribute.values) }
    Add-Item (New-CleanupItem -Id 'csa:values' -Name "$setId / $attrName values: $($vals -join ', ')" -Type Configuration -Order 7010 -Executor 'graph' -Action 'deactivate-csa-values' -Kind 'csa-values' `
        -Detail 'Allowed values of the custom security attribute' -Data ([ordered]@{ definition = $defId; values = $vals }) -DependsOn $caItems -Origin 'state' `
        -Limitation 'Custom security attribute values cannot be deleted: they are deactivated.')
    Add-Item (New-CleanupItem -Id 'csa:definition' -Name "$setId / $attrName" -Type Configuration -Order 7020 -Executor 'graph' -Action 'deactivate-csa-definition' -Kind 'csa-definition' `
        -Detail "Custom security attribute definition (status $($def.status))" -Data ([ordered]@{ definition = $defId }) -DependsOn (@('csa:values') + $caItems) -Origin 'state' `
        -Limitation 'Custom security attribute definitions cannot be deleted: it is deactivated.')
    Add-Item (New-CleanupItem -Id 'csa:set' -Name $setId -Type Configuration -Order 7030 -Executor 'record-only' -Action 'record-only' -Kind 'csa-set' `
        -Detail 'Attribute set of the custom security attribute' -Origin 'state' -Limitation 'Attribute sets can be neither deleted nor deactivated: the set stays (the next build in this tenant reuses it).')
}
if ($live -and $context.adminUpn) {
    $op = Try-Read "operator $($context.adminUpn)" { Get-CleanupObject "$G/users/$([uri]::EscapeDataString($context.adminUpn))?`$select=id,userPrincipalName" }
    if ($op) {
        $defs = @(Try-Read 'directory role definitions' { Get-DemoEntraRoleDefinitions })
        foreach ($rn in $script:DemoOperatorEntraRoles) {
            $rd = @($defs | Where-Object displayName -eq $rn) | Select-Object -First 1
            if (-not $rd) { continue }
            $as = @(Try-Read "role $rn of the operator" { @((Get-CleanupObject "$G/roleManagement/directory/roleAssignments?`$filter=$([uri]::EscapeDataString("principalId eq '$($op.id)' and roleDefinitionId eq '$($rd.id)'"))").value) })
            foreach ($ra in $as) {
                Add-Item (New-CleanupItem -Id "operator-role:$($ra.id)" -Name "$rn of $($context.adminUpn)" -Type Configuration -Order 7040 -Executor 'graph' -Action 'delete-role-assignment' -Kind 'operator-role' `
                    -Detail "Directory role assignment (scope $($ra.directoryScopeId)) that the build adds to the operator when it is missing" -Data ([ordered]@{ id = [string]$ra.id }) -DependsOn @('csa:values', 'csa:definition') -Origin 'state' `
                    -DefaultExcluded -Notes 'Kept by default: the build does not record whether the operator already had this role before. Include it only if the operator did not have it before the build.')
            }
        }
    }
}
if ($state.agents.faqPrototype.botId -or @($cp.items | Where-Object { $_.id -eq 'mcs:faqPrototype' }).Count) {
    Add-Manual -Id 'pp:auth-setting' -Name "'Authentication for agents' setting of the default environment" -Type Configuration -Order 7050 -Kind 'tenant-setting' -Detail 'Relaxed only for the legacy prototype' `
        -Where 'Power Platform admin center > Security > Identity and access > Authentication for agents' -Steps @('Restore the value it had before the demo (only if it was relaxed for the legacy prototype).') -Source 'Pack README: teardown'
}
if ($cfg.copilotStudio.paygEnvironmentId) {
    Add-Manual -Id 'pp:payg-environment' -Name "Pay-as-you-go Copilot Studio environment $($cfg.copilotStudio.paygEnvironmentId)" -Type Configuration -Order 7060 -Kind 'tenant-setting' -Detail 'Prerequisite of the build, not created by it' `
        -Where 'Power Platform admin center > Manage > Environments' -Steps @('Delete the environment only if it was created only for this lab and no other agent uses it; then remove its billing policy if nothing else uses it.') `
        -Source 'Prerequisites' -DefaultExcluded -Notes 'Kept by default: a prerequisite that other labs may use. Include it only if it was created for this lab.'
}

# ------------------------------------------------------------------------------------------------- 10. sweeps and local
Start-Section 'Final checks and local files'
foreach ($rv in $registryVerify) {
    Add-Item (New-CleanupItem -Id "registry:$($rv.key)" -Name "Registry entry of $($rv.name)" -Type Agent -Order 8030 -Executor 'registry-verify' -Action 'registry-verify' -Kind 'registry-package' `
        -Detail "Agent 365 registry packages $($rv.ids -join ', ') (normally removed with the agent)" -Data ([ordered]@{ packageIds = @($rv.ids) }) -Origin 'state' `
        -Manual ([ordered]@{ where = 'Microsoft 365 admin center > Agents > All agents'; source = 'Hard deletion'; confirmAs = 'deleted'
            steps = @("Only if '$($rv.name)' is still listed: select it > Delete agent (every entry, shared and published).", "All agents > Deleted > select it > Permanently delete.")
            verify = 'Verified through the registry API: every package must be gone.' }))
}
$knownIds = @(@($personaIds.Values) + @($cp.items | ForEach-Object { $_.data.labItem.objectId; if ($_.kind -eq 'group') { $_.data.id } }) +
    @($state.agents.Values | ForEach-Object { $_.identityId; $_.blueprintId; $_.blueprintPrincipalId; $_.projectIdentityId; $_.projectBlueprintId; $_.instanceUserId; @($_.instanceIdentityIds) }) |
    Where-Object { [string]$_ -match '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' } | Select-Object -Unique)
Add-Item (New-CleanupItem -Id 'sweep:entra' -Name 'Entra recycle bin sweep' -Type Component -Order 8040 -Executor 'graph' -Action 'entra-sweep' -Kind 'entra-sweep' `
    -Detail "Permanent purge of any lab object left soft-deleted (also those the platforms delete themselves: $($knownIds.Count) known ids)" -Data ([ordered]@{ ids = $knownIds }) -Origin 'state')
if (Test-Path -LiteralPath $labRoot) {
    $extra = @(Get-ChildItem -LiteralPath (Join-Path $script:DemoRepoRoot 'generated\copilot-studio') -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$($slug)MCS*" -or $_.Name -like "mcp-client-$($slug)MCS*" } | ForEach-Object { $_.FullName })
    Add-Item (New-CleanupItem -Id 'local:lab-folder' -Name "generated\$Prefix" -Type Resource -Order 9010 -Executor 'local' -Action 'delete-local-folder' -Kind 'local-folder' `
        -Detail "Local lab folder: state, plan, scaffolding, persona passwords, MSAL caches, operator slots$(if ($extra.Count) { "; plus $($extra.Count) Copilot Studio file(s) in generated\copilot-studio" })" `
        -Data ([ordered]@{ path = $labRoot; extraFiles = $extra }) -Origin 'state' -Notes 'Deleted last, only when nothing else is left to retry (the retries need its state and caches).')
}

# ------------------------------------------------------------------------------------------------- runbook coverage
$rb = [System.Collections.Generic.List[object]]::new()
Update-CleanupIndexes $cp
function Ref([string[]]$Kinds, [string]$Fallback) {
    $hits = @($cp.items | Where-Object { $_.kind -in $Kinds })
    if ($hits.Count) { return "Items $(@($hits | ForEach-Object { "#$($_.index)" }) -join ', ')" }
    return $Fallback
}
$cardMap = [ordered]@{
    'card-10-copilot-studio' = @('Copilot Studio agents completed in the portal (knowledge, instructions, publication, org-catalog requests)', (Ref @('mcs-agent', 'mcs-identity', 'registry-package') 'Nothing found to delete'))
    'card-11-agent-builder' = @('Agent Builder agents and their custom skill, created by the personas', (Ref @('agent-builder-agent', 'agent-skill') 'Nothing found in the registry'))
    'card-15-foundry' = @('Foundry prompt agent checked and published', (Ref @('foundry-agent', 'foundry-rai', 'registry-package') 'Removed with the lab-owned Foundry project (Lab Cleaner items)'))
    'card-20-digital-worker' = @('Digital Worker template licenses and the instances created from Teams', (Ref @('lab-agent-instance') 'No instance found'))
    'card-30-entra' = @('Conditional Access policies and the access package', (Ref @('ca-policy', 'access-package', 'catalog') 'Nothing found'))
    'card-40-purview' = @('Purview role groups, DSPM, audit retention and searches, label, DLP, Communication Compliance, eDiscovery', (Ref @('scc-policy', 'sensitivity-label', 'label-policy', 'audit-search', 'ediscovery-case') 'Nothing found'))
    'card-50-defender' = @('Defender connectors, hunting queries, incident evidence', (Ref @('hunting-query', 'defender-evidence', 'tenant-setting') 'Nothing found'))
    'card-60-admin-center' = @('Templates, tags, approvals, installs, blocks and automation rules', (Ref @('admin-center-object', 'registry-package') 'Nothing found'))
}
foreach ($k in $cardMap.Keys) { $rb.Add([ordered]@{ source = "Guided card $($k.Substring(5))"; action = $cardMap[$k][0]; rollback = $cardMap[$k][1] }) }
$register = if (Test-Path -LiteralPath (Get-DemoUserActionsPath $Prefix)) { Read-DemoUserActions $Prefix } else { @{ actions = @() } }
foreach ($a in @($register.actions)) {
    $key = [string]$a.key
    if ($key -like 'step:*/card-*') { continue }
    $roll = switch -Wildcard ($key) {
        'step:bootstrap/first-signin' { 'Nothing to delete: sign-ins only (the persona accounts are deleted with the users).' }
        'purview-roles-*' { 'Removed with the persona user (role-group membership).' }
        'knowledge-personal-*' { Ref @('onedrive') 'Removed with the OneDrive of the program lead.' }
        'mcp-approve' { Ref @('mcp-server') 'No demo MCP server recorded.' }
        'mcp-connections' { Ref @('pp-connection') 'No connection found.' }
        'agent-smoke-tests' { 'Nothing to delete: test traffic only (audit records remain by design).' }
        'agent365-lab-tag' { Ref @('admin-center-object') 'Lab-name tag item.' }
        'prepared-instance-*' { Ref @('lab-agent-instance') 'No instance found.' }
        'step:interactive/leaver-*' { 'The temporary leavers are persona users: deleted and purged with the users.' }
        'step:interactive/tests' { 'Nothing to delete: test traffic only.' }
        default { 'No automatic mapping: review this action and remove what it created by hand (or name it with -OtherAdditions).' }
    }
    $rb.Add([ordered]@{ source = "User action $($a.id) ($([string]$a.status))"; action = [string]$a.action; rollback = $roll })
}
$rb.Add([ordered]@{ source = 'Runbook: third-party platforms'; action = 'Agents created on AWS, Google or other platforms and synchronized into the registry';
    rollback = (Ref @('third-party-agent') 'None declared. If you created any, run the discovery again with -ThirdPartyAgents "<name>,<name>".') })
$outside = Join-Path $labDir 'outside-plan.json'
if (Test-Path -LiteralPath $outside) {
    foreach ($o in @(Get-Content -LiteralPath $outside -Raw | ConvertFrom-Json)) {
        if ($o.key) { $rb.Add([ordered]@{ source = 'Outside the lab plan'; action = "Agent $($o.displayName) created with the command of outside-plan.json"; rollback = (Ref @('mcs-agent') 'Not found: nothing to delete.') }) }
    }
}
$cp['runbook'] = @($rb)
# Same local content exclusions as the Demo Builder inventory, applied to these free-text rows before any renderer.
. (Join-Path $builder '_demo-inventory.ps1')
$probe = [ordered]@{ sections = @([ordered]@{ rows = @($rb | ForEach-Object { , @([string]$_.source, [string]$_.action, [string]$_.rollback) }) }) }
$probe = Remove-DemoInventoryExcludedRows $probe
$cp['runbook'] = @(@($probe.sections[0].rows) | ForEach-Object { [ordered]@{ source = $_[0]; action = $_[1]; rollback = $_[2] } })

# ------------------------------------------------------------------------------------------------- done
$null = Resolve-CleanupClosure $cp
$null = Update-CleanupSummary $cp
$cp['summary'] = $null
$cp.discovery.finishedAt = (Get-Date).ToString('o')
$cp.discovery.section = 'finished'
$cp['phase'] = $(if ($SnapshotOnly) { 'snapshot' } else { 'review' })
Save-CleanupPlan $cp
$st = Get-CleanupStats $cp
Write-CleanupLog $RunDir ("Discovery finished: {0} element(s), {1} to delete, {2} kept by default, {3} manual action(s), {4} warning(s)" -f $st.total, $st.toDelete, $st.excluded, @($cp.items | Where-Object { $_.executor -eq 'manual' -and $_.status -eq 'toDelete' }).Count, @($cp.warnings).Count) 'OK'
Write-Host "REPORT: $(Get-CleanupReportUri $RunDir)"
