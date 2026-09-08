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
