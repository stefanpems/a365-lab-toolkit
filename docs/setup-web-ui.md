# Setup — Web SPA UI (MSAL, Azure Static Web Apps)

> Single-page web UI that lets signed-in users chat with the **OBO** and **S2S** agents (both
> **ACA** and **Foundry Hosted**). Digital Workers are **not** used here — they are used from
> Teams / Outlook / Office. Reference implementation: the `ui/` folder (`agentframework-ui`
> Static Web App, SPA app registration `agentframework-ui-spa` app id
> `<WEB_UI_SPA_APP_ID>`).

See [00-introduction.md](00-introduction.md) for concepts. This SPA is vanilla JS + MSAL
Browser (no build step); it renders one vertical tab per entry in `config.js`.

---

## 0. What the SPA does

| File | Role |
| --- | --- |
| `index.html` | Login view + app shell (tabs + panels). Loads MSAL, `config.js`, `app.js`. |
| `config.js` | `window.APP_CONFIG`: MSAL `clientId`/`authority` + the `agents[]` array (one entry per agent). |
| `app.js` | MSAL sign-in (redirect flow), tab/panel UI, and one call function per agent `kind`. |
| `styles.css` | Styling. |
| `staticwebapp.config.json` | SPA navigation fallback to `index.html` + `no-store` cache headers. |

Per-agent call paths in `app.js`:
- `kind: "aca"` → `POST <apiBase>/chat` with one bearer token (`scope`), body `{ message, history }`.
- `kind: "foundry-invocations"` (OBO FH) → `POST <endpoint>` with **two** tokens: `endpointScope`
  in the `Authorization` header + `mailScope` token in body `mail_token`; per-user rotated
  `agent_session_id`; body `{ message, history?, mail_token? }`.
- `kind: "foundry-responses"` (S2S FH) → `POST <endpoint>` with the `endpointScope` token only;
  body `{ input, stream:false }`.
- `kind: "foundry-prompt"` (FD) → project Responses `POST <endpoint>` with `agent_reference`, `input` and
  optional `structured_inputs`.

**Short conversation memory (always on).** Each tab keeps its conversation in the browser, and every
request carries the **last 3 exchanges** (`MEMORY_TURNS` in `app.js`, each message truncated to 4,000
chars) so follow-ups resolve. There is no server-side store:
- **ACA and FH-OBO**: the window goes in `history` (`[{role, content}]`, user/assistant only); the agent
  re-validates and re-caps it.
- **FH-S2S and FD**: `input` becomes a Responses **message list**: the prior exchanges, then the new user
  message. The platform handles it natively.

A failed turn is dropped from the window. Reloading the page starts a fresh conversation.
`index.html` loads `app.js?v=<n>`; bump it whenever `app.js` changes so browsers don't keep a cached copy.

## 1. Get the sources

```powershell
git clone https://github.com/<your-org>/a365-lab-toolkit.git
cd a365-lab-toolkit/ui
```

## 2. Create the SPA app registration

Register a **single-page application** (SPA platform) in Microsoft Entra whose **redirect URIs**
are the SPA origin(s) — the SWA host (created in §6) and, for local testing, `http://localhost:3000`.
Also add a **public-client (Mobile & desktop) loopback redirect** `http://localhost` so native/CLI
tools that sign in with MSAL (e.g. the **Prompts Sender**) can redeem the code server-side — an
SPA-only registration rejects that with `AADSTS9002327` ("SPA client-type … only … cross-origin").
Record its **app id** → this is `config.js` → `msal.clientId`.

> **Do the app-registration steps in the TARGET tenant.** `az ad ...` / `az rest`→Graph ignore
> `--subscription` and act as the **globally active** `az` account. Before each one run
> `az account set --subscription <TARGET_SUB>` and confirm
> `az ad signed-in-user show --query userPrincipalName -o tsv` is the **target-tenant admin**
> (a parallel shell doing `az account set` can silently flip you to the wrong tenant).

```powershell
# 1) Create the app (or patch it if it already exists) and its service principal.
#    --is-fallback-public-client true ("Allow public client flows") lets native/CLI MSAL tools
#    (the Prompts Sender loopback flow) redeem the code WITHOUT a client secret; otherwise the
#    token endpoint returns AADSTS7000218 ("must contain 'client_assertion' or 'client_secret'").
#    It does not affect the browser SPA usage.
$appId = az ad app create --display-name "agentframework-ui-spa" `
  --sign-in-audience AzureADMyOrg --is-fallback-public-client true --query appId -o tsv
az ad sp create --id $appId | Out-Null
$objId = az ad app show --id $appId --query id -o tsv

# 2) Set the redirect URIs. Use a FILE for the body: an inline JSON string is broken by
#    az.cmd on Windows ("Unable to read JSON request payload").
#    - spa.redirectUris          -> the browser SPA origins (SWA host + local test port).
#    - publicClient.redirectUris -> http://localhost (portless) for native/CLI MSAL sign-in
#      (the Prompts Sender loopback flow). Entra allows ANY port on http://localhost for a
#      public client, so no fixed port is needed here. Both platforms can coexist on one app.
$swaHost = "<swa-host>"   # e.g. victorious-bush-xxxx.azurestaticapps.net (known after §6)
$tmp = Join-Path $env:TEMP 'spa_patch.json'
@{
  spa          = @{ redirectUris = @("https://$swaHost", "http://localhost:3000") }
  publicClient = @{ redirectUris = @("http://localhost") }
} | ConvertTo-Json -Depth 5 | Set-Content $tmp -Encoding utf8
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$objId" `
  --headers "Content-Type=application/json" --body "@$tmp"
Remove-Item $tmp
```

> The SWA host is known only **after** you create the Static Web App (§6). Either create the SWA
> first and set both redirect URIs here, or add the SWA host as a second redirect URI after §6.

## 3. Grant & consent the delegated permissions (AllPrincipals)

The SPA needs delegated permissions, **admin-consented tenant-wide** so non-admin users don't
hit "Need admin approval". Which ones depend on the agents you expose:

| API | Permission (scope id) | Used for |
| --- | --- | --- |
| Microsoft Graph (`00000003-0000-0000-c000-000000000000`) | `openid` (`37f7f235-527c-4136-accd-4a02d197296e`) `profile` (`14dad69e-099b-42c9-810b-d002981feec1`) `offline_access` (`7427e0e9-2fba-42fe-b0c0-848c9e6a8182`) | sign-in |
| Azure Machine Learning Services (`18a66f5f-dbdf-4c17-9dd7-1634712a9cbe`) | `user_impersonation` (`1a7925b5-f871-417a-9b8b-303f9f29fa10`) | `https://ai.azure.com/.default` for **Foundry** agents |
| Agent 365 Tools (`ea9ffc3e-8a23-4a7d-836d-234d7c7565c1`) | `McpServers.Mail.All` (`be685e8e-277f-43ec-aff6-087fdca57ca3`) | **OBO** Mail token (ACA + Foundry OBO) |
| ACA S2S blueprint | `api://<s2s-app-id>/access_agent_as_user` | **ACA S2S** `/chat` |
| Custom BYO tool app(s) `ext_<name>Anon` / `ext_<name>Auth` | `Tools.ListInvoke.All` (per BYO audience) | **OBO** custom MCP tool calls (see §6c) |

> **OBO + custom MCP: pre-consent the BYO tool scopes (§6c).** In the browser the SPA can obtain
> these `Tools.ListInvoke.All` tokens via a one-time **incremental consent** at first use, but a
> **headless caller** (the **Prompts Sender** CLI, which reuses the SPA client for silent tokens)
> cannot consent interactively — `acquire_token_silent` returns `null` and the tool call fails. So
> when an OBO agent exposes a custom MCP, **grant + admin-consent the SPA for each BYO audience** per
> §6c, exactly like the S2S scope in §6b.

> **The resource service principals must exist in the tenant.** Agent 365 Tools
> (`ea9ffc3e-…`) is created by `a365 setup` during agent onboarding; if
> `az ad sp show --id ea9ffc3e-8a23-4a7d-836d-234d7c7565c1` returns nothing, run the OBO agent
> setup first (or `az ad sp create --id ea9ffc3e-8a23-4a7d-836d-234d7c7565c1` as a tenant admin).
> The scope ids above are stable, but you can re-read one with
> `az ad sp show --id <api> --query "oauth2PermissionScopes[?value=='<name>'].id" -o tsv`.

```powershell
$graph = "00000003-0000-0000-c000-000000000000"
$tools = "ea9ffc3e-8a23-4a7d-836d-234d7c7565c1"
# Sign-in (OIDC)
az ad app permission add --id $appId --api $graph --api-permissions `
  37f7f235-527c-4136-accd-4a02d197296e=Scope `
  14dad69e-099b-42c9-810b-d002981feec1=Scope `
  7427e0e9-2fba-42fe-b0c0-848c9e6a8182=Scope
# OBO Mail (only if you expose an OBO agent)
az ad app permission add --id $appId --api $tools --api-permissions `
  be685e8e-277f-43ec-aff6-087fdca57ca3=Scope
# ACA S2S (only if you expose the S2S agent) — use the S2S blueprint app id + its scope id:
# az ad app permission add --id $appId --api <s2s-app-id> --api-permissions <access_agent_as_user-id>=Scope

az ad app permission admin-consent --id $appId    # run as a TARGET-tenant admin
```

> If `admin-consent` fails with *"can only be performed by an administrator"* even though you
> are one, your active `az` identity has flipped (see §2 warning) — re-pin with
> `az account set --subscription <TARGET>` and re-verify `az ad signed-in-user show`.
>
> `admin-consent` grants the app's **configured** permissions AllPrincipals, but the OIDC basics
> can remain admin-only under restricted user-consent — if non-admin login still shows
> "Need admin approval", create an explicit **AllPrincipals** `oauth2PermissionGrant` for
> Microsoft Graph `openid profile offline_access`.

## 4. Azure RBAC for the Foundry (FH / FD) agents

Entra consent alone is not enough for Foundry Hosted **and Foundry declarative (prompt)** agents —
the gateway also checks **Azure RBAC** on the Foundry account. Assign **Cognitive Services User**
(`a97b65f3-24c7-4388-baec-2e87135dc908`) on each Foundry account to an access **group** and add
your users (see [setup-MAF-FH-OBO.md](setup-MAF-FH-OBO.md) §8). Multiple users/groups are fine — a
**group** is recommended (grant once, manage membership). **No RBAC is needed for the ACA agents.**

## 5. Configure `config.js`

Set `msal.clientId` (from step 2) and `msal.authority`
(`https://login.microsoftonline.com/<tenant>`), then list your agents. Example entries:

Use a **consistent tab name** for every agent: `<framework>-<hosting>-<authN>`, where `<framework>`
is the agent framework (`MAF` today), `<hosting>` is one of `ACA` (Azure Container Apps), `FH`
(Foundry Hosted) or `FD` (Foundry Declarative), and `<authN>` is one of `OBO`, `S2S` or `DW`. So the
tabs read `MAF-ACA-OBO`, `MAF-ACA-S2S`, `MAF-FH-OBO`, `MAF-FH-S2S`, `MAF-FD-OBO`, `MAF-FD-S2S`, … — the
per-agent details go in the `description` field. (The Lab Builder names its tabs
`<prefix>-<framework>-<hosting>-<identity>`, e.g. `contoso-MAF-ACA-OBO`.)

```js
window.APP_CONFIG = {
  msal: { clientId: "<SPA_APPID>", authority: "https://login.microsoftonline.com/<tenant>" },
  agents: [
    { id:"s2s", kind:"aca", name:"MAF-ACA-S2S",
      apiBase:"https://<s2s-fqdn>",
      scope:"api://<s2s-app-id>/access_agent_as_user" },
    { id:"obo", kind:"aca", name:"MAF-ACA-OBO",
      apiBase:"https://<obo-fqdn>",
      scope:"ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/McpServers.Mail.All" },
    { id:"obo-fh", kind:"foundry-invocations", name:"MAF-FH-OBO",
      endpoint:"https://<account>.services.ai.azure.com/api/projects/<project>/agents/<obo-agent>/endpoint/protocols/invocations?api-version=v1",
      endpointScope:"https://ai.azure.com/.default",
      mailScope:"ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/McpServers.Mail.All",
      sessionPrefix:"obo" },
    { id:"s2s-fh", kind:"foundry-responses", name:"MAF-FH-S2S",
      endpoint:"https://<account>.services.ai.azure.com/api/projects/<project>/agents/<s2s-agent>/endpoint/protocols/openai/responses?api-version=v1",
      endpointScope:"https://ai.azure.com/.default" }
  ]
};
```

> The ACA `apiBase` must be reachable cross-origin. In the lab the Foundry gateway and the
> ACA `/chat` accepted browser fetches from the SWA origin (no CORS proxy needed); if you host
> the ACA agents behind a stricter ingress, allow the SWA origin.

> **Sidebar reveal (`enabled`).** Each agent entry may carry an `enabled` flag: while `enabled: false`
> its **left-sidebar tab is hidden**, and it appears only once you set `enabled: true`. This lets the UI
> reveal each agent as it goes live. The Lab Builder scaffolds **every tab with `enabled: false`** and
> flips it to `true` in the same `config.js` edit that fills the agent's FQDN/endpoint after it deploys.
> An entry **without** the flag is treated as live (shown), so a hand-written config stays visible.
> When no tab is enabled yet, the shell shows a short "agents appear as they are deployed" placeholder.

## 6. Validate & deploy to Azure Static Web Apps

> **`config.js` is gitignored** (tenant-specific). Create it from the tracked template first:
> `Copy-Item config.js.example config.js`, then set the values above.

Always syntax-check before deploying — a single JS error breaks the whole page (including
login):

```powershell
node --check app.js ; node --check config.js
```

Create the Static Web App (once), then deploy the content. **Deploy with the `StaticSitesClient.exe`
uploader directly** — on Windows the `npx @azure/static-web-apps-cli deploy` wrapper reliably exits 1
(it spawns this same uploader but fails to propagate the result), so use the uploader as the primary path:

```powershell
az staticwebapp create -n agentframework-ui -g agentframework-ui -l <region> --sku Free --tags a365component=web-ui
$tok = az staticwebapp secrets list -n agentframework-ui -g agentframework-ui --query properties.apiKey -o tsv
# The uploader is downloaded under %USERPROFILE%\.swa\deploy\<hash>\ (the path is printed on first use).
$c = "$env:USERPROFILE\.swa\deploy\<hash>\StaticSitesClient.exe"
& $c upload --app "<repo-root>\generated\<prefix>\<prefix>-ui" --apiToken $tok --skipAppBuild true
```

Run it **from the repo root** and pass an **absolute `--app` path** to the UI folder. ⛔ Do **not** run it
from inside the UI folder with `--app "."` — the uploader rejects an artifact folder equal to the current
directory (*"current directory cannot be identical to the artifact folder"*). It prints
`Deployment Complete :)` and the site URL.

> **Durable component tag:** the `--tags a365component=web-ui` on `az staticwebapp create` marks this SWA
> as a web UI instance of this solution, so the Lab Builder can list it when a later lab chooses *Attach
> to an existing web UI*, and the *Web UI & MCP Remover* can find standalone instances. Ownership by one
> lab is the separate `a365lab=<prefix>` tag; a **standalone** UI (created by the *Web UI Creator*) has
> `a365component` but **no** `a365lab`, so the Lab Cleaner never deletes it — it only deregisters the
> lab's tabs. If you created the SWA without the tag, add it later:
> `az tag update --resource-id $(az staticwebapp show -n <swa> -g <rg> --query id -o tsv) --operation Merge --tags a365component=web-ui`
> (or run `.github/skills/agent365-wizard/scripts/Set-ComponentTags.ps1 -SwaName <swa> -Subscription <sub> -TenantId <tenant>`).

> **Region:** SWA **Free** is only offered in a few regions (`eastus2`, `centralus`, `eastasia`,
> `westeurope`, `westus2`) — not every Azure region (e.g. `swedencentral` is unavailable) — and the SPA is
> served from a **global CDN**, so the SWA region need not match the lab region. `westeurope` has returned
> *"region is currently not accepting new customers"* in the lab; **`eastus2`** is validated. If the lab
> region is not an SWA region, the wizard **asks** which allowed region to use for the Free SWA.

After the first deploy, add the SWA host (`https://<swa-host>`) as a **SPA redirect URI** on
the app registration (step 2) if you didn't already.

> **Editing local files does **not** update the live site — you must **redeploy** each time.** The
> redeploy is a **static file re-upload with NO build/compilation** (`--skipAppBuild true`; the SPA has
> no build step). When you integrate a new agent, the only file that changes is `config.js`, so the
> redeploy just re-uploads the regenerated `config.js` plus the unchanged static assets. Integrating a
> live agent means, in that same `config.js` edit: fill its FQDN/endpoint **and** set its `enabled: true`
> to unhide its left-sidebar tab, then redeploy.

### 6a. Enable CORS on the ACA agents (`UI_ALLOWED_ORIGINS`) — required

The ACA `/chat` endpoint only emits `Access-Control-Allow-Origin` for origins listed in the
container env var **`UI_ALLOWED_ORIGINS`** (comma-separated; empty by default — so the browser
**blocks** the cross-origin `POST` and the tab silently fails). The SWA host is known only
**after** the SWA is created, so this is a **post-deploy** step on each ACA agent you expose:

```powershell
az containerapp update -n agentframework-obo-sample -g agentframework-OBO-rg-pl `
  --subscription <TARGET_SUB_ID> --set-env-vars "UI_ALLOWED_ORIGINS=https://<swa-host>"
```

Verify the preflight returns the header (expect HTTP 204 with `Access-Control-Allow-Origin`):

```powershell
Invoke-WebRequest -Method Options -UseBasicParsing `
  -Uri "https://<obo-fqdn>/chat" `
  -Headers @{ Origin="https://<swa-host>"; 'Access-Control-Request-Method'='POST' } |
  Select-Object -ExpandProperty Headers
```

> **Shared `az` context / parallel sessions — `az ad` ignores `--subscription`.** All the
> app-registration steps (`az ad app ...`, `az ad sp ...`, `az ad app permission admin-consent`,
> `az rest` → Graph) act as the **globally active** `az` account, **not** the one implied by
> `--subscription`. If another shell (or a parallel automation) runs `az account set`, your
> Graph calls can silently execute against the **wrong tenant** (e.g. creating the SPA app
> registration in a corporate tenant, or failing admin-consent with *"can only be performed by
> an administrator"*). **Before every `az ad`/Graph command**, run
> `az account set --subscription <TARGET>` **and verify**
> `az ad signed-in-user show --query userPrincipalName -o tsv` is the **target tenant admin**;
> abort if it isn't.

### 6b. S2S only — `UI_AUDIENCE` + the `access_agent_as_user` scope

The **ACA S2S** agent's `/chat` validates the caller's Entra token **audience** against the
container env var **`UI_AUDIENCE`** (= the **S2S blueprint app id**). The SPA acquires a token
for `api://<s2s-app-id>/access_agent_as_user`, so its `aud` is the blueprint app id; set:

```powershell
az containerapp update -n agentframework-s2s-sample -g agentframework-S2S-rg-pl `
  --subscription <TARGET_SUB_ID> --set-env-vars "UI_AUDIENCE=<s2s-blueprint-app-id>"
```

For this to work the **blueprint app must expose** the `access_agent_as_user` delegated scope
under identifier URI `api://<s2s-app-id>` (recent `a365 setup all --authmode s2s` adds it —
verify with `az ad app show --id <s2s-app-id> --query "api.oauth2PermissionScopes[].value"`),
and the **SPA must be granted + admin-consented** for it:

```powershell
$scopeId = az ad app show --id <s2s-app-id> --query "api.oauth2PermissionScopes[?value=='access_agent_as_user'].id | [0]" -o tsv
az ad app permission add --id <SPA_APPID> --api <s2s-app-id> --api-permissions "$scopeId=Scope"
az ad app permission admin-consent --id <SPA_APPID>
```

> **The OBO agent does NOT need `UI_AUDIENCE`.** Its SPA token targets the **Mail** resource
> (`ea9ffc3e-…/McpServers.Mail.All`), so its `aud` is the Mail MCP, not the agent — leave
> `UI_AUDIENCE` unset for OBO (the `/chat` still validates signature, issuer and expiry).

### 6c. OBO + custom MCP only — grant & admin-consent the SPA for each BYO tool scope

When an OBO agent exposes a custom (BYO) MCP, `config.js` gives that tab a `customScopes` map
(`{ <BYO-audience>: "<BYO-audience>/Tools.ListInvoke.All" }`), and both the browser SPA and the
**Prompts Sender** CLI mint a delegated token per audience. The browser can consent to a new scope
at runtime; the CLI's **silent** flow cannot — so the SPA must be **granted + admin-consented** for
`Tools.ListInvoke.All` on **each** `ext_<name>Anon` / `ext_<name>Auth` **BYO** app (not the proxy or
resource apps). The BYO app ids are the `customScopes` audiences in `config.js` (also in the custom
MCP's `ToolingManifest.json`). Run per BYO audience:

```powershell
$byo = "<byo-audience-app-id>"   # e.g. an ext_<name>Anon / ext_<name>Auth BYO app id
$scopeId = az ad sp show --id $byo --query "oauth2PermissionScopes[?value=='Tools.ListInvoke.All'].id | [0]" -o tsv
az ad app permission add --id <SPA_APPID> --api $byo --api-permissions "$scopeId=Scope"
az ad app permission admin-consent --id <SPA_APPID>    # run as a TARGET-tenant admin
```

> This is the same privilege the browser SPA already requests interactively — pre-consenting just
> moves it to setup, removing the first-use prompt **and** unblocking the headless CLI. It does not
> grant the SPA anything the user couldn't already consent to at runtime.

## 7. Verify

Open the SWA URL, click **Sign in** (redirect flow), and exercise each tab:
- **ACA OBO / FH OBO** — a mail prompt sends email from **your** mailbox (use an internal
  recipient).
- **ACA S2S / FH S2S** — a generic prompt returns an LLM answer with the agent's **own**
  identity (no user impersonation).

> **First use of a newly-added agent tab — a one-time incremental consent is EXPECTED.** This
> happens for the **ACA S2S** tab and for every **Foundry** tab (Hosted / Declarative) the first
> time a user exercises it, because the SPA now requests a **new scope** not yet consented for
> that user (`api://<s2s-app-id>/access_agent_as_user` for S2S; `https://ai.azure.com/.default`
> — Azure ML `user_impersonation` — for the Foundry agents; plus the Mail scope for OBO). Entra
> shows a **two-app** consent (even though you admin-consented the SPA earlier — the second app
> is the downstream API/blueprint):
> 1. **"Permissions requested (1 of 2 apps)"** — *agentframework-ui-spa* (lists the aggregated
>    new scopes: *View basic profile*, *Maintain access*, *Mail MCP Server All*, *Access agent
>    on behalf of user*, *user_impersonation*) → click **Next**.
> 2. **"Permissions requested (2 of 2 apps)"** — the downstream app/blueprint (shown as
>    **unverified** — normal, it is your own app) → as an admin tick **"Consent on behalf of
>    your organization"** → **Accept**.
>
> After this once, subsequent calls do not prompt. If the redirect lands on a Conditional-Access
> *"Try that again using a different browser"* page, the consent was still recorded (see the
> ACA-S2S guide §3.1). The **Foundry (Hosted/Declarative) tabs** trigger the same flow on first
> use — accept it once.

> **The agent answers in the language of your prompt.** This is normal LLM behavior: e.g.
> typing the Scandinavian greeting `Hej!` yields a Swedish reply
> (*"Hej! Hur kan jag hjälpa dig idag?"*). Write in English/Italian to get English/Italian back.
> A successful reply here confirms the S2S agent works end-to-end (LLM via its own managed
> identity).

Multi-user note: the SPA was validated with several non-admin users side by side. Foundry
sessions are per-user (`agent_session_id`) and a single client-side retry handles transient
gateway 5xx.
