#requires -Version 7.0
<#
.SYNOPSIS
  Fills clientAppId of an agent's a365.config.json with the tenant's "Agent 365 CLI" public client app id.
.DESCRIPTION
  The scaffolder writes the placeholder <YOUR_AGENT365_CLI_PUBLIC_CLIENT_APP_ID>. 'a365 ... --agent-name' resolves it by
  itself, but in custom naming (namingMode custom) the a365 commands run WITHOUT --agent-name and read the file as is.
  Resolution: -ClientAppId when given, else the single app registration named "Agent 365 CLI" in the tenant of the
  current az profile (read-only Graph call through az; honours AZURE_CONFIG_DIR). A value that is already set is kept.
.EXAMPLE
  pwsh -File .\Set-A365ClientAppId.ps1 -ConfigPath .\a365.config.json -TenantId <tenant-guid>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$TenantId,
    [string]$ClientAppId,
    [string]$DisplayName = 'Agent 365 CLI'
)
$ErrorActionPreference = 'Stop'
$placeholder = '<YOUR_AGENT365_CLI_PUBLIC_CLIENT_APP_ID>'
$guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
if (-not (Test-Path -LiteralPath $ConfigPath)) { Write-Error "Not found: $ConfigPath"; exit 1 }
$cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
$current = [string]$cfg['clientAppId']
if ($current -match $guid -and -not $ClientAppId) { Write-Host "clientAppId already set ($current)."; exit 0 }

if (-not $ClientAppId) {
    $acct = az account show --query '{t:tenantId}' -o json 2>$null | ConvertFrom-Json
    if (-not $acct) { Write-Error "az is not signed in (AZURE_CONFIG_DIR=$env:AZURE_CONFIG_DIR). Sign in interactively to the lab tenant first."; exit 1 }
    $tid = if ($TenantId) { $TenantId } elseif ($cfg['tenantId']) { [string]$cfg['tenantId'] } else { $acct.t }
    if ($acct.t -ne $tid) { Write-Error "The az profile is signed in to tenant $($acct.t), not $tid (AZURE_CONFIG_DIR=$env:AZURE_CONFIG_DIR)."; exit 1 }
    $ids = @(az ad app list --display-name $DisplayName --query '[].appId' -o tsv 2>$null | Where-Object { $_ -match $guid })
    if ($ids.Count -ne 1) {
        Write-Error ("Found $($ids.Count) app registrations named '$DisplayName' in tenant ${tid}: pass -ClientAppId <appId>. " +
            "To create it see docs/setup-MAF-ACA-OBO.md (tenant-owned 'Agent 365 CLI' public client).")
        exit 1
    }
    $ClientAppId = $ids[0]
}
if ($ClientAppId -notmatch $guid) { Write-Error "Not an app id: $ClientAppId"; exit 1 }
$cfg['clientAppId'] = $ClientAppId
$cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ConfigPath -Encoding utf8
Write-Host "clientAppId set to $ClientAppId in $ConfigPath$(if ($current -and $current -ne $placeholder) { " (was $current)" })."
