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
            # DW agents prompt for the optional 'ext_UtilityInsights' custom MCP (may be absent in the tenant) and defer the messaging endpoint until the container is deployed.
            $dwNote = if ($a.type -eq 'ACA-DW') { "   # DW: answer N at the 'ext_UtilityInsights' prompt (optional custom MCP — add only when wiring it); after the container deploys, register the endpoint: a365 setup blueprint --endpoint-only --messaging-endpoint https://<fqdn>/api/messages" } else { '' }
            $nextCommands.Add("cd `"$dst`"; a365 setup all --agent-name `"$($a.name)`"$(if($a.type -eq 'ACA-DW'){' --aiteammate'}); .\$($m.deploy) -Subscription $($plan.solution.subscriptionId) -AoaiRg <AOAI_RG> -AoaiAcc $($a.ai.account)$reuse$dwNote")
            if ($a.type -eq 'ACA-DW') {
                # DW publish: register the real endpoint, regenerate the package for THIS blueprint, then upload it in the admin center.
                $nextCommands.Add("cd `"$dst`"; a365 setup blueprint --endpoint-only --messaging-endpoint https://<ACA_DW_FQDN>/api/messages; a365 publish --aiteammate --agent-name `"$($a.name)`"   # answer n + Enter at the manifest prompts; then upload manifest\manifest.zip at admin.microsoft.com > Agents > All agents > Upload custom agent (Publish/Activate), then users hire in Teams")
            }
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
                $proto = if ($a.type -eq 'FH-S2S') { 'responses' } else { 'invocations' }
                # azd provision (FH-OBO/S2S) does NOT create the model deployment nor grant data-plane RBAC:
                # after provision, create the model in the generated account + grant Cognitive Services User, then deploy.
                $fhDep = "cd `"$dst`"; azd env new $($a.name); azd env set AZURE_SUBSCRIPTION_ID $($plan.solution.subscriptionId); azd env set AZURE_TENANT_ID $($plan.solution.tenantId); azd env set AZURE_LOCATION $($plan.solution.region); azd env set AZURE_RESOURCE_GROUP $($a.resourceGroup); azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME $($a.ai.deployment); azd provision"
                $fhModel = "`$acct=(az cognitiveservices account list -g $($a.resourceGroup) --query `"[?kind=='AIServices'].name | [0]`" -o tsv); az cognitiveservices account deployment create -n `$acct -g $($a.resourceGroup) --deployment-name $($a.ai.deployment) --model-name $($a.ai.deployment) --model-version 2025-04-14 --model-format OpenAI --sku-name GlobalStandard --sku-capacity 20"
                $fhRole = "az role assignment create --assignee-object-id (az ad signed-in-user show --query id -o tsv) --assignee-principal-type User --role `"Cognitive Services User`" --scope (az cognitiveservices account show -n `$acct -g $($a.resourceGroup) --query id -o tsv)"
                $nextCommands.Add("$fhDep; $fhModel; $fhRole; azd deploy   # protocol: $proto  (adjust --model-version if not gpt-4.1; RBAC propagates ~2-5min)")
            }
            else {
                # FH-DW hardcodes the agent name in Bicep + scripts (NOT azure.yaml). Rewrite every
                # occurrence to the planned name so DW matches the <prefix>-FH-DW scheme like the others.
                $dwFiles = @(
                    'infra\main.bicep', 'infra\main.json', 'infra\main.parameters.json',
                    'scripts\create-agent-blueprint.ps1', 'scripts\read-logs.ps1', 'scripts\roll-instrumented-version.ps1'
                )
                foreach ($rel in $dwFiles) {
                    $fp = Join-Path $dst $rel
                    if (Test-Path -LiteralPath $fp) {
                        (Get-Content -LiteralPath $fp -Raw).Replace('agentframeworkFH-DW2-agent', $a.name) | Set-Content -LiteralPath $fp
                    }
                }
                # Solution A (governed subscription): the ARM deploymentScript that creates the managed
                # agent identity blueprint needs shared-key storage, which tenant policy may block
                # (KeyBasedAuthenticationNotPermitted). Instead of a policy waiver, create the blueprint
                # OUT-OF-BAND via an Entra ID call between two provisions (see scripts/create-agent-blueprint.ps1).
                $envSet = "azd env new $($a.name); azd env set AZURE_SUBSCRIPTION_ID $($plan.solution.subscriptionId); azd env set AZURE_TENANT_ID $($plan.solution.tenantId); azd env set AZURE_LOCATION $($plan.solution.region); azd env set AZURE_RESOURCE_GROUP $($a.resourceGroup); azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME $($a.ai.deployment)"
                $nextCommands.Add("cd `"$dst`"; $envSet; azd provision   # 1st provision: creates account/project/ACR/model (the blueprint deploymentScript step FAILS under a shared-key storage policy — expected)")
                $nextCommands.Add("cd `"$dst`"; pwsh -File .\scripts\create-agent-blueprint.ps1 -Subscription $($plan.solution.subscriptionId) -ResourceGroup $($a.resourceGroup) -AgentName $($a.name)   # Solution A: MAIB via Entra ID (no storage/shared-key), grants Cognitive Services User, sets AGENT_IDENTITY_BLUEPRINT_CLIENT_ID")
                $nextCommands.Add("cd `"$dst`"; azd provision   # 2nd provision: deploymentScript SKIPPED; finishes Bot + post-provision (agent version, grants, publish)")
            }
        }
        'fd' {
            $envPath = Join-Path $dst '.env'
            $fp = $a.foundryProject
            if ($fp -and $fp -notmatch '/api/projects/') {
                # Prompt-agent SDK needs the PROJECT endpoint (…/api/projects/<project>), not the account endpoint. Derive it (read-only az).
                $acctName = ([uri]$fp).Host.Split('.')[0]
                $proj = az rest --method get --url "https://management.azure.com/subscriptions/$($plan.solution.subscriptionId)/resourceGroups/$($a.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$acctName/projects?api-version=2025-04-01-preview" --query "value[0].name" -o tsv 2>$null
                if ($proj) { if ($proj -like '*/*') { $proj = $proj.Split('/')[-1] }; $fp = "https://$acctName.services.ai.azure.com/api/projects/$proj"; Write-Host "    FD project endpoint derived: $fp" -ForegroundColor DarkGray }
                else { Write-Host "    WARN $($a.name): set FOUNDRY_PROJECT_ENDPOINT manually to https://<acct>.services.ai.azure.com/api/projects/<project>" -ForegroundColor Yellow }
            }
            if ($fp) { Set-EnvValue -Path $envPath -Key 'FOUNDRY_PROJECT_ENDPOINT' -Value $fp }
            Set-EnvValue -Path $envPath -Key 'FOUNDRY_MODEL_NAME' -Value $a.ai.deployment
            Set-EnvValue -Path $envPath -Key 'AGENT_NAME' -Value $a.name
            if ($a.type -eq 'FD-OBO') {
                Set-EnvValue -Path $envPath -Key 'AZURE_TENANT_ID' -Value $plan.solution.tenantId
                Set-EnvValue -Path $envPath -Key 'CLIENT_APP_ID' -Value '<YOUR_AGENT365_CLI_PUBLIC_CLIENT_APP_ID>'
            }
            # FD deploy authors an agent version -> needs Cognitive Services User on the reused Foundry account.
            $fdGrant = "az role assignment create --assignee-object-id (az ad signed-in-user show --query id -o tsv) --assignee-principal-type User --role `"Cognitive Services User`" --scope (az cognitiveservices account show -n $($a.ai.account) -g $($a.resourceGroup) --query id -o tsv)"
            $nextCommands.Add("cd `"$dst`"; $fdGrant; python -m venv .venv; .\.venv\Scripts\Activate.ps1; pip install -r requirements.txt; python deploy_agent.py   # RBAC propagates ~2-5min")
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
    $nextCommands.Add("# UI: create SWA (az staticwebapp create -l eastus2 --sku Free; westeurope may reject new customers), register the SPA app (redirect https://<swa-host> + http://localhost:3000), fill config.js, deploy per docs/setup-web-ui.md, then set UI_ALLOWED_ORIGINS (+ UI_AUDIENCE=<s2s-app-id> for ACA-S2S) on the ACA containers.")
}

# ---------------------------------------------------------------- custom MCP
if ($plan.customMcp -and $plan.customMcp.enabled) {
    $name      = $plan.customMcp.name
    # Every per-copy identifier derives from the (unique) <Name>, so N copies never collide.
    $mcpSlug   = ($name -replace '[^A-Za-z0-9]', '').ToLower()
    $mcpSrc = Join-Path $repoRoot 'custom-mcp'
    $mcpDst = Join-Path $OutRoot "custom-mcp-$mcpSlug"
    if (Test-Path -LiteralPath $mcpDst) { Remove-Item -LiteralPath $mcpDst -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $mcpDst | Out-Null
    $null = robocopy $mcpSrc $mcpDst /E /XD '.venv' '__pycache__' /XF '*.pyc' '.env' /NFL /NDL /NJH /NJS /NP /NC /NS

    $publisher = if ($plan.customMcp.publisher) { $plan.customMcp.publisher } else { 'Contoso' }
    $mcpRegion = if ($plan.customMcp.region) { $plan.customMcp.region } else { $plan.solution.region }
    $mcpRg     = if ($plan.customMcp.resourceGroup) { $plan.customMcp.resourceGroup } else { "$mcpSlug-mcp-rg" }
    $mcpApp    = "$mcpSlug-mcp-ca"
    $mcpEnv    = "$mcpSlug-mcp-cae"
    $servers   = @($plan.customMcp.servers); if (-not $servers) { $servers = @('anon', 'auth') }

    # Rewrite the hardcoded constants in deploy-mcp.ps1.
    $depPath = Join-Path $mcpDst 'deploy-mcp.ps1'
    if (Test-Path -LiteralPath $depPath) {
        $txt = Get-Content -LiteralPath $depPath -Raw
        $txt = [regex]::Replace($txt, '(\$RG\s*=\s*)"[^"]*"',      "`$1`"$mcpRg`"")
        $txt = [regex]::Replace($txt, '(\$APP\s*=\s*)"[^"]*"',     "`$1`"$mcpApp`"")
        $txt = [regex]::Replace($txt, '(\$ENVNAME\s*=\s*)"[^"]*"', "`$1`"$mcpEnv`"")
        $txt = [regex]::Replace($txt, '(\$LOC\s*=\s*)"[^"]*"',     "`$1`"$mcpRegion`"")
        $txt = [regex]::Replace($txt, '(\$IMAGE\s*=\s*)"[^"]*"',   "`$1`"$mcpSlug-mcp:1.0.0`"")
        Set-Content -LiteralPath $depPath -Value $txt
    }

    # Fill the registration JSON files from the templates (the FQDN is filled after the container deploys).
    foreach ($srv in $servers) {
        $tmpl = Join-Path $mcpDst "register-$srv.template.json"
        if (-not (Test-Path -LiteralPath $tmpl)) { continue }
        $j = (Get-Content -LiteralPath $tmpl -Raw).Replace('<NAME>', $name).Replace('<PUBLISHER>', $publisher)
        Set-Content -LiteralPath (Join-Path $mcpDst "register-$srv.json") -Value $j
    }
    Write-Host "  scaffolded custom MCP -> generated\custom-mcp (servers: $($servers -join ', '))" -ForegroundColor Cyan

    # Next-commands: deploy -> register (after admin approval) -> attach per agent.
    $graphArgs = if ($plan.customMcp.propagateToGraph) { " -AuthClientId <AUTH_APP_ID> -AuthTenantId $($plan.solution.tenantId)" } else { '' }
    $nextCommands.Add("cd `"$mcpDst`"; .\deploy-mcp.ps1 -Subscription $($plan.solution.subscriptionId)$graphArgs   # prints the /anon/mcp and /auth/mcp FQDNs")
    foreach ($srv in $servers) {
        $extName = if ($srv -eq 'anon') { "ext_${name}Anon" } else { "ext_${name}Auth" }
        $nextCommands.Add("cd `"$mcpDst`"; # edit register-$srv.json: replace <MCP_FQDN> with the deployed FQDN, then: a365 develop-mcp register-external-mcp-server -f .\register-$srv.json --dry-run; a365 develop-mcp register-external-mcp-server -f .\register-$srv.json   # a tenant admin then approves '$extName' in the M365 admin center (Agents > Requested)")
    }
    $extList = (@($servers | ForEach-Object { if ($_ -eq 'anon') { "ext_${name}Anon" } else { "ext_${name}Auth" } }))
    foreach ($t in @($plan.customMcp.attachTo)) {
        $ag = $plan.agents | Where-Object { $_.type -eq $t } | Select-Object -First 1
        if (-not $ag) { continue }
        # Accumulate the custom ext_ servers; the unified attach section emits one command per agent.
        if (-not $attachByAgent.ContainsKey($ag.name)) { $attachByAgent[$ag.name] = New-Object System.Collections.Generic.List[string] }
        $extList | ForEach-Object { if ($attachByAgent[$ag.name] -notcontains $_) { $attachByAgent[$ag.name].Add($_) } }
    }
    if ($plan.customMcp.propagateToGraph) {
        $nextCommands.Add("# propagate_to_graph: on the ext_${name}Auth app add Microsoft Graph delegated 'User.Read' + admin consent + a client secret, then redeploy deploy-mcp.ps1 with -AuthClientId/-AuthTenantId (secret entered in the terminal). See custom-mcp/README.md.")
    }
}

# ---------------------------------------------------------------- MCP tool attachment (Work IQ / catalog / custom)
# For each ACA-*/FH-* agent, attach the selected registered MCP servers via the documented flow:
#   a365 develop add-mcp-servers <uniqueName...>   (writes ToolingManifest.json; scope/audience from the catalog)
#   a365 setup permissions mcp --agent-name <name> (Global Admin grants the OAuth2 grants to the blueprint)
# The samples ship ToolingManifest.json with mcp_MailTools; if the plan's tools omit it, remove it.
# Reuse the Work IQ MCP token lessons (references/workiq-mcp-integration.md) for any non-Mail Work IQ tool.
foreach ($a in $plan.agents) {
    if ($a.type -like 'FD-*') { continue }  # FD prompt agents wire tools in agent_config.py, not via add-mcp-servers
    $tools = @($a.tools)
    $extras = @($tools | Where-Object { $_ -and $_ -ne 'mcp_MailTools' })
    if ($attachByAgent.ContainsKey($a.name)) { $extras += @($attachByAgent[$a.name] | Where-Object { $extras -notcontains $_ }) }
    $agentDir = Join-Path $OutRoot $a.name
    if ($extras.Count -gt 0) {
        $note = if ($a.type -like 'FH-*') { '   # FH sample code currently wires only Mail — a non-Mail Work IQ tool also needs the code generalization in references/workiq-mcp-integration.md' } else { '   # ACA turn path is manifest-driven — Work IQ token/refresh lessons already apply generically' }
        $nextCommands.Add("cd `"$agentDir`"; a365 develop add-mcp-servers $($extras -join ' '); a365 setup permissions mcp --agent-name `"$($a.name)`"$note")
    }
    # Mail is shipped in the sample manifest; drop it if the plan explicitly excludes it.
    if (($tools.Count -gt 0) -and ($tools -notcontains 'mcp_MailTools')) {
        $nextCommands.Add("cd `"$agentDir`"; a365 develop remove-mcp-servers mcp_MailTools; a365 setup permissions mcp --agent-name `"$($a.name)`"   # Mail deselected for this agent")
    }
}

# ---------------------------------------------------------------- summary
Write-Host ""
Write-Host "Scaffolding complete under: $OutRoot" -ForegroundColor Green
Write-Host "NEXT COMMANDS (review before running — none were executed):" -ForegroundColor Yellow
$i = 1
foreach ($c in $nextCommands) { Write-Host ("  {0}. {1}" -f $i, $c); $i++ }
Write-Host ""
Write-Host "Reminder: secrets (blueprint client secret, Azure OpenAI key) are entered in the terminal at deploy time, never here." -ForegroundColor DarkGray
