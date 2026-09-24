<#
.SYNOPSIS
  Step 4 (Sentinel scenario only) - Deploys the patched Copilot Studio and Foundry packs (analytic rules, hunting
  queries, watchlists) to a Microsoft Sentinel workspace, then disables the rules listed in -DisableRules.
.DESCRIPTION
  Sentinel rejects analytic rules whose tables do not exist yet: the script first checks that AppEvents and
  AppDependencies exist in the workspace (connect the telemetry and send a few prompts first). Re-running the
  script updates the same rules and RE-ENABLES the rules listed in -DisableRules before disabling them again.
.EXAMPLE
  .\04-Deploy-SentinelPacks.ps1 -SentinelWorkspaceResourceId $ws
  .\04-Deploy-SentinelPacks.ps1 -SentinelWorkspaceResourceId $ws -Packs Foundry_Agents -ValidateOnly
#>
param(
    [Parameter(Mandatory)][string] $SentinelWorkspaceResourceId,
    [string] $RepoPath,
    [ValidateSet('CopilotStudio', 'Foundry_Agents')][string[]] $Packs = @('CopilotStudio', 'Foundry_Agents'),
    [bool] $EnableAnalyticRules = $true,
    [string[]] $DisableRules = @('Copilot Studio - Off-hours or non-published-channel activity',
                                 'Foundry - Off-hours or anomalous-geo agent activity'),
    [switch] $ValidateOnly,
    [switch] $SkipTableCheck
)
. (Join-Path $PSScriptRoot '_common.ps1')
if (-not $RepoPath) { $RepoPath = $DefaultRepoPath }
$w = Split-ResourceId $SentinelWorkspaceResourceId
$root = Get-PacksRoot $RepoPath

if (-not $SkipTableCheck -and -not $ValidateOnly) {
    $need = @{ CopilotStudio = @('AppEvents', 'AppDependencies'); Foundry_Agents = @('AppDependencies') }
    foreach ($t in ($Packs | ForEach-Object { $need[$_] } | Select-Object -Unique)) {
        try { Invoke-LaQuery -WorkspaceResourceId $SentinelWorkspaceResourceId -Timespan 'P1D' -Query "$t | take 1" | Out-Null }
        catch { throw "Table $t does not exist yet in $($w.Name). Connect App Insights (step 2), send a few prompts, wait 10-15 min and retry." }
    }
}

foreach ($p in $Packs) {
    $tpl = Join-Path $root "$p\Deploy\azuredeploy.json"
    if (-not (Test-Path $tpl)) { throw "Template not found: $tpl (run 01-Prepare-Packs.ps1 first)" }
    $verb = if ($ValidateOnly) { 'validate' } else { 'create' }
    Write-Host "== $verb $p -> $($w.Name)"
    az deployment group $verb --subscription $w.SubscriptionId -g $w.ResourceGroup -n "ai-agents-$p" --template-file $tpl `
        --parameters workspaceName=$($w.Name) enableAnalyticRules=$($EnableAnalyticRules.ToString().ToLower()) `
        --query "{state:properties.provisioningState, resources:length(properties.outputResources || properties.validatedResources || ``[]``)}" -o json
    if ($LASTEXITCODE) { throw "Deployment of $p failed" }
}
if ($ValidateOnly) { return }

$si = "$SentinelWorkspaceResourceId/providers/Microsoft.SecurityInsights"
$rules = (Invoke-Arm "$si/alertRules?api-version=2024-09-01").value
foreach ($r in ($rules | Where-Object { $_.properties.displayName -in $DisableRules -and $_.properties.enabled })) {
    $r.properties.enabled = $false
    $r.properties.PSObject.Properties.Remove('lastModifiedUtc')
    $res = Invoke-Arm "$si/alertRules/$($r.name)?api-version=2024-09-01" -Method PUT -Body @{ kind = $r.kind; etag = $r.etag; properties = $r.properties }
    Write-Host ("   disabled: {0} (enabled={1})" -f $res.properties.displayName, $res.properties.enabled)
}

$rules = (Invoke-Arm "$si/alertRules?api-version=2024-09-01").value | Where-Object { $_.properties.displayName -match '^(Foundry|Copilot Studio) - ' }
$ss = (Invoke-Arm "$SentinelWorkspaceResourceId/savedSearches?api-version=2020-08-01").value | Where-Object { $_.properties.category -eq 'Hunting Queries' }
$wl = (Invoke-Arm "$si/watchlists?api-version=2024-09-01").value
Write-Host ("`nAnalytic rules: {0} ({1} enabled) | Hunting queries in workspace: {2} | Watchlists: {3}" -f `
    $rules.Count, @($rules | Where-Object { $_.properties.enabled }).Count, $ss.Count, (($wl.properties.watchlistAlias) -join ', '))
Write-Host 'Disabled AI rules:'; $rules | Where-Object { -not $_.properties.enabled } | ForEach-Object { "  - $($_.properties.displayName)" }
