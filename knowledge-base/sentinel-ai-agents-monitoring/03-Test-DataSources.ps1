<#
.SYNOPSIS
  Step 3 - Checks, in a Log Analytics workspace, every data source used by the packs and the workbook, including
  whether prompt/response content is being recorded (required by the text-based detections).
.EXAMPLE
  .\03-Test-DataSources.ps1 -WorkspaceResourceId $ws -Timespan P7D
#>
param(
    [Parameter(Mandatory)][string] $WorkspaceResourceId,
    [string] $Timespan = 'P7D'
)
. (Join-Path $PSScriptRoot '_common.ps1')

$checks = [ordered]@{
    'AppEvents'                 = 'Copilot Studio agent-level telemetry (both packs + workbook)'
    'AppDependencies'           = 'Foundry gen_ai spans / Copilot Studio connector calls (both packs + workbook)'
    'AppRequests'               = 'Workbook usage tiles'
    'AppExceptions'             = 'Workbook error tiles'
    'AppGenAIContent'           = 'Foundry protected content table (8 Foundry rules; only via native App Insights ingestion)'
    'ThreatIntelIndicators'     = 'TI URL/domain match rules (Threat Intelligence connector)'
    'SecurityAlert'             = 'Workbook SOC / Detections tabs (Sentinel)'
    'SecurityIncident'          = 'Workbook SOC tab (Sentinel)'
    'IdentityInfo'              = 'Workbook department / business-unit tiles (UEBA)'
    'SigninLogs'                = 'Workbook investigation tab (Entra ID connector)'
    'AuditLogs'                 = 'Foundry hunting (Entra ID connector)'
    'OfficeActivity'            = 'Foundry hunting + workbook (Office 365 connector)'
    'AzureActivity'             = 'Foundry hunting (Azure Activity connector)'
    'CopilotActivity'           = 'Workbook M365 Copilot tab (Microsoft Copilot connector, Analytics plan)'
    'OpenAIAuditLogs'           = 'Workbook OpenAI tab (OpenAI codeless connector)'
    'OpenAIChatCompletions'     = 'Workbook OpenAI tab (OpenAI codeless connector)'
    'ASimAgentEventLogs'        = 'Workbook OpenAI / timeline tiles (OpenAI connector parsers)'
    'CloudAppEvents'            = 'Workbook governance / shadow-AI tiles (Defender XDR connector)'
}
Write-Host ("{0,-24} {1,10}  {2}" -f 'Table', 'Rows', 'Used by')
foreach ($t in $checks.Keys) {
    try { $n = (Invoke-LaQuery -WorkspaceResourceId $WorkspaceResourceId -Timespan $Timespan -Query "$t | summarize Rows = count()" | Select-Object -First 1).Rows }
    catch { $n = 'MISSING' }
    Write-Host ("{0,-24} {1,10}  {2}" -f $t, $n, $checks[$t])
}

Write-Host "`n== Content recording (text-based detections stay silent without it)"
$q = @'
union isfuzzy=true
 (AppEvents | where Name in ("BotMessageReceived", "BotMessageSend")
   | summarize Total = count(), WithText = countif(isnotempty(tostring(Properties["text"]))) | extend Source = "Copilot Studio messages (Log sensitive properties)"),
 (AppDependencies | where isnotempty(tostring(Properties["gen_ai.operation.name"]))
   | summarize Total = count(), WithText = countif(isnotempty(tostring(Properties["gen_ai.input.messages"]))) | extend Source = "Foundry gen_ai spans (content recording)")
| where Total > 0 | project Source, Total, WithText
'@
try { Invoke-LaQuery -WorkspaceResourceId $WorkspaceResourceId -Timespan $Timespan -Query $q | Format-Table -AutoSize | Out-String -Width 200 }
catch { Write-Host 'No App* telemetry yet.' }
