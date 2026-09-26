#requires -Version 5.1
<#
.SYNOPSIS
  Attach the registered knowledge-base MCP server to every OBO, S2S and (best-effort) DW agent of a
  lab created by Lab Builder. STANDALONE and POST-HOC — this script only edits a lab's already-
  generated agent folders; it does not modify Lab Builder itself. Step 4.

.DESCRIPTION
  Reads the lab's deployment plan (generated/<prefix>/a365-deployment-plan.json) and, for each
  OBO/S2S/DW agent:
    * ACA-OBO/S2S/DW and FH-OBO/S2S/DW -> runs `a365 develop add-mcp-servers <serverName>` in the
      directory that holds ToolingManifest.json (agent root, or nested src/<pkg>/ for FH-DW). Writes
      the manifest; a redeploy is needed to take effect.
    * FD-OBO -> merges the server into CUSTOM_MCP_SERVERS_JSON in the agent's .env (redeploy with
      python deploy_agent.py to take effect).
    * FD-S2S -> skipped: Foundry declarative S2S has no tool-attach path (documented, not a bug).

  PREREQUISITE: the server must already be REGISTERED in Agent 365 (deploy-kb-mcp.ps1 emits the
  payload; register it with `a365 develop-mcp register-external-mcp-server`) and ADMIN-APPROVED in
  the M365 admin center. This script does NOT deploy or redeploy agents — it only updates their
  local tool configuration, so it is safe and reversible.

.PARAMETER LabPrefix
  The lab solution prefix (e.g. lab12). Used to locate generated/<prefix>/.
.PARAMETER ServerName
  The Agent 365 server name to attach. Defaults to the serverName recorded in kb.state.json.
.PARAMETER GeneratedRoot
  Override the generated lab root (default: <repo>/generated/<LabPrefix>).
.PARAMETER WhatIf
  Show what would change without editing anything.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)] [string]$LabPrefix,
    [string]$ServerName,
    [string]$GeneratedRoot
)
$ErrorActionPreference = 'Stop'

$stateFile = Join-Path $PSScriptRoot 'kb.state.json'
$state = if (Test-Path $stateFile) { Get-Content $stateFile -Raw | ConvertFrom-Json } else { $null }
if (-not $ServerName) {
    if (-not $state) { throw "No -ServerName and kb.state.json not found." }
    $ServerName = $state.serverName
}
if (-not $ServerName) { throw "Could not determine the server name. Pass -ServerName." }

$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $GeneratedRoot) { $GeneratedRoot = Join-Path $repoRoot "generated\$LabPrefix" }
$planPath = Join-Path $GeneratedRoot 'a365-deployment-plan.json'
if (-not (Test-Path $planPath)) { throw "Deployment plan not found: $planPath" }
$plan = Get-Content $planPath -Raw | ConvertFrom-Json

$gatewayUrl = if ($state.serverUrl) { $state.serverUrl } else { "https://agent365.svc.cloud.microsoft/agents/servers/$ServerName" }
$serverScope = if ($state.serverScope) { $state.serverScope } else { 'Tools.ListInvoke.All' }
$serverAudience = $state.serverAudience   # may be empty until the server is registered
$serverPublisher = $state.serverPublisher
# OBO/S2S + best-effort DW. FD-S2S is skipped (no attach path); DW attaches like ACA/FH (agentic id).
$targetTypes = @('ACA-OBO', 'ACA-S2S', 'ACA-DW', 'FH-OBO', 'FH-S2S', 'FH-DW', 'FD-OBO', 'FD-S2S')

function Update-ToolingManifest {
    <#
      Add or replace the server entry in an agent's ToolingManifest.json, keyed by mcpServerName.
      Writes the full entry (url/scope/audience/publisher) directly, so it does not depend on the
      server being present in the Agent 365 catalog (which requires tenant approval first).
    #>
    param(
        [Parameter(Mandatory)] [string]$ManifestFile,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Url,
        [string]$Scope, [string]$Audience, [string]$Publisher
    )
    $json = Get-Content $ManifestFile -Raw | ConvertFrom-Json
    if (-not $json.PSObject.Properties['mcpServers']) { $json | Add-Member -NotePropertyName mcpServers -NotePropertyValue @() }
    $entry = [ordered]@{ mcpServerName = $Name; mcpServerUniqueName = $Name; url = $Url }
    if ($Scope) { $entry.scope = $Scope }
    if ($Audience) { $entry.audience = $Audience }
    if ($Publisher) { $entry.publisher = $Publisher }
    $kept = @($json.mcpServers | Where-Object { $_.mcpServerName -ne $Name })
    $json.mcpServers = @($kept + [pscustomobject]$entry)
    $json | ConvertTo-Json -Depth 10 | Set-Content $ManifestFile -Encoding utf8
}

function Update-FdEnv {
    <#
      Merge one server entry into the CUSTOM_MCP_SERVERS_JSON value of a FD agent's .env,
      de-duplicating by label. Creates the key (and the file) if missing.
    #>
    param([Parameter(Mandatory)] [string]$EnvFile, [Parameter(Mandatory)] $Entry)

    $lines = if (Test-Path $EnvFile) { @(Get-Content $EnvFile) } else { @() }
    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*CUSTOM_MCP_SERVERS_JSON\s*=') { $idx = $i; break }
    }
    $existing = @()
    if ($idx -ge 0) {
        $val = ($lines[$idx] -replace '^\s*CUSTOM_MCP_SERVERS_JSON\s*=', '').Trim().Trim("'`"")
        if ($val) { try { $existing = @($val | ConvertFrom-Json) } catch { $existing = @() } }
    }
    $merged = @($existing | Where-Object { $_.label -ne $Entry.label })
    $merged += [pscustomobject]$Entry
    $json = ($merged | ConvertTo-Json -Compress -Depth 5)
    if ($merged.Count -eq 1) { $json = "[$json]" }  # ConvertTo-Json emits a bare object for a single item
    $newLine = "CUSTOM_MCP_SERVERS_JSON='$json'"
    if ($idx -ge 0) { $lines[$idx] = $newLine } else { $lines += $newLine }
    Set-Content -Path $EnvFile -Value $lines -Encoding utf8
}

Write-Host "Attaching '$ServerName' to OBO/S2S agents of lab '$LabPrefix'..." -ForegroundColor Cyan
Write-Host "  Gateway URL: $gatewayUrl" -ForegroundColor DarkGray
Write-Host ""

$attached = @(); $skipped = @(); $redeploy = @()

foreach ($agent in $plan.agents) {
    if ($targetTypes -notcontains $agent.type) { continue }
    $folder = Join-Path $GeneratedRoot $agent.name

    if ($agent.type -eq 'FD-S2S') {
        Write-Host "  [skip] $($agent.name) ($($agent.type)) — Foundry declarative S2S has no tool-attach path." -ForegroundColor DarkYellow
        $skipped += $agent.name
        continue
    }
    if (-not (Test-Path $folder)) {
        Write-Host "  [warn] $($agent.name) ($($agent.type)) — folder not found: $folder" -ForegroundColor Yellow
        $skipped += $agent.name
        continue
    }

    if ($agent.type -like 'FD-*') {
        # FD-OBO: merge into CUSTOM_MCP_SERVERS_JSON in .env.
        $envFile = Join-Path $folder '.env'
        $entry = [ordered]@{ label = $ServerName; url = $gatewayUrl; input = 'kb_token' }
        if ($PSCmdlet.ShouldProcess($envFile, "merge CUSTOM_MCP_SERVERS_JSON += $ServerName")) {
            Update-FdEnv -EnvFile $envFile -Entry $entry
        }
        Write-Host "  [ok]   $($agent.name) ($($agent.type)) — CUSTOM_MCP_SERVERS_JSON updated." -ForegroundColor Green
        $attached += $agent.name
        $redeploy += "cd `"$folder`"; python deploy_agent.py   # FD redeploy"
        continue
    }

    # ACA/FH/DW: run a365 develop add-mcp-servers in the directory that holds ToolingManifest.json.
    # ACA-* and FH-OBO/S2S keep it at the agent root; FH-DW keeps it nested under src/<pkg>/.
    $rootManifest = Join-Path $folder 'ToolingManifest.json'
    if (Test-Path $rootManifest) {
        $workdir = $folder
    } else {
        $found = Get-ChildItem -Path $folder -Filter ToolingManifest.json -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
        $workdir = if ($found) { $found.Directory.FullName } else { $null }
    }
    if (-not $workdir) {
        Write-Host "  [warn] $($agent.name) ($($agent.type)) — no ToolingManifest.json under $folder" -ForegroundColor Yellow
        $skipped += $agent.name
        continue
    }
    $manifestFile = Join-Path $workdir 'ToolingManifest.json'
    if ($PSCmdlet.ShouldProcess($manifestFile, "add ToolingManifest entry $ServerName")) {
        if ($serverAudience) {
            # Deterministic: write the full entry directly (no dependency on catalog/approval).
            Update-ToolingManifest -ManifestFile $manifestFile -Name $ServerName -Url $gatewayUrl `
                -Scope $serverScope -Audience $serverAudience -Publisher $serverPublisher
        } else {
            # Fallback: let the CLI resolve scope/audience from the catalog (needs approval first).
            Push-Location $workdir
            try {
                & a365 develop list-available *> $null
                & a365 develop add-mcp-servers $ServerName
                if ($LASTEXITCODE -ne 0) { throw "a365 develop add-mcp-servers exited $LASTEXITCODE" }
            } finally {
                Pop-Location
            }
        }
    }
    Write-Host "  [ok]   $($agent.name) ($($agent.type)) — ToolingManifest.json updated." -ForegroundColor Green
    $attached += $agent.name
    switch -Wildcard ($agent.type) {
        'ACA-DW' { $redeploy += "cd `"$folder`"; ./deploy-aca-DW.ps1  # ACA-DW redeploy"; break }
        'ACA-*'  { $redeploy += "cd `"$folder`"; ./deploy-aca.ps1     # ACA redeploy"; break }
        default  { $redeploy += "cd `"$folder`"; azd deploy           # FH redeploy" }
    }
}

Write-Host ""
Write-Host "Attach summary:" -ForegroundColor Cyan
Write-Host "  Attached: $($attached.Count) -> $($attached -join ', ')"
Write-Host "  Skipped : $($skipped.Count) -> $($skipped -join ', ')"
Write-Host ""
Write-Host "The tool is attached in each agent's config but a REDEPLOY is required to take effect:" -ForegroundColor Yellow
$redeploy | ForEach-Object { Write-Host "  $_" }
