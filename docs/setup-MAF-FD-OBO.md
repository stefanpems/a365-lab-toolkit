# Setup — MAF-FD-OBO (Agent Framework, Foundry **Declarative** / prompt agent, On-Behalf-Of)

> Build a Foundry **prompt agent** (declarative) that acts **on behalf of the signed-in user**
> (OBO): the Agent 365 Mail MCP is attached to the agent definition and the user's delegated
> Mail token is supplied **per request** so mail is sent from the **user's own mailbox**.
> Consumed from the web SPA. Reference implementation: **`agentframeworkFD-OBO-agent`**
> (folder [foundry-declarative/obo](../foundry-declarative/obo)).

See [00-introduction.md](00-introduction.md) for concepts. Use a **neutral** Foundry **project**
name that hosts FH *and* FD agents of any type; only the agent name carries the type.

---

## 0. Prerequisites

- **az login** with **Foundry User** on the project and **Cognitive Services User** on the
  Foundry account (to invoke the agent).
- A Foundry project with a chat model (e.g. `gpt-4.1`).
- Python venv with `azure-ai-projects azure-identity httpx openai msal python-dotenv`
  (`httpx` is a runtime dependency of `azure-ai-projects` and is listed in `requirements.txt`).
- The **Agent 365 Tools** Mail MCP consent (`McpServers.Mail.All`) available to the public
  client used to fetch the test token (the "Agent 365 CLI" app `3c5eabff-…`).

> **Identity gotcha (`DefaultAzureCredential`).** `deploy_agent.py` authenticates with
> `DefaultAzureCredential`. On a dev box that also has **corporate** credentials cached (VS,
> Azure PowerShell, the Windows shared-token cache), that chain can silently pick the **wrong**
> identity and fail with *"Identity(object id: …) does not have permissions for
> Microsoft.CognitiveServices/accounts/AIServices/agents/write"*. Two things to check before
> deploying: (1) pin the Azure CLI to the **target** account —
> `az account set --subscription <target-sub>` and confirm
> `az account show --query user.name` is your **target** admin (the active account can flip if
> another `az login` runs elsewhere); (2) force the credential chain to use only the CLI:
> `$env:AZURE_TOKEN_CREDENTIALS = "AzureCliCredential"` (PowerShell) before `python deploy_agent.py`.

## 1. Get the sources

```powershell
git clone https://github.com/<your-org>/a365-agent-lab.git
cd a365-agent-lab/foundry-declarative/obo
python -m venv .venv ; .\.venv\Scripts\Activate.ps1 ; pip install -r requirements.txt
copy .env.template .env   # edit: project endpoint, model, agent name
```

## 2. Deploy the prompt agent (with the Mail MCP tool)

```powershell
python deploy_agent.py
# -> Deployed prompt agent: name=agentframeworkFD-OBO-agent version=1
```

`deploy_agent.py` creates the version with:
- `MCPTool(server_label="mcp_MailTools", server_url=<Mail MCP gateway>, require_approval="never",
  headers={"Authorization": "{{mail_token}}"})` — the Authorization header is a **template**.
- `structured_inputs={"mail_token": StructuredInputDefinition(required=False, default_value="", …)}`
  — the delegated Mail token is supplied **per request**. (Optional inputs **must** carry a
  `default_value`, else the API rejects with *"Must be specified for optional inputs"*.)

## 3. Test end-to-end (OBO mail)

The Foundry gateway lists the MCP tools on **every** invocation, so a valid Mail token is
needed even for a "hello" turn (an empty header → `400`). Acquire a delegated Mail token and
invoke in one process:

```powershell
python run_obo_test.py --message "Send a short test email to <internal-recipient> with subject 'FD OBO test'."
# completes a device-code sign-in, then invokes the agent; mail is sent from YOUR mailbox.
```

Under the hood the invoke is a **project-level Responses** call:

```python
openai.responses.create(
    input=message,
    extra_body={
        "agent_reference": {"name": AGENT_NAME, "type": "agent_reference"},
        "structured_inputs": {"mail_token": f"Bearer {token}"},
    },
)
```

The invocation authenticates to the Foundry gateway with a token for
`https://ai.azure.com/.default`; the endpoint is `{project}/openai/v1/responses`.

## 4. Web SPA integration

Add a `foundry-prompt` tab to `ui/config.js` (see [setup-web-ui.md](setup-web-ui.md)):

```js
{ id:"obo-fd", kind:"foundry-prompt", name:"FD-OBO",
  endpoint:"https://<account>.services.ai.azure.com/api/projects/<project>/openai/v1/responses",
  endpointScope:"https://ai.azure.com/.default",
  agentName:"agentframeworkFD-OBO-agent",
  mailScope:"ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/McpServers.Mail.All" }
```

The SPA sends `{ input, agent_reference, structured_inputs:{ mail_token } }`. Because a prompt
agent has **no server-side code** to decode the caller's token (the `mail_token` is only used
server-side as the MCP header), the SPA also passes the signed-in user's **verified profile**
in `input` so the agent can answer "who am I?".

## 5. RBAC & consent

- **Entra**: the SPA app needs `McpServers.Mail.All` (Mail) and Azure Machine Learning Services
  `user_impersonation` (for `https://ai.azure.com/.default`), admin-consented AllPrincipals.
- **Azure RBAC**: assign **Cognitive Services User** on the Foundry account to your access
  group (same account/role as the FH agents; the prompt agent lives in the same project).

## Notes

- Prompt agents run the agent loop on the platform — you ship **no code/container**, only the
  definition (model + instructions + tools).
- OBO here = per-request Mail token via a **structured input** that fills the MCP tool header.
