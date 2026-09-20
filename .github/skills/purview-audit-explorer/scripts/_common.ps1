#Requires -Version 7
<#
.SYNOPSIS
  Shared helpers for the Purview Audit Explorer.
  Dot-source this file: . "$PSScriptRoot/_common.ps1"

  DESIGN (clean / repeatable / deterministic):
   * ONE-TIME SETUP (privileged, interactive admin) is done by Setup-PurviewAudit.ps1, which calls
     Register-PurviewApp to create/reuse a dedicated app registration with the READ-ONLY application
     permissions and grant admin consent. Verified fact: the transcript endpoint
     getAllEnterpriseInteractions is NOT supported in a delegated context (HTTP 412), so an app-only
     (application-permission) token is MANDATORY - there is no delegated alternative.
   * RUNTIME (read-only) uses Get-PurviewToken, which ONLY reads the cached credential and mints an
     app-only token. It has NO side effects, needs NO interactive sign-in and NO Azure CLI, so it behaves
     identically on every run. If the credential is missing it tells the user to run Setup once.
   * The client secret is cached OUTSIDE the repository at $HOME/.a365-purview-audit-explorer/cred.json
     and is never committed.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:GraphAppId = '00000003-0000-0000-c000-000000000000'
$script:AppName    = 'a365-purview-audit-explorer'
# Read-only application permissions the tool needs:
#  - AiEnterpriseInteraction.Read.All : read the agent<->user transcripts (app-only; no delegated option)
#  - AuditLogsQuery.Read.All          : tenant-wide discovery + action auditing (CopilotInteraction)
#  - User.Read.All                    : resolve UPN<->id at runtime without any Azure CLI dependency
$script:WantRoles  = 'AiEnterpriseInteraction.Read.All', 'AuditLogsQuery.Read.All', 'User.Read.All'
$script:CredDir    = Join-Path $HOME '.a365-purview-audit-explorer'
$script:CredPath   = Join-Path $script:CredDir 'cred.json'

# ---------------------------------------------------------------------------------------------------
# Graph request helpers
# ---------------------------------------------------------------------------------------------------
function Get-ODataNext {
    param($Response)
    if ($Response.PSObject.Properties.Name -contains '@odata.nextLink') { return $Response.'@odata.nextLink' }
    if (($Response -is [System.Collections.IDictionary]) -and $Response.Contains('@odata.nextLink')) { return $Response['@odata.nextLink'] }
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

# ---------------------------------------------------------------------------------------------------
# Privileged token sources - used by SETUP only
# ---------------------------------------------------------------------------------------------------
function Get-AzGraphToken {
    $t = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
    if (-not $t) { throw "No Azure CLI Graph token. Run: az login --scope https://graph.microsoft.com/.default" }
    return $t
}

# Dispatcher so Register-PurviewApp works with either a Graph PowerShell context or an az token.
$script:PrivMode = 'Az'      # 'Mg' | 'Az'
$script:PrivToken = $null

function Set-PrivilegedAuth {
    param([ValidateSet('Mg', 'Az')] [string] $Mode, [string] $Token)
    $script:PrivMode = $Mode
    $script:PrivToken = $Token
}

function Invoke-GraphPriv {
    param([string] $Method = 'GET', [Parameter(Mandatory)] [string] $Uri, $Body)
    if ($script:PrivMode -eq 'Mg') {
        if ($Body) { return Invoke-MgGraphRequest -Method $Method -Uri $Uri -Body ($Body | ConvertTo-Json -Depth 10) -ContentType 'application/json' }
        return Invoke-MgGraphRequest -Method $Method -Uri $Uri
    }
    return Invoke-Graph -Token $script:PrivToken -Method $Method -Uri $Uri -Body $Body
}

# ---------------------------------------------------------------------------------------------------
# App-only token - RUNTIME
# ---------------------------------------------------------------------------------------------------
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

function Get-PurviewToken {
    <#
      RUNTIME entry point. Deterministic and read-only: reads the cached credential and returns an
      app-only Graph token. Never creates or changes anything. Throws a clear instruction if setup
      has not been run.
    #>
    [CmdletBinding()] param()
    if (-not (Test-Path $script:CredPath)) {
        throw "Not set up yet. Run the one-time setup once:`n" +
        "  pwsh -File `"$PSScriptRoot/Setup-PurviewAudit.ps1`"`n" +
        "(It creates the read-only app registration '$($script:AppName)' and caches its credential at $($script:CredPath).)"
    }
    $cred = Get-Content $script:CredPath -Raw | ConvertFrom-Json
    try {
        $tok = Get-AppOnlyToken -Cred $cred
    }
    catch {
        throw "Cached credential at $($script:CredPath) no longer works ($($_.Exception.Message)). Re-run Setup-PurviewAudit.ps1 to refresh it."
    }
    if (-not $tok) { throw "Could not mint an app-only token. Re-run Setup-PurviewAudit.ps1." }
    return [pscustomobject]@{ Token = $tok; Cred = $cred }
}

# ---------------------------------------------------------------------------------------------------
# Registration - SETUP (idempotent). Requires Set-PrivilegedAuth to have been called first.
# ---------------------------------------------------------------------------------------------------
function Register-PurviewApp {
    [CmdletBinding()] param()
    $v1 = 'https://graph.microsoft.com/v1.0'

    $graphSp = Invoke-GraphPriv -Uri "$v1/servicePrincipals(appId='$($script:GraphAppId)')"
    $roleIds = @()
    foreach ($rv in $script:WantRoles) {
        $r = $graphSp.appRoles | Where-Object { $_.value -eq $rv -and $_.isEnabled }
        if (-not $r) { throw "Graph application permission '$rv' not found/enabled in this tenant." }
        $roleIds += $r.id
    }

    $flt = [uri]::EscapeDataString("displayName eq '$($script:AppName)'")
    $ex = Invoke-GraphPriv -Uri "$v1/applications?`$filter=$flt"
    if (@($ex.value).Count -gt 0) {
        $app = @($ex.value)[0]
        Write-Host "Reusing app registration '$($script:AppName)' (appId=$($app.appId))." -ForegroundColor DarkGray
        # Ensure all required permissions are declared on the app.
        Invoke-GraphPriv -Method PATCH -Uri "$v1/applications/$($app.id)" -Body @{
            requiredResourceAccess = @(@{ resourceAppId = $script:GraphAppId; resourceAccess = @($roleIds | ForEach-Object { @{ id = $_; type = 'Role' } }) })
        } | Out-Null
    }
    else {
        $app = Invoke-GraphPriv -Method POST -Uri "$v1/applications" -Body @{
            displayName            = $script:AppName
            signInAudience         = 'AzureADMyOrg'
            requiredResourceAccess = @(@{ resourceAppId = $script:GraphAppId; resourceAccess = @($roleIds | ForEach-Object { @{ id = $_; type = 'Role' } }) })
        }
        Write-Host "Created app registration '$($script:AppName)' (appId=$($app.appId))." -ForegroundColor Green
    }

    $spFlt = [uri]::EscapeDataString("appId eq '$($app.appId)'")
    $spEx = Invoke-GraphPriv -Uri "$v1/servicePrincipals?`$filter=$spFlt"
    if (@($spEx.value).Count -gt 0) {
        $sp = @($spEx.value)[0]
    }
    else {
        $sp = Invoke-GraphPriv -Method POST -Uri "$v1/servicePrincipals" -Body @{ appId = $app.appId }
        Start-Sleep -Milliseconds 1500
    }

    $assigned = Invoke-GraphPriv -Uri "$v1/servicePrincipals/$($sp.id)/appRoleAssignments"
    foreach ($rid in $roleIds) {
        if (@($assigned.value) | Where-Object { $_.appRoleId -eq $rid -and $_.resourceId -eq $graphSp.id }) {
            Write-Host "  admin consent already granted: $rid" -ForegroundColor DarkGray
            continue
        }
        Invoke-GraphPriv -Method POST -Uri "$v1/servicePrincipals/$($sp.id)/appRoleAssignedTo" -Body @{
            principalId = $sp.id; resourceId = $graphSp.id; appRoleId = $rid
        } | Out-Null
        Write-Host "  admin consent granted:        $rid" -ForegroundColor Green
    }

    $pw = Invoke-GraphPriv -Method POST -Uri "$v1/applications/$($app.id)/addPassword" -Body @{
        passwordCredential = @{ displayName = "purview-audit-explorer-$(Get-Date -Format yyyyMMddHHmmss)" }
    }

    $org = Invoke-GraphPriv -Uri "$v1/organization?`$select=id"
    $tenantId = @($org.value)[0].id
    $cred = [ordered]@{ tenantId = $tenantId; appId = $app.appId; clientSecret = $pw.secretText; spId = $sp.id }
    if (-not (Test-Path $script:CredDir)) { New-Item -ItemType Directory -Path $script:CredDir -Force | Out-Null }
    ($cred | ConvertTo-Json) | Set-Content -Path $script:CredPath -Encoding utf8

    # New app-role assignments take a few seconds to reflect in a fresh app-only token.
    for ($i = 0; $i -lt 10; $i++) {
        try { if (Get-AppOnlyToken -Cred ([pscustomobject]$cred)) { return [pscustomobject]$cred } } catch { }
        Start-Sleep -Seconds 4
    }
    throw "App and consent created, but an app-only token was not usable yet. Wait a minute and re-run a runtime script."
}

# ---------------------------------------------------------------------------------------------------
# Data helpers - RUNTIME (all use the app-only token)
# ---------------------------------------------------------------------------------------------------
function Resolve-UserId {
    param([Parameter(Mandatory)] [string] $Token, [Parameter(Mandatory)] [string] $Upn)
    Invoke-Graph -Token $Token -Uri "https://graph.microsoft.com/v1.0/users/$Upn`?`$select=id,displayName,userPrincipalName"
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
