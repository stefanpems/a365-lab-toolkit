#requires -Version 7.0
<#
.SYNOPSIS
  Offline unit test of the user-actions register (_demo-common.ps1: Set-DemoUserAction, Read-DemoUserActions,
  Write-DemoUserActionsFile, Get-DemoIdsFor; Set-DemoUserAction.ps1 wrapper). No tenant call. Uses a throwaway lab
  folder generated/zzuatest/ that it deletes at the end. Exit code 0 = all assertions passed.
.EXAMPLE
  pwsh -File .\test-demo-user-actions.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_demo-common.ps1')
$prefix = 'zzuatest'
$root = Join-Path $script:DemoRepoRoot "generated\$prefix"
if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
$script:fail = 0; $script:pass = 0
function Assert([bool]$Cond, [string]$Name) { if ($Cond) { $script:pass++; Write-Host "  ok   $Name" } else { $script:fail++; Write-Host "  FAIL $Name" -ForegroundColor Red } }
function Get-Md { Get-Content -LiteralPath (Join-Path (Get-DemoLabDir $prefix) 'USER-ACTIONS.md') -Raw -Encoding utf8 }
function Get-Row([string]$Key) { (Read-DemoUserActions $prefix).actions | Where-Object { $_.key -eq $Key } | Select-Object -First 1 }

try {
    Write-Host 'Register helpers'
    $r1 = Set-DemoUserAction -Prefix $prefix -Key 'k1' -Action 'First action' -Where 'portal A' -NeededBy 'D1'
    Assert ($r1.id -eq 'A1' -and $r1.status -eq 'TODO' -and -not $r1.blocking) 'new row gets A1, TODO, not blocking'
    Assert (Test-Path -LiteralPath (Join-Path (Get-DemoLabDir $prefix) 'USER-ACTIONS.md')) 'USER-ACTIONS.md rendered'
    Assert ((Get-Md) -match '\| A1 \| TODO \| First action \| portal A \| D1 \|') 'row rendered in the table'
    Assert ((Get-Md) -match '(?m)^# zzuatest - actions for the user') 'header rendered without a demo config'

    $r2 = Set-DemoUserAction -Prefix $prefix -Key 'k2' -Action 'Second' -Blocking $true
    Assert ($r2.id -eq 'A2') 'second key gets A2'
    Assert ((Get-Md) -match '\| A2 \| \*\*BLOCKING\*\* \| Second \|') 'blocking TODO renders BLOCKING'

    $null = Set-DemoUserAction -Prefix $prefix -Key 'k1' -Action 'First action (updated)'
    $k1 = Get-Row 'k1'
    Assert ($k1.id -eq 'A1' -and $k1.action -eq 'First action (updated)' -and $k1.where -eq 'portal A' -and $k1.neededBy -eq 'D1') 'update keeps id and the fields not given'

    $null = Set-DemoUserAction -Prefix $prefix -Key 'k2' -Status DONE
    $k2 = Get-Row 'k2'
    Assert ($k2.status -eq 'DONE' -and $k2.doneAt) 'Status DONE sets doneAt'
    Assert ((Get-Md) -match '\| A2 \| DONE \| Second \|') 'a DONE blocking row renders DONE'
    $null = Set-DemoUserAction -Prefix $prefix -Key 'k2' -Action 'Second (re-registered)'
    Assert ((Get-Row 'k2').status -eq 'DONE') 're-registering without -Status never reopens a DONE row'
    $null = Set-DemoUserAction -Prefix $prefix -Key 'k2' -Status TODO
    Assert ((Get-Row 'k2').status -eq 'TODO' -and -not (Get-Row 'k2').Contains('doneAt')) 'explicit -Status TODO reopens and clears doneAt'
    $null = Set-DemoUserAction -Prefix $prefix -Key 'k2' -Blocking $false
    Assert (-not (Get-Row 'k2').blocking) '-Blocking $false clears the flag'

    $null = Set-DemoUserAction -Prefix $prefix -Key 'k3' -Action "pipe | and`r`nnewline" -Where 'a|b'
    Assert ((Get-Md) -match '\| A3 \| TODO \| pipe \\\| and newline \| a\\\|b \|') 'pipes escaped and newlines flattened'

    $threw = $false; try { $null = Set-DemoUserAction -Prefix $prefix -Key 'nope' } catch { $threw = $true }
    Assert $threw 'a new key without -Action throws'
    Assert (@((Read-DemoUserActions $prefix).actions).Count -eq 3) 'the failed call added no row'

    $null = Set-DemoUserAction -Prefix $prefix -Key 'k1' -WebUiUrl 'https://ui.example'
    Assert ((Get-Md) -match 'Web UI: https://ui\.example') 'web UI URL kept in meta and rendered'

    # ids are never renumbered: the next id follows the highest one, also with gaps
    $f = Get-DemoUserActionsPath $prefix
    $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable
    $j.actions[2].id = 'A7'
    $j | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $f -Encoding utf8
    Assert ((Set-DemoUserAction -Prefix $prefix -Key 'k4' -Action 'Fourth').id -eq 'A8') 'next id after a gap is max+1'
    Assert (-not (Test-Path -LiteralPath "$f.tmp")) 'no temporary file left behind'

    Write-Host 'Get-DemoIdsFor'
    $fake = [pscustomobject]@{ demos = @(
            [pscustomobject]@{ id = 'D10'; portal = 'entra'; agents = @('a') }, [pscustomobject]@{ id = 'D2'; portal = 'purview'; agents = @('b', 'a') },
            [pscustomobject]@{ id = 'C1'; portal = 'entra'; agents = @() }, [pscustomobject]@{ id = 'D3'; portal = 'x'; agents = @() }) }
    $ids = @(Get-DemoIdsFor $fake -AgentKeys @('a'))
    Assert (($ids -join ',') -eq 'D2,D10') 'by agent, numeric order (D2 before D10)'
    $ids = @(Get-DemoIdsFor $fake -AgentKeys @('a') -Portals @('entra'))
    Assert (($ids -join ',') -eq 'C1,D2,D10') 'agents + portals, unique, C before D'
    Assert (@(Get-DemoIdsFor $fake -Portals @('none')).Count -eq 0) 'no match = empty'

    Write-Host 'Set-DemoUserAction.ps1 wrapper'
    $w = Join-Path $PSScriptRoot 'Set-DemoUserAction.ps1'
    pwsh -NoProfile -File $w -Prefix $prefix -Key 'w1' -Action 'From wrapper' -Where 'here' -NeededBy 'D7' -Blocking | Out-Null
    Assert ($LASTEXITCODE -eq 0 -and (Get-Row 'w1').blocking -and (Get-Row 'w1').id -eq 'A9') 'wrapper creates a blocking row'
    pwsh -NoProfile -File $w -Prefix $prefix -Key 'w1' -NotBlocking -Status DONE | Out-Null
    Assert ((Get-Row 'w1').status -eq 'DONE' -and -not (Get-Row 'w1').blocking -and (Get-Row 'w1').where -eq 'here') 'wrapper updates flags and keeps texts'
    $out = pwsh -NoProfile -File $w -Prefix $prefix -List 6>&1 | Out-String
    Assert ($LASTEXITCODE -eq 0 -and $out -match 'From wrapper') 'wrapper -List prints the register'
    pwsh -NoProfile -File $w -Prefix $prefix -Key 'w1' -Blocking -NotBlocking 2>$null | Out-Null
    Assert ($LASTEXITCODE -ne 0) 'wrapper rejects -Blocking with -NotBlocking'
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
Write-Host ''
Write-Host "Passed $($script:pass), failed $($script:fail)" -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $(if ($script:fail) { 1 } else { 0 })
