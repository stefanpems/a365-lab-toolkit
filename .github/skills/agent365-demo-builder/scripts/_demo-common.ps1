# Shared helpers of the Demo Builder skills (dot-source): demo-pack loading (pack + locale merge + placeholder
# resolution), per-lab configuration/state under generated/<prefix>/demo/, tenant pinning, Microsoft Graph calls
# (az token, retries) and MSAL tokens (system browser; device code is never used).
$ErrorActionPreference = 'Stop'
$script:DemoRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
$script:DemoScriptsDir = $PSScriptRoot
$script:WizardScriptsDir = Join-Path $script:DemoRepoRoot '.github\skills\agent365-wizard\scripts'
# Directory roles the operator (demo-config adminUpn) needs on top of Global Administrator (custom security attributes).
$script:DemoOperatorEntraRoles = @('Attribute Definition Administrator', 'Attribute Assignment Administrator')
. (Join-Path $script:WizardScriptsDir 'Test-A365Names.ps1')

# --------------------------------------------------------------------------------------------- demo pack + locale
function Get-DemoPackDir([string]$Pack = 'agent-governance') {
    $root = if ($env:DEMO_PACKS_ROOT) { $env:DEMO_PACKS_ROOT } else { Join-Path $script:DemoRepoRoot 'demo-packs' }
    Join-Path $root $Pack
}

function Get-DemoPack([string]$Pack = 'agent-governance') {
    Get-Content -LiteralPath (Join-Path (Get-DemoPackDir $Pack) 'pack.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
}

# Dotted path into the locale (keys may contain '-'; numeric segments index lists).
function Resolve-DemoPath($Root, [string]$Path) {
    $node = $Root
    foreach ($seg in $Path.Split('.')) {
        if ($node -is [System.Collections.IDictionary] -and $node.Contains($seg)) { $node = $node[$seg] }
        elseif ($node -is [System.Collections.IList] -and $seg -match '^\d+$' -and [int]$seg -lt $node.Count) { $node = $node[[int]$seg] }
        else { return $null }
    }
    return $node
}

# Replaces {{a.b.c}} with the string at that path of the locale (nested placeholders: up to 5 passes).
function Expand-DemoPlaceholders($Node, $Root, $Unresolved) {
    if ($Node -is [string]) {
        $out = $Node
        for ($i = 0; $i -lt 5 -and $out.Contains('{{'); $i++) {
            $out = [regex]::Replace($out, '\{\{([A-Za-z0-9_.\-]+)\}\}', [System.Text.RegularExpressions.MatchEvaluator]{
                param($m)
                $v = Resolve-DemoPath $Root $m.Groups[1].Value
                if ($v -is [string]) { return $v }
                $Unresolved.Add($m.Groups[1].Value); return $m.Value
            })
        }
        return $out
    }
    if ($Node -is [System.Collections.IDictionary]) {
        # Keys starting with '_' are comments: never expanded.
        foreach ($k in @($Node.Keys)) { if ("$k".StartsWith('_')) { continue }; $Node[$k] = Expand-DemoPlaceholders $Node[$k] $Root $Unresolved }
        return $Node
    }
    if ($Node -is [System.Collections.IList]) {
        for ($i = 0; $i -lt $Node.Count; $i++) { $Node[$i] = Expand-DemoPlaceholders $Node[$i] $Root $Unresolved }
        return , $Node
    }
    return $Node
}

# Merged locale: core.json (root) + knowledge.json (.knowledge) + tests.json (.tests), placeholders resolved.
function Get-DemoLocale([Parameter(Mandatory)][string]$Locale, [string]$Pack = 'agent-governance') {
    $dir = Join-Path (Get-DemoPackDir $Pack) "locales\$Locale"
    $core = Join-Path $dir 'core.json'
    if (-not (Test-Path -LiteralPath $core)) { throw "Locale '$Locale' not found: $core is missing." }
    $loc = Get-Content -LiteralPath $core -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    foreach ($part in 'knowledge', 'tests') {
        $f = Join-Path $dir "$part.json"
        if (Test-Path -LiteralPath $f) { $loc[$part] = Get-Content -LiteralPath $f -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable }
    }
    $unresolved = [System.Collections.Generic.List[string]]::new()
    $null = Expand-DemoPlaceholders $loc $loc $unresolved
    $loc['_unresolved'] = @($unresolved | Select-Object -Unique)
    return $loc
}

function Get-DemoPersonaAlias($Locale, [string]$Key) {
    $p = $Locale.personas[$Key]
    if ($p.Contains('alias') -and $p.alias) { return [string]$p.alias }
    return (ConvertTo-A365Alias @($p.givenName, $p.surname))
}
function Get-DemoPersonaDisplayName($Locale, [string]$Key) { $p = $Locale.personas[$Key]; "$($p.givenName) $($p.surname)" }

function Get-DemoAgentName {
    param([Parameter(Mandatory)]$Locale, [Parameter(Mandatory)][string]$Key,
          [ValidateSet('registry', 'entra', 'copilotStudio', 'webui', 'blueprint', 'instance', 'liveInstance')][string]$Surface = 'registry',
          $State, [switch]$IncludeAliases)
    $agent = $Locale.agents[$Key]
    if (-not $agent) { throw "Agent '$Key' is not configured in the locale." }
    $name = if ($agent.names -and $agent.names[$Surface]) { [string]$agent.names[$Surface] }
            elseif ($Surface -eq 'instance') { [string]$agent.instance.displayName }
            elseif ($Surface -eq 'liveInstance') { [string]$agent.instance.liveDisplayName }
            elseif ($Surface -eq 'blueprint' -and $agent.blueprint) { [string]$agent.blueprint }
            elseif ($Surface -eq 'entra' -and $agent.identity) { [string]$agent.identity }
            else { [string]$agent.displayName }
    if ([string]::IsNullOrWhiteSpace($name)) { throw "Agent '$Key' has no configured name for '$Surface'." }
    $name
    if ($IncludeAliases -and $State.agentResolution.legacyAliases -and $agent.aliases) {
        @($agent.aliases[$Surface] | Where-Object { $_ -and $_ -cne $name } | Select-Object -Unique)
    }
}

function Assert-DemoLiveNames($Pack, $Locale) {
    foreach ($agent in @($Pack.agents | Where-Object { $_.instance.live })) {
        $null = Get-DemoAgentName -Locale $Locale -Key $agent.key -Surface liveInstance
        if ([string]::IsNullOrWhiteSpace([string]$Locale.agents[$agent.key].instance.liveAlias)) {
            throw "Missing localized instance alias: agents.$($agent.key).instance.liveAlias. Run Test-DemoPack."
        }
    }
    foreach ($rule in @($Pack.governance.adminCenter.rules | Where-Object { $_.nameKey })) {
        if (-not $Locale.governance.rules -or [string]::IsNullOrWhiteSpace([string]$Locale.governance.rules[$rule.nameKey])) {
            throw "Missing localized rule name: governance.rules.$($rule.nameKey). Run Test-DemoPack."
        }
    }
}

function Get-DemoPreparedInstanceAction($Config, $Locale, $AgentDef) {
    $instance = $AgentDef.instance
    if (-not $instance -or $instance.createFrom -ne 'teams' -or -not $instance.creator -or -not $instance.manager) {
        throw "Agent '$($AgentDef.key)' needs an explicit Teams instance creator and manager."
    }
    $name = Get-DemoAgentName -Locale $Locale -Key $AgentDef.key -Surface instance
    $alias = [string]$Locale.agents[$AgentDef.key].instance.alias
    if ([string]::IsNullOrWhiteSpace($alias)) { throw "Agent '$($AgentDef.key)' has no configured prepared-instance alias." }
    $creator = Get-DemoPersonaDisplayName $Locale $instance.creator
    $upn = Get-DemoUpn $Locale $Config $instance.creator
    $manager = Get-DemoPersonaDisplayName $Locale $instance.manager
    $template = Get-DemoAgentName -Locale $Locale -Key $AgentDef.key -Surface registry
    return @{
        Key = "prepared-instance-$($AgentDef.key)"
        Action = "Manually create the prepared Teams instance '$name' as $creator ($upn), after the AI-teammate package upload and activation."
        Where = "After the package upload/activation is verified, sign in as $upn in Teams > Apps > Built for your org > $template > Create instance. Name: '$name'; alias: '$alias'; managed by: $manager. Follow generated\$($Config.prefix)\demo\cards\20-digital-worker.md. Prepared instance only; leave live-demo instance creation on camera."
        NeededBy = "Before rehearsals of $(@($AgentDef.demos) -join ', '), after package upload/activation and before identities-refresh."
        Blocking = $false
    }
}

function ConvertTo-DemoAgentNameKey([string]$Name) {
    ($Name -replace '[\p{Pd}\p{Pi}\p{Pf}\u2212\u2032\u2033\uff02\uff07''"\s\p{Z}]', '').ToLowerInvariant()
}

function ConvertTo-DemoCanonicalAgentName([string]$Name) {
    $value = $Name -replace '[\u2012-\u2015\u2e3a\u2e3b]', ' - ' -replace '[\p{Pd}\u2212]', '-'
    $value = $value -replace '[\u2018-\u201b\u2032\u2039\u203a\uff07]', "'"
    $value = $value -replace '[\p{Pi}\p{Pf}\u2033\uff02]', '"'
    ($value -replace '[\s\p{Z}]+', ' ').Trim()
}

function Set-DemoJsonProperties {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][System.Collections.IDictionary]$Changes)
    $text = [IO.File]::ReadAllText($Path)
    $document = [Text.Json.JsonDocument]::Parse($text)
    $propertyPattern = [regex]::new('\G\s*,?\s*(?<key>"(?:\\.|[^"\\])*")\s*:\s*')
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    function Get-Indent([int]$Offset) {
        $line = $text.LastIndexOf("`n", [Math]::Max(0, $Offset - 1)) + 1
        [regex]::Match($text.Substring($line, $Offset - $line), '^[ \t]*').Value
    }
    function Get-Location([string]$PropertyPath) {
        $parts = $PropertyPath.Split('.')
        $element = $document.RootElement
        $start = 0
        for ($partIndex = 0; $partIndex -lt $parts.Count; $partIndex++) {
            if ($element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                if ($parts[$partIndex] -notmatch '^\d+$') { throw "JSON path '$PropertyPath' requires an array index." }
                $wanted = [int]$parts[$partIndex]
                if ($wanted -ge $element.GetArrayLength()) { throw "JSON array index is out of range in '$PropertyPath'." }
                $cursor = $start + 1
                $index = 0
                foreach ($item in $element.EnumerateArray()) {
                    $separator = [regex]::Match($text.Substring($cursor), '^\s*,?\s*')
                    $valueStart = $cursor + $separator.Length
                    $raw = $item.GetRawText()
                    if ($index -eq $wanted) {
                        if ($partIndex -eq $parts.Count - 1) {
                            return [pscustomobject]@{ exists = $true; start = $valueStart; length = $raw.Length; indent = (Get-Indent $valueStart); unit = '  ' }
                        }
                        $element = $item
                        $start = $valueStart
                        break
                    }
                    $cursor = $valueStart + $raw.Length
                    $index++
                }
                continue
            }
            if ($element.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw "JSON path '$PropertyPath' has a non-object parent." }
            $cursor = $start + 1
            $count = 0
            $firstIndent = $null
            $found = $false
            foreach ($property in $element.EnumerateObject()) {
                $match = $propertyPattern.Match($text, $cursor)
                if (-not $match.Success) { throw "Cannot locate JSON property '$PropertyPath' without reformatting unrelated content." }
                $valueStart = $match.Index + $match.Length
                $raw = $property.Value.GetRawText()
                if ($text.Substring($valueStart, $raw.Length) -cne $raw) { throw "JSON span mismatch for '$PropertyPath'." }
                $indent = Get-Indent $match.Groups['key'].Index
                if ($null -eq $firstIndent) { $firstIndent = $indent }
                $parentIndent = Get-Indent $start
                $unit = if ($indent.StartsWith($parentIndent) -and $indent.Length -gt $parentIndent.Length) { $indent.Substring($parentIndent.Length) } else { '  ' }
                if ($property.Name -ceq $parts[$partIndex]) {
                    if ($partIndex -eq $parts.Count - 1) {
                        return [pscustomobject]@{ exists = $true; start = $valueStart; length = $raw.Length; indent = $indent; unit = $unit }
                    }
                    $element = $property.Value
                    $start = $valueStart
                    $found = $true
                    break
                }
                $cursor = $valueStart + $raw.Length
                $count++
            }
            if ($found) { continue }
            if ($partIndex -ne $parts.Count - 1) { throw "Cannot insert '$PropertyPath': its parent is missing." }
            $parentIndent = Get-Indent $start
            $indent = if ($null -ne $firstIndent) { $firstIndent } else { $parentIndent + '  ' }
            $unit = if ($indent.Length -gt $parentIndent.Length) { $indent.Substring($parentIndent.Length) } else { '  ' }
            return [pscustomobject]@{ exists = $false; start = $cursor; length = 0; indent = $indent; unit = $unit
                parent = $start; count = $count; name = $parts[-1]; multiline = $element.GetRawText().Contains("`n") }
        }
    }
    function Format-Value($Value, [string]$Indent, [string]$Unit) {
        $lines = (ConvertTo-Json -InputObject $Value -Depth 100) -split '\r?\n'
        if ($lines.Count -eq 1) { return $lines[0] }
        $result = @($lines[0])
        $result += @($lines | Select-Object -Skip 1 | ForEach-Object {
            $spaces = [regex]::Match($_, '^ *').Length
            $Indent + ($Unit * ($spaces / 2)) + $_.Substring($spaces)
        })
        $result -join $newline
    }
    try {
        $edits = [Collections.Generic.List[object]]::new()
        $insertions = @{}
        foreach ($key in $Changes.Keys) {
            $location = Get-Location ([string]$key)
            $value = Format-Value $Changes[$key] $location.indent $location.unit
            if ($location.exists) {
                $edits.Add([pscustomobject]@{ start = $location.start; length = $location.length; value = $value })
            }
            else {
                $parent = [string]$location.parent
                if (-not $insertions.ContainsKey($parent)) {
                    $insertions[$parent] = @{ location = $location; properties = [Collections.Generic.List[string]]::new() }
                }
                $encodedKey = ConvertTo-Json -InputObject $location.name -Compress
                $insertions[$parent].properties.Add("${encodedKey}: $value")
            }
        }
        foreach ($insertion in $insertions.Values) {
            $location = $insertion.location
            $separator = if ($location.multiline) { $newline + $location.indent } else { '' }
            $prefix = if ($location.count) { ',' + $separator } else { $separator }
            $value = $prefix + ($insertion.properties -join (',' + $separator))
            $edits.Add([pscustomobject]@{ start = $location.start; length = 0; value = $value })
        }
        foreach ($edit in $edits | Sort-Object start -Descending) {
            $text = $text.Substring(0, $edit.start) + $edit.value + $text.Substring($edit.start + $edit.length)
        }
        $verification = [Text.Json.JsonDocument]::Parse($text)
        $verification.Dispose()
        [IO.File]::WriteAllText($Path, $text, [Text.UTF8Encoding]::new($false))
    }
    finally { $document.Dispose() }
}

function Test-DemoAgentNameSource {
    param([Parameter(Mandatory)][string]$Source, [string]$File = '<source>')
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Cannot check agent-name resolution in '$File': PowerShell parse errors." }
    $localeVariables = @('la')
    foreach ($assignment in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        if ($assignment.Left -is [Management.Automation.Language.VariableExpressionAst] -and $assignment.Right.Extent.Text -match '\.agents\[') {
            $localeVariables += $assignment.Left.VariablePath.UserPath
        }
    }
    $reported = @{}
    foreach ($node in $ast.FindAll({ param($item)
        $item -is [Management.Automation.Language.MemberExpressionAst] -or
        $item -is [Management.Automation.Language.ExpandableStringExpressionAst] -or
        $item -is [Management.Automation.Language.BinaryExpressionAst]
    }, $true)) {
        $parent = $node
        $allowed = $false
        while ($parent) {
            if ($parent -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $parent.Name -in 'Get-DemoAgentName', 'Test-DemoAgentNameSource') { $allowed = $true; break }
            $parent = $parent.Parent
        }
        if ($allowed) { continue }
        $text = $node.Extent.Text
        $reason = ''
        if ($node -is [Management.Automation.Language.MemberExpressionAst] -and
            $node.Member.Extent.Text -in 'displayName', 'identity', 'blueprint') {
            $root = $node.Expression.Extent.Text
            if ($root -match '\.agents\[' -or @($localeVariables | Where-Object { $root -match ('^\$' + [regex]::Escape($_) + '(?:\.instance)?$') }).Count) {
                $reason = 'Read configured agent names through Get-DemoAgentName.'
            }
        }
        elseif ($text -match '(?i)(?:\.codeName|\$codeName)' -and $text -match '(?i)\b(?:Agent|Blueprint|Identity)\b|AgentIdentity') {
            if ($text -notmatch '[\\/]') { $reason = 'Do not construct agent names from codeName or suffixes.' }
        }
        elseif ($node -is [Management.Automation.Language.BinaryExpressionAst] -and
            $text -match '\+\s*[''"]\s*(?:Agent|Identity|Blueprint)\b') {
            $reason = 'Do not append conventional agent-name suffixes.'
        }
        elseif ($node -is [Management.Automation.Language.ExpandableStringExpressionAst] -and
            ($text -match '\(Microsoft Copilot Studio\)|-AgentIdentity' -or
             $text -match '\$(?:\([^)]*\)|\{[^}]+\}|[\w:]+)[ -]+(?:Agent|Blueprint|Identity)(?=["'']|$)')) {
            $reason = 'Configure agent and provider names explicitly instead of constructing them.'
        }
        if ($reason -and -not $reported.ContainsKey($node.Extent.StartLineNumber)) {
            $reported[$node.Extent.StartLineNumber] = $true
            [pscustomobject]@{ file = $File; line = $node.Extent.StartLineNumber; message = $reason }
        }
    }
}

function Set-DemoAgentIds {
    param([Parameter(Mandatory)][string]$Prefix, [Parameter(Mandatory)]$State,
          [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][System.Collections.IDictionary]$Ids)
    if (-not $State.agents) { $State['agents'] = [ordered]@{} }
    if (-not $State.agents.Contains($Key)) { $State.agents[$Key] = [ordered]@{} }
    $entry = $State.agents[$Key]
    $changed = $false
    foreach ($field in $Ids.Keys) {
        if ($null -eq $Ids[$field] -or $Ids[$field] -eq '') { continue }
        if (($entry[$field] | ConvertTo-Json -Depth 10 -Compress) -cne ($Ids[$field] | ConvertTo-Json -Depth 10 -Compress)) {
            $entry[$field] = $Ids[$field]
            $changed = $true
        }
    }
    if ($changed) { Save-DemoLabState $Prefix $State }
}

function Get-DemoAgentConfig($Locale, [string]$Prefix, $AgentDef) {
    $codeName = [string]$Locale.agents[$AgentDef.key].codeName
    if (-not $codeName) { return $null }
    $path = Join-Path $script:DemoRepoRoot "generated\$Prefix\$codeName\a365.generated.config.json"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $raw = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $public = [ordered]@{}
    foreach ($field in 'agentBlueprintId', 'agentBlueprintObjectId', 'agenticAppId', 'agentIdentityId', 'agentRegistrationId', 'botId', 'messagingEndpoint') {
        if ($raw[$field]) { $public[$field] = $raw[$field] }
    }
    return [pscustomobject]$public
}

function Initialize-DemoAgentState($Config, $Locale, $State, $AgentDef) {
    $key = [string]$AgentDef.key
    $entry = if ($State.agents -and $State.agents.Contains($key)) { $State.agents[$key] } else { @{} }
    $ids = [ordered]@{}
    $generated = Get-DemoAgentConfig $Locale $Config.prefix $AgentDef
    if ($generated) {
        $fields = @{ blueprintId = 'agentBlueprintObjectId'; blueprintAppId = 'agentBlueprintId'
            identityAppId = 'agenticAppId'; identityId = 'agentIdentityId'; registrationId = 'agentRegistrationId' }
        foreach ($field in $fields.Keys) {
            if (-not $entry[$field] -and $generated.($fields[$field])) { $ids[$field] = [string]$generated.($fields[$field]) }
        }
    }
    $legacy = @(if ($State.governance.identities) { $State.governance.identities[$key] | Where-Object { $_.identityId } })
    if ($legacy.Count) {
        if ($AgentDef.sponsorOn -eq 'instance') {
            if (-not $entry.instanceIdentityIds) { $ids['instanceIdentityIds'] = @($legacy | ForEach-Object { [string]$_.identityId }) }
        }
        else {
            if (-not $entry.identityId) { $ids['identityId'] = [string]$legacy[0].identityId }
            if ([string]$AgentDef.variant -like 'FD-*' -and $legacy.Count -gt 1 -and -not $entry.projectIdentityId) {
                $ids['projectIdentityId'] = [string]$legacy[1].identityId
            }
        }
    }
    if ($ids.Count) { Set-DemoAgentIds -Prefix $Config.prefix -State $State -Key $key -Ids $ids }
}

$script:DemoAgentLookups = [System.Collections.Generic.List[object]]::new()
function Add-DemoAgentLookup($Config, [string]$Key, [string]$Object, [string]$Method, [string]$Name, [string]$Id) {
    $script:DemoAgentLookups.Add([pscustomobject]@{ key = $Key; object = $Object; method = $Method; name = $Name; id = $Id })
    if ($Method -in 'name', 'alias') {
        Write-DemoLog $Config.prefix "Agent '$Key' ($Object): exact $Method fallback '$Name'; saved id '$Id'." 'WARN'
    }
}

function Get-DemoGraphObject([string]$Uri, [string]$Token) {
    $result = Invoke-DemoGraph GET $Uri -Token $Token -NoThrow
    if ($result -and $result.PSObject.Properties['error'] -and $result.PSObject.Properties['status']) {
        if ($result.status -eq 404) { return $null }
        throw $result.error
    }
    return $result
}

function Resolve-DemoAgentObject {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Locale, [Parameter(Mandatory)]$State,
          [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$IdField,
          [Parameter(Mandatory)][string]$Surface, [Parameter(Mandatory)][scriptblock]$ReadById,
          [Parameter(Mandatory)][scriptblock]$FindByName, [string]$IdProperty = 'id',
          [string]$NameProperty = 'displayName', [string[]]$CandidateIds = @())
    $known = if ($State.agents -and $State.agents.Contains($Key)) { [string]$State.agents[$Key][$IdField] } else { '' }
    foreach ($id in @(@($known) + $CandidateIds | Where-Object { $_ } | Select-Object -Unique)) {
        $object = & $ReadById $id
        if ($object -and [string]::IsNullOrWhiteSpace([string]$object.$IdProperty)) {
            throw "Agent '$Key' ($IdField): the id lookup returned an object without '$IdProperty'."
        }
        if ($object -and $object.$IdProperty) {
            $resolved = [string]$object.$IdProperty
            Set-DemoAgentIds $Config.prefix $State $Key @{ $IdField = $resolved }
            Add-DemoAgentLookup $Config $Key $IdField 'id' '' $resolved
            return $object
        }
        if ($id -eq $known) { Write-DemoLog $Config.prefix "Agent '$Key' ($IdField): recorded id '$id' no longer exists; checking remaining id candidates before exact-name fallback." 'WARN' }
    }
    $names = @(Get-DemoAgentName -Locale $Locale -Key $Key -Surface $Surface -State $State -IncludeAliases)
    $aliases = [System.Collections.Generic.List[object]]::new()
    foreach ($name in $names) {
        $hits = @(& $FindByName $name | Where-Object { $_ -and $_.$NameProperty -ceq $name })
        if (@($hits | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.$IdProperty) }).Count) {
            throw "Agent '$Key' ($IdField): the exact-name lookup returned an object without '$IdProperty'."
        }
        if ($hits.Count -gt 1) { throw "Agent '$Key' ($IdField): exact name '$name' is ambiguous ($($hits.Count) objects). Record the intended id in state.json." }
        if ($hits.Count -eq 0) { continue }
        if ($name -ceq $names[0]) {
            $id = [string]$hits[0].$IdProperty
            Set-DemoAgentIds $Config.prefix $State $Key @{ $IdField = $id }
            Add-DemoAgentLookup $Config $Key $IdField 'name' $name $id
            return $hits[0]
        }
        $aliases.Add([pscustomobject]@{ name = $name; value = $hits[0] })
    }
    $distinct = @($aliases | Group-Object { [string]$_.value.$IdProperty })
    if ($distinct.Count -gt 1) { throw "Agent '$Key' ($IdField): legacy aliases match different objects. Record the intended id in state.json." }
    if ($aliases.Count) {
        $match = $aliases[0]
        $id = [string]$match.value.$IdProperty
        Set-DemoAgentIds $Config.prefix $State $Key @{ $IdField = $id }
        Add-DemoAgentLookup $Config $Key $IdField 'alias' $match.name $id
        return $match.value
    }
    Add-DemoAgentLookup $Config $Key $IdField 'missing' $names[0] ''
    return $null
}

function Get-DemoAgentReference($Locale, $State, [string]$Key, [string]$Surface = 'registry') {
    $name = Get-DemoAgentName -Locale $Locale -Key $Key -Surface $Surface
    $entry = $State.agents[$Key]
    if ($Surface -eq 'copilotStudio' -and $entry.botId -and $entry.environmentId) {
        return "[$name](https://copilotstudio.microsoft.com/environments/$($entry.environmentId)/bots/$($entry.botId)/overview)"
    }
    if ($Surface -in 'registry', 'webui' -and $entry.titleId) { return "[$name](https://m365.cloud.microsoft/chat/?titleId=$([uri]::EscapeDataString($entry.titleId)))" }
    $field = @{ registry = 'titleId'; webui = 'titleId'; copilotStudio = 'botId'
        entra = 'identityId'; blueprint = 'blueprintId'; instance = 'instanceUserId'; liveInstance = 'liveInstanceUserId' }[$Surface]
    if ($entry.$field) { return "$name (${field}: $($entry.$field))" }
    return "$name ($field not recorded yet)"
}

$script:DemoOrgUrls = @{}
function Get-DemoCopilotStudioOrgUrl($Config, [string]$EnvironmentId) {
    if (-not $EnvironmentId) { throw 'No Copilot Studio environment id is configured.' }
    $cacheKey = "$($Config.tenantId)/$EnvironmentId"
    if (-not $script:DemoOrgUrls.ContainsKey($cacheKey)) {
        $token = Get-DemoAzToken -Resource 'https://service.powerapps.com/' -TenantId $Config.tenantId
        $environment = Invoke-DemoGraph GET "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/environments/${EnvironmentId}?api-version=2020-10-01" -Token $token
        $url = [string]$environment.properties.linkedEnvironmentMetadata.instanceUrl
        if (-not $url) { throw "Environment '$EnvironmentId' has no Dataverse instance URL." }
        $script:DemoOrgUrls[$cacheKey] = $url.TrimEnd('/')
    }
    return $script:DemoOrgUrls[$cacheKey]
}

function Resolve-DemoCopilotStudioBot($Config, $Locale, $State, $AgentDef) {
    $environmentId = if ($AgentDef.environment -eq 'default') { [string]$Config.copilotStudio.defaultEnvironmentId } else { [string]$Config.copilotStudio.paygEnvironmentId }
    $entry = $State.agents[$AgentDef.key]
    if ($entry.botId -and $entry.environmentId -and $entry.environmentId -ne $environmentId) {
        throw "Agent '$($AgentDef.key)' is recorded in environment '$($entry.environmentId)', not '$environmentId'. Reconcile state.json before continuing."
    }
    $org = Get-DemoCopilotStudioOrgUrl $Config $environmentId
    $token = Get-DemoAzToken -Resource $org -TenantId $Config.tenantId
    $columns = 'botid,name,publishedon,modifiedon,synchronizationstatus'
    $bot = Resolve-DemoAgentObject -Config $Config -Locale $Locale -State $State -Key $AgentDef.key -IdField botId -Surface copilotStudio -IdProperty botid -NameProperty name -ReadById {
        param($id) Get-DemoGraphObject "$org/api/data/v9.2/bots($id)?`$select=$columns" $token
    } -FindByName {
        param($name)
        $filter = [uri]::EscapeDataString("name eq '$($name.Replace("'", "''"))'")
        (Invoke-DemoGraph GET "$org/api/data/v9.2/bots?`$select=$columns&`$filter=$filter" -Token $token).value
    }
    if ($bot) { Set-DemoAgentIds $Config.prefix $State $AgentDef.key @{ environmentId = $environmentId; dataverseUrl = $org } }
    return $bot
}

# --------------------------------------------------------------------------------------------- operator texts
# UPN of a persona key ('admin' = the operator admin account of the config).
function Get-DemoUpn($Locale, $Config, [string]$Key) { if ($Key -eq 'admin') { return [string]$Config.adminUpn }; "$(Get-DemoPersonaAlias $Locale $Key)@$($Config.domain)" }
function Get-DemoSlotText([string]$Id, [string]$Pack = 'agent-governance') { "[operator slot ${Id}: fill it from operator-slots.json - see demo-packs/$Pack/OPERATOR-SLOTS.md]" }
function ConvertTo-DemoText($V) { if ($null -eq $V) { return $null }; if ($V -is [System.Collections.IList]) { return (@($V) -join ', ') }; return [string]$V }

# Expands the placeholders of an English operator text (cards, manual resets, guide): {{locale.path}},
# {upn:<persona>|admin}, {name:<persona>|admin}, {agent:<key>}, {group:<key>}, {folder:<key>}, {cfg:<path>},
# {state:<path>}, {pack:<path>}, {slot:<id>}. An unresolved value becomes '<missing ...>'.
function Expand-DemoText([string]$Text, $Locale, $Config, $State, $Pack) {
    $t = [regex]::Replace($Text, '\{\{([A-Za-z0-9_.\-]+)\}\}', [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $path = $m.Groups[1].Value
        $v = if ($path -match '^agents\.([^.]+)\.(displayName|identity|blueprint|instance\.displayName|instance\.liveDisplayName)$') {
            $surface = switch ($Matches[2]) { 'identity' { 'entra' }; 'blueprint' { 'blueprint' }; 'instance.displayName' { 'instance' }; 'instance.liveDisplayName' { 'liveInstance' }; default { 'registry' } }
            Get-DemoAgentName -Locale $Locale -Key $Matches[1] -Surface $surface
        }
        else { ConvertTo-DemoText (Resolve-DemoPath $Locale $path) }
        if ($null -eq $v) { "<missing $path>" } else { $v }
    })
    return [regex]::Replace($t, '\{(upn|name|agent|group|folder|cfg|state|pack|slot|tagged):([A-Za-z0-9_.\-]+)\}', [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $k = $m.Groups[2].Value
        $known = $k -eq 'admin' -or ($Locale.personas -and $Locale.personas.Contains($k))
        $v = switch ($m.Groups[1].Value) {
            'upn' { if ($known) { Get-DemoUpn $Locale $Config $k } }
            'name' { if ($k -eq 'admin') { 'the tenant administrator' } elseif ($known) { Get-DemoPersonaDisplayName $Locale $k } }
            'agent' { Get-DemoAgentName -Locale $Locale -Key $k }
            'group' { [string]$Locale.groups[$k].displayName }
            'folder' { [string]$Locale.knowledge.folders[$k] }
            'cfg' { ConvertTo-DemoText (Resolve-DemoPath $Config $k) }
            'state' { ConvertTo-DemoText (Resolve-DemoPath $State $k) }
            'pack' { ConvertTo-DemoText (Resolve-DemoPath $Pack $k) }
            'slot' { Get-DemoSlotText $k ([string]$Config.pack) }
            'tagged' { (@($Pack.agents | Where-Object { @($_.tags) -contains $k } | ForEach-Object { Get-DemoAgentName -Locale $Locale -Key $_.key }) -join ', ') }
        }
        if ($v) { $v } else { "<missing $($m.Value)>" }
    })
}

# --------------------------------------------------------------------------------------------- per-lab config/state
function Get-DemoLabDir([Parameter(Mandatory)][string]$Prefix) { Join-Path $script:DemoRepoRoot "generated\$Prefix\demo" }

function Read-DemoConfig([Parameter(Mandatory)][string]$Prefix) {
    $f = Join-Path (Get-DemoLabDir $Prefix) 'demo-config.json'
    if (-not (Test-Path -LiteralPath $f)) { throw "Demo config not found: $f. Create it with New-DemoConfig.ps1 (Demo Builder, phase 1)." }
    $c = Get-Content -LiteralPath $f -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    Use-DemoAzProfile $c
    return $c
}

# Lab-private Azure CLI profile (demo-config azConfigDir, New-DemoConfig.ps1 -IsolatedAzProfile): sets AZURE_CONFIG_DIR
# for this process and its children (az, a365, the Lab Builder scripts), so the lab's az login / account set never
# change the machine-wide default of other sessions. Extensions stay shared (AZURE_EXTENSION_DIR = the default folder).
function Use-DemoAzProfile($Config) {
    $configured = if ($env:DEMO_SESSION_AUTH_DIR) { Join-Path $env:DEMO_SESSION_AUTH_DIR 'azure' } else { [string]$Config.azConfigDir }
    if (-not $configured) { return }
    $dir = if ([IO.Path]::IsPathRooted($configured)) { $configured } else { Join-Path $script:DemoRepoRoot $configured }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Set-DemoAzProfileDefaults $dir
    $env:AZURE_CONFIG_DIR = $dir
    if (-not $env:AZURE_EXTENSION_DIR) { $env:AZURE_EXTENSION_DIR = Join-Path $HOME '.azure\cliextensions' }
}

# Settings of the lab-private az profile (its own 'config' INI file): browser sign-in instead of the Windows account
# picker (WAM), which can stay hidden behind other windows while the operator waits; no interactive subscription
# picker after az login. Idempotent; other keys are kept.
function Set-DemoAzProfileDefaults([Parameter(Mandatory)][string]$Dir) {
    $f = Join-Path $Dir 'config'
    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $f) { foreach ($l in (Get-Content -LiteralPath $f -Encoding utf8)) { $lines.Add($l) } }
    $want = [ordered]@{ enable_broker_on_windows = 'false'; login_experience_v2 = 'off' }
    $core = $lines.IndexOf('[core]')
    if ($core -lt 0) { if ($lines.Count -and $lines[$lines.Count - 1]) { $lines.Add('') }; $lines.Add('[core]'); $core = $lines.Count - 1 }
    $end = $core + 1; while ($end -lt $lines.Count -and $lines[$end] -notmatch '^\[') { $end++ }
    $changed = $false
    foreach ($k in $want.Keys) {
        $i = -1; for ($j = $core + 1; $j -lt $end; $j++) { if ($lines[$j] -match "^\s*$k\s*=") { $i = $j } }
        $line = "$k = $($want[$k])"
        if ($i -ge 0) { if ($lines[$i] -ne $line) { $lines[$i] = $line; $changed = $true } }
        else { $lines.Insert($end, $line); $end++; $changed = $true }
    }
    if ($changed -or -not (Test-Path -LiteralPath $f)) { $lines | Set-Content -LiteralPath $f -Encoding utf8 }
}

# The command line the operator (or the agent) runs to sign in to the lab's az profile.
function Get-DemoAzLoginCommand($Config) {
    $p = if ($env:DEMO_SESSION_AUTH_DIR -or $Config.azConfigDir) { "`$env:AZURE_CONFIG_DIR='$($env:AZURE_CONFIG_DIR)'; `$env:AZURE_EXTENSION_DIR='$($env:AZURE_EXTENSION_DIR)'; " } else { '' }
    "${p}az login --tenant $($Config.tenantId)"
}

function Read-DemoLabState([Parameter(Mandatory)][string]$Prefix) {
    $f = Join-Path (Get-DemoLabDir $Prefix) 'state.json'
    if (Test-Path -LiteralPath $f) {
        $state = Get-Content -LiteralPath $f -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        if (-not $state.Contains('agentResolution')) {
            $built = ($state.agents.Count -gt 0) -or ($state.governance.identities.Count -gt 0) -or
                ($state.phases.setup.agents.status -in 'started', 'done')
            if (-not $built) {
                $runDir = Split-Path (Get-DemoLabDir $Prefix) -Parent
                $built = @(Get-ChildItem -LiteralPath $runDir -Directory | Where-Object {
                    Test-Path -LiteralPath (Join-Path $_.FullName 'a365.generated.config.json')
                }).Count -gt 0
            }
            $state['agentResolution'] = [ordered]@{ version = 1; legacyAliases = $built }
        }
        return $state
    }
    return [ordered]@{ prefix = $Prefix; agentResolution = [ordered]@{ version = 1; legacyAliases = $false }
        users = [ordered]@{}; groups = [ordered]@{}; agents = [ordered]@{}; mcp = [ordered]@{ servers = [ordered]@{}; pool = @() }; knowledge = [ordered]@{}; governance = [ordered]@{} }
}

function Save-DemoLabState([Parameter(Mandatory)][string]$Prefix, [Parameter(Mandatory)]$State) {
    $dir = Get-DemoLabDir $Prefix
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $State['updated'] = (Get-Date).ToString('s')
    $State | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath (Join-Path $dir 'state.json') -Encoding utf8
}

function Write-DemoLog([Parameter(Mandatory)][string]$Prefix, [Parameter(Mandatory)][string]$Message, [string]$Level = 'INFO') {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    $dir = Join-Path $script:DemoRepoRoot "generated\$Prefix"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Add-Content -LiteralPath (Join-Path $dir 'wizard-progress.log') -Value "$line (demo)" -Encoding utf8
}

# --------------------------------------------------------------------------------------------- tenant + Graph
function Assert-DemoTenant($Config) {
    Use-DemoAzProfile $Config
    if ($Config.subscriptionId) { az account set --subscription $Config.subscriptionId 2>$null | Out-Null }
    $tid = ([string](az account show --query tenantId -o tsv 2>$null)).Trim()
    if ($tid -ne $Config.tenantId) { throw "Tenant mismatch: az is on '$tid', the demo config expects '$($Config.tenantId)'. Sign in (interactive browser): $(Get-DemoAzLoginCommand $Config)" }
}

$script:DemoTokenCache = @{}
function Get-DemoAzToken([string]$Resource = 'https://graph.microsoft.com', [string]$TenantId) {
    $c = $script:DemoTokenCache[$Resource]
    if ($c -and $c.ExpiresOn -gt (Get-Date).AddMinutes(5)) { return $c.Token }
    $azArgs = @('account', 'get-access-token', '--resource', $Resource, '-o', 'json')
    if ($TenantId) { $azArgs += @('--tenant', $TenantId) }
    $raw = az @azArgs | ConvertFrom-Json
    if (-not $raw.accessToken) { throw "az could not get a token for $Resource (try: az login --tenant <id> --scope $Resource/.default)." }
    $exp = if ($raw.expires_on) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$raw.expires_on).LocalDateTime } else { [datetime]$raw.expiresOn }
    $script:DemoTokenCache[$Resource] = @{ Token = $raw.accessToken; ExpiresOn = $exp }
    return $raw.accessToken
}

# MSAL public-client token, system browser on first use, persistent cache (py/msal_token.py). Default client:
# Microsoft Graph Command Line Tools. Used for the delegated scopes az cannot obtain (agent registry, risk, ...).
function Get-DemoMsalToken {
    param([Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string[]]$Scopes, [Parameter(Mandatory)][string]$Prefix,
          [string]$LoginHint, [string]$ClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e', [string]$CacheName = 'msal_graph_cache.json',
          [switch]$SilentOnly, [switch]$ForceRefresh)
    # -SilentOnly (dry runs): never opens a browser; returns $null when no cached sign-in serves the scopes.
    $cache = if ($env:DEMO_SESSION_AUTH_DIR) { Join-Path $env:DEMO_SESSION_AUTH_DIR "msal\$Prefix\$CacheName" }
             else { Join-Path (Get-DemoLabDir $Prefix) "secrets\$CacheName" }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cache) | Out-Null
    $pyArgs = @('--tenant', $TenantId, '--client', $ClientId, '--scopes', ($Scopes -join ','), '--cache', $cache, '--hint', "$LoginHint")
    if ($SilentOnly) { $pyArgs += '--silent-only' }
    if ($ForceRefresh) { $pyArgs += '--force-refresh' }
    $tok = python (Join-Path $script:DemoScriptsDir 'py\msal_token.py') @pyArgs
    if ($SilentOnly -and $LASTEXITCODE -eq 3) { return $null }
    if ($LASTEXITCODE -ne 0 -or -not $tok) { throw 'MSAL token acquisition failed (see the message above).' }
    return [string]($tok | Select-Object -Last 1)
}

# Drops the cached access tokens of the LAB-PRIVATE az profile (py/az_cache_drop.py; refresh tokens kept), so that az
# mints new ones: the fix of a CAE revocation (az keeps its 24 h token even after a new login). Never on the
# machine-wide profile (other sessions). Returns $true when the cache was processed.
function Reset-DemoAzCachedTokens([string]$Resource = 'graph.microsoft.com') {
    if (-not $env:AZURE_CONFIG_DIR) { return $false }
    $script:DemoTokenCache = @{}
    $o = python (Join-Path $script:DemoScriptsDir 'py\az_cache_drop.py') --config-dir $env:AZURE_CONFIG_DIR --resource $Resource 2>&1
    $ok = $LASTEXITCODE -eq 0
    Write-Host "  az token cache of the lab profile: $(($o | Out-String).Trim())"
    return $ok
}

# READ-ONLY check of the lab's az session before asking the operator for a new sign-in: account, a Graph call and an
# ARM call. A sign-in is requested only when one of them fails (an unneeded browser sign-in can even pick the wrong
# account through the SSO of the default browser profile).
function Test-DemoAzSession($Config) {
    Use-DemoAzProfile $Config
    $r = [ordered]@{ account = ''; tenantOk = $false; graphOk = $false; armOk = $false; message = '' }
    $acc = az account show --query "{t:tenantId,u:user.name}" -o json 2>$null | ConvertFrom-Json
    if ($acc) { $r.account = [string]$acc.u; $r.tenantOk = [string]$acc.t -eq [string]$Config.tenantId }
    if ($r.tenantOk) {
        $g = Invoke-DemoGraph GET 'https://graph.microsoft.com/v1.0/organization?$select=id' -NoThrow -MaxRetries 1
        $r.graphOk = $g -and -not $g.PSObject.Properties['error']
        az group list --subscription ([string]$Config.subscriptionId) --query '[0].name' -o tsv 2>$null | Out-Null
        $r.armOk = $LASTEXITCODE -eq 0
    }
    $r.message = if ($r.tenantOk -and $r.graphOk -and $r.armOk) { "az session OK ($($r.account))" } else { "az session NOT usable (account '$($r.account)', tenant $($r.tenantOk), Graph $($r.graphOk), ARM $($r.armOk)): $(Get-DemoAzLoginCommand $Config)" }
    return [pscustomobject]$r
}

# REST call with retries on throttling/transient errors. -Token overrides the az Graph token.
function Invoke-DemoGraph {
    param([Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string]$Method, [Parameter(Mandatory)][string]$Uri,
          $Body, [string]$Token, [hashtable]$Headers, [switch]$All, [int]$MaxRetries = 5, [switch]$NoThrow)
    $results = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    do {
        $attempt = 0
        while ($true) {
            $bearer = if ($Token) { $Token } else { Get-DemoAzToken }
            $h = @{ Authorization = "Bearer $bearer" }
            if ($Headers) { foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] } }
            $p = @{ Method = $Method; Uri = $next; Headers = $h; ErrorAction = 'Stop' }
            if ($null -ne $Body) { $p.ContentType = 'application/json; charset=utf-8'; $p.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 30 -Compress } }
            try { $resp = Invoke-RestMethod @p; break }
            catch {
                $status = $null; try { $status = [int]$_.Exception.Response.StatusCode } catch { }
                $attempt++
                if ($attempt -le $MaxRetries -and (($null -eq $status) -or ($status -in 429, 500, 502, 503, 504))) { Start-Sleep -Seconds ([Math]::Min(60, [Math]::Pow(2, $attempt))); continue }
                $msg = "$Method $next failed ($status): $($_.ErrorDetails.Message)"
                $cae = $status -eq 401 -and -not $Token -and "$($_.ErrorDetails.Message)" -match 'InteractionRequired|TokenIssuedBeforeRevocationTimestamp|TokenCreatedWithOutdated|AADSTS50173|AADSTS700082'
                if ($cae -and -not $script:DemoCaeRetried -and $env:AZURE_CONFIG_DIR) {
                    # CAE revocation: az keeps returning its cached 24 h token even after a new login. Drop the cached
                    # access tokens of the lab profile (refresh token kept) and retry once with a new one.
                    $script:DemoCaeRetried = $true
                    Write-Host '  the az access token was revoked (CAE): dropping the cached tokens of the lab az profile and retrying once' -ForegroundColor Yellow
                    if (Reset-DemoAzCachedTokens 'graph.microsoft.com') { $attempt = 0; continue }
                }
                if ($cae) {
                    # Still refused: the refresh token itself is revoked or expired -> a new interactive sign-in.
                    $msg += " | The az sign-in is no longer valid: $(if ($env:AZURE_CONFIG_DIR) { "`$env:AZURE_CONFIG_DIR='$($env:AZURE_CONFIG_DIR)'; " })az login --tenant <tenant id>   (interactive browser), then re-run (a stale cached token is dropped automatically)"
                }
                if ($NoThrow) { return [pscustomobject]@{ error = $msg; status = $status } }
                throw $msg
            }
        }
        if ($All -and $resp -and $resp.PSObject.Properties['value']) { foreach ($v in $resp.value) { $results.Add($v) }; $next = $resp.'@odata.nextLink' }
        else { return $resp }
    } while ($next)
    return $results.ToArray()
}

# --------------------------------------------------------------------------------------------- demo MCP backends
# Azure names of the demo MCP backends. Own RG + component tag 'demo-mcp' (NOT 'custom-mcp': that tag means the
# Lab Builder anon/auth sample pair to discover-environment.ps1 and to the Web UI & MCP Remover).
function Get-DemoMcpAzureNames([Parameter(Mandatory)][string]$Prefix) {
    $p = $Prefix.ToLowerInvariant()
    [ordered]@{ resourceGroup = "$p-demomcp-rg"; environment = "$p-demomcp-cae"; appPrefix = "$p-dmcp-"; component = 'demo-mcp' }
}

# Tool names the locale declares for one backend key: the exact set the backend must expose.
function Get-DemoMcpDeclaredTools($Locale, [Parameter(Mandatory)][string]$Key) {
    $s = $Locale.mcp.servers[$Key]
    return @($s.tools.Keys | ForEach-Object { [string]$s.tools[$_].name })
}

# MCP initialize + tools/list against a NoAuth streamable-HTTP backend (.../mcp); returns the exposed tool names.
function Get-DemoMcpBackendTools([Parameter(Mandatory)][string]$Url) {
    $h = @{ Accept = 'application/json, text/event-stream' }
    $parse = { param($resp) $c = [string]$resp.Content; if ($c -match '(?m)^data:\s*(\{.*\})\s*$') { $Matches[1] | ConvertFrom-Json } else { $c | ConvertFrom-Json } }
    $init = @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{ protocolVersion = '2025-03-26'; capabilities = @{}; clientInfo = @{ name = 'demo-builder-check'; version = '1' } } } | ConvertTo-Json -Depth 5 -Compress
    $r1 = Invoke-WebRequest -Method POST -Uri $Url -Headers $h -ContentType 'application/json' -Body $init -UseBasicParsing -TimeoutSec 60
    $sid = [string]($r1.Headers['mcp-session-id'] | Select-Object -First 1)
    if ($sid) { $h['mcp-session-id'] = $sid }
    $null = Invoke-WebRequest -Method POST -Uri $Url -Headers $h -ContentType 'application/json' -Body '{"jsonrpc":"2.0","method":"notifications/initialized"}' -UseBasicParsing -TimeoutSec 30
    $r2 = Invoke-WebRequest -Method POST -Uri $Url -Headers $h -ContentType 'application/json' -Body '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' -UseBasicParsing -TimeoutSec 60
    return @((& $parse $r2).result.tools | ForEach-Object { [string]$_.name })
}

# --------------------------------------------------------------------------------------------- user-actions register
# Every action the USER must do outside the scripts (portal steps, sign-ins, approvals, uploads, tests) is recorded in
# generated/<prefix>/demo/user-actions.json (source of truth) and rendered to USER-ACTIONS.md after every change, so the
# register is the same whatever agent, model or session runs the build. Rows are keyed and idempotent: a known key only
# updates the texts and the flags it is given; ids A1, A2... are assigned once and never renumbered; a DONE row is kept.
function Get-DemoUserActionsPath([Parameter(Mandatory)][string]$Prefix) { Join-Path (Get-DemoLabDir $Prefix) 'user-actions.json' }

function Read-DemoUserActions([Parameter(Mandatory)][string]$Prefix) {
    $f = Get-DemoUserActionsPath $Prefix
    $r = if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } else { $null }
    if (-not $r) { $r = [ordered]@{} }
    if (-not $r.Contains('meta') -or -not $r.meta) { $r['meta'] = [ordered]@{} }
    $r['actions'] = @($r['actions'] | Where-Object { $_ })
    return $r
}

function Format-DemoUserActionCell([string]$Text) { if (-not $Text) { return '' }; (($Text -replace '\r?\n', ' ') -replace '\|', '\|').Trim() }

# Renders USER-ACTIONS.md (English) from the register. Status column: DONE, TODO, or **BLOCKING** for a blocking TODO.
function Write-DemoUserActionsFile([Parameter(Mandatory)][string]$Prefix, $Register) {
    if (-not $Register) { $Register = Read-DemoUserActions $Prefix }
    $cfgFile = Join-Path (Get-DemoLabDir $Prefix) 'demo-config.json'
    $cfg = if (Test-Path -LiteralPath $cfgFile) { Read-DemoConfig $Prefix } else { @{} }
    $md = [System.Collections.Generic.List[string]]::new()
    $md.Add("# $Prefix - actions for the user")
    $md.Add('')
    $md.Add('> Generated from user-actions.json by the Demo Builder scripts: do not edit by hand. Add or update a row with')
    $md.Add("> ``Set-DemoUserAction.ps1 -Prefix $Prefix -Key <key> ...``; manual phase steps are marked done with ``Invoke-DemoPhase.ps1 -Done <step>``.")
    $md.Add('')
    $md.Add("Tenant ``$($cfg.tenantId)``, subscription ``$($cfg.subscriptionId)``.$(if ($Register.meta.webUiUrl) { " Web UI: $($Register.meta.webUiUrl)" })")
    $md.Add('Status: `TODO`, `DONE`, or **BLOCKING** (the build cannot go on until it is done). "Needed by" = the first step or demo that')
    $md.Add("really needs it. Cards: ``generated/$Prefix/demo/cards/`` (each says who does what, where, and the expected result).")
    $md.Add('')
    $md.Add('| # | Status | Action | Where / how | Needed by |')
    $md.Add('|---|---|---|---|---|')
    foreach ($a in $Register.actions) {
        $st = if ($a.status -eq 'DONE') { 'DONE' } elseif ($a.blocking) { '**BLOCKING**' } else { 'TODO' }
        $md.Add(('| {0} | {1} | {2} | {3} | {4} |' -f $a.id, $st, (Format-DemoUserActionCell $a.action), (Format-DemoUserActionCell $a.where), (Format-DemoUserActionCell $a.neededBy)))
    }
    $path = Join-Path (Get-DemoLabDir $Prefix) 'USER-ACTIONS.md'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    $md | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

# Adds or updates one row (by -Key) and re-renders USER-ACTIONS.md. -Blocking/-Status are applied only when given, so a
# script re-registering an action never reopens a DONE row. A new row needs -Action. Returns the row.
function Set-DemoUserAction {
    param([Parameter(Mandatory)][string]$Prefix, [Parameter(Mandatory)][string]$Key, [string]$Action, [string]$Where,
          [string]$NeededBy, [object]$Blocking = $null, [ValidateSet('', 'TODO', 'DONE')][string]$Status = '', [string]$WebUiUrl)
    $reg = Read-DemoUserActions $Prefix
    if ($WebUiUrl) { $reg.meta['webUiUrl'] = $WebUiUrl }
    $row = $reg.actions | Where-Object { $_.key -eq $Key } | Select-Object -First 1
    if (-not $row) {
        if (-not $Action) { throw "User action '$Key' does not exist yet: -Action is required to create it." }
        $n = 0; foreach ($a in $reg.actions) { if ([string]$a.id -match '^A(\d+)$' -and [int]$Matches[1] -gt $n) { $n = [int]$Matches[1] } }
        $row = [ordered]@{ id = "A$($n + 1)"; key = $Key; status = 'TODO'; blocking = $false; action = ''; where = ''; neededBy = ''; added = (Get-Date).ToString('s') }
        $reg.actions = @($reg.actions) + @($row)
    }
    if ($Action) { $row['action'] = $Action }
    if ($PSBoundParameters.ContainsKey('Where')) { $row['where'] = $Where }
    if ($PSBoundParameters.ContainsKey('NeededBy')) { $row['neededBy'] = $NeededBy }
    if ($null -ne $Blocking) { $row['blocking'] = [bool]$Blocking }
    if ($Status) {
        if ($Status -eq 'DONE' -and $row.status -ne 'DONE') { $row['doneAt'] = (Get-Date).ToString('s') }
        if ($Status -eq 'TODO') { $row.Remove('doneAt') }
        $row['status'] = $Status
    }
    $row['updated'] = (Get-Date).ToString('s')
    $f = Get-DemoUserActionsPath $Prefix
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f) | Out-Null
    $tmp = "$f.tmp"
    $reg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $f -Force
    $null = Write-DemoUserActionsFile $Prefix $reg
    return $row
}

# Ids of the demos of the pack that involve the given agents or portals (used for "Needed by").
function Get-DemoIdsFor($Pack, [string[]]$AgentKeys = @(), [string[]]$Portals = @()) {
    @($Pack.demos | Where-Object { (@($_.agents) | Where-Object { $AgentKeys -contains $_ }).Count -or (@($_.portal) | Where-Object { $Portals -contains $_ }).Count } |
        ForEach-Object { [string]$_.id } | Select-Object -Unique | Sort-Object { $_.Substring(0, 1) }, { [int]($_ -replace '\D', '') })
}

# --------------------------------------------------------------------------------------------- license roles
# A license role of demo-config licenseSkus is ONE SKU part number or a BUNDLE 'SKU1+SKU2+...' whose service plans add
# up to the role (for example E5 without Teams + Microsoft 365 Copilot + Frontier, when the tenant has no E7).
function Get-DemoSkuParts([string]$Value) { @(($Value -split '\+') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

# License roles of a persona; demo-config teamsForAllPersonas adds Teams to the personas whose pack entry has none
# (the leavers) so that every demo person can use Teams.
function Get-DemoPersonaLicenseRoles($Persona, $Config) {
    $r = @($Persona.licenses | Where-Object { $_ })
    if ($Config -and $Config.teamsForAllPersonas -and $r -notcontains 'teams') { $r += 'teams' }
    return $r
}

# Service plan names of a role (union over its bundle) from the subscribedSkus list.
function Get-DemoRolePlans($Skus, [string]$Value) {
    @(foreach ($part in Get-DemoSkuParts $Value) { $s = $Skus | Where-Object { $_.skuPartNumber -eq $part } | Select-Object -First 1; if ($s) { $s.servicePlans.servicePlanName } }) | Select-Object -Unique
}

# addLicenses entries for the SKUs of $Wanted (subscribedSkus objects, in priority order) not held yet. Two mailbox
# plans conflict (assignLicense fails), so the mailbox plans of a SKU are disabled when a SKU the user already holds,
# or an earlier SKU of the list, brings a mailbox.
$script:DemoMailboxPlanPattern = '^EXCHANGE_S_(STANDARD|ENTERPRISE|DESKLESS)$'
function Get-DemoLicenseAdds($Wanted, [string[]]$HeldSkuIds, $Skus) {
    $hasMailbox = $false
    foreach ($id in @($HeldSkuIds)) {
        $s = $Skus | Where-Object { [string]$_.skuId -eq $id } | Select-Object -First 1
        if ($s -and @($s.servicePlans | Where-Object { $_.servicePlanName -match $script:DemoMailboxPlanPattern }).Count) { $hasMailbox = $true }
    }
    $adds = @()
    foreach ($s in @($Wanted)) {
        $mbx = @($s.servicePlans | Where-Object { $_.servicePlanName -match $script:DemoMailboxPlanPattern })
        if (@($HeldSkuIds) -contains [string]$s.skuId) { continue }
        $disabled = @()
        if ($mbx.Count) { if ($hasMailbox) { $disabled = @($mbx | ForEach-Object { [string]$_.servicePlanId }) } else { $hasMailbox = $true } }
        $adds += @{ skuId = $s.skuId; disabledPlans = $disabled; partNumber = [string]$s.skuPartNumber }
    }
    return $adds
}
