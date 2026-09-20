#Requires -Version 7
<#
.SYNOPSIS
  Shared read-only helpers for the Purview Audit Explorer.
  Dot-source this file: . "$PSScriptRoot/_common.ps1"

  Auth model (device sign-in is blocked in some workspaces, so this avoids it entirely):
    * A dedicated Entra app registration 'a365-purview-audit-explorer' is created/reused with the two
      READ-ONLY Microsoft Graph application permissions AiEnterpriseInteraction.Read.All and
      AuditLogsQuery.Read.All, self-consented using the operator's already-signed-in `az` admin session
      (which holds Application.ReadWrite.All + AppRoleAssignment.ReadWrite.All).
    * The app's client secret is cached OUTSIDE the repository, under $HOME/.a365-purview-audit-explorer/,
      never committed. App-only tokens are then minted via client-credentials.
    * The `az` session token is used ONLY to resolve user ids (it lacks the two target scopes by design).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:GraphAppId   = '00000003-0000-0000-c000-000000000000'
$script:AppName      = 'a365-purview-audit-explorer'
$script:WantRoles    = 'AiEnterpriseInteraction.Read.All', 'AuditLogsQuery.Read.All'
$script:CredDir      = Join-Path $HOME '.a365-purview-audit-explorer'
$script:CredPath     = Join-Path $script:CredDir 'cred.json'

function Get-AzGraphToken {
    # Reuse the operator's existing az session (no interactive sign-in).
    $t = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
    if (-not $t) {
        throw "No Azure CLI Graph token. Run: az login --scope https://graph.microsoft.com/.default"
    }
    return $t
}

function Get-ODataNext {
    param($Response)
    if ($Response.PSObject.Properties.Name -contains '@odata.nextLink') { return $Response.'@odata.nextLink' }
    return $null
}

function Invoke-Graph {
    param(
        [Parameter(Mandatory)] [string] $Token,
        [Parameter(Mandatory)] [string] $Uri,
        [string] $Method = 'GET',
        $Body
    )
    $h = @{ Authorization = "Bearer $Token" }
    if ($Body) {
        $h['Content-Type'] = 'application/json'
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $h -Body ($Body | ConvertTo-Json -Depth 10)
    }
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $h
}

function Get-AppOnlyToken {
    param([Parameter(Mandatory)] $Cred)
    $body = @{
        client_id     = $Cred.appId
        client_secret = $Cred.clientSecret
        scope         = 'https://graph.microsoft.com/.default'
        grant_type    = 'client_credentials'
    }
    (Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$($Cred.tenantId)/oauth2/v2.0/token" -Body $body).access_token
}

function Initialize-PurviewApp {
    <#
      Ensure the dedicated app registration exists & is consented; return a fresh app-only token.
      Reuses the cached secret when it still works; only bootstraps when needed.
    #>
    [CmdletBinding()]
    param([switch] $ForceBootstrap)

    # 1. Try the cached credential first.
    if (-not $ForceBootstrap -and (Test-Path $script:CredPath)) {
        try {
            $cred = Get-Content $script:CredPath -Raw | ConvertFrom-Json
            $tok = Get-AppOnlyToken -Cred $cred
            if ($tok) { return [pscustomobject]@{ Token = $tok; Cred = $cred } }
        }
        catch { Write-Verbose "Cached credential unusable; bootstrapping. $($_.Exception.Message)" }
    }

    # 2. Bootstrap using the az admin session (direct REST to avoid the `az ad` CAE loop).
    $az = Get-AzGraphToken
    $tenantId = az account show --query tenantId -o tsv
    $base = 'https://graph.microsoft.com/v1.0'

    $graphSp = Invoke-Graph -Token $az -Uri "$base/servicePrincipals(appId='$($script:GraphAppId)')"
    $roleIds = @()
    foreach ($rv in $script:WantRoles) {
        $r = $graphSp.appRoles | Where-Object { $_.value -eq $rv -and $_.isEnabled }
        if (-not $r) { throw "Graph application permission '$rv' not found/enabled in this tenant." }
        $roleIds += $r.id
    }

    $flt = [uri]::EscapeDataString("displayName eq '$($script:AppName)'")
    $ex = Invoke-Graph -Token $az -Uri "$base/applications?`$filter=$flt"
    if ($ex.value.Count -gt 0) {
        $app = $ex.value[0]
    }
    else {
        $app = Invoke-Graph -Token $az -Method POST -Uri "$base/applications" -Body @{
            displayName            = $script:AppName
            signInAudience         = 'AzureADMyOrg'
            requiredResourceAccess = @(@{ resourceAppId = $script:GraphAppId; resourceAccess = @($roleIds | ForEach-Object { @{ id = $_; type = 'Role' } }) })
        }
    }

    $spFlt = [uri]::EscapeDataString("appId eq '$($app.appId)'")
    $spEx = Invoke-Graph -Token $az -Uri "$base/servicePrincipals?`$filter=$spFlt"
    if ($spEx.value.Count -gt 0) {
        $sp = $spEx.value[0]
    }
    else {
        $sp = Invoke-Graph -Token $az -Method POST -Uri "$base/servicePrincipals" -Body @{ appId = $app.appId }
        Start-Sleep -Milliseconds 1500
    }

    $assigned = Invoke-Graph -Token $az -Uri "$base/servicePrincipals/$($sp.id)/appRoleAssignments"
    foreach ($rid in $roleIds) {
        if ($assigned.value | Where-Object { $_.appRoleId -eq $rid -and $_.resourceId -eq $graphSp.id }) { continue }
        Invoke-Graph -Token $az -Method POST -Uri "$base/servicePrincipals/$($sp.id)/appRoleAssignedTo" -Body @{
            principalId = $sp.id; resourceId = $graphSp.id; appRoleId = $rid
        } | Out-Null
    }

    $pw = Invoke-Graph -Token $az -Method POST -Uri "$base/applications/$($app.id)/addPassword" -Body @{
        passwordCredential = @{ displayName = "purview-audit-explorer-$(Get-Date -Format yyyyMMddHHmmss)" }
    }

    $cred = [ordered]@{ tenantId = $tenantId; appId = $app.appId; clientSecret = $pw.secretText; spId = $sp.id }
    if (-not (Test-Path $script:CredDir)) { New-Item -ItemType Directory -Path $script:CredDir -Force | Out-Null }
    ($cred | ConvertTo-Json) | Set-Content -Path $script:CredPath -Encoding utf8

    # New app-role assignments can take a few seconds to reflect in a fresh token.
    for ($i = 0; $i -lt 8; $i++) {
        try {
            $tok = Get-AppOnlyToken -Cred ([pscustomobject]$cred)
            if ($tok) { return [pscustomobject]@{ Token = $tok; Cred = ([pscustomobject]$cred) } }
        }
        catch { }
        Start-Sleep -Seconds 4
    }
    throw "Could not mint an app-only token after bootstrap."
}

function Resolve-UserId {
    param([Parameter(Mandatory)] [string] $Upn)
    $az = Get-AzGraphToken
    $u = Invoke-Graph -Token $az -Uri "https://graph.microsoft.com/v1.0/users/$Upn`?`$select=id,displayName,userPrincipalName"
    return $u
}

function Get-EnterpriseInteractions {
    <# Pull AI interaction history for one user; page and (optionally) client-side filter. #>
    param(
        [Parameter(Mandatory)] [string] $Token,
        [Parameter(Mandatory)] [string] $UserId,
        [datetime] $Since,
        [string]   $AppClassLike,
        [int]      $MaxPages = 50
    )
    $uri = "https://graph.microsoft.com/beta/copilot/users/$UserId/interactionHistory/getAllEnterpriseInteractions"
    $out = New-Object System.Collections.Generic.List[object]
    $next = $uri; $page = 0
    while ($next -and $page -lt $MaxPages) {
        $r = Invoke-Graph -Token $Token -Uri $next
        foreach ($it in $r.value) {
            if ($Since -and ([datetime]$it.createdDateTime) -lt $Since) { continue }
            if ($AppClassLike -and ($it.appClass -notlike $AppClassLike)) { continue }
            $out.Add($it)
        }
        $next = Get-ODataNext $r
        $page++
    }
    return $out
}

function Format-AgentName {
    # Derive a friendly agent label from the appClass.
    param([string] $AppClass)
    if ([string]::IsNullOrEmpty($AppClass)) { return '(unknown)' }
    if ($AppClass -like '*Copilot.ThirdPartyCopilot*') { return 'Copilot Studio / third-party (MCS)' }
    $m = [regex]::Match($AppClass, 'ConnectedAIApp\.AzureAI\.(?<n>.+)$')
    if ($m.Success) { return $m.Groups['n'].Value }
    return $AppClass
}
