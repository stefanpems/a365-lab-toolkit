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

For AI teammates, `a365 publish` really produces a package (the `--agent-name` flag is **required**):

```powershell
a365 publish --aiteammate --agent-name "<agent-name>"
```

- Emits `manifest/` (`manifest.json` with an `agenticUserTemplates` block →
  `agenticUserTemplateManifest.json`, icons) and `manifest/manifest.zip`.
- It **always** prints the manifest fields and prompts *"Open manifest in your default editor now?
  (Y/n)"* — answer **n** if the defaults are fine, then press **Enter** at *"Press Enter when you
  have finished editing…"* to package. Answer **Y** only to edit `name.short`/`name.full`/`description`
  first.
- `a365 publish` **regenerates `name.short`/`name.full` from `agentBlueprintDisplayName`**; keep the
  blueprint display name ≤ 30 chars (see §2) so `name.short` stays valid.

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

### 7.1 Custom policy template + publish flow (verified)

Once the licenses are available (§0.1) you can either **upload the agent** and create/pick a
template inline, or **create a custom policy template first** and select it during upload.

**Create the custom policy template** (*Agents → Settings → Add a new policy template*):
1. **Details** — name (e.g. `Stefanpe Custom Policy Template for AI Teammates`); *What kind of
   agent?* → **Agents with their own identity**.
2. **Licenses** — Location + select **both** *Microsoft 365 Frontier for Autopilots (no Teams)*
   **and** *Microsoft Teams Enterprise*.
3. **Security policies and protections** — leave defaults (Entra / Purview / Defender /
   SharePoint) or adjust.
4. **Review and save**.

> **Gotcha — do NOT add E5 or E7 while *creating* the policy template.** In the policy-template
> **creation wizard** (*Agents → Settings → Add a new policy template → Licenses*), adding an
> **E5** or **E7** license makes the final **Save never complete, with no error** (it just
> hangs). Keep the *creation* wizard to *Frontier for Autopilots (no Teams)* + *Teams
> Enterprise*. To give instances **E5/E7** (mailbox + full O365 services) assign them **in one of
> these two places instead** (both save fine):
> - **On the deployed Agent template → Licenses tab** — the convenient option when **all
>   instances should get the same licenses** (e.g. every instance gets **E5**). Applies to every
>   **new** instance created from the template. *(See §8.)*
> - **On each individual instance** — after the user creates it, when instances need
>   **different** licenses. *(See §8.)*

**Upload + publish the agent** (*All agents → `+ Add agent`*):
1. **Upload agent** — select `manifest.zip` (from `aca/dw/manifest/`).
2. **Publish to users** — *Publish* = who can request instances (*All users*); **Activate
   (optional)** = who can create instances (*None* / *All users* / *Specific*). This selection
   **is** the activation — there is no separate "Activate" button later.
3. **Apply template** — pick your custom template; it shows both licenses with availability
   (e.g. *Frontier for Autopilots 25/25*, *Teams Enterprise 7/50*).
4. **Accept permissions** — usually *"No required permissions"* for this sample.
5. **Review & finish → `Publish`** — this **publishes and activates** the agent per the choices
   in step 2. The agent becomes **Active** in the Registry; then create an instance (§8) or let
   users hire it in Teams.

> **Post-publish is asynchronous.** Right after **Publish** the agent may still show
> **Unavailable** with an **Activate** button. Wait a few minutes and **reopen** the agent side
> panel (close/refresh): the status flips to **Available** on its own and the **Activate** button
> **disappears** — you do **not** click it (activation was already set in *Publish to users*).
> The agent header then shows **Available** + **`+ Add instance`** (Entra agent ID = the
> blueprint app id; Title ID `T_…`).

## 8. Create and license instances

**Three entry points** to create an instance (once the agent is **Available**, §7.1). All open
the same **Create agent** form — *Agent icon*, *Agent name*, *Alias* `<name>@<tenant>.onmicrosoft.com`,
*Agent description*, *Managed by* — then **Create** → *"Your agent is being created. You'll get a
notification when the set up process is complete."* Whoever creates it becomes **Owner**; the
entry points are available to whoever you allowed in *Publish to users → Activate* (e.g. *All
users*).

- **M365 Copilot** — `m365.cloud.microsoft/chat` → **Agent Store** (or *More agents*) → open
  **`AgentFramework DW Sample`** → **`Create instance`**. **Most reliable in this preview:**
  provisioned **immediately** and showed **Active** in the admin-center *Instances* tab right
  away.
- **Teams** — `teams.cloud.microsoft` → **Apps → Built for your org → `AgentFramework DW Sample`
  → `Create instance`**. **Intermittent in this preview:** a first attempt was silently dropped
  (nothing created — see below), a **retry provisioned fine**.
- **Admin center** — Agents → agent side panel → **`+ Add instance`** (or *Registry → `<agent>`
  → Instances → Add instance*).

Verify in **admin center → Agents → `<agent>` → Instances** (Name / Email `<alias>@<tenant>` /
**Status = Active** / Owner). **Quick log-side confirmation** it really provisioned: the
**Autopilot license `consumed` increments by 1** per active instance, and an **agent user**
`<alias>@<tenant>` (enabled) appears in the directory.

> **Admin-center visibility is fast; end-user surfaces lag (badly, in preview).** An instance
> typically shows **Active** in the *Instances* tab **almost immediately** (and already holds its
> license + directory entry), **while still not being discoverable/usable in Teams or M365
> Copilot**. Those surfaces need extra time for the agent user to become **searchable** —
> *Active in MAC ≠ usable in Teams/Copilot yet*. **Observed in the initial preview: still not
> searchable in Teams after ~1 hour; only appeared the next day** (i.e. it can take on the order
> of a **day**). Don't treat a Teams/Copilot no-show as a failure until MAC also disagrees; the
> Teams "Create instance" path is additionally intermittent (§8.1).

> **Not a store app.** Searching the instance name in the M365 Copilot **Agent Store** returns
> *"no matches"* — the instance is an **agent user (a person)**, not a store app. Interact with
> it via **1:1 chat / @mention / email** (`<alias>@<tenant>`) or manage it in the admin center
> *Instances* tab.

Instance creation is **asynchronous** (minutes to hours); the **creator** is notified in the
Teams activity feed when the agent user becomes **searchable** — only then is it usable in Teams
(1:1 chat / @mention), by email, or via Word/Office comments.

> **Assign extra licenses at the Agent template *before* creating instances (recommended).** The
> deployed agent's **Licenses** tab (agent side panel → **Licenses**) lets you add licenses
> **beyond** the policy-template minimum — e.g. **Microsoft 365 E5 or E7 (No Teams)** — so that
> **every new instance** gets a **mailbox + full O365 services** (not just Frontier for
> Autopilots + Teams). Check the boxes and **Save changes**; you get *"License assignment
> updated. New agent instances created from this template will be assigned the licenses you
> selected."* Unlike the policy-template *creation* wizard (§7.1 gotcha), adding E5/E7 **here**
> works. Do this **before** creating instances so they inherit the licenses.

- **License an existing instance** (if not covered above): *All agents → Registry →
  `<blueprint>` → Instances → `<instance>` → Licenses → Save* (agent users are **not**
  licensed under *Users → Active users*). Assign **E5/E7 here** if needed (they can't go in the
  policy template — see the §7.1 Save-hang gotcha).

Each instance is an **agent user** with its own mailbox, OneDrive, Teams presence, and
directory entry.

### 8.1 Expected sequence & provisioning delay (Teams "Create instance")

From Teams the user flow is: **Apps → Built for your org → `<agent>` → `Create instance`** →
**Create agent** form (*Agent name*, *Alias* `<name>@<tenant>.onmicrosoft.com`, *Agent
description*, *Managed by*) → **Create** → green toast *"Your agent is being created. You'll get
a notification when the set up process is complete."*

> **Provisioning to visibility can take a long time — and can stall.** After a successful
> "Create", the agent user (mailbox + Teams + directory entry) is provisioned **asynchronously**.
> It may take **many hours** before the instance appears in **Teams** and in the **A365 Agent
> Registry**. In one run it was **still not visible after 8+ hours** and no agent-user object had
> been created in the directory (verified via Graph: no `AFDW1` user, no users created that day)
> — i.e. the request was effectively **stuck**, not just slow.
>
> **Log-side signals that a request never provisioned** (checked via Graph with `az` token +
> `Invoke-RestMethod`, since `az rest` mangles `()`/`&` in URLs on Windows): the agent user is
> absent from **`/v1.0/users`** *and* **`/beta/users`**, absent from **deletedItems**, there is
> **no `directoryAudits` entry** for it that day, and the **Agent 365 Autopilot license shows
> `0 consumed`** (an active instance consumes **1**). If licenses are still **available** (not a
> quota shortage), the stall is in the **Agent 365 provisioning backend** (preview), not in
> Entra/licensing — there is nothing to fix tenant-side; use the admin-center **Instances /
> Requests** tabs and **delete + recreate**.
>
> **What to check when it doesn't appear:**
> - **A365 admin center → Agents → `<agent>` → Instances** — the instance **status**
>   (*Provisioning* / *Failed* / *Active*).
> - **Agents → Requests** — the instance request may be **Pending** or **Failed** (with an error).
> - The **creator's Teams activity feed** — the completion/error notification lands there.
> - **License availability** — if the template's licenses ran out mid-provision, it stalls.
> - If it stays **Pending** for many hours or shows **Failed**: delete the instance and recreate;
>   a persistent stall is a Frontier-**preview** provisioning issue (retry later).
>
> **Silent-drop case (nothing to delete).** If the **Instances** *and* **Requests** tabs are
> **both empty** after a Teams "Create instance" — no instance, no request, no agent user, and
> the Autopilot license still **`0 consumed`** — the Teams user-hire request was **silently
> dropped** and there is **nothing to delete**. Recreate from the **admin center** instead:
> **Agents → `<agent>` → `+ Add instance`** (admin-driven, more reliable than the Teams path).
> If the admin path *also* creates nothing (license stays `0 consumed`), it is a preview backend
> outage — retry later / raise with the Frontier program.
>
> *Observed:* the very first Teams attempt dropped silently; simply **retrying** (a second Teams
> *Create instance*, or the **M365 Copilot** path) provisioned fine — two instances then existed
> and the Autopilot license went `0 → 2 consumed`. Treat the Teams path as **intermittent** in
> preview and prefer **M365 Copilot** or the **admin center** for reliability.

## 9. Tool Gateway & observability

- Work IQ tools work as in MAF-ACA-OBO (the agentic path auto-resolves per-audience tokens).
- Observability: set `ENABLE_A365_OBSERVABILITY_EXPORTER=true`; the exporter token is minted
  per turn via `exchange_token`. Optionally add `APPLICATIONINSIGHTS_CONNECTION_STRING`.

> **Troubleshooting — Mail send fails with HTTP 401 (`x-ms-agentid=None`).** When you ask an
> instance in Teams to send mail, the agent may loop ("working on it…") and finally report a
> tool error. Query the container's Log Analytics for the `mcp_diag` line:
> `ContainerAppConsoleLogs_CL | where Log_s has 'agent365.svc.cloud.microsoft' or Log_s has 'mcp_diag' | order by TimeGenerated desc`.
> A failing line looks like *`ERROR:mcp_diag:Agent 365 tool call failed — HTTP 401 POST … mcp_MailTools | x-ms-agentid=None | token_claims={… "aud":"ea9ffc3e-…", "scp":"McpServers.Mail.All", "xms_par_app_azp":"<blueprint>", "idtyp":"user"}`*.
> The bearer token is otherwise well-formed (audience = Agent 365 Tools, `McpServers.Mail.All`,
> target tenant, agentic-user). **Ruled out:** the agent user is a real `#microsoft.graph.agentUser`
> with a **mailbox** (`SMTP:<alias>@…`) and full licenses (**Frontier for Autopilots + Teams
> Enterprise + E7**) — so it is **not** a license/mailbox problem.
>
> **Two root causes, both fixed in this sample:**
>
> 1. **Stale/expired tool token (the main one).** `setup_mcp_servers()` used to be memoized with
>    a one-shot `mcp_servers_initialized` flag: the per-audience OAuth token is baked into the MCP
>    tools' **httpx client headers at build time** and the SDK never refreshes it. Because the
>    Container App runs a **single always-on replica** (`--min-replicas 1`), the very first turn's
>    token stays frozen and, once it expires (~60–90 min), **every** Mail call returns 401. Fixed
>    by rebuilding the MCP tools (which re-runs the token exchange) once they exceed a TTL —
>    `self._mcp_ttl_seconds`, default **1800 s**, override with `MCP_TOKEN_TTL_SECONDS` — closing
>    the previous httpx clients first via `tool_service.cleanup()` to avoid leaks. This is exactly
>    a "force token re-acquisition" so a long-lived agent keeps a valid token.
> 2. **Missing `x-ms-agentid` on per-server calls.** The SDK adds `x-ms-agentid` to the *discovery*
>    (gateway) request but **not** to the per-server MCP tool calls, so those arrive with no agent
>    identifier (hence `x-ms-agentid=None`). As a belt-and-suspenders fix, [mcp_diag.py](../aca/dw/mcp_diag.py)
>    now stamps `x-ms-agentid` on outbound Agent 365 MCP requests when absent, deriving the same
>    value the SDK uses for discovery (`xms_par_app_azp` > `appid` > `azp` from the token).
>
> Redeploy the image after these fixes (`az acr build` + `az containerapp update --image`, no
> secret rotation needed) and confirm 100% traffic is on the new revision
> (`az containerapp ingress traffic show`). (The clarifying "loop" is the small `gpt-4.1-mini`
> model being cautious **plus** every Mail call 401-ing so it can never complete — once the token
> is valid the loop stops.)
>
> **Confirmed fixed.** After redeploying, the container logs show `Stamped x-ms-agentid=… on MCP
> tool request`, `MCP call → tool=SendEmailWithAttachments`, `POST …/mcp_MailTools "HTTP/1.1 200
> OK"`, `Function SendEmailWithAttachments succeeded` — **no 401** — and the email is delivered.
> The same token-refresh fix is applied to the **MAF-ACA-OBO** and **MAF-ACA-S2S** samples (same
> latent memoization); redeploy those images too if their containers are long-lived.

> **These lessons generalize to ANY Work IQ MCP** (Calendar, Teams, SharePoint, OneDrive, User,
> Word, Copilot), not just Mail — every Work IQ server shares the same resource
> (`ea9ffc3e-…`) and token lifecycle. When you attach another Work IQ MCP to an agent (e.g. via the
> provisioning wizard's `a365 develop add-mcp-servers`), reuse the same fixes. The full per-variant
> difficulty→fix matrix and the generic vs. Mail-specific breakdown are consolidated in
> [.github/skills/agent365-wizard/references/workiq-mcp-integration.md](../.github/skills/agent365-wizard/references/workiq-mcp-integration.md).

## 10. Verify

Interact with the agent user directly in **Teams** (1:1 chat / @mention), by **email**, or via
**Word/Office comments** (the notification handler processes `EMAIL_NOTIFICATION` and
`WPX_COMMENT`). Confirm the instance **Status = Active** in the admin center.
