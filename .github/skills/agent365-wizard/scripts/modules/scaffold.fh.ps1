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
    if ($a.type -ne 'FH-DW') {
        $envPath = Join-Path $dst '.env'
        if ($a.foundryProject) { Set-EnvValue -Path $envPath -Key 'FOUNDRY_PROJECT_ENDPOINT' -Value $a.foundryProject }
        Set-EnvValue -Path $envPath -Key 'AZURE_AI_MODEL_DEPLOYMENT_NAME' -Value $a.ai.deployment
        $proto = if ($a.type -eq 'FH-S2S') { 'responses' } else { 'invocations' }
        # azd provision (FH-OBO/S2S) does NOT create the model deployment nor grant data-plane RBAC:
        # after provision, create the model in the generated account + grant Cognitive Services User, then deploy.
        $fhDep = "cd `"$dst`"; azd env new $($a.name); azd env set AZURE_SUBSCRIPTION_ID $($plan.solution.subscriptionId); azd env set AZURE_TENANT_ID $($plan.solution.tenantId); azd env set AZURE_LOCATION $($plan.solution.region); azd env set AZURE_RESOURCE_GROUP $($a.resourceGroup); azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME $($a.ai.deployment); azd provision"
        $fhModel = "`$acct=(az cognitiveservices account list -g $($a.resourceGroup) --query `"[?kind=='AIServices'].name | [0]`" -o tsv); az cognitiveservices account deployment create -n `$acct -g $($a.resourceGroup) --deployment-name $($a.ai.deployment) --model-name $($a.ai.deployment) --model-version 2025-04-14 --model-format OpenAI --sku-name GlobalStandard --sku-capacity 20"
        $fhRole = "az role assignment create --assignee-object-id (az ad signed-in-user show --query id -o tsv) --assignee-principal-type User --role `"Cognitive Services User`" --scope (az cognitiveservices account show -n `$acct -g $($a.resourceGroup) --query id -o tsv)"
        $nextCommands.Add("$fhDep; $fhModel; $fhRole; azd deploy   # protocol: $proto  (adjust --model-version if not gpt-4.1; RBAC propagates ~2-5min)")
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
