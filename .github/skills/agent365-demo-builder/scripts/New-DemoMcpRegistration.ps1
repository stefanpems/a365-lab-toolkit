#requires -Version 7.0
<#
.SYNOPSIS
  Registers the demo MCP servers in the Agent 365 tool gateway (long-lived servers + the reserve-name pool), pre-empts
  their approval consents, records their BYO audiences and gives the per-user connection URLs BEFORE any test.
.DESCRIPTION
  The a365 CLI asks 'Proceed with registration? (y/N)' and needs a real terminal, so this script never registers by
  itself: it checks everything, writes the payload and prints the exact command to run. Actions:
    Status                                 pack validation, instances in state.json, ext_ servers seen in the tenant
    Register -Server <key> [-ServerName n] long-lived server (records, companies): checks + payload + command
    Register -Role live|rehearsal|spare    reserve-name pool: next free <base><NN>, checks + payload + command
    Confirm  -Name <n>                     after 'registered successfully': backing apps + approval consents
                                           (custom-mcp/preempt-proxy-consents.ps1 -Server), BYO audience -> state
    Approved -Name <n>                     after the admin approved it in the admin center; then Urls
    Urls     [-Name <n>]                   connectionsMcp URL of each approved server (print-connection-urls.ps1 -Server)
    Retire   -Name <n> | -Role <r> | -All [-Confirmed]   pool only: manual Reject/Block, then -Confirmed records it
  Checks before a payload is written: the locale passes Test-DemoPack.ps1; the concrete name passes the iron rules
  (Test-ExtMcpServer); the backend answers /health and tools/list returns exactly the declared tools; the name is not
  used in state.json or in the tenant; a pool base has no other non-retired instance (pack.json mcp.rules).
  Server and tool names are tenant-wide: a second demo lab in the same tenant needs -ServerName (another ext_ name
  within the iron rules) for the long-lived servers, and the same tool names must never be active twice: Block the
  first lab's servers (or retire its pool instances) first, or build the second lab in another locale.
.EXAMPLE
  pwsh -File .\New-DemoMcpRegistration.ps1 -Prefix cts2 -Action Register -Server records
.EXAMPLE
  pwsh -File .\New-DemoMcpRegistration.ps1 -Prefix cts2 -Action Register -Role live
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)][string]$Prefix,
    [ValidateSet('Status', 'Register', 'Confirm', 'Approved', 'Urls', 'Retire')][string]$Action = 'Status',
    [string]$Server,
    [string]$ServerName,
    [ValidateSet('live', 'rehearsal', 'spare')][string]$Role,
    [ValidateRange(0, 99)][int]$Number = 0,
    [string]$Name,
    [switch]$All,
    [switch]$Confirmed,
    [string]$EnvironmentId
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_demo-common.ps1')
. (Join-Path $script:WizardScriptsDir 'Test-A365Names.ps1')
$cfg = Read-DemoConfig $Prefix
$pack = Get-DemoPack $cfg.pack
$LOC = Get-DemoLocale -Locale $cfg.locale -Pack $cfg.pack
$state = Read-DemoLabState $Prefix
foreach ($k in 'servers', 'backends') { if (-not $state.mcp.Contains($k)) { $state.mcp[$k] = [ordered]@{} } }
$pool = [System.Collections.Generic.List[object]]::new()
foreach ($i in @($state.mcp.pool)) { if ($i) { $pool.Add($i) } }
$regDir = Join-Path (Get-DemoLabDir $Prefix) 'mcp-registration'
$customMcp = Join-Path $script:DemoRepoRoot 'custom-mcp'
$activeStates = @('pending', 'approved')
$longKeys = @($pack.mcp.longLived | ForEach-Object { [string]$_.key })

function Save-State { $state.mcp['pool'] = @($pool); Save-DemoLabState $Prefix $state }
function Get-PoolDef([string]$R) {
    $b = @($pack.mcp.pool | Where-Object { @($_.roles) -contains $R }) | Select-Object -First 1
    if (-not $b) { throw "No pool base of pack '$($cfg.pack)' has the role '$R'." }
    return $b
}
function Get-LocaleTools([string]$Key) {
    $ls = $LOC.mcp.servers[$Key]
    @(foreach ($tk in @(($pack.mcp.longLived + $pack.mcp.pool) | Where-Object { $_.key -eq $Key } | Select-Object -First 1).tools) { [ordered]@{ name = [string]$ls.tools[$tk].name; description = [string]$ls.tools[$tk].description } })
}
function Get-AllInstances {
    $out = @(foreach ($k in @($state.mcp.servers.Keys)) { $s = $state.mcp.servers[$k]; [pscustomobject]@{ name = $s.name; key = $k; kind = 'long-lived'; role = ''; status = $s.status } })
    $out + @($pool | ForEach-Object { [pscustomobject]@{ name = $_.name; key = $_.key; kind = 'pool'; role = $_.role; status = $_.status } })
}

# ext_ servers of the tenant, from their Power Platform connectors in the hidden Compliant Container environment
# (id from -EnvironmentId or the per-tenant cache shared with custom-mcp/print-connection-urls.ps1). $null = unknown.
function Get-TenantExtServers {
    $envId = $EnvironmentId
    if (-not $envId) { $f = Join-Path $env:LOCALAPPDATA "a365-lab\pp-compliant-env.$($cfg.tenantId).txt"; if (Test-Path -LiteralPath $f) { $envId = (Get-Content -LiteralPath $f -Raw).Trim() } }
    if (-not $envId) { return $null }
    $tok = Get-DemoAzToken -Resource 'https://service.powerapps.com/'
    $items = @(); $next = "https://api.powerapps.com/providers/Microsoft.PowerApps/apis?api-version=2016-11-01&`$filter=environment eq '$envId'"
    while ($next) {
        $r = Invoke-DemoGraph GET $next -Token $tok
        $items += @($r.value)
        $next = if ($r.PSObject.Properties['nextLink']) { $r.nextLink } elseif ($r.PSObject.Properties['@odata.nextLink']) { $r.'@odata.nextLink' } else { $null }
    }
    return @($items | ForEach-Object { [string]$_.properties.displayName } | Where-Object { $_ -like 'ext_*' } | ForEach-Object { $_ -replace 'P$', '' } | Sort-Object -Unique)
}

# --- Status -----------------------------------------------------------------------------------------------------
if ($Action -eq 'Status') {
    $v = @(& (Join-Path $PSScriptRoot 'Test-DemoPack.ps1') -Pack $cfg.pack -Locale $cfg.locale -AsObject | Where-Object { $_.level -eq 'error' -and $_.field -like 'mcp.*' })
    Write-Host "=== MCP definition of locale '$($cfg.locale)' (pool bases checked at NN=99): $(if ($v.Count) { "$($v.Count) error(s)" } else { 'OK' })"
    $v | ForEach-Object { Write-Host "  KO $($_.field): $($_.message)" }
    Write-Host '=== Backends (Deploy-DemoMcp.ps1)'
    foreach ($k in @($state.mcp.backends.Keys)) { $b = $state.mcp.backends[$k]; Write-Host ("  {0,-10} {1} health={2} tools={3}" -f $k, $b.url, $b.healthy, $b.toolsMatch) }
    if (-not @($state.mcp.backends.Keys).Count) { Write-Host '  (none deployed yet)' }
    Write-Host '=== Registered servers (state.json)'
    $inst = @(Get-AllInstances)
    if (-not $inst.Count) { Write-Host '  (none yet)' }
    $inst | ForEach-Object { Write-Host ("  {0,-20} {1,-10} {2,-10} {3}" -f $_.name, $_.kind, $_.role, $_.status) }
    foreach ($b in $pack.mcp.pool) {
        $n = @($pool | Where-Object { $_.key -eq $b.key -and $_.status -in $activeStates })
        Write-Host ("  pool {0}NN: non-retired [{1}] -> {2}" -f $LOC.mcp.servers[$b.key].base, (@($n.name) -join ', '), $(if ($n.Count -le 1) { 'OK' } else { 'KO: more than one non-retired instance (duplicate tools)' }))
    }
    $t = Get-TenantExtServers
    Write-Host "=== ext_ servers in the tenant: $(if ($null -eq $t) { 'unknown (Compliant Container environment not cached yet: see Urls)' } else { "$($t.Count): $($t -join ', ')" })"
    return
}
# --- Register (local files only: payload + state; the operator runs the printed a365 command) --------------------
if ($Action -eq 'Register') {
    if (-not $Server -and -not $Role) { throw 'Register needs -Server <long-lived key> or -Role live|rehearsal|spare (pool).' }
    $isPool = [bool]$Role
    if ($isPool) { $key = [string](Get-PoolDef $Role).key }
    else {
        $key = $Server
        if ($longKeys -notcontains $key) { throw "'$key' is not a long-lived server of pack '$($cfg.pack)' ($($longKeys -join ', ')); pool servers are registered with -Role." }
    }
    $ls = $LOC.mcp.servers[$key]
    $v = @(& (Join-Path $PSScriptRoot 'Test-DemoPack.ps1') -Pack $cfg.pack -Locale $cfg.locale -AsObject | Where-Object { $_.level -eq 'error' })
    if ($v.Count) { throw "Locale '$($cfg.locale)' has $($v.Count) validation error(s): run Test-DemoPack.ps1 -Locale $($cfg.locale) and fix them first." }
    $tenant = Get-TenantExtServers
    if ($null -eq $tenant) { Write-DemoLog $Prefix 'Tenant ext_ servers unknown (Compliant Container environment not cached yet): only state.json is checked for name reuse' 'WARN' }
    $cur = if ($isPool) { $null } else { $state.mcp.servers[$key] }
    $known = @(Get-AllInstances | Where-Object { -not ($cur -and $_.name -eq $cur.name -and $cur.status -eq 'payload') } | ForEach-Object { $_.name }) + @($tenant)
    if ($isPool) {
        $base = [string]$ls.base
        $open = @($pool | Where-Object { $_.key -eq $key -and $_.status -in $activeStates })
        if ($open.Count) { throw "$($base)NN already has a non-retired instance ($(@($open | ForEach-Object { $_.name }) -join ', ')): retire it first (-Action Retire -Name <n>), so the same tools never run on two servers." }
        $used = @($known | ForEach-Object { if ($_ -match "^$([regex]::Escape($base))(\d{2})$") { [int]$Matches[1] } })
        $nn = if ($Number) { $Number } else { [int](($used | Measure-Object -Maximum).Maximum) + 1 }
        if ($nn -lt 1 -or $nn -gt 99) { throw "No free number left for $base (next would be $nn)." }
        if ($used -contains $nn) { throw ('{0}{1:00} was already used (state or tenant): pool numbers are never reused.' -f $base, $nn) }
        $cand = '{0}{1:00}' -f $base, $nn
    }
    else {
        if ($cur -and $cur.status -in $activeStates) { Write-DemoLog $Prefix "$($cur.name) is already registered ($($cur.status)): nothing to do"; return }
        $cand = if ($ServerName) { $ServerName } elseif ($cur -and $cur.status -eq 'payload') { [string]$cur.name } else { [string]$ls.name }
        if ($known -contains $cand) { throw "$cand already exists in this tenant or in state.json: ext_ names are tenant-wide and never reusable; choose another one with -ServerName <ext_ name> (letters/digits after 'ext_', 18 characters at most)." }
    }
    $err = @(Test-ExtMcpServer -Name $cand -Description ([string]$ls.description) | Where-Object { $_.level -eq 'error' })
    if ($err.Count) { throw "Iron rules failed for ${cand}: $(@($err | ForEach-Object { "$($_.field): $($_.message)" }) -join ' | ')" }
    $b = $state.mcp.backends[$key]
    if (-not $b -or -not $b.url) { throw "Backend '$key' is not deployed: run Deploy-DemoMcp.ps1 -Prefix $Prefix -Server $key" }
    $health = try { (Invoke-WebRequest -Uri ($b.url -replace '/mcp$', '/health') -TimeoutSec 60 -UseBasicParsing).StatusCode } catch { 'no response' }
    if ($health -ne 200) { throw "Backend $($b.url) is not healthy ($health): redeploy it with Deploy-DemoMcp.ps1 -Prefix $Prefix -Server $key" }
    $exposed = @(Get-DemoMcpBackendTools $b.url | Sort-Object)
    $tools = @(Get-LocaleTools $key)
    $declared = @($tools | ForEach-Object { $_.name } | Sort-Object)
    if (($exposed -join ',') -ne ($declared -join ',')) { throw "Backend $($b.url) exposes [$($exposed -join ', ')] but locale '$($cfg.locale)' declares [$($declared -join ', ')]: redeploy it with Deploy-DemoMcp.ps1." }
    New-Item -ItemType Directory -Force -Path $regDir | Out-Null
    $payloadPath = Join-Path $regDir "register-$cand.json"
    [ordered]@{ serverName = $cand; serverUrl = $b.url; authType = 'NoAuth'; description = [string]$ls.description; publisherName = [string]$LOC.org.publisher
        tools = $tools; remoteScopes = $null; externalOAuth = $null; apiKey = $null } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $payloadPath -Encoding utf8
    $entry = [ordered]@{ name = $cand; key = $key; status = 'payload'; payload = $payloadPath; url = $b.url; tools = $declared; payloadAt = (Get-Date).ToString('s') }
    if ($isPool) {
        foreach ($p in @($pool | Where-Object { $_.key -eq $key -and $_.status -eq 'payload' })) { $p.status = 'abandoned' }
        $entry['role'] = $Role; $entry['number'] = $nn; $pool.Add($entry)
    }
    else { $state.mcp.servers[$key] = $entry }
    Save-State
    $conn = Get-ExtMcpProxyConnectorId -Name $cand
    Write-DemoLog $Prefix "MCP payload ready: $cand ($(if ($isPool) { "pool, role $Role" } else { 'long-lived' }); name $($cand.Length) chars, proxy connector $($conn.Length) chars; backend tools [$($declared -join ', ')] match)"
    Write-Host ''
    Write-Host 'Run this in a REAL terminal (the CLI asks "Proceed with registration? (y/N)": answer y; do not pipe the command):' -ForegroundColor Cyan
    Write-Host "  cd `"$regDir`"; a365 develop-mcp register-external-mcp-server -f `"register-$cand.json`""
    Write-Host "When it prints 'has been registered successfully':  New-DemoMcpRegistration.ps1 -Prefix $Prefix -Action Confirm -Name $cand"
    Write-Host 'If it fails, the name may stay reserved: run Register again (the pool takes the next number; a long-lived server needs -ServerName).'
    return
}
function Find-Instance([string]$N) {
    if (-not $N) { throw "-Action $Action needs -Name <ext_ server name>." }
    foreach ($k in @($state.mcp.servers.Keys)) { if ($state.mcp.servers[$k].name -eq $N) { return $state.mcp.servers[$k] } }
    $p = $pool | Where-Object { $_.name -eq $N } | Select-Object -First 1
    if (-not $p) { throw "$N is not a demo MCP server of lab $Prefix (see -Action Status)." }
    return $p
}

# --- Confirm: backing apps + approval consents + BYO audience ---------------------------------------------------
if ($Action -eq 'Confirm') {
    $e = Find-Instance $Name
    Assert-DemoTenant $cfg
    $r = @()
    for ($try = 1; $try -le 3 -and -not $r.Count; $try++) {
        if ($try -gt 1) { Write-Host "  backing apps not visible yet (directory replication): retry $try/3 in 20 s..."; Start-Sleep -Seconds 20 }
        try { $r = @(& (Join-Path $customMcp 'preempt-proxy-consents.ps1') -Server $Name -Subscription ([string]$cfg.subscriptionId) -PassThru | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['byoAudience'] }) }
        catch { Write-DemoLog $Prefix "preempt-proxy-consents.ps1 -Server ${Name}: $($_.Exception.Message)" 'WARN' }
    }
    if (-not $r.Count) {
        $e.status = 'failed'; Save-State
        throw "${Name}: backing apps not found, the registration did not complete. Run Register again (a failed name is never reused)."
    }
    $e.status = 'pending'; $e.audience = [string]$r[0].byoAudience; $e.proxyAppId = [string]$r[0].proxyAppId; $e.publicClientsAppId = [string]$r[0].publicClientsAppId
    $e.registeredAt = (Get-Date).ToString('s')
    Save-State
    Write-DemoLog $Prefix "$Name registered: approval consents pre-empted, BYO audience $($e.audience), status pending"
    if ($e.role -eq 'live') { Write-Host "MANUAL: leave $Name PENDING (admin center > Agents > Tools > Requests): it is approved live in D6." }
    else {
        Write-Host "MANUAL: Microsoft 365 admin center > Agents > Tools > Requests > $Name > Approve (watch for a blocked popup)."
        Write-Host "Then:   New-DemoMcpRegistration.ps1 -Prefix $Prefix -Action Approved -Name $Name"
    }
    if (-not $e.role) { Write-Host 'Re-run New-DemoLabPlan.ps1 now: the web UI tab of the OBO agent needs this audience (byoMcpAudiences).' }
    return
}

# --- Approved: record the admin approval, then give the connection URL -----------------------------------------
if ($Action -eq 'Approved') {
    $e = Find-Instance $Name
    if ($e.status -notin $activeStates) { throw "$Name is '$($e.status)': run -Action Confirm first." }
    $e.status = 'approved'; $e.approvedAt = (Get-Date).ToString('s'); Save-State
    Write-DemoLog $Prefix "$Name approved in the admin center"
    $Action = 'Urls'
}

# --- Urls: connectionsMcp URL per approved server, BEFORE any test that uses it ---------------------------------
if ($Action -eq 'Urls') {
    $names = if ($Name) { @($Name) } else { @(Get-AllInstances | Where-Object { $_.status -eq 'approved' -and $_.kind -eq 'long-lived' } | ForEach-Object { $_.name }) }
    if (-not $names.Count) { Write-Host 'No approved long-lived demo MCP server yet (pass -Name for a pool server).'; return }
    Assert-DemoTenant $cfg
    $p = @{ Server = $names; PassThru = $true }
    if ($EnvironmentId) { $p['EnvironmentId'] = $EnvironmentId }
    $urls = @()
    try { $urls = @(& (Join-Path $customMcp 'print-connection-urls.ps1') @p | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['url'] }) }
    catch {
        $agent = @($pack.agents | Where-Object { $_.variant -like '*-OBO' -and @($_.tools) -contains "mcp:$((Find-Instance $names[0]).key)" }) | Select-Object -First 1
        $who = if ($agent) { "the web UI tab of '$($LOC.agents[$agent.key].displayName)'" } else { 'an OBO agent that has the server attached' }
        Write-Host "The Power Platform environment of the ext_ connectors is not known yet in this tenant (first time only)." -ForegroundColor Yellow
        Write-Host "  1. In $who send:  $(([string]$LOC.prompts.mcpSetupUrl).Replace('{server}', $names[0]))"
        Write-Host '  2. Copy the environmentName=<id> value of the URL it returns.'
        Write-Host "  3. Run:  New-DemoMcpRegistration.ps1 -Prefix $Prefix -Action Urls -EnvironmentId <id>   (cached per tenant afterwards)"
        return
    }
    foreach ($u in $urls) {
        $e = Find-Instance $u.server
        $e.connectionUrl = $u.url; $state.mcp['environmentId'] = $u.environmentId
        $users = @($pack.tests | Where-Object { $_.needsConnection -eq $e.key } | ForEach-Object { @($_.persona) + @($_.personas) } | Where-Object { $_ -and $_ -ne 'anyone' } | Select-Object -Unique)
        Write-Host ("{0}: every user below opens it ONCE, signed in as themselves, and creates the connection BEFORE the tests:" -f $u.server) -ForegroundColor Green
        Write-Host "  $($u.url)"
        foreach ($k in $users) { Write-Host ("    - {0} ({1}@{2})" -f (Get-DemoPersonaDisplayName $LOC $k), (Get-DemoPersonaAlias $LOC $k), $cfg.domain) }
    }
    Save-State
    Write-DemoLog $Prefix "Connection URLs recorded for: $(@($urls | ForEach-Object { $_.server }) -join ', ')"
    return
}

# --- Retire (pool only): Reject / Block by hand, then -Confirmed records it -------------------------------------
if ($Action -eq 'Retire') {
    $targets = if ($Name) { @($pool | Where-Object { $_.name -eq $Name }) }
               elseif ($Role) { $d = Get-PoolDef $Role; @($pool | Where-Object { $_.key -eq $d.key -and $_.status -in $activeStates }) }
               elseif ($All) { @($pool | Where-Object { $_.status -in $activeStates -or $_.status -eq 'payload' }) }
               else { throw 'Retire needs -Name, -Role or -All.' }
    if ($Name -and -not $targets.Count) { throw "$Name is not a pool instance (long-lived servers are retired only by the teardown)." }
    if (-not $targets.Count) { Write-Host 'Nothing to retire.'; return }
    foreach ($t in $targets) {
        if ($t.status -eq 'payload') { $t.status = 'abandoned'; Write-DemoLog $Prefix "MCP pool: $($t.name) was never registered: marked abandoned"; continue }
        if ($Confirmed) { $t.status = 'retired'; $t.retiredAt = (Get-Date).ToString('s'); Write-DemoLog $Prefix "MCP pool: $($t.name) retired (rejected/blocked in the admin center)"; continue }
        $where = if ($t.status -eq 'pending') { "Requests > $($t.name) > Reject" } else { "$($t.name) > Block" }
        Write-Host "MANUAL for $($t.name) [$($t.status)]: Microsoft 365 admin center > Agents > Tools > $where (the platform delete API fails for ext_ servers)."
        Write-Host "  Then: New-DemoMcpRegistration.ps1 -Prefix $Prefix -Action Retire -Name $($t.name) -Confirmed"
    }
    Save-State
}
