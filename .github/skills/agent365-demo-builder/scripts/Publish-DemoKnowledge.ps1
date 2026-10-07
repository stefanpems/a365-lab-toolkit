#requires -Version 7.0
<#
.SYNOPSIS
  Uploads the generated knowledge (generated/<prefix>/demo/knowledge/out) to the document library of the demo
  site group, one folder per knowledge area. Idempotent (files overwritten, folders reused). -WhatIf = dry run.
.DESCRIPTION
  SharePoint rejects the az token (401): a delegated MSAL token (Sites.ReadWrite.All, Files.ReadWrite.All; system
  browser on first use) is used. Folder URLs are saved in the demo state (the configuration cards link them).
  The personal file (_personal) is NOT uploaded: its owner uploads it to their own OneDrive (manual step).
.EXAMPLE
  pwsh -File .\Publish-DemoKnowledge.ps1 -Prefix cts2
#>
[CmdletBinding(PositionalBinding = $false)]
param([Parameter(Mandatory)][string]$Prefix, [switch]$WhatIf)
. (Join-Path $PSScriptRoot '_demo-common.ps1')
$cfg = Read-DemoConfig $Prefix
Assert-DemoTenant $cfg
$pack = Get-DemoPack $cfg.pack
$LOC = Get-DemoLocale -Locale $cfg.locale -Pack $cfg.pack
$state = Read-DemoLabState $Prefix
$out = Join-Path (Get-DemoLabDir $Prefix) 'knowledge\out'
if (-not (Test-Path -LiteralPath (Join-Path $out 'manifest.json'))) { throw "Knowledge not generated: run New-DemoKnowledge.ps1 -Prefix $Prefix first." }
$G = 'https://graph.microsoft.com/v1.0'
$tok = Get-DemoMsalToken -TenantId $cfg.tenantId -Scopes @('Sites.ReadWrite.All', 'Files.ReadWrite.All') -Prefix $Prefix -LoginHint $cfg.adminUpn
$nick = $LOC.groups[$pack.knowledge.siteGroup].mailNickname
$grp = @((Invoke-DemoGraph GET "$G/groups?`$filter=mailNickname eq '$nick'&`$select=id,displayName").value) | Select-Object -First 1
if (-not $grp) { throw "Site group '$nick' not found: run Set-DemoIdentities.ps1 first." }
$drive = $null
for ($i = 0; $i -lt 20 -and -not $drive; $i++) {
    $d = Invoke-DemoGraph GET "$G/groups/$($grp.id)/drive?`$select=id,webUrl" -Token $tok -NoThrow
    if ($d -and -not $d.PSObject.Properties['error']) { $drive = $d } else { Start-Sleep -Seconds 15 }
}
if (-not $drive) { throw 'The group site is not provisioned yet (a new Microsoft 365 group can take a few minutes): re-run later.' }
Write-DemoLog $Prefix "Knowledge target library: $($drive.webUrl)"
$enc = { param($s) [uri]::EscapeDataString($s) }
$manifest = Get-Content -LiteralPath (Join-Path $out 'manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json
$folders = [ordered]@{}
foreach ($fk in $pack.knowledge.folders) {
    $name = $LOC.knowledge.folders[$fk]
    $f = Invoke-DemoGraph GET "$G/drives/$($drive.id)/root:/$(& $enc $name)" -Token $tok -NoThrow
    if (-not $f -or $f.PSObject.Properties['error']) {
        if ($WhatIf) { Write-Host "  would create folder $name"; continue }
        $f = Invoke-DemoGraph POST "$G/drives/$($drive.id)/root/children" -Token $tok -Body @{ name = $name; folder = @{}; '@microsoft.graph.conflictBehavior' = 'fail' }
        Write-Host "  folder created: $name"
    }
    $folders[$fk] = [ordered]@{ name = $name; webUrl = $f.webUrl }
}
$n = 0
foreach ($m in $manifest | Where-Object { $_.folder -ne '_personal' }) {
    $src = Join-Path $out (Join-Path $m.folder $m.file)
    if ($WhatIf) { Write-Host "  would upload $($m.folder)/$($m.file)"; continue }
    $uri = "$G/drives/$($drive.id)/root:/$(& $enc $m.folder)/$(& $enc $m.file):/content"
    Invoke-RestMethod -Method PUT -Uri $uri -Headers @{ Authorization = "Bearer $tok" } -ContentType 'application/octet-stream' -InFile $src -TimeoutSec 300 | Out-Null
    $n++
    Write-Host "  uploaded: $($m.folder)/$($m.file)"
}
if (-not $WhatIf) {
    $state.knowledge = [ordered]@{ siteGroupId = $grp.id; driveId = $drive.id; libraryUrl = $drive.webUrl; folders = $folders; uploaded = (Get-Date).ToString('s'); files = $n }
    Save-DemoLabState $Prefix $state
}
$personal = @($manifest | Where-Object { $_.folder -eq '_personal' })
foreach ($pf in $personal) {
    Write-Host "MANUAL: the program lead uploads '$($pf.file)' (from $out\_personal) to their own OneDrive (it is the ungoverned personal source of D4)."
    if (-not $WhatIf) {
        $null = Set-DemoUserAction -Prefix $Prefix -Key "knowledge-personal-$($pf.file)" -Action "Signed in as $(Get-DemoUpn $LOC $cfg 'programLead') (program lead), upload '$($pf.file)' to their own OneDrive (the ungoverned personal source)" `
            -Where "file in generated/$Prefix/demo/knowledge/out/_personal/; OneDrive > My files > Upload" -NeededBy 'D4'
    }
}
Write-DemoLog $Prefix "Knowledge published: $n file(s)$(if ($WhatIf) { ' (dry run)' })"
