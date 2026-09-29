#requires -Version 5.1
<#
.SYNOPSIS
  Iron rules for every name and text the lab registers or publishes (BYO MCP servers and tools, AI-teammate
  manifests, Copilot Studio / Agent Builder agents, Entra and Purview objects, aliases, SharePoint names).

.DESCRIPTION
  Dot-source this file to get the Test-* functions, or run it with -SelfTest to verify the rules against the
  failures observed in real runs. The limits live in ../references/text-limits.json (single source of truth):
  'max' is ENFORCED (platform limit minus a safety margin), 'platformMax' is the platform limit itself.
  Every Test-* function returns violation objects { level = error|warning; field; message }; an empty result
  means the value is valid. With -PlatformOnly a value above 'max' but within 'platformMax' is a WARNING
  (use it for names that already exist), otherwise it is an ERROR (use the default for anything NEW).

.EXAMPLE
  . .\Test-A365Names.ps1; Test-ExtMcpServer -Name 'ext_ContosoTest' -Description 'Test server (fictional data).'
.EXAMPLE
  pwsh -File .\Test-A365Names.ps1 -SelfTest
#>
[CmdletBinding()]
param([switch]$SelfTest)

$script:A365LimitsPath = Join-Path $PSScriptRoot '..\references\text-limits.json'
$script:A365Limits = $null

function Get-A365TextLimits {
    if (-not $script:A365Limits) {
        $script:A365Limits = Get-Content -LiteralPath $script:A365LimitsPath -Raw -Encoding utf8 | ConvertFrom-Json
    }
    return $script:A365Limits
}

function New-A365Violation([string]$Level, [string]$Field, [string]$Message) {
    [pscustomobject]@{ level = $Level; field = $Field; message = $Message }
}

# Length check against { max, platformMax }: above platformMax -> error; above max -> error (or warning with -PlatformOnly).
function Test-A365Length {
    param([string]$Field, [AllowEmptyString()][string]$Value, $Limit, [switch]$PlatformOnly, [switch]$AllowEmpty)
    $out = @()
    if ($null -eq $Value -or $Value -eq '') {
        if (-not $AllowEmpty) { $out += New-A365Violation 'error' $Field 'is empty' }
        return $out
    }
    if ($Value -ne $Value.Trim()) { $out += New-A365Violation 'error' $Field 'has leading or trailing whitespace' }
    if ($Value -match '[\x00-\x1F]' -and $Field -notmatch 'instructions|descriptionFull|descriptionLong') {
        $out += New-A365Violation 'error' $Field 'contains control characters'
    }
    $len = $Value.Length
    $pmax = if ($Limit.PSObject.Properties['platformMax']) { [int]$Limit.platformMax } else { [int]$Limit.max }
    if ($len -gt $pmax) { $out += New-A365Violation 'error' $Field "is $len characters (platform limit $pmax)" }
    elseif ($len -gt [int]$Limit.max) {
        $lvl = if ($PlatformOnly) { 'warning' } else { 'error' }
        $out += New-A365Violation $lvl $Field "is $len characters (enforced limit $($Limit.max), platform $pmax)"
    }
    if ($Limit.PSObject.Properties['min'] -and $len -lt [int]$Limit.min) { $out += New-A365Violation 'error' $Field "is $len characters (minimum $($Limit.min))" }
    return $out
}

function Test-A365Pattern([string]$Field, [string]$Value, $Limit) {
    if ($Limit.PSObject.Properties['pattern'] -and $Value -cnotmatch $Limit.pattern) {
        $rule = if ($Limit.PSObject.Properties['patternRule']) { $Limit.patternRule } else { "pattern $($Limit.pattern)" }
        return @(New-A365Violation 'error' $Field "'$Value' breaks the rule: $rule")
    }
    return @()
}

# Proxy tool-connector id the Agent 365 gateway creates for a BYO server. Only its LENGTH is tenant-independent;
# pass the real hex blocks to build a real id.
function Get-ExtMcpProxyConnectorId {
    param([Parameter(Mandatory)][string]$Name, [string]$Hex1 = ('0' * 16), [string]$Hex2 = ('0' * 16))
    $rest = ($Name -replace '^(?i)ext_', '').ToLowerInvariant() -replace '_', '-5f'
    return "tc-ext-5f${rest}p-5f$Hex1-5f$Hex2"
}

<#
  BYO MCP server: name pattern + name length + proxy connector length + description length.
  -Numbered validates a reserve-pool BASE (ext_<Base>) at its worst case ext_<Base>99.
#>
function Test-ExtMcpServer {
    param([Parameter(Mandatory)][string]$Name, [AllowEmptyString()][string]$Description, [switch]$Numbered, [switch]$PlatformOnly, [switch]$SkipDescription)
    $L = (Get-A365TextLimits).byoMcpServer
    $candidate = if ($Numbered) { "${Name}99" } else { $Name }
    $out = @()
    # An EXISTING server (-PlatformOnly) may carry an underscore after 'ext_' as long as its connector fits the
    # platform: that is a warning. A NEW name must follow the strict pattern.
    if ($PlatformOnly -and $candidate -cmatch '^ext_[A-Za-z0-9_]+$' -and $candidate -cnotmatch $L.name.pattern) {
        $out += New-A365Violation 'warning' 'server.name' "'$candidate' has characters after 'ext_' that Power Platform encodes (+2 per '_'); never use this form for a new server"
    }
    else { $out += Test-A365Pattern 'server.name' $candidate $L.name }
    $out += Test-A365Length -Field "server.name ($candidate)" -Value $candidate -Limit $L.name -PlatformOnly:$PlatformOnly
    $conn = Get-ExtMcpProxyConnectorId -Name $candidate
    $out += Test-A365Length -Field "server.proxyConnector ($conn)" -Value $conn -Limit $L.proxyConnectorId -PlatformOnly:$PlatformOnly
    if (-not $SkipDescription) { $out += Test-A365Length -Field 'server.description' -Value $Description -Limit $L.description -PlatformOnly:$PlatformOnly }
    return $out
}

<#
  Tools of ONE server: name pattern/length/reserved words, description lengths, parameter descriptions, duplicates
  inside the server and - with -ToolOwners (tool name -> server names) - duplicates across servers.
  Each tool: @{ name; description; parameters = @(@{ name; description }) } (parameters optional).
#>
function Test-McpTools {
    param([Parameter(Mandatory)][string]$ServerName, [Parameter(Mandatory)][object[]]$Tools, [hashtable]$ToolOwners)
    $L = (Get-A365TextLimits).mcpTool
    $out = @()
    if (-not $Tools.Count) { $out += New-A365Violation 'error' "$ServerName.tools" 'no tools declared' }
    $seen = @{}
    foreach ($t in $Tools) {
        $n = [string]$t.name
        $out += Test-A365Pattern "$ServerName.tool.name" $n $L.name
        $out += Test-A365Length -Field "$ServerName.tool '$n' name" -Value $n -Limit $L.name
        if ($L.name.reserved -contains $n) { $out += New-A365Violation 'error' "$ServerName.tool '$n'" 'is reserved by the Agent 365 gateway' }
        if ($seen.ContainsKey($n)) { $out += New-A365Violation 'error' "$ServerName.tool '$n'" 'is declared twice in the same server' }
        $seen[$n] = $true
        $out += Test-A365Length -Field "$ServerName.tool '$n' description" -Value ([string]$t.description) -Limit $L.description
        foreach ($p in @($t.parameters)) {
            if (-not $p) { continue }
            $out += Test-A365Length -Field "$ServerName.tool '$n' parameter '$($p.name)' description" -Value ([string]$p.description) -Limit $L.parameterDescription
            if ([string]$p.name -cnotmatch '^[a-z][a-z0-9_]*$') { $out += New-A365Violation 'error' "$ServerName.tool '$n' parameter" "'$($p.name)' must be lowercase ASCII snake_case" }
        }
        if ($ToolOwners -and $ToolOwners.ContainsKey($n)) {
            $others = @($ToolOwners[$n] | Where-Object { $_ -ne $ServerName } | Select-Object -Unique)
            if ($others.Count) { $out += New-A365Violation 'error' "$ServerName.tool '$n'" "is also declared by: $($others -join ', ') (a tool name may belong to ONE active server only)" }
        }
    }
    return $out
}

# Teams / AI-teammate manifest texts (name.short, name.full, description.short, description.full, developer.name).
function Test-TeamsManifestText {
    param([string]$NameShort, [string]$NameFull, [string]$DescriptionShort, [string]$DescriptionFull, [string]$DeveloperName)
    $L = (Get-A365TextLimits).teamsManifest
    $out = @()
    $out += Test-A365Length -Field 'manifest.name.short' -Value $NameShort -Limit $L.nameShort
    $out += Test-A365Length -Field 'manifest.name.full' -Value $NameFull -Limit $L.nameFull
    $out += Test-A365Length -Field 'manifest.description.short' -Value $DescriptionShort -Limit $L.descriptionShort
    $out += Test-A365Length -Field 'manifest.description.full' -Value $DescriptionFull -Limit $L.descriptionFull
    if ($DeveloperName) { $out += Test-A365Length -Field 'manifest.developer.name' -Value $DeveloperName -Limit $L.developerName }
    return $out
}

# Generic length (+ optional pattern) check by dotted limit path, e.g. 'copilotStudioAgent.displayName'.
function Test-A365Text {
    param([Parameter(Mandatory)][string]$Kind, [AllowEmptyString()][string]$Value, [string]$Field, [switch]$PlatformOnly, [switch]$AllowEmpty)
    $node = Get-A365TextLimits
    foreach ($seg in $Kind.Split('.')) { $node = $node.$seg; if ($null -eq $node) { throw "Unknown text-limit kind '$Kind'." } }
    if (-not $Field) { $Field = $Kind }
    $out = @()
    if ($node.PSObject.Properties['max']) { $out += Test-A365Length -Field $Field -Value $Value -Limit $node -PlatformOnly:$PlatformOnly -AllowEmpty:$AllowEmpty }
    if ($Value -and $node.PSObject.Properties['pattern']) { $out += Test-A365Pattern $Field $Value $node }
    return $out
}

# SharePoint folder / file name segment.
function Test-SharePointSegment([string]$Field, [string]$Value) {
    $L = (Get-A365TextLimits).sharePoint.segment
    $out = @(Test-A365Length -Field $Field -Value $Value -Limit $L)
    foreach ($ch in $L.forbiddenChars.ToCharArray()) { if ($Value.Contains($ch)) { $out += New-A365Violation 'error' $Field "contains the forbidden character '$ch'" } }
    if ($Value -match '^[ .]|[ .]$') { $out += New-A365Violation 'error' $Field 'starts or ends with a space or a dot' }
    return $out
}

# Removes diacritics and builds a safe alias ('Chloé Dupré' -> 'chloe.dupre').
function ConvertTo-A365Alias {
    param([Parameter(Mandatory)][string[]]$Parts)
    $norm = foreach ($p in $Parts) {
        $d = $p.Normalize([Text.NormalizationForm]::FormD)
        $s = -join ($d.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' })
        $s = $s.Replace('ß', 'ss').Replace('æ', 'ae').Replace('ø', 'o').Replace('œ', 'oe').Replace('Æ', 'AE').Replace('Ø', 'O').Replace('Œ', 'OE')
        ($s.ToLowerInvariant() -replace '[^a-z0-9]', '')
    }
    return (@($norm | Where-Object { $_ }) -join '.')
}

if ($SelfTest) {
    $fail = 0
    function Assert-A365([string]$Label, [object[]]$Violations, [bool]$ExpectValid) {
        $errors = @($Violations | Where-Object level -eq 'error')
        $ok = ($errors.Count -eq 0) -eq $ExpectValid
        if (-not $ok) { $script:fail++ }
        '{0}  {1}{2}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $Label, $(if ($errors) { " -> $($errors[0].message)" } else { '' })
    }
    Assert-A365 'ext_Protocollo_Test (underscore -> 65-char connector) is rejected' (Test-ExtMcpServer -Name 'ext_Protocollo_Test' -Description 'Test server (fictional data).') $false
    Assert-A365 'existing ext_Protocollo_Test is rejected even platform-only (connector 65 > 64)' (Test-ExtMcpServer -Name 'ext_Protocollo_Test' -Description 'Test server (fictional data).' -PlatformOnly) $false
    Assert-A365 'existing ext_My_Srv passes platform-only (warning: underscore, connector 57)' (Test-ExtMcpServer -Name 'ext_My_Srv' -Description 'Test server.' -PlatformOnly) $true
    Assert-A365 'ext_ProtocolloTest (62-char connector) is accepted' (Test-ExtMcpServer -Name 'ext_ProtocolloTest' -Description 'Records office of Contoso (test server, fictional data).') $true
    Assert-A365 'a 93-character server description is rejected' (Test-ExtMcpServer -Name 'ext_RecordsTest' -Description ('x' * 93)) $false
    Assert-A365 'pool base ext_ScadenzeTest is valid at NN=99' (Test-ExtMcpServer -Name 'ext_ScadenzeTest' -Numbered -Description 'Deadlines of the call (test server, fictional data).') $true
    Assert-A365 'pool base ext_ContributiTest is rejected at NN=99 (connector 64)' (Test-ExtMcpServer -Name 'ext_ContributiTest' -Numbered -Description 'Grants (test server).') $false
    Assert-A365 'Lab Builder pair ext_<12-char prefix>Anon passes platform-only (warning)' (Test-ExtMcpServer -Name 'ext_abcdefghijklAnon' -Description 'Anonymous sample server.' -PlatformOnly) $true
    Assert-A365 'tool initialize_server is reserved' (Test-McpTools -ServerName 'ext_X' -Tools @(@{ name = 'initialize_server'; description = 'x' })) $false
    Assert-A365 'duplicate tool across servers is rejected' (Test-McpTools -ServerName 'ext_A' -Tools @(@{ name = 'list_items'; description = 'List.' }) -ToolOwners @{ list_items = @('ext_B') }) $false
    Assert-A365 'camelCase tool name is rejected' (Test-McpTools -ServerName 'ext_A' -Tools @(@{ name = 'listItems'; description = 'List.' })) $false
    Assert-A365 'DW description.short of 81 characters is rejected' (Test-TeamsManifestText -NameShort 'Records Colleague' -NameFull 'Records Colleague' -DescriptionShort ('x' * 81) -DescriptionFull 'x') $false
    Assert-A365 'alias from accented names' @(if ((ConvertTo-A365Alias 'Chloé', 'Dupré-Lefèvre') -ne 'chloe.duprelefevre') { New-A365Violation 'error' 'alias' (ConvertTo-A365Alias 'Chloé', 'Dupré-Lefèvre') }) $true
    Assert-A365 'SharePoint segment with a colon is rejected' (Test-SharePointSegment 'folder' 'Call: 2026') $false
    "Self-test: $(if ($fail) { "$fail FAILURE(S)" } else { 'all passed' })"
    if ($fail) { exit 1 }
}
