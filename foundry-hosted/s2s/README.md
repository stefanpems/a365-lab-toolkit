# Agent 365 — S2S Foundry Hosted Agent (Python, Agent Framework)

A [Microsoft Foundry **Hosted Agent**](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agents)
that acts with **its own identity (S2S)**: when it sends an email, the message is sent
from **the agent's own mailbox** (its agent user).

## How it works

- **Hosting model:** Foundry Hosted Agent (preview) via the Agent Framework hosting
  integration. Uses the **Responses** protocol (`ResponsesHostServer`), the recommended
  default; the platform manages history/streaming and the agent needs no per-user token.
- **Chat model:** `FoundryChatClient` using the `FOUNDRY_PROJECT_ENDPOINT` /
  `AZURE_AI_MODEL_DEPLOYMENT_NAME` injected by Foundry at runtime.
- **Mail tool:** the Agent 365 Mail MCP is attached explicitly with
  `MCPStreamableHTTPTool` (Foundry does **not** auto-wire M365 tools). Each call carries
  a fresh **agent-identity** token (`DefaultAzureCredential`) → mail is sent as the agent.
- **Auth flow:** [Agent 365 agent-identity authentication](https://learn.microsoft.com/microsoft-agent-365/developer/identity#authentication-flows)
  ("send email from the agent's mailbox").

> ⚠️ **Prerequisite for sending mail:** the agent must have an **agent user** provisioned
> and assigned a **Microsoft 365 license** (mailbox). Mailbox provisioning can take up to
> 24h after license assignment. The token used against the Mail MCP must represent that
> agent user (the Agent 365 agentic-user token), not merely the agent app identity —
> confirm the acquired token maps to the licensed agent user.

## Files

| File | Purpose |
| --- | --- |
| `main.py` | Foundry Responses host wrapping the agent. |
| `foundry_agent.py` | Builds the `Agent` + Mail MCP tool bound to the agent's own identity. |
| `ToolingManifest.json` | Declares the Agent 365 Mail MCP endpoint. |
| `requirements.txt` | Runtime dependencies. |
| `.env.template` | Local-run environment variables. |

## Local run

```powershell
python -m venv .venv; .\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.template .env   # then fill in FOUNDRY_PROJECT_ENDPOINT + model
az login                       # identity able to get an Agent 365 Tools token
python main.py                 # http://localhost:8088/responses
```

Invoke:

```powershell
curl -X POST http://localhost:8088/responses `
  -H "Content-Type: application/json" `
  -d '{ "input": "Send a status email to my manager", "stream": false }'
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
azd ai agent init            # choose Python, Agent Framework, Responses
azd provision                # creates Foundry project, model, ACR, App Insights, agent
azd deploy                   # builds container, deploys the hosted agent
```

Prerequisites: `Foundry User`/`Foundry Project Manager` at project scope, `Owner`/
`Contributor` on the resource group (Azure Bot Service), a region that supports Hosted
agents, and at least one **Microsoft Agent 365 / M365 Copilot** license in the tenant.
See [hosted agent permissions](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agent-permissions).

## Publish to Agent 365 + create the agent user

To give the agent its own Entra Agent ID, an **agent user**, and a license (mailbox),
publish it as an **autopilot** and complete admin approval:
[Publish an autopilot in Microsoft Agent 365](https://learn.microsoft.com/azure/foundry/agents/how-to/agent-365).
The agent-identity model (blueprint → instance → agent user) is described in
[Agent 365 Identity](https://learn.microsoft.com/microsoft-agent-365/developer/identity).
