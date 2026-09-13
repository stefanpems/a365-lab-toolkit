#requires -Version 7.0
<#
.SYNOPSIS
  READ-ONLY. Render a lab-state dashboard as a self-contained HTML page.

.DESCRIPTION
  Companion to Get-LabState.ps1. It does NOT talk to Azure / Graph itself — it consumes the
  machine-readable `state.json` that Get-LabState.ps1 already produced and renders a single, self-
  contained HTML file (inline CSS, no external assets) with a FIXED macro-structure:

    1. Header (lab name, tenant, subscription, generated timestamp, plan source)
    2. Legend
    3. Acronyms
    4. Summary
    5. Web UI
    6. Custom MCP
    7. Agents
    8. Shared Foundry (create-shared)        - only when present
    9. Shared Azure OpenAI (create-shared)   - only when present
   10. Digital Worker instances & licenses
   11. Entra recycle bin (pending purge)     - only when present
   12. Footer

  The macro-structure is identical for every lab: the core sections (Web UI, Custom MCP, Agents, DW)
  always render — with a placeholder note when a lab does not include them — while the optional
  sections (shared Foundry, shared Azure OpenAI, recycle bin) render only when the state has data for
  them. This lets a single template host any lab configuration.

  Two ways to call it:
    - Give it an existing `state.json` (preferred; fully offline, no cloud calls):
        pwsh -File .\Get-LabStateHtml.ps1 -StateJsonPath <path-to-state.json>
    - Give it a lab name + context and let it generate a fresh state first (invokes Get-LabState.ps1):
        pwsh -File .\Get-LabStateHtml.ps1 -LabName a09091 -Subscription <sub> -TenantId <tenant>

.PARAMETER StateJsonPath
  Path to a `state.json` produced by Get-LabState.ps1. When supplied, no cloud calls are made.

.PARAMETER LabName
  Lab name / solution prefix. Used (with -Subscription / -TenantId) to generate a fresh state first.

.PARAMETER Subscription
  Target subscription id (only needed when generating a fresh state).

.PARAMETER TenantId
  Expected tenant id (only needed when generating a fresh state).

.PARAMETER OutFile
  Optional output path for the HTML. Defaults to `report.html` next to the source `state.json`.

.EXAMPLE
  pwsh -File .\Get-LabStateHtml.ps1 -StateJsonPath .\generated\lab-reporter\a09091-20260911-121332\state.json
#>
[CmdletBinding()]
param(
    [string]$StateJsonPath,
    [string]$LabName,
    [string]$Subscription,
    [string]$TenantId,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ---------------------------------------------------------------------------
# Resolve the state.json: use the one supplied, or generate a fresh one.
# ---------------------------------------------------------------------------
if (-not $StateJsonPath) {
    if (-not $LabName) { throw "Provide -StateJsonPath, or -LabName (+ -Subscription / -TenantId) to generate a fresh state." }
    $genArgs = @('-LabName', $LabName)
    if ($Subscription) { $genArgs += @('-Subscription', $Subscription) }
    if ($TenantId) { $genArgs += @('-TenantId', $TenantId) }
    $stateScript = Join-Path $PSScriptRoot 'Get-LabState.ps1'
    Write-Host "No -StateJsonPath supplied; generating a fresh state via Get-LabState.ps1..." -ForegroundColor Cyan
    $reportMd = & $stateScript @genArgs | Select-Object -Last 1
    if (-not $reportMd) { throw "Get-LabState.ps1 did not return a report path." }
    $StateJsonPath = Join-Path (Split-Path -Parent $reportMd) 'state.json'
}
if (-not (Test-Path -LiteralPath $StateJsonPath)) { throw "state.json not found: $StateJsonPath" }
$state = Get-Content -LiteralPath $StateJsonPath -Raw | ConvertFrom-Json

if (-not $OutFile) { $OutFile = Join-Path (Split-Path -Parent $StateJsonPath) 'report.html' }

# ---------------------------------------------------------------------------
# Small rendering helpers.
# ---------------------------------------------------------------------------
function HtmlEncode { param([string]$Text) if ($null -eq $Text) { return '' } return [System.Net.WebUtility]::HtmlEncode([string]$Text) }
function Status-Badge {
    param([string]$State)
    $map = @{
        ok   = @{ cls = 'ok';   sym = '✅' }
        warn = @{ cls = 'warn'; sym = '🟡' }
        fail = @{ cls = 'fail'; sym = '❌' }
        na   = @{ cls = 'na';   sym = '⚪' }
        info = @{ cls = 'info'; sym = '🔵' }
    }
    $m = if ($map.ContainsKey($State)) { $map[$State] } else { $map['na'] }
    return "<span class='badge $($m.cls)'>$($m.sym)</span>"
}
function Bool-Badge { param($Value) if ($Value) { "<span class='badge ok'>✅</span>" } else { "<span class='badge fail'>❌</span>" } }

$sb = New-Object System.Text.StringBuilder
function W { param([string]$Line) [void]$sb.AppendLine($Line) }

# Render a 6-column resource table (Object | Layer | Name | Exists | Status | Details).
function Write-ResSection {
    param([string]$Id, [string]$Title, $Rows, [string]$EmptyNote)
    W "<section id='$Id'>"
    W "  <h2>$(HtmlEncode $Title)</h2>"
    if (-not $Rows -or @($Rows).Count -eq 0) {
        W "  <p class='empty'>$(HtmlEncode $EmptyNote)</p>"
        W "</section>"
        return
    }
    W "  <table>"
    W "    <thead><tr><th>Object</th><th>Layer</th><th>Name</th><th class='c'>Exists</th><th class='c'>Status</th><th>Details</th></tr></thead>"
    W "    <tbody>"
    foreach ($r in @($Rows)) {
        W ("      <tr><td>{0}</td><td>{1}</td><td><code>{2}</code></td><td class='c'>{3}</td><td class='c'>{4}</td><td>{5}</td></tr>" -f `
            (HtmlEncode $r.object), (HtmlEncode $r.layer), (HtmlEncode $r.name), (Bool-Badge $r.exists), (Status-Badge $r.state), (HtmlEncode $r.details))
    }
    W "    </tbody>"
    W "  </table>"
    W "</section>"
}

# ---------------------------------------------------------------------------
# Page head + fixed styling.
# ---------------------------------------------------------------------------
$css = @'
:root{color-scheme:light dark}
*{box-sizing:border-box}
body{font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;margin:0;padding:0 0 3rem;line-height:1.5;color:#1b1f23;background:#f6f8fa}
header.top{background:#0b3d66;color:#fff;padding:1.5rem 2rem}
header.top h1{margin:0 0 .5rem;font-size:1.5rem}
header.top .meta{font-size:.85rem;opacity:.9;display:grid;grid-template-columns:max-content 1fr;gap:.15rem 1rem}
header.top .meta dt{font-weight:600}
header.top .meta dd{margin:0;font-family:ui-monospace,SFMono-Regular,Consolas,monospace}
main{max-width:1100px;margin:0 auto;padding:0 1rem}
section{background:#fff;border:1px solid #d0d7de;border-radius:8px;padding:1rem 1.25rem;margin:1.25rem 0}
h2{margin:.2rem 0 .8rem;font-size:1.15rem;border-bottom:1px solid #eaecef;padding-bottom:.35rem}
table{width:100%;border-collapse:collapse;font-size:.88rem}
th,td{text-align:left;padding:.4rem .5rem;border-bottom:1px solid #eaecef;vertical-align:top}
th{background:#f0f3f6;font-weight:600}
th.c,td.c{text-align:center}
code{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;background:#f0f3f6;padding:.05rem .3rem;border-radius:4px;font-size:.85em}
.badge{font-size:1rem}
.legend{display:flex;flex-wrap:wrap;gap:.5rem 1.25rem;font-size:.85rem}
.legend span{white-space:nowrap}
.glossary{display:grid;grid-template-columns:max-content 1fr;gap:.3rem 1rem;font-size:.88rem}
.glossary dt{font-weight:700;font-family:ui-monospace,SFMono-Regular,Consolas,monospace}
.glossary dd{margin:0}
.summary{display:flex;flex-wrap:wrap;gap:.75rem}
.card{flex:1 1 180px;border:1px solid #d0d7de;border-radius:8px;padding:.75rem 1rem;background:#f6f8fa}
.card .n{font-size:1.5rem;font-weight:700}
.card .l{font-size:.8rem;color:#57606a}
.empty{color:#57606a;font-style:italic}
footer{max-width:1100px;margin:1.5rem auto 0;padding:0 1rem;font-size:.8rem;color:#57606a}
@media (prefers-color-scheme:dark){
  body{background:#0d1117;color:#c9d1d9}
  section{background:#161b22;border-color:#30363d}
  h2{border-color:#30363d}
  th{background:#21262d}
  th,td{border-color:#21262d}
  code,.card{background:#21262d}
  .card{border-color:#30363d}
  .card .l,.empty,footer{color:#8b949e}
}
'@

$title = "Lab state report — $($state.labName)"
W "<!doctype html>"
W "<html lang='en'>"
W "<head>"
W "  <meta charset='utf-8'>"
W "  <meta name='viewport' content='width=device-width, initial-scale=1'>"
W "  <title>$(HtmlEncode $title)</title>"
W "  <style>$css</style>"
W "</head>"
W "<body>"

# 1. Header.
W "<header class='top'>"
W "  <h1>Lab state report — <code>$(HtmlEncode $state.labName)</code></h1>"
W "  <dl class='meta'>"
W "    <dt>Tenant</dt><dd>$(HtmlEncode $state.tenantId)</dd>"
W "    <dt>Subscription</dt><dd>$(HtmlEncode $state.subscription)</dd>"
W "    <dt>Generated</dt><dd>$(HtmlEncode $state.generatedUtc)</dd>"
W "    <dt>Plan source</dt><dd>$(HtmlEncode $state.planSource)</dd>"
W "  </dl>"
W "</header>"
W "<main>"

# 2. Legend.
W "<section id='legend'>"
W "  <h2>Legend</h2>"
W "  <div class='legend'>"
W "    <span>✅ present &amp; healthy</span><span>🟡 present, provisioning/degraded</span><span>❌ missing or failed</span><span>⚪ not part of this lab</span><span>🔵 informational</span>"
W "  </div>"
W "</section>"

# 3. Acronyms (from state.acronyms; fall back to a built-in glossary for older state.json files).
$acr = $state.acronyms
if (-not $acr) {
    $acr = [pscustomobject]@{
        MAF = 'Microsoft Agent Framework — the framework the sample agents are currently built with.'
        ACA = 'Azure Container Apps — agent hosting on the managed container platform.'
        FH  = 'Foundry Hosted — agent hosting managed by Azure AI Foundry.'
        FD  = 'Foundry Declarative — a prompt (declarative) agent defined in Azure AI Foundry.'
        OBO = 'On-Behalf-Of — the agent acts using the signed-in user''s delegated identity.'
        S2S = 'Service-to-Service — the agent acts with its own application identity.'
        DW  = 'Digital Worker — an AI-teammate agent hired as an agent user (holds a Frontier / Agent 365 license).'
    }
}
W "<section id='acronyms'>"
W "  <h2>Acronyms</h2>"
W "  <dl class='glossary'>"
foreach ($p in $acr.PSObject.Properties) {
    W "    <dt>$(HtmlEncode $p.Name)</dt><dd>$(HtmlEncode $p.Value)</dd>"
}
W "  </dl>"
W "</section>"

# 4. Summary (computed from the state arrays so it holds for any configuration).
# Denominators count only SIGNIFICANT rows (ok/warn/fail); informational (🔵) and not-part-of-this-lab
# (⚪) rows are excluded so they never inflate the X / Y health ratio.
function Measure-Significant { param($Rows) @($Rows | Where-Object { $_.state -in @('ok', 'warn', 'fail') }).Count }
$agents = @($state.agents)
$agSig = @($agents | Where-Object { $_.overall -in @('ok', 'warn', 'fail') })
$agHealthy = @($agSig | Where-Object { $_.overall -eq 'ok' }).Count
$agTotal = @($agSig).Count
$webui = @($state.webui)
$mcp = @($state.customMcp)
$dwLab = @($state.dwInstances.lab)
$dwOther = @($state.dwInstances.other)
W "<section id='summary'>"
W "  <h2>Summary</h2>"
W "  <div class='summary'>"
W "    <div class='card'><div class='n'>$agHealthy / $agTotal</div><div class='l'>Agents healthy</div></div>"
if ($webui.Count -gt 0) { $uiOk = @($webui | Where-Object { $_.state -eq 'ok' }).Count; W "    <div class='card'><div class='n'>$uiOk / $(Measure-Significant $webui)</div><div class='l'>Web UI objects healthy</div></div>" }
if ($mcp.Count -gt 0) { $mcpOk = @($mcp | Where-Object { $_.state -eq 'ok' }).Count; W "    <div class='card'><div class='n'>$mcpOk / $(Measure-Significant $mcp)</div><div class='l'>Custom MCP objects healthy</div></div>" }
W "    <div class='card'><div class='n'>$($dwLab.Count)</div><div class='l'>DW instances (lab-matched)</div></div>"
W "  </div>"
W "</section>"

# 5. Web UI.
Write-ResSection 'webui' '1. Web UI' $state.webui 'No web UI in this lab.'
# 6. Custom MCP.
Write-ResSection 'mcp' '2. Custom MCP' $state.customMcp 'No custom MCP in this lab.'

# 7. Agents.
W "<section id='agents'>"
W "  <h2>3. Agents</h2>"
if ($agents.Count -eq 0) {
    W "  <p class='empty'>No agents discovered for this lab.</p>"
}
else {
    W "  <table>"
    W "    <thead><tr><th>Agent</th><th>Type</th><th class='c'>Resource group</th><th>Compute</th><th>Entra Agent ID</th><th class='c'>Overall</th></tr></thead>"
    W "    <tbody>"
    foreach ($r in $agents) {
        $cp = (Status-Badge $r.computeState) + ' ' + (HtmlEncode $r.computeDetail)
        $en = (Status-Badge $r.entraState) + ' ' + (HtmlEncode $r.entraDetail)
        W ("      <tr><td><code>{0}</code></td><td>{1}</td><td class='c'>{2}</td><td>{3}</td><td>{4}</td><td class='c'>{5}</td></tr>" -f `
            (HtmlEncode $r.name), (HtmlEncode $r.type), (Status-Badge $r.rgState), $cp, $en, (Status-Badge $r.overall))
    }
    W "    </tbody>"
    W "  </table>"
    W "  <p class='empty'>Entra Agent ID = the agent&#39;s blueprint application (agentIdentityBlueprint), resolved from the durable appId recorded in generated/&lt;lab&gt;/&lt;agent&gt;/ and validated by the a365lab Entra tag. FD agents are declarative (defined in the Foundry project — no Entra blueprint app); MCS agents live in Copilot Studio (Dataverse). Compute: ACA = container app running status; FH = Foundry account provisioning state; FD = prompt agent (no dedicated Azure compute).</p>"
}
W "</section>"

# 8. Shared Foundry (only when present).
if (@($state.sharedFoundry).Count -gt 0) { Write-ResSection 'foundry' '4. Shared Foundry (create-shared)' $state.sharedFoundry 'No shared Foundry resources found.' }
# 9. Shared Azure OpenAI (only when present).
if (@($state.sharedAoai).Count -gt 0) { Write-ResSection 'aoai' '4b. Shared Azure OpenAI (create-shared)' $state.sharedAoai 'No shared Azure OpenAI resources found.' }

# 10. Digital Worker instances & licenses.
W "<section id='dw'>"
W "  <h2>5. Digital Worker instances &amp; licenses</h2>"
if ($dwLab.Count -eq 0) {
    W "  <p class='empty'>No agent-user instances linked to this lab&#39;s blueprints were found (a published-but-not-yet-hired DW has no instances yet).</p>"
    if ($dwOther.Count -gt 0) { W "  <p class='empty'>($($dwOther.Count) other Frontier / Agent 365 license holder(s) exist in the tenant but are not linked to this lab's blueprints — likely other labs.)</p>" }
}
else {
    W "  <table>"
    W "    <thead><tr><th>Instance (display name)</th><th>UPN</th><th class='c'>Enabled</th><th>Licenses</th></tr></thead>"
    W "    <tbody>"
    foreach ($i in $dwLab) {
        $lic = if (@($i.licenses).Count) { (@($i.licenses) -join '; ') } else { '(none)' }
        W ("      <tr><td>{0}</td><td><code>{1}</code></td><td class='c'>{2}</td><td>{3}</td></tr>" -f `
            (HtmlEncode $i.displayName), (HtmlEncode $i.userPrincipalName), (Bool-Badge $i.accountEnabled), (HtmlEncode $lic))
    }
    W "    </tbody>"
    W "  </table>"
    if ($dwOther.Count -gt 0) { W "  <p class='empty'>(Plus $($dwOther.Count) other Frontier / Agent 365 license holder(s) in the tenant not linked to this lab's blueprints — likely other labs; not listed here.)</p>" }
}
W "</section>"

# 11. Entra recycle bin (only when present).
$recycle = @($state.recycleBin)
if ($recycle.Count -gt 0) {
    W "<section id='recycle'>"
    W "  <h2>Entra recycle bin (pending purge)</h2>"
    W "  <table>"
    W "    <thead><tr><th>Kind</th><th>Display name</th><th>Deleted</th></tr></thead>"
    W "    <tbody>"
    foreach ($r in $recycle) {
        W ("      <tr><td>{0}</td><td><code>{1}</code></td><td>{2}</td></tr>" -f (HtmlEncode $r.kind), (HtmlEncode $r.displayName), (HtmlEncode $r.deleted))
    }
    W "    </tbody>"
    W "  </table>"
    W "</section>"
}

W "</main>"
# 12. Footer.
W "<footer>"
W "  Read-only report generated by the Lab Reporter (Get-LabStateHtml.ps1) from <code>$(HtmlEncode (Split-Path -Leaf $StateJsonPath))</code>. No cloud resources were modified."
W "</footer>"
W "</body>"
W "</html>"

Set-Content -LiteralPath $OutFile -Value $sb.ToString() -Encoding utf8
Write-Host ''
Write-Host "Lab state HTML report written to:" -ForegroundColor Green
Write-Host "  $OutFile" -ForegroundColor White
Write-Output $OutFile
