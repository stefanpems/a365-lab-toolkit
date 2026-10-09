#requires -Version 7.0
<#
.SYNOPSIS
  Runs the phases of a demo lab in order, with progress kept in state.json, so that a build can be paused and resumed:
    bootstrap    people and foundations: license gate, pack/locale check, users, roles, licenses, managers, groups, photos
    setup        automated setup: knowledge, demo MCP backends and registrations, agents (Lab Builder), governance, hand-outs
    interactive  user interaction: registrations run in a terminal, approvals, per-user connections, the portal cards, tests
    use          running the demo: outside this agent (agent365-demo-guide)
    restore      starting conditions again after a rehearsal or a run (agent365-demo-reset), users recreated when needed
    teardown     removal of the lab (Lab Cleaner + the extras listed in the pack README)
.DESCRIPTION
  DRY RUN unless -Apply: each automated step runs its script in preview mode (-WhatIf / -ValidateOnly / Status) and nothing
  is marked done. With -Apply the automated steps run for real and are marked done when they succeed. Manual and terminal
  steps print what to do; mark them with -Done <step id> once the user confirms. -Phase status shows every phase.
.EXAMPLE
  pwsh -File .\Invoke-DemoPhase.ps1 -Prefix cts2 -Phase bootstrap
.EXAMPLE
  pwsh -File .\Invoke-DemoPhase.ps1 -Prefix cts2 -Phase setup -Apply -From governance
.EXAMPLE
  pwsh -File .\Invoke-DemoPhase.ps1 -Prefix cts2 -Phase interactive -Done card-30-entra
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)][string]$Prefix,
    [ValidateSet('status', 'report', 'bootstrap', 'setup', 'interactive', 'use', 'restore', 'teardown')][string]$Phase = 'status',
    [switch]$SnapshotOnly,
    [switch]$Apply,
    [string]$From,
    [string]$Only,
    [string]$Done
)
$ErrorActionPreference = 'Stop'
if ($Phase -eq 'report') {
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Get-DemoInventory.ps1') -Prefix $Prefix -SnapshotOnly:$SnapshotOnly
    exit $LASTEXITCODE
}
if ($SnapshotOnly) { throw '-SnapshotOnly is valid only with -Phase report.' }
. (Join-Path $PSScriptRoot '_demo-common.ps1')
$cfg = Read-DemoConfig $Prefix
$pack = Get-DemoPack $cfg.pack
$reset = Join-Path $PSScriptRoot '..\..\agent365-demo-reset\scripts'
$guide = Join-Path $PSScriptRoot '..\..\agent365-demo-guide\scripts'
$labDir = Get-DemoLabDir $Prefix
$slotsFile = Join-Path $labDir 'operator-slots.json'

# Step: phase, id, title, kind (auto = script; terminal = command the operator runs; manual = portal/persona action;
# agent = continue in the Lab Builder), script + arguments for -Apply and for the dry run (null = same as -Apply).
function New-Step([string]$Ph, [string]$Id, [string]$Title, [string]$Kind, [string]$Script, [object[]]$ApplyArgs, [object[]]$DryArgs, [string]$Hint) {
    [pscustomobject]@{ phase = $Ph; id = $Id; title = $Title; kind = $Kind; script = $Script; applyArgs = $ApplyArgs; dryArgs = $DryArgs; hint = $Hint }
}
$P = @('-Prefix', $Prefix)
$steps = [System.Collections.Generic.List[object]]::new()
# --- bootstrap ---
$steps.Add((New-Step 'bootstrap' 'prereqs' 'License gate and prerequisites (read-only)' 'auto' (Join-Path $PSScriptRoot 'Test-DemoPrereqs.ps1') $P $P 'fix every failed check (docs/demo-environment-prerequisites.md) before going on'))
$packArgs = @('-Pack', $cfg.pack, '-Locale', $cfg.locale) + $(if (Test-Path -LiteralPath $slotsFile) { @('-OperatorSlots', $slotsFile) } else { @() })
$steps.Add((New-Step 'bootstrap' 'pack' 'Pack and locale check (dictionary, iron rules)' 'auto' (Join-Path $PSScriptRoot 'Test-DemoPack.ps1') $packArgs $packArgs ''))
$steps.Add((New-Step 'bootstrap' 'python-deps' 'Python packages of the scripts (msal, documents)' 'auto' (Join-Path $PSScriptRoot 'Install-DemoPythonDeps.ps1') $P ($P + '-WhatIf') ''))
$steps.Add((New-Step 'bootstrap' 'foundry' 'Foundry project of the prompt agents (FD-only packs)' 'auto' (Join-Path $PSScriptRoot 'Set-DemoFoundry.ps1') $P ($P + '-WhatIf') 'switches demo-config to reuse-existing; nothing to do when it is already set'))
$steps.Add((New-Step 'bootstrap' 'identities' 'Users, licenses, roles, managers, groups' 'auto' (Join-Path $PSScriptRoot 'Set-DemoIdentities.ps1') $P ($P + '-WhatIf') 'the Purview role groups it prints are manual (Purview card)'))
$steps.Add((New-Step 'bootstrap' 'photos' 'Profile photos (leavers included, before their deletion)' 'auto' (Join-Path $PSScriptRoot 'Set-DemoPhotos.ps1') $P ($P + '-WhatIf') 'photos are not shipped: put them in generated/<prefix>/demo/photos'))
$steps.Add((New-Step 'bootstrap' 'first-signin' 'First sign-in of every persona, each in its own browser profile' 'manual' $null @() @() "passwords in generated/$Prefix/demo/secrets; register MFA if prompted; keep one browser profile per persona (tabs in demo order later)"))
# --- setup (automated) ---
$steps.Add((New-Step 'setup' 'knowledge-build' 'Fictional documents in the demo language' 'auto' (Join-Path $PSScriptRoot 'New-DemoKnowledge.ps1') $P $P ''))
$steps.Add((New-Step 'setup' 'knowledge-publish' 'SharePoint library of the knowledge' 'auto' (Join-Path $PSScriptRoot 'Publish-DemoKnowledge.ps1') $P ($P + '-WhatIf') ''))
$steps.Add((New-Step 'setup' 'mcp-deploy' 'Demo MCP backends (Container Apps)' 'auto' (Join-Path $PSScriptRoot 'Deploy-DemoMcp.ps1') $P ($P + '-WhatIf') ''))
foreach ($k in @($pack.mcp.longLived | ForEach-Object { [string]$_.key })) {
    # -Run: registers with the a365 CLI (the 'y' of its prompt is piped) and confirms (backing apps, consents, audience).
    $steps.Add((New-Step 'setup' "mcp-register-$k" "Registration of the '$k' server (a365 CLI + confirm)" 'auto' (Join-Path $PSScriptRoot 'New-DemoMcpRegistration.ps1') ($P + @('-Action', 'Register', '-Server', $k, '-Run')) ($P + @('-Action', 'Status')) 'on failure the name may stay reserved: re-run with -ServerName <another ext_ name>'))
}
# The admin approval gates the agents: an ext_ tool cannot be attached to an agent before it (was in 'interactive').
$steps.Add((New-Step 'setup' 'mcp-approve' 'Registered demo MCP servers: admin approval (BLOCKING before the agents)' 'manual' (Join-Path $PSScriptRoot 'New-DemoMcpRegistration.ps1') ($P + @('-Action', 'Status')) ($P + @('-Action', 'Status')) 'per server: the admin approves it in the admin center (allow pop-ups; the live pool instance stays pending), then -Action Approved -Name <n>'))
$steps.Add((New-Step 'setup' 'agents' 'Lab Builder plan and scaffold of the agents' 'agent' (Join-Path $PSScriptRoot 'New-DemoLabPlan.ps1') ($P + '-Scaffold') ($P + '-ValidateOnly') "then continue as a Lab Builder 'resume $Prefix' (deploy ordering); its per-agent test gate is deferred to the register row agent-smoke-tests"))
$steps.Add((New-Step 'setup' 'aoai-capacity' 'Size the shared Azure OpenAI deployment for the demo traffic' 'auto' (Join-Path $PSScriptRoot 'Set-DemoAoaiCapacity.ps1') $P ($P + '-WhatIf') 'after the ACA agents exist; the Lab Builder default capacity is too small for the traffic plan'))
$steps.Add((New-Step 'setup' 'governance' 'Attribute, owners/sponsors/attributes of agent identities, catalog' 'auto' (Join-Path $PSScriptRoot 'Set-DemoGovernance.ps1') $P ($P + '-WhatIf') 're-run -Step identities whenever a new agent identity appears'))
$steps.Add((New-Step 'setup' 'cards' 'Guided cards and test hand-out' 'auto' (Join-Path $PSScriptRoot 'New-DemoCards.ps1') $P $P ''))
$steps.Add((New-Step 'setup' 'guide' 'Run of show' 'auto' (Join-Path $guide 'New-DemoGuide.ps1') $P $P ''))
# --- interactive (user interaction) ---
$steps.Add((New-Step 'interactive' 'mcp-connections' 'Per-user connection URLs, BEFORE any test that uses a demo MCP server' 'auto' (Join-Path $PSScriptRoot 'New-DemoMcpRegistration.ps1') ($P + @('-Action', 'Urls')) ($P + @('-Action', 'Urls')) 'every person listed opens the URL signed in as themselves, once'))
$cardDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'references\cards'
foreach ($c in @(Get-ChildItem -LiteralPath $cardDir -Filter '*.md' | Sort-Object Name)) {
    $steps.Add((New-Step 'interactive' "card-$($c.BaseName)" "Guided card $($c.BaseName) (one step per turn)" 'manual' $null @() @() "generated/$Prefix/demo/cards/$($c.Name)"))
}
# The creators of the ownerless-agent demos leave: at least a day before the rehearsals (the admin-center card lags).
foreach ($a in @($pack.agents | Where-Object { $_.leaver })) {
    $steps.Add((New-Step 'interactive' "leaver-$($a.key)" "Creator of $($a.key) leaves (temporary owner held, then permanently deleted)" 'auto' (Join-Path $reset 'New-OrphanAgent.ps1') ($P + @('-Agent', $a.key, '-Apply')) ($P + @('-Agent', $a.key)) 'only after the agent was created, shared and its share link opened by the recipients (Agent Builder card)'))
}
$steps.Add((New-Step 'interactive' 'identities-refresh' 'Owners/sponsors/attributes of the agent identities created since the setup' 'auto' (Join-Path $PSScriptRoot 'Set-DemoGovernance.ps1') ($P + @('-Step', 'identities')) ($P + @('-Step', 'identities', '-WhatIf')) 'after the Digital Worker instance and every agent publication'))
$steps.Add((New-Step 'interactive' 'mcs-published' 'Copilot Studio agents really published (read-only)' 'auto' (Join-Path $PSScriptRoot 'Publish-DemoMcsAgent.ps1') $P $P 'an agent NOT up to date: Publish-DemoMcsAgent.ps1 -Agent <key> -Publish, then a new conversation in Teams'))
$steps.Add((New-Step 'interactive' 'tests' 'Test hand-out, in order (traffic from T-3 to T-1)' 'manual' $null @() @() "generated/$Prefix/demo/cards/90-test-handout.md"))
$steps.Add((New-Step 'interactive' 'aoai-429' 'Throttling check after the first traffic round (read-only)' 'auto' (Join-Path $PSScriptRoot 'Set-DemoAoaiCapacity.ps1') ($P + @('-Check429', '-WhatIf')) ($P + @('-Check429', '-WhatIf')) 'any 429: raise the capacity (aoai-capacity step)'))
$steps.Add((New-Step 'interactive' 'preflight' 'Pre-flight of every demo (read-only)' 'auto' (Join-Path $reset 'Get-DemoState.ps1') $P $P 'fix every KO, then the lab is ready'))
# --- user actions of the manual/terminal steps: what needs them (pack-driven), whether the build stops, register key ---
$mcsKeys = @($pack.agents | Where-Object { $_.platform -eq 'copilotStudio' -and -not $_.outsideLabPlan } | ForEach-Object { [string]$_.key })
$abKeys = @($pack.agents | Where-Object { $_.platform -eq 'agentBuilder' } | ForEach-Object { [string]$_.key })
$fdKeys = @($pack.agents | Where-Object { $_.variant -like 'FD-*' } | ForEach-Object { [string]$_.key })
$dwKeys = @($pack.agents | Where-Object { $_.variant -like '*-DW' } | ForEach-Object { [string]$_.key })
$cardScope = @{
    '10-copilot-studio' = @{ agents = $mcsKeys }; '11-agent-builder' = @{ agents = $abKeys }; '15-foundry' = @{ agents = $fdKeys }
    '20-digital-worker' = @{ agents = $dwKeys }; '30-entra' = @{ portals = @('entra') }; '40-purview' = @{ portals = @('purview') }
    '50-defender' = @{ portals = @('defender') }; '60-admin-center' = @{ portals = @('microsoft365Admin') }
}
foreach ($sp in $steps) {
    $sp | Add-Member -NotePropertyName key -NotePropertyValue "step:$($sp.phase)/$($sp.id)"
    $sp | Add-Member -NotePropertyName neededBy -NotePropertyValue ''
    $sp | Add-Member -NotePropertyName blocking -NotePropertyValue $false
    if ($sp.id -like 'card-*') {
        $base = $sp.id.Substring(5)
        $s = $cardScope[$base]
        $ids = if ($s) { @(Get-DemoIdsFor $pack -AgentKeys @($s.agents) -Portals @($s.portals)) } else { @() }
        $sp.neededBy = if ($ids.Count) { $ids -join ', ' } else { 'see the card' }
        $src = Join-Path $labDir "cards\$base.md"; if (-not (Test-Path -LiteralPath $src)) { $src = Join-Path $cardDir "$base.md" }
        $t = if (Test-Path -LiteralPath $src) { ([regex]::Match((Get-Content -LiteralPath $src -Raw -Encoding utf8), '(?m)^# (.+)$')).Groups[1].Value.Trim() } else { '' }
        $sp.title = "Card $base$(if ($t) { ": $t" })"
        $sp.hint = "$($sp.hint) (the agent can guide it one step per turn and verify it)"
    }
}
function Set-StepMeta([string]$Id, [string]$NeededBy, [bool]$Blocking, [string]$Key) {
    foreach ($sp in @($steps | Where-Object { $_.id -eq $Id })) { if ($NeededBy) { $sp.neededBy = $NeededBy }; $sp.blocking = $Blocking; if ($Key) { $sp.key = $Key } }
}
Set-StepMeta 'first-signin' 'every card done by a persona, the per-user MCP connections and the tests' $false
Set-StepMeta 'mcp-approve' 'agents step (an ext_ tool cannot be attached before the admin approval)' $true 'mcp-approve'
Set-StepMeta 'tests' 'the rehearsal (traffic from T-3 to T-1; usage metrics and audit records)' $false
# --- use, restore, teardown ---
$steps.Add((New-Step 'use' 'run' 'Run the demo (outside this agent)' 'manual' $null @() @() "agent365-demo-guide: generated/$Prefix/demo/guide/run-of-show.md"))
$steps.Add((New-Step 'restore' 'preflight' 'Pre-flight of every demo (read-only)' 'auto' (Join-Path $reset 'Get-DemoState.ps1') $P $P ''))
$steps.Add((New-Step 'restore' 'reset' 'Restore the starting conditions (users recreated when a demo needs them)' 'auto' (Join-Path $reset 'Reset-DemoState.ps1') ($P + '-Apply') $P 'then the manual resets it prints, one per turn'))
$steps.Add((New-Step 'restore' 'preflight-after' 'Pre-flight again (read-only)' 'auto' (Join-Path $reset 'Get-DemoState.ps1') $P $P ''))
$steps.Add((New-Step 'teardown' 'remove' 'Remove the lab' 'manual' $null @() @() "Lab Cleaner for everything tagged a365lab=$Prefix, then the extras in demo-packs/$($cfg.pack)/README.md#teardown"))

# --- progress in state.json ---------------------------------------------------------------------------------------
$script:MovedSteps = @{ 'setup/mcp-approve' = 'interactive' }
$state = Read-DemoLabState $Prefix
if (-not $state.Contains('phases')) { $state['phases'] = [ordered]@{} }
function Get-StepStatus($Sp) {
    $ph = $state.phases[$Sp.phase]; if ($ph -and $ph.Contains($Sp.id)) { return [string]$ph[$Sp.id].status }
    # Steps moved to another phase keep the status recorded under their old phase (labs built before the move).
    $old = $script:MovedSteps["$($Sp.phase)/$($Sp.id)"]
    if ($old) { $ph = $state.phases[$old]; if ($ph -and $ph.Contains($Sp.id)) { return [string]$ph[$Sp.id].status } }
    return ''
}
function Set-StepStatus($Sp, [string]$Status) {
    # Re-read: the step's own script may have saved state.json since this runner started.
    $script:state = Read-DemoLabState $Prefix
    if (-not $state.Contains('phases')) { $state['phases'] = [ordered]@{} }
    if (-not $state.phases.Contains($Sp.phase)) { $state.phases[$Sp.phase] = [ordered]@{} }
    $state.phases[$Sp.phase][$Sp.id] = [ordered]@{ status = $Status; at = (Get-Date).ToString('s') }
    Save-DemoLabState $Prefix $state
}
# Manual and terminal steps of the build phases are user actions: recorded in the register (USER-ACTIONS.md) when the
# phase runs with -Apply, marked DONE with -Done. An existing row (also one written by a step script, e.g. mcp-approve)
# keeps its texts; only the status is applied.
function Register-StepAction($Sp, [string]$Status = '') {
    if ($Sp.phase -notin 'bootstrap', 'setup', 'interactive' -or $Sp.kind -notin 'manual', 'terminal') { return }
    $exists = @((Read-DemoUserActions $Prefix).actions | Where-Object { $_.key -eq $Sp.key }).Count -gt 0
    $p = @{ Prefix = $Prefix; Key = $Sp.key }
    if (-not $exists) { $p += @{ Action = $Sp.title; Where = $Sp.hint; NeededBy = $Sp.neededBy; Blocking = [bool]$Sp.blocking } }
    if ($Status) { $p['Status'] = $Status }
    elseif (-not $exists -and (Get-StepStatus $Sp) -eq 'done') { $p['Status'] = 'DONE' }
    $row = Set-DemoUserAction @p
    Write-Host ("   user action {0} [{1}{2}] -> generated/{3}/demo/USER-ACTIONS.md" -f $row.id, $row.status, $(if ($row.blocking -and $row.status -ne 'DONE') { ', BLOCKING' }), $Prefix)
}

if ($Done) {
    $sp = @($steps | Where-Object { $_.id -eq $Done -and ($Phase -eq 'status' -or $_.phase -eq $Phase) }) | Select-Object -First 1
    if (-not $sp) { throw "Unknown step '$Done'$(if ($Phase -ne 'status') { " in phase $Phase" }). Steps: $(@($steps | ForEach-Object { "$($_.phase)/$($_.id)" }) -join ', ')" }
    Set-StepStatus $sp 'done'
    Register-StepAction $sp 'DONE'
    Write-DemoLog $Prefix "Phase $($sp.phase): step '$($sp.id)' confirmed done"
    return
}
if ($Phase -eq 'status') {
    foreach ($ph in 'bootstrap', 'setup', 'interactive', 'use', 'restore', 'teardown') {
        $list = @($steps | Where-Object { $_.phase -eq $ph })
        $n = @($list | Where-Object { (Get-StepStatus $_) -eq 'done' }).Count
        Write-Host ("{0,-12} {1}/{2} done" -f $ph, $n, $list.Count)
        foreach ($sp in $list) { $s = Get-StepStatus $sp; Write-Host ("  {0,-6} {1,-26} {2,-9} {3}" -f $(if ($s -eq 'done') { '[x]' } elseif ($s) { "[$s]" } else { '[ ]' }), $sp.id, $sp.kind, $sp.title) }
    }
    return
}

# --- run one phase --------------------------------------------------------------------------------------------------
$list = @($steps | Where-Object { $_.phase -eq $Phase })
if ($Only) { $list = @($list | Where-Object { $_.id -eq $Only }) }
elseif ($From) { $i = [array]::IndexOf(@($list | ForEach-Object { $_.id }), $From); if ($i -lt 0) { throw "Step '$From' is not in phase $Phase." }; $list = @($list[$i..($list.Count - 1)]) }
Write-DemoLog $Prefix "Phase $Phase ($(if ($Apply) { 'APPLY' } else { 'DRY RUN' })): $(@($list | ForEach-Object { $_.id }) -join ', ')"
foreach ($sp in $list) {
    $st = Get-StepStatus $sp
    Write-Host ''
    Write-Host ("== {0}/{1} [{2}] {3}{4}" -f $Phase, $sp.id, $sp.kind, $sp.title, $(if ($st -eq 'done') { ' (already done)' })) -ForegroundColor Cyan
    if ($Apply) { Register-StepAction $sp }
    if ($sp.script) {
        $a = if ($Apply -or $null -eq $sp.dryArgs) { $sp.applyArgs } else { $sp.dryArgs }
        pwsh -NoProfile -File $sp.script @a
        if ($LASTEXITCODE -ne 0) {
            Write-DemoLog $Prefix "Phase ${Phase}: step '$($sp.id)' FAILED (exit $LASTEXITCODE). Fix it, then resume with -From $($sp.id)" 'ERROR'
            exit 1
        }
        if ($Apply -and $sp.kind -eq 'auto') { Set-StepStatus $sp 'done' }
        elseif ($Apply -and $sp.kind -in 'terminal', 'agent') { Set-StepStatus $sp 'started' }
    }
    if ($sp.hint) { Write-Host "   next: $($sp.hint)" }
    if ($sp.kind -ne 'auto') { Write-Host "   confirm when done: Invoke-DemoPhase.ps1 -Prefix $Prefix -Phase $Phase -Done $($sp.id)" }
    # A blocking step (or the Lab Builder work of the 'agents' step) stops an -Apply run: the next steps depend on it.
    if ($Apply -and ($sp.blocking -or $sp.kind -eq 'agent') -and (Get-StepStatus $sp) -ne 'done') {
        $rest = @($list | Select-Object -Skip ([array]::IndexOf(@($list | ForEach-Object { $_.id }), $sp.id) + 1))
        Write-Host "   STOP: '$($sp.id)' is blocking (the next steps depend on it). When it is done: -Done $($sp.id)$(if ($rest.Count) { ", then resume with -Phase $Phase -Apply -From $($rest[0].id)" })" -ForegroundColor Yellow
        Write-DemoLog $Prefix "Phase ${Phase}: paused at the blocking step '$($sp.id)'"
        exit 0
    }
}
Write-DemoLog $Prefix "Phase $Phase ($(if ($Apply) { 'APPLY' } else { 'DRY RUN' })) finished. Progress: Invoke-DemoPhase.ps1 -Prefix $Prefix"
