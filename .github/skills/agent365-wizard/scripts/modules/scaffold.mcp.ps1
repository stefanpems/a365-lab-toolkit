# Optional sample custom MCP (custom-mcp/): copy the sample to the per-run folder <prefix>-mcp,
# rewrite the deploy-mcp.ps1 constants, fill the register-*.json from the templates,
# and emit deploy/register next-commands. Accumulates ext_ servers into $attachByAgent for the
# unified tool-attachment pass. Reads $plan / $repoRoot / $OutRoot / $nextCommands / $attachByAgent.

function Invoke-ScaffoldCustomMcp {
    $name      = $plan.customMcp.name
    # Azure resources and ext_ registrations derive from the (unique) <Name>, so N copies never collide.
    $mcpSlug   = ($name -replace '[^A-Za-z0-9]', '').ToLower()
    $mcpFolderName = "$($plan.solution.prefix)-mcp"
    $mcpSrc = Join-Path $repoRoot 'custom-mcp'
    $mcpDst = Join-Path $OutRoot $mcpFolderName
    if (Test-Path -LiteralPath $mcpDst) { Remove-Item -LiteralPath $mcpDst -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $mcpDst | Out-Null
    $null = robocopy $mcpSrc $mcpDst /E /XD '.venv' '__pycache__' /XF '*.pyc' '.env' /NFL /NDL /NJH /NJS /NP /NC /NS

    $publisher = if ($plan.customMcp.publisher) { $plan.customMcp.publisher } else { 'Contoso' }
    $mcpRegion = if ($plan.customMcp.region) { $plan.customMcp.region } else { $plan.solution.region }
    $mcpRg     = if ($plan.customMcp.resourceGroup) { $plan.customMcp.resourceGroup } else { "$mcpSlug-mcp-rg" }
    $mcpAppAnon = "$mcpSlug-mcp-anon-ca"
    $mcpAppAuth = "$mcpSlug-mcp-auth-ca"
    $mcpEnv     = "$mcpSlug-mcp-cae"
    $servers    = @($plan.customMcp.servers); if (-not $servers) { $servers = @('anon', 'auth') }
    $serversLit = '@(' + (($servers | ForEach-Object { "'$_'" }) -join ', ') + ')'

    # Rewrite the hardcoded constants in deploy-mcp.ps1.
    $depPath = Join-Path $mcpDst 'deploy-mcp.ps1'
    if (Test-Path -LiteralPath $depPath) {
        $txt = Get-Content -LiteralPath $depPath -Raw
        $txt = [regex]::Replace($txt, '(\$RG\s*=\s*)"[^"]*"',        "`$1`"$mcpRg`"")
        $txt = [regex]::Replace($txt, '(\$APP_ANON\s*=\s*)"[^"]*"',  "`$1`"$mcpAppAnon`"")
        $txt = [regex]::Replace($txt, '(\$APP_AUTH\s*=\s*)"[^"]*"',  "`$1`"$mcpAppAuth`"")
        $txt = [regex]::Replace($txt, '(\$ENVNAME\s*=\s*)"[^"]*"', "`$1`"$mcpEnv`"")
        $txt = [regex]::Replace($txt, '(\$LOC\s*=\s*)"[^"]*"',     "`$1`"$mcpRegion`"")
        $txt = [regex]::Replace($txt, '(\$IMAGE\s*=\s*)"[^"]*"',   "`$1`"$mcpSlug-mcp:1.0.0`"")
        $txt = [regex]::Replace($txt, '(\$SERVERS\s*=\s*)@\([^)]*\)', "`$1$serversLit")
        Set-Content -LiteralPath $depPath -Value $txt
    }

    # Fill the registration JSON files from the templates (the FQDN is filled after the container deploys).
    foreach ($srv in $servers) {
        $tmpl = Join-Path $mcpDst "register-$srv.template.json"
        if (-not (Test-Path -LiteralPath $tmpl)) { continue }
        $j = (Get-Content -LiteralPath $tmpl -Raw).Replace('<NAME>', $name).Replace('<PUBLISHER>', $publisher)
        Set-Content -LiteralPath (Join-Path $mcpDst "register-$srv.json") -Value $j
    }
    Write-Host "  scaffolded custom MCP -> generated\$mcpFolderName (servers: $($servers -join ', '))" -ForegroundColor Cyan

    # Next-commands: deploy -> register (after admin approval) -> attach per agent.
    $graphArgs = if ($plan.customMcp.propagateToGraph) { " -AuthClientId <AUTH_APP_ID> -AuthTenantId $($plan.solution.tenantId)" } else { '' }
    $nextCommands.Add("cd `"$mcpDst`"; .\deploy-mcp.ps1 -Subscription $($plan.solution.subscriptionId)$graphArgs   # deploys one container per server (single replica) and prints each server's /mcp FQDN")
    $nextCommands.Add("# If a registration fails partway (HTTP 400 on the proxy connector, or leftover proxy apps/connectors), run before retrying: cd `"$mcpDst`"; .\cleanup-registration.ps1 -Name $name -Subscription $($plan.solution.subscriptionId) -TenantId $($plan.solution.tenantId)")
    foreach ($srv in $servers) {
        if ($srv -eq 'anon') {
            $nextCommands.Add("cd `"$mcpDst`"; # edit register-anon.json: replace <MCP_ANON_FQDN> with the deployed anon FQDN, then: a365 develop-mcp register-external-mcp-server -f .\register-anon.json --dry-run; a365 develop-mcp register-external-mcp-server -f .\register-anon.json   # tenant admin approves 'ext_${name}Anon' (Agents > Requested). If Approve errors on consent, the ext_${name}Anon-PublicClients app may lack a service principal - see custom-mcp/README.md.")
        } else {
            $nextCommands.Add("cd `"$mcpDst`"; # AUTH: first create the resource app exposing api://<appId>/access_as_agent (see custom-mcp/README.md), put it in register-auth.json remoteScopes, replace <MCP_AUTH_FQDN> with the deployed auth FQDN, then: a365 develop-mcp register-external-mcp-server -f .\register-auth.json --dry-run; a365 develop-mcp register-external-mcp-server -f .\register-auth.json   # tenant admin approves 'ext_${name}Auth'")
        }
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
