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
    # Resolve the effective Azure OpenAI target from solution.azureOpenAI (shared by all ACA agents):
    # create-shared = a lab-owned account <prefix>aoai in <prefix>-aoai-rg (created before the deploys,
    # deleted by the Lab Cleaner via the prefix); reuse-existing = the account the user picked; absent =
    # legacy per-agent a.ai. Used for both env/.env.playground.user and the deploy -AoaiRg/-AoaiAcc.
    $aoai = Resolve-AoaiTarget $plan $a
    # env/.env.playground.user is copied from the sample and ships a PRIOR lab's Azure OpenAI values
    # (tenant-specific, gitignored). deploy-aca*.ps1 reads AZURE_OPENAI_ENDPOINT/DEPLOYMENT from it, so a
    # stale endpoint sends the container to the wrong account where its managed identity has no role ->
    # a 401 on the model call. Overwrite it from the plan so the deploy targets the right account+model.
    if ($aoai.account) {
        $pgPath = Join-Path $dst 'env/.env.playground.user'
        $apiVer = '2024-12-01-preview'
        if (Test-Path -LiteralPath $pgPath) {
            $cur = @{}
            Get-Content -LiteralPath $pgPath | Where-Object { $_ -match '=' -and $_ -notmatch '^\s*#' } | ForEach-Object { $kk, $vv = $_ -split '=', 2; $cur[$kk.Trim()] = $vv.Trim() }
            if ($cur['AZURE_OPENAI_API_VERSION']) { $apiVer = $cur['AZURE_OPENAI_API_VERSION'] }
        }
        else {
            New-Item -ItemType Directory -Force -Path (Split-Path $pgPath) | Out-Null
        }
        @(
            "AZURE_OPENAI_ENDPOINT=https://$($aoai.account).openai.azure.com/"
            "AZURE_OPENAI_DEPLOYMENT_NAME=$($aoai.deployment)"
            "AZURE_OPENAI_API_VERSION=$apiVer"
            "SECRET_AZURE_OPENAI_API_KEY="
        ) | Set-Content -LiteralPath $pgPath -Encoding utf8
    }
    # Make ToolingManifest.json AUTHORITATIVE = exactly the plan's Work IQ (mcp_*) tools, BEFORE any
    # `a365 setup all` (which grants MCP permissions from this manifest). The sample ships mcp_MailTools;
    # this keeps it only when selected, so an agent with tools:[] (e.g. S2S) gets NO Mail permission.
    # Custom ext_ servers are appended later by `a365 develop add-mcp-servers` (see scaffold.tools.ps1).
    Set-ToolingManifest -Path (Join-Path $dst 'ToolingManifest.json') -Tools @($a.tools)
    $reuse = if ($plan.solution.resourceGroupStrategy -eq 'shared') { ' -ReuseEnv' } else { '' }
    # DW defers the messaging endpoint until the container is deployed (the FQDN is a post-deploy artifact).
    $dwNote = if ($a.type -eq 'ACA-DW') { "   # DW: after the container deploys, register the endpoint: a365 setup blueprint --endpoint-only --messaging-endpoint https://<fqdn>/api/messages" } else { '' }
    # IMPORTANT: 'a365 setup all' and the deploy script are WORKING-DIRECTORY-SENSITIVE and must run
    # FROM this agent folder. 'a365 setup all' writes a365.generated.config.json + stamps .env only
    # when it detects the project here; run from elsewhere it prints "No project detected ... skipping
    # project settings" and the deploy loses the blueprint id. The 'cd' prefix below guarantees this
    # for a human; an automation runner MUST set the cwd first (a leading 'cd' in an async shell can be
    # dropped). The deploy scripts also self-heal (resolve the blueprint by display name) as a backstop.
    # create-shared: the FIRST ACA agent creates the lab's ONE shared Azure OpenAI account + deployment
    # before any deploy (emitted once, ahead of this agent's setup/deploy line). The rest reuse it.
    if ($aoai.mode -eq 'create-shared' -and $a.name -eq (Get-SharedAoaiProvisioner $plan)) {
        $modelVer = if ($plan.solution.azureOpenAI.modelVersion) { $plan.solution.azureOpenAI.modelVersion } else { '2025-04-14' }
        $mkAoai = "az group create -n $($aoai.resourceGroup) -l $($plan.solution.region) -o none; az cognitiveservices account create -n $($aoai.account) -g $($aoai.resourceGroup) -l $($plan.solution.region) --kind OpenAI --sku S0 --custom-domain $($aoai.account) --yes -o none; az cognitiveservices account deployment create -n $($aoai.account) -g $($aoai.resourceGroup) --deployment-name $($aoai.deployment) --model-name $($aoai.deployment) --model-version $modelVer --model-format OpenAI --sku-name GlobalStandard --sku-capacity 20 -o none"
        $nextCommands.Add("$mkAoai   # SHARED Azure OpenAI (create-shared): create the lab's ONE account '$($aoai.account)' + deployment '$($aoai.deployment)' in '$($aoai.resourceGroup)' (lab-owned; deleted by the Lab Cleaner via the '$($plan.solution.prefix)' prefix). Run ONCE before the ACA deploys; each deploy grants the app's managed identity Cognitive Services OpenAI User on it.")
    }
    # -AoaiRg is the resolved account RG (create-shared: <prefix>-aoai-rg; reuse-existing: existingResourceGroup);
    # falls back to the <AOAI_RG> placeholder only in legacy per-agent mode where no shared RG is known.
    $aoaiRgArg = if ($aoai.resourceGroup) { $aoai.resourceGroup } else { '<AOAI_RG>' }
    $nextCommands.Add("cd `"$dst`"; a365 setup all --agent-name `"$($a.name)`"$(if($a.type -eq 'ACA-DW'){' --aiteammate'}); .\$($m.deploy) -Subscription $($plan.solution.subscriptionId) -AoaiRg $aoaiRgArg -AoaiAcc $($aoai.account)$reuse$dwNote")
    if ($a.type -eq 'ACA-DW') {
        # DW publish: register the real endpoint, regenerate the package for THIS blueprint, then upload it in the admin center.
        # a365 publish is CWD-SENSITIVE: it reads THIS folder's config and drops manifest/ in the CURRENT dir -> the leading cd is mandatory.
        $nextCommands.Add("cd `"$dst`"; a365 setup blueprint --endpoint-only --messaging-endpoint https://<ACA_DW_FQDN>/api/messages; a365 publish --aiteammate --agent-name `"$($a.name)`"   # RUN FROM THIS AGENT FOLDER (a365 publish is cwd-sensitive: it reads this folder's a365.config.json and writes manifest\ here; from the wrong cwd it reads a stale config + drops a stray manifest\ at the repo root). answer n + Enter at the manifest prompts; then upload manifest\manifest.zip at admin.microsoft.com > Agents > All agents > Upload custom agent (Publish/Activate), then users hire in Teams")
    }
}
