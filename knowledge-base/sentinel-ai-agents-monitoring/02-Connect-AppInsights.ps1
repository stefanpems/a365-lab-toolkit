<#
.SYNOPSIS
  Step 2 (Sentinel scenario only) - Makes the telemetry of one or more Application Insights resources available in
  the Microsoft Sentinel workspace.
.DESCRIPTION
  Mode Relink (the approach recommended by the pack author): the Application Insights resource is re-linked to the
  Sentinel workspace, so ALL its tables (including AppGenAIContent and AppTraces) are ingested there from now on.
  Historical data stays in the previous workspace. Nothing is duplicated.

  Mode DiagnosticSetting: a diagnostic setting COPIES only the selected categories to the Sentinel workspace; the
  Application Insights resource keeps writing to its own workspace. Lets you skip noisy/costly tables such as
  AppTraces, but the copied tables are billed twice and AppGenAIContent cannot be exported this way.
.EXAMPLE
  .\02-Connect-AppInsights.ps1 -AppInsightsResourceId $ai1,$ai2 -SentinelWorkspaceResourceId $ws -Mode DiagnosticSetting
  .\02-Connect-AppInsights.ps1 -AppInsightsResourceId $ai1 -SentinelWorkspaceResourceId $ws -Mode Relink -WhatIf
#>
param(
    [Parameter(Mandatory)][string[]] $AppInsightsResourceId,
    [Parameter(Mandatory)][string] $SentinelWorkspaceResourceId,
    [ValidateSet('DiagnosticSetting', 'Relink')][string] $Mode = 'DiagnosticSetting',
    [string[]] $Categories = @('AppDependencies', 'AppEvents', 'AppRequests', 'AppExceptions'),
    [string] $SettingName = 'to-sentinel',
    [switch] $RemoveDiagnosticSetting,
    [switch] $WhatIf
)
. (Join-Path $PSScriptRoot '_common.ps1')

foreach ($ai in $AppInsightsResourceId) {
    $c = az rest --method get --url "https://management.azure.com$($ai)?api-version=2020-02-02" -o json | ConvertFrom-Json
    Write-Host ("== {0}  (currently linked to: {1})" -f $c.name, (Split-ResourceId $c.properties.WorkspaceResourceId).Name)

    if ($Mode -eq 'DiagnosticSetting') {
        $logs = $Categories | ForEach-Object { @{ category = $_; enabled = $true } }
        $tmp = New-TemporaryFile
        ConvertTo-Json -InputObject @($logs) -Compress | Set-Content $tmp -Encoding utf8
        $cmd = "az monitor diagnostic-settings create --name $SettingName --resource $ai --workspace $SentinelWorkspaceResourceId --logs @$tmp"
        if ($WhatIf) { Write-Host "WHATIF: $cmd  (logs: $($Categories -join ', '))" }
        else {
            az monitor diagnostic-settings create --name $SettingName --resource $ai --workspace $SentinelWorkspaceResourceId `
                --logs "@$tmp" --query "{name:name, categories:logs[?enabled].category}" -o json
            if ($LASTEXITCODE) { throw "Diagnostic setting on $($c.name) failed" }
        }
        Remove-Item $tmp
    }
    else {
        $t = Split-ResourceId $ai
        $cmd = "az monitor app-insights component update --app $($t.Name) -g $($t.ResourceGroup) --subscription $($t.SubscriptionId) --workspace $SentinelWorkspaceResourceId"
        if ($WhatIf) { Write-Host "WHATIF: $cmd" }
        else {
            az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors | Out-Null
            az monitor app-insights component update --app $t.Name -g $t.ResourceGroup --subscription $t.SubscriptionId `
                --workspace $SentinelWorkspaceResourceId --query "{name:name, workspace:workspaceResourceId}" -o json
            if ($LASTEXITCODE) { throw "Re-link of $($c.name) failed" }
        }
        if ($RemoveDiagnosticSetting) {
            $cmd = "az monitor diagnostic-settings delete --name $SettingName --resource $ai"
            if ($WhatIf) { Write-Host "WHATIF: $cmd" } else { az monitor diagnostic-settings delete --name $SettingName --resource $ai }
        }
    }
}
Write-Host 'Done. New telemetry reaches the workspace within 5-15 minutes; data is not retroactive.'
