#requires -Version 7.0
<#
.SYNOPSIS
  Inspect or change Microsoft Entra Agent ID risk for controlled demonstrations.
.DESCRIPTION
  Calls the Microsoft Graph beta riskyAgents API. Mutating actions require confirmation unless
  -Force is supplied. The script never handles or persists credentials or access tokens.
.EXAMPLE
  .\Set-EntraAgentRisk.ps1 -AgentId '00000000-0000-0000-0000-000000000000' -Action Get
.EXAMPLE
  .\Set-EntraAgentRisk.ps1 -AgentId '00000000-0000-0000-0000-000000000000' -Action SetHigh -Force
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateScript({
        $parsed = [guid]::Empty
        if (-not [guid]::TryParse($_, [ref]$parsed)) {
            throw 'AgentId must be a directory object ID in GUID format.'
        }
        $true
    })]
    [string]$AgentId,

    [Parameter(Mandatory)]
    [ValidateSet('Get', 'SetHigh', 'Dismiss', 'ConfirmSafe')]
    [string]$Action,

    [string]$TenantId,

    [switch]$InstallDependencies,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$requiredScope = 'IdentityRiskyAgent.ReadWrite.All'
$graphModule = 'Microsoft.Graph.Authentication'
$baseUri = 'https://graph.microsoft.com/beta/identityProtection/riskyAgents'

function Import-GraphAuthentication {
    if (-not (Get-Module -ListAvailable -Name $graphModule)) {
        if (-not $InstallDependencies) {
            throw "Module '$graphModule' is required. Rerun with -InstallDependencies or install it for the current user."
        }

        Write-Host "Installing $graphModule for the current user..." -ForegroundColor Cyan
        Install-Module -Name $graphModule -Scope CurrentUser -Repository PSGallery -Force
    }

    Import-Module $graphModule -ErrorAction Stop
}

function Connect-AgentRiskGraph {
    $context = Get-MgContext
    $hasScope = $context -and ($context.Scopes -contains $requiredScope)
    $matchesTenant = -not $TenantId -or ($context -and $context.TenantId -eq $TenantId)

    if (-not $context -or -not $hasScope -or -not $matchesTenant) {
        $connectParams = @{
            Scopes    = @($requiredScope)
            NoWelcome = $true
        }
        if ($TenantId) {
            $connectParams.TenantId = $TenantId
        }

        Connect-MgGraph @connectParams | Out-Null
        $context = Get-MgContext
    }

    if (-not $context -or -not ($context.Scopes -contains $requiredScope)) {
        throw "The Graph session does not include delegated scope '$requiredScope'."
    }

    if ($TenantId -and $context.TenantId -ne $TenantId) {
        throw "Connected tenant '$($context.TenantId)' does not match requested tenant '$TenantId'."
    }

    $context
}

function Get-AgentRisk {
    param([Parameter(Mandatory)][string]$ObjectId)

    try {
        Invoke-MgGraphRequest -Method GET -Uri "$baseUri/$ObjectId" -OutputType PSObject
    }
    catch {
        $statusCode = $_.Exception.ResponseStatusCode
        if ($statusCode -eq 404 -or $statusCode -eq 'NotFound') {
            return [pscustomobject]@{
                id           = $ObjectId
                riskLevel    = 'none'
                riskState    = 'none'
                riskDetail   = $null
                recordExists = $false
            }
        }
        throw
    }
}

Import-GraphAuthentication
$context = Connect-AgentRiskGraph

Write-Host "Connected tenant: $($context.TenantId)" -ForegroundColor Cyan
Write-Host "Agent object ID: $AgentId" -ForegroundColor Cyan

if ($Action -eq 'Get') {
    Get-AgentRisk -ObjectId $AgentId |
        Select-Object id, agentDisplayName, identityType, riskLevel, riskState, riskDetail,
            isEnabled, isProcessing, recordExists
    return
}

$actionDetails = @{
    SetHigh = @{
        Endpoint   = 'confirmCompromised'
        Description = 'set risk to high and mark the agent confirmed compromised'
    }
    Dismiss = @{
        Endpoint   = 'dismiss'
        Description = 'set risk to none and dismiss the current risk'
    }
    ConfirmSafe = @{
        Endpoint   = 'confirmSafe'
        Description = 'set risk to none and classify the event as a false positive'
    }
}
$selectedAction = $actionDetails[$Action]
$target = "agent '$AgentId' in tenant '$($context.TenantId)'"
$approved = $Force -or $PSCmdlet.ShouldProcess($target, $selectedAction.Description)

if (-not $approved) {
    Write-Host 'No change was made.' -ForegroundColor Yellow
    return
}

$body = @{ agentIds = @($AgentId) } | ConvertTo-Json -Compress
Invoke-MgGraphRequest -Method POST -Uri "$baseUri/$($selectedAction.Endpoint)" `
    -Body $body -ContentType 'application/json' | Out-Null

Write-Host "Action '$Action' accepted by Microsoft Graph. Reading current state..." -ForegroundColor Green
Get-AgentRisk -ObjectId $AgentId |
    Select-Object id, agentDisplayName, identityType, riskLevel, riskState, riskDetail,
        isEnabled, isProcessing, recordExists