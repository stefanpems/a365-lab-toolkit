# Foundry Hosted family (FH-OBO / FH-S2S / FH-DW): rename azure.yaml, fill .env (OBO/S2S), and emit
# the azd provision/deploy next-commands. FH-DW rewrites the Bicep/scripts agent name and uses the
# governed-subscription blueprint path (Solution A). Reads $plan / $nextCommands from the router scope.

function Invoke-ScaffoldFhAgent {
    param($a, $m, $dst)

    # azure.yaml: rename the service + kind name to the planned agent name.
    $ay = Join-Path $dst 'azure.yaml'
    if (Test-Path -LiteralPath $ay) {
        $txt = Get-Content -LiteralPath $ay -Raw
        $txt = [regex]::Replace($txt, 'agentframeworkFH-(OBO|S2S|DW)\d*-agent', $a.name)
        Set-Content -LiteralPath $ay -Value $txt
    }
    # Make ToolingManifest.json AUTHORITATIVE = exactly the plan's Work IQ (mcp_*) tools. The FH sample
    # runtime is manifest-driven (wires every server in the manifest), so an agent with tools:[] (e.g.
    # FH-S2S) ships an empty manifest and gets no Mail wiring/permission. FH-DW keeps its manifest under
    # src/. Custom ext_ are appended later by `a365 develop add-mcp-servers` (see scaffold.tools.ps1).
    $fhManifest = if ($a.type -eq 'FH-DW') { Join-Path $dst 'src\hello_world_a365_agent\ToolingManifest.json' } else { Join-Path $dst 'ToolingManifest.json' }
    Set-ToolingManifest -Path $fhManifest -Tools @($a.tools)
    if ($a.type -ne 'FH-DW') {
        $envPath = Join-Path $dst '.env'
        $proto = if ($a.type -eq 'FH-S2S') { 'responses' } else { 'invocations' }
        $ft = Resolve-FoundryTarget $plan $a
        $modelVer = if ($plan.solution.foundry -and $plan.solution.foundry.modelVersion) { $plan.solution.foundry.modelVersion } else { '2025-04-14' }
        Set-EnvValue -Path $envPath -Key 'AZURE_AI_MODEL_DEPLOYMENT_NAME' -Value $ft.deployment
        if ($ft.endpoint) { Set-EnvValue -Path $envPath -Key 'FOUNDRY_PROJECT_ENDPOINT' -Value $ft.endpoint }
        $envBase = "cd `"$dst`"; azd env new $($a.name); azd env set AZURE_SUBSCRIPTION_ID $($plan.solution.subscriptionId); azd env set AZURE_TENANT_ID $($plan.solution.tenantId); azd env set AZURE_LOCATION $($plan.solution.region)"

        if ($ft.mode -eq 'reuse-existing') {
            # Deploy-only into an EXISTING account+project (no azd provision). Deterministic endpoint from the
            # plan; the existing project is assumed already set up (model + Cognitive Services User) — if not,
            # run the ensure/grant one-liner in the trailing comment. Resilient path when new-account
            # hosted-agent provisioning is failing service-side.
            $projId = ''
            if ($ft.account -and $ft.resourceGroup -and $ft.project) {
                $projId = "/subscriptions/$($plan.solution.subscriptionId)/resourceGroups/$($ft.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($ft.account)/projects/$($ft.project)"
            }
            $set = "$envBase; azd env set FOUNDRY_PROJECT_ENDPOINT $($ft.endpoint); azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME $($ft.deployment)"
            if ($projId) { $set += "; azd env set AZURE_AI_PROJECT_ID `"$projId`"" }
            $nextCommands.Add("$set; azd deploy   # protocol: $proto  (reuse-existing: deploy into $($ft.endpoint); if it 404s on the model, ensure $($ft.deployment) exists on account $($ft.account) and you have Cognitive Services User)")
        }
        elseif ($ft.mode -eq 'create-shared') {
            $provisioner = Get-SharedFoundryProvisioner $plan
            if ($a.name -eq $provisioner) {
                # This FH agent PROVISIONS the single shared account + project <prefix> for the whole lab.
                $prov = "$envBase; azd env set AZURE_RESOURCE_GROUP $($ft.resourceGroup); azd env set AZURE_AI_PROJECT_NAME $($ft.project); azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME $($ft.deployment); azd provision"
                $model = "`$acct=(az cognitiveservices account list -g $($ft.resourceGroup) --query `"[?kind=='AIServices'].name | [0]`" -o tsv); az cognitiveservices account deployment create -n `$acct -g $($ft.resourceGroup) --deployment-name $($ft.deployment) --model-name $($ft.deployment) --model-version $modelVer --model-format OpenAI --sku-name GlobalStandard --sku-capacity 20"
                $role = "az role assignment create --assignee-object-id (az ad signed-in-user show --query id -o tsv) --assignee-principal-type User --role `"Cognitive Services User`" --scope (az cognitiveservices account show -n `$acct -g $($ft.resourceGroup) --query id -o tsv)"
                $nextCommands.Add("$prov; $model; $role; azd deploy   # SHARED Foundry: provisions the lab's ONE account + project '$($ft.project)' + model, then deploys THIS agent. Capture the shared endpoint for the other FH/FD agents: azd env get-values | Select-String 'FOUNDRY_PROJECT_ENDPOINT|AZURE_AI_PROJECT_ID'")
            }
            else {
                # Deploy into the shared project the provisioner created. The agent substitutes the two
                # $SHARED_FOUNDRY_* tokens with the values captured from the provisioning step above.
                $set = "$envBase; azd env set FOUNDRY_PROJECT_ENDPOINT $SHARED_FOUNDRY_ENDPOINT_TOKEN; azd env set AZURE_AI_PROJECT_ID $SHARED_FOUNDRY_PROJECTID_TOKEN; azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME $($ft.deployment)"
                $nextCommands.Add("$set; azd deploy   # protocol: $proto  (create-shared: deploy into the shared project from '$provisioner'; replace $SHARED_FOUNDRY_ENDPOINT_TOKEN / $SHARED_FOUNDRY_PROJECTID_TOKEN with the captured values)")
            }
        }
        else {
            # Legacy per-agent: azd provision creates this agent's OWN account in its OWN RG; it does NOT
            # create the model deployment nor grant data-plane RBAC, so do both before azd deploy.
            $fhDep = "$envBase; azd env set AZURE_RESOURCE_GROUP $($a.resourceGroup); azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME $($ft.deployment); azd provision"
            $fhModel = "`$acct=(az cognitiveservices account list -g $($a.resourceGroup) --query `"[?kind=='AIServices'].name | [0]`" -o tsv); az cognitiveservices account deployment create -n `$acct -g $($a.resourceGroup) --deployment-name $($ft.deployment) --model-name $($ft.deployment) --model-version $modelVer --model-format OpenAI --sku-name GlobalStandard --sku-capacity 20"
            $fhRole = "az role assignment create --assignee-object-id (az ad signed-in-user show --query id -o tsv) --assignee-principal-type User --role `"Cognitive Services User`" --scope (az cognitiveservices account show -n `$acct -g $($a.resourceGroup) --query id -o tsv)"
            $nextCommands.Add("$fhDep; $fhModel; $fhRole; azd deploy   # protocol: $proto  (adjust --model-version if not gpt-4.1; RBAC propagates ~2-5min)")
        }
    }
    else {
        # FH-DW hardcodes the agent name in Bicep + scripts (NOT azure.yaml). Rewrite every
        # occurrence to the planned name so DW matches the <prefix>-FH-DW scheme like the others.
        $dwFiles = @(
            'infra\main.bicep', 'infra\main.json', 'infra\main.parameters.json',
            'scripts\create-agent-blueprint.ps1', 'scripts\read-logs.ps1', 'scripts\roll-instrumented-version.ps1'
        )
        foreach ($rel in $dwFiles) {
            $fp = Join-Path $dst $rel
            if (Test-Path -LiteralPath $fp) {
                (Get-Content -LiteralPath $fp -Raw).Replace('agentframeworkFH-DW2-agent', $a.name) | Set-Content -LiteralPath $fp
            }
        }
        # Solution A (governed subscription): the ARM deploymentScript that creates the managed
        # agent identity blueprint needs shared-key storage, which tenant policy may block
        # (KeyBasedAuthenticationNotPermitted). Instead of a policy waiver, create the blueprint
        # OUT-OF-BAND via an Entra ID call between two provisions (see scripts/create-agent-blueprint.ps1).
        $envSet = "azd env new $($a.name); azd env set AZURE_SUBSCRIPTION_ID $($plan.solution.subscriptionId); azd env set AZURE_TENANT_ID $($plan.solution.tenantId); azd env set AZURE_LOCATION $($plan.solution.region); azd env set AZURE_RESOURCE_GROUP $($a.resourceGroup); azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME $($a.ai.deployment)"
        $nextCommands.Add("cd `"$dst`"; $envSet; azd provision   # 1st provision: creates account/project/ACR/model (the blueprint deploymentScript step FAILS under a shared-key storage policy — expected)")
        $nextCommands.Add("cd `"$dst`"; pwsh -File .\scripts\create-agent-blueprint.ps1 -Subscription $($plan.solution.subscriptionId) -ResourceGroup $($a.resourceGroup) -AgentName $($a.name)   # Solution A: MAIB via Entra ID (no storage/shared-key), grants Cognitive Services User, sets AGENT_IDENTITY_BLUEPRINT_CLIENT_ID")
        $nextCommands.Add("cd `"$dst`"; azd provision   # 2nd provision: deploymentScript SKIPPED; finishes Bot + post-provision (agent version, grants, publish)")
    }
}
