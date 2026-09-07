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
. (Join-Path $moduleDir 'scaffold.ui.ps1')
. (Join-Path $moduleDir 'scaffold.mcp.ps1')
. (Join-Path $moduleDir 'scaffold.tools.ps1')

# ---------------------------------------------------------------- validation
$errors = New-Object System.Collections.Generic.List[string]
$prefix = $plan.solution.prefix
if (-not $prefix) { $errors.Add('solution.prefix is required.') }
elseif ($prefix -notmatch '^[a-z]') { $errors.Add("solution.prefix '$prefix' must start with a lowercase letter (Azure Container Apps / managed identities reject names starting with a digit or symbol).") }
if (-not $plan.solution.region) { $errors.Add('solution.region is required.') }
if (-not $plan.agents -or $plan.agents.Count -eq 0) { $errors.Add('at least one agent is required.') }

foreach ($a in $plan.agents) {
    if (-not $MAP.ContainsKey($a.type)) { $errors.Add("unknown agent type '$($a.type)'."); continue }
    if (-not $a.name) { $errors.Add("agent of type $($a.type) is missing 'name'.") }
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

# Shared-RG + ACA safety: the generic deploy-aca.ps1 deletes its RG; only S2S/DW named scripts are safe.
if ($plan.solution.resourceGroupStrategy -eq 'shared') {
    foreach ($a in ($plan.agents | Where-Object { $_.type -eq 'ACA-OBO' })) {
        $errors.Add("$($a.name): ACA-OBO uses the destructive deploy-aca.ps1 (deletes its RG). A shared RG is unsafe for ACA-OBO — use 'isolated', or pass -ReuseEnv at deploy time.")
    }
}

# Custom MCP validation (optional).
if ($plan.customMcp -and $plan.customMcp.enabled) {
    $mcpName = $plan.customMcp.name
    if (-not $mcpName) { $errors.Add('customMcp.enabled is true but customMcp.name is missing.') }
    elseif ($mcpName -notmatch '^[A-Za-z][A-Za-z0-9]*$') { $errors.Add("customMcp.name '$mcpName' must start with a letter and contain only letters/digits.") }
    elseif ($mcpName.Length -gt 12) { $errors.Add("customMcp.name '$mcpName' is $($mcpName.Length) chars (max 12; ext_<Name>Anon/Auth must stay <= 20).") }
    foreach ($t in @($plan.customMcp.attachTo)) {
        if ($t -like 'FD-*') { $errors.Add("customMcp.attachTo '$t': FD (prompt) agents are not supported for custom MCP attachment (they use M365 app-manifest agent connectors).") }
        elseif (-not ($plan.agents | Where-Object { $_.type -eq $t })) { $errors.Add("customMcp.attachTo '$t' is not among the planned agents.") }
    }
}

# agents[].tools validation (registered MCP server unique names to attach, e.g. mcp_MailTools, ext_Foo).
foreach ($a in $plan.agents) {
    foreach ($tool in @($a.tools)) {
        if ($tool -notmatch '^(mcp_|ext_)') { $errors.Add("$($a.name): tool '$tool' must be a registered server unique name starting with 'mcp_' or 'ext_' (see 'a365 develop list-available').") }
    }
    if (($a.type -like 'FD-*') -and (@($a.tools).Count -gt 0)) {
        $errors.Add("$($a.name): FD (prompt) agents do not attach tools via ToolingManifest/add-mcp-servers; leave 'tools' empty (the FD sample wires its tools in agent_config.py).")
    }
}

if ($errors.Count -gt 0) {
    Write-Host "Plan validation FAILED:" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Plan validation OK ($($plan.agents.Count) agent(s), UI mode: $($plan.ui.mode))." -ForegroundColor Green
if ($ValidateOnly) { exit 0 }

# ---------------------------------------------------------------- scaffolding
New-Item -ItemType Directory -Force -Path $OutRoot | Out-Null
$nextCommands = New-Object System.Collections.Generic.List[string]
# agent-name -> set of MCP server unique names to attach (Work IQ / catalog / custom). Emitted once at the end.
$attachByAgent = @{}

foreach ($a in $plan.agents) {
    $m = $MAP[$a.type]
    $srcPath = Join-Path $repoRoot $m.src
    if (-not (Test-Path -LiteralPath $srcPath)) { Write-Host "  SKIP $($a.type): sample '$($m.src)' not found." -ForegroundColor Yellow; continue }
    $dst = Join-Path $OutRoot $a.name
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
    Write-Host "  scaffolded $($a.type) -> generated\$($a.name)" -ForegroundColor Cyan
}

# ---------------------------------------------------------------- web UI
if ($plan.ui.mode -in @('create', 'attach')) { Invoke-ScaffoldUi }

# ---------------------------------------------------------------- custom MCP
if ($plan.customMcp -and $plan.customMcp.enabled) { Invoke-ScaffoldCustomMcp }

# ---------------------------------------------------------------- MCP tool attachment (Work IQ / catalog / custom)
Invoke-ScaffoldToolAttachment

# ---------------------------------------------------------------- summary
Write-Host ""
Write-Host "Scaffolding complete under: $OutRoot" -ForegroundColor Green
Write-Host "NEXT COMMANDS (review before running — none were executed):" -ForegroundColor Yellow
$i = 1
foreach ($c in $nextCommands) { Write-Host ("  {0}. {1}" -f $i, $c); $i++ }
Write-Host ""
Write-Host "Reminder: secrets (blueprint client secret, Azure OpenAI key) are entered in the terminal at deploy time, never here." -ForegroundColor DarkGray
