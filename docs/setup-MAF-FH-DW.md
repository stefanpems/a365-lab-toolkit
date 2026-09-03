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

> **⚠️ Check this first — governed subscriptions (storage shared-key).** If your subscription
> enforces the policy **"Storage accounts should prevent shared key access"** (`allowSharedKeyAccess=false`),
> the default `azd provision` **will stop midway** at the blueprint step with
> `KeyBasedAuthenticationNotPermitted` (the ARM deployment script that creates the blueprint mounts
> a storage file share with the shared key). This is **expected and recoverable** — follow the
> **governed-subscription flow in §3** (create the blueprint out-of-band, then re-provision). Detect
> it up front:
>
> ```powershell
> # 'Deny' effect on a shared-key policy assignment => you are on the governed flow.
> az policy assignment list --disable-scope-strict-match `
>   --query "[?contains(to_string(displayName),'shared key') || contains(to_string(displayName),'Shared Key')].{name:displayName}" -o table
> ```

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

> **Azure Bot Service handles are GLOBALLY unique** (across all tenants). To avoid an
> `InvalidBotData: The bot name is already registered to another bot application` error when more
> than one person deploys this sample, `main.bicep` defaults the bot handle to
> `fhdw-bot-<hash(resourceGroup)>`. Override it with the azd var **`AGENT_BOT_NAME`** if you want a
> specific handle (2–42 chars). The handle is internal — Teams/publish bind to the **blueprint id**,
> not the bot handle.

### Path A — standard subscription

```powershell
azd provision
```

This runs the whole thing in one shot. The **postprovision** hook (`scripts/post-provision.ps1`)
orchestrates the five pieces:

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

### Path B — governed subscription (storage **shared-key disabled**)

If you flagged the policy in §0, use this **three-step** flow. It is the *same* deployment, just
with the blueprint created out-of-band (the only step the policy blocks). **Expect the first
`azd provision` to stop at the blueprint step** — that is normal here, not a real failure.

```powershell
# 1. Provision the base. It creates account/project/model/ACR, then STOPS at the blueprint
#    deployment script with 'KeyBasedAuthenticationNotPermitted'. That is expected.
azd provision

# 2. Create the blueprint out-of-band + wire it back into azd (idempotent helper). It discovers
#    the account/project in the RG, grants you 'Cognitive Services User', PUTs the blueprint,
#    deletes the failed script, and runs `azd env set AGENT_IDENTITY_BLUEPRINT_CLIENT_ID`.
pwsh -File .\scripts\create-agent-blueprint.ps1 -ResourceGroup <your-rg>

# 3. Re-provision. With AGENT_IDENTITY_BLUEPRINT_CLIENT_ID set, main.bicep SKIPS the deployment
#    script and finishes the Bot Service + monitoring + the full postprovision (steps 1–5 above).
azd provision
```

**Why this happens & why it is safe.** The blueprint is normally created by an ARM **deployment
script** (`infra/modules/maib-creation-script.bicep`) whose container mounts an Azure File share
with the storage **shared key** — blocked by the policy. `main.bicep` therefore accepts a
pre-created blueprint client id via `agentIdentityBlueprintClientId` (azd var
`AGENT_IDENTITY_BLUEPRINT_CLIENT_ID`); when set, the deployment-script modules are skipped and the
value feeds the Bot Service `msaAppId` + the `AGENT_IDENTITY_BLUEPRINT_ID` output. The helper makes
the **same** data-plane call the script would (`PUT {projectEndpoint}/managedagentidentityblueprints/{maibName}`)
but from your own Entra ID token — no storage, no shared key. This mirrors the wider pattern for
this subscription: **when a key-based mechanism is blocked, replace it with an Entra ID call** (the
same reasoning used for Azure OpenAI key auth → managed identity in the ACA samples).

### 3.2 What a successful provision looks like

`azd` ends with `SUCCESS: Your application was provisioned in Azure`, and the postprovision hook
prints `Publish digital worker script finished` with a `titleId` + `teamsAppId`, the OAuth2 grants
(MCP `McpServers.*` + APX `AgentData.ReadWrite`), and `Adding current user as blueprint owner`. The
resource group then contains:

| Resource | Example name |
|---|---|
| Foundry account + project + model (`gpt-4.1`) | `dwfh<hash>acct` / `…proj` |
| Container Registry | `dwfh<hash>acr` |
| Deployment-script UMI | `foundry-deployment-script-umi` (only on the standard path) |
| **Azure Bot Service** (Teams channel) | `fhdw-bot-<hash>` |
| Log Analytics workspace | `<env>-logs` |

Sanity check: the Bot Service **`msaAppId` must equal your Blueprint ID** (`azd env get-values →
AGENT_IDENTITY_BLUEPRINT_ID`). Verify with
`az bot show -n <bot> -g <rg> --query properties.msaAppId`.

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
