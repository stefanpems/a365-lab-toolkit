<#
.SYNOPSIS
  Create the Microsoft Entra client app that lets a Copilot Studio (MCS) agent call Agent 365 Tooling
  Gateway (ATG) MCP servers — Mail and, experimentally, the custom BYO servers.
.DESCRIPTION
  Official pattern ("Connect an MCP server through Agent 365 Tooling Gateway" in Copilot Studio): a
  single-tenant confidential Entra app with a delegated permission on the ATG resource app
  (ea9ffc3e-8a23-4a7d-836d-234d7c7565c1) + admin consent. In Copilot Studio you then add a
  Model Context Protocol tool with OAuth 2.0 (Manual), scope '<ATG appId>/.default', using this app's
  client id + secret; paste the wizard's callback URL back as a Web redirect URI on this app.

  This script automates the Entra side (app + permissions + admin consent) with the az CLI and prints
  the NON-secret OAuth values to paste into the Copilot Studio MCP wizard. The client SECRET is written
  ONLY to a gitignored local file (never printed), so it is never exposed in an agent transcript.

  Requires: az CLI logged in to the TARGET tenant (az login --tenant <target>), with rights to create
  app registrations and grant admin consent.
.PARAMETER Tools     Which ATG MCP servers to authorize: any of Mail, Anon, Auth (default: Mail).
.PARAMETER AppName   Display name of the Entra app. Default 'MCS MCP Client (ATG)'.
.PARAMETER Tenant    Target tenant id (for the printed authorize/token URLs and an az context check).
.PARAMETER McpPrefix For Anon/Auth: the custom-MCP solution prefix, i.e. the ext_<prefix>Anon/Auth servers.
.PARAMETER OutDir    Where to write the gitignored secret file. Default: generated/copilot-studio.
.NOTES
  Mail is the confirmed, tested path (scope McpServers.Mail.All). Anon/Auth (custom BYO ext_ servers) are
  EXPERIMENTAL from Copilot Studio: they also require the ext_ server to be admin-approved and a one-time
  Power Platform connection owned by the signing-in user — see references/mcp-integration-feasibility.md.
#>
[CmdletBinding()]
param(
    [ValidateSet('Mail', 'Anon', 'Auth')][string[]]$Tools = @('Mail'),
    [string]$AppName = 'MCS MCP Client (ATG)',
    [string]$Tenant,
    [string]$McpPrefix,
    [string]$OutDir
)
$ErrorActionPreference = 'Stop'

$ATG_APP_ID = 'ea9ffc3e-8a23-4a7d-836d-234d7c7565c1'   # Agent 365 Tooling Gateway (first-party)
# Delegated scope per selected tool. Mail is confirmed; custom BYO servers reuse the ATG /.default scope
# but ALSO need the ext_ server approved + a Power Platform connection (see the feasibility reference).
$SCOPE_BY_TOOL = @{ Mail = 'McpServers.Mail.All'; Anon = 'McpServers.Metadata.Read.All'; Auth = 'McpServers.Metadata.Read.All' }

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw "az CLI is required. Install it and 'az login --tenant <target>' first." }
if (-not $OutDir) { $OutDir = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path 'generated\copilot-studio' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$ctxTenant = az account show --query tenantId -o tsv 2>$null
if ($Tenant -and $ctxTenant -and ($ctxTenant -ne $Tenant)) {
    throw "az is logged into tenant $ctxTenant but the target is $Tenant. Run 'az login --tenant $Tenant' first (the MCP client app must live in the Copilot Studio env's tenant)."
}
if (-not $Tenant) { $Tenant = $ctxTenant }

# 1) Create (or reuse) the single-tenant app registration.
$appId = az ad app list --display-name $AppName --query "[0].appId" -o tsv 2>$null
if (-not $appId) {
    Write-Host "  Creating Entra app '$AppName' ..." -ForegroundColor Cyan
    $appId = az ad app create --display-name $AppName --sign-in-audience AzureADMyOrg --query appId -o tsv
}
else { Write-Host "  Reusing existing Entra app '$AppName' ($appId)." -ForegroundColor DarkGray }

# 2) Resolve the ATG service principal and the requested delegated scope ids.
$atgSp = az ad sp show --id $ATG_APP_ID 2>$null | ConvertFrom-Json
if (-not $atgSp) { throw "Agent 365 Tooling Gateway SP ($ATG_APP_ID) not found in tenant $Tenant. Ensure Agent 365 is provisioned in this tenant." }
$wanted = $Tools | ForEach-Object { $SCOPE_BY_TOOL[$_] } | Select-Object -Unique
foreach ($scopeName in $wanted) {
    $scope = $atgSp.oauth2PermissionScopes | Where-Object { $_.value -eq $scopeName } | Select-Object -First 1
    if (-not $scope) { Write-Host "  WARN: ATG does not expose delegated scope '$scopeName' in this tenant; skipping." -ForegroundColor Yellow; continue }
    Write-Host "  Adding delegated permission $scopeName ..." -ForegroundColor Cyan
    az ad app permission add --id $appId --api $ATG_APP_ID --api-permissions "$($scope.id)=Scope" 2>$null | Out-Null
}

# 3) Admin consent for the tenant.
Write-Host "  Granting admin consent (a browser window may open) ..." -ForegroundColor Cyan
az ad app permission admin-consent --id $appId 2>$null

# 4) Create a client secret -> write to a GITIGNORED file only (never printed).
$secretFile = Join-Path $OutDir ("mcp-client-" + ($AppName -replace '[^A-Za-z0-9]', '') + ".secret.txt")
Write-Host "  Creating client secret (written to a local gitignored file, NOT printed) ..." -ForegroundColor Cyan
$secret = az ad app credential reset --id $appId --display-name "cs-mcp" --query password -o tsv
Set-Content -LiteralPath $secretFile -Value $secret -NoNewline -Encoding UTF8
Remove-Variable secret

# 5) Print the NON-secret OAuth values for the Copilot Studio MCP wizard.
$serverUrls = @()
foreach ($t in $Tools) {
    switch ($t) {
        'Mail' { $serverUrls += "Mail : https://agent365.svc.cloud.microsoft/agents/servers/mcp_MailTools" }
        'Anon' { if ($McpPrefix) { $serverUrls += "Anon : https://agent365.svc.cloud.microsoft/agents/servers/ext_${McpPrefix}Anon" } }
        'Auth' { if ($McpPrefix) { $serverUrls += "Auth : https://agent365.svc.cloud.microsoft/agents/servers/ext_${McpPrefix}Auth" } }
    }
}
Write-Host ""
Write-Host "=== Copilot Studio MCP wizard values (Tools -> Add a tool -> Model Context Protocol -> OAuth 2.0 Manual) ===" -ForegroundColor Green
Write-Host "  Client ID          : $appId"
Write-Host "  Client secret      : (open the gitignored file) $secretFile"
Write-Host "  Authorization URL  : https://login.microsoftonline.com/$Tenant/oauth2/v2.0/authorize"
Write-Host "  Token URL template : https://login.microsoftonline.com/$Tenant/oauth2/v2.0/token"
Write-Host "  Refresh URL        : https://login.microsoftonline.com/$Tenant/oauth2/v2.0/token"
Write-Host "  Scope              : $ATG_APP_ID/.default"
Write-Host "  Server URL(s)      :"
$serverUrls | ForEach-Object { Write-Host "     $_" }
Write-Host ""
Write-Host "  After 'Create', copy the wizard's callback URL and add it as a Web redirect URI on app ${appId}:" -ForegroundColor Yellow
Write-Host "     az ad app update --id $appId --web-redirect-uris <CALLBACK_URL>"
Write-Host "  Mail is the tested path. Anon/Auth also need the ext_ server admin-approved + a one-time Power" -ForegroundColor DarkGray
Write-Host "  Platform connection owned by the signing-in user — see references/mcp-integration-feasibility.md." -ForegroundColor DarkGray

[ordered]@{ appId = $appId; tenant = $Tenant; scope = "$ATG_APP_ID/.default"; secretFile = $secretFile; tools = $Tools }
