#requires -Version 7.0
<#
.SYNOPSIS
  Creates (idempotent) a web UI instance: the Static Web App, the SPA app registration (redirect URIs, public-client
  loopback, base delegated permissions, tenant-wide admin consent) and the shell deploy with msal.clientId filled.
  The scripted form of docs/setup-web-ui.md sections 2, 3 and 6 for a LAB-OWNED UI (Lab Builder 'create' mode) or a
  STANDALONE one (Web UI Creator: -Standalone, no a365lab tag).

.DESCRIPTION
  Then add each agent's tab with Add-WebUiTab.ps1 (-TabId <scaffolded id> -WorkFolder <this folder> -SpaAppId <id>):
  it fills the endpoint, reveals the tab, grants the agent's own scopes to the SPA and wires CORS.
  Re-running is safe: an existing SWA / app / permission / grant is reused; the shell is redeployed only when the
  live site has no config.js yet (or with -Redeploy), so the tabs already live are never wiped.
  Names: SWA '<Name>' in RG '<Name>-rg', SPA app '<Name>-spa' (the Lab Builder convention for a lab is
  -Name <prefix>-ui: SWA <prefix>-ui, RG <prefix>-ui-rg, app <prefix>-ui-spa, which Set-LabTags.ps1 and the Lab
  Cleaner expect).

.PARAMETER Name          Base name (e.g. <prefix>-ui).
.PARAMETER Subscription  Target subscription id (pinned on every az call; the tenant is asserted).
.PARAMETER TenantId      Expected tenant id.
.PARAMETER UiFolder      Folder with the SPA files (index.html, app.js, config.js...): the scaffolded
                         generated/<prefix>/<prefix>-ui, or the repo ui/ for a standalone UI.
.PARAMETER Region        SWA Free region (eastus2 validated; also centralus, eastasia, westeurope, westus2).
.PARAMETER LabPrefix     Lab prefix for the a365lab tag (omit with -Standalone).
.PARAMETER Mail          Add the Agent 365 Tools McpServers.Mail.All delegated permission (OBO agents).
.PARAMETER Foundry       Add Azure Machine Learning Services user_impersonation (FH/FD agents).
.PARAMETER Standalone    Shared UI of the Web UI Creator: tag a365component=web-ui only (never a365lab).
.PARAMETER SpaAppName    SPA app display name (default <Name>-spa; the Web UI Creator names it <base>-spa for -Name <base>-ui).
.PARAMETER Redeploy      Redeploy the shell even when the site already serves a config.js.
.PARAMETER WhatIf        Show what would be created; change nothing.
.EXAMPLE
  pwsh -File .\New-WebUi.ps1 -Name contoso-ui -Subscription <sub> -TenantId <tid> -UiFolder generated\contoso\contoso-ui -LabPrefix contoso -Mail -Foundry
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Subscription,
    [string]$TenantId,
    [Parameter(Mandatory)][string]$UiFolder,
    [string]$Region = 'eastus2',
    [string]$LabPrefix,
    [switch]$Mail,
    [switch]$Foundry,
    [switch]$Standalone,
    [string]$SpaAppName,
    [switch]$Redeploy,
    [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot '_webui-cloud.ps1')
if (-not $Standalone -and -not $LabPrefix) { throw 'Pass -LabPrefix <prefix> (lab-owned UI) or -Standalone (shared UI).' }
if (-not (Test-Path -LiteralPath (Join-Path $UiFolder 'index.html'))) { throw "UiFolder '$UiFolder' has no index.html (scaffold the lab first, or use the repo ui/ folder)." }
$ctx = az account show --subscription $Subscription -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not signed in (or no access to subscription $Subscription). Run 'az login --tenant <id>' first." }
if ($TenantId -and $ctx.tenantId -ne $TenantId) { throw "az is on tenant '$($ctx.tenantId)', expected '$TenantId'." }
$TenantId = $ctx.tenantId
$rg = "$Name-rg"; $spaName = if ($SpaAppName) { $SpaAppName } else { "$Name-spa" }
$azTags = @('a365component=web-ui') + $(if ($Standalone) { @() } else { @("a365lab=$LabPrefix") })
$appTags = @('a365component:web-ui') + $(if ($Standalone) { @() } else { @("a365lab:$LabPrefix") })
$graph = '00000003-0000-0000-c000-000000000000'
$perms = [ordered]@{ $graph = @('37f7f235-527c-4136-accd-4a02d197296e', '14dad69e-099b-42c9-810b-d002981feec1', '7427e0e9-2fba-42fe-b0c0-848c9e6a8182') }   # openid profile offline_access
if ($Mail) { $perms['ea9ffc3e-8a23-4a7d-836d-234d7c7565c1'] = @('be685e8e-277f-43ec-aff6-087fdca57ca3') }                                    # McpServers.Mail.All
if ($Foundry) { $perms['18a66f5f-dbdf-4c17-9dd7-1634712a9cbe'] = @('1a7925b5-f871-417a-9b8b-303f9f29fa10') }                                # user_impersonation

# --- Static Web App ---------------------------------------------------------------------------------------------
$swa = az staticwebapp show -n $Name -g $rg --subscription $Subscription -o json 2>$null | ConvertFrom-Json
$appId = az ad app list --display-name $spaName --query '[0].appId' -o tsv 2>$null
if ($WhatIf) {
    Write-Host "WhatIf (tenant $TenantId):"
    Write-Host "  SWA $Name ($Region, Free) in ${rg}: $(if ($swa) { "exists ($($swa.defaultHostname))" } else { 'would CREATE' }); tags $($azTags -join ', ')"
    Write-Host "  SPA app $spaName : $(if ($appId) { "exists ($appId)" } else { 'would CREATE' }); permissions: Graph OIDC$(if ($Mail) { ', Mail' })$(if ($Foundry) { ', Foundry' }); admin consent"
    Write-Host "  shell deploy from $UiFolder$(if ($swa) { ' (only if the site has no config.js yet, or -Redeploy)' })"
    return
}
if (-not $swa) {
    if ((az group exists -n $rg --subscription $Subscription) -ne 'true') { az group create -n $rg -l $Region --subscription $Subscription --tags @azTags -o none }
    az staticwebapp create -n $Name -g $rg -l $Region --sku Free --tags @azTags --subscription $Subscription -o none
    if ($LASTEXITCODE -ne 0) { throw "az staticwebapp create $Name failed (SWA Free regions: eastus2, centralus, eastasia, westeurope, westus2)." }
    $swa = az staticwebapp show -n $Name -g $rg --subscription $Subscription -o json | ConvertFrom-Json
    Write-Host "SWA created: https://$($swa.defaultHostname)" -ForegroundColor Green
}
else {
    az tag update --resource-id $swa.id --operation Merge --tags @azTags --subscription $Subscription -o none 2>$null
    Write-Host "SWA reused: https://$($swa.defaultHostname)" -ForegroundColor DarkGray
}
$origin = "https://$($swa.defaultHostname)"

# --- SPA app registration (+ service principal), redirect URIs, tags ---------------------------------------------
if (-not $appId) {
    $appId = az ad app create --display-name $spaName --sign-in-audience AzureADMyOrg --is-fallback-public-client true --query appId -o tsv
    if (-not $appId) { throw "az ad app create $spaName failed." }
    Write-Host "SPA app created: $spaName ($appId)" -ForegroundColor Green
}
else { Write-Host "SPA app reused: $spaName ($appId)" -ForegroundColor DarkGray }
if (-not (az ad sp show --id $appId --query id -o tsv 2>$null)) { az ad sp create --id $appId -o none }
$objId = az ad app show --id $appId --query id -o tsv
$cur = az ad app show --id $appId --query '{spa:spa.redirectUris, tags:tags}' -o json | ConvertFrom-Json
$redirects = @(@($cur.spa) + @($origin, 'http://localhost:3000') | Where-Object { $_ } | Select-Object -Unique)
$tags = @(@($cur.tags) + $appTags | Where-Object { $_ } | Select-Object -Unique)
$tmp = New-TemporaryFile
@{ spa = @{ redirectUris = $redirects }; publicClient = @{ redirectUris = @('http://localhost') }; tags = $tags } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding utf8
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$objId" --headers 'Content-Type=application/json' --body "@$tmp" -o none
Remove-Item -LiteralPath $tmp -Force
$spId = az ad sp show --id $appId --query id -o tsv
$tmp = New-TemporaryFile
@{ tags = $tags } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $tmp -Encoding utf8
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spId" --headers 'Content-Type=application/json' --body "@$tmp" -o none 2>$null
Remove-Item -LiteralPath $tmp -Force

# --- Delegated permissions + tenant-wide admin consent -------------------------------------------------------------
foreach ($api in $perms.Keys) {
    if (-not (az ad sp show --id $api --query id -o tsv 2>$null)) { az ad sp create --id $api -o none 2>$null }
    $have = @(az ad app permission list --id $appId --query "[?resourceAppId=='$api'].resourceAccess[].id" -o tsv 2>$null)
    $add = @($perms[$api] | Where-Object { $have -notcontains $_ } | ForEach-Object { "$_=Scope" })
    if ($add.Count) { az ad app permission add --id $appId --api $api --api-permissions @add -o none 2>$null }
}
$consented = $false
for ($i = 0; $i -lt 4 -and -not $consented; $i++) {
    if ($i) { Start-Sleep -Seconds 15 }
    az ad app permission admin-consent --id $appId -o none 2>$null
    $consented = $LASTEXITCODE -eq 0
}
Write-Host "Delegated permissions $(if ($consented) { 'admin-consented' } else { 'NOT consented (run as a tenant admin: az ad app permission admin-consent --id ' + $appId + ')' })" -ForegroundColor $(if ($consented) { 'Green' } else { 'Yellow' })

# --- Shell: msal.clientId + authority in config.js, deploy (never over a live config.js unless -Redeploy) ------------
$cfgPath = Join-Path $UiFolder 'config.js'
if (-not (Test-Path -LiteralPath $cfgPath)) {
    $ex = Join-Path $UiFolder 'config.js.example'
    if (-not (Test-Path -LiteralPath $ex)) { throw "No config.js nor config.js.example in $UiFolder." }
    Copy-Item -LiteralPath $ex -Destination $cfgPath
}
$text = Get-Content -LiteralPath $cfgPath -Raw -Encoding utf8
$text = [regex]::Replace($text, '("clientId"\s*:\s*|clientId\s*:\s*)"[^"]*"', "`${1}`"$appId`"", 1)
$text = [regex]::Replace($text, '("authority"\s*:\s*|authority\s*:\s*)"[^"]*"', "`${1}`"https://login.microsoftonline.com/$TenantId`"", 1)
Set-Content -LiteralPath $cfgPath -Value $text -Encoding utf8 -NoNewline
node --check $cfgPath 2>$null
if ($LASTEXITCODE -ne 0) { throw "node --check failed on $cfgPath." }
$live = Get-DeployedConfigText -Origin $origin
if (-not $live -or $Redeploy) {
    Deploy-SwaContent -SwaName $Name -ResourceGroup $swa.resourceGroup -AppFolder $UiFolder -Subscription $Subscription
    Write-Host "Shell deployed (tabs stay hidden until each agent is wired with Add-WebUiTab.ps1)." -ForegroundColor Green
}
else { Write-Host 'The site already serves a config.js: shell not redeployed (use Add-WebUiTab.ps1 for tabs, or -Redeploy).' -ForegroundColor DarkGray }

Write-Host ''
Write-Host 'Web UI ready:' -ForegroundColor Cyan
Write-Host "  $origin"
Write-Host "  SPA app id: $appId"
[pscustomobject]@{ name = $Name; resourceGroup = $swa.resourceGroup; origin = $origin; spaAppId = $appId; consented = $consented }
