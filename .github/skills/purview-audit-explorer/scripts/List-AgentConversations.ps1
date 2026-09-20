#Requires -Version 7
<#
.SYNOPSIS
  READ-ONLY. List the agent conversations (sessions) found in a user's AI interaction history.
.EXAMPLE
  pwsh -File List-AgentConversations.ps1 -UserUpn admin@contoso.onmicrosoft.com -SinceHours 168
.EXAMPLE
  pwsh -File List-AgentConversations.ps1 -UserUpn admin@contoso.onmicrosoft.com -AppClassLike '*fh-obo*'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $UserUpn,
    [int]    $SinceHours = 168,
    [string] $AppClassLike,
    [switch] $AsJson
)
. "$PSScriptRoot/_common.ps1"

$since = (Get-Date).ToUniversalTime().AddHours(-$SinceHours)
$auth = Initialize-PurviewApp
$u = Resolve-UserId -Upn $UserUpn
if (-not $AsJson) {
    Write-Host "User: $($u.userPrincipalName)  ($($u.displayName))  since $($since.ToString('u'))" -ForegroundColor Cyan
}

$items = Get-EnterpriseInteractions -Token $auth.Token -UserId $u.id -Since $since -AppClassLike $AppClassLike
if ($items.Count -eq 0) {
    Write-Host "No agent interactions found in this window." -ForegroundColor Yellow
    return
}

# One conversation = one sessionId within one appClass.
$convs = $items | Group-Object { "$($_.appClass)|$($_.sessionId)" } | ForEach-Object {
    $g = $_.Group | Sort-Object createdDateTime
    $firstUser = ($g | Where-Object interactionType -eq 'userPrompt' | Select-Object -First 1)
    [pscustomobject]@{
        Agent     = Format-AgentName $g[0].appClass
        AppClass  = $g[0].appClass
        SessionId = $g[0].sessionId
        Start     = ([datetime]$g[0].createdDateTime).ToString('u')
        End       = ([datetime]$g[-1].createdDateTime).ToString('u')
        Msgs      = $g.Count
        FirstPrompt = if ($firstUser) { ($firstUser.body.content -replace '\s+', ' ') } else { '' }
    }
} | Sort-Object End -Descending

if ($AsJson) {
    $convs | ConvertTo-Json -Depth 6
    return
}

$i = 0
$convs | ForEach-Object {
    $i++
    $fp = if ($_.FirstPrompt.Length -gt 70) { $_.FirstPrompt.Substring(0, 70) + '...' } else { $_.FirstPrompt }
    [pscustomobject]@{
        '#'       = $i
        Agent     = if ($_.Agent.Length -gt 34) { $_.Agent.Substring(0, 34) } else { $_.Agent }
        Session   = $_.SessionId.Substring(0, [Math]::Min(13, $_.SessionId.Length)) + '...'
        End       = $_.End
        Msgs      = $_.Msgs
        FirstPrompt = $fp
    }
} | Format-Table -AutoSize -Wrap

Write-Host "`nTip: show one with  Show-Conversation.ps1 -UserUpn $UserUpn -SessionId <full-session-id>" -ForegroundColor DarkGray
