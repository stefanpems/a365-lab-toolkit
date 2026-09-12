#requires -Version 7.0
<#
  Shared, CLOUD-FREE helpers for surgically editing the web UI's config.js (window.APP_CONFIG).
  Dot-sourced by Add-WebUiTab.ps1 / Remove-WebUiTab.ps1 and by the offline unit test.

  The config.js the Lab Builder / Web UI Creator deploy is PURE JSON wrapped in
  `window.APP_CONFIG = { ... };`. These helpers parse that wrapper, mutate the agents[] array
  WITHOUT touching the msal block or any other tab, and re-serialize it. They never call Azure.

  A tab carries, in addition to the shape scaffold.ui.ps1 emits, two association fields:
    * id        = "<typeShortId>-<labPrefix>"  (unique across labs in a SHARED config.js)
    * labPrefix = "<labPrefix>"                (authoritative owner; drives deregistration)
  app.js ignores unknown fields, so labPrefix is inert at runtime.
#>

Set-StrictMode -Version Latest

# Short tab id per agent type (matches scaffold.ui.ps1 base ids).
function Get-TabShortId {
    param([Parameter(Mandatory)][string]$AgentType)
    switch ($AgentType) {
        'ACA-OBO' { 'obo' }
        'ACA-S2S' { 's2s' }
        'FH-OBO'  { 'obo-fh' }
        'FH-S2S'  { 's2s-fh' }
        'FD-OBO'  { 'obo-fd' }
        'FD-S2S'  { 's2s-fd' }
        default   { throw "Unsupported agent type for a web UI tab: '$AgentType' (DW/MCS are never exposed in the SPA)." }
    }
}

# Parse `window.APP_CONFIG = { ... };` (optionally preceded by a comment line) into a PSCustomObject.
function Read-AppConfig {
    param([Parameter(Mandatory)][string]$Text)
    $marker = 'window.APP_CONFIG'
    $idx = $Text.IndexOf($marker)
    if ($idx -lt 0) { throw "config.js does not contain 'window.APP_CONFIG'." }
    $eq = $Text.IndexOf('=', $idx)
    if ($eq -lt 0) { throw "config.js: no '=' after window.APP_CONFIG." }
    $body = $Text.Substring($eq + 1).Trim()
    # Strip a single trailing ';' and any trailing whitespace/newlines.
    $body = $body.TrimEnd()
    if ($body.EndsWith(';')) { $body = $body.Substring(0, $body.Length - 1).TrimEnd() }
    try { return ($body | ConvertFrom-Json) }
    catch {
        throw "config.js is not parseable as JSON (malformed, or hand-written JS that is not valid JSON). The Lab Builder / Web UI Creator emit pure JSON, so this only happens on a hand-edited config — reconcile it by hand. Detail: $($_.Exception.Message)"
    }
}

# Serialize a config object back to the config.js wrapper.
function Write-AppConfig {
    param([Parameter(Mandatory)]$Config)
    $json = $Config | ConvertTo-Json -Depth 12
    return "// Generated/edited by the Agent 365 lab web-UI scripts — pure JSON; do not add comments.`nwindow.APP_CONFIG = $json;"
}

# Build one tab entry (ordered) mirroring scaffold.ui.ps1 exactly, plus id/labPrefix/enabled.
function New-TabEntry {
    param(
        [Parameter(Mandatory)][string]$AgentType,
        [Parameter(Mandatory)][string]$Name,          # free-form label
        [Parameter(Mandatory)][string]$LabPrefix,
        [string]$TabId,                                 # default <shortId>-<labPrefix>
        [string]$ApiBase,                               # ACA
        [string]$S2sAppId,                              # ACA-S2S scope
        [string]$Endpoint,                              # Foundry
        [string]$AgentName,                             # FD
        [string]$AnonAudience,                          # custom MCP (OBO)
        [string]$AuthAudience
    )
    $short = Get-TabShortId -AgentType $AgentType
    if (-not $TabId) { $TabId = "$short-$LabPrefix" }
    $mailScope = 'ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/McpServers.Mail.All'
    $entry = switch ($AgentType) {
        'ACA-OBO' { [ordered]@{ id = $TabId; kind = 'aca'; name = $Name; description = 'OBO agent; /chat sends mail from your mailbox.'; apiBase = $ApiBase; scope = $mailScope } }
        'ACA-S2S' { [ordered]@{ id = $TabId; kind = 'aca'; name = $Name; description = 'S2S blueprint agent; own identity.'; apiBase = $ApiBase; scope = "api://$S2sAppId/access_agent_as_user" } }
        'FH-OBO'  { [ordered]@{ id = $TabId; kind = 'foundry-invocations'; name = $Name; description = 'Foundry Hosted OBO; gateway auth + mail_token.'; endpoint = $Endpoint; endpointScope = 'https://ai.azure.com/.default'; mailScope = $mailScope; sessionPrefix = $short } }
        'FH-S2S'  { [ordered]@{ id = $TabId; kind = 'foundry-responses'; name = $Name; description = 'Foundry Hosted S2S; own identity.'; endpoint = $Endpoint; endpointScope = 'https://ai.azure.com/.default' } }
        'FD-OBO'  { [ordered]@{ id = $TabId; kind = 'foundry-prompt'; name = $Name; description = 'Foundry prompt OBO; project Responses + mail_token.'; endpoint = $Endpoint; endpointScope = 'https://ai.azure.com/.default'; agentName = $AgentName; mailScope = $mailScope } }
        'FD-S2S'  { [ordered]@{ id = $TabId; kind = 'foundry-prompt'; name = $Name; description = 'Foundry prompt S2S; own identity.'; endpoint = $Endpoint; endpointScope = 'https://ai.azure.com/.default'; agentName = $AgentName } }
        default   { throw "Unsupported agent type for a web UI tab: '$AgentType'." }
    }
    # Custom (BYO) MCP token wiring — only for OBO tabs that have a custom MCP attached.
    if ($AnonAudience -or $AuthAudience) {
        if ($AgentType -eq 'ACA-OBO' -or $AgentType -eq 'FH-OBO') {
            $cs = [ordered]@{}
            if ($AnonAudience) { $cs[$AnonAudience] = "$AnonAudience/Tools.ListInvoke.All" }
            if ($AuthAudience) { $cs[$AuthAudience] = "$AuthAudience/Tools.ListInvoke.All" }
            if ($cs.Count -gt 0) { $entry['customScopes'] = $cs }
        }
        elseif ($AgentType -eq 'FD-OBO') {
            $ci = [ordered]@{}
            if ($AnonAudience) { $ci['anon_token'] = "$AnonAudience/Tools.ListInvoke.All" }
            if ($AuthAudience) { $ci['auth_token'] = "$AuthAudience/Tools.ListInvoke.All" }
            if ($ci.Count -gt 0) { $entry['customInputs'] = $ci }
        }
    }
    $entry['enabled'] = $true
    $entry['labPrefix'] = $LabPrefix
    return $entry
}

# Merge a tab into config.agents: replace an entry with the same id, else append. Preserves everything else.
function Add-OrReplaceTab {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Entry)
    $id = $Entry['id']
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($a in @($Config.agents)) { if ("$($a.id)" -ne "$id") { $list.Add($a) } }
    $list.Add([pscustomobject]$Entry)
    $Config.agents = $list.ToArray()
    return $Config
}

# Remove every tab owned by a lab (labPrefix match, or id ending in "-<prefix>" for older tabs). Returns removed count.
function Remove-TabsByLab {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$LabPrefix)
    $keep = New-Object System.Collections.Generic.List[object]
    $removed = 0
    foreach ($a in @($Config.agents)) {
        $owner = if ($a.PSObject.Properties.Name -contains 'labPrefix') { "$($a.labPrefix)" } else { '' }
        $byId = ("$($a.id)".EndsWith("-$LabPrefix"))
        if (($owner -eq $LabPrefix) -or ($owner -eq '' -and $byId)) { $removed++; continue }
        $keep.Add($a)
    }
    $Config.agents = $keep.ToArray()
    return $removed
}

# Remove a single tab by id. Returns removed count (0 or 1).
function Remove-TabById {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$TabId)
    $keep = New-Object System.Collections.Generic.List[object]
    $removed = 0
    foreach ($a in @($Config.agents)) {
        if ("$($a.id)" -eq $TabId) { $removed++; continue }
        $keep.Add($a)
    }
    $Config.agents = $keep.ToArray()
    return $removed
}
