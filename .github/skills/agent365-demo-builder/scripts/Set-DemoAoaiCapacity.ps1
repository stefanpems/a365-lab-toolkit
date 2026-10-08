#requires -Version 7.0
<#
.SYNOPSIS
  Sizes the lab's shared Azure OpenAI deployment for the demo traffic (pack.json solutionSizing.azureOpenAICapacity),
  after the Lab Builder created it with its default capacity, and reports the requests by status code.
.DESCRIPTION
  Reference lab, 29/09: the Lab Builder default capacity (20 = 20K tokens and 20 requests per minute) saturated with
  about four turns per minute across the ACA agents that share the deployment (HTTP 429 in the chats); 600 fixed it.
  The target is checked against the regional quota of the SKU before the change. Model, version and SKU of the
  deployment are kept. -Check429 reports AzureOpenAIRequests by StatusCode for the last -Hours (run it after the
  first traffic round: expect no 429). The Lab Builder itself is not changed (its plan is only read).
.EXAMPLE
  pwsh -File .\Set-DemoAoaiCapacity.ps1 -Prefix cts2 -WhatIf
.EXAMPLE
  pwsh -File .\Set-DemoAoaiCapacity.ps1 -Prefix cts2 -Check429 -Hours 24
#>
[CmdletBinding(PositionalBinding = $false)]
param([Parameter(Mandatory)][string]$Prefix, [int]$Capacity, [switch]$Check429, [int]$Hours = 24, [switch]$WhatIf)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_demo-common.ps1')
$cfg = Read-DemoConfig $Prefix
$pack = Get-DemoPack $cfg.pack
$planPath = Join-Path $script:DemoRepoRoot "generated\$Prefix\a365-deployment-plan.json"
if (-not (Test-Path -LiteralPath $planPath)) {
    if ($WhatIf) { Write-DemoLog $Prefix 'Azure OpenAI capacity: not yet applicable (no Lab Builder plan yet)'; return }
    throw "Lab Builder plan not found: $planPath (run New-DemoLabPlan.ps1 first)."
}
$plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
$o = $plan.solution.azureOpenAI
if (-not $o -or $o.mode -notin 'create-shared', 'reuse-existing') { Write-DemoLog $Prefix 'No shared Azure OpenAI deployment in the plan (per-agent mode or no ACA agent): nothing to size'; return }
$lbPrefix = [string]$plan.solution.prefix
$account = if ($o.account) { [string]$o.account } else { (($lbPrefix -replace '[^a-z0-9]', '').ToLower()) + 'aoai' }
$rg = if ($o.mode -eq 'create-shared') { if ($o.resourceGroup) { [string]$o.resourceGroup } else { "$lbPrefix-aoai-rg" } } else { [string]$o.existingResourceGroup }
$deployment = if ($o.deployment) { [string]$o.deployment } else { $null }
if (-not $deployment) {
    # A plan written before the agents step (or by an older New-DemoLabPlan.ps1): nothing to size yet.
    if ($WhatIf) { Write-DemoLog $Prefix 'Azure OpenAI capacity: not yet applicable (the plan has no shared deployment yet; runs after the agents step)'; return }
    throw 'The plan has no solution.azureOpenAI.deployment (re-run New-DemoLabPlan.ps1).'
}
$target = if ($Capacity) { $Capacity } elseif ($pack.solutionSizing -and $pack.solutionSizing.azureOpenAICapacity) { [int]$pack.solutionSizing.azureOpenAICapacity } else { 0 }
Assert-DemoTenant $cfg
$SubArg = @('--subscription', [string]$cfg.subscriptionId)
$d = az cognitiveservices account deployment show -n $account -g $rg --deployment-name $deployment @SubArg -o json 2>$null | ConvertFrom-Json
if (-not $d) {
    if ($WhatIf) { Write-DemoLog $Prefix "Azure OpenAI capacity: not yet applicable ('$deployment' of '$account' does not exist yet; runs after the ACA agents are deployed)"; return }
    throw "Deployment '$deployment' of '$account' ($rg) not found: deploy the ACA agents first (Lab Builder)."
}
$acc = az cognitiveservices account show -n $account -g $rg @SubArg -o json | ConvertFrom-Json
$cur = [int]$d.sku.capacity
Write-DemoLog $Prefix "Azure OpenAI '$account/$deployment' ($($d.properties.model.name) $($d.properties.model.version), $($d.sku.name), $($acc.location)): capacity $cur, target $(if ($target) { $target } else { '(none in the pack)' })"

if ($Check429) {
    $start = (Get-Date).ToUniversalTime().AddHours(-$Hours).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $end = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    # --end-time is required: with --start-time alone az returns a one-hour window.
    $m = az monitor metrics list --resource $acc.id --metric AzureOpenAIRequests --aggregation Total --interval PT1H --start-time $start --end-time $end --filter "StatusCode eq '*'" @SubArg -o json 2>$null | ConvertFrom-Json
    $rows = foreach ($ts in @($m.value[0].timeseries)) {
        $code = [string](@($ts.metadatavalues | Where-Object { $_.name.value -eq 'statuscode' })[0].value)
        [pscustomobject]@{ status = $code; requests = [int](@($ts.data | ForEach-Object { $_.total } | Where-Object { $_ }) | Measure-Object -Sum).Sum }
    }
    $rows = @($rows | Sort-Object status)
    Write-Host "Requests in the last $Hours h by status code: $(if ($rows.Count) { ($rows | ForEach-Object { "$($_.status)=$($_.requests)" }) -join ', ' } else { 'none' })"
    $n429 = [int](@($rows | Where-Object { $_.status -eq '429' } | ForEach-Object { $_.requests }) | Measure-Object -Sum).Sum
    if ($n429) { Write-DemoLog $Prefix "Azure OpenAI: $n429 throttled request(s) (429) in $Hours h: raise the capacity (this script without -Check429)" 'WARN' }
}

if (-not $target -or $target -eq $cur) { return }
$model = [string]$d.properties.model.name
# Quota names drop the dash after 'gpt' for the standard SKUs (e.g. OpenAI.GlobalStandard.gpt4.1-mini).
$usageNames = @("OpenAI.$($d.sku.name).$model", "OpenAI.$($d.sku.name).$($model -replace '^gpt-', 'gpt')")
$u = @(az cognitiveservices usage list -l $acc.location @SubArg -o json | ConvertFrom-Json) | Where-Object { $usageNames -contains $_.name.value } | Select-Object -First 1
$usageName = if ($u) { $u.name.value } else { $usageNames[-1] }
if ($u) {
    $free = [int]$u.limit - [int]$u.currentValue + $cur
    Write-Host "Regional quota $usageName in $($acc.location): limit $($u.limit), used $($u.currentValue) (this deployment $cur) -> at most $free for it"
    if ($target -gt $free) { throw "Target capacity $target exceeds the available quota ($free): request more quota or pass -Capacity <n>." }
}
else { Write-DemoLog $Prefix "Quota entry $usageName not found: the change is attempted without the pre-check" 'WARN' }
if ($WhatIf) { Write-Host "WhatIf: would set the capacity of '$deployment' from $cur to $target."; return }
az cognitiveservices account deployment create -n $account -g $rg --deployment-name $deployment --model-name $d.properties.model.name `
    --model-version $d.properties.model.version --model-format $d.properties.model.format --sku-name $d.sku.name --sku-capacity $target @SubArg -o none
if ($LASTEXITCODE -ne 0) { throw 'Capacity update failed.' }
$after = [int](az cognitiveservices account deployment show -n $account -g $rg --deployment-name $deployment @SubArg -o json | ConvertFrom-Json).sku.capacity
Write-DemoLog $Prefix "Azure OpenAI '$deployment' capacity: $cur -> $after$(if ($after -ne $target) { " (expected $target)" })" $(if ($after -eq $target) { 'INFO' } else { 'WARN' })
