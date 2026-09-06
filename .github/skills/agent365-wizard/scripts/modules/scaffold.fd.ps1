# Foundry Declarative / prompt family (FD-OBO / FD-S2S): fill .env with the PROJECT endpoint
# (deriving it read-only when only the account endpoint is known), the model, and the agent name;
# emit the RBAC grant + python deploy next-command. Reads $plan / $nextCommands from the router scope.

function Invoke-ScaffoldFdAgent {
    param($a, $m, $dst)

    $envPath = Join-Path $dst '.env'
    $fp = $a.foundryProject
    if ($fp -and $fp -notmatch '/api/projects/') {
        # Prompt-agent SDK needs the PROJECT endpoint (…/api/projects/<project>), not the account endpoint. Derive it (read-only az).
        $acctName = ([uri]$fp).Host.Split('.')[0]
        $proj = az rest --method get --url "https://management.azure.com/subscriptions/$($plan.solution.subscriptionId)/resourceGroups/$($a.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$acctName/projects?api-version=2025-04-01-preview" --query "value[0].name" -o tsv 2>$null
        if ($proj) { if ($proj -like '*/*') { $proj = $proj.Split('/')[-1] }; $fp = "https://$acctName.services.ai.azure.com/api/projects/$proj"; Write-Host "    FD project endpoint derived: $fp" -ForegroundColor DarkGray }
        else { Write-Host "    WARN $($a.name): set FOUNDRY_PROJECT_ENDPOINT manually to https://<acct>.services.ai.azure.com/api/projects/<project>" -ForegroundColor Yellow }
    }
    if ($fp) { Set-EnvValue -Path $envPath -Key 'FOUNDRY_PROJECT_ENDPOINT' -Value $fp }
    Set-EnvValue -Path $envPath -Key 'FOUNDRY_MODEL_NAME' -Value $a.ai.deployment
    Set-EnvValue -Path $envPath -Key 'AGENT_NAME' -Value $a.name
    if ($a.type -eq 'FD-OBO') {
        Set-EnvValue -Path $envPath -Key 'AZURE_TENANT_ID' -Value $plan.solution.tenantId
        Set-EnvValue -Path $envPath -Key 'CLIENT_APP_ID' -Value '<YOUR_AGENT365_CLI_PUBLIC_CLIENT_APP_ID>'
    }
    # FD deploy authors an agent version -> needs Cognitive Services User on the reused Foundry account.
    $fdGrant = "az role assignment create --assignee-object-id (az ad signed-in-user show --query id -o tsv) --assignee-principal-type User --role `"Cognitive Services User`" --scope (az cognitiveservices account show -n $($a.ai.account) -g $($a.resourceGroup) --query id -o tsv)"
    $nextCommands.Add("cd `"$dst`"; $fdGrant; python -m venv .venv; .\.venv\Scripts\Activate.ps1; pip install -r requirements.txt; python deploy_agent.py   # RBAC propagates ~2-5min")
}
