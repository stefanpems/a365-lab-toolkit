# Agent 365 — OBO Foundry Hosted Agent (Python, Agent Framework)

A [Microsoft Foundry **Hosted Agent**](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agents)
that acts **On-Behalf-Of (OBO)** the signed-in user: when it sends an email, the message
is sent from **the user's own mailbox**.

## How it works

- **Hosting model:** Foundry Hosted Agent (preview) via the Agent Framework hosting
  integration. Uses the **Invocations** protocol (`azure.ai.agentserver.invocations`)
  because OBO needs per-request access to the caller's delegated token.
- **Chat model:** `FoundryChatClient` using the `FOUNDRY_PROJECT_ENDPOINT` /
  `AZURE_AI_MODEL_DEPLOYMENT_NAME` injected by Foundry at runtime.
- **Mail tool:** the Agent 365 Mail MCP is attached explicitly with
  `MCPStreamableHTTPTool` (Foundry does **not** auto-wire M365 tools). The MCP call
  carries the **user's** delegated token → the mail is sent as the user.
- **Auth flow:** [Agent 365 On-Behalf-Of flow](https://learn.microsoft.com/microsoft-agent-365/developer/identity#authentication-flows).

> ⚠️ The delegated token passed to the agent must have audience = **Agent 365 Tools**
> (`ea9ffc3e-8a23-4a7d-836d-234d7c7565c1`). A naive confidential-client OBO
> (jwt-bearer) exchange fails for agentic apps with **AADSTS82002**; obtain the token
> through the Agent 365 delegated flow and pass it per invocation.

## Files

| File | Purpose |
| --- | --- |
| `main.py` | Foundry Invocations host; reads the user token and runs one OBO turn. |
| `foundry_agent.py` | Builds the per-request `Agent` + Mail MCP tool bound to the user token. |
| `ToolingManifest.json` | Declares the Agent 365 Mail MCP endpoint. |
| `requirements.txt` | Runtime dependencies. |
| `.env.template` | Local-run environment variables. |

## Local run

```powershell
python -m venv .venv; .\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.template .env   # then fill in FOUNDRY_PROJECT_ENDPOINT + model
python main.py                 # http://localhost:8088/invocations
```

Invoke (supply the user's Mail MCP token in the body):

```powershell
curl -X POST http://localhost:8088/invocations `
  -H "Content-Type: application/json" `
  -d '{ "message": "Send a test email to me", "mail_token": "<user-delegated-mail-mcp-token>" }'
```

## Deploy to Foundry (azd)

> These projects were hand-authored for the code layer. The **`azure.yaml`** manifest,
> `Dockerfile`, and infra are generated/validated by the Azure Developer CLI. Generate
> them once with `azd ai agent init`, then keep `main.py` / `foundry_agent.py` /
> `requirements.txt` as the app code.

```powershell
# one-time tooling
winget install Microsoft.Azd
azd ext install microsoft.foundry
az login; azd auth login

# scaffold the azd project (adds azure.yaml with startupCommand `python main.py`)
azd ai agent init            # choose Python, Agent Framework, Invocations/Responses
azd provision                # creates Foundry project, model, ACR, App Insights, agent
azd deploy                   # builds container, deploys the hosted agent
```

Prerequisites: `Foundry User`/`Foundry Project Manager` at project scope, `Owner`/
`Contributor` on the resource group (Azure Bot Service), a region that supports Hosted
agents, and at least one **Microsoft Agent 365 / M365 Copilot** license in the tenant.
See [hosted agent permissions](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agent-permissions).

## Publish to Agent 365 (optional)

To bring the agent into the Agent 365 registry with its own Entra Agent ID and connect
it to Teams / M365 surfaces, publish it as an **autopilot**:
[Publish an autopilot in Microsoft Agent 365](https://learn.microsoft.com/azure/foundry/agents/how-to/agent-365).
