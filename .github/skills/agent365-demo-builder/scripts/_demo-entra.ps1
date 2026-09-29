# Shared Entra helpers of the Demo Builder, used by the build (Set-DemoGovernance.ps1) and the reset scripts. Dot-source
# AFTER _demo-common.ps1. Agent-identity sponsors/owners and custom security attribute ASSIGNMENTS are application-only
# APIs: New-DemoAppOnlySession creates a TEMPORARY app registration (tagged a365lab:<prefix>) with only the Graph
# application permissions needed, a 4-hour secret kept in memory, and Close-DemoAppOnlySession deletes and purges it.
# Directory writes replicate asynchronously: every change is re-read until visible (Wait-DemoConverged).
$script:DemoG = 'https://graph.microsoft.com'

function Get-DemoAgentIdentities([switch]$Refresh) {
    if ($script:DemoAgentIdentities -and -not $Refresh) { return $script:DemoAgentIdentities }
    $script:DemoAgentIdentities = @(Invoke-DemoGraph GET "$script:DemoG/beta/servicePrincipals/microsoft.graph.agentIdentity?`$select=id,appId,displayName,agentIdentityBlueprintId,accountEnabled,createdDateTime&`$top=999" -All)
    return $script:DemoAgentIdentities
}

# The agent identity of one pack agent. Platform naming (verified in the reference lab, 28/09): code agents use the
# localized identity name (locale agents.<key>.identity), Copilot Studio agents '<displayName> (Microsoft Copilot
# Studio)', Foundry prompt agents '<account>-<project>-<codeName>-AgentIdentity'. Returns $null when not found (not
# created or published yet) and throws when a name is ambiguous (two identities match).
function Resolve-DemoAgentIdentity($Locale, [Parameter(Mandatory)][string]$AgentKey) {
    $la = $Locale.agents[$AgentKey]
    $n = if ($la.identity) { [string]$la.identity } else { [string]$la.displayName }
    $mcs = "$([string]$la.displayName) (Microsoft Copilot Studio)"
    $fd = if ($la.codeName) { "*-$([string]$la.codeName)-AgentIdentity" } else { $null }
    $all = Get-DemoAgentIdentities
    foreach ($test in @({ param($i) $i.displayName -eq $n }, { param($i) $i.displayName -eq $mcs }, { param($i) $fd -and $i.displayName -like $fd })) {
        $hits = @($all | Where-Object { & $test $_ })
        if ($hits.Count -gt 1) { throw "Agent identity of '$AgentKey' is ambiguous: $(@($hits | ForEach-Object { "'$($_.displayName)' ($($_.id))" }) -join ', '). Delete the stale identities first." }
        if ($hits.Count -eq 1) { return $hits[0] }
    }
    return $null
}

# Shared identity of the Foundry project of a Foundry prompt agent identity ('<account>-<project>-AgentIdentity').
function Get-DemoFoundryProjectIdentity($AgentIdentity, [string]$CodeName) {
    $suffix = "-$CodeName-AgentIdentity"
    if (-not $AgentIdentity -or -not $CodeName -or -not $AgentIdentity.displayName.EndsWith($suffix)) { return $null }
    $name = $AgentIdentity.displayName.Substring(0, $AgentIdentity.displayName.Length - $suffix.Length) + '-AgentIdentity'
    $hits = @(Get-DemoAgentIdentities | Where-Object { $_.displayName -eq $name })
    if ($hits.Count -eq 1) { return $hits[0] }
    return $null
}

# Pack agents that carry an Entra owner, sponsor or attribute, each with its agent identities: code agents by the
# agenticAppId of their Lab Builder config, Digital Worker instances by blueprint (sponsorOn: instance), the others by
# name (Resolve-DemoAgentIdentity); Foundry prompt agents also get their project's shared identity (reference lab).
function Get-DemoIdentityPlan([string]$Prefix, $Pack, $Locale) {
    @(foreach ($a in @($Pack.agents | Where-Object { $_.entraOwner -or $_.sponsor -or $_.attribute })) {
        $la = $Locale.agents[$a.key]
        $gcFile = if ($la.codeName) { Join-Path $script:DemoRepoRoot "generated\$Prefix\$($la.codeName)\a365.generated.config.json" } else { $null }
        $gc = if ($gcFile -and (Test-Path -LiteralPath $gcFile)) { Get-Content -LiteralPath $gcFile -Raw | ConvertFrom-Json } else { $null }
        $ids = if ($a.sponsorOn -eq 'instance') { if ($gc -and $gc.agentBlueprintId) { @(Get-DemoBlueprintInstances ([string]$gc.agentBlueprintId)) } else { @() } }
               elseif ($gc -and $gc.agenticAppId) { @(Get-DemoAgentIdentities | Where-Object { $_.appId -eq [string]$gc.agenticAppId }) }
               else { @(Resolve-DemoAgentIdentity $Locale $a.key | Where-Object { $_ }) }
        if ([string]$a.variant -like 'FD-*' -and @($ids).Count -eq 1) { $pi = Get-DemoFoundryProjectIdentity $ids[0] ([string]$la.codeName); if ($pi) { $ids = @($ids) + $pi } }
        [pscustomobject]@{ key = [string]$a.key; name = [string]$la.displayName; def = $a; identities = @($ids) }
    })
}

# Instances (agent identities) created from one blueprint, e.g. the Digital Worker instances of an ACA-DW/FH-DW agent.
function Get-DemoBlueprintInstances([Parameter(Mandatory)][string]$BlueprintAppId) {
    return @(Get-DemoAgentIdentities | Where-Object { $_.agentIdentityBlueprintId -eq $BlueprintAppId })
}

function Wait-DemoConverged([scriptblock]$Read, [scriptblock]$IsDone, [int]$Tries = 6, [int]$DelaySeconds = 8) {
    $v = $null
    for ($i = 0; $i -lt $Tries; $i++) { $v = & $Read; if (& $IsDone $v) { return $v }; Start-Sleep -Seconds $DelaySeconds }
    return $v
}

function ConvertFrom-DemoJwt([string]$Jwt) {
    $p = $Jwt.Split('.')[1].Replace('-', '+').Replace('_', '/'); switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
}

# Temporary app with the given Graph APPLICATION permissions; returns @{ app; token; roles }. Always pair with
# Close-DemoAppOnlySession in a finally block.
function New-DemoAppOnlySession {
    param([Parameter(Mandatory)][string]$Prefix, [Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string[]]$Roles)
    $G = $script:DemoG
    $name = "$Prefix-demo-automation (temporary)"
    $app = (Invoke-DemoGraph GET "$G/v1.0/applications?`$filter=displayName eq '$name'&`$select=id,appId").value | Select-Object -First 1
    if (-not $app) {
        $app = Invoke-DemoGraph POST "$G/v1.0/applications" -Body @{ displayName = $name; signInAudience = 'AzureADMyOrg'; tags = @("a365lab:$Prefix")
            notes = 'Temporary app-only automation of the Demo Builder (agent sponsors/owners, custom security attributes). Safe to delete.' }
        Write-DemoLog $Prefix "Temporary app created: $name ($($app.appId))"
    }
    $session = @{ app = $app; token = $null; roles = $Roles; prefix = $Prefix }
    $sp = $null
    for ($i = 0; $i -lt 10 -and -not $sp; $i++) {
        $sp = (Invoke-DemoGraph GET "$G/v1.0/servicePrincipals?`$filter=appId eq '$($app.appId)'&`$select=id").value | Select-Object -First 1
        if (-not $sp) { try { $sp = Invoke-DemoGraph POST "$G/v1.0/servicePrincipals" -Body @{ appId = $app.appId; tags = @("a365lab:$Prefix") } -MaxRetries 1 } catch { Start-Sleep -Seconds 3 } }
    }
    if (-not $sp) { throw 'Service principal of the temporary app not created.' }
    $graphSp = (Invoke-DemoGraph GET "$G/v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=id,appRoles").value | Select-Object -First 1
    $have = @((Invoke-DemoGraph GET "$G/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments" -All) | ForEach-Object { $_.appRoleId })
    foreach ($rn in $Roles) {
        $role = $graphSp.appRoles | Where-Object { $_.value -eq $rn -and $_.allowedMemberTypes -contains 'Application' } | Select-Object -First 1
        if (-not $role) { throw "Graph application permission $rn not found." }
        if ($have -notcontains $role.id) { Invoke-DemoGraph POST "$G/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments" -Body @{ principalId = $sp.id; resourceId = $graphSp.id; appRoleId = $role.id } | Out-Null }
    }
    $cred = Invoke-DemoGraph POST "$G/v1.0/applications/$($app.id)/addPassword" -Body @{ passwordCredential = @{ displayName = 'temporary'; endDateTime = (Get-Date).ToUniversalTime().AddHours(4).ToString('o') } }
    $secret = $cred.secretText; $cred = $null
    for ($i = 0; $i -lt 30 -and -not $session.token; $i++) {
        try {
            $r = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -ContentType 'application/x-www-form-urlencoded' `
                -Body @{ client_id = $app.appId; client_secret = $secret; scope = "$G/.default"; grant_type = 'client_credentials' } -ErrorAction Stop
            $got = @((ConvertFrom-DemoJwt $r.access_token).roles)
            if (@($Roles | Where-Object { $got -notcontains $_ }).Count -eq 0) { $session.token = $r.access_token; break }
        }
        catch { }
        Start-Sleep -Seconds 10
    }
    $secret = $null
    if (-not $session.token) { Close-DemoAppOnlySession $session; throw 'App-only token with the expected roles not obtained within 5 minutes.' }
    Write-DemoLog $Prefix "App-only token obtained ($($Roles -join ', '))"
    return $session
}

function Close-DemoAppOnlySession($Session) {
    if (-not $Session -or -not $Session.app) { return }
    $Session.token = $null
    $G = $script:DemoG
    try {
        Invoke-DemoGraph DELETE "$G/v1.0/applications/$($Session.app.id)" | Out-Null
        try { Invoke-DemoGraph DELETE "$G/v1.0/directory/deletedItems/$($Session.app.id)" -MaxRetries 2 | Out-Null } catch { }
        Write-DemoLog $Session.prefix 'Temporary app deleted and purged'
    }
    catch { Write-DemoLog $Session.prefix "Temporary app NOT deleted ($($_.Exception.Message)): delete '$($Session.prefix)-demo-automation (temporary)' manually" 'WARN' }
}
# --- Agent identity: sponsors, owners, enabled flag, custom security attribute (application-only) ---------------
function Get-DemoRef([string]$ObjectId) { @{ '@odata.id' = "$script:DemoG/beta/directoryObjects/$ObjectId" } }
function Format-DemoRefs($List) {
    @($List | ForEach-Object { $n = if ($_.displayName) { $_.displayName } else { $_.id }; if ($_.'@odata.type' -and $_.'@odata.type' -ne '#microsoft.graph.user') { "$n <app>" } else { $n } })
}

# Sponsor = -UserId (with -Exclusive every other sponsor is removed). Returns the final sponsors.
function Set-DemoIdentitySponsor($Session, [string]$IdentityId, [string]$UserId, [switch]$Exclusive) {
    $base = "$script:DemoG/beta/servicePrincipals/$IdentityId/microsoft.graph.agentIdentity/sponsors"
    $read = { @((Invoke-DemoGraph GET "${base}?`$select=id,displayName" -Token $Session.token).value) }
    $cur = & $read
    if (@($cur | ForEach-Object { $_.id }) -notcontains $UserId) { Invoke-DemoGraph POST "$base/`$ref" -Body (Get-DemoRef $UserId) -Token $Session.token | Out-Null }
    if ($Exclusive) { foreach ($o in @($cur | Where-Object { $_.id -ne $UserId })) { Invoke-DemoGraph DELETE "$base/$($o.id)/`$ref" -Token $Session.token | Out-Null } }
    return (Format-DemoRefs (Wait-DemoConverged $read { param($l) (@($l | ForEach-Object { $_.id }) -contains $UserId) -and (-not $Exclusive -or @($l).Count -eq 1) }))
}

# User owner = -UserId (with -ExclusiveUser the other USER owners are removed; service-principal owners such as the
# Foundry project managed identity are always kept). Falls back to the delegated token, as in the reference lab.
function Set-DemoIdentityOwner($Session, [string]$IdentityId, [string]$UserId, [switch]$ExclusiveUser) {
    $base = "$script:DemoG/beta/servicePrincipals/$IdentityId/microsoft.graph.agentIdentity/owners"
    $read = { @((Invoke-DemoGraph GET "${base}?`$select=id,displayName" -Token $Session.token).value) }
    $cur = & $read
    if (@($cur | ForEach-Object { $_.id }) -notcontains $UserId) {
        $r = Invoke-DemoGraph POST "$base/`$ref" -Body (Get-DemoRef $UserId) -Token $Session.token -NoThrow
        if ($r -and $r.PSObject.Properties['error']) { Invoke-DemoGraph POST "$base/`$ref" -Body (Get-DemoRef $UserId) | Out-Null }
    }
    if ($ExclusiveUser) {
        foreach ($o in @($cur | Where-Object { $_.id -ne $UserId -and $_.'@odata.type' -eq '#microsoft.graph.user' })) {
            $r = Invoke-DemoGraph DELETE "$base/$($o.id)/`$ref" -Token $Session.token -NoThrow
            if ($r -and $r.PSObject.Properties['error']) { Invoke-DemoGraph DELETE "$script:DemoG/v1.0/servicePrincipals/$IdentityId/owners/$($o.id)/`$ref" | Out-Null }
        }
    }
    $isDone = { param($l) (@($l | ForEach-Object { $_.id }) -contains $UserId) -and (-not $ExclusiveUser -or @($l | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.user' }).Count -eq 1) }
    return (Format-DemoRefs (Wait-DemoConverged $read $isDone))
}

function Set-DemoIdentityEnabled($Session, [string]$IdentityId, [bool]$Enabled) {
    $cur = Invoke-DemoGraph GET "$script:DemoG/beta/servicePrincipals/${IdentityId}?`$select=accountEnabled" -Token $Session.token
    if ([bool]$cur.accountEnabled -eq $Enabled) { return 'unchanged' }
    Invoke-DemoGraph PATCH "$script:DemoG/beta/servicePrincipals/$IdentityId/microsoft.graph.agentIdentity" -Body @{ accountEnabled = $Enabled } -Token $Session.token | Out-Null
    return 'changed'
}

# Custom security attribute assignment on an agent identity; returns the value read back.
function Set-DemoIdentityAttribute($Session, [string]$IdentityId, [string]$AttributeSet, [string]$Attribute, [string]$Value) {
    $body = @{ customSecurityAttributes = @{ $AttributeSet = @{ '@odata.type' = '#Microsoft.DirectoryServices.CustomSecurityAttributeValue'; $Attribute = $Value } } }
    $errs = @(); $done = $false
    foreach ($u in "$script:DemoG/beta/servicePrincipals/$IdentityId/microsoft.graph.agentIdentity", "$script:DemoG/beta/servicePrincipals/$IdentityId") {
        $r = Invoke-DemoGraph PATCH $u -Body $body -Token $Session.token -NoThrow
        if ($r -and $r.PSObject.Properties['error']) { $errs += $r.error } else { $done = $true; break }
    }
    if (-not $done) { throw "Attribute $AttributeSet/$Attribute on ${IdentityId}: $($errs -join ' | ')" }
    $read = { try { [string](Invoke-DemoGraph GET "$script:DemoG/beta/servicePrincipals/${IdentityId}?`$select=customSecurityAttributes" -Token $Session.token).customSecurityAttributes.$AttributeSet.$Attribute } catch { '' } }
    return (Wait-DemoConverged $read { param($v) $v -eq $Value })
}
