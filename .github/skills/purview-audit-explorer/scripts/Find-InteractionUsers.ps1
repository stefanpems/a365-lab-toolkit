#Requires -Version 7
<#
.SYNOPSIS
  READ-ONLY tenant-wide discovery. Runs an async unified-audit-log query for Copilot interactions and
  returns the distinct users (and agent identifiers) that have interactions in the window. Use this to
  learn WHICH user UPNs to pass to List-AgentConversations.ps1.
.EXAMPLE
  pwsh -File Find-InteractionUsers.ps1 -SinceDays 7
#>
[CmdletBinding()]
param(
    [int] $SinceDays = 7,
    [int] $PollSeconds = 180
)
. "$PSScriptRoot/_common.ps1"

$auth = Get-PurviewToken
$tok = $auth.Token
$start = (Get-Date).ToUniversalTime().AddDays(-$SinceDays).ToString('yyyy-MM-ddTHH:mm:ssZ')
$end = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

$q = Invoke-Graph -Token $tok -Method POST -Uri 'https://graph.microsoft.com/beta/security/auditLog/queries' -Body @{
    '@odata.type'       = '#microsoft.graph.security.auditLogQuery'
    displayName         = "purview-audit-explorer-$(Get-Date -Format yyyyMMddHHmmss)"
    filterStartDateTime = $start
    filterEndDateTime   = $end
    recordTypeFilters   = @('copilotInteraction')
}
Write-Host "Audit query $($q.id) created ($start .. $end). Waiting..." -ForegroundColor Cyan

$deadline = (Get-Date).AddSeconds($PollSeconds)
do {
    Start-Sleep -Seconds 10
    $s = Invoke-Graph -Token $tok -Uri "https://graph.microsoft.com/beta/security/auditLog/queries/$($q.id)"
    Write-Host "  status=$($s.status)" -ForegroundColor DarkGray
} while ($s.status -notin @('succeeded', 'failed') -and (Get-Date) -lt $deadline)

if ($s.status -ne 'succeeded') {
    Write-Host "Query did not finish in time (status=$($s.status)). Re-run later or increase -PollSeconds." -ForegroundColor Yellow
    return
}

$recs = @(); $next = "https://graph.microsoft.com/beta/security/auditLog/queries/$($q.id)/records"
$page = 0
while ($next -and $page -lt 50) {
    $r = Invoke-Graph -Token $tok -Uri $next
    $recs += $r.value; $next = Get-ODataNext $r; $page++
}
Write-Host "Records: $($recs.Count)" -ForegroundColor Cyan

$rows = foreach ($rec in $recs) {
    $ad = $rec.auditData
    $ced = if ($ad.PSObject.Properties.Name -contains 'CopilotEventData') { $ad.CopilotEventData } else { $null }
    $agent = ''
    if ($ced) {
        if ($ced.PSObject.Properties.Name -contains 'AppHost') { $agent = $ced.AppHost }
        if (-not $agent -and ($ced.PSObject.Properties.Name -contains 'AppIdentity')) { $agent = $ced.AppIdentity }
    }
    [pscustomobject]@{
        Time   = $rec.createdDateTime
        User   = $rec.userPrincipalName
        Agent  = $agent
        Op     = $rec.operation
    }
}

Write-Host "`n--- distinct users with Copilot/agent interactions ---" -ForegroundColor Green
$rows | Group-Object User | Sort-Object Count -Descending | ForEach-Object { "  {0,-45} {1}" -f $_.Name, $_.Count }
Write-Host "`n--- distinct agents/app hosts ---" -ForegroundColor Green
$rows | Group-Object Agent | Sort-Object Count -Descending | ForEach-Object { "  {0,-45} {1}" -f $_.Name, $_.Count }
