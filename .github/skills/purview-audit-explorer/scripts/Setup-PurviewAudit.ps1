#Requires -Version 7
<#
.SYNOPSIS
  ONE-TIME setup for the Purview Audit Explorer (privileged, interactive admin). Creates/reuses a
  dedicated READ-ONLY app registration and grants admin consent, then caches its credential outside the
  repo. Idempotent: safe to re-run (reuses the app, refreshes the cached secret).

  Why an app registration is required: the transcript endpoint getAllEnterpriseInteractions is not
  supported in a delegated context (verified: HTTP 412), so an app-only (application-permission) token
  is mandatory. After this one-time setup, all read operations run app-only with no further sign-in.

  Requires an administrator who can create an app registration and grant admin consent
  (e.g. Global Administrator, or Application Administrator + Privileged Role Administrator).

.PARAMETER Method
  How to obtain the privileged token:
    GraphPowerShell (default) - Connect-MgGraph interactive sign-in (cross-platform, no Azure CLI).
    Az                        - reuse an existing `az login` admin session (Windows/az users).

.EXAMPLE
  pwsh -File Setup-PurviewAudit.ps1
.EXAMPLE
  pwsh -File Setup-PurviewAudit.ps1 -Method Az
#>
[CmdletBinding()]
param(
    [ValidateSet('GraphPowerShell', 'Az')] [string] $Method = 'GraphPowerShell',
    [string] $TenantId
)
. "$PSScriptRoot/_common.ps1"

Write-Host "Purview Audit Explorer - one-time setup (read-only app registration)`n" -ForegroundColor Cyan

if ($Method -eq 'Az') {
    Write-Host "Using the existing Azure CLI session for the privileged setup call." -ForegroundColor DarkGray
    Set-PrivilegedAuth -Mode Az -Token (Get-AzGraphToken)
}
else {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $connect = @{ Scopes = @('Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All'); NoWelcome = $true }
    if ($TenantId) { $connect.TenantId = $TenantId }
    Write-Host "Signing in with Microsoft Graph PowerShell (a browser window may open, possibly behind other windows)..." -ForegroundColor DarkGray
    Connect-MgGraph @connect -ErrorAction Stop
    $ctx = Get-MgContext
    Write-Host "Signed in as $($ctx.Account)." -ForegroundColor DarkGray
    Set-PrivilegedAuth -Mode Mg
}

$cred = Register-PurviewApp

Write-Host "`nSetup complete." -ForegroundColor Green
Write-Host "  App:      $($script:AppName)  (appId $($cred.appId))"
Write-Host "  Cred:     $($script:CredPath)  (outside the repo; never commit it)"
Write-Host "  Scopes:   $($script:WantRoles -join ', ')  [all read-only, admin-consented]"
Write-Host "`nYou can now run the read-only tools without signing in again, e.g.:" -ForegroundColor Cyan
Write-Host "  pwsh -File `"$PSScriptRoot/Find-InteractionUsers.ps1`" -SinceDays 7"
Write-Host "  pwsh -File `"$PSScriptRoot/List-AgentConversations.ps1`" -UserUpn <upn> -SinceHours 168"
