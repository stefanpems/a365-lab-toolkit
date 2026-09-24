# Shared helpers for the AI-agents monitoring deployment scripts (dot-source this file).
$ErrorActionPreference = 'Stop'
# Local clone of the upstream repo, kept outside this repository (deep paths, not versioned here).
$DefaultRepoPath = Join-Path $env:LOCALAPPDATA 'Dalonso-Security-Repo'

function Invoke-LaQuery {
    <# Runs a KQL query against a Log Analytics workspace through ARM (no CLI extension needed). #>
    param(
        [Parameter(Mandatory)][string] $WorkspaceResourceId,
        [Parameter(Mandatory)][string] $Query,
        [string] $Timespan = 'P7D'
    )
    $body = @{ query = $Query; timespan = $Timespan } | ConvertTo-Json -Compress
    $tmp = New-TemporaryFile
    try {
        [IO.File]::WriteAllText($tmp, $body)
        $raw = az rest --method post --url "https://management.azure.com$WorkspaceResourceId/api/query?api-version=2020-08-01" --body "@$tmp" -o json 2>&1
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    if ($LASTEXITCODE) { throw ($raw | Out-String) }
    $r = ($raw | Out-String) | ConvertFrom-Json
    $cols = @($r.Tables[0].Columns.ColumnName)
    foreach ($row in $r.Tables[0].Rows) {
        $o = [ordered]@{}
        for ($i = 0; $i -lt $cols.Count; $i++) { $o[$cols[$i]] = $row[$i] }
        [pscustomobject]$o
    }
}

function Invoke-Arm {
    <# ARM call through Invoke-RestMethod (UTF-8 safe; az rest strips non-ASCII characters on Windows). #>
    param(
        [Parameter(Mandatory)][string] $Path,
        [string] $Method = 'GET',
        $Body
    )
    $token = az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv
    $p = @{ Method = $Method; Uri = "https://management.azure.com$Path"; Headers = @{ Authorization = "Bearer $token" } }
    if ($null -ne $Body) {
        $p.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 50))
        $p.ContentType = 'application/json; charset=utf-8'
    }
    Invoke-RestMethod @p
}

function Split-ResourceId {
    param([Parameter(Mandatory)][string] $ResourceId)
    $p = $ResourceId.Trim('/').Split('/')
    [pscustomobject]@{ SubscriptionId = $p[1]; ResourceGroup = $p[3]; Name = $p[-1] }
}

function Get-PacksRoot {
    param([Parameter(Mandatory)][string] $RepoPath)
    Join-Path $RepoPath 'Use Cases Threat Hunting\Monitoring AI Agents'
}
