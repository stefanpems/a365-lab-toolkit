#Requires -Version 7
<#
.SYNOPSIS
  READ-ONLY. Render the ordered message exchange of one agent conversation (session) from a user's
  AI interaction history.
.EXAMPLE
  pwsh -File Show-Conversation.ps1 -UserUpn admin@contoso.onmicrosoft.com -SessionId 0dda3f56-c8a6-...
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $UserUpn,
    [Parameter(Mandatory)] [string] $SessionId,
    [int] $SinceHours = 720
)
. "$PSScriptRoot/_common.ps1"

$since = (Get-Date).ToUniversalTime().AddHours(-$SinceHours)
$auth = Get-PurviewToken
$u = Resolve-UserId -Token $auth.Token -Upn $UserUpn

$items = Get-EnterpriseInteractions -Token $auth.Token -UserId $u.id -Since $since |
    Where-Object { $_.sessionId -eq $SessionId } | Sort-Object createdDateTime
if ($items.Count -eq 0) {
    Write-Host "No interactions for session $SessionId in the last $SinceHours h." -ForegroundColor Yellow
    return
}

$agent = Format-AgentName $items[0].appClass
Write-Host "Conversation  agent='$agent'  session=$SessionId  turns=$($items.Count)" -ForegroundColor Cyan
Write-Host ("appClass: {0}" -f $items[0].appClass) -ForegroundColor DarkGray
Write-Host ''

foreach ($it in $items) {
    $ts = ([datetime]$it.createdDateTime).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $dir = switch ($it.interactionType) {
        'userPrompt' { 'USER  ->' }
        'aiResponse' { '<- AGENT' }
        default { $it.interactionType }
    }
    $who = if ($it.from.user) { $it.from.user.displayName } elseif ($it.from.application) { $it.from.application.displayName } else { '' }
    $text = if ($it.body -and $it.body.content) { $it.body.content } else { '(no text captured)' }
    Write-Host ("[{0}] {1} ({2}):" -f $ts, $dir, $who) -ForegroundColor Green
    Write-Host $text
    Write-Host ''
}
