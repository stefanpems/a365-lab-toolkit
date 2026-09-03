# Setup — MAF-FH-DW (Agent Framework, Foundry Hosted, Digital Worker / AI teammate)

> Deploy an **AI teammate** ("Digital Worker") as a **Foundry hosted container agent**,
> relayed to **Teams / Outlook / Office** through an **Azure Bot Service**, and published to
> Microsoft 365 as a **hireable digital worker**. Reference implementation:
> **`agentframeworkFH-DW*-agent`** (lab env `dwfh2`).

See [00-introduction.md](00-introduction.md) for concepts. Unlike MAF-FH-OBO/S2S, this model
does **not** use the Responses/Invocations protocols — it runs the **same Bot Framework
`/api/messages` code** as the ACA agents, inside a Foundry-hosted container.

---

## 0. Prerequisites

- Enrollment in the **[Frontier preview program](https://adoption.microsoft.com/copilot/frontier-program/)**
  and the AI-teammate **licensing** described in [setup-MAF-ACA-DW.md](setup-MAF-ACA-DW.md) §0.
- **azd** (`winget install Microsoft.Azd`) + `az login` + `azd auth login`.
- **Docker** (only for the optional local `azd` agent commands; the image itself is built in
  ACR by the scripts).
- Roles: **Owner** on the subscription, **Azure AI User / Cognitive Services User**, and a
  **Tenant Admin** for org-wide configuration/consent.
- Region must support **Foundry hosted agents** (e.g. eastus2, polandcentral — see the
  [region list](https://learn.microsoft.com/azure/foundry/agents/quickstarts/quickstart-hosted-agent?pivots=azd)).

## 1. Get the sources

```powershell
git clone https://github.com/<your-org>/agent365-agentframework-samples.git
cd agent365-agentframework-samples/foundry-hosted/dw
```

Layout (azd project):

```
azure.yaml            # azd manifest + postprovision hook
infra/                # Bicep: Foundry project, ACR, Azure Bot Service, roles
scripts/              # postprovision orchestration (build, publish, grants)
src/hello_world_a365_agent/
  main.py             # create_and_run_host(FoundryDigitalWorkerAgent)
  agent.py            # FoundryDigitalWorkerAgent (AGENT_PROMPT), same GenericAgentHost pattern
  host_agent_server.py, agent_interface.py, ToolingManifest.json, requirements.txt
```

## 2. Customize the agent (optional)

- Instructions: `src/hello_world_a365_agent/agent.py` (`AGENT_PROMPT` on
  `FoundryDigitalWorkerAgent`).
- MCP tools: `src/hello_world_a365_agent/ToolingManifest.json`.

## 3. Provision everything

```powershell
azd provision
```

The **postprovision** hook (`scripts/post-provision.ps1`) orchestrates the five pieces:

1. **Build & push** the Docker image with `az acr build` (`build-docker-image-acr.ps1`).
2. **Create an agent version** as a Foundry **hosted container** agent
   (`agent-creation-script.ps1`).
3. **Publish the digital worker** to Microsoft 365 via the Foundry API
   (`publish-digital-worker.ps1`) — creates the hireable DW with the blueprint id + DW
   metadata.
4. **OAuth2 grants** for the blueprint SP so inheritable scopes work
   (`create-blueprintsp-oauth2-grants.ps1`).
5. **Add the current user as blueprint owner** (`add-current-user-as-blueprint-owner.ps1`).

Infra also provisions an **Azure Bot Service** that relays M365 activity to the Foundry
agent endpoint, configured with the **blueprint identity as its appId**.

Retrieve values afterward: `azd env get-values` (blueprint id, agent name, account, project).

> The `azure.ai.agent` service block in `azure.yaml` is **commented out** during provisioning
> (its `language: docker` would force a local Docker runtime). Re-enable it (with Docker
> running) only to use `azd ai agent monitor` on the deployed agent.

### 3.1 Governed subscriptions (storage **shared-key disabled**) — create the blueprint out-of-band

On a subscription whose policy **forbids shared-key access on storage accounts**, `azd provision`
fails at the **managed agent identity blueprint** step with:

```
DeploymentScriptOperationFailed / 403 KeyBasedAuthenticationNotPermitted
```

Cause: the blueprint is created by an ARM **deployment script**
(`infra/modules/maib-creation-script.bicep`), whose container mounts an Azure File share using the
storage **shared key** — which the policy blocks. The account, project, model and ACR are created
first, so only the blueprint (and the Bot Service / monitoring that depend on it) are missing.

`main.bicep` supports skipping the script: pass the **pre-created** blueprint client id via
`agentIdentityBlueprintClientId` (azd var `AGENT_IDENTITY_BLUEPRINT_CLIENT_ID`). Create the
blueprint yourself with the same data-plane call the script makes, then re-provision:

```powershell
# 1. Project endpoint + MAIB name (agentName + '-maib'):
$acc='<account>'; $proj='<project>'; $maib='<agentName>-maib'
$ep="https://$acc.services.ai.azure.com/api/projects/$proj"
# 2. Data-plane role to call the project, then PUT the blueprint:
az role assignment create --assignee-object-id (az ad signed-in-user show --query id -o tsv) `
  --assignee-principal-type User --role 'a97b65f3-24c7-4388-baec-2e87135dc908' `
  --scope (az cognitiveservices account show -n $acc -g <rg> --query id -o tsv)   # Cognitive Services User
$tok = az account get-access-token --resource 'https://ai.azure.com' --query accessToken -o tsv
$r = Invoke-RestMethod -Method Put -Uri "$ep/managedagentidentityblueprints/$maib`?api-version=2025-11-15-preview" `
  -Headers @{ Authorization = "Bearer $tok"; 'Content-Type'='application/json' }
$r.agentIdentityBlueprint.clientId   # <-- the blueprint client id (Bot Service msaAppId)
# 3. If a failed 'create-agent-script' deploymentScript remains, delete it:
az resource delete -g <rg> -n create-agent-script --resource-type Microsoft.Resources/deploymentScripts
# 4. Feed it back and re-provision (bicep now SKIPS the deployment script):
azd env set AGENT_IDENTITY_BLUEPRINT_CLIENT_ID <clientId>
azd provision
```

## 4. Approve the blueprint

1. [M365 admin center → Agents → Requests](https://admin.cloud.microsoft/#/agents/all/requested).
2. Locate your **agent blueprint** and click **Approve request and activate**.

## 5. Configure Teams integration

1. Open the [Teams Developer Portal → agent-blueprint](https://dev.teams.microsoft.com/tools/agent-blueprint)
   (if your blueprint isn't listed, open any blueprint and replace the id in the URL with your
   Blueprint ID from `azd env get-values`).
2. Under **Configuration**, set the **Bot ID** = your **Blueprint ID**.

## 6. Create instances (hire) & license

In Microsoft Teams → **Apps → Agents for your team** → find your blueprint → **create an
instance**. Each instance is an **agent user** with its own mailbox, OneDrive, and Teams
presence. Assign licenses per instance as in [setup-MAF-ACA-DW.md](setup-MAF-ACA-DW.md) §8 if
the policy template didn't (admin approval may be required before hiring).

## 7. Observability

App Insights is auto-injected. For the A365 exporter, assign the app role
**`Agent365.Observability.OtelWrite`** to the agent identity SP and restart the container
(same as [setup-MAF-FH-OBO.md](setup-MAF-FH-OBO.md) §5). If an invocation errors, the response
includes a `FOUNDRY_AGENT_SESSION_ID`; stream the container's session logs:

```powershell
pwsh -File .\scripts\read-logs.ps1 -Mode session -SessionId <session-id>
# or the REST :logstream endpoint:
#   GET https://<account>.services.ai.azure.com/api/projects/<project>/agents/<agent>/sessions/<sid>:logstream
#       ?api-version=2025-11-15-preview   (Headers: Authorization: Bearer, Accept: text/event-stream,
#        Foundry-Features: HostedAgents=V1Preview)
```

## 8. Tool Gateway (Work IQ)

As an AI teammate, the DW reaches Work IQ tools through the Tool Gateway with its **own
identity** (own mailbox) and/or OBO for a requesting user. Add servers via
`ToolingManifest.json` and grant blueprint permissions (`a365 setup permissions mcp` +
admin consent) exactly as for the ACA agents.

## 9. Verify

Interact with the agent user directly in **Teams** (1:1 / @mention), by **email**, or via
**Office comments**. Confirm the instance **Status = Active** in the admin center and check
telemetry in Application Insights / Agent 365 observability.
