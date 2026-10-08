#requires -Version 7.0
<#
.SYNOPSIS
  Bootstrap step 'foundry': creates the lab's Foundry account + project + model deployment when the pack's Foundry
  agents are prompt agents only (FD) and the config says create-shared, then switches demo-config to reuse-existing.
.DESCRIPTION
  An FD-only plan cannot provision a shared Foundry account (no azd project), so the Lab Builder needs
  solution.foundry.mode = reuse-existing. This step runs the Lab Builder's own New-FoundryProject.ps1 (idempotent,
  tags a365lab=<prefix>) in the lab region and writes endpoint/account/resource group/deployment to the config.
  Nothing to do when the config already points to a project, when the pack has FH agents (the Lab Builder creates the
  shared account) or when the pack has no Foundry agent. -WhatIf = dry run.
.EXAMPLE
  pwsh -File .\Set-DemoFoundry.ps1 -Prefix cts2 -WhatIf
#>
[CmdletBinding(PositionalBinding = $false)]
param([Parameter(Mandatory)][string]$Prefix, [string]$Region, [switch]$WhatIf)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_demo-common.ps1')
$cfg = Read-DemoConfig $Prefix
$pack = Get-DemoPack $cfg.pack
$hasFd = @($pack.agents | Where-Object { $_.variant -like 'FD-*' }).Count -gt 0
$hasFh = @($pack.agents | Where-Object { $_.variant -like 'FH-*' }).Count -gt 0
$mode = if ($cfg.foundry) { [string]$cfg.foundry.mode } else { '' }
if (-not $hasFd) { Write-DemoLog $Prefix 'Foundry: no prompt (FD) agent in the pack: nothing to create'; return }
if ($hasFh) { Write-DemoLog $Prefix 'Foundry: the pack has hosted (FH) agents: the Lab Builder creates the shared account'; return }
if ($mode -eq 'reuse-existing' -and $cfg.foundry.endpoint) { Write-DemoLog $Prefix "Foundry: already configured ($($cfg.foundry.account), $($cfg.foundry.endpoint))"; return }
if (-not $Region) { $Region = [string]$cfg.region }
$deployment = if ($cfg.foundry -and $cfg.foundry.deployment) { [string]$cfg.foundry.deployment } else { 'gpt-4.1' }
if ($WhatIf) {
    Write-Host "  would create the Foundry account $Prefix-foundry + project 'demo' + deployment $deployment in $Prefix-foundry-rg ($Region), then set demo-config foundry.mode = reuse-existing"
    return
}
Assert-DemoTenant $cfg
$nfp = Join-Path $script:WizardScriptsDir 'New-FoundryProject.ps1'
$out = pwsh -NoProfile -File $nfp -Prefix $Prefix -Subscription ([string]$cfg.subscriptionId) -Region $Region -Model $deployment -AsJson 2>&1
if ($LASTEXITCODE -ne 0) { throw "New-FoundryProject.ps1 failed: $(($out | Out-String).Trim())" }
$json = @($out | Where-Object { "$_" -match '^\s*\{.*\}\s*$' }) | Select-Object -Last 1
if (-not $json) { throw "New-FoundryProject.ps1 returned no JSON: $(($out | Out-String).Trim())" }
$r = $json | ConvertFrom-Json
& (Join-Path $PSScriptRoot 'New-DemoConfig.ps1') -Prefix $Prefix -FoundryMode reuse-existing -FoundryEndpoint $r.endpoint -FoundryAccount $r.account -FoundryResourceGroup $r.existingResourceGroup -FoundryDeployment $r.deployment | Out-Null
Write-DemoLog $Prefix "Foundry: $($r.account) ready ($($r.endpoint), deployment $($r.deployment) $($r.sku)); demo-config set to reuse-existing"
