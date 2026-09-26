#requires -Version 5.1
<#
.SYNOPSIS
  End-to-end orchestrator for the standalone knowledge-base toolkit: provision search, ingest the
  SharePoint documents, and deploy the MCP shim. STANDALONE — not part of Lab Builder.

.DESCRIPTION
  Convenience wrapper that runs the first three steps in order. Registration in Agent 365 and the
  admin approval are intentionally left as manual steps (they prompt / require the M365 admin
  center); attach-to-lab.ps1 is run separately once the server is approved.

.EXAMPLE
  ./run-all.ps1 -Subscription <sub> -ResourceGroup kb-docs4agents-rg -Location swedencentral `
      -SearchService kbdocs4agents123 -FolderUrl "https://<tenant>.sharepoint.com/sites/docs4agents/Shared%20Documents/Forms/AllItems.aspx"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$Subscription,
    [Parameter(Mandatory = $true)] [string]$ResourceGroup,
    [Parameter(Mandatory = $true)] [string]$Location,
    [Parameter(Mandatory = $true)] [string]$SearchService,
    [Parameter(Mandatory = $true)] [string]$FolderUrl,
    [string]$IndexName = 'docs4agents-idx',
    [string]$Extensions = 'docx',
    [string]$ServerName = 'ext_Docs4AgentsKb',
    [string]$Publisher = 'Agent 365 Lab',
    [string]$PythonExe = 'python'
)
$ErrorActionPreference = 'Stop'
$stateFile = Join-Path $PSScriptRoot 'kb.state.json'

Write-Host "=== Step 1/3: provision Azure AI Search ===" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'provision-search.ps1') -Subscription $Subscription -ResourceGroup $ResourceGroup `
    -Location $Location -SearchService $SearchService -IndexName $IndexName

Write-Host "`n=== Step 2/3: ingest SharePoint documents ===" -ForegroundColor Cyan
& $PythonExe (Join-Path $PSScriptRoot 'ingest\ingest_docs.py') --state $stateFile --folder-url $FolderUrl --extensions $Extensions
if ($LASTEXITCODE -ne 0) { throw "Ingestion failed (exit $LASTEXITCODE)." }

Write-Host "`n=== Step 3/3: deploy the knowledge-base MCP shim ===" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'deploy-kb-mcp.ps1') -ServerName $ServerName -Publisher $Publisher

Write-Host "`n=== Manual steps remaining ===" -ForegroundColor Yellow
Write-Host "  a) a365 develop-mcp register-external-mcp-server -f `"$(Join-Path $PSScriptRoot 'register-kb.json')`""
Write-Host "  b) Approve the tool in the M365 admin center (Agents > Tools)."
Write-Host "  c) ./attach-to-lab.ps1 -LabPrefix <lab>"
