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
  **Global Administrator** (Tenant Admin) for org-wide configuration/consent. No Agent-ID directory
  role is needed: the instances' MCP tool scopes (incl. Mail) are declared at publish time via
  `optionalPermissionScopes` and the **platform** configures the blueprint's inheritable permissions
  at admin approval — you never `PATCH` the blueprint yourself (§8.1).
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
git clone https://github.com/<your-org>/a365-agent-lab.git
cd a365-agent-lab/foundry-hosted/dw
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
   metadata, and **declares the MCP tool scopes** the instances need via `optionalPermissionScopes`
   (incl. `McpServers.Mail.All`). At admin approval the **platform** uses these to configure the
   blueprint's inheritable permissions, so every hired **instance** inherits them — without this,
   instances get `AADSTS65001 consent_required` on the Mail token and report *"I cannot send
   emails"* (see §8.1).
4. **OAuth2 grants** for the blueprint (`create-blueprintsp-oauth2-grants.ps1`): admin-consents the
   MCP/APX scopes on the blueprint **service principal**. (It does **not** touch the blueprint's
   `inheritablePermissions` — that is platform-managed, driven by step 3's `optionalPermissionScopes`.)
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

## 4. Approve, grant consent & publish

The provisioned agent lands as a **request** in the admin center. Approving it is a wizard, not a
single click.

1. [M365 admin center → Agents → All agents → **Requests**](https://admin.cloud.microsoft/#/agents/all/requested)
   → open your agent (e.g. `agentframeworkFH-DW2-agent`, **Pending review**, *Platform: Microsoft
   Foundry*). The **Details** tab shows the version, owner, and the **Entra agent ID**.
2. **Permissions** tab → **Grant admin consent** for the scopes the agent needs:
   - `Agent365.Observability.OtelWrite` (**Application**) — telemetry to Agent 365.
   - `AgentData.ReadWrite` (Messaging Bot API, **Delegated**).
   - the **Agent Tools** `McpServers.*.All` set (Mail, Teams, Calendar, Files, SharePoint,
     Word/Excel/PowerPoint, Dataverse, D365, …) — all **Delegated**.
   - `AgentIdentity.CreateAsManager` (Microsoft Graph, **Application**).
3. **Publish to store** → the *Publish new agent* wizard:
   1. **Publish to users** — *Host products* = **Copilot**; *Publish* = **All users**;
      *Activate* = **All users** (or specific users/groups who may create instances).
   2. **Apply template** — pick your **AI-teammate policy template** (§7.1 of
      [setup-MAF-ACA-DW.md](setup-MAF-ACA-DW.md)). It must carry **Microsoft 365 Frontier for
      Autopilots (no Teams)** + **Microsoft Teams Enterprise**. The default Entra/Purview/Defender/
      SharePoint protections are listed below the template.
   3. **Accept permissions** → **Grant admin consent**. A **blueprint consent popup** appears —
      *"Allow agents created from this blueprint to access data?"* (Access agent data, Enable Agent
      365 Telemetry, Sign you in and read your profile). Click **Allow** → the wizard then shows
      *"All required permissions have been granted."*
   4. **Review and finish** → **Publish** → *"You published `<agent>`"*.
4. The agent now shows **Available** in **Agents → All agents** (Platform *Microsoft Foundry*).

## 5. Configure Teams integration (REQUIRED — this is what makes instances respond)

**Without this step an instance is created but stays silent in Teams** — messages never reach the
Foundry agent because the blueprint has no backend wired to the Bot Service. The postprovision
hook that would do it (`scripts/configure-blueprint-backend.ps1`) is **commented out**, so do it
manually:

1. Open the [Teams Developer Portal → agent-blueprint](https://dev.teams.microsoft.com/tools/agent-blueprint)
   (if your blueprint isn't listed, open any blueprint and replace the id in the URL with your
   Blueprint ID from `azd env get-values`).
2. Under **Configuration**, set the **Bot ID** = your **Blueprint ID** (= the Bot Service
   `msaAppId`). Save.

> This sets the blueprint **backendConfiguration** (`botBased.botId = <BlueprintId>`). Doing it via
> `scripts/configure-blueprint-backend.ps1` needs an **interactive** Teams-scoped token — a plain
> `az account get-access-token --resource https://dev.teams.microsoft.com` returns **403**. If you
> prefer the script, first run `az login --scope https://dev.teams.microsoft.com/.default` (as the
> blueprint owner), set `AGENT_IDENTITY_BLUEPRINT_ID`, then run it. The **UI path above is the
> reliable one.** After saving, an existing silent instance starts responding within a minute or two
> (recreate the instance if it stays silent).

## 6. Create instances (hire) & license

In Microsoft Teams → **Apps → Agents for your team** → find your agent → **create an
instance**. Each instance is an **agent user** with its own mailbox, OneDrive, and Teams
presence.

The M365 Copilot store's **Create** action can complete without a useful confirmation and without
adding the instance under **Your agents**. Before retrying, verify the authoritative state in
**Admin center → Agents → `<agent template>` → Instances**. The hired instance is an agent user,
not another Agent Store app; find it by name/alias in Teams. Registry **Available** can precede
end-to-end Teams message routing.

### 6.1 Give instances a mailbox + full O365 — add **Microsoft 365 E7** on the Licenses tab

The AI-teammate policy template only assigns the **minimum** — **Frontier for Autopilots (no
Teams)** + **Teams Enterprise**. That yields the agent identity + Teams presence but **not a full
mailbox / O365 resources**. To make each new instance get a **mailbox + OneDrive + full O365**, add
**Microsoft 365 E7 (No Teams)** (or E5) to the template's license set:

1. Admin center → **Agents → All agents** → open your agent (the **template**) → **Licenses** tab.
2. Check **Microsoft 365 Frontier for Autopilots (no Teams)** + **Microsoft Teams Enterprise** +
   **Microsoft 365 E7 (No Teams)** → **Save changes**.
3. You get *"License assignment updated. New agent instances created from this template will be
   assigned the licenses you selected."* — the **Licenses (3)** set is now inherited by every new
   instance.

> **Why the Licenses tab and not the template wizard.** You **cannot** add E5/E7 while *creating*
> the policy template (the **Save hangs** — same gotcha as [setup-MAF-ACA-DW.md](setup-MAF-ACA-DW.md)
> §7.1). Adding E5/E7 **here**, on the deployed agent's **Licenses** tab, works. Assign the
> licenses **before** hiring so instances inherit the mailbox + O365 from creation.

> **Known MAC bug (observed 2026-09-05).** The current
> **Instances → `<instance>` → Licenses** route can replace the complete Agents page with only
> *"An error occurred."* The failure occurs client-side before a license request is issued and was
> reproduced on FH-DW. Do not use per-instance licensing as the repeatable path in
> this preview. Correct the **template** license set, then delete and re-hire an incorrectly licensed
> instance.

> **Exhaustion and stale counts.** If any selected product reaches zero availability, the template
> says *"You have run out of licenses"*, Add instance is disabled, and the store rejects new hires.
> Check Frontier, Teams Enterprise, and E7/E5 separately. Deleted instances release their products
> asynchronously, and an already-open Licenses flyout may continue showing the old count; close and
> reopen it or refresh the Registry before concluding that cleanup failed.

### 6.1.1 Delete unused instances and release their licenses

1. **Agents → All agents** → open the **agent template** row (the row with an instance count).
2. **Instances** → select the exact name/alias → **Permanently delete** → **Delete instance**.
3. Verify it disappears from Instances and wait for all assigned products to return to the tenant
   pool. Preserve any instance not explicitly selected for cleanup.

Do not delete only the Entra object and do not select the similarly named Foundry resource row. In
the validated cleanup, deleting FH-DW3 instances `AFDHDW3I1` through `AFDHDW3I3` preserved
`AFDHDW3I4` and returned three Teams Enterprise seats. The open template flyout still displayed
`0 of 50` until refreshed even though fresh tenant inventory already reported 3 available.

### 6.2 Model access — every instance identity must be able to call the model

**Symptom.** The instance is created, is wired to Teams (§5), and *responds* — but every turn
fails with an error from the chat model, e.g.:

> `Error code: 401 - PermissionDenied — The principal <guid> lacks the required data action`
> `Microsoft.CognitiveServices/accounts/OpenAI/deployments/chat/completions/action to perform`
> `POST /openai/deployments/{deployment-id}/chat/completions` — or simply *"Principal does not have
> access to API/Operation."*

**Root cause — the autopilot per-instance identity model.** An autopilot is *one blueprint → many
instances*, and **each hired instance gets its OWN agent identity** (a distinct Entra service
principal) plus its own agent user account — see
[What is an autopilot](https://learn.microsoft.com/azure/foundry/agents/concepts/autopilot-overview#the-identity-model).
The hosted container authenticates its **model** call with `DefaultAzureCredential`
([agent.py](../foundry-hosted/dw/src/hello_world_a365_agent/agent.py)), which at runtime resolves
to the **instance's** agent identity — **not** the template/published identity. The provisioning
step only grants the model role to the template identity
([agent-creation-script.ps1](../foundry-hosted/dw/scripts/agent-creation-script.ps1) →
`instance_identity.client_id`), so **every newly hired instance starts with no model access**. The
`<guid>` in the error is that instance's principal, and `az role assignment list --assignee <guid>`
returns nothing.

Why a role is needed at all: the sample calls the **account-level Azure OpenAI endpoint directly**
(`https://<account>.openai.azure.com/`). Per
[Hosted agent permissions → Account-level access](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agent-permissions),
an agent's *implicit* model-inference access applies **only when calling through the project
endpoint**; a direct account-endpoint call requires an explicit role at account scope for the
**calling identity** (here, each instance identity).

**Fix — pick one.**

| Option | Covers **future** instances? | What to do |
|---|---|---|
| **A. Route inference through the project endpoint** *(recommended)* | ✅ **Yes — zero per-instance RBAC** | Have the agent call the **project** inference endpoint (`https://<account>.services.ai.azure.com/api/projects/<project>`) instead of the account OpenAI endpoint. Foundry then proxies the call with the **project managed identity** (which already holds `Cognitive Services User`/`Foundry User` on the account), and **every** agent identity in the project — every current and future instance — has **implicit** inference access, so no role assignment is ever required per hire. |
| **B. Grant the role to the instance identity** *(interim / single instance)* | ❌ No — repeat at **every** hire | Assign **`Cognitive Services OpenAI User`** (least-privilege for OpenAI) *or* `Cognitive Services User` to that instance's agent identity at **account** scope. |

> **✅ Implemented in this sample (Option A).** The agent builds its chat client with
> **`agent_framework.foundry.FoundryChatClient`** against the **project endpoint**
> ([agent.py](../foundry-hosted/dw/src/hello_world_a365_agent/agent.py)), and the build script bakes
> `AZURE_AI_PROJECT_ENDPOINT` into the image
> ([build-docker-image-acr.ps1](../foundry-hosted/dw/scripts/build-docker-image-acr.ps1),
> [Dockerfile](../foundry-hosted/dw/src/hello_world_a365_agent/foundry-infra/Dockerfile) +
> `agent-framework-foundry` in
> [requirements.txt](../foundry-hosted/dw/src/hello_world_a365_agent/requirements.txt)). So a freshly
> deployed agent version needs **no per-instance RBAC** — every current and future instance has
> implicit model access. The account-endpoint path (and Option B) remain only as a **fallback** when
> `AzureAIProjectEndpoint` is unset. Existing instances start working after a new agent version is
> rolled out; you do **not** need to grant them anything.

**Interim unblock (option B)** — grant the role to the instance principal named in the error. Use
`--assignee-object-id` (not `--assignee`) so it doesn't need a Microsoft Graph lookup:

```powershell
$sub   = '<subscription-id>'
$scope = "/subscriptions/$sub/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<account>"

az role assignment create `
  --subscription $sub `
  --assignee-object-id '<instance-principal-guid-from-the-error>' `
  --assignee-principal-type ServicePrincipal `
  --role 'Cognitive Services OpenAI User' `
  --scope $scope
```

After RBAC propagates, send a new message — **do not recreate the instance** (a new hire produces a
new principal that again lacks the role).

**Verify** which principal a failing turn used and whether it holds the role:

```powershell
# The <guid> is printed in the Teams error; confirm it has (or lacks) the model role at account scope.
az role assignment list --subscription $sub --scope $scope --include-inherited `
  --assignee-object-id '<instance-principal-guid>' `
  --query "[].{role:roleDefinitionName,scope:scope}" -o table
```

> **Scope of this issue.** This affects **FH-DW only**. **ACA-DW** authenticates the model call with
> the Container App's *own* fixed managed identity (one grant covers all instances; the per-instance
> agentic identity is used only for the Mail token), so it doesn't need per-instance model RBAC.

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

### 8.1 Why instances can send mail — declared publish scopes (AADSTS65001)

An autopilot **instance** is its own agent identity, separate from the blueprint. For an instance to
get a Mail (or any MCP tool) token, the blueprint must expose the resource's scopes as
**inheritable permissions** — otherwise the instance's token exchange fails with
**`AADSTS65001` (`consent_required`)** for app `<instance>` and the agent replies *"I cannot send
emails at the moment."*

**You do not (and must not) configure the blueprint directly.** The autopilot blueprint that Foundry
creates is a **platform-managed** application (`type: System`): user tokens cannot `PATCH` its
`inheritablePermissions` (every attempt returns `403 Authorization_RequestDenied`, even with the
Agent ID Administrator role — the app is not customer-modifiable). Microsoft's guidance is explicit:
*"Customers should not PATCH the blueprint as part of the normal deployment or publication workflow."*

Instead, the required tool scopes are **declared at publish time** and the **platform configures the
blueprint's inheritable permissions for you at admin approval**:

1. **`publish-digital-worker.ps1`** (postprovision step 3) sends an **`optionalPermissionScopes`**
   field in the Microsoft 365 publish body:

   ```powershell
   optionalPermissionScopes = @(
       @{ resourceAppId = "ea9ffc3e-8a23-4a7d-836d-234d7c7565c1"   # Agent 365 Tools (MCP)
          scopes        = @("McpServers.Mail.All", "McpServersMetadata.Read.All") }
   )
   ```

   `McpServers.Mail.All` is the Mail tool; `McpServersMetadata.Read.All` is required alongside any MCP
   tool for tool/metadata discovery (the ACA DW declares the same pair). Add one entry per resource
   app / scope your tools need (e.g. `McpServers.Calendar.All`, `McpServers.Teams.All`).

   > **⚠️ Endpoint matters.** `optionalPermissionScopes` is honored **only** by the Foundry **agent**
   > publish endpoint (`{project}/agents/<name>/microsoft365/publish` with `publishAsAutopilot=true`).
   > The older **AzureML agent-asset** endpoint (`…api.azureml.ms/agent-asset/…/microsoft365/publish`
   > with `publishAsDigitalWorker=true`) **silently ignores** the field — the publish succeeds but the
   > scopes never appear in the admin center **Permissions** tab and instances still hit `AADSTS65001`.
   > `publish-digital-worker.ps1` uses the agent endpoint for this reason.

2. **Admin approval (the "Publish new agent" wizard)** — after publish, an admin approves the agent
   in the **Microsoft 365 admin center** (**Agents → Requests → open the request → Publish**). Two
   steps in this wizard are **mandatory and easy to miss**:

   - **Apply template** — pick a **custom policy template that has a valid Agent 365 License**
     assigned. The **Default policy template** shows *"Create a custom template and select an Agent
     365 License. Autopilot agents require a valid Agent 365 License to create and use instances"* and
     lists **`0 of 0 licenses available`** — selecting it **blocks instance creation**. Create the
     custom template under **Agents → Settings → Templates** (assign a Microsoft Agent 365 license),
     then select it here.
   - **Accept permissions** — on the **Review permissions** step, click **Grant admin consent** for
     the org. Under **Agent Tools** the declared delegated scopes must be listed — **`Mail MCP Server
     All`** (`McpServers.Mail.All`) and **`Read All Mcp Server Metadata`** (`McpServersMetadata.Read.All`)
     — and consented. **This consent is what makes the platform configure the blueprint's inheritable
     permissions**, so every hired instance inherits them. Without it, the scopes stay unconsented and
     instances hit `AADSTS65001`. **Grant admin consent** opens an Entra dialog — *"Allow agents created
     from this blueprint to access data?"* — that lists everything the blueprint's agents will be able
     to do (**Access agent data**, **Mail MCP Server All**, **Read All Mcp Server Metadata**, **Enable
     Agent 365 Telemetry**, **Sign you in and read your profile**); click **Allow** to consent them all.

3. **Hire (or re-hire) an instance** — new instances inherit the scopes at hire time. An instance
   hired **before** the scope was approved will **not** retroactively gain it; hire a fresh instance.

> **Changing the declared scopes later?** Bump the publish version so the endpoint accepts the new
> metadata (it rejects re-publishing an already-published version):
>
> ```powershell
> $env:PUBLISH_APP_VERSION = "1.0.1"   # any value greater than the last published one
> ./scripts/publish-digital-worker.ps1 -AgentGuid <agent_guid>
> ```
>
> Then re-approve in the admin center and re-hire. `create-blueprintsp-oauth2-grants.ps1`
> (postprovision step 4) only admin-consents the scopes on the blueprint **service principal** and
> the APX `AgentData.ReadWrite` scope — it deliberately does **not** touch the blueprint's
> `inheritablePermissions` (that is the platform's job, driven by the publish `optionalPermissionScopes`).


## 9. Verify

Interact with the agent user directly in **Teams** (1:1 / @mention), by **email**, or via
**Office comments**. Confirm the instance **Status = Active** in the admin center and check
telemetry in Application Insights / Agent 365 observability.
