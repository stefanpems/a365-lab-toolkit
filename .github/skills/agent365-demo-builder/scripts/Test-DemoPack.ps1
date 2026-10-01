#requires -Version 7.0
<#
.SYNOPSIS
  Validates the locale(s) of a demo pack BEFORE anything is created in a tenant: completeness against pack.json,
  placeholders, iron rules (text-limits.json via Test-A365Names.ps1), uniqueness (aliases, groups, agent names,
  MCP tools across every server incl. the Lab Builder samples) and fictional-only e-mail domains.
.EXAMPLE
  pwsh -File .\Test-DemoPack.ps1                    # every locale declared in pack.json
.EXAMPLE
  pwsh -File .\Test-DemoPack.ps1 -Locale it,fr
#>
[CmdletBinding(PositionalBinding = $false)]
param([string]$Pack = 'agent-governance', [string[]]$Locale = @('all'), [string]$OperatorSlots, [switch]$AsObject)
. (Join-Path $PSScriptRoot '_demo-common.ps1')
# 'pwsh -File' passes "en,it" as ONE string: accept comma-separated lists.
$Locale = @($Locale | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$packDef = Get-DemoPack $Pack
$locales = if ($Locale -contains 'all') { @($packDef.locales) } else { $Locale }
$all = [System.Collections.Generic.List[object]]::new()

function Add-V([string]$Loc, [string]$Level, [string]$Field, [string]$Message) { $all.Add([pscustomobject]@{ locale = $Loc; level = $Level; field = $Field; message = $Message }) }
function Add-Vs([string]$Loc, $Violations, [string]$Prefix = '') { foreach ($v in @($Violations)) { if ($v) { Add-V $Loc $v.level "$Prefix$($v.field)" $v.message } } }
function Get-Keys($H) { if ($H -is [System.Collections.IDictionary]) { return @($H.Keys) } return @() }
function Test-Need([string]$Loc, $Node, [string]$Path, [string[]]$Keys) {
    foreach ($k in $Keys) {
        $missing = -not ($Node -is [System.Collections.IDictionary]) -or -not $Node.Contains($k) -or $null -eq $Node[$k] -or ($Node[$k] -is [string] -and $Node[$k] -eq '')
        if ($missing) { Add-V $Loc 'error' "$Path.$k" 'is missing or empty' }
    }
}

# Tools of the Lab Builder sample servers: a demo tool must never reuse one of their names.
$sampleTools = @{}
foreach ($tpl in 'register-anon.template.json', 'register-auth.template.json') {
    $f = Join-Path $script:DemoRepoRoot "custom-mcp\$tpl"
    if (Test-Path -LiteralPath $f) { foreach ($t in (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).tools) { $sampleTools[[string]$t.name] = @("Lab Builder sample ($tpl)") } }
}
$limits = Get-A365TextLimits
$slotIds = @($packDef.operatorSlots | ForEach-Object { [string]$_.id })

# Dictionary completeness: every locale must have exactly the leaf keys of the default locale (the dictionary of
# everything that is localized). Keys starting with '_' are comments.
function Get-LeafKeys($Node, [string]$Prefix = '') {
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($k in $Node.Keys) { if (-not "$k".StartsWith('_')) { Get-LeafKeys $Node[$k] $(if ($Prefix) { "$Prefix.$k" } else { "$k" }) } }
    }
    else { $Prefix }
}
function Get-RawLocale([string]$Loc) {
    $d = Join-Path (Get-DemoPackDir $Pack) "locales\$Loc"
    $r = Get-Content -LiteralPath (Join-Path $d 'core.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    foreach ($part in 'knowledge', 'tests') { $f = Join-Path $d "$part.json"; if (Test-Path -LiteralPath $f) { $r[$part] = Get-Content -LiteralPath $f -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } }
    return $r
}
$refLocale = [string]$packDef.defaultLocale
$refKeys = @(Get-LeafKeys (Get-RawLocale $refLocale))

foreach ($loc in $locales) {
    $dir = Join-Path (Get-DemoPackDir $Pack) "locales\$loc"
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'core.json'))) { Add-V $loc 'warning' 'locale' "not present ($dir): create it (the Demo Builder can translate the en pack) before using this language"; continue }
    if ($loc -ne $refLocale) {
        $keys = @(Get-LeafKeys (Get-RawLocale $loc))
        foreach ($k in @($refKeys | Where-Object { $keys -notcontains $_ })) { Add-V $loc 'error' $k "missing (present in the $refLocale dictionary)" }
        foreach ($k in @($keys | Where-Object { $refKeys -notcontains $_ })) { Add-V $loc 'error' $k "not in the $refLocale dictionary" }
    }
    try { $L = Get-DemoLocale -Locale $loc -Pack $Pack } catch { Add-V $loc 'error' 'locale' "cannot be loaded: $($_.Exception.Message)"; continue }
    foreach ($u in $L._unresolved) { Add-V $loc 'error' "{{$u}}" 'placeholder does not resolve to a string' }
    Test-Need $loc $L 'locale' @('locale', 'language', 'usageLocation', 'org', 'personas', 'groups', 'agents', 'mcp', 'overlays', 'governance', 'prompts', 'knowledge', 'tests')
    if ($L.locale -ne $loc) { Add-V $loc 'error' 'locale' "declares '$($L.locale)' but lives in folder '$loc'" }
    if ([string]$L.usageLocation -cnotmatch '^[A-Z]{2}$') { Add-V $loc 'error' 'usageLocation' 'must be an ISO 3166 two-letter code' }
    Test-Need $loc $L.org 'org' @('name', 'department', 'program', 'portal', 'fictionalBanner', 'fictionalSuffix', 'namePrefix', 'publisher', 'offices', 'caseIdPrefix', 'recordIdPrefix')
    Test-Need $loc $L.org.offices 'org.offices' @('main', 'secondary')

    # Personas: names, aliases (diacritics removed), uniqueness; the reports monitor filters officers by department.
    $aliases = @{}
    foreach ($p in $packDef.personas) {
        $lp = $L.personas[$p.key]
        if (-not $lp) { Add-V $loc 'error' "personas.$($p.key)" 'missing'; continue }
        Test-Need $loc $lp "personas.$($p.key)" @('givenName', 'surname', 'jobTitle', 'department')
        $alias = Get-DemoPersonaAlias $L $p.key
        Add-Vs $loc (Test-A365Text -Kind 'entra.userAlias' -Value $alias -Field "personas.$($p.key).alias ($alias)")
        Add-Vs $loc (Test-A365Text -Kind 'entra.displayName' -Value (Get-DemoPersonaDisplayName $L $p.key) -Field "personas.$($p.key).displayName")
        if ($aliases.ContainsKey($alias)) { Add-V $loc 'error' "personas.$($p.key)" "alias '$alias' is also used by $($aliases[$alias])" } else { $aliases[$alias] = $p.key }
    }
    foreach ($k in 'maker', 'caseOfficer', 'director', 'programLead', 'orphanLeaver', 'd8Leaver') {
        if ($L.personas[$k] -and $L.personas[$k].department -ne $L.org.department) { Add-V $loc 'error' "personas.$k.department" "must equal org.department ('$($L.org.department)')" }
    }

    # Groups
    $nicks = @{}
    foreach ($g in $packDef.groups) {
        $lg = $L.groups[$g.key]
        if (-not $lg) { Add-V $loc 'error' "groups.$($g.key)" 'missing'; continue }
        Test-Need $loc $lg "groups.$($g.key)" @('displayName', 'mailNickname', 'description')
        Add-Vs $loc (Test-A365Text -Kind 'entra.groupMailNickname' -Value $lg.mailNickname -Field "groups.$($g.key).mailNickname")
        Add-Vs $loc (Test-A365Text -Kind 'entra.displayName' -Value $lg.displayName -Field "groups.$($g.key).displayName")
        if ($nicks.ContainsKey([string]$lg.mailNickname)) { Add-V $loc 'error' "groups.$($g.key).mailNickname" 'is duplicated' } else { $nicks[[string]$lg.mailNickname] = 1 }
    }

    # Agents per platform
    $displayNames = @{}; $codeNames = @{}
    foreach ($a in $packDef.agents) {
        $la = $L.agents[$a.key]; $path = "agents.$($a.key)"
        if (-not $la) { Add-V $loc 'error' $path 'missing'; continue }
        Test-Need $loc $la $path @('displayName')
        if ($displayNames.ContainsKey([string]$la.displayName)) { Add-V $loc 'error' "$path.displayName" "duplicates agents.$($displayNames[[string]$la.displayName])" } else { $displayNames[[string]$la.displayName] = $a.key }
        switch ($a.platform) {
            'code' {
                Test-Need $loc $la $path @('codeName', 'blueprint', 'identity')
                $cn = [string]$la.codeName
                Add-Vs $loc (Test-A365Pattern "$path.codeName" $cn $limits.codeAgentName)
                if ($cn.ToLowerInvariant().Length -gt [int]$limits.codeAgentName.containerAppMax) { Add-V $loc 'error' "$path.codeName" "container app name '$($cn.ToLowerInvariant())' exceeds $($limits.codeAgentName.containerAppMax) characters" }
                if ($a.variant -like '*-DW') {
                    if ($cn.Length -gt [int]$limits.codeAgentName.dwMax) { Add-V $loc 'error' "$path.codeName" "a Digital Worker name must be <= $($limits.codeAgentName.dwMax) characters" }
                    Test-Need $loc $la $path @('manifest', 'instance')
                    if ($la.manifest) { Add-Vs $loc (Test-TeamsManifestText -NameShort $la.manifest.nameShort -NameFull $la.manifest.nameFull -DescriptionShort $la.manifest.descriptionShort -DescriptionFull $la.manifest.descriptionFull -DeveloperName $la.manifest.developer) "$path." }
                    if ($la.instance) {
                        Add-Vs $loc (Test-A365Text -Kind 'aiTeammateInstance.displayName' -Value $la.instance.displayName -Field "$path.instance.displayName")
                        Add-Vs $loc (Test-A365Text -Kind 'aiTeammateInstance.alias' -Value $la.instance.alias -Field "$path.instance.alias")
                    }
                }
                foreach ($f in 'blueprint', 'identity') { if ($la[$f]) { Add-Vs $loc (Test-A365Text -Kind 'entra.displayName' -Value $la[$f] -Field "$path.$f") } }
                if ($codeNames.ContainsKey($cn)) { Add-V $loc 'error' "$path.codeName" 'is duplicated' } else { $codeNames[$cn] = 1 }
            }
            'copilotStudio' {
                Test-Need $loc $la $path @('codeName', 'shortDescription', 'description')
                if (-not $a.instructionsEmpty) { Test-Need $loc $la $path @('instructions') }
                Add-Vs $loc (Test-A365Text -Kind 'copilotStudioAgent.displayName' -Value $la.displayName -Field "$path.displayName")
                if ([string]$la.displayName -match '[<>&"#]|: ') { Add-V $loc 'error' "$path.displayName" 'must not contain < > & " # or '': '' (it would break the solution transform)' }
                Add-Vs $loc (Test-A365Text -Kind 'copilotStudioAgent.descriptionShort' -Value $la.shortDescription -Field "$path.shortDescription")
                Add-Vs $loc (Test-A365Text -Kind 'copilotStudioAgent.description' -Value $la.description -Field "$path.description")
                Add-Vs $loc (Test-A365Text -Kind 'copilotStudioAgent.instructions' -Value ([string]$la.instructions) -Field "$path.instructions" -AllowEmpty:([bool]$a.instructionsEmpty))
                Add-Vs $loc (Test-A365Pattern "$path.codeName" ([string]$la.codeName) $limits.codeAgentName)
            }
            'agentBuilder' {
                Test-Need $loc $la $path @('description', 'instructions')
                Add-Vs $loc (Test-A365Text -Kind 'agentBuilderAgent.name' -Value $la.displayName -Field "$path.displayName")
                Add-Vs $loc (Test-A365Text -Kind 'agentBuilderAgent.description' -Value $la.description -Field "$path.description")
                Add-Vs $loc (Test-A365Text -Kind 'agentBuilderAgent.instructions' -Value $la.instructions -Field "$path.instructions")
            }
        }
    }
    if ($L.agents.personalContacts -and -not $L.agents.personalContacts.rejectionReason) { Add-V $loc 'error' 'agents.personalContacts.rejectionReason' 'is missing' }

    # Agent Builder catalog submission (reference lab, 28/09): display name <= 30, short description <= 80, developer <= 32.
    foreach ($ab in @($packDef.agents | Where-Object { $_.platform -eq 'agentBuilder' })) {
        $la = $L.agents[$ab.key]; $path = "agents.$($ab.key)"
        if ([string]$la.displayName -and ([string]$la.displayName).Length -gt 30) { Add-V $loc 'error' "$path.displayName" "is $(([string]$la.displayName).Length) characters (Agent Builder catalog submission: max 30)" }
        if ([string]$la.description -and ([string]$la.description).Length -gt 80) { Add-V $loc 'error' "$path.description" "is $(([string]$la.description).Length) characters (short description of the catalog submission: max 80)" }
        if ($ab.submitToCatalog -and $ab.creator -and $L.personas[$ab.creator]) {
            $dev = Get-DemoPersonaDisplayName $L $ab.creator
            if ($dev.Length -gt 32) { Add-V $loc 'error' "$path (developer)" "developer name '$dev' is longer than 32 characters" }
        }
    }
    # Agent Builder custom skills: lowercase ASCII kebab-case name, description and body present.
    foreach ($ab in @($packDef.agents | Where-Object { $_.customSkill })) {
        $sk = if ($L.skills) { $L.skills[[string]$ab.customSkill] } else { $null }
        $path = "skills.$($ab.customSkill)"
        if (-not $sk) { Add-V $loc 'error' $path "missing (custom skill of $($ab.key))"; continue }
        Test-Need $loc $sk $path @('name', 'description', 'body')
        if ([string]$sk.name -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$' -or ([string]$sk.name).Length -gt 64) { Add-V $loc 'error' "$path.name" "'$($sk.name)' must be lowercase ASCII kebab-case, at most 64 characters" }
    }
    # Registry tags: short names (15 characters proven in the reference lab), one description each.
    foreach ($tk in @($packDef.governance.adminCenter.tags)) {
        $tn = [string]$L.governance.tags[$tk]
        if (-not $tn) { Add-V $loc 'error' "governance.tags.$tk" 'is missing' }
        elseif ($tn.Length -gt 15) { Add-V $loc 'error' "governance.tags.$tk" "'$tn' is $($tn.Length) characters (registry tags: keep <= 15)" }
        if (-not [string]$L.governance.tagDescriptions[$tk]) { Add-V $loc 'error' "governance.tagDescriptions.$tk" 'is missing' }
    }

    # MCP servers (long-lived + reserve-pool bases at NN=99): name, proxy connector, description, tools, and
    # tool names unique across EVERY server of the pack and the Lab Builder sample servers.
    $owners = @{}; foreach ($k in $sampleTools.Keys) { $owners[$k] = @($sampleTools[$k]) }
    $defs = @()
    foreach ($s in @($packDef.mcp.longLived) + @($packDef.mcp.pool)) {
        $ls = $L.mcp.servers[$s.key]; $path = "mcp.servers.$($s.key)"
        if (-not $ls) { Add-V $loc 'error' $path 'missing'; continue }
        $isPool = @($packDef.mcp.pool | Where-Object { $_.key -eq $s.key }).Count -gt 0
        $name = if ($isPool) { [string]$ls.base } else { [string]$ls.name }
        if (-not $name) { Add-V $loc 'error' $path $(if ($isPool) { 'base is missing' } else { 'name is missing' }); continue }
        Add-Vs $loc (Test-ExtMcpServer -Name $name -Description $ls.description -Numbered:$isPool) "$path."
        $tools = @(foreach ($tk in $s.tools) {
            $lt = $ls.tools[$tk]
            if (-not $lt) { Add-V $loc 'error' "$path.tools.$tk" 'missing'; continue }
            $params = @(foreach ($pk in (Get-Keys $lt.params)) { @{ name = $lt.params[$pk].name; description = $lt.params[$pk].description } })
            @{ name = [string]$lt.name; description = [string]$lt.description; parameters = $params }
        })
        $defs += [pscustomobject]@{ server = $name; tools = $tools; path = $path }
        foreach ($t in $tools) { if (-not $owners.ContainsKey($t.name)) { $owners[$t.name] = @() }; $owners[$t.name] += $name }
    }
    foreach ($d in $defs) {
        $others = @{}; foreach ($k in $owners.Keys) { $others[$k] = @($owners[$k] | Where-Object { $_ -ne $d.server }) }
        Add-Vs $loc (Test-McpTools -ServerName $d.server -Tools $d.tools -ToolOwners $others) "$($d.path)."
    }

    # Overlays of the code agents (in-process function tools: Python identifiers / function names)
    foreach ($ok in @($packDef.agents | Where-Object { $_.overlay } | ForEach-Object { $_.overlay } | Select-Object -Unique)) {
        $lo = $L.overlays[$ok]; $path = "overlays.$ok"
        if (-not $lo) { Add-V $loc 'error' $path 'missing'; continue }
        Test-Need $loc $lo $path @('rolePrompt')
        if ($lo.rolePrompt -and $lo.rolePrompt.Length -gt 4000) { Add-V $loc 'error' "$path.rolePrompt" 'is longer than 4000 characters' }
        foreach ($tk in (Get-Keys $lo.tools)) {
            $t = $lo.tools[$tk]
            if ([string]$t.name -cnotmatch '^[a-z][a-z0-9_]{2,39}$') { Add-V $loc 'error' "$path.tools.$tk.name" "'$($t.name)' must be a lowercase snake_case identifier (3-40 characters)" }
            if (-not $t.description -or $t.description.Length -gt 300) { Add-V $loc 'error' "$path.tools.$tk.description" 'is empty or longer than 300 characters' }
            foreach ($pk in (Get-Keys $t.params)) { if ([string]$t.params[$pk].name -cnotmatch '^[a-z][a-z0-9_]{0,39}$') { Add-V $loc 'error' "$path.tools.$tk.params.$pk" "'$($t.params[$pk].name)' must be a lowercase snake_case identifier" } }
        }
    }
    foreach ($r in @($L.overlays['reports-monitor'].reports)) { if ($r -and $r.office -notin @($L.org.offices.main, $L.org.offices.secondary)) { Add-V $loc 'error' "overlays.reports-monitor.reports.$($r.id).office" "'$($r.office)' is not one of org.offices" } }
    if ($L.overlays['records-colleague']) { Test-Need $loc $L.overlays['records-colleague'].texts 'overlays.records-colleague.texts' @('welcome', 'hired', 'goodbye', 'identityNote', 'callerNote', 'emailSender', 'notificationSender') }

    # Knowledge (SharePoint-safe names, formats, block model, the poisoned notice of D16)
    foreach ($fk in $packDef.knowledge.folders) { $fn = $L.knowledge.folders[$fk]; if (-not $fn) { Add-V $loc 'error' "knowledge.folders.$fk" 'missing' } else { Add-Vs $loc (Test-SharePointSegment "knowledge.folders.$fk" $fn) } }
    foreach ($d in $packDef.knowledge.documents) {
        $ld = $L.knowledge.documents[$d.key]; $path = "knowledge.documents.$($d.key)"
        if (-not $ld) { Add-V $loc 'error' $path 'missing'; continue }
        Test-Need $loc $ld $path @('file', 'title', 'blocks')
        Add-Vs $loc (Test-SharePointSegment "$path.file" $ld.file)
        if ([IO.Path]::GetExtension([string]$ld.file).TrimStart('.').ToLowerInvariant() -ne $d.format) { Add-V $loc 'error' "$path.file" "extension must be .$($d.format)" }
        foreach ($b in @($ld.blocks)) { if ($b[0] -notin 'h1', 'h2', 'p', 'pi', 'slot', 'bullets', 'numbered', 'table') { Add-V $loc 'error' "$path.blocks" "unknown block type '$($b[0])'" } }
        foreach ($b in @($ld.blocks | Where-Object { $_[0] -eq 'slot' })) { if ($slotIds -notcontains [string]$b[1]) { Add-V $loc 'error' "$path.blocks" "slot '$($b[1])' is not declared in pack.json operatorSlots" } }
        if ($d.poisoned -and -not @($ld.blocks | Where-Object { $_[0] -eq 'slot' }).Count) { Add-V $loc 'error' $path 'the D16 notice needs its operator slot block' }
    }
    foreach ($pf in $packDef.knowledge.personalFiles) {
        $lp = $L.knowledge.personal[$pf.key]
        if (-not $lp) { Add-V $loc 'error' "knowledge.personal.$($pf.key)" 'missing' } else { Test-Need $loc $lp "knowledge.personal.$($pf.key)" @('file', 'sheet', 'headers', 'rows'); Add-Vs $loc (Test-SharePointSegment "knowledge.personal.$($pf.key).file" $lp.file) }
    }

    # Governance object names
    $gv = $L.governance
    Add-Vs $loc (Test-A365Text -Kind 'entra.attributeSetId' -Value $gv.attributeSet.id -Field 'governance.attributeSet.id')
    Add-Vs $loc (Test-A365Text -Kind 'entra.attributeName' -Value $gv.attribute.name -Field 'governance.attribute.name')
    foreach ($vk in $packDef.governance.attribute.values) { Add-Vs $loc (Test-A365Text -Kind 'entra.attributeValue' -Value $gv.attribute.values[$vk] -Field "governance.attribute.values.$vk") }
    foreach ($ca in $packDef.governance.conditionalAccess) { Add-Vs $loc (Test-A365Text -Kind 'entra.conditionalAccessPolicyName' -Value $gv.conditionalAccess[$ca.key] -Field "governance.conditionalAccess.$($ca.key)") }
    Add-Vs $loc (Test-A365Text -Kind 'entra.catalogName' -Value $gv.catalog.name -Field 'governance.catalog.name')
    Add-Vs $loc (Test-A365Text -Kind 'entra.accessPackageName' -Value $gv.accessPackage.name -Field 'governance.accessPackage.name')
    Add-Vs $loc (Test-A365Text -Kind 'purview.sensitivityLabelName' -Value $gv.sensitivityLabel.name -Field 'governance.sensitivityLabel.name')
    foreach ($pn in 'dlpPolicy', 'auditRetentionPolicy', 'communicationCompliancePolicy', 'ediscoveryCase') { Add-Vs $loc (Test-A365Text -Kind 'purview.policyName' -Value $gv[$pn] -Field "governance.$pn") }
    Add-Vs $loc (Test-A365Text -Kind 'agent365Admin.rtpRuleName' -Value $gv.rtpRule -Field 'governance.rtpRule')
    foreach ($tk in $packDef.governance.adminCenter.tags) { Add-Vs $loc (Test-A365Text -Kind 'agent365Admin.tagName' -Value $gv.tags[$tk] -Field "governance.tags.$tk") }
    foreach ($tp in $packDef.governance.adminCenter.templates) { Add-Vs $loc (Test-A365Text -Kind 'agent365Admin.templateName' -Value $gv.templates[$tp.key] -Field "governance.templates.$($tp.key)") }
    Test-Need $loc $gv.auditSearches 'governance.auditSearches' @('agentInteractions', 'agentAdminActions')

    # Prompts and tests
    Test-Need $loc $L.prompts 'prompts' @('d6RegisterRecord', 'd10MonitorRun', 'd16Summarize', 'mcpSetupUrl')
    Test-Need $loc $L.tests.baseline 'tests.baseline' @('B1', 'B2', 'B3')
    $personaKeys = @($packDef.personas | ForEach-Object { [string]$_.key }) + 'anyone'   # 'anyone' = any licensed demo user
    foreach ($t in $packDef.tests) {
        foreach ($pk in @($t.persona) + @($t.personas)) { if ($pk -and $personaKeys -notcontains [string]$pk) { Add-V $loc 'error' "pack.tests.$($t.id)" "persona '$pk' is not declared in pack.json personas" } }
        $has = $L.tests.items -and $L.tests.items.Contains($t.id)
        if (-not $has -and -not $t.uses) { Add-V $loc 'error' "tests.items.$($t.id)" 'missing' }
        if ($has) {
            $it = $L.tests.items[$t.id]
            foreach ($s in @($it.promptSlot) + @($it.promptSlots)) { if ($s -and $slotIds -notcontains [string]$s) { Add-V $loc 'error' "tests.items.$($t.id)" "slot '$s' is not declared in pack.json operatorSlots" } }
        }
    }

    # Every e-mail address must be on a reserved example domain.
    $raw = ''
    foreach ($f in 'core.json', 'knowledge.json', 'tests.json') { $fp = Join-Path $dir $f; if (Test-Path -LiteralPath $fp) { $raw += Get-Content -LiteralPath $fp -Raw -Encoding utf8 } }
    foreach ($m in [regex]::Matches($raw, '[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z0-9-]+')) {
        $dom = $m.Value.Split('@')[1].ToLowerInvariant()
        $ok = $dom -match '(^|\.)example$' -or $dom -match '(^|\.)example\.(com|org|net)$'
        if (-not $ok) { Add-V $loc 'error' 'e-mail' "'$($m.Value)' is not on a reserved example domain" }
    }
}

if ($AsObject) { return $all }
# Operator slots file (optional): presence and constraints only - values are NEVER printed.
if ($OperatorSlots) {
    if (-not (Test-Path -LiteralPath $OperatorSlots)) { Add-V '-' 'error' 'operatorSlots' "file not found: $OperatorSlots (copy operator-slots.template.json)" }
    else {
        $os = Get-Content -LiteralPath $OperatorSlots -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        foreach ($loc in $locales) {
            $row = if ($os.Contains($loc)) { $os[$loc] } else { @{} }
            foreach ($sid in $slotIds) {
                $val = [string]$row[$sid]
                if (-not $val) { Add-V $loc 'warning' "operatorSlots.$sid" 'not filled: the demo steps that use it cannot be shown'; continue }
                if ($val.Length -gt 1000) { Add-V $loc 'error' "operatorSlots.$sid" "is $($val.Length) characters (max 1000)" }
                foreach ($m in [regex]::Matches($val, '[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z0-9-]+')) {
                    $dom = $m.Value.Split('@')[1].ToLowerInvariant()
                    if (-not ($dom -match '(^|\.)example$' -or $dom -match '(^|\.)example\.(com|org|net)$')) { Add-V $loc 'error' "operatorSlots.$sid" 'contains an e-mail address outside the reserved example domains' }
                }
                Add-V $loc 'info' "operatorSlots.$sid" "filled ($($val.Length) characters)"
            }
        }
    }
}
$errs = @($all | Where-Object level -eq 'error'); $warns = @($all | Where-Object level -eq 'warning')
foreach ($v in ($all | Sort-Object locale, level, field)) {
    $color = switch ($v.level) { 'error' { 'Red' } 'warning' { 'DarkYellow' } default { 'Gray' } }
    Write-Host ('{0,-3} {1,-7} {2}: {3}' -f $v.locale, $v.level.ToUpper(), $v.field, $v.message) -ForegroundColor $color
}
Write-Host ("Demo pack '{0}', locales [{1}]: {2} error(s), {3} warning(s)" -f $Pack, ($locales -join ', '), $errs.Count, $warns.Count) -ForegroundColor $(if ($errs.Count) { 'Red' } else { 'Green' })
if ($errs.Count) { exit 1 }
