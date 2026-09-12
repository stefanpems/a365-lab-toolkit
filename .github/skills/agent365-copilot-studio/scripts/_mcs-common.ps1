# Shared helpers for the Microsoft Copilot Studio (MCS) agent family (MCS-OH / MCS-NH).
# Dot-source this file; it exposes the base-solution catalog, the pac CLI resolver/installer, and the
# unpack -> rename -> pack transform used to turn a base solution zip into a uniquely named agent.
#
# MCS agents are NOT Azure/Entra agents: they are Power Platform Solutions (Dataverse) imported into a
# Copilot Studio environment via the Power Platform CLI (pac). The two base zips shipped in
# assets/base-solutions/ were captured from a source tenant (see Export-McsBaseSolution.ps1) and are the
# creation base for every MCS agent.

$ErrorActionPreference = 'Stop'

# Resolve the skill root (this file lives in <skill>/scripts) and the base-solutions folder.
$script:McsSkillRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:McsBaseDir     = Join-Path $script:McsSkillRoot 'assets\base-solutions'

# ---------------------------------------------------------------- base-solution catalog
# One entry per harness. Each records the base zip and every token that must be rewritten to produce a
# uniquely named agent. Verified against the zips captured on 2026-09:
#   OH (legacy standard harness, template default-2.1.0): display name "AgentOH2" in 3 places
#     (bot.xml <name>, the gpt botcomponent.xml <name>, the gpt data 'displayName:'); bot schema token
#     "new_AgentOH2"; solution unique "AgentOHSol" / friendly "AgentOH-Sol".
#   NH (GitHub Copilot harness, template cliagent-1.0.0): display name "AgentNH2" in 1 place
#     (bot.xml <name>); bot schema token "cr47b_agentnh2_URxM4c"; solution unique "AgentNHSol" /
#     friendly "AgentNH-Sol".
$script:MCS_BASE = @{
    'OH' = @{
        harness          = 'legacy'
        template         = 'default-2.1.0'
        zip              = 'AgentOHSol.zip'
        displayName      = 'AgentOH2'
        botSchemaToken   = 'new_AgentOH2'
        solutionUnique   = 'AgentOHSol'
        solutionFriendly = 'AgentOH-Sol'
        prereqs          = 'none'   # legacy harness needs no Copilot Credits / PAYG
    }
    'NH' = @{
        harness          = 'ghcp'
        template         = 'cliagent-1.0.0'
        zip              = 'AgentNHSol.zip'
        displayName      = 'AgentNH2'
        botSchemaToken   = 'cr47b_agentnh2_URxM4c'
        solutionUnique   = 'AgentNHSol'
        solutionFriendly = 'AgentNH-Sol'
        prereqs          = 'payg+dataverse+copilotstudio'  # GHCP harness consumes Copilot Credits
    }
}

# Map an agent type ('MCS-OH' / 'MCS-NH' or a bare 'OH' / 'NH') to its base catalog entry.
function Get-McsBase {
    param([Parameter(Mandatory)][string]$Harness)
    $key = ($Harness -replace '(?i)^MCS-', '').ToUpper()
    if (-not $script:MCS_BASE.ContainsKey($key)) {
        throw "Unknown MCS harness '$Harness' (expected MCS-OH / MCS-NH)."
    }
    $entry = $script:MCS_BASE[$key].Clone()
    $entry.key     = $key
    $entry.zipPath = Join-Path $script:McsBaseDir $entry.zip
    return $entry
}

# ---------------------------------------------------------------- pac CLI resolver / installer
# pac is a global dotnet tool. It is REQUIRED for every MCS operation (export/import). Returns the pac
# executable path, or $null when absent and -Install was not requested (or the install failed).
function Get-PacCli {
    [CmdletBinding()]
    param([switch]$Install)

    $toolsDir = Join-Path $env:USERPROFILE '.dotnet\tools'
    if (($env:PATH -split ';') -notcontains $toolsDir) { $env:PATH += ";$toolsDir" }

    $pac = Get-Command pac -ErrorAction SilentlyContinue
    if ($pac) { return $pac.Source }

    $direct = Join-Path $toolsDir 'pac.exe'
    if (Test-Path $direct) { return $direct }

    if (-not $Install) { return $null }

    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        Write-Host "  pac not found and 'dotnet' is unavailable — install the .NET SDK, then rerun with -Install." -ForegroundColor Red
        return $null
    }
    Write-Host "  Installing Power Platform CLI (dotnet tool Microsoft.PowerApps.CLI.Tool)..." -ForegroundColor Cyan
    dotnet tool install --global Microsoft.PowerApps.CLI.Tool 2>&1 | Write-Host
    if (($env:PATH -split ';') -notcontains $toolsDir) { $env:PATH += ";$toolsDir" }
    if (Test-Path $direct) { return $direct }
    $pac = Get-Command pac -ErrorAction SilentlyContinue
    if ($pac) { return $pac.Source }
    Write-Host "  pac install did not produce pac.exe — install it manually: dotnet tool install --global Microsoft.PowerApps.CLI.Tool" -ForegroundColor Red
    return $null
}

# Assert pac is present, or throw a clear, actionable error.
function Assert-PacCli {
    [CmdletBinding()]
    param([switch]$Install)
    $p = Get-PacCli -Install:$Install
    if (-not $p) {
        throw "Power Platform CLI (pac) is required for MCS agents. Install it with: dotnet tool install --global Microsoft.PowerApps.CLI.Tool"
    }
    return $p
}

# ---------------------------------------------------------------- Dataverse bot-id discovery (for removal)
# Deleting a Copilot Studio AGENT needs its bot GUID (pac copilot-studio delete-copilot-agent --bot-id).
# The bot GUID is per-environment (assigned on import), so it must be discovered at removal time. We query
# the Dataverse `bots` table with an az-issued token (works when az is logged into the target tenant).
function Get-McsDataverseToken {
    param([Parameter(Mandatory)][string]$OrgUrl)
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { return $null }
    $t = az account get-access-token --resource ($OrgUrl.TrimEnd('/')) --query accessToken -o tsv 2>$null
    if ([string]::IsNullOrWhiteSpace($t)) { return $null }
    return $t
}

# Resolve the bot GUID by agent display name (primary) or schema name (fallback). Returns $null when it
# cannot be resolved (e.g. az not logged into the target tenant) so the caller can fall back to a prompt.
function Get-McsBotId {
    param(
        [Parameter(Mandatory)][string]$OrgUrl,
        [string]$DisplayName,
        [string]$SchemaName
    )
    $tok = Get-McsDataverseToken -OrgUrl $OrgUrl
    if (-not $tok) { return $null }
    $base = $OrgUrl.TrimEnd('/')
    $clauses = @()
    if ($DisplayName) { $clauses += "name eq '$($DisplayName.Replace("'", "''"))'" }
    if ($SchemaName)  { $clauses += "schemaname eq '$($SchemaName.Replace("'", "''"))'" }
    if ($clauses.Count -eq 0) { return $null }
    $filter = [uri]::EscapeDataString(($clauses -join ' or '))
    try {
        $r = Invoke-RestMethod -Method Get -Uri "$base/api/data/v9.2/bots?`$select=botid,name,schemaname&`$filter=$filter" `
            -Headers @{ Authorization = "Bearer $tok"; Accept = 'application/json'; 'OData-MaxVersion' = '4.0'; 'OData-Version' = '4.0' }
        return ($r.value | Select-Object -First 1).botid
    }
    catch { return $null }
}

# ---------------------------------------------------------------- transform: base zip -> renamed zip
# Sanitize an arbitrary string into a valid Dataverse solution unique name (letters/digits/underscore,
# must start with a letter). Hyphens and other symbols are stripped.
function ConvertTo-SolutionUniqueName {
    param([Parameter(Mandatory)][string]$Name)
    $s = ($Name -replace '[^A-Za-z0-9]', '')
    if ($s -notmatch '^[A-Za-z]') { $s = 'a' + $s }
    if (-not $s) { $s = 'McsAgent' }
    return $s
}

# Produce a uniquely named, ready-to-import unmanaged solution zip from a base MCS solution.
#   -Harness         MCS-OH / MCS-NH (or OH / NH)
#   -DisplayName     the agent display name to show in Copilot Studio (e.g. contoso-MCS-OH)
#   -OutZip          destination path of the renamed solution zip
#   -SolutionUniqueName  optional; default derived from DisplayName. Rewrites the solution unique+friendly
#                    name so several MCS solutions coexist in one environment.
#   -IsolateSchemaName   optional; also rewrites the bot schema token so several agents of the SAME
#                    harness can coexist in ONE environment without colliding on the shared bot component.
#                    Default OFF (matches the validated cross-tenant path: display-name rename only).
#   -WorkDir         optional scratch dir; a temp dir is used and cleaned up when omitted.
# Returns a hashtable with the produced zip path and the effective names.
function New-RenamedMcsSolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Harness,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$OutZip,
        [string]$SolutionUniqueName,
        [switch]$IsolateSchemaName,
        [string]$WorkDir
    )
    $pac  = Assert-PacCli
    $base = Get-McsBase $Harness
    if (-not (Test-Path $base.zipPath)) { throw "Base solution zip not found: $($base.zipPath)" }

    if (-not $SolutionUniqueName) { $SolutionUniqueName = ConvertTo-SolutionUniqueName $DisplayName }
    $solFriendly = $DisplayName

    $cleanup = $false
    if (-not $WorkDir) { $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("mcs-" + [guid]::NewGuid().ToString('N').Substring(0,8)); $cleanup = $true }
    $src = Join-Path $WorkDir 'src'
    New-Item -ItemType Directory -Force -Path $src | Out-Null

    Write-Host "  Unpacking base ($($base.key)) ..." -ForegroundColor DarkGray
    & $pac solution unpack --zipfile $base.zipPath --folder $src --packagetype Unmanaged --allowWrite --allowDelete --clobber | Out-Null

    # 1) Rename the DISPLAY name everywhere it appears (bot.xml <name>, gpt botcomponent.xml <name>,
    #    gpt data 'displayName:'). Content-based so it is independent of the schema token.
    $oldDisp = $base.displayName
    Get-ChildItem -Recurse $src -File | ForEach-Object {
        $raw = Get-Content -LiteralPath $_.FullName -Raw
        $new = $raw.Replace("<name>$oldDisp</name>", "<name>$DisplayName</name>").Replace("displayName: $oldDisp", "displayName: $DisplayName")
        if ($new -ne $raw) { Set-Content -LiteralPath $_.FullName -Value $new -NoNewline -Encoding UTF8 }
    }

    # 2) Rewrite the SOLUTION unique + friendly name (Solution.xml) so multiple MCS solutions coexist.
    $solXml = Join-Path $src 'Other\Solution.xml'
    if (Test-Path $solXml) {
        $raw = Get-Content -LiteralPath $solXml -Raw
        $raw = $raw.Replace("<UniqueName>$($base.solutionUnique)</UniqueName>", "<UniqueName>$SolutionUniqueName</UniqueName>")
        $raw = $raw.Replace("description=`"$($base.solutionFriendly)`"", "description=`"$solFriendly`"")
        Set-Content -LiteralPath $solXml -Value $raw -NoNewline -Encoding UTF8
    }

    # 3) OPTIONAL: rewrite the bot schema token everywhere (file contents + folder names) for full
    #    per-environment isolation between same-harness agents.
    $effectiveSchema = $base.botSchemaToken
    if ($IsolateSchemaName) {
        $prefix = ($base.botSchemaToken -split '_', 2)[0]                      # 'new' (OH) / 'cr47b' (NH)
        $suffix = ($SolutionUniqueName -replace '[^A-Za-z0-9]', '')
        $effectiveSchema = "${prefix}_$suffix"
        Get-ChildItem -Recurse $src -File | ForEach-Object {
            $raw = Get-Content -LiteralPath $_.FullName -Raw
            if ($raw.Contains($base.botSchemaToken)) {
                Set-Content -LiteralPath $_.FullName -Value ($raw.Replace($base.botSchemaToken, $effectiveSchema)) -NoNewline -Encoding UTF8
            }
        }
        # Rename any folder whose name contains the token (deepest first so parents stay valid).
        Get-ChildItem -Recurse $src -Directory | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
            if ($_.Name.Contains($base.botSchemaToken)) {
                Rename-Item -LiteralPath $_.FullName -NewName ($_.Name.Replace($base.botSchemaToken, $effectiveSchema))
            }
        }
    }

    $outDir = Split-Path -Parent $OutZip
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    Write-Host "  Packing -> $OutZip" -ForegroundColor DarkGray
    & $pac solution pack --zipfile $OutZip --folder $src --packagetype Unmanaged | Out-Null

    if ($cleanup) { Remove-Item -Recurse -Force -LiteralPath $WorkDir -ErrorAction SilentlyContinue }

    return [ordered]@{
        harness            = $base.key
        displayName        = $DisplayName
        solutionUniqueName = $SolutionUniqueName
        solutionFriendly   = $solFriendly
        botSchemaName      = $effectiveSchema
        zip                = (Resolve-Path $OutZip).Path
    }
}
