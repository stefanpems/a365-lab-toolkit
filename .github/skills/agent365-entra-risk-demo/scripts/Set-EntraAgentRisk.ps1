#requires -Version 7.0
<#
.SYNOPSIS
  Inspect or change Microsoft Entra Agent ID risk (Microsoft Graph beta riskyAgents) in one run.
.DESCRIPTION
  Signs in through get_graph_token.py (MSAL: system browser by default or device code; never WAM),
  asserts the tenant and the delegated scope, resolves the targets, applies the action to all the
  agents in one request, and prints the read-after-write state. Tokens stay in memory and are never
  printed; the MSAL cache makes later runs silent. The script never prompts: the request is the
  confirmation (-WhatIf gives a dry run without signing in).
.EXAMPLE
  .\Set-EntraAgentRisk.ps1 -TenantId '<tenant-id>' -AgentId '<agent-object-id>' -Action SetHigh
.EXAMPLE
  pwsh -File .\Set-EntraAgentRisk.ps1 -TenantId '<tenant-id>' -AgentId '<id-1>,<id-2>' -Action Dismiss -AuthMethod DeviceCode
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # Agent directory object IDs; comma- or space-separated values are accepted (pwsh -File).
    [Parameter(Mandatory)]
    [string[]]$AgentId,

    [Parameter(Mandatory)]
    [ValidateSet('Get', 'SetHigh', 'Dismiss', 'ConfirmSafe')]
    [string]$Action,

    [Parameter(Mandatory)]
    [ValidateScript({ [guid]::TryParse($_, [ref][guid]::Empty) })]
    [string]$TenantId,

    [ValidateSet('Browser', 'DeviceCode')]
    [string]$AuthMethod = 'Browser',

    [string]$LoginHint,

    # DPAPI-encrypted on Windows; a path ending in .json is kept as plain MSAL JSON (existing lab caches).
    [string]$CachePath = [IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'), 'agent365-lab', 'msal-graph-cache.bin'),

    [ValidateRange(0, 900)]
    [int]$WaitSeconds = 60,

    [switch]$InstallDependencies,

    # Accepted for compatibility with older invocations; the script never prompts.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$scope = 'IdentityRiskyAgent.ReadWrite.All'
$graph = 'https://graph.microsoft.com/beta'
$riskUri = "$graph/identityProtection/riskyAgents"
$actions = @{
    SetHigh     = @{ Endpoint = 'confirmCompromised'; State = 'confirmedCompromised' }
    Dismiss     = @{ Endpoint = 'dismiss'; State = 'dismissed' }
    ConfirmSafe = @{ Endpoint = 'confirmSafe'; State = 'confirmedSafe' }
}

$AgentId = @($AgentId -split '[,;\s]+' | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
$invalid = @($AgentId | Where-Object { -not [guid]::TryParse($_, [ref][guid]::Empty) })
if ($AgentId.Count -eq 0 -or $invalid.Count -gt 0) { throw "AgentId must contain directory object IDs (GUIDs). Invalid: $($invalid -join ', ')" }
$TenantId = $TenantId.ToLowerInvariant()

$mutation = $actions[$Action]
if ($mutation -and -not $PSCmdlet.ShouldProcess("$($AgentId -join ', ') in tenant $TenantId", "riskyAgents/$($mutation.Endpoint)")) { return }

$python = foreach ($name in 'python', 'python3', 'py') {
    $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { $command.Source; break }
}
if (-not $python) { throw 'Python 3 is required on PATH (with the msal package).' }
& $python -c 'import msal' 2>$null
if ($LASTEXITCODE -ne 0) {
    if (-not $InstallDependencies) { throw "The Python package 'msal' is missing: rerun with -InstallDependencies." }
    & $python -m pip install --user --quiet msal
    if ($LASTEXITCODE -ne 0) { throw "pip could not install 'msal'." }
}

$helperArgs = @((Join-Path $PSScriptRoot 'get_graph_token.py'), '--tenant', $TenantId, '--scopes', $scope, '--cache', $CachePath, '--auth', $AuthMethod.ToLowerInvariant())
if ($LoginHint) { $helperArgs += @('--login-hint', $LoginHint) }
$helperOutput = & $python @helperArgs
if ($LASTEXITCODE -ne 0 -or -not $helperOutput) { throw 'Microsoft Graph sign-in failed (see the message above).' }
try { $session = $helperOutput | Select-Object -Last 1 | ConvertFrom-Json }
catch { throw 'The token helper returned an unexpected response.' }
finally { Remove-Variable helperOutput }

if ($session.tenant_id -ne $TenantId) { throw "Signed-in tenant '$($session.tenant_id)' does not match '$TenantId': sign in with an account of the target tenant (-LoginHint)." }
if ((-split $session.scopes) -notcontains $scope) { throw "The token lacks the delegated scope '$scope': sign in as a Security Administrator and accept the consent." }
$token = ConvertTo-SecureString $session.access_token -AsPlainText -Force
$session.access_token = $null
Write-Host "Signed in as $($session.account) | tenant $TenantId" -ForegroundColor Cyan

function Invoke-Graph([string]$Method, [string]$Uri, [hashtable]$Body) {
    $request = @{ Method = $Method; Uri = $Uri; Authentication = 'Bearer'; Token = $token }
    if ($Body) { $request.Body = $Body | ConvertTo-Json -Compress; $request.ContentType = 'application/json' }
    Invoke-RestMethod @request
}

function Get-StatusCode($ErrorRecord) { [int]$ErrorRecord.Exception.Response.StatusCode }

function Get-AgentRisk([string]$Id) {
    try { Invoke-Graph GET "$riskUri/$Id" }
    catch { if ((Get-StatusCode $_) -eq 404) { return $null }; throw }
}

$names = @{}
foreach ($id in $AgentId) {
    try {
        $object = Invoke-Graph GET "$graph/directoryObjects/$id"
        $names[$id] = $object.displayName
        Write-Host "Target $id : $($object.'@odata.type' -replace '^#microsoft\.graph\.') '$($object.displayName)'"
    }
    catch {
        $status = Get-StatusCode $_
        if ($status -eq 404) { throw "Object $id was not found in tenant $TenantId (an application/client ID is not valid here)." }
        if ($status -ne 403) { throw }
        Write-Host "Target $id : not verified (no directory read permission)."
    }
}

if ($mutation) {
    Invoke-Graph POST "$riskUri/$($mutation.Endpoint)" @{ agentIds = $AgentId } | Out-Null
    Write-Host "$($mutation.Endpoint) accepted for $($AgentId.Count) agent(s)." -ForegroundColor Green
    if ($Action -eq 'SetHigh') {
        Write-Host 'Conditional Access policies that block high-risk agents now stop new token issuance for these agents (reset with -Action Dismiss).' -ForegroundColor Yellow
    }
}

$deadline = [datetime]::UtcNow.AddSeconds($(if ($mutation) { $WaitSeconds } else { 0 }))
foreach ($id in $AgentId) {
    do {
        $record = Get-AgentRisk $id
        $applied = $mutation -and $record -and $record.riskState -eq $mutation.State
        if (-not $mutation -or $applied -or [datetime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Seconds 5
    } while ($true)
    [pscustomobject]@{
        AgentId     = $id
        DisplayName = $record.agentDisplayName ?? $names[$id]
        RiskLevel   = $record ? $record.riskLevel : 'none'
        RiskState   = $record ? $record.riskState : 'none'
        RiskDetail  = $record.riskDetail
        Result      = if (-not $mutation) { $record ? 'current state' : 'no riskyAgents record (no active risk)' }
                      elseif ($applied) { 'applied' }
                      else { 'accepted, not visible yet: propagation can take minutes (rerun with -Action Get)' }
    }
}