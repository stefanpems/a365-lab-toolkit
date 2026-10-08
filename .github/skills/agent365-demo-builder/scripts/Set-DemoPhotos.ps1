#requires -Version 7.0
<#
.SYNOPSIS
  Sets the profile photo of the demo people (Microsoft Graph PUT /users/{id}/photo/$value) from a local folder.
.DESCRIPTION
  Photos are NOT shipped with the repo: put one image per persona in -PhotoDir, or (default) in the lab folder
  generated/<prefix>/demo/photos or the shared folder generated/_demo-photos/<pack> (one set for every lab and language).
  A file matches a persona when it is named <personaKey>.jpg|.jpeg|.png or when its name contains the persona's given
  name and surname in ANY locale of the pack (case, separators and accents ignored), for example "Portrait_Anna_Walsh.jpg"
  or "Ritratto_Anna_Verdi.jpg". JPEG or PNG, at most 4 MB, square and at least 648 x 648 pixels recommended.
  No photo found = a WARN and a row in the user-actions register (never a failure: photos are cosmetic).
  The az Graph token is tried first; on 401/403 an MSAL token with ProfilePhoto.ReadWrite.All is requested once
  (system browser, admin consent). A person whose mailbox is not provisioned yet may refuse the photo: re-run later.
  Set the leavers' photos BEFORE they are deleted; the reset calls this script again when it recreates a leaver.
.EXAMPLE
  pwsh -File .\Set-DemoPhotos.ps1 -Prefix cts2 -PhotoDir $HOME\Downloads
.EXAMPLE
  pwsh -File .\Set-DemoPhotos.ps1 -Prefix cts2 -Persona orphanLeaver
#>
[CmdletBinding(PositionalBinding = $false)]
param([Parameter(Mandatory)][string]$Prefix, [string]$PhotoDir, [string[]]$Persona = @('all'), [switch]$WhatIf)
. (Join-Path $PSScriptRoot '_demo-common.ps1')
$cfg = Read-DemoConfig $Prefix
Assert-DemoTenant $cfg
$pack = Get-DemoPack $cfg.pack
$L = Get-DemoLocale -Locale $cfg.locale -Pack $cfg.pack
# Photo folders: -PhotoDir, else the lab folder and the shared folder of the pack (one set serves every lab and language).
$sharedDir = Join-Path $script:DemoRepoRoot "generated\_demo-photos\$($cfg.pack)"
$dirs = if ($PhotoDir) { @($PhotoDir) } else { @((Join-Path (Get-DemoLabDir $Prefix) 'photos'), $sharedDir) }
$dirs = @($dirs | Where-Object { Test-Path -LiteralPath $_ })
$Persona = @($Persona | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$G = 'https://graph.microsoft.com/v1.0'
$maxBytes = [int64]$pack.photos.maxBytes
function Get-Norm([string]$s) { (ConvertTo-A365Alias @($s)) -replace '\.', '' }
$files = @(foreach ($d in $dirs) { Get-ChildItem -LiteralPath $d -File | Where-Object { $_.Extension.TrimStart('.').ToLowerInvariant() -in $pack.photos.formats } })
$where = "put one JPEG/PNG per persona (named <personaKey>.jpg or containing the persona's given name and surname in any language of the pack) in generated/_demo-photos/$($cfg.pack)/ (shared by every lab) or generated/$Prefix/demo/photos/, then re-run Set-DemoPhotos.ps1"
if (-not $files.Count) {
    Write-DemoLog $Prefix "Profile photos: no photo file found ($(if ($PhotoDir) { $PhotoDir } else { 'lab and shared folders' })): skipped. Photos are not shipped: $where" 'WARN'
    if (-not $WhatIf) { $null = Set-DemoUserAction -Prefix $Prefix -Key 'photos' -Action 'Provide the profile photos of the demo people (they are not shipped with the repo)' -Where $where -NeededBy 'the rehearsal (persona photos in Teams, Outlook and the admin center); the leavers BEFORE their deletion' }
    return
}
# Every locale of the pack: a photo named after the persona in another language still matches (for example a set
# prepared for an Italian lab reused by an English one).
$names = @{}
foreach ($loc in @($pack.locales)) {
    $lx = if ($loc -eq $cfg.locale) { $L } else { try { Get-DemoLocale -Locale $loc -Pack $cfg.pack } catch { $null } }
    if (-not $lx) { continue }
    foreach ($p in $pack.personas) { $lp = $lx.personas[$p.key]; if ($lp) { $names[$p.key] = @($names[$p.key]) + @(Get-Norm "$($lp.givenName)$($lp.surname)") | Where-Object { $_ } | Select-Object -Unique } }
}
$msal = $null
function Send-Photo([string]$UserId, [IO.FileInfo]$File) {
    $ct = if ($File.Extension -match '(?i)png') { 'image/png' } else { 'image/jpeg' }
    $bytes = [IO.File]::ReadAllBytes($File.FullName)
    foreach ($attempt in 1, 2) {
        $tok = if ($script:msal) { $script:msal } else { Get-DemoAzToken -TenantId $cfg.tenantId }
        try {
            Invoke-RestMethod -Method PUT -Uri "$G/users/$UserId/photo/`$value" -Headers @{ Authorization = "Bearer $tok" } -ContentType $ct -Body $bytes -TimeoutSec 120 -ErrorAction Stop | Out-Null
            return 'set'
        }
        catch {
            $s = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
            if ($s -in 401, 403 -and -not $script:msal -and $attempt -eq 1) {
                Write-Host '>>> A browser tab may open: sign in as the admin and ACCEPT the consent (profile photos).'
                $script:msal = Get-DemoMsalToken -TenantId $cfg.tenantId -Scopes @('ProfilePhoto.ReadWrite.All', 'User.ReadWrite.All') -Prefix $Prefix -LoginHint $cfg.adminUpn
                continue
            }
            $m = ($_.ErrorDetails.Message -replace '\s+', ' ')
            $hint = if ($m -match '(?i)mailbox|ErrorItemNotFound|ResourceNotFound') { ' (mailbox not provisioned yet: re-run later)' } else { '' }
            return "FAILED ($s)$hint"
        }
    }
}
$state = Read-DemoLabState $Prefix
$rows = @()
foreach ($p in $pack.personas) {
    if ($Persona -notcontains 'all' -and $Persona -notcontains $p.key) { continue }
    $lp = $L.personas[$p.key]
    $f = $files | Where-Object { $_.BaseName -ieq $p.key } | Select-Object -First 1
    if (-not $f) { $f = $files | Where-Object { $n = Get-Norm $_.BaseName; @($names[$p.key] | Where-Object { $n.Contains($_) }).Count } | Select-Object -First 1 }
    $upn = "$(Get-DemoPersonaAlias $L $p.key)@$($cfg.domain)"
    if (-not $f) { $rows += [pscustomobject]@{ persona = $p.key; user = $upn; file = '(none)'; result = 'photo file MISSING' }; continue }
    if ($f.Length -gt $maxBytes) { $rows += [pscustomobject]@{ persona = $p.key; user = $upn; file = $f.Name; result = "too large ($($f.Length) bytes, max $maxBytes)" }; continue }
    $u = Invoke-DemoGraph GET "$G/users/$([uri]::EscapeDataString($upn))?`$select=id" -NoThrow
    if (-not $u -or $u.PSObject.Properties['error']) { $rows += [pscustomobject]@{ persona = $p.key; user = $upn; file = $f.Name; result = 'user not found (create the identities first)' }; continue }
    $res = if ($WhatIf) { 'would set' } else { Send-Photo $u.id $f }
    if ($res -eq 'set') {
        if (-not $state.users.Contains($p.key)) { $state.users[$p.key] = [ordered]@{} }
        $state.users[$p.key]['photo'] = [ordered]@{ file = $f.Name; bytes = $f.Length; set = (Get-Date).ToString('s') }
    }
    $rows += [pscustomobject]@{ persona = $p.key; user = $upn; file = $f.Name; result = $res }
}
if (-not $WhatIf) { Save-DemoLabState $Prefix $state }
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$ok = @($rows | Where-Object result -eq 'set').Count
Write-DemoLog $Prefix "Profile photos: $ok of $($rows.Count) set$(if ($WhatIf) { ' (WhatIf)' })"
if (-not $WhatIf -and $Persona -contains 'all') {
    $missing = @($rows | Where-Object { $_.result -match '^(photo file MISSING|too large)' } | ForEach-Object { "$($_.persona) ($($_.result))" })
    $known = @((Read-DemoUserActions $Prefix).actions | Where-Object { $_.key -eq 'photos' }).Count -gt 0
    if ($missing.Count) { $null = Set-DemoUserAction -Prefix $Prefix -Key 'photos' -Action "Provide the missing profile photos: $($missing -join ', ')" -Where $where -NeededBy 'the rehearsal; the leavers BEFORE their deletion' -Status TODO }
    elseif ($known) { $null = Set-DemoUserAction -Prefix $Prefix -Key 'photos' -Status DONE }
}
