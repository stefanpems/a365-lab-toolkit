# Setup — MAF-FD-S2S (Agent Framework, Foundry **Declarative** / prompt agent, Service-to-Service)

> Build a Foundry **prompt agent** (declarative) that acts with its **own identity** (no user
> OBO): a pure conversational assistant with **no Mail tool** (a pure S2S identity cannot use
> the delegated Work IQ Mail MCP). Consumed from the web SPA. Reference implementation:
> **`agentframeworkFD-S2S-agent`** (folder [foundry-declarative/s2s](../foundry-declarative/s2s)).

See [00-introduction.md](00-introduction.md) for concepts and
[setup-MAF-FD-OBO.md](setup-MAF-FD-OBO.md) for the shared Foundry-project/RBAC notes.

---

## 1. Get the sources

```powershell
git clone https://github.com/<your-org>/a365-lab-toolkit.git
cd a365-lab-toolkit/foundry-declarative/s2s
python -m venv .venv ; .\.venv\Scripts\Activate.ps1 ; pip install -r requirements.txt
copy .env.template .env
```

Files: `agent_config.py` (own-identity instructions; only the optional web-access tool), `deploy_agent.py`,
`invoke_agent.py`, `requirements.txt`, `.env.template`, `.gitignore`.

## 2. Deploy the prompt agent

```powershell
python deploy_agent.py
# -> Deployed prompt agent: name=agentframeworkFD-S2S-agent version=1
```

`deploy_agent.py` creates the version with `PromptAgentDefinition(model, instructions, tools)`. It has
**no Mail / user-data tools** (own identity, no mailbox). Its only tool is **web access**, and only when
`WEB_FETCH_MCP_URL` is set in `.env`: an `MCPTool(server_label="web_fetch", server_url=WEB_FETCH_MCP_URL,
allowed_tools=["fetch_url"], require_approval="never")` with **no Authorization header**. It lets the agent
check whether a public URL is reachable (HTTP status) and read the page. The Lab Builder deploys the
per-lab [web-fetch MCP](../web-fetch-mcp/README.md) and fills the URL, but only after that server's
smoke test passes. If the value is empty, the agent is deployed without web access.

## 3. Test

```powershell
python invoke_agent.py --message "Hello! In one sentence, who are you and what can you do?"
python invoke_agent.py --message "Can you read the content of https://example.com/ or at least tell me whether it is reachable (HTTP 200)?"
```

No token beyond your `az login` is needed (the web-fetch MCP is anonymous; no per-request Mail token).
The invoke is a project-level Responses call with `agent_reference`.

## 4. Web SPA integration

Add a `foundry-prompt` tab **without** `mailScope` (see [setup-web-ui.md](setup-web-ui.md)):

```js
{ id:"s2s-fd", kind:"foundry-prompt", name:"FD-S2S",
  endpoint:"https://<account>.services.ai.azure.com/api/projects/<project>/openai/v1/responses",
  endpointScope:"https://ai.azure.com/.default",
  agentName:"agentframeworkFD-S2S-agent" }
```

`callFoundryPrompt` handles the missing `mailScope` (no `structured_inputs`); it still passes
the signed-in user's **verified profile** in `input` so the agent can personalize replies /
answer "who am I?" while acting as itself.

## 5. RBAC & consent

- **Entra**: the SPA app needs Azure Machine Learning Services `user_impersonation` (for
  `https://ai.azure.com/.default`). No Mail scope required for S2S.
- **Azure RBAC**: **Cognitive Services User** on the Foundry account for the invoking users.

## Notes

- S2S here = the agent acts with its **own identity**; it has no mailbox and no user data. For
  Work IQ tools in S2S you'd need an **application app-role** on the resource (same limitation
  as MAF-ACA-S2S / MAF-FH-S2S) — out of scope for this conversational sample.
