# Setup — MAF-ACA-DW (Agent Framework, Azure Container Apps, Digital Worker / AI teammate)

> Build an **AI teammate** ("Digital Worker") on **Azure Container Apps**: an agent with its
> **own Entra agent-user identity**, mailbox, OneDrive, and Teams presence, that users
> **hire** and interact with from **Teams / Outlook / Office**. Reference implementation:
> **`AgentFrameworkDWSample`** (blueprint app id `fa48baa5-1de8-4e94-b88e-b72f9b4f2478`).

See [00-introduction.md](00-introduction.md) for concepts. The **code is identical** to
MAF-ACA-OBO; what changes is the **blueprint type (AI teammate)**, the **licensing**, and the
**publish → activate → instance** lifecycle.

---

## 0. Licensing prerequisites (read first — mandatory)

An AI teammate is a **Frontier** feature. Without the right licensing you cannot create or
activate it (*"Insufficient licenses available"*):

- Tenant enrolled in the **Frontier preview program** and **Agent 365 ToS accepted** (M365
  admin center → Agents → Overview → Try now → I agree; Global Admin only).
- ≥ 1 **Microsoft 365 Copilot** *or* **Microsoft Agent 365** license (incl. **M365 E7 /
  Frontier Suite**) in the tenant.
- On the agent user (instance): **Agent 365 / "Frontier for AI Teammates"** (**required**);
  **M365 E5**, **Teams Enterprise**, **M365 Copilot** (recommended for full functionality).

Refs: [Frontier](https://learn.microsoft.com/microsoft-agent-365/frontier),
[Create agent instances](https://learn.microsoft.com/microsoft-agent-365/developer/create-instance#troubleshooting).

## 1. Get the sources

```powershell
git clone https://github.com/<your-org>/agent365-agentframework-samples.git
cd agent365-agentframework-samples/aca/dw
uv venv ; .\.venv\Scripts\Activate.ps1 ; uv pip install -e .
```

## 2. Configure an AI-teammate blueprint

`a365.config.json` — set `aiTeammate: true` (there is **no** `--aiteammate` flag on
`a365 setup blueprint`; the mode comes from this field):

```json
{
  "agentIdentityDisplayName": "AgentFrameworkDWSample Identity",
  "agentBlueprintDisplayName": "AgentFrameworkDWSample Blueprint",
  "agentDescription": "AgentFrameworkDWSample",
  "aiTeammate": true,
  "useBlueprint": false
}
```

Reset `a365.generated.config.json` to `{}` for a **new** blueprint.

## 3. Create the blueprint + permissions

```powershell
a365 setup blueprint --no-endpoint     # creates the AI-teammate Entra app
a365 setup permissions mcp             # McpServers.Mail.All, McpServersMetadata.Read.All
a365 setup permissions bot             # Bot API + Observability + Power Platform
```

Consents encountered (grant as Global Admin): a Graph/Power-Platform admin consent, an Agent
365 Tools consent, an Observability app-role `[y/N]` prompt, and a Messaging-Bot/Observability
/Power-Platform admin consent. A fourth approval happens later in the admin center when the
agent user is enabled.

## 4. Deploy to Azure Container Apps

Same code and Dockerfile as MAF-ACA-OBO. Use `deploy-aca-DW.ps1` (fixed region, reuses the
shared Log Analytics workspace, client secret via `-ClientSecret`). Container env vars are the
**agentic** set (identical to MAF-ACA-OBO step 6): `AUTH_HANDLER_NAME=AGENTIC` +
`AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__*` +
`CONNECTIONS__SERVICE_CONNECTION__*`.

```powershell
.\deploy-aca-DW.ps1 -ClientSecret '<blueprint client secret (cleartext)>'
```

> Container App names must be **lowercase** (Azure constraint). Verify
> `GET https://<fqdn>/api/health` → `200`.

## 5. Register the messaging endpoint

```powershell
a365 setup blueprint --endpoint-only `
  --messaging-endpoint "https://<fqdn>/api/messages"
```

## 6. Publish the AI teammate package

For AI teammates, `a365 publish` really produces a package:

```powershell
a365 publish --aiteammate
```

- Emits `manifest/` (`manifest.json` with an `agenticUserTemplates` block →
  `agenticUserTemplateManifest.json`, icons) and `manifest/manifest.zip`.
- Before packaging, set a real `description` and shorten `name.short`/`name.full` to **≤ 30
  characters** (the CLI rejects longer names).

## 7. Upload, register, activate (admin center — browser)

1. [M365 admin center](https://admin.cloud.microsoft/#/agents/all) → **Agents → All agents →
   Upload custom agent** → select `manifest.zip`.
2. If you **skip** user assignment during upload, the agent lands in **Registry** with State
   **"Not activated"** (it does **not** create a *Requests* entry).
3. Open it → **Activate** → choose *who can create instances* → apply the AI-teammate **policy
   template** (which **assigns the Agent 365 license**) → confirm. State becomes active.

## 8. Create and license instances

- **User (hire) in Teams**: *Apps → find the agent → Add/Create instance* (the user becomes
  Owner). Creation is **asynchronous** (minutes to hours); the **creator** is notified in the
  Teams activity feed when the agent user becomes searchable.
- **Admin in the admin center**: *Registry → `<blueprint>` → Instances → Add instance*.
- **License an instance** (if the policy template didn't): *All agents → Registry →
  `<blueprint>` → Instances → `<instance>` → Licenses → Save* (agent users are **not**
  licensed under *Users → Active users*).

Each instance is an **agent user** with its own mailbox, OneDrive, Teams presence, and
directory entry.

## 9. Tool Gateway & observability

- Work IQ tools work as in MAF-ACA-OBO (the agentic path auto-resolves per-audience tokens).
- Observability: set `ENABLE_A365_OBSERVABILITY_EXPORTER=true`; the exporter token is minted
  per turn via `exchange_token`. Optionally add `APPLICATIONINSIGHTS_CONNECTION_STRING`.

## 10. Verify

Interact with the agent user directly in **Teams** (1:1 chat / @mention), by **email**, or via
**Word/Office comments** (the notification handler processes `EMAIL_NOTIFICATION` and
`WPX_COMMENT`). Confirm the instance **Status = Active** in the admin center.
