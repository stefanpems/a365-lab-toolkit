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

### 0.1 Obtain the "Frontier for Autopilots (No Teams) Trial" licenses (required)

The policy template that activates an autopilot agent (§7) is gated on a license the admin
center recognizes as an **Agent 365** license — namely **"Microsoft 365 Frontier for Autopilots
(No Teams) Trial"**. **Without it you cannot approve/activate the agent.** In a fresh Diamond
tenant it shows **0 of 0** until you enable the trial:

1. **M365 admin center → Copilot → Settings → View all** — verify **Copilot Frontier** is
   enabled (in Diamond tenants it is enabled for **All Users** by default).
2. **M365 admin center → Agent 365 → Overview → `Get Started with AI Teammates`** *(this is the
   easily-missed step)*. On the order page that opens (priced at **$0**), click **Edit** (top
   left), fill in the required fields — only then does **Try now** become enabled.
3. Click **Try now** → **25 "Microsoft 365 Frontier for Autopilots (No Teams) Trial"** licenses
   become available in the tenant.

**Two-license rule (see §7):** in the policy-template wizard you must select **both**
**Microsoft 365 Frontier for Autopilots (No Teams) Trial** *and* **Microsoft Teams Enterprise**
— the Autopilot license is the "(No Teams)" variant, so without a Teams-providing license the
**Next** button stays disabled.

**Diamond tenants pre-assign all E7 and Teams Enterprise to users by default** — free up a few
first so they can be assigned to your autopilot agents. When unassigning, you must **also remove
the dependent licenses in the same operation** (e.g. Calling Plan, Planner + Project, some
Dynamics 365) — see §8 / the license-cleanup note; the removal must happen atomically per user
(the admin-center UI removes one license at a time and hits the dependency conflict).

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
  "agentIdentityDisplayName": "AgentFramework DW Identity",
  "agentBlueprintDisplayName": "AgentFramework DW Sample",
  "agentDescription": "AgentFrameworkDWSample",
  "aiTeammate": true,
  "useBlueprint": false
}
```

Reset `a365.generated.config.json` to `{}` for a **new** blueprint.

> **Keep the blueprint display name ≤ 30 characters and without a redundant "Blueprint"
> suffix.** `a365 publish` (§6) derives the package **`name.short`** from
> `agentBlueprintDisplayName`, and Teams/M365 rejects a `name.short` longer than **30 chars**.
> Note that `a365 setup all --agent-name <name>` auto-derives the blueprint display name as
> `"<name> Blueprint"` — with a 22-char base like `AgentFrameworkDWSample` that yields 32 chars
> and fails packaging. Prefer a short display name such as **`AgentFramework DW Sample`** (24).

## 3. Create the blueprint + permissions

The most reliable, reproducible path — and the one the CLI itself steers you to on a fresh
tenant — is a single **`a365 setup all`** with explicit flags (it does **not** depend on the
`a365.config.json` being picked up):

```powershell
az account set --subscription <TARGET_SUB>
a365 setup all --agent-name AgentFrameworkDWSample --aiteammate --tenant-id <TARGET_TENANT>
```

- **`--aiteammate`** creates an AI-teammate blueprint and *overrides* the `aiTeammate` field in
  `a365.config.json`; for a teammate, `setup all` provisions **blueprint + permissions only**
  (no infrastructure, no endpoint). The granular `a365 setup blueprint` subcommand has **no**
  `--aiteammate` flag, so use `setup all` for teammates.
- **`--agent-name`** derives `AgentIdentityDisplayName="<name> Identity"` and
  `AgentBlueprintDisplayName="<name> Blueprint"`, and resolves `ClientAppId` by looking up the
  **"Agent 365 CLI"** app in your tenant. When provided, no config file is required.
- **`--tenant-id`** forces the tenant. This matters on a **multi-tenant machine**: `a365`
  auto-detects the tenant from `az account show`, and if the active Azure CLI context points at
  a *different* tenant (e.g. a parallel session), the CLI prints *"Detected tenant change …
  current session is tenant `<other>`"*, aborts without creating the blueprint, and removes
  `a365.generated.config.json`. Pinning `az account set --subscription <TARGET_SUB>` in the same
  line **and** passing `--tenant-id` makes the run deterministic.

Expected output: a *"Frontier Preview Program — Tenant enrollment cannot be verified
automatically"* **warning** (non-blocking if the tenant is enrolled), then the blueprint is
created (note the **Blueprint ID** and **service principal ID**), the `access_agent_as_user`
scope is added, and a **client secret** is printed **once** — copy it now (needed at deploy;
retrieve later with `a365 setup blueprint --show-secret` from the same folder/user/machine).

Consents encountered (grant as Global Admin): a Graph/Power-Platform admin consent, an Agent
365 Tools consent, an Observability app-role prompt **`Assign this application permission now?
[y/N]`** (answer **`y`** to grant `Agent365.Observability.OtelWrite`), and a
Messaging-Bot/Observability/Power-Platform admin consent. A further approval happens later in
the admin center when the agent user is enabled.

> **Two transient snags on a fresh/multi-tenant setup:**
> - The in-line **OtelWrite app-role assignment can fail** right after blueprint creation with
>   *"Resource `<blueprint-sp-id>` does not exist …"* — the new blueprint **service principal
>   hasn't propagated** yet. `setup all` continues and lists it under manual steps; re-assign it
>   later (after propagation) with
>   `az rest --method POST --url "https://graph.microsoft.com/v1.0/servicePrincipals/<blueprint-sp-id>/appRoleAssignments" --body '{"principalId":"<blueprint-sp-id>","resourceId":"<observability-sp-id>","appRoleId":"<OtelWrite-role-id>"}'`.
> - `setup all` may prompt **`… - Provision via 'az ad sp create'? [y/N]`** for a missing
>   resource service principal (e.g. `ext_UtilityInsights`). **`az ad sp create` uses the active
>   Azure CLI context and IGNORES `--subscription`.** On a machine whose `az` context can flip to
>   another tenant, answer **`N`** and provision it yourself with a **pinned + verified** target
>   context: `az account set --subscription <TARGET_SUB>`, confirm
>   `az account show --query tenantId` is the target, then
>   `az ad sp create --id <resource-app-id>`.
> - The **delegated admin consent** opens a browser (*"Allow agents created from this blueprint
>   to access data?"*). After **Accept**, the `entra.microsoft.com/TokenAuthorize?admin_consent=True`
>   redirect may show *"Try that again using a different browser"* — this is a **cosmetic
>   Conditional-Access block on the redirect target**, not a consent failure (`admin_consent=True`
>   means the grant went through, same as MAF-ACA-S2S §3.1). The CLI can't detect it and offers
>   **`Add these permissions to the blueprint programmatically? [y/N]`**. That fallback may shell
>   out to `az rest` (active az context), so on a flip-prone box answer **`N`** and instead
>   **verify** the grants with a pinned/verified target context:
>   `az rest --method GET --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?\$filter=clientId eq '<blueprint-sp-id>'"`;
>   add any missing grant programmatically yourself (pinned).
> - Finally `setup all` prompts **`Messaging endpoint URL:`** — **leave it blank** (press Enter).
>   The endpoint is a post-deploy artifact (you only know the FQDN after §4); register it in §5
>   with `a365 setup blueprint --endpoint-only`.

After `setup all` finishes with *"action required"*, the **Setup Summary** lists what to verify
and finish. With the target context **pinned + verified** (`az account set --subscription
<TARGET_SUB>`; confirm `az ad signed-in-user`), complete them:

- **Delegated grants** — verify they landed (the browser consent usually succeeds despite the
  cosmetic block): `az rest --method GET --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?\$filter=clientId eq '<blueprint-sp-id>'"`.
  You should see Graph (Mail/Chat/Sites/Files/Channel), Power Platform (Connectivity), Messaging
  Bot (AgentData), Observability (OtelWrite, delegated), and Agent 365 Tools (Mail) grants.
- **Observability application app-role** (the "S2S app role" the summary flags) — assign it
  (the in-line attempt can fail on SP propagation): POST to
  `…/servicePrincipals/<blueprint-sp-id>/appRoleAssignments` with
  `{"principalId":"<blueprint-sp-id>","resourceId":"<observability-sp-id>","appRoleId":"<OtelWrite-role-id>"}`.
  On Windows, pass the JSON via `--body "@file.json"` (inline `--body '{...}'` fails with
  *"Unable to read JSON request payload"*).
- **`ext_UtilityInsights` SP** — the summary asks to `az ad sp create --id <appId>` and grant
  `Tools.ListInvoke.All`. In a fresh **Frontier-preview** tenant this can fail with
  **`NoBackingApplicationObject`** (the resource app isn't published/propagated in the tenant
  yet). It only backs tool-metadata listing, so it is **non-blocking** for a basic teammate —
  defer it and retry once the resource is available.

## 4. Deploy to Azure Container Apps

Same code and Dockerfile as MAF-ACA-OBO. Use `deploy-aca-DW.ps1` (fixed region, **self-contained
Log Analytics workspace**, client secret via `-ClientSecret`). Container env vars are the
**agentic** set (identical to MAF-ACA-OBO step 6): `AUTH_HANDLER_NAME=AGENTIC` +
`AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__*` +
`CONNECTIONS__SERVICE_CONNECTION__*`.

```powershell
.\deploy-aca-DW.ps1 -ClientSecret '<blueprint client secret (cleartext)>' `
  -Subscription <TARGET_SUB> -AoaiRg <AOAI_RG> -AoaiAcc <AOAI_ACCOUNT>
```

Like MAF-ACA-OBO, the script pins `--subscription` on every `az` call (parallel-session flip
safe), passes the Azure OpenAI **key only if non-empty**, builds with `az acr build --no-logs`
(avoids the cp1252 console crash), and — when `-AoaiRg`/`-AoaiAcc` are given — assigns the
Container App **system-managed identity** the **`Cognitive Services OpenAI User`** role on the
Azure OpenAI account (required when the subscription disables key auth → Entra ID). `agent.py`
builds `AsyncAzureOpenAI` with an `azure_ad_token_provider` and pops an empty
`AZURE_OPENAI_API_KEY` (same Entra ID fix as MAF-ACA-OBO).

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
- `a365 publish` **regenerates `name.short`/`name.full` from `agentBlueprintDisplayName`** and
  prompts *"Open manifest in your default editor now? (Y/n)"* if `name.short` is **> 30 chars**.
  Keep the blueprint display name ≤ 30 (see §2, e.g. `AgentFramework DW Sample`) so this never
  triggers; otherwise answer **Y** and shorten `name.short`/`name.full` before packaging. Also
  give a real `description`.

## 7. Upload, register, activate (admin center — browser)

1. [M365 admin center](https://admin.cloud.microsoft/#/agents/all) → **Agents → All agents →
   Upload custom agent** → select `manifest.zip`. The wizard walks through **Upload agent →
   Publish to users → Apply template → Accept permissions → Review & finish**. The agent shows
   with the manifest **`name.short`** (e.g. *AgentFramework DW Sample*).
2. **Publish to users**: choose who can request instances (e.g. *All users*). **Activate
   (optional)**: choose who can create instances (*None* / *All users* / *Specific*).
3. **Apply template**: pick a **policy template** that carries an **Agent 365 license** (the
   default template has none). Creating a custom template goes **Details** (name; *Agents with
   their own identity* for a teammate) → **Licenses** (Location + pick an **Agent 365 license**)
   → **Security policies** → **Review**.

> **Licensing gate (hard blocker).** *Apply template → Licenses* requires **≥ 1 Agent 365
> license** that the admin center **recognizes as an Agent 365 license** (the wizard says
> *"Agent 365 licenses are automatically selected"* and auto-picks them when present). If you
> see the red *"Policy templates require at least one Agent 365 License"* and **Next stays
> disabled**, the tenant has no recognized Agent 365 license.
>
> **Important:** a **Frontier `MICROSOFT_365_E7_NO_TEAMS`** license bundles the **`AGENT_365`
> service plan** but the admin center does **not** accept E7 (No Teams) as an "Agent 365
> license" for autopilot policy templates — selecting it (even when free) does **not** satisfy
> the gate. The **recognized** Agent 365 license is a distinct SKU shown as
> **"Microsoft 365 Frontier for Autopilots (no Teams)"** (the red banner lists it under *"Agent
> 365 Licenses in your tenant are:"*). If your tenant shows **0 of** that SKU, none are
> provisioned — freeing/reassigning E7 will **not** help; obtain Agent 365 license units via the
> **Frontier preview program** / M365 admin center → **Billing** (the *"Frontier Preview
> Program — enrollment cannot be verified"* warning at `a365 setup` is a sign the entitlement may
> not be granted yet).
>
> **Two-license requirement.** Because the Autopilot license is the **"(no Teams)"** variant,
> selecting it alone raises *"The selected Agent 365 license doesn't include Microsoft Teams.
> Select an additional license that provides Teams access to continue."* — you must **also**
> select a Teams-providing license (**Microsoft Teams Enterprise**). With **both** *Frontier for
> Autopilots (no Teams)* **and** *Teams Enterprise* checked, **Next** enables. The uploaded agent
> stays in **Registry / "Not activated"** until a recognized Agent 365 license exists.

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
