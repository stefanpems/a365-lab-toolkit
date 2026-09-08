# Azure Container Apps family (ACA-OBO / ACA-S2S / ACA-DW): fill a365.config.json, rewrite the
# hardcoded deploy-script constants, and emit the setup/deploy (+ DW publish) next-commands.
# Reads $plan / $nextCommands from the router scope; mutates the shared $nextCommands list.

function Invoke-ScaffoldAcaAgent {
    param($a, $m, $dst)

    # a365.config.json from the .example, filled from the plan. Ordered for reproducible output.
    $cfg = [ordered]@{
        tenantId                  = $plan.solution.tenantId
        clientAppId               = '<YOUR_AGENT365_CLI_PUBLIC_CLIENT_APP_ID>'
        agentIdentityDisplayName  = $a.displayNames.identity
        agentBlueprintDisplayName = $a.displayNames.blueprint
        agentDescription          = $a.name
        aiTeammate                = ($a.type -eq 'ACA-DW')
        useBlueprint              = $true
    }
    $cfg | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dst 'a365.config.json')
    # Parameterize the hardcoded constants in the deploy script.
    $app = ($a.name -replace '[^A-Za-z0-9-]', '-').ToLower()
    $rg  = $a.resourceGroup
    $env = "$app-env"
    $deployPath = Join-Path $dst $m.deploy
    if (Test-Path -LiteralPath $deployPath) {
        $txt = Get-Content -LiteralPath $deployPath -Raw
        $txt = [regex]::Replace($txt, '(\$RG\s*=\s*)"[^"]*"',      "`$1`"$rg`"")
        $txt = [regex]::Replace($txt, '(\$APP\s*=\s*)"[^"]*"',     "`$1`"$app`"")
        $txt = [regex]::Replace($txt, '(\$ENVNAME\s*=\s*)"[^"]*"', "`$1`"$env`"")
        # Pin region: single-entry probe list (obo) or $LOC constant (s2s/dw).
        $txt = [regex]::Replace($txt, '(?s)\$REGIONS\s*=\s*@\([^)]*\)', "`$REGIONS = @(`"$($plan.solution.region)`")")
        $txt = [regex]::Replace($txt, '(\$LOC\s*=\s*)"[^"]*"',     "`$1`"$($plan.solution.region)`"")
        Set-Content -LiteralPath $deployPath -Value $txt
    }
    # Make ToolingManifest.json AUTHORITATIVE = exactly the plan's Work IQ (mcp_*) tools, BEFORE any
    # `a365 setup all` (which grants MCP permissions from this manifest). The sample ships mcp_MailTools;
    # this keeps it only when selected, so an agent with tools:[] (e.g. S2S) gets NO Mail permission.
    # Custom ext_ servers are appended later by `a365 develop add-mcp-servers` (see scaffold.tools.ps1).
    Set-ToolingManifest -Path (Join-Path $dst 'ToolingManifest.json') -Tools @($a.tools)
    $reuse = if ($plan.solution.resourceGroupStrategy -eq 'shared') { ' -ReuseEnv' } else { '' }
    # DW agents prompt for the optional 'ext_UtilityInsights' custom MCP (may be absent in the tenant) and defer the messaging endpoint until the container is deployed.
    $dwNote = if ($a.type -eq 'ACA-DW') { "   # DW: answer N at the 'ext_UtilityInsights' prompt (optional custom MCP — add only when wiring it); after the container deploys, register the endpoint: a365 setup blueprint --endpoint-only --messaging-endpoint https://<fqdn>/api/messages" } else { '' }
    $nextCommands.Add("cd `"$dst`"; a365 setup all --agent-name `"$($a.name)`"$(if($a.type -eq 'ACA-DW'){' --aiteammate'}); .\$($m.deploy) -Subscription $($plan.solution.subscriptionId) -AoaiRg <AOAI_RG> -AoaiAcc $($a.ai.account)$reuse$dwNote")
    if ($a.type -eq 'ACA-DW') {
        # DW publish: register the real endpoint, regenerate the package for THIS blueprint, then upload it in the admin center.
        $nextCommands.Add("cd `"$dst`"; a365 setup blueprint --endpoint-only --messaging-endpoint https://<ACA_DW_FQDN>/api/messages; a365 publish --aiteammate --agent-name `"$($a.name)`"   # answer n + Enter at the manifest prompts; then upload manifest\manifest.zip at admin.microsoft.com > Agents > All agents > Upload custom agent (Publish/Activate), then users hire in Teams")
    }
}
