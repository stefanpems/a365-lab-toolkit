#requires -Version 7.0
<#
.SYNOPSIS
  Generates the Lab Builder plan of a demo environment (generated/<prefix>/a365-deployment-plan.json) and the
  localized agent overlays (generated/<prefix>/demo/overlays/<agent>/) from the demo pack + demo-config.json.
.DESCRIPTION
  The Demo Builder never re-implements agent provisioning: it writes a standard, secret-free Lab Builder plan
  (namingMode custom, localized names, overlays, registered ext_ servers in agents[].tools, byoMcpAudiences from
  the demo state) and then runs the SAME Lab Builder scaffolder (scaffold-from-plan.ps1). Agents outside the lab
  plan (e.g. the unauthenticated Copilot Studio prototype in another environment) are listed in
  generated/<prefix>/demo/outside-plan.json with the exact Lab Builder engine command to create them.
  Re-run it whenever the demo state changes (e.g. after the MCP registration fills the BYO audiences).
.EXAMPLE
  pwsh -File .\New-DemoLabPlan.ps1 -Prefix cts2
#>
[CmdletBinding(PositionalBinding = $false)]
param([Parameter(Mandatory)][string]$Prefix, [switch]$Scaffold, [switch]$ValidateOnly)
. (Join-Path $PSScriptRoot '_demo-common.ps1')
$cfg = Read-DemoConfig $Prefix
$pack = Get-DemoPack $cfg.pack
$L = Get-DemoLocale -Locale $cfg.locale -Pack $cfg.pack
$state = Read-DemoLabState $Prefix
$packDir = Get-DemoPackDir $cfg.pack
$labDir = Get-DemoLabDir $Prefix
$planPath = Join-Path $script:DemoRepoRoot "generated\$Prefix\a365-deployment-plan.json"
function Get-Upn([string]$Key) { "$(Get-DemoPersonaAlias $L $Key)@$($cfg.domain)" }

# Tool reference of the pack ("mcp:<serverKey>" -> the registered name from state.json when the server was registered
# with a suffix, else the localized name; others are kept verbatim).
function Resolve-PackTool([string]$T) {
    if ($T -like 'mcp:*') {
        $k = $T.Substring(4)
        if ($state.mcp.servers -and $state.mcp.servers.Contains($k) -and $state.mcp.servers[$k].name) { return [string]$state.mcp.servers[$k].name }
        return [string]$L.mcp.servers[$k].name
    }
    return $T
}

# --- overlays ---------------------------------------------------------------------------------------------------
$overlayRoot = Join-Path $labDir 'overlays'
function New-AgentOverlay($A) {
    $dst = Join-Path $overlayRoot $A.key
    if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Copy-Item -LiteralPath (Join-Path $packDir 'overlays\overlay_tools.py') -Destination $dst
    Copy-Item -Path (Join-Path $packDir "overlays\$($A.overlay)\*") -Destination $dst -Recurse
    [ordered]@{ org = $L.org; overlay = $L.overlays[$A.overlay] } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $dst 'overlay_strings.json') -Encoding utf8
    if ($A.variant -like '*-DW') {
        $m = $L.agents[$A.key].manifest
        [ordered]@{ name = [ordered]@{ short = $m.nameShort; full = $m.nameFull }; description = [ordered]@{ short = $m.descriptionShort; full = $m.descriptionFull }; developer = [ordered]@{ name = $m.developer } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dst 'manifest.overrides.json') -Encoding utf8
    }
    if ($A.knowledgeFiles) {
        $kdst = Join-Path $dst 'knowledge'
        New-Item -ItemType Directory -Force -Path $kdst | Out-Null
        foreach ($k in $A.knowledgeFiles) {
            $doc = $L.knowledge.documents[$k]
            $folderKey = ($pack.knowledge.documents | Where-Object { $_.key -eq $k }).folder
            $src = Join-Path $labDir "knowledge\out\$($L.knowledge.folders[$folderKey])\$($doc.file)"
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $kdst }
            else { Write-Host "  note: $($A.key) knowledge file not generated yet: $src (run New-DemoKnowledge.ps1, then re-run this script)" -ForegroundColor DarkYellow }
        }
    }
    return $dst.Substring($script:DemoRepoRoot.Length + 1)
}

# --- plan -------------------------------------------------------------------------------------------------------
$agents = [System.Collections.Generic.List[object]]::new()
$outside = [System.Collections.Generic.List[object]]::new()
foreach ($a in ($pack.agents | Sort-Object { [int]$_.buildOrder })) {
    $la = $L.agents[$a.key]
    if ($a.platform -eq 'code') {
        $entry = [ordered]@{ type = $a.variant; framework = 'MAF'; name = $la.codeName
            displayNames = [ordered]@{ blueprint = $la.blueprint; identity = $la.identity }
            resourceGroup = "$($la.codeName)-rg"; tools = @($a.tools | ForEach-Object { Resolve-PackTool $_ }) }
        if ($a.variant -like 'FD-*') { $entry.tools = @() }
        if ($a.variant -like '*-DW') { $entry['frontier'] = [ordered]@{ enrollmentConfirmed = $true; policyTemplate = $L.governance.templates.aiTeammateTemplate } }
        if ($a.overlay) { $entry['overlay'] = New-AgentOverlay $a }
        $agents.Add($entry)
    }
    elseif ($a.platform -eq 'copilotStudio') {
        $entry = [ordered]@{ type = $a.variant; name = $la.codeName; displayName = $la.displayName; mcp = @(); publish = $true }
        if ($a.outsideLabPlan) {
            $envKey = if ($a.environment -eq 'default') { 'defaultEnvironmentId' } else { 'paygEnvironmentId' }
            $sol = (($Prefix -replace '[^A-Za-z0-9]', '') + 'MCSX' + ($a.key -replace '[^A-Za-z0-9]', '')).Substring(0, [Math]::Min(40, (($Prefix -replace '[^A-Za-z0-9]', '') + 'MCSX' + ($a.key -replace '[^A-Za-z0-9]', '')).Length))
            $cs = Join-Path $script:DemoRepoRoot '.github\skills\agent365-copilot-studio\scripts\New-McsAgent.ps1'
            $outside.Add([ordered]@{ key = $a.key; displayName = $la.displayName; environment = $a.environment; environmentId = $cfg.copilotStudio[$envKey]
                command = "pwsh -File `"$cs`" -Harness $($a.variant) -DisplayName `"$($la.displayName)`" -SolutionUniqueName `"$sol`" -Tenant `"$($cfg.tenantId)`" -EnvironmentId `"$($cfg.copilotStudio[$envKey])`" -IsolateSchemaName -InstallPac -Publish" })
            continue
        }
        $agents.Add($entry)
    }
}
$expose = @($pack.webUi.expose | ForEach-Object { [ordered]@{ agentName = $L.agents[$_].codeName } })
$cfgFoundry = if ($cfg.foundry) { $cfg.foundry } else { @{ mode = 'create-shared' } }
$hasFh = @($pack.agents | Where-Object { $_.variant -like 'FH-*' }).Count -gt 0
if ($cfgFoundry.mode -ne 'reuse-existing' -and -not $hasFh -and @($pack.agents | Where-Object { $_.variant -like 'FD-*' }).Count) {
    throw "The pack's Foundry agents are prompt agents (FD) only: the Lab Builder needs solution.foundry.mode 'reuse-existing'. Create the account first: pwsh -File `"$(Join-Path $script:WizardScriptsDir 'New-FoundryProject.ps1')`" -Prefix $Prefix -Subscription $($cfg.subscriptionId) -Region $($cfg.region) -AsJson, then New-DemoConfig.ps1 -Prefix $Prefix -FoundryMode reuse-existing -FoundryEndpoint <endpoint> -FoundryAccount <account> -FoundryResourceGroup <rg>."
}
$solution = [ordered]@{
    prefix = $Prefix; tenantId = $cfg.tenantId; subscriptionId = $cfg.subscriptionId; region = $cfg.region
    secretHandling = $cfg.secretHandling; resourceGroupStrategy = 'isolated'; namingMode = 'custom'
    foundry = $cfgFoundry
    azureOpenAI = [ordered]@{ mode = 'create-shared'; deployment = 'gpt-4.1-mini' }
    observability = [ordered]@{ appInsights = [ordered]@{ mode = 'create-shared' } }
    copilotStudio = [ordered]@{ targetTenantId = $cfg.tenantId; targetEnvironmentId = $cfg.copilotStudio.paygEnvironmentId }
}
$audiences = [ordered]@{}
foreach ($k in @($state.mcp.servers.Keys)) { $s = $state.mcp.servers[$k]; if ($s.name -and $s.audience) { $audiences[$s.name] = $s.audience } }
$plan = [ordered]@{
    '$comment' = "Agent 365 deployment plan - SECRET-FREE. Generated by the Demo Builder from demo pack '$($cfg.pack)' (locale $($cfg.locale)); regenerate it with New-DemoLabPlan.ps1 instead of editing it. Schema: .github/skills/agent365-wizard/references/deployment-plan-schema.md"
    version = 1; solution = $solution; agents = $agents
    ui = [ordered]@{ mode = 'create'; name = "$Prefix-ui"; hosting = 'static-web-app'; swaRegion = $cfg.swaRegion; expose = $expose
        permissions = [ordered]@{ mailConsent = $true; s2sAudience = $true; foundryAccess = @((Get-Upn 'maker'), (Get-Upn 'caseOfficer')) } }
    byoMcpAudiences = $audiences
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $planPath) | Out-Null
$plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $planPath -Encoding utf8
$outside | ConvertTo-Json -Depth 5 -AsArray | Set-Content -LiteralPath (Join-Path $labDir 'outside-plan.json') -Encoding utf8
Write-DemoLog $Prefix "Lab Builder plan written ($($agents.Count) agents, locale $($cfg.locale)): $planPath"
if ($outside.Count) { Write-Host "Outside the lab plan (Lab Builder engine command in demo\outside-plan.json): $(@($outside | ForEach-Object { $_.displayName }) -join ', ')" }
$scaffolder = Join-Path $script:WizardScriptsDir 'scaffold-from-plan.ps1'
if ($ValidateOnly) { & pwsh -NoProfile -File $scaffolder -PlanPath $planPath -ValidateOnly; exit $LASTEXITCODE }
if ($Scaffold) { & pwsh -NoProfile -File $scaffolder -PlanPath $planPath; exit $LASTEXITCODE }
Write-Host "Next (Lab Builder engine): pwsh -File `"$scaffolder`" -PlanPath `"$planPath`"" -ForegroundColor Cyan
