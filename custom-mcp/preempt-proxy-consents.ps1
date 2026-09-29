#requires -Version 5.1
<#
.SYNOPSIS
  Pre-empt the admin-center "Approve" consent for a registered sample custom MCP server pair by
  creating the missing proxy service principals and the AllPrincipals oauth2PermissionGrants that the
  approval expects. Run AFTER `a365 develop-mcp register-external-mcp-server` and BEFORE the tenant
  admin clicks Approve, so the approval succeeds on the first try (otherwise it fails with
  "Couldn't complete consent for one or more apps backing this MCP server").

.DESCRIPTION
  Registration creates the backing Entra apps (A365Proxy / RemoteProxy / PublicClients / BYO) but does
  NOT create service principals for the proxy apps, and does NOT pre-create the delegated grants — so
  the portal cannot record consent. This script:
    1. Discovers the ext_<Name>Anon* / ext_<Name>Auth* apps by display name.
    2. Creates a service principal for every proxy app that lacks one (az ad sp create).
    3. Creates the AllPrincipals grants (idempotent) via a Graph token + Invoke-RestMethod:
         anon: A365Proxy + PublicClients -> BYO           scope Tools.ListInvoke.All
               BYO                       -> Agent 365 Tools scope PlatformRuntime.Internal.All
         auth: A365Proxy + PublicClients -> BYO           scope Tools.ListInvoke.All
               RemoteProxy               -> Resource       scope access_as_agent
               BYO                       -> Agent 365 Tools scope PlatformRuntime.Internal.All

  Why Invoke-RestMethod (not `az rest --body @file`): on Windows `az rest --body @file` can mangle the
  JSON (Graph sees resourceId as a single character). A Graph bearer token + native Invoke-RestMethod
  is reliable. Existence checks use /servicePrincipals/{id}/oauth2PermissionGrants (a combined
  $filter on clientId + resourceId is rejected by Graph as "Filter is invalid").

.PARAMETER Name
  The MCP base name (the solution prefix), e.g. 'contoso' -> ext_contosoAnon / ext_contosoAuth.
.PARAMETER Server
  Instead of -Name: one or more full ext_ server names registered with authType NoAuth (e.g. the Demo
  Builder servers), comma-separated or as an array. Apps are matched EXACTLY: '<server>-A365Proxy',
  '<server>-PublicClients', '<server> - BYO'; the grants are the anonymous topology below.
.PARAMETER PassThru
  With -Server: also return one object per server (server, byoAudience, proxyAppId, publicClientsAppId);
  byoAudience is the delegated-token audience an OBO web UI tab needs (plan byoMcpAudiences).
.PARAMETER Subscription
  Target subscription id (pins the az context; az ad ignores --subscription but the context matters).
.EXAMPLE
  .\preempt-proxy-consents.ps1 -Name contoso -Subscription <SUB_ID>
.EXAMPLE
  .\preempt-proxy-consents.ps1 -Server ext_RecordsTest,ext_CompaniesTest -Subscription <SUB_ID> -PassThru
#>
[CmdletBinding()]
param(
    [string]$Name,
    [Parameter(Mandatory = $true)] [string]$Subscription,
    [string[]]$Server,
    [switch]$PassThru
)
$ErrorActionPreference = 'Stop'
$Server = @($Server | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $Name -and -not $Server.Count) { throw 'Pass -Name <base> (sample pair) or -Server <ext_ server name(s)> (NoAuth topology).' }
$AGENT_TOOLS_APPID = 'ea9ffc3e-8a23-4a7d-836d-234d7c7565c1'   # Agent 365 Tools (first-party)

az account set --subscription $Subscription | Out-Null

# --- Discover the backing apps by display name ---
$all = az ad app list --all --query "[].{name:displayName,appId:appId}" -o json | ConvertFrom-Json
$mine = if ($Server.Count) { $all | Where-Object { $n = $_.name; @($Server | Where-Object { $n -like "$_*" }).Count -gt 0 } } else { $all | Where-Object { $_.name -like "ext_$Name*" } }
if (-not $mine) { Write-Error "No backing apps found for $(if ($Server.Count) { $Server -join ', ' } else { "ext_$Name*" }). Register the servers first."; exit 1 }

function Find-App([string]$anonOrAuth, [string]$suffixLike) {
    ($mine | Where-Object { $_.name -like "ext_$Name$anonOrAuth*" -and $_.name -like "*$suffixLike" } | Select-Object -First 1)
}

# Resolve (or create) an SP object id for an app id.
function Get-SpId([string]$appId) {
    if (-not $appId) { return $null }
    $sp = az ad sp show --id $appId --query id -o tsv 2>$null
    if (-not $sp) {
        az ad sp create --id $appId 2>&1 | Out-Null
        $sp = az ad sp show --id $appId --query id -o tsv 2>$null
    }
    return $sp
}

$token = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv
$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }

function New-Grant([string]$clientSp, [string]$resourceSp, [string]$scope, [string]$label) {
    if (-not $clientSp -or -not $resourceSp) { Write-Host "SKIP (missing SP): $label"; return }
    $existing = Invoke-RestMethod -Method GET -Headers $headers `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$clientSp/oauth2PermissionGrants"
    if ($existing.value | Where-Object { $_.resourceId -eq $resourceSp -and $_.scope -match [regex]::Escape($scope) }) {
        Write-Host "SKIP (exists): $label ($scope)"; return
    }
    $body = @{ clientId = $clientSp; consentType = 'AllPrincipals'; resourceId = $resourceSp; scope = $scope } | ConvertTo-Json
    try {
        $r = Invoke-RestMethod -Method POST -Headers $headers -Body $body `
            -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants"
        Write-Host "CREATED: $label ($scope) -> $($r.id)" -ForegroundColor Green
    } catch {
        Write-Host "FAILED: $label -> $($_.Exception.Message)" -ForegroundColor Red
    }
}

# --- Explicit servers (-Server): anonymous topology per server, exact app names ---
if ($Server.Count) {
    $spAgentTools = Get-SpId $AGENT_TOOLS_APPID
    $result = @()
    foreach ($srv in $Server) {
        $proxy  = $mine | Where-Object { $_.name -eq "$srv-A365Proxy" } | Select-Object -First 1
        $public = $mine | Where-Object { $_.name -eq "$srv-PublicClients" } | Select-Object -First 1
        $byo    = $mine | Where-Object { $_.name -eq "$srv - BYO" } | Select-Object -First 1
        if (-not ($proxy -and $public -and $byo)) { Write-Host "SKIP ${srv}: backing apps not all found (-A365Proxy / -PublicClients / ' - BYO'). Registered?" -ForegroundColor Yellow; continue }
        $spProxy = Get-SpId $proxy.appId; $spPublic = Get-SpId $public.appId; $spByo = Get-SpId $byo.appId
        New-Grant $spProxy  $spByo        'Tools.ListInvoke.All'         "$srv A365Proxy->BYO"
        New-Grant $spPublic $spByo        'Tools.ListInvoke.All'         "$srv PublicClients->BYO"
        New-Grant $spByo    $spAgentTools 'PlatformRuntime.Internal.All' "$srv BYO->AgentTools"
        $result += [pscustomobject]@{ server = $srv; byoAudience = $byo.appId; proxyAppId = $proxy.appId; publicClientsAppId = $public.appId }
    }
    Write-Host "DONE. The tenant admin can now Approve $($Server -join ' / ') (watch for a BLOCKED popup)." -ForegroundColor Cyan
    if ($PassThru) { return $result }
    return
}

# --- Anonymous topology ---
$anonProxy  = Find-App 'Anon' '-A365Proxy'
$anonPublic = Find-App 'Anon' '-PublicClients'
$anonByo    = Find-App 'Anon' 'BYO'
# --- Authenticated topology ---
$authProxy  = Find-App 'Auth' '-A365Proxy'
$authRemote = Find-App 'Auth' '-RemoteProxy'
$authPublic = Find-App 'Auth' '-PublicClients'
$authByo    = Find-App 'Auth' 'BYO'
$authRes    = Find-App 'Auth' '-Resource'

# --- Ensure SPs (proxies + shared resources) ---
$spAnonProxy  = Get-SpId $anonProxy.appId
$spAnonPublic = Get-SpId $anonPublic.appId
$spAnonByo    = Get-SpId $anonByo.appId
$spAuthProxy  = Get-SpId $authProxy.appId
$spAuthRemote = Get-SpId $authRemote.appId
$spAuthPublic = Get-SpId $authPublic.appId
$spAuthByo    = Get-SpId $authByo.appId
$spAuthRes    = Get-SpId $authRes.appId
$spAgentTools = Get-SpId $AGENT_TOOLS_APPID

# --- Grants ---
if ($anonByo) {
    New-Grant $spAnonProxy  $spAnonByo    'Tools.ListInvoke.All'         'AnonA365Proxy->AnonBYO'
    New-Grant $spAnonPublic $spAnonByo    'Tools.ListInvoke.All'         'AnonPublicClients->AnonBYO'
    New-Grant $spAnonByo    $spAgentTools 'PlatformRuntime.Internal.All' 'AnonBYO->AgentTools'
}
if ($authByo) {
    New-Grant $spAuthProxy  $spAuthByo    'Tools.ListInvoke.All'         'AuthA365Proxy->AuthBYO'
    New-Grant $spAuthPublic $spAuthByo    'Tools.ListInvoke.All'         'AuthPublicClients->AuthBYO'
    New-Grant $spAuthByo    $spAgentTools 'PlatformRuntime.Internal.All' 'AuthBYO->AgentTools'
    if ($spAuthRes) { New-Grant $spAuthRemote $spAuthRes 'access_as_agent' 'AuthRemoteProxy->Resource' }
    else { Write-Host "NOTE: ext_${Name}Auth-Resource not found; skipping RemoteProxy->Resource grant (create the resource app first for EntraOAuth)." -ForegroundColor Yellow }
}
Write-Host "DONE. The tenant admin can now Approve ext_${Name}Anon / ext_${Name}Auth (watch for a BLOCKED popup)." -ForegroundColor Cyan
