#requires -Version 7.0
<#
.SYNOPSIS
  Stamp the durable COMPONENT tag on web UI / custom MCP instances created from THIS solution's code, so
  the Lab Builder can list existing web UIs to attach to and the Web UI & MCP Remover can list standalone
  instances to remove. Also supports a RETRO sweep that tags instances created by earlier runs.

.DESCRIPTION
  Two tags, in the existing Azure/Entra convention (Azure key=value, Entra key:value):
    * a365component=web-ui      -> the Static Web App (+ its RG + SPA app) of a web UI instance.
    * a365component=custom-mcp  -> the MCP RG (+ its Container Apps + ext_<Name>* apps) of a custom MCP.
  These mark an instance REGARDLESS of who created it (a lab run or the standalone creators). Ownership
  by a specific lab stays with the separate a365lab=<prefix> tag (Set-LabTags.ps1); a STANDALONE instance
  has a365component but NO a365lab, which is exactly how the Remover tells it apart from a lab-owned one.

  Modes (choose one):
    -SwaName <name>           Tag one Static Web App (+ RG + <name>-spa app if present) as web-ui.
    -McpName <name>           Tag one custom MCP (RG <slug>-mcp-rg + its CAs + ext_<name>* apps) as custom-mcp.
    -Retro                    Scan generated/*/a365-deployment-plan.json, resolve each lab's UI (ui.mode
                              create) and custom MCP (customMcp.enabled), and tag every one that still
                              exists. It stamps a365component AND a365lab=<prefix> on these lab-owned
                              instances (so the standalone discriminator is correct even for default names).
                              Idempotent; verifies existence; never creates or deletes anything.

  Entra tags are written with a Graph token + Invoke-RestMethod (NOT az rest --body @file). Azure resource
  tags are merged with `az tag update --operation Merge`.

.PARAMETER Subscription   Target subscription id (pins the az context).
.PARAMETER TenantId       Expected tenant id (aborts on mismatch — az ad / Graph ignore --subscription).
.PARAMETER WhatIf         Show what would be tagged without writing anything.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Subscription,
    [string]$TenantId,
    [string]$SwaName,
    [string]$McpName,
    [switch]$Retro
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
if (-not ($SwaName -or $McpName -or $Retro)) { throw "Choose a mode: -SwaName, -McpName, or -Retro." }

az account set --subscription $Subscription | Out-Null
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' first." }
if ($TenantId -and $ctx.tenantId -ne $TenantId) { throw "az context tenant '$($ctx.tenantId)' != -TenantId '$TenantId'. Re-pin and retry." }
$sub = $ctx.id

$graphToken = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
$graphHeaders = @{ Authorization = "Bearer $graphToken"; 'Content-Type' = 'application/json'; ConsistencyLevel = 'eventual' }
$summary = New-Object System.Collections.Generic.List[string]

function Set-AzResourceComponentTag {
    param([string]$ResourceId, [string]$Value, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return }
    if ($PSCmdlet.ShouldProcess($Label, "tag a365component=$Value")) {
        az tag update --resource-id $ResourceId --operation Merge --tags "a365component=$Value" --subscription $sub -o none 2>$null
        if ($LASTEXITCODE -eq 0) { $summary.Add("res  TAGGED $Label (a365component=$Value)") } else { $summary.Add("res  ERROR  $Label") }
    }
}
function Set-RgComponentTag {
    param([string]$Rg, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($Rg)) { return }
    if ((az group exists -n $Rg --subscription $sub 2>$null) -ne 'true') { $summary.Add("rg   skip   $Rg (not found)"); return }
    if ($PSCmdlet.ShouldProcess($Rg, "tag a365component=$Value")) {
        az group update -n $Rg --subscription $sub --set "tags.a365component=$Value" -o none 2>$null
        if ($LASTEXITCODE -eq 0) { $summary.Add("rg   TAGGED $Rg (a365component=$Value)") } else { $summary.Add("rg   ERROR  $Rg") }
    }
}
function Add-EntraComponentTag {
    param([string]$Entity, [string]$ObjectId, [object]$CurrentTags, [string]$Value, [string]$Label)
    $tag = "a365component:$Value"
    $tags = @($CurrentTags | Where-Object { $_ })
    if ($tags -contains $tag) { $summary.Add("$Label ok (already)"); return }
    if ($PSCmdlet.ShouldProcess($Label, "tag $tag")) {
        try {
            $body = '{"tags":' + (@(@($tags) + $tag) | ConvertTo-Json -AsArray) + '}'
            Invoke-RestMethod -Method Patch -Uri "https://graph.microsoft.com/v1.0/$Entity/$ObjectId" -Headers $graphHeaders -Body $body | Out-Null
            $summary.Add("$Label TAGGED")
        } catch { $summary.Add("$Label ERROR ($($_.Exception.Message))") }
    }
}
function Set-EntraAppComponentTagByName {
    param([string]$DisplayName, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($DisplayName)) { return }
    $flt = [uri]::EscapeDataString("displayName eq '$($DisplayName.Replace("'", "''"))'")
    $apps = $null
    try { $apps = (Invoke-RestMethod -Method Get -Uri ("https://graph.microsoft.com/v1.0/applications?`$filter=$flt") -Headers $graphHeaders).value } catch { $apps = $null }
    foreach ($a in @($apps)) { Add-EntraComponentTag -Entity 'applications' -ObjectId $a.id -CurrentTags $a.tags -Value $Value -Label "app '$DisplayName'" }
}
function Set-EntraAppComponentTagByPrefix {
    param([string]$NamePrefix, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($NamePrefix)) { return }
    $flt = [uri]::EscapeDataString("startswith(displayName,'$($NamePrefix.Replace("'", "''"))')")
    $apps = $null
    try { $apps = (Invoke-RestMethod -Method Get -Uri ("https://graph.microsoft.com/v1.0/applications?`$filter=$flt") -Headers $graphHeaders).value } catch { $apps = $null }
    foreach ($a in @($apps)) { Add-EntraComponentTag -Entity 'applications' -ObjectId $a.id -CurrentTags $a.tags -Value $Value -Label "app '$($a.displayName)'" }
}

# Lab-ownership tag (a365lab=<prefix> Azure / a365lab:<prefix> Entra). Applied alongside the component tag
# for LAB-OWNED instances so the standalone discriminator is correct even with default names.
function Set-AzResourceLabTag {
    param([string]$ResourceId, [string]$Prefix, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return }
    if ($PSCmdlet.ShouldProcess($Label, "tag a365lab=$Prefix")) {
        az tag update --resource-id $ResourceId --operation Merge --tags "a365lab=$Prefix" --subscription $sub -o none 2>$null
        if ($LASTEXITCODE -eq 0) { $summary.Add("res  TAGGED $Label (a365lab=$Prefix)") } else { $summary.Add("res  ERROR  $Label (a365lab)") }
    }
}
function Set-RgLabTag {
    param([string]$Rg, [string]$Prefix)
    if ([string]::IsNullOrWhiteSpace($Rg)) { return }
    if ((az group exists -n $Rg --subscription $sub 2>$null) -ne 'true') { return }
    if ($PSCmdlet.ShouldProcess($Rg, "tag a365lab=$Prefix")) {
        az group update -n $Rg --subscription $sub --set "tags.a365lab=$Prefix" -o none 2>$null
        if ($LASTEXITCODE -eq 0) { $summary.Add("rg   TAGGED $Rg (a365lab=$Prefix)") } else { $summary.Add("rg   ERROR  $Rg (a365lab)") }
    }
}
function Add-EntraLabTag {
    param([string]$Entity, [string]$ObjectId, [object]$CurrentTags, [string]$Prefix, [string]$Label)
    $tag = "a365lab:$Prefix"
    $tags = @($CurrentTags | Where-Object { $_ })
    if ($tags -contains $tag) { return }
    if ($PSCmdlet.ShouldProcess($Label, "tag $tag")) {
        try {
            $body = '{"tags":' + (@(@($tags) + $tag) | ConvertTo-Json -AsArray) + '}'
            Invoke-RestMethod -Method Patch -Uri "https://graph.microsoft.com/v1.0/$Entity/$ObjectId" -Headers $graphHeaders -Body $body | Out-Null
            $summary.Add("$Label TAGGED (a365lab)")
        } catch { $summary.Add("$Label ERROR (a365lab: $($_.Exception.Message))") }
    }
}
function Set-EntraAppLabTagByName {
    param([string]$DisplayName, [string]$Prefix)
    if ([string]::IsNullOrWhiteSpace($DisplayName)) { return }
    $flt = [uri]::EscapeDataString("displayName eq '$($DisplayName.Replace("'", "''"))'")
    $apps = $null
    try { $apps = (Invoke-RestMethod -Method Get -Uri ("https://graph.microsoft.com/v1.0/applications?`$filter=$flt") -Headers $graphHeaders).value } catch { $apps = $null }
    foreach ($a in @($apps)) { Add-EntraLabTag -Entity 'applications' -ObjectId $a.id -CurrentTags $a.tags -Prefix $Prefix -Label "app '$($a.displayName)'" }
}
function Set-EntraAppLabTagByPrefix {
    param([string]$NamePrefix, [string]$Prefix)
    if ([string]::IsNullOrWhiteSpace($NamePrefix)) { return }
    $flt = [uri]::EscapeDataString("startswith(displayName,'$($NamePrefix.Replace("'", "''"))')")
    $apps = $null
    try { $apps = (Invoke-RestMethod -Method Get -Uri ("https://graph.microsoft.com/v1.0/applications?`$filter=$flt") -Headers $graphHeaders).value } catch { $apps = $null }
    foreach ($a in @($apps)) { Add-EntraLabTag -Entity 'applications' -ObjectId $a.id -CurrentTags $a.tags -Prefix $Prefix -Label "app '$($a.displayName)'" }
}

# Tag one web UI: the SWA resource, its RG, and the <name>-spa app registration.
# When -LabPrefix is given (retro/lab-owned), ALSO stamp a365lab=<prefix> so the "standalone =
# a365component without a365lab" discriminator stays correct even for DEFAULT-named labs.
function Set-WebUiComponent {
    param([string]$Name, [string]$LabPrefix)
    $swa = @(az staticwebapp list --subscription $sub -o json 2>$null | ConvertFrom-Json | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
    if (-not $swa) { $summary.Add("swa  skip   $Name (not found)"); return }
    Set-AzResourceComponentTag -ResourceId $swa.id -Value 'web-ui' -Label "swa $Name"
    Set-RgComponentTag -Rg $swa.resourceGroup -Value 'web-ui'
    Set-EntraAppComponentTagByName -DisplayName "$Name-spa" -Value 'web-ui'
    if ($LabPrefix) {
        Set-AzResourceLabTag -ResourceId $swa.id -Prefix $LabPrefix -Label "swa $Name"
        Set-RgLabTag -Rg $swa.resourceGroup -Prefix $LabPrefix
        Set-EntraAppLabTagByName -DisplayName "$Name-spa" -Prefix $LabPrefix
    }
}

# Tag one custom MCP: its RG (default <slug>-mcp-rg), each Container App in it, and the ext_<Name>* apps.
# -LabPrefix (retro/lab-owned) ALSO stamps a365lab=<prefix> (same reason as the web UI above).
function Set-CustomMcpComponent {
    param([string]$Name, [string]$ResourceGroup, [string]$LabPrefix)
    $slug = ($Name -replace '[^A-Za-z0-9]', '').ToLower()
    $rg = if ($ResourceGroup) { $ResourceGroup } else { "$slug-mcp-rg" }
    if ((az group exists -n $rg --subscription $sub 2>$null) -ne 'true') { $summary.Add("mcp  skip   $rg (not found)"); return }
    Set-RgComponentTag -Rg $rg -Value 'custom-mcp'
    foreach ($ca in @(az containerapp list -g $rg --subscription $sub -o json 2>$null | ConvertFrom-Json)) {
        Set-AzResourceComponentTag -ResourceId $ca.id -Value 'custom-mcp' -Label "ca $($ca.name)"
        if ($LabPrefix) { Set-AzResourceLabTag -ResourceId $ca.id -Prefix $LabPrefix -Label "ca $($ca.name)" }
    }
    Set-EntraAppComponentTagByPrefix -NamePrefix "ext_$Name" -Value 'custom-mcp'
    if ($LabPrefix) {
        Set-RgLabTag -Rg $rg -Prefix $LabPrefix
        Set-EntraAppLabTagByPrefix -NamePrefix "ext_$Name" -Prefix $LabPrefix
    }
}

if ($SwaName) { Set-WebUiComponent -Name $SwaName }
if ($McpName) { Set-CustomMcpComponent -Name $McpName }

if ($Retro) {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
    $genRoot = Join-Path $repoRoot 'generated'
    Write-Host "Retro-scan of $genRoot for web UI / custom MCP instances to tag..." -ForegroundColor Cyan
    $plans = Get-ChildItem -Path $genRoot -Recurse -Filter 'a365-deployment-plan.json' -ErrorAction SilentlyContinue
    $seenSwa = @{}; $seenMcp = @{}
    foreach ($pf in $plans) {
        $plan = $null
        try { $plan = Get-Content -LiteralPath $pf.FullName -Raw | ConvertFrom-Json } catch { continue }
        if (-not $plan) { continue }
        $prefix = $plan.solution.prefix
        if ($plan.ui -and $plan.ui.mode -eq 'create') {
            $swaName = if ($plan.ui.name) { $plan.ui.name } else { "$prefix-ui" }
            if (-not $seenSwa.ContainsKey($swaName)) { $seenSwa[$swaName] = $true; Write-Host "  UI:  $swaName (from $($pf.Directory.Name))" -ForegroundColor DarkGray; Set-WebUiComponent -Name $swaName -LabPrefix $prefix }
        }
        if ($plan.customMcp -and $plan.customMcp.enabled) {
            $mcpName = $prefix   # custom MCP <Name> defaults to the solution prefix
            $mcpRg = if ($plan.customMcp.resourceGroup) { $plan.customMcp.resourceGroup } else { $null }
            if (-not $seenMcp.ContainsKey($mcpName)) { $seenMcp[$mcpName] = $true; Write-Host "  MCP: $mcpName (from $($pf.Directory.Name))" -ForegroundColor DarkGray; Set-CustomMcpComponent -Name $mcpName -ResourceGroup $mcpRg -LabPrefix $prefix }
        }
    }
    # Also sweep any SWA/MCP RG that already carries a365lab but not yet a365component (older labs).
    foreach ($swa in @(az staticwebapp list --subscription $sub -o json 2>$null | ConvertFrom-Json)) {
        if ($seenSwa.ContainsKey($swa.name)) { continue }
        $hasLab = az staticwebapp show -n $swa.name -g $swa.resourceGroup --subscription $sub --query "tags.a365lab" -o tsv 2>$null
        if ($hasLab) { $seenSwa[$swa.name] = $true; Write-Host "  UI (by a365lab tag): $($swa.name)" -ForegroundColor DarkGray; Set-WebUiComponent -Name $swa.name -LabPrefix $hasLab }
    }
}

Write-Host ""
Write-Host "Component-tagging summary:" -ForegroundColor Green
foreach ($l in $summary) { Write-Host "  $l" }
$tagged = @($summary | Where-Object { $_ -match 'TAGGED' }).Count
$errs   = @($summary | Where-Object { $_ -match 'ERROR' }).Count
Write-Host "`n  $tagged newly tagged, $errs error(s). Idempotent — safe to re-run." -ForegroundColor DarkGray
if ($errs -gt 0) { exit 1 }
