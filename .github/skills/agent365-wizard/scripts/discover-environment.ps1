#requires -Version 5.1
<#
.SYNOPSIS
  READ-ONLY environment discovery for the Agent 365 provisioning wizard.
.DESCRIPTION
  Emits JSON with the current tenant/subscription, Azure OpenAI accounts, Foundry (Cognitive
  Services AIServices) accounts, and Static Web Apps, so the wizard can pre-fill plan defaults.
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

$result | ConvertTo-Json -Depth 6
