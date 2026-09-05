#requires -Version 5.1
<#
.SYNOPSIS
  Validate an Agent 365 deployment plan and scaffold per-variant folders + the web UI config.
.DESCRIPTION
  Reads a SECRET-FREE JSON plan (a365-deployment-plan.json) and, for each agent, copies the matching
  repo sample into generated/<agent-name>/ and fills its tenant-specific config from the plan. It
  parameterizes the ACA deploy script constants (RG / region / app / env — they are HARDCODED in the
  samples, not parameters) and generates generated/ui/config.js when a UI is requested.

  This script performs NO cloud mutations and runs NO deploys. It only reads the repo and writes
  under generated/. It prints the exact next commands for the user to run.
.PARAMETER Plan
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

# variant -> source sample folder + deploy script + config kind
$MAP = @{
    'ACA-OBO' = @{ src = 'aca\obo';               deploy = 'deploy-aca.ps1';      config = 'aca' }
    'ACA-S2S' = @{ src = 'aca\s2s';               deploy = 'deploy-aca-S2S.ps1';  config = 'aca' }
    'ACA-DW'  = @{ src = 'aca\dw';                deploy = 'deploy-aca-DW.ps1';   config = 'aca' }
    'FH-OBO'  = @{ src = 'foundry-hosted\obo';    deploy = $null;                 config = 'fh'  }
    'FH-S2S'  = @{ src = 'foundry-hosted\s2s';    deploy = $null;                 config = 'fh'  }
    'FH-DW'   = @{ src = 'foundry-hosted\dw';     deploy = $null;                 config = 'fh'  }
    'FD-OBO'  = @{ src = 'foundry-declarative\obo'; deploy = $null;               config = 'fd'  }
    'FD-S2S'  = @{ src = 'foundry-declarative\s2s'; deploy = $null;               config = 'fd'  }
}

# ---------------------------------------------------------------- validation
$errors = New-Object System.Collections.Generic.List[string]
$prefix = $plan.solution.prefix
if (-not $prefix) { $errors.Add('solution.prefix is required.') }
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

function Set-EnvValue {
    param([string]$Path, [string]$Key, [string]$Value)
    $lines = if (Test-Path -LiteralPath $Path) { @(Get-Content -LiteralPath $Path) } else { @() }
    $set = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*#?\s*$([regex]::Escape($Key))=") { $lines[$i] = "$Key=$Value"; $set = $true }
    }
    if (-not $set) { $lines = @($lines) + "$Key=$Value" }
    Set-Content -LiteralPath $Path -Value $lines -Encoding utf8
}

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
        'aca' {
            # a365.config.json from the .example, filled from the plan.
            $cfg = @{
                tenantId                  = $plan.solution.tenantId
                clientAppId               = '<YOUR_AGENT365_CLI_PUBLIC_CLIENT_APP_ID>'
                agentIdentityDisplayName  = $a.displayNames.identity
                agentBlueprintDisplayName = $a.displayNames.blueprint
                agentDescription          = $a.name
                aiTeammate                = ($a.type -eq 'ACA-DW')
                useBlueprint              = $true
            }
            $cfg | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dst 'a365.config.json')
            # Parameterize the hardcoded constants in the deploy script.
            $app = ($a.name -replace '[^A-Za-z0-9-]', '-').ToLower()
            $rg  = $a.resourceGroup
            $env = "$app-env"
            $deployPath = Join-Path $dst $m.deploy
            if (Test-Path -LiteralPath $deployPath) {
                $txt = Get-Content -LiteralPath $deployPath -Raw
                $txt = [regex]::Replace($txt, '(\$RG\s*=\s*)"[^"]*"',      "`$1`"$rg`"")
                $txt = [regex]::Replace($txt, '(\$APP\s*=\s*)"[^"]*"',     "`$1`"$app`"")
                $txt = [regex]::Replace($txt, '(\$ENVNAME\s*=\s*)"[^"]*"', "`$1`"$env`"")
                # Pin region: single-entry probe list (obo) or $LOC constant (s2s/dw).
                $txt = [regex]::Replace($txt, '(?s)\$REGIONS\s*=\s*@\([^)]*\)', "`$REGIONS = @(`"$($plan.solution.region)`")")
                $txt = [regex]::Replace($txt, '(\$LOC\s*=\s*)"[^"]*"',     "`$1`"$($plan.solution.region)`"")
                Set-Content -LiteralPath $deployPath -Value $txt
            }
            $reuse = if ($plan.solution.resourceGroupStrategy -eq 'shared') { ' -ReuseEnv' } else { '' }
            $nextCommands.Add("cd `"$dst`"; a365 setup all --agent-name `"$($a.name)`"$(if($a.type -eq 'ACA-DW'){' --aiteammate'}); .\$($m.deploy) -Subscription $($plan.solution.subscriptionId) -AoaiRg <AOAI_RG> -AoaiAcc $($a.ai.account)$reuse")
        }
        'fh' {
            # azure.yaml: rename the service + kind name to the planned agent name.
            $ay = Join-Path $dst 'azure.yaml'
            if (Test-Path -LiteralPath $ay) {
                $txt = Get-Content -LiteralPath $ay -Raw
                $txt = [regex]::Replace($txt, 'agentframeworkFH-(OBO|S2S|DW)\d*-agent', $a.name)
                Set-Content -LiteralPath $ay -Value $txt
            }
            if ($a.type -ne 'FH-DW') {
                $envPath = Join-Path $dst '.env'
                if ($a.foundryProject) { Set-EnvValue -Path $envPath -Key 'FOUNDRY_PROJECT_ENDPOINT' -Value $a.foundryProject }
                Set-EnvValue -Path $envPath -Key 'AZURE_AI_MODEL_DEPLOYMENT_NAME' -Value $a.ai.deployment
            }
            $proto = if ($a.type -eq 'FH-S2S') { 'responses' } else { 'invocations' }
            $nextCommands.Add("cd `"$dst`"; azd env new $($a.name); azd env set AZURE_SUBSCRIPTION_ID $($plan.solution.subscriptionId); azd env set AZURE_TENANT_ID $($plan.solution.tenantId); azd env set AZURE_LOCATION $($plan.solution.region); azd env set AZURE_RESOURCE_GROUP $($a.resourceGroup); azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME $($a.ai.deployment); azd provision; azd deploy   # protocol: $proto")
        }
        'fd' {
            $envPath = Join-Path $dst '.env'
            if ($a.foundryProject) { Set-EnvValue -Path $envPath -Key 'FOUNDRY_PROJECT_ENDPOINT' -Value $a.foundryProject }
            Set-EnvValue -Path $envPath -Key 'FOUNDRY_MODEL_NAME' -Value $a.ai.deployment
            Set-EnvValue -Path $envPath -Key 'AGENT_NAME' -Value $a.name
            if ($a.type -eq 'FD-OBO') {
                Set-EnvValue -Path $envPath -Key 'AZURE_TENANT_ID' -Value $plan.solution.tenantId
                Set-EnvValue -Path $envPath -Key 'CLIENT_APP_ID' -Value '<YOUR_AGENT365_CLI_PUBLIC_CLIENT_APP_ID>'
            }
            $nextCommands.Add("cd `"$dst`"; python -m venv .venv; .\.venv\Scripts\Activate.ps1; pip install -r requirements.txt; python deploy_agent.py")
        }
    }
    Write-Host "  scaffolded $($a.type) -> generated\$($a.name)" -ForegroundColor Cyan
}

# ---------------------------------------------------------------- web UI
if ($plan.ui.mode -in @('create', 'attach')) {
    $uiDst = Join-Path $OutRoot 'ui'
    if (Test-Path -LiteralPath $uiDst) { Remove-Item -LiteralPath $uiDst -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path $repoRoot 'ui') -Destination $uiDst -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $uiDst 'config.js') -Force -ErrorAction SilentlyContinue

    $clientId  = if ($plan.ui.mode -eq 'attach') { $plan.ui.existing.spaAppId } else { '<YOUR_SPA_APP_ID>' }
    $exposeTypes = @($plan.ui.expose | ForEach-Object { $_.agentType })
    $uiAgents = New-Object System.Collections.Generic.List[object]
    foreach ($t in $exposeTypes) {
        if ($t -like '*-DW') { continue }  # DW never exposed via the SPA
        $ag = $plan.agents | Where-Object { $_.type -eq $t } | Select-Object -First 1
        if (-not $ag) { continue }
        $entry = switch ($t) {
            'ACA-OBO' { [ordered]@{ id='obo'; kind='aca'; name="$($ag.name) (ACA, OBO)"; description='OBO agent; /chat sends mail from your mailbox.'; apiBase='https://<YOUR_ACA_OBO_FQDN>'; scope='ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/McpServers.Mail.All' } }
            'ACA-S2S' { [ordered]@{ id='s2s'; kind='aca'; name="$($ag.name) (ACA, S2S)"; description='S2S blueprint agent; own identity.'; apiBase='https://<YOUR_ACA_S2S_FQDN>'; scope='api://<YOUR_ACA_S2S_APP_ID>/access_agent_as_user' } }
            'FH-OBO'  { [ordered]@{ id='obo-fh'; kind='foundry-invocations'; name="$($ag.name) (FH, OBO)"; description='Foundry Hosted OBO; gateway auth + mail_token.'; endpoint='https://<ACCOUNT>.services.ai.azure.com/api/projects/<PROJECT>/agents/'+$ag.name+'/endpoint/protocols/invocations?api-version=v1'; endpointScope='https://ai.azure.com/.default'; mailScope='ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/McpServers.Mail.All'; sessionPrefix='obo' } }
            'FH-S2S'  { [ordered]@{ id='s2s-fh'; kind='foundry-responses'; name="$($ag.name) (FH, S2S)"; description='Foundry Hosted S2S; own identity.'; endpoint='https://<ACCOUNT>.services.ai.azure.com/api/projects/<PROJECT>/agents/'+$ag.name+'/endpoint/protocols/openai/responses?api-version=v1'; endpointScope='https://ai.azure.com/.default' } }
            'FD-OBO'  { [ordered]@{ id='obo-fd'; kind='foundry-prompt'; name="$($ag.name) (FD, OBO)"; description='Foundry prompt OBO; project Responses + mail_token.'; endpoint='https://<ACCOUNT>.services.ai.azure.com/api/projects/<PROJECT>/openai/v1/responses'; endpointScope='https://ai.azure.com/.default'; agentName=$ag.name; mailScope='ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/McpServers.Mail.All' } }
            'FD-S2S'  { [ordered]@{ id='s2s-fd'; kind='foundry-prompt'; name="$($ag.name) (FD, S2S)"; description='Foundry prompt S2S; own identity.'; endpoint='https://<ACCOUNT>.services.ai.azure.com/api/projects/<PROJECT>/openai/v1/responses'; endpointScope='https://ai.azure.com/.default'; agentName=$ag.name } }
            default   { $null }
        }
        if ($entry) { $uiAgents.Add($entry) }
    }
    $appConfig = [ordered]@{
        msal   = [ordered]@{ clientId = $clientId; authority = "https://login.microsoftonline.com/$($plan.solution.tenantId)" }
        agents = $uiAgents
    }
    $json = $appConfig | ConvertTo-Json -Depth 8
    "// Generated by scaffold-from-plan.ps1 — fill <PLACEHOLDER> FQDNs/endpoints after each agent deploys.`nwindow.APP_CONFIG = $json;" |
        Set-Content -LiteralPath (Join-Path $uiDst 'config.js')
    Write-Host "  scaffolded UI ($($plan.ui.mode)) -> generated\ui\config.js ($($uiAgents.Count) tab(s))" -ForegroundColor Cyan
    $nextCommands.Add("# UI: register the SPA app (redirect https://<swa-host> + http://localhost:3000), fill config.js FQDNs, then deploy per docs/setup-web-ui.md")
}

# ---------------------------------------------------------------- summary
Write-Host ""
Write-Host "Scaffolding complete under: $OutRoot" -ForegroundColor Green
Write-Host "NEXT COMMANDS (review before running — none were executed):" -ForegroundColor Yellow
$i = 1
foreach ($c in $nextCommands) { Write-Host ("  {0}. {1}" -f $i, $c); $i++ }
Write-Host ""
Write-Host "Reminder: secrets (blueprint client secret, Azure OpenAI key) are entered in the terminal at deploy time, never here." -ForegroundColor DarkGray
