# Setup — MAF-FD-DW (Agent Framework, Foundry **Declarative** / prompt agent, Digital Worker)

> Build a Foundry **prompt agent** (declarative: model + instructions + tools, run by the
> platform — no container) and **publish it as a Digital Worker** to Microsoft Agent 365, so
> it gets its **own agent identity + license** and is used from **Microsoft Teams**.
> Reference implementation: **`agentframeworkFD-DW-agent`** / **`agentframeworkFD-DW2-agent`**
> (folder [foundry-declarative/dw](../foundry-declarative/dw)).

See [00-introduction.md](00-introduction.md) for concepts. Foundry Declarative (`FD`) is the
third hosting/dev model (alongside ACA and FH): the platform runs the agent from its
definition; you don't ship code or a container.

> **Naming**: the Foundry **project** name must be **neutral** (no `FH`/`FD`/auth in it) — one
> project hosts FH *and* FD agents of any type. Only the **agent name** carries the type
> (`agentframeworkFD-DW-agent`). In this lab we reused an FH-named project for convenience,
> which is misleading; for a clean setup name the project e.g. `agent365-agentframework-foundry`.

---

## 0. Prerequisites

- **az login** with, on the resource group that hosts the Foundry account:
  - **Foundry User** on the project (create/manage/publish agents), and
  - **Azure Bot Service Contributor** (or Contributor/Owner) to create the Bot Service.
- Register the Bot Service provider: `az provider register --namespace Microsoft.BotService`.
- A **Foundry project** with a deployed chat model (e.g. `gpt-4.1`). Reuse an existing one or
  create a neutral-named project.
- **Frontier** licensing on the tenant for the Digital Worker experience (as for any AI
  teammate / autopilot) — the license assigned on approval is **Microsoft 365 Frontier for
  Autopilot**.
- Python venv with `azure-ai-projects azure-identity requests python-dotenv` (see
  `requirements.txt`).

## 1. Get the sources

```powershell
git clone https://github.com/<your-org>/agent365-agentframework-samples.git
cd agent365-agentframework-samples/foundry-declarative/dw
python -m venv .venv ; .\.venv\Scripts\Activate.ps1 ; pip install -r requirements.txt
copy .env.template .env   # then edit .env (project endpoint, model, RG, names)
```

Files: `agent_config.py` (project/model/agent name + publish metadata), `deploy_agent.py`
(create the prompt-agent version), `bot-service.bicep` (Azure Bot Service), `publish_autopilot.py`
(publish flow), `.env.template`, `.gitignore`.

## 2. Deploy the prompt agent

```powershell
python deploy_agent.py
# -> Deployed prompt agent: name=agentframeworkFD-DW-agent version=1
```

`deploy_agent.py` calls `AIProjectClient.agents.create_version(agent_name, PromptAgentDefinition(model, instructions))`.

> A Foundry prompt-agent version automatically gets a **`ManagedAgentIdentityBlueprint`** plus
> an **`agent_guid`** and an `instance_identity`. You can see them with:
> `python publish_autopilot.py identity` (and the full details via the Foundry API). These are
> exactly what the Digital Worker publish needs — so **a prompt agent can become a Digital
> Worker**.

## 3. Publish as a Digital Worker (the correct procedure)

> ⚠️ **Use the `dwpublish` command.** The Foundry data-plane
> `…/agents/{name}/microsoft365/publish` with `publishAsAutopilot=true` returned a persistent
> `502 upstream_dependency_failed` in the lab, and the Foundry **portal** "Publish → Teams &
> M365 Copilot" publishes a **plain Agent** (no own-identity/license template). The reliable
> way to get the **own-identity + Frontier-for-Autopilot license** is the **AzureML
> agent-asset digital-worker publish** — the same mechanism the container FH-DW uses.

```powershell
python publish_autopilot.py dwpublish
```

`dwpublish` performs, in one shot:

1. **Reads the asset**: `GET {project}/agents/{name}` → `agent_guid`, `blueprint.client_id`,
   `instance_identity`.
2. **Creates the Azure Bot Service** (`bot-service.bicep`, F0, Teams channel) wired to the
   agent's **activity-protocol endpoint**. **Critical:** the bot's `msaAppId` must be the
   **blueprint `client_id`** (not the instance identity), or the Teams↔Foundry relay fails.
3. **Calls the AzureML digital-worker publish**:

   ```
   POST https://<location>.api.azureml.ms/agent-asset/v2.0/subscriptions/<sub>/resourceGroups/<rg>
        /providers/Microsoft.MachineLearningServices/workspaces/<account>@<project>@AML/microsoft365/publish
   Authorization: Bearer <token for https://ai.azure.com>
   {
     "agentGuid": "<agent_guid>",
     "botId": "<blueprint.client_id>",
     "publishAsDigitalWorker": true,
     "appPublishScope": "Tenant",
     "subscriptionId": "<sub>",
     "agentName": "<agent-name>",
     "appVersion": "1.0.0",
     "shortDescription": "…", "fullDescription": "…", "developerName": "…",
     "useAgenticUserTemplate": true,
     "agenticUserTemplate": {
       "Id": "digitalWorkerTemplate",
       "File": "agenticUserTemplateManifest.json",
       "SchemaVersion": "0.1.0-preview",
       "AgentIdentityBlueprintId": "<blueprint.client_id>",
       "CommunicationProtocol": "activityProtocol"
     }
   }
   ```

   A successful response returns a `titleId` and `teamsAppId`. (The `agenticUserTemplate` is
   sent **inline** — no separate manifest file is needed.)

## 4. Approve in the Microsoft 365 admin center

1. [M365 admin center → Agents → All agents → **Requests**](https://admin.cloud.microsoft/#/agents/all/requested).
2. Find your agent (Publisher = your `developerName`) → **Publish to store / Approve**.
3. In the **Apply template** step you now get the **agent-with-own-identity** policy template
   and a **Licenses** section (**Microsoft 365 Frontier for Autopilot**). Choose the template
   that assigns the license → **Accept permissions** → **Finish**.

> If you instead see only "Default policy template for agents" **without** a Licenses section,
> the agent was published as a **plain Agent** (portal regular publish or the 502-blocked
> `publishAsAutopilot` path), **not** as a Digital Worker. Re-publish with `dwpublish`.

## 5. Use it in Teams

After approval the agent is in the **Registry**, appears in **Teams → Apps → Built for your
org** and the **M365 Copilot agent store → Built by your org**. Add it / create an instance
and chat. The Digital Worker acts with its **own agent identity** (own Entra identity + the
Frontier-for-Autopilot license assigned by the template).

## 6. Observability & tools

Same as the other Foundry agents: App Insights is available on the project; to export to
Agent 365, grant the `Agent365.Observability.OtelWrite` app role to the agent identity. Attach
Work IQ / MCP tools on the prompt-agent definition (see [setup-MAF-FD-OBO.md](setup-MAF-FD-OBO.md)
for the Mail MCP with a per-request token).

## Notes / lessons learned

- A prompt agent **does** carry a `ManagedAgentIdentityBlueprint` + `agent_guid` → it **can**
  be a Digital Worker (contrary to first impressions).
- The **data-plane** `publishAsAutopilot=true` path was **502-broken** in the lab; the
  **AzureML `publishAsDigitalWorker`** path works. The portal "Publish to Teams" is a
  **plain-Agent** publish (no license).
- Bot Service `msaAppId` **= blueprint client_id** (not instance identity).
- Bump `appVersion` (env `PUBLISH_APP_VERSION`) to re-publish (else "version already exists").
