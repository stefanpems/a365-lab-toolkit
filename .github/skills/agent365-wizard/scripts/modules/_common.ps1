# Shared scaffolder state: the variant map, the Work IQ MCP permission catalog, the ToolingManifest
# reconciler and the .env writer.
# Dot-sourced by scaffold-from-plan.ps1 into the router scope so every module sees these.

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

# ---------------------------------------------------------------- Work IQ MCP permission catalog
# Agent 365 Work IQ MCP servers use the "legacy shared model" (a365 CLI `setup permissions mcp` doc):
# one shared resource app ($MCP_TOOLING_RESOURCE) with a per-server delegated scope
# `McpServers.<Workload>.All`, PLUS a shared `McpServersMetadata.Read.All` granted alongside ANY
# server. So an agent's MCP permissions = (one per attached server) + the shared metadata scope, and
# NOTHING when it attaches no server. The `add-mcp-servers` CLI fills scope/audience into
# ToolingManifest.json from the live catalog; these constants mirror that catalog so the wizard knows
# the right permission per tool WITHOUT hardcoding a grant.
# Work IQ is DELEGATED-ONLY: usable by OBO and Agentic-User/DW, never pure S2S (see
# references/workiq-mcp-integration.md "Supportability by identity model").
$MCP_TOOLING_RESOURCE = 'ea9ffc3e-8a23-4a7d-836d-234d7c7565c1'  # "Agent 365 Tools" first-party app
$MCP_METADATA_SCOPE   = 'McpServersMetadata.Read.All'          # shared, granted with any server
$MCP_SERVER_URL_BASE  = 'https://agent365.svc.cloud.microsoft/agents/servers'

# Per-server delegated scope by Work IQ server. `enabled` = wizard-selectable + validated end-to-end
# today (ONLY Mail). The rest are listed so the mapping is ready when each tool is enabled and tested;
# their `uniqueName` MUST be confirmed live with `a365 develop list-available` before use (a display
# name does not always map 1:1 to the uniqueName). Scopes verified against the A365 blueprint OAuth2
# grant reference (foundry-hosted/dw/scripts/create-blueprintsp-oauth2-grants.ps1).
$WORKIQ_MCP_CATALOG = @(
    @{ workload = 'Mail';                uniqueName = 'mcp_MailTools'; scope = 'McpServers.Mail.All';             enabled = $true  }
    @{ workload = 'Calendar';            uniqueName = $null;           scope = 'McpServers.Calendar.All';         enabled = $false }
    @{ workload = 'Teams';               uniqueName = $null;           scope = 'McpServers.Teams.All';            enabled = $false }
    @{ workload = 'Copilot';             uniqueName = $null;           scope = 'McpServers.CopilotMCP.All';       enabled = $false }
    @{ workload = 'OneDrive/SharePoint'; uniqueName = $null;           scope = 'McpServers.OneDriveSharepoint.All'; enabled = $false }
    @{ workload = 'SharePoint Lists';    uniqueName = $null;           scope = 'McpServers.SharepointLists.All';  enabled = $false }
    @{ workload = 'User';                uniqueName = $null;           scope = 'McpServers.Me.All';               enabled = $false }
    @{ workload = 'Word';                uniqueName = $null;           scope = 'McpServers.Word.All';             enabled = $false }
    @{ workload = 'Excel';               uniqueName = $null;           scope = 'McpServers.Excel.All';            enabled = $false }
    @{ workload = 'PowerPoint';          uniqueName = $null;           scope = 'McpServers.PowerPoint.All';       enabled = $false }
    @{ workload = 'Files';               uniqueName = $null;           scope = 'McpServers.Files.All';            enabled = $false }
    @{ workload = 'Knowledge';           uniqueName = $null;           scope = 'McpServers.Knowledge.All';        enabled = $false }
    @{ workload = 'Dataverse';           uniqueName = $null;           scope = 'McpServers.Dataverse.All';        enabled = $false }
    @{ workload = 'Dataverse (custom)';  uniqueName = $null;           scope = 'McpServers.DataverseCustom.All';  enabled = $false }
    @{ workload = 'D365 Sales';          uniqueName = $null;           scope = 'McpServers.D365Sales.All';        enabled = $false }
    @{ workload = 'D365 Service';        uniqueName = $null;           scope = 'McpServers.D365Service.All';      enabled = $false }
    @{ workload = 'ERP Analytics';       uniqueName = $null;           scope = 'McpServers.ERPAnalytics.All';     enabled = $false }
    @{ workload = 'MCP Management';      uniqueName = $null;           scope = 'McpServers.Management.All';        enabled = $false }
    @{ workload = 'Developer';           uniqueName = $null;           scope = 'McpServers.Developer.All';        enabled = $false }
    @{ workload = 'M365 Admin';          uniqueName = $null;           scope = 'McpServers.M365Admin.All';        enabled = $false }
    @{ workload = 'Admin 365 Graph';     uniqueName = $null;           scope = 'McpServers.Admin365Graph.All';    enabled = $false }
    @{ workload = 'Discovery/Answers';   uniqueName = $null;           scope = 'McpServers.DASearch.All';         enabled = $false }
    @{ workload = 'Web Search';          uniqueName = $null;           scope = 'McpServers.WebSearch.All';        enabled = $false }
)

# Look up the delegated scope for a Work IQ server uniqueName (only Mail is confirmed today).
function Get-WorkIQScope {
    param([string]$UniqueName)
    ($WORKIQ_MCP_CATALOG | Where-Object { $_.uniqueName -eq $UniqueName } | Select-Object -First 1).scope
}

# ---------------------------------------------------------------- Foundry-resource strategy
# All FH + FD agents share ONE Foundry footprint (account + project + model deployment) when the
# optional solution.foundry block is present, instead of one Foundry account per agent. Two modes:
#   create-shared  = the wizard provisions ONE account + project (<prefix>) + model (gpt-4.1) in
#                    <prefix>-foundry-rg; the FIRST FH agent runs azd provision, the rest azd deploy
#                    into it; FD deploys into it too. (The azd account name is generated, so the
#                    shared endpoint/project-id are captured post-provision and reused — placeholder
#                    tokens below are substituted by the agent from the provisioning step's output.)
#   reuse-existing = every FH/FD agent deploys into an existing account+project the user supplies
#                    (foundry.endpoint/account/existingResourceGroup); no azd provision. This is also
#                    the resilient path when new-account hosted-agent provisioning is failing service-side.
# When the block is ABSENT the legacy per-agent behaviour is unchanged (each FH agent provisions its
# own account in its own RG; FD reuses the agent's own foundryProject).
$SHARED_FOUNDRY_ENDPOINT_TOKEN = '<SHARED_FOUNDRY_PROJECT_ENDPOINT>'  # create-shared: agent fills from the provisioning step
$SHARED_FOUNDRY_PROJECTID_TOKEN = '<SHARED_FOUNDRY_PROJECT_ID>'

# Resolve the effective Foundry target for one FH/FD agent from solution.foundry (fallback = agent fields).
function Resolve-FoundryTarget {
    param($plan, $a)
    $t = [ordered]@{
        mode          = 'per-agent'          # 'per-agent' (legacy) | 'create-shared' | 'reuse-existing'
        resourceGroup = $a.resourceGroup
        account       = $a.ai.account
        endpoint      = $a.foundryProject
        deployment    = $a.ai.deployment
        project       = $null
    }
    $f = $plan.solution.foundry
    if ($f -and $f.mode) {
        $t.mode = $f.mode
        if ($f.deployment) { $t.deployment = $f.deployment }
        if ($f.mode -eq 'reuse-existing') {
            if ($f.endpoint) { $t.endpoint = $f.endpoint }
            if ($f.account) { $t.account = $f.account }
            if ($f.existingResourceGroup) { $t.resourceGroup = $f.existingResourceGroup }
            # Parse the project name from the endpoint (…/api/projects/<project>) so the caller can build
            # AZURE_AI_PROJECT_ID for azd deploy.
            if ($t.endpoint -and $t.endpoint -match '/api/projects/([^/?]+)') { $t.project = $matches[1] }
        }
        elseif ($f.mode -eq 'create-shared') {
            if ($f.resourceGroup) { $t.resourceGroup = $f.resourceGroup }
            if ($f.project) { $t.project = $f.project }
            $t.endpoint = $SHARED_FOUNDRY_ENDPOINT_TOKEN   # discovered post-provision, agent substitutes
        }
    }
    return $t
}

# Name of the FH agent that provisions the shared account (create-shared only): the first FH-OBO/FH-S2S
# in plan order. The rest (and FD) deploy into it. FH-DW is EXCLUDED — it bundles a Bot Service +
# managed-agent-identity blueprint (bicep) that are DW-specific, so DW keeps its own account. Returns
# $null when no shared-capable FH agent / not create-shared.
function Get-SharedFoundryProvisioner {
    param($plan)
    if (-not ($plan.solution.foundry -and $plan.solution.foundry.mode -eq 'create-shared')) { return $null }
    ($plan.agents | Where-Object { $_.type -in @('FH-OBO', 'FH-S2S') } | Select-Object -First 1).name
}

# Extra UI-tester grants from ui.permissions.foundryAccess: the additional people (BEYOND the signed-in
# deploy identity, which every FH/FD deploy already grants) who need Cognitive Services User on the SHARED
# Foundry account so the FH/FD tabs work in the SPA. Each list entry is a UPN or a GROUP object id, and a
# single entry may itself be a COMMA-SEPARATED list of UPNs. Emitted ONCE per run (there is one shared
# account). $ScopeExpr must resolve to the account resource id in the emitted shell (it may contain a
# literal $acct for the create-shared provisioner, where the azd-generated account name lives in $acct).
$script:FoundryAccessEmitted = $false
function Get-FoundryAccessGrants {
    param($plan, [string]$ScopeExpr)
    if ($script:FoundryAccessEmitted) { return @() }
    $ids = @()
    if ($plan.ui -and $plan.ui.permissions -and $plan.ui.permissions.foundryAccess) {
        foreach ($e in @($plan.ui.permissions.foundryAccess)) { foreach ($p in ("$e" -split ',')) { $t = $p.Trim(); if ($t) { $ids += $t } } }
    }
    if ($ids.Count -eq 0) { return @() }
    $cmds = @()
    foreach ($id in $ids) {
        if ($id -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
            # A GUID = a group object id (grant the role to the group once; manage membership there).
            $cmds += "az role assignment create --assignee-object-id $id --assignee-principal-type Group --role `"Cognitive Services User`" --scope $ScopeExpr   # UI tester group $id"
        }
        else {
            # A UPN = resolve to the user's object id at run time (avoids a name-vs-id ambiguity).
            $cmds += "az role assignment create --assignee-object-id (az ad user show --id `"$id`" --query id -o tsv) --assignee-principal-type User --role `"Cognitive Services User`" --scope $ScopeExpr   # UI tester $id"
        }
    }
    $script:FoundryAccessEmitted = $true
    return $cmds
}

# ---------------------------------------------------------------- Azure OpenAI strategy (ACA)
# All ACA agents share ONE Azure OpenAI footprint (account + model deployment) when the optional
# solution.azureOpenAI block is present, mirroring solution.foundry for FH/FD. Two modes:
#   create-shared  = the wizard creates a LAB-OWNED account (<prefix>aoai) + deployment in
#                    <prefix>-aoai-rg before the ACA deploys; the FIRST ACA agent emits the create
#                    command, the rest reuse it. The Lab Cleaner deletes+purges it via the prefix.
#   reuse-existing = every ACA agent deploys against an existing account the user supplies
#                    (account/existingResourceGroup); nothing is created and cleanup never touches it.
# When the block is ABSENT the legacy per-agent behaviour is unchanged (each agent uses its own a.ai).

# Resolve the effective Azure OpenAI target for one ACA agent from solution.azureOpenAI (fallback = a.ai).
function Resolve-AoaiTarget {
    param($plan, $a)
    $t = [ordered]@{
        mode          = 'per-agent'        # 'per-agent' (legacy) | 'create-shared' | 'reuse-existing'
        resourceGroup = $null              # AOAI account RG (deploy -AoaiRg / MI role scope); $null = unknown
        account       = $a.ai.account
        deployment    = $a.ai.deployment
        auth          = if ($a.ai.auth) { $a.ai.auth } else { 'managed-identity' }
    }
    $o = $plan.solution.azureOpenAI
    if ($o -and $o.mode) {
        $t.mode = $o.mode
        if ($o.deployment) { $t.deployment = $o.deployment }
        if ($o.auth) { $t.auth = $o.auth }
        if ($o.mode -eq 'create-shared') {
            $t.account = if ($o.account) { $o.account } else { "$(($plan.solution.prefix -replace '[^a-z0-9]', '').ToLower())aoai" }
            $t.resourceGroup = if ($o.resourceGroup) { $o.resourceGroup } else { "$($plan.solution.prefix)-aoai-rg" }
        }
        elseif ($o.mode -eq 'reuse-existing') {
            if ($o.account) { $t.account = $o.account }
            if ($o.existingResourceGroup) { $t.resourceGroup = $o.existingResourceGroup }
        }
    }
    return $t
}

# Name of the ACA agent that creates the shared account (create-shared only): the first ACA-* in plan
# order. The rest reuse it. Returns $null when not create-shared / no ACA agent.
function Get-SharedAoaiProvisioner {
    param($plan)
    if (-not ($plan.solution.azureOpenAI -and $plan.solution.azureOpenAI.mode -eq 'create-shared')) { return $null }
    ($plan.agents | Where-Object { $_.type -like 'ACA-*' } | Select-Object -First 1).name
}

# ---------------------------------------------------------------- ToolingManifest reconciler
# Make a scaffolded ToolingManifest.json AUTHORITATIVE: keep exactly the servers whose uniqueName is
# in $Tools, drop the rest. The samples ship `mcp_MailTools`, so this KEEPS Mail when selected and
# REMOVES it when not (fixing the S2S over-grant: `a365 setup all` reads this manifest, so a manifest
# without Mail grants no Mail permission). It only filters entries already present (uses their shipped
# scope/audience — no hand-written values, so it is correct on any tenant/permission-model). Custom
# `ext_*` servers are NOT added here: they are appended later by `a365 develop add-mcp-servers` from
# the catalog once the server is registered/approved.
function Set-ToolingManifest {
    param([string]$Path, [string[]]$Tools)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try { $doc = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return }
    $wanted = @($Tools)
    $kept = @(@($doc.mcpServers) | Where-Object { $_ -and ($wanted -contains $_.mcpServerUniqueName) })
    # Force an array shape for mcpServers even with 0/1 entries.
    $ordered = @($kept | ForEach-Object {
        $o = [ordered]@{}
        foreach ($p in $_.PSObject.Properties) { $o[$p.Name] = $p.Value }
        $o
    })
    # ConvertTo-Json on an empty array yields "[]"; on one element yields an object — normalize to array.
    $arrJson = ($ordered | ConvertTo-Json -Depth 8)
    if ($ordered.Count -eq 0) { $arrJson = '[]' }
    elseif ($ordered.Count -eq 1) { $arrJson = '[' + $arrJson + ']' }
    $out = "{`n  `"mcpServers`": $arrJson`n}"
    Set-Content -LiteralPath $Path -Value $out -Encoding utf8
}

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
