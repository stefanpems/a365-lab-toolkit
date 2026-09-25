# Web access (fetch_url) — ALWAYS ON for the 8 code agent types (ACA/FH/FD x OBO/S2S/DW); MCS excluded.
#
#  * ACA-* and FH-* carry fetch_url IN-PROCESS: the samples import web_fetch.py (copied with the sample by
#    the router's robocopy) and register it as an Agent Framework function tool. Nothing to scaffold.
#  * FD-* (prompt agents) run no code, so they reach fetch_url through the lab's web-fetch MCP server
#    (web-fetch-mcp/): this module copies it to <RunRoot>\<prefix>-webfetch, rewrites the constants of
#    deploy-web-fetch.ps1 and emits ONE Phase-1 next-command (before the agents). That script writes
#    WEB_FETCH_MCP_URL into every FD agent's .env ONLY after an MCP smoke test passes (else it clears it,
#    so an FD agent is never deployed with a broken MCP tool). Emitted only when the plan has FD agents.
# Reads $plan / $repoRoot / $RunRoot / $nextCommands from the router scope.

# Every sample that ships a copy of web_fetch.py (keep them byte-identical to web-fetch-mcp/web_fetch.py).
$WebFetchCopies = @(
    'aca\obo', 'aca\s2s', 'aca\dw',
    'foundry-hosted\obo', 'foundry-hosted\s2s', 'foundry-hosted\dw\src\hello_world_a365_agent'
)

function Test-WebFetchCopies {
    # Warn-only consistency check: a drifted copy means one family runs a different fetch_url.
    $canon = Join-Path $repoRoot 'web-fetch-mcp\web_fetch.py'
    if (-not (Test-Path -LiteralPath $canon)) { Write-Host "  WARN web access: web-fetch-mcp\web_fetch.py not found." -ForegroundColor Yellow; return }
    $h = (Get-FileHash -LiteralPath $canon -Algorithm SHA256).Hash
    foreach ($d in $WebFetchCopies) {
        $p = Join-Path $repoRoot (Join-Path $d 'web_fetch.py')
        if (-not (Test-Path -LiteralPath $p)) { Write-Host "  WARN web access: $d\web_fetch.py is missing - that agent family would fail to import it." -ForegroundColor Yellow }
        elseif ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash -ne $h) { Write-Host "  WARN web access: $d\web_fetch.py differs from web-fetch-mcp\web_fetch.py (keep every copy byte-identical)." -ForegroundColor Yellow }
    }
}

function Get-WebFetchNames {
    # Deterministic lab-owned names (prefix is validated lowercase-alphanumeric, <= 12 chars).
    $p = $plan.solution.prefix
    [pscustomobject]@{
        Folder  = "$p-webfetch"
        Rg      = "$p-webfetch-rg"
        Env     = "$p-webfetch-cae"
        App     = "$p-webfetch-ca"
        Repo    = "$p-webfetch"
        UrlFile = (Join-Path $RunRoot 'web-fetch-mcp-url.txt')
    }
}

function Get-WebFetchUrlForFd {
    # URL persisted by a previous deploy-web-fetch.ps1 run (re-scaffold safe). Reused ONLY if the endpoint
    # still answers /health (read-only GET) — a stale URL (deleted container) would break every FD turn.
    $n = Get-WebFetchNames
    if (-not (Test-Path -LiteralPath $n.UrlFile)) { return '' }
    $url = (Get-Content -LiteralPath $n.UrlFile -Raw).Trim()
    if ($url -notmatch '^https://[^/]+/mcp$') { return '' }
    try {
        $r = Invoke-WebRequest -Uri ($url -replace '/mcp$', '/health') -TimeoutSec 10 -UseBasicParsing
        if ([int]$r.StatusCode -eq 200) { return $url }
    } catch { }
    Write-Host "    web access: persisted web-fetch URL does not answer /health; leaving WEB_FETCH_MCP_URL empty until deploy-web-fetch.ps1 runs." -ForegroundColor DarkYellow
    return ''
}

function Invoke-ScaffoldWebFetch {
    $fdAgents = @($plan.agents | Where-Object { $_.type -in @('FD-OBO', 'FD-S2S') })
    if ($fdAgents.Count -eq 0) { return }
    $src = Join-Path $repoRoot 'web-fetch-mcp'
    if (-not (Test-Path -LiteralPath (Join-Path $src 'deploy-web-fetch.ps1'))) {
        Write-Host "  SKIP web-fetch MCP: sample 'web-fetch-mcp' not found - the FD agents will deploy without web access." -ForegroundColor Yellow
        return
    }
    $n = Get-WebFetchNames
    $dst = Join-Path $RunRoot $n.Folder
    if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    $null = robocopy $src $dst /E /XD '.venv' '__pycache__' /XF '*.pyc' '.env' /NFL /NDL /NJH /NJS /NP /NC /NS
    if ($LASTEXITCODE -ge 8) { Write-Host "  robocopy failed for web-fetch-mcp (code $LASTEXITCODE)" -ForegroundColor Red; return }

    # FD agent .env files that receive the verified URL (the FD folders are scaffolded in Phase 2, BEFORE
    # this command is executed, so the paths exist at run time).
    $envFiles = @($fdAgents | ForEach-Object { Join-Path (Join-Path $RunRoot $_.name) '.env' })
    $envLit = '@(' + (($envFiles | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', ') + ')'
    $urlLit = "'" + ($n.UrlFile -replace "'", "''") + "'"

    $depPath = Join-Path $dst 'deploy-web-fetch.ps1'
    $txt = Get-Content -LiteralPath $depPath -Raw
    $txt = [regex]::Replace($txt, '(\$RG\s*=\s*)"[^"]*"',      "`$1`"$($n.Rg)`"")
    $txt = [regex]::Replace($txt, '(\$ENVNAME\s*=\s*)"[^"]*"', "`$1`"$($n.Env)`"")
    $txt = [regex]::Replace($txt, '(\$LOC\s*=\s*)"[^"]*"',     "`$1`"$($plan.solution.region)`"")
    $txt = [regex]::Replace($txt, '(\$REPO\s*=\s*)"[^"]*"',    "`$1`"$($n.Repo)`"")
    $txt = [regex]::Replace($txt, '(\$APP\s*=\s*)"[^"]*"',     "`$1`"$($n.App)`"")
    $txt = [regex]::Replace($txt, '(\$LAB\s*=\s*)"[^"]*"',     "`$1`"$($plan.solution.prefix)`"")
    $txt = [regex]::Replace($txt, '(\$FD_ENV_FILES\s*=\s*)@\([^)]*\)', { param($m) $m.Groups[1].Value + $envLit })
    $txt = [regex]::Replace($txt, '(\$URL_FILE\s*=\s*)"[^"]*"', { param($m) $m.Groups[1].Value + $urlLit })
    Set-Content -LiteralPath $depPath -Value $txt -Encoding utf8
    Write-Host "  scaffolded web-fetch MCP -> generated\$($plan.solution.prefix)\$($n.Folder) (web access for $($fdAgents.Count) FD agent(s))" -ForegroundColor Cyan

    $nextCommands.Add("cd `"$dst`"; .\deploy-web-fetch.ps1 -Subscription $($plan.solution.subscriptionId)   # WEB ACCESS for the FD agents (fetch_url): non-interactive (~3-5 min); deploys ONE anonymous MCP container ($($n.App) in $($n.Rg), tagged a365lab=$($plan.solution.prefix)) and, ONLY after its MCP smoke test passes, writes WEB_FETCH_MCP_URL into every FD agent's .env. Run it BEFORE the FD deploys. If it fails it clears the URL and the FD agents still deploy (without web access) - never block the lab on it; fix + re-run, then redeploy the FD agents. ACA/FH agents need nothing (in-process fetch_url).")
}
