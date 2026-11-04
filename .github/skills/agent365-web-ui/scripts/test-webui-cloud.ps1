#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '_webui-cloud.ps1')
$passed = 0
$script:EnvironmentItems = @()
$script:ReadCode = 0
$script:UpdateCode = 0
$script:Updates = [Collections.Generic.List[object]]::new()
function az {
    if ($args[1] -eq 'show') {
        $global:LASTEXITCODE = $script:ReadCode
        if ($script:ReadCode -eq 0) { ConvertTo-Json -InputObject $script:EnvironmentItems -Depth 5 -Compress }
    }
    elseif ($args[1] -eq 'update') {
        $script:Updates.Add(@($args))
        $global:LASTEXITCODE = $script:UpdateCode
    }
    else { throw 'Unexpected Azure CLI operation in the CORS fixture.' }
}
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
    Write-Host "PASS: $Message"
}
function Invoke-Cors([string]$Audience = '') {
    Add-AcaCorsOrigin -App fixture -ResourceGroup fixture-rg -Origin 'https://ui.example.test' -Subscription fixture-sub -S2sAudience $Audience
}
foreach ($items in @(
    @{ name = 'empty'; value = @() },
    @{ name = 'unrelated'; value = @([pscustomobject]@{ name = 'OTHER'; value = 'keep' }) },
    @{ name = 'blank'; value = @([pscustomobject]@{ name = 'UI_ALLOWED_ORIGINS'; value = '' }) },
    @{ name = 'null'; value = @([pscustomobject]@{ name = 'UI_ALLOWED_ORIGINS'; value = $null }) }
)) {
    $script:EnvironmentItems = $items.value; $script:Updates.Clear()
    Assert (Invoke-Cors) "$($items.name) origin configuration accepts the first UI under strict mode."
    Assert ($script:Updates[0] -contains 'UI_ALLOWED_ORIGINS=https://ui.example.test') "$($items.name) origin configuration writes the exact first origin."
}
$script:EnvironmentItems = @([pscustomobject]@{ name = 'UI_ALLOWED_ORIGINS'; value = ' https://first.example.test, https://ui.example.test ' })
$script:Updates.Clear()
Assert (Invoke-Cors 'audience-fixture') 'Existing origins and an S2S audience can be merged.'
Assert ($script:Updates[0] -contains 'UI_ALLOWED_ORIGINS=https://first.example.test,https://ui.example.test') 'Other origins survive and the current UI is not duplicated.'
Assert ($script:Updates[0] -contains 'UI_AUDIENCE=audience-fixture') 'S2S audience is preserved in the same update.'
foreach ($invalid in @(
    [pscustomobject]@{ name = 'UI_ALLOWED_ORIGINS'; secretRef = 'origins-secret' },
    [pscustomobject]@{ name = 'UI_ALLOWED_ORIGINS' }
)) {
    $script:EnvironmentItems = @($invalid); $script:Updates.Clear(); $rejected = $false
    try { Invoke-Cors | Out-Null } catch { $rejected = $_.Exception.Message -match 'secret-backed|no readable value' }
    Assert ($rejected -and $script:Updates.Count -eq 0) 'Unreadable configured origins are reported before any update.'
}
$script:EnvironmentItems = @(); $script:ReadCode = 1; $script:Updates.Clear(); $rejected = $false
try { Invoke-Cors | Out-Null } catch { $rejected = $_.Exception.Message -match 'Cannot read environment variables' }
Assert ($rejected -and $script:Updates.Count -eq 0) 'A failed cloud read cannot erase an unknown existing origin list.'
$script:ReadCode = 0; $script:UpdateCode = 1
Assert (-not (Invoke-Cors)) 'Cloud update failure remains visible to the caller.'
$global:LASTEXITCODE = 0
Write-Host "$passed CORS cloud-helper checks passed."
