  $ErrorActionPreference = "Stop"

  $AzureAIProjectEndpoint = $env:AZURE_AI_PROJECT_ENDPOINT
  $AgentName = $env:AGENT_NAME
  $AzureContainerRegistryEndpoint = $env:AZURE_CONTAINER_REGISTRY_ENDPOINT
  $MAIBName = $env:MAIB_NAME

  # Config-driven agent env vars. These are set on the agent VERSION (not baked into the image),
  # so toggling a feature = create a new version reusing the same image (no `az acr build`).
  # Only custom vars are allowed here — FOUNDRY_*/AGENT_*/APPLICATIONINSIGHTS_* are reserved by the
  # platform. Add a passthrough entry below to surface an azd env value to the container.
  $environmentVariables = @{}
  if ($env:DW_ENABLE_MAIL) { $environmentVariables["DW_ENABLE_MAIL"] = "$($env:DW_ENABLE_MAIL)" }


  $agentUrl = "$($AzureAIProjectEndpoint)/agents/$($AgentName)/versions?api-version=2025-11-15-preview"

  $agentCreationBody = @{
      definition = @{
          kind = "hosted"
          image = "$($AzureContainerRegistryEndpoint)/hello-world-a365-agent:latest"
          cpu = "2"
          memory = "4Gi"
          environment_variables = $environmentVariables
          container_protocol_versions = @(
              @{
                  protocol = "activity_protocol"
                  version  = "v1"
              }
          )
      }
      metadata = @{
        enableVnextExperience = "true"
      }
      description = "Foundry digital worker."
      agent_endpoint = @{
        protocols = @("activity")
      }
      blueprint_reference = @{
        type = "ManagedAgentIdentityBlueprint"
        blueprint_id = $MAIBName
      }
  }

  $jsonBody = $agentCreationBody | ConvertTo-Json -Depth 5

  Write-Host "Getting access token for https://ai.azure.com ..."

  $aiAzureToken = az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv


  Write-Host "Token length: $($aiAzureToken.Length)"

  $headers = @{
      "Content-Type"  = "application/json"
      "Accept"        = "application/json"
      "Authorization" = "Bearer $aiAzureToken"
      "Foundry-Features" = "HostedAgents=V1Preview,AgentEndpoints=V1Preview"
  }

  Write-Host "Creating agent version at: $agentUrl"
  Write-Host "JSON Body:"
  Write-Host $jsonBody

  $response = Invoke-RestMethod -Uri $agentUrl `
      -Method Post `
      -Headers $headers `
      -Body $jsonBody `
      -ErrorAction Stop

  Write-Host ""
  Write-Host "Response:"
  $response | ConvertTo-Json -Depth 100 | Write-Host

  # Output the agent version
  $agentVersion = $response.version
  $agentGuid = $response.agent_guid
  $agentDefaultInstanceClientId = $response.instance_identity.client_id
  Write-Host "Agent GUID: $agentGuid"
  Write-Host "Agent Version: $agentVersion"

  # Poll for agent version provisioning status
  $maxRetries = 30
  $delaySeconds = 10
  $provisioningStatus = $response.status
  if (-not $provisioningStatus) { $provisioningStatus = "Unknown" }

  Write-Host "Initial provisioning status: $provisioningStatus"

  $pollUrl = "$($AzureAIProjectEndpoint)/agents/$($AgentName)/versions/$($agentVersion)?api-version=2025-11-15-preview"

  if ($provisioningStatus -ne "active" -and $provisioningStatus -ne "failed") {
      for ($i = 1; $i -lt $maxRetries; $i++) {
          Write-Host "Waiting ${delaySeconds}s before poll $($i + 1)/${maxRetries}..."
          Start-Sleep -Seconds $delaySeconds

          try {
              $pollResponse = Invoke-RestMethod -Uri $pollUrl `
                  -Method Get `
                  -Headers $headers `
                  -ErrorAction Stop

              $provisioningStatus = $pollResponse.status
              if (-not $provisioningStatus) { $provisioningStatus = "Unknown" }
          } catch {
              Write-Host "Poll failed: $($_.Exception.Message)"
          }

          Write-Host "Provisioning status: $provisioningStatus"

          if ($provisioningStatus -eq "active" -or $provisioningStatus -eq "failed") {
              break
          }
      }
  }

  Write-Host "Agent version provisioned: $provisioningStatus"

  if ($provisioningStatus -ne "active") {
      throw "Agent version provisioning status is '$provisioningStatus', expected 'active'."
  }

  # Grant Cognitive Services User role on the foundry account to the agent's default instance identity.
  $accountScope = "/subscriptions/$($env:SUBSCRIPTION_ID)/resourceGroups/$($env:RESOURCE_GROUP)/providers/Microsoft.CognitiveServices/accounts/$($env:ACCOUNT_NAME)"
  $cognitiveServicesUserRoleId = "a97b65f3-24c7-4388-baec-2e87135dc908"

  Write-Host "Granting Cognitive Services User role to client id $agentDefaultInstanceClientId on scope $accountScope"

  $roleAssignmentOutput = az role assignment create `
      --assignee $agentDefaultInstanceClientId `
      --role $cognitiveServicesUserRoleId `
      --scope $accountScope 2>&1 | Out-String

  if ($LASTEXITCODE -eq 0) {
      Write-Host "Cognitive Services User role assignment created."
  } elseif ($roleAssignmentOutput -match "RoleAssignmentExists") {
      Write-Host "Cognitive Services User role assignment already exists, skipping."
  } else {
      throw "Failed to create Cognitive Services User role assignment: $roleAssignmentOutput"
  }

  # Patch agent endpoint with activity protocol.
  # IMPORTANT: the authorization scheme MUST match the publish scope used in
  # publish-digital-worker.ps1 (appPublishScope). Foundry pairs them as follows:
  #   publishScope = "Tenant"           -> "BotServiceTenant" (anyone in the tenant can invoke)
  #   publishScope = "Shared"/"Personal" -> "BotServiceRbac"   (only identities with the required
  #                                                            Foundry Azure RBAC can invoke)
  # A mismatch causes the Bot Service -> Foundry relay to be rejected with
  # 403 "no valid bot service token". Our publish uses "Tenant", so we set "BotServiceTenant".
  $patchUrl = "$($AzureAIProjectEndpoint)/agents/$($AgentName)?api-version=2025-11-15-preview"
  $patchBody = @{
      agent_endpoint = @{
          protocols = @("activity")
          authorization_schemes = @(
            @{ "type" = "BotServiceTenant" }
        )
      }
  } | ConvertTo-Json -Depth 5

  Write-Host "Patching agent endpoint at: $patchUrl"
  Write-Host "Patch Body:"
  Write-Host $patchBody

  $patchResponse = Invoke-RestMethod -Uri $patchUrl `
      -Method Patch `
      -Headers $headers `
      -Body $patchBody `
      -ErrorAction Stop
  
  Write-Host ""
  Write-Host "Patch Response:"
  $patchResponse | ConvertTo-Json -Depth 100 | Write-Host

  # Return agent GUID for downstream scripts
  return $agentGuid
