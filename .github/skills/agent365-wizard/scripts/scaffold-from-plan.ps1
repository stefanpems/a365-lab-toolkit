#requires -Version 5.1
<#
.SYNOPSIS
  Validate an Agent 365 deployment plan and scaffold per-variant folders + the web UI config.
.DESCRIPTION
  Reads a SECRET-FREE JSON plan (a365-deployment-plan.json) and, for each agent, copies the matching
  repo sample into generated/<agent-name>/ and fills its tenant-specific config from the plan. It
  parameterizes the ACA deploy script constants (RG / region / app / env — they are HARDCODED in the
    samples, not parameters) and generates generated/<prefix>-ui/config.js when a UI is requested.

  This script performs NO cloud mutations and runs NO deploys. It only reads the repo and writes
  under generated/. It prints the exact next commands for the user to run.

  It is a thin ROUTER: the per-family/component logic lives in scripts/modules/ (scaffold.aca.ps1,
  scaffold.fh.ps1, scaffold.fd.ps1, scaffold.ui.ps1, scaffold.mcp.ps1, scaffold.tools.ps1) and shared
  helpers in _common.ps1. Modules are dot-sourced into this scope, so they share $plan / $repoRoot /
  $OutRoot and mutate the ordered $nextCommands list and the $attachByAgent accumulator.
.PARAMETER PlanPath
  Path to the plan JSON. Default: <repo-root>/a365-deployment-plan.json
.PARAMETER OutRoot
  Output root for generated folders. Default: <repo-root>/generated
.PARAMETER ValidateOnly
  Validate the plan and exit without writing anything.
.EXAMPLE
  pwsh -File .\scaffold-from-plan.ps1
.EXAMPLE
  pwsh -File .\scaffold-from-plan.ps1 -ValidateOnly
#>
[CmdletBinding()]
param(
    [string]$PlanPath,
    [string]$OutRoot,
    [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Repo root = three levels up from this script (.github/skills/agent365-wizard/scripts).
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
if (-not $PlanPath) { $PlanPath = Join-Path $repoRoot 'a365-deployment-plan.json' }
if (-not $OutRoot)  { $OutRoot  = Join-Path $repoRoot 'generated' }

if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Plan not found: $PlanPath. Create it from .github/skills/agent365-wizard/assets/deployment-plan.template.json"
}
$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json

# Family/component scaffolders + shared helpers (variant map, .env writer). Dot-sourced so every
# module runs in THIS scope and shares $plan / $repoRoot / $OutRoot / $nextCommands / $attachByAgent.
$moduleDir = Join-Path $PSScriptRoot 'modules'
. (Join-Path $moduleDir '_common.ps1')
. (Join-Path $moduleDir 'scaffold.aca.ps1')
. (Join-Path $moduleDir 'scaffold.fh.ps1')
. (Join-Path $moduleDir 'scaffold.fd.ps1')
. (Join-Path $moduleDir 'scaffold.mcs.ps1')
. (Join-Path $moduleDir 'scaffold.ui.ps1')
. (Join-Path $moduleDir 'scaffold.mcp.ps1')
. (Join-Path $moduleDir 'scaffold.tools.ps1')

# ---------------------------------------------------------------- validation
$errors = New-Object System.Collections.Generic.List[string]
$prefix = $plan.solution.prefix
# Naming mode: 'default' (absent) enforces the fixed convention <prefix>-<framework>-<hosting>-<identity>;
# 'custom' lets the user free-form each code agent name (ACA/FH/FD) and relaxes the name check to the
# STRUCTURAL rules only (still enough to derive valid Azure/Entra names). MCS agents ALWAYS keep the
# prefix-derived name so the Lab Cleaner can compute + delete them from the lab name alone.
$namingMode = if ($plan.solution.namingMode) { "$($plan.solution.namingMode)".Trim().ToLower() } else { 'default' }

# Every lab agent name carries a FIXED <framework> segment: <prefix>-<framework>-<hosting>-<identity>
# (e.g. a90902-MAF-ACA-OBO). framework defaults to MAF; it keeps a same-type agent built with another
# framework (LangChain, Semantic Kernel, ...) distinguishable. Resolve it per agent so the dynamic prefix
# cap and the per-agent name check can use it.
function Get-AgentFramework { param($a) if ($a.framework) { "$($a.framework)".Trim() } else { 'MAF' } }

# Multi-instance suffix map (agent NAME -> '' | '-<n>'): a type with a single instance carries no suffix;
# a type with >1 instance suffixes every instance '-1'/'-2'/... in plan order. Single source of truth for
# the whole validation + scaffold (see Get-InstanceSuffixMap in modules/_common.ps1).
$suffixMap = Get-InstanceSuffixMap $plan

# Dynamic prefix cap. The 12-char base ceiling is driven by the CUSTOM MCP (ext_<prefix>Anon / ext_<prefix>Auth
# must stay <= 20), NOT the agent name. A Digital Worker adds a SECOND ceiling: 'a365 setup all --agent-name
# <name>' derives the Teams/M365 name.short as "<name> Blueprint", which is rejected above 30 chars. With the
# fixed <framework> segment the worst case is "<prefix>-<fw>-<hosting>-DW Blueprint", so a DW lab needs a
# shorter prefix (e.g. 9 for MAF-ACA-DW). A multi-instance DW type also adds its '-<n>' suffix. Take the
# strictest applicable ceiling.
$maxPrefix = 12
foreach ($a in @($plan.agents | Where-Object { $_.type -like '*-DW' })) {
    $sfx = [string]$suffixMap[[string]$a.name]
    $cap = 30 - "-$(Get-AgentFramework $a)-$($a.type)$sfx Blueprint".Length
    if ($cap -lt $maxPrefix) { $maxPrefix = $cap }
}
if ($maxPrefix -lt 3) { $maxPrefix = 3 }

if (-not $prefix) { $errors.Add('solution.prefix is required.') }
elseif ($prefix -cnotmatch "^[a-z][a-z0-9]{2,$($maxPrefix - 1)}$") {
    $dwNote = if ($maxPrefix -lt 12) { " For THIS lab the cap is $maxPrefix (not 12) because it includes a Digital Worker: 'a365 setup all' derives the Teams name.short as '<name> Blueprint', which must stay <= 30 chars once the fixed <framework> segment is added." } else { '' }
    $errors.Add("solution.prefix '$prefix' is invalid. It must start with a lowercase letter, contain ONLY lowercase letters and digits (no hyphens, underscores, uppercase or symbols), and be 3-$maxPrefix characters. The 12-char base cap comes from the custom MCP (Agent 365 registers ext_<prefix>Anon / ext_<prefix>Auth, which must stay <= 20 = 4 + prefix + 4) and is INDEPENDENT of the agent name.$dwNote Lowercase-alphanumeric starting with a letter also satisfies Azure Container Apps (2-32), managed identities, resource groups, the Entra app registrations and the Static Web App, so one prefix works for every resource.")
}
if (-not $plan.solution.region) { $errors.Add('solution.region is required.') }
if (-not $plan.agents -or $plan.agents.Count -eq 0) { $errors.Add('at least one agent is required.') }

foreach ($a in $plan.agents) {
    if (-not $MAP.ContainsKey($a.type)) {
        if ($a.type -eq 'FD-DW') { $errors.Add("agent type 'FD-DW' is not supported: a Digital Worker runs on a Bot Framework / Teams messaging surface (a hosted container exposing /api/messages), but a Foundry declarative (prompt) agent is platform-run with no container, code or endpoint and cannot host that surface. Use ACA-DW or FH-DW for a Digital Worker.") }
        else { $errors.Add("unknown agent type '$($a.type)' (supported: ACA-OBO, ACA-S2S, ACA-DW, FH-OBO, FH-S2S, FH-DW, FD-OBO, FD-S2S, MCS-OH, MCS-NH).") }
        continue
    }
    if (-not $a.name) { $errors.Add("agent of type $($a.type) is missing 'name'.") }
    # Microsoft Copilot Studio (MCS) agents use a 3-part name <prefix>-MCS-<OH|NH> with NO framework
    # segment (they are not a code framework). Validate them separately from the code families.
    elseif ($a.type -like 'MCS-*') {
        if ($prefix -and $namingMode -ne 'custom') {
            $sfx = [string]$suffixMap[[string]$a.name]
            $expected = "$prefix-$($a.type)$sfx"
            if ($a.name -ne $expected) {
                $hint = if ($sfx) { " With >1 instance of this type the name carries the instance suffix '$sfx'." } else { '' }
                $errors.Add("$($a.name): in DEFAULT naming mode an MCS agent name must be '<prefix>-MCS-<OH|NH>' = '$expected'. MCS carries no <framework> segment (Copilot Studio agent, not a code framework). Set solution.namingMode='custom' to free-form the display name.$hint")
            }
        }
        elseif ($prefix -and $namingMode -eq 'custom') {
            # Custom DISPLAY name for the Copilot Studio agent. The SOLUTION unique name stays prefix-derived
            # (<prefix>MCS<OH|NH>[<n>], pinned by scaffold.mcs.ps1) so the Lab Cleaner's prefix fallback
            # (solutions matching '<prefix>MCS*') is unaffected; only the visible display name is free-form.
            if ($a.name -notmatch '^[A-Za-z][A-Za-z0-9-]*$') {
                $errors.Add("$($a.name): a custom MCS agent name must start with a letter and contain ONLY letters, digits and hyphens (no spaces, underscores or symbols).")
            }
            elseif ($a.name -match '--' -or $a.name.EndsWith('-')) {
                $errors.Add("$($a.name): a custom MCS agent name must not contain consecutive hyphens or end with a hyphen.")
            }
        }
    }
    # FIXED naming convention for code families: <prefix>-<framework>-<hosting>-<identity> (framework default MAF).
    elseif ($prefix -and $namingMode -ne 'custom') {
        $fw = Get-AgentFramework $a
        $sfx = [string]$suffixMap[[string]$a.name]
        $expected = "$prefix-$fw-$($a.type)$sfx"
        if ($a.name -ne $expected) {
            $sfxHint = if ($sfx) { " This type has more than one instance, so every instance name carries a 1-based '-<n>' suffix (here '$sfx'); a single-instance type carries NO suffix." } else { ' A type with a single instance carries NO instance suffix.' }
            $errors.Add("$($a.name): agent name must follow the fixed convention <prefix>-<framework>-<hosting>-<identity>[-<instance>] = '$expected' (framework '$fw', type '$($a.type)').$sfxHint The <framework> segment is mandatory so a same-type agent built with a different framework stays distinguishable. (Set solution.namingMode='custom' to free-form agent names.)")
        }
        # Only MAF has sample source folders today; block silently scaffolding MAF code under another name.
        if ($fw -ne 'MAF') {
            $errors.Add("$($a.name): framework '$fw' has no sample source yet — only 'MAF' is implemented. The <framework> naming segment is reserved for future frameworks (LangChain/Semantic Kernel/...); set framework to 'MAF', or add the per-framework source folders + variant-map entry before using another code.")
        }
    }
    # CUSTOM naming mode: the user free-formed this code agent name. The convention check is relaxed, but
    # every rule the DERIVED resource names impose is still enforced here so an invalid custom name is
    # caught up-front (not at deploy time): structure, no double/trailing hyphen, ACA Container App length
    # (2-32), and the DW Teams name.short ("<name> Blueprint") <= 30 => name <= 20.
    elseif ($prefix -and $namingMode -eq 'custom' -and $a.type -notlike 'MCS-*') {
        $fw = Get-AgentFramework $a
        if ($fw -ne 'MAF') {
            $errors.Add("$($a.name): framework '$fw' has no sample source yet — only 'MAF' is implemented. Set framework to 'MAF', or add the per-framework source folders + variant-map entry first.")
        }
        if ($a.name -notmatch '^[A-Za-z][A-Za-z0-9-]*$') {
            $errors.Add("$($a.name): custom agent name must start with a letter and contain ONLY letters, digits and hyphens (no spaces, underscores or symbols) — it derives the resource group '<name>-rg', the ACA container app / managed identity, the Entra app registrations and, for a DW, the Teams name.short.")
        }
        elseif ($a.name -match '--' -or $a.name.EndsWith('-')) {
            $errors.Add("$($a.name): custom agent name must not contain consecutive hyphens or end with a hyphen (Azure Container Apps and resource names reject them).")
        }
        else {
            if ($a.type -like 'ACA-*') {
                $app = $a.name.ToLower()
                if ($app.Length -lt 2 -or $app.Length -gt 32) {
                    $errors.Add("$($a.name): an ACA custom name derives the Container App name '$app' ($($app.Length) chars), which must be 2-32 characters.")
                }
            }
            if ($a.type -like '*-DW') {
                # 'a365 setup all --agent-name <name>' derives the Teams name.short as "<name> Blueprint";
                # Teams/M365 rejects name.short above 30 chars, so a DW custom name must be <= 20 chars.
                $short = "$($a.name) Blueprint"
                if ($short.Length -gt 30) {
                    $errors.Add("$($a.name): a DW custom name is $($a.name.Length) chars; it must be <= 20 so the derived Teams name.short '$short' stays <= 30 characters.")
                }
            }
        }
    }
    # ACA container app name must be lowercase.
    if ($a.type -like 'ACA-*') {
        $app = ($a.name -replace '[^A-Za-z0-9-]', '-').ToLower()
        if ($app -cmatch '[A-Z]') { $errors.Add("$($a.name): derived container app name must be lowercase.") }
    }
    # DW display name hard limit: <= 30 chars.
    if ($a.type -like '*-DW') {
        $bp = $a.displayNames.blueprint
        if ($bp -and $bp.Length -gt 30) {
            $errors.Add("$($a.name): DW blueprint display name '$bp' is $($bp.Length) chars (max 30). Shorten it.")
        }
    }
}

# Instance uniqueness: N instances of a type each need a UNIQUE name (the '-<n>' suffix guarantees this
# for default names; a custom-named lab must not reuse a name). A collision would make two agents scaffold
# into the same generated/<prefix>/<name>/ folder and share resource groups.
foreach ($d in @($plan.agents | Where-Object { $_.name } | Group-Object -Property name | Where-Object { $_.Count -gt 1 })) {
    $errors.Add("duplicate agent name '$($d.Name)': $($d.Count) agents (instances) share it. Each instance must have a UNIQUE name — for default names the wizard appends a 1-based '-<n>' suffix when a type has more than one instance.")
}

# Shared-RG + ACA safety: the generic deploy-aca.ps1 deletes its RG; only S2S/DW named scripts are safe.
if ($plan.solution.resourceGroupStrategy -eq 'shared') {
    foreach ($a in ($plan.agents | Where-Object { $_.type -eq 'ACA-OBO' })) {
        $errors.Add("$($a.name): ACA-OBO uses the destructive deploy-aca.ps1 (deletes its RG). A shared RG is unsafe for ACA-OBO — use 'isolated', or pass -ReuseEnv at deploy time.")
    }
}

# Shared Foundry strategy (optional solution.foundry). When present, all FH/FD agents share ONE account +
# project + model instead of one account per agent. Absent = legacy per-agent (each FH provisions its own).
if ($plan.solution.foundry) {
    $f = $plan.solution.foundry
    if ($f.mode -notin @('create-shared', 'reuse-existing')) {
        $errors.Add("solution.foundry.mode '$($f.mode)' is invalid (use 'create-shared' = the wizard provisions one shared account+project+model for the lab, or 'reuse-existing' = deploy all FH/FD agents into an account+project you already have).")
    }
    if ($f.mode -eq 'reuse-existing' -and -not $f.endpoint) {
        $errors.Add("solution.foundry.mode 'reuse-existing' requires 'endpoint' (the project endpoint https://<account>.services.ai.azure.com/api/projects/<project> the FH/FD agents deploy into). Add 'account' + 'existingResourceGroup' too so the model can be verified and the deploy identity granted Cognitive Services User.")
    }
    if ($f.mode -eq 'create-shared') {
        $sharedProv = ($plan.agents | Where-Object { $_.type -in @('FH-OBO', 'FH-S2S') } | Select-Object -First 1)
        $needsShared = $plan.agents | Where-Object { $_.type -in @('FH-OBO', 'FH-S2S', 'FD-OBO', 'FD-S2S') }
        if ($needsShared -and -not $sharedProv) {
            $errors.Add("solution.foundry.mode 'create-shared' needs at least one FH-OBO/FH-S2S agent to provision the shared account (azd provision runs from an FH folder); FD-only labs must use 'reuse-existing' (a prompt agent has no azd project to provision from). FH-DW always keeps its own account (Bot Service + blueprint bicep).")
        }
    }
}

# Shared Azure OpenAI strategy (optional solution.azureOpenAI). When present, all ACA agents share ONE
# account + deployment instead of per-agent a.ai fields. create-shared = the wizard creates a lab-owned
# account in <prefix>-aoai-rg (deleted by the Lab Cleaner); reuse-existing = deploy against an account the
# user already has. Absent = legacy per-agent a.ai (unchanged).
if ($plan.solution.azureOpenAI) {
    $o = $plan.solution.azureOpenAI
    if ($o.mode -notin @('create-shared', 'reuse-existing')) {
        $errors.Add("solution.azureOpenAI.mode '$($o.mode)' is invalid (use 'create-shared' = the wizard creates one lab-owned Azure OpenAI account+deployment for all ACA agents, or 'reuse-existing' = deploy all ACA agents against an account you already have).")
    }
    if ($o.mode -eq 'reuse-existing' -and (-not $o.account)) {
        $errors.Add("solution.azureOpenAI.mode 'reuse-existing' requires 'account' (the existing Azure OpenAI account name). Add 'existingResourceGroup' too so the deploy can grant the app's managed identity Cognitive Services OpenAI User on it.")
    }
}

# Observability / App Insights strategy (optional solution.observability.appInsights). When present, the
# sample agents' OpenTelemetry exports to an Application Insights resource. none = no-op (default);
# create-shared = the wizard creates a lab-owned resource (deleted by the Lab Cleaner); reuse-existing =
# an existing user-owned resource (never touched). Absent = unchanged (no observability wiring).
if ($plan.solution.observability -and $plan.solution.observability.appInsights) {
    $ai = $plan.solution.observability.appInsights
    if ($ai.mode -notin @('none', 'create-shared', 'reuse-existing')) {
        $errors.Add("solution.observability.appInsights.mode '$($ai.mode)' is invalid (use 'none' = no wiring, 'create-shared' = the wizard creates one lab-owned Application Insights for the lab, or 'reuse-existing' = wire the agents to an Application Insights you already have).")
    }
    if ($ai.mode -eq 'reuse-existing' -and (-not $ai.existingName -or -not $ai.existingResourceGroup)) {
        $errors.Add("solution.observability.appInsights.mode 'reuse-existing' requires 'existingName' + 'existingResourceGroup' (the existing Application Insights resource and its resource group, so the deploy can resolve its connection string / connect it to the Foundry project).")
    }
}

# Web UI validation. 'attach' targets an EXISTING (possibly shared) SWA and must name it so the deploy
# flow can surgically merge tabs (Add-WebUiTab.ps1) instead of regenerating config.js.
if ($plan.ui -and $plan.ui.mode -eq 'attach') {
    if (-not ($plan.ui.existing -and $plan.ui.existing.staticWebApp)) {
        $errors.Add("ui.mode 'attach' requires ui.existing.staticWebApp (the name of the existing Static Web App to attach to). The wizard lists SWAs tagged a365component=web-ui so the user can pick one; also record ui.existing.spaAppId + ui.existing.origin.")
    }
}

# Custom MCP validation (optional). The custom MCP name is NOT asked — it IS the solution prefix (the
# prefix rule above already guarantees a valid ext_<prefix>Anon/Auth: <= 12 lowercase alphanumeric,
# letter-first, so ext_ stays <= 20).
if ($plan.customMcp -and $plan.customMcp.enabled) {
    $mcpMode = if ($plan.customMcp.mode) { "$($plan.customMcp.mode)".Trim().ToLower() } else { 'create' }
    if ($mcpMode -notin @('create', 'attach')) {
        $errors.Add("customMcp.mode '$($plan.customMcp.mode)' is invalid (use 'create' = deploy+register a NEW ext_<prefix>Anon/Auth pair, or 'attach' = reuse an EXISTING pair from the Custom MCP Creator / another existing custom MCP: no deploy/register, only attach it to the OBO agents).")
    }
    if ($mcpMode -eq 'attach') {
        $ex = $plan.customMcp.existing
        if (-not ($ex -and $ex.name)) {
            $errors.Add("customMcp.mode 'attach' requires customMcp.existing.name (the base <Name> of the existing pair; the servers are ext_<Name>Anon / ext_<Name>Auth). The wizard lists custom MCP instances tagged a365component=custom-mcp (Custom MCP Creator standalone) and any other existing ext_ pair so the user can PICK one — never a raw typed name.")
        }
        else {
            $exSlug = ($ex.name -replace '[^A-Za-z0-9]', '').ToLower()
            if ($exSlug.Length -lt 1 -or $exSlug.Length -gt 12) {
                $errors.Add("customMcp.existing.name '$($ex.name)' is invalid: after slugifying (lowercase alphanumeric) it must be 1-12 chars so ext_<Name>Anon / ext_<Name>Auth stay <= 20 (the Agent 365 server-name limit).")
            }
        }
        if (@($plan.customMcp.attachTo).Count -eq 0) {
            # Empty attachTo is normally a no-op error. EXCEPTION: an MCS-only lab may reuse an existing
            # pair purely to source anon/auth for its Copilot Studio agents (agents[].mcp = anon/auth),
            # which are wired via New-McsMcpClientApp -McpPrefix (Copilot Studio portal), NOT via
            # add-mcp-servers on an OBO agent. In that case the pair legitimately has no OBO attach target.
            $mcsAnonAuth = @($plan.agents | Where-Object { ($_.type -like 'MCS-*') -and (@($_.mcp | Where-Object { $_ -in @('anon', 'auth') }).Count -gt 0) })
            if ($mcsAnonAuth.Count -eq 0) {
                $errors.Add("customMcp.mode 'attach' with an empty customMcp.attachTo has nothing to do — list the OBO agent(s) (ACA-OBO / FH-OBO / FD-OBO) to attach the existing pair to (or, for an MCS-only lab, add MCS agents whose 'mcp' requests anon/auth so the reused pair supplies them via the Copilot Studio MCP wizard).")
            }
        }
    }
    if ($plan.customMcp.integrationMode -and ($plan.customMcp.integrationMode -notin @('approve-first', 'attach-when-approved'))) {
        $errors.Add("customMcp.integrationMode '$($plan.customMcp.integrationMode)' is invalid (use 'approve-first' or 'attach-when-approved').")
    }
    foreach ($t in @($plan.customMcp.attachTo)) {
        # A token is an agent NAME (one instance) or an agent TYPE (all its instances). Every resolved agent must be OBO.
        $resolved = @(Resolve-PlanAgents $plan $t)
        if ($resolved.Count -eq 0) { $errors.Add("customMcp.attachTo '$t' matches no planned agent — give an agent name (one instance) or an agent type (all its instances).") }
        foreach ($ra in $resolved) {
            if ($ra.type -notlike '*-OBO') { $errors.Add("customMcp.attachTo '$t' resolves to '$($ra.name)' ($($ra.type)): custom (BYO) MCP works only on OBO agents (ACA-OBO / FH-OBO / FD-OBO). A BYO server reached through the Agent 365 gateway needs a one-time Power Platform connection OWNED BY THE INVOKING IDENTITY; only an OBO agent invokes as the signed-in user who owns that connection. An S2S (own app identity) or DW (projected agentUser identity) agent invokes as a NON-USER identity that can neither own that connection nor be granted it (sharing is refused in preview with ConnectionSharingNotAllowed 403); S2S also can't mint a custom-audience token from the SPA path (AADSTS82001 app-only / AADSTS82002 OBO). This is a known preview platform limitation, not an unfinished feature.") }
        }
    }
}

# agents[].tools validation (registered MCP server unique names to attach, e.g. mcp_MailTools, ext_Foo).
foreach ($a in $plan.agents) {
    foreach ($tool in @($a.tools | Where-Object { $_ })) {
        if ($tool -notmatch '^(mcp_|ext_)') { $errors.Add("$($a.name): tool '$tool' must be a registered server unique name starting with 'mcp_' or 'ext_' (see 'a365 develop list-available').") }
        elseif (($tool -like 'ext_*') -and ($a.type -notlike '*-OBO')) { $errors.Add("$($a.name): custom BYO server '$tool' can attach only to an OBO agent. An S2S/DW agent invokes as a non-user (own app / agentUser) identity that can't own the Power Platform connection a BYO server needs (ConnectionSharingNotAllowed) — use an *-OBO agent. Work IQ 'mcp_*' servers are fine on any agent.") }
    }
    if (($a.type -like 'FD-*') -and (@($a.tools | Where-Object { $_ }).Count -gt 0)) {
        $errors.Add("$($a.name): FD (prompt) agents do not attach tools via ToolingManifest/add-mcp-servers; leave 'tools' empty (the FD sample wires its tools in agent_config.py).")
    }
    if (($a.type -like 'MCS-*') -and (@($a.tools | Where-Object { $_ }).Count -gt 0)) {
        $errors.Add("$($a.name): MCS (Copilot Studio) agents do not use the 'tools' (ToolingManifest) mechanism — set their MCP integration in 'mcp' (subset of mail/anon/auth), wired via a custom Entra client app in Copilot Studio.")
    }
}

# MCS (Copilot Studio) validation: NH needs a target PAYG+Dataverse env; both need the base zips to exist.
$mcsAgents = @($plan.agents | Where-Object { $_.type -like 'MCS-*' })
if ($mcsAgents) {
    $cs = $plan.solution.copilotStudio
    $baseDir = Join-Path $repoRoot '.github\skills\agent365-copilot-studio\assets\base-solutions'
    foreach ($a in $mcsAgents) {
        $zip = if ($a.type -eq 'MCS-OH') { 'AgentOHSol.zip' } else { 'AgentNHSol.zip' }
        if (-not (Test-Path (Join-Path $baseDir $zip))) { $errors.Add("$($a.name): base solution '$zip' not found under agent365-copilot-studio/assets/base-solutions. Re-extract it with Export-McsBaseSolution.ps1.") }
        foreach ($mm in @($a.mcp | Where-Object { $_ })) { if ($mm -notin @('mail', 'anon', 'auth')) { $errors.Add("$($a.name): mcp '$mm' is invalid (use mail / anon / auth).") } }
    }
    if (-not $cs -or -not $cs.targetTenantId) { $errors.Add("solution.copilotStudio.targetTenantId is required when an MCS agent is planned (the Copilot Studio target tenant).") }
    if (($mcsAgents | Where-Object { $_.type -eq 'MCS-NH' }) -and (-not $cs -or -not $cs.targetEnvironmentId)) {
        $errors.Add("solution.copilotStudio.targetEnvironmentId is required for MCS-NH (GitHub Copilot harness): it must be a PAYG-linked, Dataverse-enabled Copilot Studio environment, or preview fails with EnforcementUsageCredits. Verify it with Test-McsPrereqs.ps1 -Harness MCS-NH -EnvironmentId <id>.")
    }
}

if ($errors.Count -gt 0) {
    Write-Host "Plan validation FAILED:" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Plan validation OK ($($plan.agents.Count) agent(s), UI mode: $($plan.ui.mode))." -ForegroundColor Green
if ($ValidateOnly) { exit 0 }

# Normalize per-agent resourceGroup for the CODE families (ACA/FH/FD). The ACA/FH modules read
# $a.resourceGroup DIRECTLY — the ACA module rewrites the deploy script's $RG constant and emits the
# App Insights `az containerapp update -g <rg>` from it, and the FH module passes it to `azd env set
# AZURE_RESOURCE_GROUP` — so an OMITTED value silently produces a broken `-g ""` / blank $RG and aborts
# the deploy. Derive it deterministically from the naming convention (naming-and-validation.md) when the
# plan does not carry it: isolated => "<agent-name>-rg", shared => solution.sharedResourceGroup (or
# "<prefix>-rg"). MCS agents have no resourceGroup. A value already present is left untouched.
foreach ($a in $plan.agents) {
    if ($a.type -like 'MCS-*') { continue }
    if ($a.PSObject.Properties['resourceGroup'] -and $a.resourceGroup) { continue }
    $rgName = if ($plan.solution.resourceGroupStrategy -eq 'shared') {
        if ($plan.solution.sharedResourceGroup) { $plan.solution.sharedResourceGroup } else { "$prefix-rg" }
    }
    else { "$($a.name)-rg" }
    if ($a.PSObject.Properties['resourceGroup']) { $a.resourceGroup = $rgName }
    else { $a | Add-Member -NotePropertyName resourceGroup -NotePropertyValue $rgName }
}

# ---------------------------------------------------------------- scaffolding
# All generated folders for THIS run live under one per-run root: generated/<prefix>/.
$RunRoot     = Join-Path $OutRoot $prefix
$McpBaseName = if ($prefix) { ($prefix -replace '[^A-Za-z0-9]', '').ToLower() } else { '' }
# Custom MCP ATTACH mode: the ext_ servers come from an EXISTING pair (Custom MCP Creator standalone, or
# another existing custom MCP), so the base name is the CHOSEN pair's name, NOT this lab's prefix. The
# custom-MCP + UI modules key ext_<name>Anon/Auth (and the SPA customScopes) off $McpBaseName, so point it
# at the existing pair before Phase 1. In create mode (or when customMcp is absent/disabled) it is unchanged.
if ($plan.customMcp -and $plan.customMcp.enabled -and "$($plan.customMcp.mode)".Trim().ToLower() -eq 'attach' -and $plan.customMcp.existing -and $plan.customMcp.existing.name) {
    $McpBaseName = ($plan.customMcp.existing.name -replace '[^A-Za-z0-9]', '').ToLower()
}
New-Item -ItemType Directory -Force -Path $RunRoot | Out-Null
# Archive the plan with the run so the per-lab plan survives the next run overwriting the root copy.
try { Copy-Item -LiteralPath $PlanPath -Destination (Join-Path $RunRoot 'a365-deployment-plan.json') -Force -ErrorAction Stop } catch { Write-Host "  note: could not archive the plan to $RunRoot ($($_.Exception.Message))" -ForegroundColor DarkYellow }

# Emit next-commands in EXECUTION order: the web UI and the custom MCP FIRST (so the MCP is deployed +
# registered before the agents and can be attached immediately as each agent is created), then the
# agents — each integrated with its tools/custom MCP right after it is created. Two ordered lists keep
# that order regardless of when each folder is scaffolded; $nextCommands is repointed per phase and the
# dot-sourced modules append to whichever list it currently references.
$preCommands   = New-Object System.Collections.Generic.List[string]  # web UI + custom MCP
$agentCommands = New-Object System.Collections.Generic.List[string]  # per-agent setup/deploy + integration
# agent-name -> custom ext_ servers to attach (OBO only), populated by the custom-MCP module.
$attachByAgent = @{}

# Phase 1 — web UI, then custom MCP (deploy + register + approval-mode note).
$nextCommands = $preCommands
if ($plan.ui.mode -in @('create', 'attach')) { Invoke-ScaffoldUi }
if ($plan.customMcp -and $plan.customMcp.enabled) { Invoke-ScaffoldCustomMcp }

# Phase 2 — agents, each integrated immediately after its own setup/deploy.
$nextCommands = $agentCommands
foreach ($a in $plan.agents) {
    $m = $MAP[$a.type]
    # MCS (Copilot Studio) agents have NO code sample to copy — they are built by transforming a committed
    # base solution zip and importing it with pac. Handle them before the src/robocopy path.
    if ($m.config -eq 'mcs') {
        $dst = Join-Path $RunRoot $a.name
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Invoke-ScaffoldMcsAgent $a $m $dst
        Write-Host "  scaffolded $($a.type) -> generated\$prefix\$($a.name)" -ForegroundColor Cyan
        continue
    }
    $srcPath = Join-Path $repoRoot $m.src
    if (-not (Test-Path -LiteralPath $srcPath)) { Write-Host "  SKIP $($a.type): sample '$($m.src)' not found." -ForegroundColor Yellow; continue }
    $dst = Join-Path $RunRoot $a.name
    if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    # Copy the sample, EXCLUDING heavy/local state up-front (venv, caches, azd env, build output).
    $null = robocopy $srcPath $dst /E `
        /XD '.venv' '__pycache__' '.azure' 'node_modules' 'bin' 'obj' '.git' '.pytest_cache' `
        /XF '.env' 'a365.generated.config.json' 'a365.generated.config.template.json' '*.pyc' `
        /NFL /NDL /NJH /NJS /NP /NC /NS
    if ($LASTEXITCODE -ge 8) { Write-Host "  robocopy failed for $($a.type) (code $LASTEXITCODE)" -ForegroundColor Red; continue }

    switch ($m.config) {
        'aca' { Invoke-ScaffoldAcaAgent $a $m $dst }
        'fh'  { Invoke-ScaffoldFhAgent  $a $m $dst }
        'fd'  { Invoke-ScaffoldFdAgent  $a $m $dst }
    }
    # Integrate this agent immediately: attach its custom BYO MCP (OBO) + any non-Mail Work IQ tool,
    # with permissions, right after its setup/deploy command (Work IQ Mail is already authoritative in
    # ToolingManifest.json via Set-ToolingManifest). Grouped with the agent that needs it.
    Add-AgentCustomAttach $a $dst
    Write-Host "  scaffolded $($a.type) -> generated\$prefix\$($a.name)" -ForegroundColor Cyan
}

# Durable OWNERSHIP tag. A LAB (>=1 agent) stamps a365lab=<prefix> (Azure RGs) / a365lab:<prefix> (Entra
# apps + SPs) on every lab-owned resource via Set-LabTags.ps1 — with CUSTOM names it is the ONLY way the
# Lab Cleaner finds agents whose name does not contain the prefix; with DEFAULT names it keeps the tag
# scheme consistent. A STANDALONE instance (agents == 0 — a web-UI-only plan from the Web UI Creator) must
# NEVER carry a365lab: that tag is exactly what tells the Lab Cleaner / Web UI & MCP Remover / Prompts
# Sender a resource is lab-owned. So for an agent-less plan we emit Set-ComponentTags.ps1 (a365component
# only) instead, honouring the "standalone = a365component WITHOUT a365lab" contract. Both are benign,
# idempotent metadata tags — re-run after the deploys AND on resume (closes any create/tag gap).
$tenantArg = if ($plan.solution.tenantId) { " -TenantId $($plan.solution.tenantId)" } else { '' }
$subArg    = if ($plan.solution.subscriptionId) { $plan.solution.subscriptionId } else { '<subscription-id>' }
if (@($plan.agents).Count -gt 0) {
    $tagScript = (Join-Path $PSScriptRoot 'Set-LabTags.ps1')
    $agentCommands.Add("pwsh -File `"$tagScript`" -Prefix $prefix -Subscription $subArg$tenantArg   # LAB: stamp the durable lab tag a365lab=<prefix> on every lab-owned resource — re-run after each deploy / on resume")
}
elseif ($plan.ui -and $plan.ui.mode -eq 'create') {
    $compScript = (Join-Path $PSScriptRoot 'Set-ComponentTags.ps1')
    $swaName    = if ($plan.ui.name) { $plan.ui.name } else { "$prefix-ui" }
    $agentCommands.Add("pwsh -File `"$compScript`" -SwaName $swaName -Subscription $subArg$tenantArg   # STANDALONE web UI: stamp a365component=web-ui ONLY (never a365lab, so the Lab Cleaner never deletes it)")
}

# ---------------------------------------------------------------- summary
$allCommands = @($preCommands) + @($agentCommands)
Write-Host ""
Write-Host "Scaffolding complete under: $RunRoot" -ForegroundColor Green
Write-Host "NEXT COMMANDS (review before running — none were executed):" -ForegroundColor Yellow
$i = 1
foreach ($c in $allCommands) { Write-Host ("  {0}. {1}" -f $i, $c); $i++ }
Write-Host ""
Write-Host "Reminder: secrets (blueprint client secret, Azure OpenAI key) are entered in the terminal at deploy time, never here." -ForegroundColor DarkGray
