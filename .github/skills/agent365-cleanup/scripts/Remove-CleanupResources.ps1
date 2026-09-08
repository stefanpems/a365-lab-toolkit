#requires -Version 7.0
<#
.SYNOPSIS
  Delete the Agent 365 lab resources selected in the cleanup wizard, writing a persistent deletion log.

.DESCRIPTION
  Consumes a JSON selection produced from Discover-CleanupResources.ps1 (the subset the operator
  confirmed in the checkbox review) and deletes each item in dependency order. Every action — success,
  skip, or error — is appended to a human-readable log so an unexpected outcome can be reconstructed.

  Deletion is idempotent and continues past individual failures (each is logged); it never aborts the
  whole run because one item errors. Supported actions and order:

    10  remove-licenses-and-delete-user  Remove EVERY assigned license (guaranteed, verified), then
                                         soft-delete the agent user and PURGE it from the recycle bin.
    20  delete-app                       az ad app delete (cascades its SP), then purge the app and any
                                         leftover SP from the recycle bin.
    24  purge-deleted-item               Permanently remove an object already sitting in the recycle bin.
    30  delete-connector                 Delete a Power Platform custom connector.
    38  delete-swa                       Delete a Static Web App resource.
    39  purge-cognitiveservices          Delete (if live) + PURGE a Cognitive Services account, freeing its
                                         name + regional quota and removing its child project ("workspace").
    40  delete-rg                        Delete an Azure resource group (async by default; see -WaitForRg).

  License release is the priority: a soft-delete alone does NOT free M365 licenses — only the purge
  does — so this script removes the licenses explicitly first AND purges the object, then verifies.

.PARAMETER SelectionPath
  Path to the JSON array of selected items to delete.

.PARAMETER Subscription
  Target subscription id. Pinned before every operation (az ad / Graph use the active account).

.PARAMETER TenantId
  Expected tenant id. The script aborts if the signed-in az context is a different tenant.

.PARAMETER LogPath
  Path to the persistent deletion log (appended). Defaults next to the selection file.

.PARAMETER WaitForRg
  Wait for each resource group deletion to complete (can take 20-40 min for ACA environments). By
  default resource-group deletion is started with --no-wait and logged as "initiated".

.PARAMETER WhatIf
  List what would be deleted, and write WHATIF lines to the log, without deleting anything.

.PARAMETER Force
  Skip the final "type DELETE to proceed" confirmation (for non-interactive/automated runs).

.EXAMPLE
  pwsh -File .\Remove-CleanupResources.ps1 -SelectionPath .\selection.json `
      -Subscription <sub> -TenantId <tenant>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SelectionPath,
    [Parameter(Mandatory)][string]$Subscription,
    [string]$TenantId,
    [string]$LogPath,
    [switch]$WaitForRg,
    [switch]$WhatIf,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Test-Path -LiteralPath $SelectionPath)) { throw "Selection file not found: $SelectionPath" }
$selection = @(Get-Content -LiteralPath $SelectionPath -Raw | ConvertFrom-Json)
if (-not $selection -or $selection.Count -eq 0) { Write-Host "Selection is empty — nothing to delete." -ForegroundColor Yellow; return }

if (-not $LogPath) { $LogPath = Join-Path (Split-Path -Parent $SelectionPath) 'deletion.log' }
$logDir = Split-Path -Parent $LogPath
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$resultPath = Join-Path $logDir 'result.json'
$results = New-Object System.Collections.Generic.List[object]

function Write-Log {
    param([string]$Status, [string]$Message)
    $line = "[{0}] [{1}] {2}" -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $Status, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
    $color = switch ($Status) { 'OK' { 'Green' } 'ERROR' { 'Red' } 'WHATIF' { 'Yellow' } 'SKIP' { 'DarkYellow' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
}
function Add-Result {
    param($Item, [string]$Status, [string]$Message)
    $results.Add([pscustomobject]@{
            category = $Item.category; kind = $Item.kind; displayName = $Item.displayName
            id = $Item.id; action = $Item.action; status = $Status; message = $Message
            timestamp = (Get-Date).ToUniversalTime().ToString('o')
        })
}

# ---------------------------------------------------------------------------
# Context: pin subscription + verify tenant (az ad / Graph use the active account).
# ---------------------------------------------------------------------------
az account set --subscription $Subscription | Out-Null
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' first." }
if ($TenantId -and $ctx.tenantId -ne $TenantId) {
    throw "az context tenant '$($ctx.tenantId)' != -TenantId '$TenantId'. Re-pin the context and retry."
}
$sub = $ctx.id
$signedIn = $ctx.user.name

Write-Log 'INFO' "=== Cleanup run started by '$signedIn' — tenant $($ctx.tenantId), subscription $sub, $($selection.Count) item(s)$(if($WhatIf){' [WHATIF]'}) ==="

# ---------------------------------------------------------------------------
# Final confirmation (unless -Force / -WhatIf).
# ---------------------------------------------------------------------------
if (-not $WhatIf -and -not $Force) {
    Write-Host ""
    Write-Host "About to permanently delete $($selection.Count) resource(s) in tenant $($ctx.tenantId):" -ForegroundColor Red
    $selection | ForEach-Object { Write-Host ("  [{0}] {1} — {2}" -f $_.category, $_.kind, $_.displayName) -ForegroundColor Gray }
    $answer = Read-Host "Type DELETE to proceed (anything else cancels)"
    if ($answer -ne 'DELETE') { Write-Log 'INFO' 'Cancelled at final confirmation.'; return }
}

# ---------------------------------------------------------------------------
# Graph helpers.
# ---------------------------------------------------------------------------
function Invoke-GraphDelete {
    param([string]$Url, [switch]$OkIfMissing)
    $out = az rest --method DELETE --url $Url 2>&1
    if ($LASTEXITCODE -eq 0) { return @{ ok = $true; message = 'deleted' } }
    $txt = ($out | Out-String).Trim()
    if ($OkIfMissing -and ($txt -match '(?i)(404|not\s*found|does not exist|Request_ResourceNotFound)')) {
        return @{ ok = $true; message = 'already absent' }
    }
    return @{ ok = $false; message = $txt }
}

function Get-UserLicenseSkuIds {
    param([string]$UserId)
    # No query params: licenseDetails already returns skuId + skuPartNumber, and a '?$select=' with a
    # comma is corrupted by az.cmd/cmd.exe argument parsing on some Windows hosts.
    $raw = az rest --method GET --url "https://graph.microsoft.com/v1.0/users/$UserId/licenseDetails" -o json 2>$null
    if (-not $raw) { return @() }
    try { return @(($raw | ConvertFrom-Json).value) } catch { return @() }
}

# ---------------------------------------------------------------------------
# Per-action removal.
# ---------------------------------------------------------------------------
function Remove-AgentInstance {
    param($Item)
    $uid = $Item.objectId; if (-not $uid) { $uid = $Item.id }
    $upn = $Item.userPrincipalName

    # 1. Remove EVERY assigned license (guaranteed release, not reliant on the async purge).
    $lic = Get-UserLicenseSkuIds -UserId $uid
    $skuIds = @($lic | ForEach-Object { $_.skuId } | Where-Object { $_ })
    $parts = @($lic | ForEach-Object { $_.skuPartNumber } | Where-Object { $_ })
    if ($skuIds.Count -gt 0) {
        if ($WhatIf) {
            Write-Log 'WHATIF' "would remove licenses [$($parts -join ', ')] from user $upn ($uid)"
        }
        else {
            $body = @{ addLicenses = @(); removeLicenses = $skuIds } | ConvertTo-Json -Compress
            $tmp = [System.IO.Path]::GetTempFileName()
            Set-Content -LiteralPath $tmp -Value $body -Encoding utf8
            $out = az rest --method POST --url "https://graph.microsoft.com/v1.0/users/$uid/assignLicense" --headers 'Content-Type=application/json' --body "@$tmp" 2>&1
            $rc = $LASTEXITCODE
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            if ($rc -eq 0) { Write-Log 'OK' "removed licenses [$($parts -join ', ')] from user $upn ($uid)" }
            else { Write-Log 'ERROR' "license removal failed for $upn ($uid): $(( $out | Out-String).Trim()) — will still purge to release" }
            # Verify the explicit removal.
            $still = Get-UserLicenseSkuIds -UserId $uid
            if (@($still).Count -gt 0) { Write-Log 'INFO' "user $upn still shows $((@($still)).Count) license(s) after removal; the purge below releases them" }
            else { Write-Log 'OK' "verified user $upn holds no licenses after removal" }
        }
    }
    else { Write-Log 'INFO' "user $upn ($uid) holds no licenses" }

    if ($WhatIf) {
        Write-Log 'WHATIF' "would soft-delete + purge agent user $upn ($uid)"
        Add-Result $Item 'WHATIF' "licenses [$($parts -join ', ')]"
        return
    }

    # 2. Soft-delete the agent user.
    $del = Invoke-GraphDelete -Url "https://graph.microsoft.com/v1.0/users/$uid" -OkIfMissing
    if ($del.ok) { Write-Log 'OK' "soft-deleted agent user $upn ($uid) [$($del.message)]" }
    else { Write-Log 'ERROR' "soft-delete failed for $upn ($uid): $($del.message)"; Add-Result $Item 'ERROR' $del.message; return }

    # 3. Purge from the recycle bin — this definitively releases the licenses.
    $purge = Invoke-GraphDelete -Url "https://graph.microsoft.com/v1.0/directory/deletedItems/$uid" -OkIfMissing
    if ($purge.ok) { Write-Log 'OK' "purged agent user $upn ($uid) from recycle bin [$($purge.message)] — licenses released" }
    else { Write-Log 'ERROR' "purge failed for $upn ($uid): $($purge.message)" }

    # 4. Verify the user is gone.
    $check = az rest --method GET --url "https://graph.microsoft.com/v1.0/users/$uid" 2>&1
    if ($LASTEXITCODE -ne 0 -and ($check | Out-String) -match '(?i)(404|Request_ResourceNotFound|not\s*found)') {
        Write-Log 'OK' "verified agent user $upn ($uid) no longer exists (licenses released)"
        Add-Result $Item 'OK' "purged; released [$($parts -join ', ')]"
    }
    else {
        Write-Log 'INFO' "agent user $upn ($uid) still resolves post-purge (propagation delay possible)"
        Add-Result $Item 'OK' "delete issued; released [$($parts -join ', ')]"
    }
}

function Remove-EntraApp {
    param($Item)
    $appId = $Item.id
    $objId = $Item.objectId
    if ($WhatIf) { Write-Log 'WHATIF' "would delete + purge Entra app '$($Item.displayName)' ($appId)"; Add-Result $Item 'WHATIF' ''; return }

    $out = az ad app delete --id $appId 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Log 'OK' "deleted Entra app '$($Item.displayName)' ($appId)" }
    elseif (($out | Out-String) -match '(?i)(not\s*found|does not exist|Request_ResourceNotFound)') { Write-Log 'SKIP' "Entra app '$($Item.displayName)' already absent" }
    else { Write-Log 'ERROR' "app delete failed '$($Item.displayName)' ($appId): $(( $out | Out-String).Trim())"; Add-Result $Item 'ERROR' 'app delete failed'; return }

    # Purge the app object from the recycle bin.
    if ($objId) {
        $p = Invoke-GraphDelete -Url "https://graph.microsoft.com/v1.0/directory/deletedItems/$objId" -OkIfMissing
        if ($p.ok) { Write-Log 'OK' "purged Entra app '$($Item.displayName)' from recycle bin [$($p.message)]" }
        else { Write-Log 'ERROR' "app purge failed '$($Item.displayName)': $($p.message)" }
    }
    # Purge any leftover service principal for this app that landed in the recycle bin. The filter
    # value is URL-encoded and used as a single query param (no '&'): az.cmd/cmd.exe corrupt '&', quotes
    # and parentheses in a raw --url, which would otherwise return nothing and leave the SP behind.
    $spFilterUrl = "https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.servicePrincipal?" + '$filter=' + [uri]::EscapeDataString("appId eq '$appId'")
    $spDel = az rest --method GET --url $spFilterUrl -o json 2>$null
    $spParsed = $null; try { $spParsed = ($spDel -join "`n") | ConvertFrom-Json } catch { $spParsed = $null }
    foreach ($sp in @($spParsed.value)) {
        if (-not $sp.id) { continue }
        $ps = Invoke-GraphDelete -Url "https://graph.microsoft.com/v1.0/directory/deletedItems/$($sp.id)" -OkIfMissing
        if ($ps.ok) { Write-Log 'OK' "purged leftover service principal ($($sp.id)) for app '$($Item.displayName)'" }
    }
    Add-Result $Item 'OK' 'deleted + purged'
}

function Remove-DeletedItem {
    param($Item)
    $objId = $Item.objectId; if (-not $objId) { $objId = $Item.id }
    if ($WhatIf) { Write-Log 'WHATIF' "would purge recycle-bin item '$($Item.displayName)' ($objId)"; Add-Result $Item 'WHATIF' ''; return }
    # If it is a deleted user that still holds licenses, they are released on purge.
    $p = Invoke-GraphDelete -Url "https://graph.microsoft.com/v1.0/directory/deletedItems/$objId" -OkIfMissing
    if ($p.ok) { Write-Log 'OK' "purged recycle-bin item '$($Item.displayName)' ($objId) [$($p.message)]"; Add-Result $Item 'OK' 'purged' }
    else { Write-Log 'ERROR' "purge failed '$($Item.displayName)' ($objId): $($p.message)"; Add-Result $Item 'ERROR' $p.message }
}

function Remove-Connector {
    param($Item)
    $envId = $Item.environment
    $delUrl = "https://api.powerapps.com/providers/Microsoft.PowerApps/apis/$($Item.id)?api-version=2016-11-01&`$filter=environment eq '$envId'"
    if ($WhatIf) { Write-Log 'WHATIF' "would delete connector '$($Item.displayName)' in env $envId"; Add-Result $Item 'WHATIF' ''; return }
    $out = az rest --method delete --url $delUrl --resource 'https://service.powerapps.com/' 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Log 'OK' "deleted connector '$($Item.displayName)' in env $envId"; Add-Result $Item 'OK' 'deleted' }
    else { Write-Log 'ERROR' "connector delete failed '$($Item.displayName)': $(( $out | Out-String).Trim())"; Add-Result $Item 'ERROR' 'delete failed' }
}

function Remove-Swa {
    param($Item)
    if ($WhatIf) { Write-Log 'WHATIF' "would delete Static Web App '$($Item.displayName)'"; Add-Result $Item 'WHATIF' ''; return }
    $out = az staticwebapp delete -n $Item.displayName -g $Item.resourceGroup --yes --subscription $sub 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Log 'OK' "deleted Static Web App '$($Item.displayName)'"; Add-Result $Item 'OK' 'deleted' }
    elseif (($out | Out-String) -match '(?i)(not\s*found|does not exist|ResourceNotFound)') { Write-Log 'SKIP' "Static Web App '$($Item.displayName)' already absent (RG delete may have removed it)"; Add-Result $Item 'SKIP' 'absent' }
    else { Write-Log 'ERROR' "SWA delete failed '$($Item.displayName)': $(( $out | Out-String).Trim())"; Add-Result $Item 'ERROR' 'delete failed' }
}

function Remove-ResourceGroup {
    param($Item)
    $rg = $Item.id
    $exists = az group exists -n $rg --subscription $sub 2>$null
    if ($exists -ne 'true') { Write-Log 'SKIP' "resource group '$rg' does not exist"; Add-Result $Item 'SKIP' 'absent'; return }
    if ($WhatIf) { Write-Log 'WHATIF' "would delete resource group '$rg'"; Add-Result $Item 'WHATIF' ''; return }
    if ($WaitForRg) {
        $out = az group delete -n $rg --subscription $sub --yes 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Log 'OK' "deleted resource group '$rg'"; Add-Result $Item 'OK' 'deleted' }
        else { Write-Log 'ERROR' "RG delete failed '$rg': $(( $out | Out-String).Trim())"; Add-Result $Item 'ERROR' 'delete failed' }
    }
    else {
        $out = az group delete -n $rg --subscription $sub --yes --no-wait 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Log 'OK' "resource group '$rg' deletion initiated (async; --no-wait). Verify later with: az group exists -n $rg"; Add-Result $Item 'OK' 'delete initiated (async)' }
        else { Write-Log 'ERROR' "RG delete failed to start '$rg': $(( $out | Out-String).Trim())"; Add-Result $Item 'ERROR' 'delete failed to start' }
    }
}

function Remove-CognitiveServicesAccount {
    param($Item)
    $name = $Item.id; $rg = $Item.resourceGroup; $loc = $Item.location
    if ($WhatIf) { Write-Log 'WHATIF' "would delete+purge Cognitive Services account '$name' (RG $rg, $loc)"; Add-Result $Item 'WHATIF' ''; return }
    # Soft-delete if it is still live (harmless if it is already gone or already soft-deleted).
    az cognitiveservices account delete -n $name -g $rg --subscription $sub 2>$null
    # Purge from the soft-deleted state: frees the name + regional quota and removes the child project
    # ("workspace"), which is what blocks a same-name re-provision. No separate AML-workspace purge needed.
    $out = az cognitiveservices account purge --location $loc --resource-group $rg --name $name --subscription $sub 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Log 'OK' "purged Cognitive Services account '$name' (RG $rg, $loc)"; Add-Result $Item 'OK' 'purged' }
    elseif (($out | Out-String) -match '(?i)(not\s*found|does not exist|ResourceNotFound|no\s+deleted)') { Write-Log 'SKIP' "Cognitive Services account '$name' already purged/absent"; Add-Result $Item 'SKIP' 'absent' }
    else { Write-Log 'ERROR' "purge failed '$name' (RG $rg, $loc): $(( $out | Out-String).Trim())"; Add-Result $Item 'ERROR' 'purge failed' }
}

function Remove-ServicePrincipal {
    param($Item)
    $spObj = $Item.objectId; if (-not $spObj) { $spObj = $Item.id }
    if ($WhatIf) { Write-Log 'WHATIF' "would delete + purge service principal '$($Item.displayName)' ($spObj)"; Add-Result $Item 'WHATIF' ''; return }
    $del = Invoke-GraphDelete -Url "https://graph.microsoft.com/v1.0/servicePrincipals/$spObj" -OkIfMissing
    if ($del.ok) { Write-Log 'OK' "deleted service principal '$($Item.displayName)' ($spObj) [$($del.message)]" }
    else { Write-Log 'ERROR' "SP delete failed '$($Item.displayName)' ($spObj): $($del.message)"; Add-Result $Item 'ERROR' $del.message; return }
    $p = Invoke-GraphDelete -Url "https://graph.microsoft.com/v1.0/directory/deletedItems/$spObj" -OkIfMissing
    if ($p.ok) { Write-Log 'OK' "purged service principal '$($Item.displayName)' from recycle bin [$($p.message)]" }
    else { Write-Log 'INFO' "SP '$($Item.displayName)' recycle-bin purge: $($p.message)" }
    Add-Result $Item 'OK' 'deleted + purged'
}

# ---------------------------------------------------------------------------
# Execute in dependency order (licenses/users first, resource groups last).
# ---------------------------------------------------------------------------
$ordered = @($selection | Sort-Object { [int]($_.deleteOrder ?? 50) })
foreach ($item in $ordered) {
    # Re-pin the subscription before each item (a concurrent session can flip the shared az context).
    az account set --subscription $Subscription | Out-Null
    try {
        switch ($item.action) {
            'remove-licenses-and-delete-user' { Remove-AgentInstance $item }
            'delete-app' { Remove-EntraApp $item }
            'delete-sp' { Remove-ServicePrincipal $item }
            'purge-deleted-item' { Remove-DeletedItem $item }
            'delete-connector' { Remove-Connector $item }
            'delete-swa' { Remove-Swa $item }
            'purge-cognitiveservices' { Remove-CognitiveServicesAccount $item }
            'delete-rg' { Remove-ResourceGroup $item }
            default { Write-Log 'SKIP' "unknown action '$($item.action)' for '$($item.displayName)'"; Add-Result $item 'SKIP' 'unknown action' }
        }
    }
    catch {
        Write-Log 'ERROR' "unhandled error on '$($item.displayName)': $($_.Exception.Message)"
        Add-Result $item 'ERROR' $_.Exception.Message
    }
}

$results | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding utf8
$okCount = @($results | Where-Object { $_.status -eq 'OK' }).Count
$errCount = @($results | Where-Object { $_.status -eq 'ERROR' }).Count
Write-Log 'INFO' "=== Cleanup run finished: $okCount ok, $errCount error(s). Log: $LogPath | Result: $resultPath ==="
Write-Host ""
Write-Host "Done. $okCount succeeded, $errCount error(s). Persistent log: $LogPath" -ForegroundColor Cyan
if ($errCount -gt 0) { Write-Host "Review the ERROR lines in the log to reconstruct anything unexpected." -ForegroundColor Yellow }
