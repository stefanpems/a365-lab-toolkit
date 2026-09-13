#requires -Version 7.0
<#
  Shared cloud helpers for the web-UI association/deregistration scripts (Add-WebUiTab.ps1 /
  Remove-WebUiTab.ps1) and the Web UI Creator. These DO call Azure (unlike _webui-config.ps1).

  Every function pins the subscription on its az calls; the caller is responsible for the one-time
  tenant assertion. Kept small and dependency-light so the two entry-point scripts stay readable.
#>
Set-StrictMode -Version Latest

# Resolve a Static Web App's resource group + default host from its name (any RG in the sub).
function Resolve-Swa {
    param([Parameter(Mandatory)][string]$SwaName, [Parameter(Mandatory)][string]$Subscription, [string]$ResourceGroup)
    $q = if ($ResourceGroup) { @('staticwebapp', 'show', '-n', $SwaName, '-g', $ResourceGroup, '--subscription', $Subscription, '-o', 'json') }
         else { @('staticwebapp', 'list', '--subscription', $Subscription, '-o', 'json') }
    $raw = az @q 2>$null
    if (-not $raw) { throw "Static Web App '$SwaName' not found in subscription $Subscription." }
    $obj = $raw | ConvertFrom-Json
    $swa = if ($ResourceGroup) { $obj } else { @($obj | Where-Object { $_.name -eq $SwaName }) | Select-Object -First 1 }
    if (-not $swa) { throw "Static Web App '$SwaName' not found in subscription $Subscription." }
    return [pscustomobject]@{
        name          = $swa.name
        resourceGroup = $swa.resourceGroup
        id            = $swa.id
        host          = $swa.defaultHostname
        origin        = "https://$($swa.defaultHostname)"
    }
}

# Fetch the LIVE config.js from a deployed SWA (source of truth). Returns the raw text, or $null if
# the site has no config.js yet (fresh shell) or is unreachable.
function Get-DeployedConfigText {
    param([Parameter(Mandatory)][string]$Origin)
    try {
        return (Invoke-RestMethod -Uri "$($Origin.TrimEnd('/'))/config.js" -Headers @{ 'Cache-Control' = 'no-cache' } -TimeoutSec 30)
    }
    catch { return $null }
}

# Locate the StaticSitesClient.exe the SWA CLI downloads on first use (the npx wrapper exits 1 on Windows).
function Get-StaticSitesClient {
    $root = Join-Path $env:USERPROFILE '.swa\deploy'
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    $exe = Get-ChildItem -LiteralPath $root -Recurse -Filter 'StaticSitesClient.exe' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    return $(if ($exe) { $exe.FullName } else { $null })
}

# Deploy a UI folder to a SWA via StaticSitesClient.exe (build-free static re-upload). Must be called
# from the REPO ROOT with an ABSOLUTE --app path (the uploader rejects an artifact folder == cwd).
function Deploy-SwaContent {
    param(
        [Parameter(Mandatory)][string]$SwaName,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$AppFolder,
        [Parameter(Mandatory)][string]$Subscription
    )
    $appAbs = (Resolve-Path -LiteralPath $AppFolder).Path
    $tok = az staticwebapp secrets list -n $SwaName -g $ResourceGroup --subscription $Subscription --query 'properties.apiKey' -o tsv 2>$null
    if ([string]::IsNullOrWhiteSpace($tok)) { throw "Could not read the deployment token for SWA '$SwaName'." }
    $exe = Get-StaticSitesClient
    if (-not $exe) {
        # Trigger a download of the uploader once (the wrapper still fetches the binary even though it exits 1).
        npx --yes @azure/static-web-apps-cli --version *> $null
        $exe = Get-StaticSitesClient
    }
    if (-not $exe) { throw "StaticSitesClient.exe not found under ~/.swa/deploy. Run 'npx @azure/static-web-apps-cli --version' once to download it." }
    Push-Location (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path   # repo root
    try {
        # A freshly-created SWA can fail the first 1-2 uploads with "An unknown exception has occurred"
        # while its backend warms up. Retry a few times before giving up (idempotent static re-upload).
        $ok = $false
        for ($i = 1; $i -le 3 -and -not $ok; $i++) {
            & $exe upload --app $appAbs --apiToken $tok --skipAppBuild true
            if ($LASTEXITCODE -eq 0) { $ok = $true }
            elseif ($i -lt 3) { Write-Host "  SWA upload attempt $i failed (exit $LASTEXITCODE); retrying..." -ForegroundColor Yellow; Start-Sleep -Seconds 10 }
        }
        if (-not $ok) { throw "StaticSitesClient upload failed after 3 attempts (exit $LASTEXITCODE)." }
    }
    finally { Pop-Location }
}

# Merge one or more tags onto any Azure resource by id (used for a365component / a365ref_<prefix> on the SWA).
function Set-ResourceTags {
    param([Parameter(Mandatory)][string]$ResourceId, [Parameter(Mandatory)][hashtable]$Tags, [Parameter(Mandatory)][string]$Subscription)
    $pairs = @($Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
    az tag update --resource-id $ResourceId --operation Merge --tags @pairs --subscription $Subscription -o none 2>$null
    return ($LASTEXITCODE -eq 0)
}

# Remove named tag keys from an Azure resource by id (used to clear a365ref_<prefix> on deregistration).
function Remove-ResourceTagKeys {
    param([Parameter(Mandatory)][string]$ResourceId, [Parameter(Mandatory)][string[]]$Keys, [Parameter(Mandatory)][string]$Subscription)
    $pairs = @($Keys | ForEach-Object { "$_=" })
    az tag update --resource-id $ResourceId --operation Delete --tags @pairs --subscription $Subscription -o none 2>$null
    return ($LASTEXITCODE -eq 0)
}

# Append an origin to an ACA container's UI_ALLOWED_ORIGINS (read-modify-write, never clobbers others),
# and set UI_AUDIENCE for an S2S agent. FH/FD have no CORS surface, so this is ACA-only.
function Add-AcaCorsOrigin {
    param(
        [Parameter(Mandatory)][string]$App,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$Origin,
        [string]$S2sAudience,
        [Parameter(Mandatory)][string]$Subscription
    )
    $cur = az containerapp show -n $App -g $ResourceGroup --subscription $Subscription --query "properties.template.containers[0].env" -o json 2>$null | ConvertFrom-Json
    $existing = @($cur | Where-Object { $_.name -eq 'UI_ALLOWED_ORIGINS' } | Select-Object -First 1).value
    $origins = @()
    if ($existing) { $origins = @($existing -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    if ($origins -notcontains $Origin) { $origins += $Origin }
    $envArgs = @("UI_ALLOWED_ORIGINS=$($origins -join ',')")
    if ($S2sAudience) { $envArgs += "UI_AUDIENCE=$S2sAudience" }
    az containerapp update -n $App -g $ResourceGroup --subscription $Subscription --set-env-vars @envArgs -o none 2>$null
    return ($LASTEXITCODE -eq 0)
}
