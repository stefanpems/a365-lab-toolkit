#requires -Version 5.1
<#
.SYNOPSIS
  READ-ONLY environment discovery for the Agent 365 provisioning wizard.
.DESCRIPTION
  Emits JSON with the current tenant/subscription, Azure OpenAI accounts, Foundry (Cognitive
  Services AIServices) accounts, Static Web Apps (for UI attach mode), and custom MCP instances tagged
  a365component=custom-mcp (for customMcp attach mode), so the wizard can pre-fill plan defaults.
  Performs NO mutations: only 'az ... show/list'. Requires an existing 'az login'.
.PARAMETER Subscription
  Optional subscription id to pin. Defaults to the current az context.
.EXAMPLE
  pwsh -File .\discover-environment.ps1 | ConvertFrom-Json
#>
[CmdletBinding()]
param(
    [string]$Subscription
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Get-AzJson {
    param([string[]]$AzArgs)
    $out = az @AzArgs 2>$null
    if (-not $out) { return $null }
    return ($out | ConvertFrom-Json)
}

# --- Pin subscription (read-only: we only set the CLI context, no resource change) ---
$acct = Get-AzJson @('account', 'show', '-o', 'json')
if (-not $acct) { throw "Not logged in. Run 'az login' first." }
if ($Subscription) {
    az account set --subscription $Subscription | Out-Null
    $acct = Get-AzJson @('account', 'show', '-o', 'json')
}
$sub = $acct.id
$subArg = @('--subscription', $sub)

$result = [ordered]@{
    tenantId        = $acct.tenantId
    subscriptionId  = $sub
    subscriptionName = $acct.name
    signedInUser    = $acct.user.name
    azureOpenAI     = @()
    foundryAccounts = @()
    staticWebApps   = @()
    customMcpInstances = @()
}

# --- Azure OpenAI accounts (kind = OpenAI) ---
$cog = Get-AzJson (@('cognitiveservices', 'account', 'list', '-o', 'json') + $subArg)
if ($cog) {
    $result.azureOpenAI = @($cog | Where-Object { $_.kind -eq 'OpenAI' } | ForEach-Object {
        [ordered]@{ name = $_.name; resourceGroup = $_.resourceGroup; location = $_.location; endpoint = $_.properties.endpoint }
    })
    # --- Foundry / AI Services accounts (kind = AIServices) — host FH + FD agents ---
    $result.foundryAccounts = @($cog | Where-Object { $_.kind -eq 'AIServices' } | ForEach-Object {
        [ordered]@{ name = $_.name; resourceGroup = $_.resourceGroup; location = $_.location; endpoint = $_.properties.endpoint }
    })
}

# --- Static Web Apps (for UI attach mode) ---
$swa = Get-AzJson (@('staticwebapp', 'list', '-o', 'json') + $subArg)
if ($swa) {
    $result.staticWebApps = @($swa | ForEach-Object {
        [ordered]@{ name = $_.name; resourceGroup = $_.resourceGroup; defaultHostname = $_.defaultHostname }
    })
}

# --- Custom MCP instances (for customMcp attach mode) — RGs tagged a365component=custom-mcp ---
# Primary source for "attach to an existing custom MCP pair": the Custom MCP Creator (standalone, no
# a365lab) and any lab-owned MCP RG (a365lab present). Each RG is <slug>-mcp-rg; the registered servers
# are ext_<slug>Anon / ext_<slug>Auth (slug = lowercased). The containers reveal which servers exist.
$mcpRgs = Get-AzJson (@('group', 'list', '--query', "[?tags.a365component=='custom-mcp']", '-o', 'json') + $subArg)
if ($mcpRgs) {
    $result.customMcpInstances = @($mcpRgs | ForEach-Object {
        $rg = $_
        $slug = $rg.name -replace '-mcp-rg$', ''
        $cas = @(Get-AzJson (@('containerapp', 'list', '-g', $rg.name, '--query', '[].{name:name, fqdn:properties.configuration.ingress.fqdn}', '-o', 'json') + $subArg))
        $servers = @()
        if ($cas | Where-Object { $_.name -like '*-anon-ca' }) { $servers += 'anon' }
        if ($cas | Where-Object { $_.name -like '*-auth-ca' }) { $servers += 'auth' }
        $labOwner = if ($rg.tags -and ($rg.tags.PSObject.Properties.Name -contains 'a365lab')) { $rg.tags.a365lab } else { $null }
        [ordered]@{
            name          = $slug
            resourceGroup = $rg.name
            location      = $rg.location
            standalone    = (-not $labOwner)          # standalone (Custom MCP Creator) if no a365lab tag
            labOwner      = $labOwner                  # else the owning lab prefix
            source        = if ($labOwner) { 'azure' } else { 'custom-mcp-creator' }
            servers       = $servers
            anonServer    = "ext_${slug}Anon"
            authServer    = "ext_${slug}Auth"
            containers    = @($cas | ForEach-Object { $_.name })
        }
    })
}

$result | ConvertTo-Json -Depth 6
