# Setup — Web SPA UI (MSAL, Azure Static Web Apps)

> Single-page web UI that lets signed-in users chat with the **OBO** and **S2S** agents (both
> **ACA** and **Foundry Hosted**). Digital Workers are **not** used here — they are used from
> Teams / Outlook / Office. Reference implementation: the `ui/` folder (`agentframework-ui`
> Static Web App, SPA app registration `agentframework-ui-spa` app id
> `f9fe265c-5fc4-4a4e-8885-600746b05542`).

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
  `agent_session_id`.
- `kind: "foundry-responses"` (S2S FH) → `POST <endpoint>` with the `endpointScope` token only;
  body `{ input, stream:false }`.

## 1. Get the sources

```powershell
git clone https://github.com/<your-org>/agent365-agentframework-samples.git
cd agent365-agentframework-samples/ui
```

## 2. Create the SPA app registration

Register a **single-page application** (SPA platform) in Microsoft Entra and add its
**redirect URI** = the SPA origin (e.g. `https://<swa-host>` and, for local testing,
`http://localhost:<port>`). Record its **app id** → this is `config.js` → `msal.clientId`.

```powershell
$spa = az ad app create --display-name "agentframework-ui-spa" `
  --query appId -o tsv
# Add the SPA redirect URI(s) in the portal (Authentication → SPA), or via Graph.
```

## 3. Grant & consent the delegated permissions (AllPrincipals)

The SPA needs delegated permissions, **admin-consented tenant-wide** so non-admin users don't
hit "Need admin approval". Consent all of these:

| API | Permission | Used for |
| --- | --- | --- |
| Microsoft Graph | `openid` `profile` `offline_access` | sign-in (grant **AllPrincipals** explicitly) |
| Azure Machine Learning Services (`18a66f5f-dbdf-4c17-9dd7-1634712a9cbe`) | `user_impersonation` (`1a7925b5-f871-417a-9b8b-303f9f29fa10`) | `https://ai.azure.com/.default` for Foundry agents |
| Agent 365 Tools (`ea9ffc3e-8a23-4a7d-836d-234d7c7565c1`) | `McpServers.Mail.All` | OBO Mail token |
| ACA OBO blueprint | `McpServers.Mail.All` (via the ACA OBO scope) | ACA OBO `/chat` |
| ACA S2S blueprint | `api://<s2s-app-id>/access_agent_as_user` | ACA S2S `/chat` |

```powershell
az ad app permission add --id <SPA_APPID> --api 18a66f5f-dbdf-4c17-9dd7-1634712a9cbe `
  --api-permissions 1a7925b5-f871-417a-9b8b-303f9f29fa10=Scope
az ad app permission admin-consent --id <SPA_APPID>
```

> `az ad app permission admin-consent` grants the app's **configured** permissions
> AllPrincipals, but the OIDC basics (`openid/profile/offline_access`) can remain admin-only.
> With restricted user-consent this blocks non-admin login — fix it by creating an explicit
> **AllPrincipals** `oauth2PermissionGrant` for Microsoft Graph `openid profile offline_access`.

## 4. Azure RBAC for the Foundry (FH) agents

Entra consent alone is not enough for Foundry Hosted agents — the gateway also checks **Azure
RBAC** on the Foundry account. Assign **Cognitive Services User**
(`a97b65f3-24c7-4388-baec-2e87135dc908`) on each Foundry account to an access **group** and add
your users (see [setup-MAF-FH-OBO.md](setup-MAF-FH-OBO.md) §8). No RBAC is needed for the ACA
agents.

## 5. Configure `config.js`

Set `msal.clientId` (from step 2) and `msal.authority`
(`https://login.microsoftonline.com/<tenant>`), then list your agents. Example entries:

```js
window.APP_CONFIG = {
  msal: { clientId: "<SPA_APPID>", authority: "https://login.microsoftonline.com/<tenant>" },
  agents: [
    { id:"s2s", kind:"aca", name:"… (ACA, S2S)",
      apiBase:"https://<s2s-fqdn>",
      scope:"api://<s2s-app-id>/access_agent_as_user" },
    { id:"obo", kind:"aca", name:"… (ACA, OBO)",
      apiBase:"https://<obo-fqdn>",
      scope:"ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/McpServers.Mail.All" },
    { id:"obo-fh", kind:"foundry-invocations", name:"OBO Foundry Hosted",
      endpoint:"https://<account>.services.ai.azure.com/api/projects/<project>/agents/<obo-agent>/endpoint/protocols/invocations?api-version=v1",
      endpointScope:"https://ai.azure.com/.default",
      mailScope:"ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/McpServers.Mail.All",
      sessionPrefix:"obo" },
    { id:"s2s-fh", kind:"foundry-responses", name:"S2S Foundry Hosted",
      endpoint:"https://<account>.services.ai.azure.com/api/projects/<project>/agents/<s2s-agent>/endpoint/protocols/openai/responses?api-version=v1",
      endpointScope:"https://ai.azure.com/.default" }
  ]
};
```

> The ACA `apiBase` must be reachable cross-origin. In the lab the Foundry gateway and the
> ACA `/chat` accepted browser fetches from the SWA origin (no CORS proxy needed); if you host
> the ACA agents behind a stricter ingress, allow the SWA origin.

## 6. Validate & deploy to Azure Static Web Apps

> **`config.js` is gitignored** (tenant-specific). Create it from the tracked template first:
> `Copy-Item config.js.example config.js`, then set the values above.

Always syntax-check before deploying — a single JS error breaks the whole page (including
login):

```powershell
node --check app.js ; node --check config.js
```

Create the Static Web App (once) and deploy with the SWA CLI:

```powershell
az staticwebapp create -n agentframework-ui -g agentframework-ui -l <region> --sku Free
$tok = az staticwebapp secrets list --name agentframework-ui -g agentframework-ui `
  --query "properties.apiKey" -o tsv
npx -y @azure/static-web-apps-cli deploy "." --deployment-token $tok --env production
```

After the first deploy, add the SWA host (`https://<swa-host>`) as a **SPA redirect URI** on
the app registration (step 2) if you didn't already.

> Editing local files does **not** update the live site — you must **redeploy** each time.

## 7. Verify

Open the SWA URL, click **Sign in** (redirect flow), and exercise each tab:
- **ACA OBO / FH OBO** — a mail prompt sends email from **your** mailbox (use an internal
  recipient).
- **ACA S2S / FH S2S** — a generic prompt returns an LLM answer with the agent's **own**
  identity (no user impersonation).

Multi-user note: the SPA was validated with several non-admin users side by side. Foundry
sessions are per-user (`agent_session_id`) and a single client-side retry handles transient
gateway 5xx.
