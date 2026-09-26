#requires -Version 5.1
<#
.SYNOPSIS
  Provision (idempotent) an Azure AI Search service to hold a SHARED INDEXED COPY of documents,
  and record its endpoint + keys in kb.state.json. STANDALONE — not part of Lab Builder.

.DESCRIPTION
  Step 1 of the standalone knowledge-base toolkit. Creates (or reuses) a resource group and an
  Azure AI Search service, then reads its admin key (for ingestion) and a read-only query key
  (for the MCP shim). Nothing is deleted; a resource group is never removed.

  The service uses key-based data-plane auth (the default). The ingest step uses the ADMIN key
  to create the index and upload documents; the deployed MCP shim uses the read-only QUERY key.

  Resources are tagged a365component=knowledge-base (NEVER a365lab) so the Lab Cleaner — which
  only deletes a365lab-tagged runs — never touches this instance.

.PARAMETER Subscription
  Target subscription id. Pinned on every az command.
.PARAMETER ResourceGroup
  Resource group for the search service (created if absent).
.PARAMETER Location
  Azure region (e.g. swedencentral). Must offer Azure AI Search.
.PARAMETER SearchService
  Globally-unique Azure AI Search service name (lowercase letters, digits, hyphens).
.PARAMETER Sku
  Search SKU. 'basic' is enough for a lab; 'free' allows only one per subscription.
.PARAMETER IndexName
  Name of the index that ingest_docs.py will create/fill (default: docs4agents-idx).

.EXAMPLE
  ./provision-search.ps1 -Subscription <sub> -ResourceGroup kb-docs4agents-rg `
      -Location swedencentral -SearchService kbdocs4agents<rand>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$Subscription,
    [Parameter(Mandatory = $true)] [string]$ResourceGroup,
    [Parameter(Mandatory = $true)] [string]$Location,
    [Parameter(Mandatory = $true)] [string]$SearchService,
    [ValidateSet('free', 'basic', 'standard')] [string]$Sku = 'basic',
    [string]$IndexName = 'docs4agents-idx'
)
$ErrorActionPreference = 'Stop'
$SubArg = @('--subscription', $Subscription)
$stateFile = Join-Path $PSScriptRoot 'kb.state.json'

Write-Host "Provisioning Azure AI Search '$SearchService' in RG '$ResourceGroup' ($Location)..." -ForegroundColor Cyan
az account set @SubArg | Out-Null
az provider register --namespace Microsoft.Search --wait @SubArg | Out-Null

# Resource group (create if absent; never deleted).
if (-not (az group show -n $ResourceGroup @SubArg 2>$null)) {
    az group create -n $ResourceGroup -l $Location @SubArg | Out-Null
    Write-Host "  Created resource group '$ResourceGroup'." -ForegroundColor Green
} else {
    Write-Host "  Reusing existing resource group '$ResourceGroup'." -ForegroundColor DarkGray
}
# Durable component marker (never a365lab, so the Lab Cleaner leaves it alone).
az group update -n $ResourceGroup --set "tags.a365component=knowledge-base" @SubArg -o none 2>$null

# Search service (create if absent; reused otherwise).
if (-not (az search service show -n $SearchService -g $ResourceGroup @SubArg 2>$null)) {
    Write-Host "  Creating search service (this can take a few minutes)..." -ForegroundColor Cyan
    az search service create -n $SearchService -g $ResourceGroup -l $Location `
        --sku $Sku --partition-count 1 --replica-count 1 @SubArg | Out-Null
    Write-Host "  Created search service '$SearchService'." -ForegroundColor Green
} else {
    Write-Host "  Reusing existing search service '$SearchService'." -ForegroundColor DarkGray
}

# Keys: admin (ingest) + read-only query (MCP shim).
$adminKey = az search admin-key show --service-name $SearchService -g $ResourceGroup @SubArg --query primaryKey -o tsv
$queryKey = az search query-key list --service-name $SearchService -g $ResourceGroup @SubArg --query "[0].key" -o tsv
if (-not $queryKey) {
    az search query-key create --service-name $SearchService -g $ResourceGroup --name kb-mcp-readonly @SubArg | Out-Null
    $queryKey = az search query-key list --service-name $SearchService -g $ResourceGroup @SubArg --query "[0].key" -o tsv
}
$endpoint = "https://$SearchService.search.windows.net"

# Merge into the state file (created if absent), preserving any later fields.
$state = if (Test-Path $stateFile) { Get-Content $stateFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
function Set-StateProp($obj, $name, $value) {
    if ($obj.PSObject.Properties[$name]) { $obj.$name = $value } else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}
Set-StateProp $state 'subscription'  $Subscription
Set-StateProp $state 'resourceGroup' $ResourceGroup
Set-StateProp $state 'location'      $Location
Set-StateProp $state 'searchService' $SearchService
Set-StateProp $state 'searchEndpoint' $endpoint
Set-StateProp $state 'indexName'     $IndexName
Set-StateProp $state 'adminKey'      $adminKey
Set-StateProp $state 'queryKey'      $queryKey
$state | ConvertTo-Json -Depth 8 | Set-Content $stateFile -Encoding utf8

Write-Host ""
Write-Host "Search service ready." -ForegroundColor Green
Write-Host "  Endpoint : $endpoint"
Write-Host "  Index    : $IndexName (created by the ingest step)"
Write-Host "  State    : $stateFile (gitignored — contains keys)"
Write-Host ""
Write-Host "Next: python ingest\ingest_docs.py --state `"$stateFile`" --folder-url <sharepoint-folder-url>" -ForegroundColor Cyan
