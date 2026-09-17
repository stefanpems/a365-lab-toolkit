# Sending prompts to MCS (Copilot Studio) agents — feasibility & design

**Question.** Can the Prompts Sender exercise the Microsoft Copilot Studio sample agents (MCS-OH / MCS-NH)
**programmatically**, without CDP / browser automation?

**Verdict: YES.** There is an official, documented, non-browser path — the **Microsoft 365 Agents SDK
Copilot Studio client** over the Power Platform **Direct-to-Engine** API. It fits the Prompts Sender's
existing MSAL delegated-token model, so it is an additive extension, not a rewrite. A working prototype is
in [scripts/send_prompts_mcs.py](../scripts/send_prompts_mcs.py). This document records the design,
prerequisites and open items so the path can be finished and validated against a live lab.

## Why the base engine can't do it as-is
The base engine ([scripts/send_prompts.py](../scripts/send_prompts.py)) posts plain HTTP to the six
SPA-callable OBO/S2S agents listed in a web UI's `config.js`. MCS agents are **not** HTTP/SPA agents, are
**absent** from `config.js`, and are reached over a different protocol (Direct-to-Engine) with a different
token audience (Power Platform API). Hence a separate module + a separate manifest, reusing the shared
prompt library, plan builder and basic-check helpers.

## Chosen approach (documented, non-CDP)
- **SDK:** `microsoft-agents-copilotstudio-client` (PyPI) + `microsoft-agents-activity` (transitive).
  Classes used: `ConnectionSettings`, `CopilotClient`, `PowerPlatformCloud`, `AgentType`,
  `PowerPlatformEnvironment`.
- **Token (delegated user):** minted with **MSAL** (`PublicClientApplication`) against the **target**
  tenant, scope `https://api.powerplatform.com/.default` (confirmed via `CopilotClient.scope_from_cloud`).
  Same one-time interactive sign-in + silent-refresh + cache pattern the base engine already uses.
- **Call flow (async):** `CopilotClient(settings, token)` -> `start_conversation()` (capture the
  `conversation.id` from the first activity that carries one) -> `ask_question(prompt, conversation_id)`
  -> collect `activity.text` for every activity whose `type == "message"`.
- **Addressing:** `ConnectionSettings(environment_id=<CS env GUID>, agent_identifier=<bot schema name>)`;
  a `direct_connect_url` (Channels -> Web app connection string) may be supplied instead and takes
  precedence.

### Verified against the live SDK (this branch)
- Package installs on Python 3.14; imports OK.
- `ConnectionSettings.__init__(environment_id, agent_identifier, cloud, copilot_agent_type, ...,
  direct_connect_url, ...)`.
- `CopilotClient(settings, token)`; `start_conversation(emit_start_conversation_event=True)`;
  `ask_question(question, conversation_id=None)` — both return `AsyncIterable[Activity]`.
- `Activity` exposes `type`, `text`, `conversation` (`conversation.id`).
- `scope_from_cloud(PROD)` -> `https://api.powerplatform.com/.default`.
- `PowerPlatformEnvironment.get_copilot_studio_connection_url(...)` yields the documented endpoint:
  `https://{env}.environment.api.powerplatform.com/copilotstudio/dataverse-backed/authenticated/bots/{schema}/conversations?api-version=2022-03-01-preview`.

## Prerequisites (must be set up before a live run)
1. **App registration (public client) in the TARGET tenant** with delegated permission
   **Power Platform API -> Copilot Studio -> `Copilot Studio.Copilots.Invoke`** + **admin consent**.
   - The lab's existing SPA client is **not** preauthorized for the Power Platform API, so this is a new
     (or augmented) app. It is scriptable with `az ad app`.
2. **Published MCS agent** (the Lab Builder already publishes them).
3. **Per-agent metadata:** the Copilot Studio **environment GUID** and the bot **schema name**
   (`agent_identifier`). The schema name is unique per agent because the Lab Builder scaffolds MCS with
   `-IsolateSchemaName`; read it from **Copilot Studio -> Settings -> Advanced -> Metadata -> Schema
   name**, or from Dataverse `bots.SchemaName`, or (best) have the scaffolder emit it into the plan.
4. **A user in the target tenant** to sign in interactively once (delegated flow; no password stored).

## Manifest (the MCS analogue of `config.js`)
```json
{
  "msal":   { "clientId": "<public-client-app-id>",
              "authority": "https://login.microsoftonline.com/<target-tenant-id>" },
  "scope":  "https://api.powerplatform.com/.default",
  "agents": [
    { "id": "mcs-oh", "name": "<lab>-MCS-OH", "harness": "OH",
      "environmentId": "<cs-env-guid>", "agentIdentifier": "<bot schema name>",
      "directConnectUrl": null }
  ]
}
```

## Prototype commands
```
python send_prompts_mcs.py login  --manifest <mcs.json> [--user <upn>]     # one-time interactive sign-in
python send_prompts_mcs.py agents --manifest <mcs.json>                    # list MCS agents
python send_prompts_mcs.py url    --manifest <mcs.json> --agents mcs-oh    # print endpoint (offline)
python send_prompts_mcs.py send   --manifest <mcs.json> --agents mcs-oh --hello 1 --out r.json [--dry-run]
```
`agents`, `url` and `send --dry-run` need **no** credentials and are validated on this branch.

## Coherence of categories for MCS
- **`hello`** — always coherent.
- **`MCP Mail access`** — coherent only if the MCS agent has the **Mail** MCP tool wired (works on OH and
  NH per the copilot-studio skill).
- **`Custom MCP Anon/Auth`** — coherent only if the custom `ext_` tool is wired; today **OH-only** and
  experimental (Anon likely works; Auth token-forwarding unverified). The engine should skip these for an
  MCS agent that doesn't declare the tool (mirror the base engine's coherence skips).

## Open items before this is production-ready
1. **Live validation** of `login` + `send` against a real MCS-OH (and MCS-NH) agent — confirm the greeting
   returns text and the basic/semantic check passes.
2. **App-registration automation** — a small script (or reuse of `New-McsMcpClientApp.ps1` patterns) to
   create the public client + `Copilots.Invoke` delegated permission + admin consent in the target tenant.
3. **Manifest generation** — have the Copilot Studio scaffolder emit `environmentId` + `agentIdentifier`
   per MCS agent so the manifest is produced automatically (like `config.js` for the SPA agents).
4. **Per-agent tool declaration** in the manifest to drive category coherence (Mail / anon / auth).
5. **Token audience nuance** — `.default` requests the consented Power Platform set; if a tenant needs the
   explicit `Copilots.Invoke` scope string, expose it as a manifest override.

## Alternative (only if the SDK path is blocked)
**Direct Line** (`publication-connect-bot-to-custom-application`) is the documented fallback and is also
non-CDP, but Microsoft recommends it only when the Agents SDK doesn't cover the scenario (e.g. service
principal tokens). For delegated-user smoke tests the Agents SDK client is the better fit.

## Sources (Microsoft Learn)
- Integrate with web or native apps using the M365 Agents SDK:
  `learn.microsoft.com/microsoft-copilot-studio/publication-integrate-web-or-native-app-m365-agents-sdk`
- Python sample: `github.com/microsoft/Agents/tree/main/samples/python/copilotstudio-client`
- Python API: `CopilotClient`, `ConnectionSettings`, `PowerPlatformEnvironment` (agent-sdk-python-latest)
- Connect code app to Copilot Studio (endpoint format):
  `learn.microsoft.com/power-apps/developer/code-apps/how-to/connect-to-copilot-studio`
