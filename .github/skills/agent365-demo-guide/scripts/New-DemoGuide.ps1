#requires -Version 7.0
<#
.SYNOPSIS
  Writes the run of show of a demo lab to generated/<prefix>/demo/guide/run-of-show.md: one card per demo of the pack,
  in act order, in English with the localized names, prompts and expected results of the lab.
.DESCRIPTION
  Every card comes from the pack and the lab, nothing is invented: title, act, minutes, product status (say "preview"
  aloud when it is one), portal, who signs in (the demo's personas with their UPN), agents, the tests linked to the demo
  (prompts in the demo language; operator slots only as 'fill slot-N'), the governance objects the demo shows, the
  starting-condition check (Get-DemoState.ps1 -Demo <id>) and the reset after the demo (reset class, lead time, manual
  resets). The protection demos are referred to by code and slot ids only.
.EXAMPLE
  pwsh -File .\New-DemoGuide.ps1 -Prefix cts2
.EXAMPLE
  pwsh -File .\New-DemoGuide.ps1 -Prefix cts2 -Demo D4,D5
#>
[CmdletBinding(PositionalBinding = $false)]
param([Parameter(Mandatory)][string]$Prefix, [string[]]$Demo = @('All'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\agent365-demo-builder\scripts\_demo-common.ps1')
$Demo = @($Demo | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$cfg = Read-DemoConfig $Prefix
$pack = Get-DemoPack $cfg.pack
$LOC = Get-DemoLocale -Locale $cfg.locale -Pack $cfg.pack
$state = Read-DemoLabState $Prefix
$gov = $LOC.governance
function Format-Code([string]$S) { '`' + $S + '`' }
function Get-Who([string]$Key) { if ($Key -eq 'admin') { return "the tenant administrator ($($cfg.adminUpn))" }; "$(Get-DemoPersonaDisplayName $LOC $Key) ($(Get-DemoUpn $LOC $cfg $Key))" }
function Expand-Prompt([string]$P) {
    $out = $P
    $inst = @($pack.agents | Where-Object { $_.instance }) | Select-Object -First 1
    if ($inst) { $out = $out.Replace('{upn:instance}', "$($LOC.agents[$inst.key].instance.alias)@$($cfg.domain)") }
    return [regex]::Replace($out, '\{upn:([A-Za-z0-9]+)\}', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) Get-DemoUpn $LOC $cfg $m.Groups[1].Value })
}
$portals = @{ microsoft365Admin = 'Microsoft 365 admin center, https://admin.microsoft.com > Agents'; entra = 'Microsoft Entra admin center, https://entra.microsoft.com'
    purview = 'Microsoft Purview, https://purview.microsoft.com'; defender = 'Microsoft Defender, https://security.microsoft.com'; copilot = 'Microsoft 365 Copilot and the demo web UI' }
$resets = @{ readOnly = 'nothing to reset: the demo only reads'; consumes = 'the demo changes the tenant: run Reset-DemoState.ps1 -Demo {0} -Apply afterwards'
    self = 'restored at the end of the demo itself (last step of the card)'; time = 'the conditions take time to come back: recreate them with Reset-DemoState.ps1 -Demo {0} -Apply well before the next run' }

# Governance objects a demo shows (pack.governance entries whose demos list the code).
function Get-GovItems([string]$Id) {
    $g = $pack.governance
    foreach ($ca in @($g.conditionalAccess)) { if (@($ca.demos) -contains $Id) { "Conditional Access policy $(Format-Code $gov.conditionalAccess[$ca.key]) (state $($ca.state))" } }
    if ($g.entitlement -and @($g.entitlement.demos) -contains $Id) { "access package $(Format-Code $gov.accessPackage.name) for $($LOC.agents[$g.entitlement.target].displayName)" }
    $pv = $g.purview
    if ($pv.sensitivityLabel -and @($pv.sensitivityLabel.demos) -contains $Id) { "sensitivity label $(Format-Code $gov.sensitivityLabel.name)" }
    if ($pv.dlp -and @($pv.dlp.demos) -contains $Id) { "DLP policy $(Format-Code $gov.dlpPolicy)" }
    if ($pv.auditRetention -and @($pv.auditRetention.demos) -contains $Id) { "audit retention $(Format-Code $gov.auditRetentionPolicy) and the saved audit searches" }
    if ($pv.communicationCompliance -and @($pv.communicationCompliance.demos) -contains $Id) { "Communication Compliance policy $(Format-Code $gov.communicationCompliancePolicy)" }
    if ($pv.ediscovery -and @($pv.ediscovery.demos) -contains $Id) { "eDiscovery case $(Format-Code $gov.ediscoveryCase)" }
    if ($pv.dspm -and @($pv.dspm.demos) -contains $Id) { 'DSPM one-click policies' }
    $df = $g.defender
    if ($df.copilotStudioThreatDetection -and @($df.copilotStudioThreatDetection.demos) -contains $Id) { 'Copilot Studio threat detection (pay-as-you-go environment)' }
    if ($df.rtpRule -and @($df.rtpRule.demos) -contains $Id) { "real-time protection rule $(Format-Code $gov.rtpRule) on $($LOC.agents[$df.rtpRule.agent].displayName)" }
    foreach ($t in @($g.adminCenter.templates)) { if (@($t.demos) -contains $Id) { "policy template $(Format-Code $gov.templates[$t.key])" } }
    foreach ($r in @($g.adminCenter.rules)) { if (@($r.demos) -contains $Id) { "management rule $($r.key) (run live)" } }
}
# Prompts of the tests linked to a demo (localized; operator slots only by id).
function Get-TestLines([string]$Id) {
    foreach ($t in @($pack.tests | Where-Object { @($_.demos) -contains $Id })) {
        $it = if ($LOC.tests.items -and $LOC.tests.items.Contains($t.id)) { $LOC.tests.items[$t.id] } else { $null }
        $who = @(@($t.persona) + @($t.personas) | Where-Object { $_ -and $_ -ne 'anyone' } | ForEach-Object { Get-DemoPersonaDisplayName $LOC $_ }) -join ', '
        $agent = if ($t.agent) { [string]$LOC.agents[$t.agent].displayName } else { '' }
        $prompt = if ($it -and $it.prompt) { Format-Code (Expand-Prompt ([string]$it.prompt)) }
                  elseif ($it -and $it.prompts) { @($it.prompts | ForEach-Object { Format-Code (Expand-Prompt ([string]$_)) }) -join ' then ' }
                  elseif ($it -and $it.promptSlot) { "fill $($it.promptSlot) (operator slot)" }
                  elseif ($it -and $it.promptSlots) { "fill $(@($it.promptSlots) -join ' then ') (operator slots)" }
                  elseif ($t.repeat -and $LOC.tests.items.Contains($t.repeat)) { Format-Code (Expand-Prompt ([string]$LOC.tests.items[$t.repeat].prompt)) }
                  else { '(see the test hand-out)' }
        $exp = if ($it -and $it.expected) { " → $(Expand-Prompt ([string]$it.expected))" } else { '' }
        "- **$($t.id)** $agent · $who · $($t.surface): $prompt$exp"
    }
}
# Starting state of the demo's agents that the audience will see.
function Get-AgentHints($Keys) {
    foreach ($k in @($Keys)) {
        $a = $pack.agents | Where-Object { $_.key -eq $k } | Select-Object -First 1
        if (-not $a -or -not $a.baseline) { continue }
        $b = $a.baseline; $h = @()
        if ($b.blocked) { $h += 'starts BLOCKED' }
        if ($b.pendingRequest) { $h += 'has a PENDING request' }
        if ($b.ownerless) { $h += 'has NO owner' }
        if ($b.installedFor) { $h += "installed for $(if ($b.installedFor -like 'group:*') { $LOC.groups[$b.installedFor.Substring(6)].displayName } else { Get-DemoPersonaDisplayName $LOC ($b.installedFor -replace '^persona:', '') })" }
        if ($b.exceptions) { $h += 'shows exceptions' }
        if (@($a.weaknesses | Where-Object { $_ }).Count) { $h += "deliberate weaknesses: $(@($a.weaknesses) -join ', ')" }
        if ($h.Count) { "$($LOC.agents[$k].displayName) $($h -join ', ')" }
    }
}

$sel = @($pack.demos | Where-Object { $Demo -contains 'All' -or $Demo -contains $_.id })
if (-not $sel.Count) { throw "No demo of pack '$($cfg.pack)' matches: $($Demo -join ', ')." }
$stamp = "> Lab $(Format-Code $Prefix) · locale $(Format-Code $cfg.locale) · generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') by New-DemoGuide.ps1: do not edit, re-run the script."
$lines = @("# Run of show · lab $Prefix · $($LOC.language)", '', $stamp, '',
    'Before the run: every presenter persona is signed in (one browser profile per persona, tabs open in demo order),',
    'Get-DemoState.ps1 shows no KO, and nothing is reconfigured on the day. Say "preview" aloud whenever the status of a',
    'demo says so. Objects of other labs in the same tenant show up in the lists: use the search box.', '')
foreach ($act in $pack.acts) {
    $ds = @($sel | Where-Object { [int]$_.act -eq [int]$act.id })
    if (-not $ds.Count) { continue }
    $lines += "## Act $($act.id) · $($act.title)", ''
    foreach ($d in $ds) {
        $lines += "### $($d.id) · $($d.title)$(if ($d.optional) { ' (optional)' })", ''
        $lines += "- **Time**: $(@($d.minutes)[0])-$(@($d.minutes)[1]) min · importance $($d.importance) · status: $($d.status)"
        $lines += "- **Where**: $(if ($portals.ContainsKey([string]$d.portal)) { $portals[[string]$d.portal] } else { $d.portal })"
        $lines += "- **Who**: $(@($d.profiles | ForEach-Object { Get-Who $_ }) -join '; ')"
        if (@($d.agents | Where-Object { $_ }).Count) { $lines += "- **Agents**: $(@($d.agents | ForEach-Object { $LOC.agents[$_].displayName }) -join ', ')" }
        $hints = @(Get-AgentHints $d.agents); if ($hints.Count) { $lines += "- **Starting state**: $($hints -join '; ')" }
        $gi = @(Get-GovItems $d.id); if ($gi.Count) { $lines += "- **Shows**: $($gi -join '; ')" }
        $tl = @(Get-TestLines $d.id); if ($tl.Count) { $lines += '- **Prompts**:'; $lines += @($tl | ForEach-Object { "  $_" }) }
        $nt = @($d.notes | Where-Object { $_ }); if ($nt.Count) { $lines += '- **Notes**:'; $lines += @($nt | ForEach-Object { "  - $(Expand-DemoText $_ $LOC $cfg $state $pack)" }) }
        $lines += '- **Check before**: ' + (Format-Code "Get-DemoState.ps1 -Prefix $Prefix -Demo $($d.id)")
        $lines += "- **After**: $($resets[[string]$d.resetClass] -f $d.id) (lead time $($d.leadHours) h)"
        foreach ($m in @($d.manualReset)) { if ($m) { $lines += "  - $(Expand-DemoText $m $LOC $cfg $state $pack)" } }
        $lines += ''
    }
}
$lines += '## Timeline', ''
foreach ($t in $pack.timeline) { $lines += "- **T$(if ([int]$t.day -lt 0) { $t.day } else { '0' })** ($($t.focus)): $(@($t.tasks) -join ', ')" }
$dir = Join-Path (Get-DemoLabDir $Prefix) 'guide'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$out = Join-Path $dir 'run-of-show.md'
Set-Content -LiteralPath $out -Value ($lines -join "`n") -Encoding utf8
$left = @(Select-String -LiteralPath $out -Pattern '<missing [^>]+>|\{\{|\{(upn|name|agent|group|folder|cfg|state|pack|slot):' -AllMatches)
if ($left.Count) { Write-DemoLog $Prefix "Run of show written with $($left.Count) unresolved placeholder(s)" 'WARN' }
Write-DemoLog $Prefix "Run of show written: $out ($($sel.Count) demos)"
