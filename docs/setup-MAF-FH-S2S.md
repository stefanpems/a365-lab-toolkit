# Setup — MAF-FH-S2S (Agent Framework, Foundry Hosted, Service-to-Service, Responses)

> Deploy a **Foundry Hosted Agent** that acts with its **own identity** using the
> **Responses** protocol (OpenAI-compatible `/responses`), consumed by a custom web UI.
> Reference implementation: **`agentframeworkFH-S2S-agent`**.

See [00-introduction.md](00-introduction.md) for concepts and
[setup-MAF-FH-OBO.md](setup-MAF-FH-OBO.md) for the shared tooling/observability/RBAC details.
This guide highlights the S2S differences.

---

## 1. Get the sources

```powershell
git clone https://github.com/<your-org>/a365-agent-lab.git
cd a365-agent-lab/foundry-hosted/s2s
```

Same layout as MAF-FH-OBO (`main.py`, `foundry_agent.py`, `requirements.txt`, `azure.yaml`,
`ToolingManifest.json`).

## 2. Code shape (Responses)

- `main.py`: `agent_framework_foundry_hosting.ResponsesHostServer(build_agent()).run()`.
- `foundry_agent.py`: `build_agent()` uses `FoundryChatClient`. If it calls a Mail MCP tool,
  the httpx client stamps a **fresh agent-identity token** on each request
  (`DefaultAzureCredential` for `<MAIL_MCP_RESOURCE>/.default`) — **no** user/mail token,
  because the agent acts as **itself**.
- Model read with fallback: `os.environ.get("AZURE_AI_MODEL_DEPLOYMENT_NAME","gpt-4.1")`.

## 3. Dependencies

Identical to MAF-FH-OBO:

```
agent-framework-foundry
agent-framework-foundry-hosting>=1.0.0a260630
azure-identity
httpx>=0.24.0
python-dotenv
```

Same rules: don't pin `agent-framework==1.0.0`; don't list `azure-ai-agentserver`.

## 4. Init, provision, deploy

```powershell
azd ai agent init --src . --agent-name agentframeworkFH-S2S-agent `
  --deploy-mode code --runtime python_3_13 --entry-point main.py --protocol responses
azd env set AZURE_RESOURCE_GROUP agentframeworkFH-S2S-rg
azd provision
# deploy gpt-4.1 as in MAF-FH-OBO §4, then:
azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME gpt-4.1
azd deploy
```

- **`azd provision` asks *"Select location"*** here too (it sets `AZURE_LOCATION`). As in
  MAF-FH-OBO §4, pick a region that offers **`gpt-4.1` GlobalStandard** — **East US 2
  (`eastus2`)** works (validated). You can also pre-set it non-interactively with
  `azd env set AZURE_LOCATION eastus2` before provisioning.

Responses is generated with `version: 2.0.0` correctly (unlike Invocations). The output gives
the **Responses endpoint** (`.../protocols/openai/responses?api-version=v1`).

## 5. Observability

Same as MAF-FH-OBO §5. Note the observability flow for S2S uses **client-credentials** (token
claim `roles`, route `/observabilityService/...`) rather than OBO — but the app-role grant on
the agent identity SP and the container restart are the same.

## 6. Custom web UI (SPA) — one token

The Responses call needs only the gateway token; there is **no** user/mail token:

- `Authorization: Bearer <token for https://ai.azure.com/.default>`
- body `{ input, stream:false }` → `output[].content[].text`

Because the S2S agent never receives the user's token, the SPA passes the signed-in user's
**verified profile** (name/UPN from the MSAL account) as **context text** inside `input`, so
the agent can answer "who am I?" without impersonating the user. SPA config entry:

```js
{ id:"s2s-fh", kind:"foundry-responses", name:"…",
  endpoint:"https://<account>.services.ai.azure.com/api/projects/<project>/agents/agentframeworkFH-S2S-agent/endpoint/protocols/openai/responses?api-version=v1",
  endpointScope:"https://ai.azure.com/.default" }
```

The Responses API returns `200` with a `status`; treat `status !== "completed"` as an error
(`data.error.message`). Keep the single client-side retry on `status >= 500`.

## 7. Entra consent & RBAC

- **Entra**: the SPA needs Graph `openid profile offline_access` (AllPrincipals) and Azure
  Machine Learning Services `user_impersonation` (for `https://ai.azure.com/.default`). No Mail
  scope is required for S2S.
- **RBAC**: the Responses protocol is authorized by `responses/*`. The built-in **Foundry
  Project Runtime User** role fits Responses; **Cognitive Services User** also works. Assign it
  on the Foundry account to an access **group** and add users (see MAF-FH-OBO §8).

## 8. Tool Gateway in S2S

The agent uses an **agent-identity (app-only) token** per request. Delegated-only Work IQ
tools (Mail) require an **application app-role** on the resource + admin consent (and an
application access policy for a sender mailbox) before they are reachable — otherwise the same
`AADSTS82001` as ACA-S2S. For a pure conversational S2S agent, no tool wiring is needed.

## 9. Deploy the SPA & verify

Deploy the SPA with the SWA CLI (MAF-FH-OBO §9). Verify with
`azd ai agent invoke <agent> "Hello, what can you do?"` and through the SPA tab; the agent
replies with its own identity (no user impersonation, no mailbox action).
