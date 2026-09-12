#requires -Version 7.0
<#
.SYNOPSIS
  READ-ONLY listing of STANDALONE web UI / custom MCP instances of this solution — those tagged
  a365component but NOT owned by a lab (no a365lab tag) — so the Web UI & MCP Remover can present a pick
  list. Performs no mutations (only az list/show).

.DESCRIPTION
  A standalone instance is created by the Web UI Creator / Custom MCP Creator (or by an earlier lab whose
  a365lab tag was intentionally removed). It has a365component=web-ui|custom-mcp but no a365lab, so the Lab
  Cleaner never deletes it. This lister finds those instances by tag:
    * web-ui     -> Static Web Apps tagged a365component=web-ui without a365lab, plus their a365ref_<lab>
                    tags (which labs still have agents integrated — a removal warning).
    * custom-mcp -> resource groups tagged a365component=custom-mcp without a365lab, and their Container Apps.

  Output: a JSON array (also written to -OutFile). Each item carries name/id/kind and, for a web UI, the
  list of a365ref_<lab> labs still attached.

.PARAMETER Subscription  Target subscription id (pins the az context).
.PARAMETER TenantId      Expected tenant id (aborts on mismatch).
.PARAMETER Kind          Optional filter: web-ui | custom-mcp (default both).
.PARAMETER OutFile       Optional path to write the JSON array to.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Subscription,
    [string]$TenantId,
    [ValidateSet('web-ui', 'custom-mcp')][string]$Kind,
    [string]$OutFile
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

az account set --subscription $Subscription | Out-Null
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' first." }
if ($TenantId -and $ctx.tenantId -ne $TenantId) { throw "az context tenant '$($ctx.tenantId)' != -TenantId '$TenantId'. Re-pin and retry." }
$sub = $ctx.id
$items = New-Object System.Collections.Generic.List[object]

if (-not $Kind -or $Kind -eq 'web-ui') {
    Write-Host "Scanning standalone web UI instances (a365component=web-ui, no a365lab)..." -ForegroundColor Cyan
    foreach ($s in @(az staticwebapp list --subscription $sub -o json 2>$null | ConvertFrom-Json)) {
        $tags = $s.tags
        $comp = if ($tags -and ($tags.PSObject.Properties.Name -contains 'a365component')) { $tags.a365component } else { $null }
        if ($comp -ne 'web-ui') { continue }
        $lab = if ($tags -and ($tags.PSObject.Properties.Name -contains 'a365lab')) { $tags.a365lab } else { $null }
        if ($lab) { continue }   # lab-owned -> not standalone; the Lab Cleaner handles it.
        $refs = @()
        if ($tags) { foreach ($p in $tags.PSObject.Properties) { if ($p.Name -like 'a365ref_*') { $refs += ($p.Name -replace '^a365ref_', '') } } }
        $items.Add([pscustomobject]@{
                kind          = 'web-ui'
                name          = $s.name
                id            = $s.id
                resourceGroup = $s.resourceGroup
                host          = $s.defaultHostname
                labsAttached  = $refs
                detail        = "Static Web App in RG $($s.resourceGroup) — host $($s.defaultHostname)$(if($refs.Count){ ' — labs still attached: '+($refs -join ', ') })"
            })
    }
}

if (-not $Kind -or $Kind -eq 'custom-mcp') {
    Write-Host "Scanning standalone custom MCP instances (a365component=custom-mcp, no a365lab)..." -ForegroundColor Cyan
    $rgs = az group list --subscription $sub --query "[?tags.a365component=='custom-mcp' && tags.a365lab==null]" -o json 2>$null | ConvertFrom-Json
    foreach ($rg in @($rgs)) {
        $cas = @(az containerapp list -g $rg.name --subscription $sub --query "[].name" -o json 2>$null | ConvertFrom-Json)
        $items.Add([pscustomobject]@{
                kind          = 'custom-mcp'
                name          = $rg.name
                id            = $rg.id
                resourceGroup = $rg.name
                location      = $rg.location
                containers    = $cas
                detail        = "MCP resource group $($rg.name) ($($rg.location)) — containers: $(@($cas) -join ', ')"
            })
    }
}

$json = $items.ToArray() | ConvertTo-Json -Depth 8
if ($OutFile) {
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Set-Content -LiteralPath $OutFile -Value $json -Encoding utf8
    Write-Host "Wrote $($items.Count) standalone instance(s) to $OutFile" -ForegroundColor DarkGray
}
Write-Host $json
