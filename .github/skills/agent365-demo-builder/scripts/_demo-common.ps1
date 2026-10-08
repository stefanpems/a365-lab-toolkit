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
        param($m) $v = ConvertTo-DemoText (Resolve-DemoPath $Locale $m.Groups[1].Value); if ($null -eq $v) { "<missing $($m.Groups[1].Value)>" } else { $v } })
    return [regex]::Replace($t, '\{(upn|name|agent|group|folder|cfg|state|pack|slot|tagged):([A-Za-z0-9_.\-]+)\}', [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $k = $m.Groups[2].Value
        $known = $k -eq 'admin' -or ($Locale.personas -and $Locale.personas.Contains($k))
        $v = switch ($m.Groups[1].Value) {
            'upn' { if ($known) { Get-DemoUpn $Locale $Config $k } }
            'name' { if ($k -eq 'admin') { 'the tenant administrator' } elseif ($known) { Get-DemoPersonaDisplayName $Locale $k } }
            'agent' { [string]$Locale.agents[$k].displayName }
            'group' { [string]$Locale.groups[$k].displayName }
            'folder' { [string]$Locale.knowledge.folders[$k] }
            'cfg' { ConvertTo-DemoText (Resolve-DemoPath $Config $k) }
            'state' { ConvertTo-DemoText (Resolve-DemoPath $State $k) }
            'pack' { ConvertTo-DemoText (Resolve-DemoPath $Pack $k) }
            'slot' { Get-DemoSlotText $k ([string]$Config.pack) }
            'tagged' { (@($Pack.agents | Where-Object { @($_.tags) -contains $k } | ForEach-Object { [string]$Locale.agents[$_.key].displayName }) -join ', ') }
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
    if (-not $Config -or -not $Config.azConfigDir) { return }
    $dir = if ([IO.Path]::IsPathRooted([string]$Config.azConfigDir)) { [string]$Config.azConfigDir } else { Join-Path $script:DemoRepoRoot ([string]$Config.azConfigDir) }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $env:AZURE_CONFIG_DIR = $dir
    if (-not $env:AZURE_EXTENSION_DIR) { $env:AZURE_EXTENSION_DIR = Join-Path $HOME '.azure\cliextensions' }
}

# The command line the operator (or the agent) runs to sign in to the lab's az profile.
function Get-DemoAzLoginCommand($Config) {
    $p = if ($Config.azConfigDir) { "`$env:AZURE_CONFIG_DIR='$($env:AZURE_CONFIG_DIR)'; `$env:AZURE_EXTENSION_DIR='$($env:AZURE_EXTENSION_DIR)'; " } else { '' }
    "${p}az login --tenant $($Config.tenantId)"
}

function Read-DemoLabState([Parameter(Mandatory)][string]$Prefix) {
    $f = Join-Path (Get-DemoLabDir $Prefix) 'state.json'
    if (Test-Path -LiteralPath $f) { return (Get-Content -LiteralPath $f -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable) }
    return [ordered]@{ prefix = $Prefix; users = [ordered]@{}; groups = [ordered]@{}; agents = [ordered]@{}; mcp = [ordered]@{ servers = [ordered]@{}; pool = @() }; knowledge = [ordered]@{}; governance = [ordered]@{} }
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
    $cache = Join-Path (Get-DemoLabDir $Prefix) "secrets\$CacheName"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cache) | Out-Null
    $pyArgs = @('--tenant', $TenantId, '--client', $ClientId, '--scopes', ($Scopes -join ','), '--cache', $cache, '--hint', "$LoginHint")
    if ($SilentOnly) { $pyArgs += '--silent-only' }
    if ($ForceRefresh) { $pyArgs += '--force-refresh' }
    $tok = python (Join-Path $script:DemoScriptsDir 'py\msal_token.py') @pyArgs
    if ($SilentOnly -and $LASTEXITCODE -eq 3) { return $null }
    if ($LASTEXITCODE -ne 0 -or -not $tok) { throw 'MSAL token acquisition failed (see the message above).' }
    return [string]($tok | Select-Object -Last 1)
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
                if ($status -eq 401 -and -not $Token -and "$($_.ErrorDetails.Message)" -match 'InteractionRequired|TokenIssuedBeforeRevocationTimestamp|AADSTS50173|AADSTS700082') {
                    # The az session was revoked (CAE) or expired. az keeps its cached 24 h CAE token even after a new
                    # 'az login': log out first, then sign in again interactively.
                    $msg += " | The az sign-in is no longer valid (revoked sessions keep failing until the cached token is dropped): $(if ($env:AZURE_CONFIG_DIR) { "`$env:AZURE_CONFIG_DIR='$($env:AZURE_CONFIG_DIR)'; " })az logout; az login --tenant <tenant id>   (interactive browser)"
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
