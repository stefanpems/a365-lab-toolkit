# Optional sample custom MCP (custom-mcp/): copy the sample to a per-copy folder derived from the
# unique <Name>, rewrite the deploy-mcp.ps1 constants, fill the register-*.json from the templates,
# and emit deploy/register next-commands. Accumulates ext_ servers into $attachByAgent for the
# unified tool-attachment pass. Reads $plan / $repoRoot / $OutRoot / $nextCommands / $attachByAgent.

function Invoke-ScaffoldCustomMcp {
    $name      = $plan.customMcp.name
    # Every per-copy identifier derives from the (unique) <Name>, so N copies never collide.
    $mcpSlug   = ($name -replace '[^A-Za-z0-9]', '').ToLower()
    $mcpSrc = Join-Path $repoRoot 'custom-mcp'
    $mcpDst = Join-Path $OutRoot "custom-mcp-$mcpSlug"
    if (Test-Path -LiteralPath $mcpDst) { Remove-Item -LiteralPath $mcpDst -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $mcpDst | Out-Null
    $null = robocopy $mcpSrc $mcpDst /E /XD '.venv' '__pycache__' /XF '*.pyc' '.env' /NFL /NDL /NJH /NJS /NP /NC /NS

    $publisher = if ($plan.customMcp.publisher) { $plan.customMcp.publisher } else { 'Contoso' }
    $mcpRegion = if ($plan.customMcp.region) { $plan.customMcp.region } else { $plan.solution.region }
    $mcpRg     = if ($plan.customMcp.resourceGroup) { $plan.customMcp.resourceGroup } else { "$mcpSlug-mcp-rg" }
    $mcpApp    = "$mcpSlug-mcp-ca"
    $mcpEnv    = "$mcpSlug-mcp-cae"
    $servers   = @($plan.customMcp.servers); if (-not $servers) { $servers = @('anon', 'auth') }

    # Rewrite the hardcoded constants in deploy-mcp.ps1.
    $depPath = Join-Path $mcpDst 'deploy-mcp.ps1'
    if (Test-Path -LiteralPath $depPath) {
        $txt = Get-Content -LiteralPath $depPath -Raw
        $txt = [regex]::Replace($txt, '(\$RG\s*=\s*)"[^"]*"',      "`$1`"$mcpRg`"")
        $txt = [regex]::Replace($txt, '(\$APP\s*=\s*)"[^"]*"',     "`$1`"$mcpApp`"")
        $txt = [regex]::Replace($txt, '(\$ENVNAME\s*=\s*)"[^"]*"', "`$1`"$mcpEnv`"")
        $txt = [regex]::Replace($txt, '(\$LOC\s*=\s*)"[^"]*"',     "`$1`"$mcpRegion`"")
        $txt = [regex]::Replace($txt, '(\$IMAGE\s*=\s*)"[^"]*"',   "`$1`"$mcpSlug-mcp:1.0.0`"")
        Set-Content -LiteralPath $depPath -Value $txt
    }

    # Fill the registration JSON files from the templates (the FQDN is filled after the container deploys).
    foreach ($srv in $servers) {
        $tmpl = Join-Path $mcpDst "register-$srv.template.json"
        if (-not (Test-Path -LiteralPath $tmpl)) { continue }
        $j = (Get-Content -LiteralPath $tmpl -Raw).Replace('<NAME>', $name).Replace('<PUBLISHER>', $publisher)
        Set-Content -LiteralPath (Join-Path $mcpDst "register-$srv.json") -Value $j
    }
    Write-Host "  scaffolded custom MCP -> generated\custom-mcp (servers: $($servers -join ', '))" -ForegroundColor Cyan

    # Next-commands: deploy -> register (after admin approval) -> attach per agent.
    $graphArgs = if ($plan.customMcp.propagateToGraph) { " -AuthClientId <AUTH_APP_ID> -AuthTenantId $($plan.solution.tenantId)" } else { '' }
    $nextCommands.Add("cd `"$mcpDst`"; .\deploy-mcp.ps1 -Subscription $($plan.solution.subscriptionId)$graphArgs   # prints the /anon/mcp and /auth/mcp FQDNs")
    foreach ($srv in $servers) {
        $extName = if ($srv -eq 'anon') { "ext_${name}Anon" } else { "ext_${name}Auth" }
        $nextCommands.Add("cd `"$mcpDst`"; # edit register-$srv.json: replace <MCP_FQDN> with the deployed FQDN, then: a365 develop-mcp register-external-mcp-server -f .\register-$srv.json --dry-run; a365 develop-mcp register-external-mcp-server -f .\register-$srv.json   # a tenant admin then approves '$extName' in the M365 admin center (Agents > Requested)")
    }
    $extList = (@($servers | ForEach-Object { if ($_ -eq 'anon') { "ext_${name}Anon" } else { "ext_${name}Auth" } }))
    foreach ($t in @($plan.customMcp.attachTo)) {
        $ag = $plan.agents | Where-Object { $_.type -eq $t } | Select-Object -First 1
        if (-not $ag) { continue }
        # Accumulate the custom ext_ servers; the unified attach section emits one command per agent.
        if (-not $attachByAgent.ContainsKey($ag.name)) { $attachByAgent[$ag.name] = New-Object System.Collections.Generic.List[string] }
        $extList | ForEach-Object { if ($attachByAgent[$ag.name] -notcontains $_) { $attachByAgent[$ag.name].Add($_) } }
    }
    if ($plan.customMcp.propagateToGraph) {
        $nextCommands.Add("# propagate_to_graph: on the ext_${name}Auth app add Microsoft Graph delegated 'User.Read' + admin consent + a client secret, then redeploy deploy-mcp.ps1 with -AuthClientId/-AuthTenantId (secret entered in the terminal). See custom-mcp/README.md.")
    }
}
