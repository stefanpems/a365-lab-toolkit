# Prompts Sender — skill

Operational knowledge for the **Prompts Sender** agent. It sends batches of prompts to the
SPA-callable Lab Builder agents (the six OBO/S2S agents exposed in a lab's web UI) **and to Copilot
Studio MCS-OH agents** (via a separate discovery step, no web UI), and checks each response against a
success condition. It runs **interactively** (asks the operator) or **unattended** (all inputs on the
command line — for GitHub Copilot CLI launched by Windows Task Scheduler).

## Components (this skill folder)
- `references/prompt-library.md` — the random source of prompts. Four categories, four prompts each.
  Every prompt ends with a `(success condition)`; the sender **strips** that parenthesis before sending
  and uses it only to judge the response.
- `scripts/send_prompts.py` — the **web-UI engine**: reads a lab's `ui/config.js`, authenticates via MSAL
  (the SPA public client), picks random prompts, sends them, records responses, and writes JSON results.
- `scripts/send_prompts_mcs.py` — the **MCS-OH engine**: builds a manifest from a live Copilot Studio
  environment (`discover`), mints a Power Platform delegated token, and sends prompts over the
  Direct-to-Engine API (no browser automation). Shares this skill's prompt library + report model.
- `scripts/requirements.txt` — `msal`, `requests` (web-UI engine).
- `scripts/requirements-mcs.txt` — `msal`, `microsoft-agents-copilotstudio-client` (MCS-OH engine).
- `references/mcs-feasibility.md` — the MCS-OH design, prerequisites and live-validation record.

## Prompt categories → agents
| Category | Meaning | Sensible agents |
|---|---|---|
| `hello` | generic greeting | any agent |
| `MCP Mail access` | reads the user's mailbox (delegated Mail) | OBO agents (`obo`, `obo-fh`, `obo-fd`) |
| `Custom MCP Anon access` | calls the anon BYO MCP (`ext_<prefix>Anon`) | OBO agents with the custom MCP attached |
| `Custom MCP Auth access` | calls the auth BYO MCP (`ext_<prefix>Auth`) | OBO agents with the custom MCP attached |

**Coherence rule (hard).** OBO agents (`obo`, `obo-fh`, `obo-fd`) support all four categories; S2S
agents (`s2s`, `s2s-fh`, `s2s-fd`) expose no delegated Mail nor custom BYO MCP, so **only `hello` is
coherent for them**. Never send `MCP Mail access` / `Custom MCP Anon access` / `Custom MCP Auth access`
to an S2S agent — warning is not enough. The engine enforces this too: an incoherent agent×category
pair is **skipped** (reported `N/A`, not `FAIL`) and never sent.

## Authentication (must read)
- The engine mints **delegated user tokens** with MSAL using the **SPA client id** in `config.js`
  (`msal.clientId`). That client is tenant-admin-consented for Mail, the S2S API, Foundry and the custom
  BYO tool scopes. **Azure CLI cannot mint** the Mail/S2S/custom tokens (first-party preauthorization /
  missing consent), so MSAL via the SPA client is the only working path.
- One-time sign-in per user: `python send_prompts.py login --config <config.js>` opens a browser. Tokens
  are cached (`scripts/token_cache.json`, git-ignored) and refreshed silently afterwards. Device-code
  flow may be blocked by tenant policy — prefer the interactive browser flow.
- **Multi-context (future v2):** the cache holds multiple accounts; `--user <upn>` selects which account
  mints tokens. Seeding a new user still needs one interactive sign-in for that user. The engine and
  agent are already parameterised for this; v2 will iterate a set of users in one run.

## Interactive flow
1. **Runtime-model gate** (optional, consistent with the other lab agents): show the active chat model,
   let the operator confirm/continue.
2. **Explain the two surfaces + what is supported (before locating any config).** The sender reaches two
   surfaces: **web-UI agents** (need a web UI's `config.js` as the manifest — `endpoint`/`apiBase`, OAuth
   `scope`s, MSAL **SPA `clientId`**; Azure CLI cannot mint the Mail/S2S/custom tokens) and **MCS-OH
   agents** (a separate discovery step, no web UI). State the coverage:
   - **Web-UI (supported):** the 6 SPA-callable agents — ACA-OBO (`obo`), ACA-S2S (`s2s`), FH-OBO
     (`obo-fh`), FH-S2S (`s2s-fh`), FD-OBO (`obo-fd`), FD-S2S (`s2s-fd`).
   - **Copilot Studio (supported — MCS-OH only):** reached over the Power Platform **Direct-to-Engine**
     API via the Microsoft 365 Agents SDK Copilot Studio client (delegated token, scope
     `https://api.powerplatform.com/.default`, **no** browser automation). Handled by the separate
     **MCS-OH branch** (see "MCS-OH (Copilot Studio) path" below). **MCS-NH (GitHub Copilot harness) is
     NOT supported** by this API and is auto-skipped (`N/A`).
   - **Not supported — Digital Workers (ACA-DW, FH-DW):** no synchronous HTTP endpoint, absent from
     `config.js`, triggered by **email** to their mailbox (a future email-trigger mode could add them).
   Then ask the **surface gate** — web-UI agents, MCS-OH agents, or both — and run the matching branch.
3. **Pick the web UI (web-UI branch).** Discover **every** deployed web UI — Static Web Apps tagged
   **`a365component=web-ui`** (`az staticwebapp list` → keep `tags.a365component == 'web-ui'`),
   **regardless of `a365lab`**. Both **lab-owned** UIs (`a365lab=<prefix>`) and **standalone/shared** UIs
   (no `a365lab`) are valid prompt targets — never filter one out; the standalone-vs-lab distinction is a
   Cleaner/Remover concept, not a prompt-target filter. Present each with name + default hostname + owner
   (`a365lab=<prefix>` or `standalone`), let the operator pick one, and fetch that SWA's **LIVE**
   `config.js` from its origin (the on-disk `generated/<prefix>/<prefix>-ui/config.js` can be stale, so
   prefer LIVE; fall back to on-disk only if the origin is unreachable). Then run
   `python send_prompts.py agents --config <config.js>` to list the agent ids.
4. **Which agents** — multi-select from the listed ids (`obo`, `s2s`, `obo-fh`, `s2s-fh`, `obo-fd`,
   `s2s-fd`).
5. **How many prompts per category** — always ask the `hello` count. Ask the `MCP Mail access` /
   `Custom MCP Anon access` / `Custom MCP Auth access` counts **only if at least one OBO agent is
   selected**, and apply those three categories **only to the OBO agents**. When the selection mixes S2S
   and tool categories, **split the run into separate `send` invocations** — `hello` to all selected
   agents, and the tool categories to the OBO agents only — never a single combined `send`.
6. **Ensure sign-in** — if there is no cached account, run `login` first (browser).
7. **Send** — run `send_prompts.py send` with the chosen ids/counts and `--out results.json`.
8. **Evaluate + report** — read `results.json`; for each entry judge whether `condition` is satisfied in
   `reply` (semantic, case-insensitive) and present a **PASS / FAIL / N/A** table (entries the engine
   marked `skipped:true` are `N/A`, i.e. not applicable, and must not be counted as failures) plus an
   overall count. The engine's `basic_pass` is a first-pass safety net (HTTP 2xx + non-empty + no error
   markers) computed over the **sent** prompts only; the agent's semantic judgement is authoritative.

## Unattended flow (GitHub Copilot CLI + Windows Task Scheduler)
All inputs come from the command line — the agent must not prompt. Example the scheduled task runs:

```
python .github/skills/prompts-sender/scripts/send_prompts.py send \
  --config generated/a09091/a09091-ui/config.js \
  --agents obo,obo-fh,obo-fd \
  --hello 1 --mail 1 --anon 1 --auth 1 \
  --out prompts-run.json
```

The process exit code is `0` only if every **sent** prompt passed the basic check; incoherent
agent×category pairs are **skipped** (never sent, reported `skipped:true`) and do not affect the exit
code. The JSON in `--out` carries each response + condition (and `skipped`/`skip_reason`) for the
agent's semantic evaluation and for logging. A scheduled GHCP CLI invocation passes the same choices as
arguments (agents + per-category counts + optional `--user`).

For **MCS-OH** the scheduled task uses the MCS engine with a pre-built manifest:
```
python .github/skills/prompts-sender/scripts/send_prompts_mcs.py send \
  --manifest generated/a09091/mcs-manifest.json \
  --agents a09091-mcs-oh-1 --hello 1 \
  --out prompts-run-mcs.json
```

## MCS-OH (Copilot Studio) path
MCS-OH agents are **not** in `config.js`. They are reached over the Power Platform **Direct-to-Engine**
API via the Microsoft 365 Agents SDK Copilot Studio client — a delegated user token, **no browser
automation**. Only the **standard harness (MCS-OH)** is supported; **MCS-NH** (GitHub Copilot harness) is
auto-skipped (the API returns a "doesn't support … GitHub Copilot harness" notice). Full design and the
live-validation record: [references/mcs-feasibility.md](references/mcs-feasibility.md).

**One-time prerequisites**
1. `pip install -r scripts/requirements-mcs.txt`.
2. `az login` into the **target** Copilot Studio tenant (needed for `discover`).
3. A **public-client** Entra app with the Power Platform **`Copilot Studio.Copilots.Invoke`** delegated
   permission + admin consent. Create it once (target tenant):
   ```
   # 1) app with the delegated permission (Power Platform API 8578e004-…, scope id 204440d3-…):
   $rra = '[{"resourceAppId":"8578e004-a5c6-46e7-913e-12f58912df43","resourceAccess":[{"id":"204440d3-c1d0-4826-b570-99eb6f5e2aeb","type":"Scope"}]}]'
   $rra | Set-Content $env:TEMP\rra.json -Encoding utf8
   az ad app create --display-name "Prompts Sender MCS Client (Copilots.Invoke)" \
     --sign-in-audience AzureADMyOrg --is-fallback-public-client true \
     --public-client-redirect-uris "http://localhost" --required-resource-accesses "@$env:TEMP\rra.json"
   # 2) service principal + admin consent (use the returned appId):
   az ad sp create --id <appId>
   az ad app permission admin-consent --id <appId>
   ```

**Build the manifest (discover — no web UI)**
```
python scripts/send_prompts_mcs.py discover \
  --env-id <env-guid> --env-url https://orgXXXX.crm.dynamics.com \
  --tenant <target-tenant-id> --client-id <appId> \
  --name-filter MCS-OH --oh-only --out generated/<prefix>/mcs-manifest.json
```
Get `env-guid` + org URL from `pac env list`. `discover` reads the published bots (Dataverse) and writes
one manifest agent per MCS-OH bot (`id` = slugged display name, `agentIdentifier` = bot schema name,
`tools: []`).

**Sign in + send**
```
python scripts/send_prompts_mcs.py login  --manifest generated/<prefix>/mcs-manifest.json
python scripts/send_prompts_mcs.py agents --manifest generated/<prefix>/mcs-manifest.json
python scripts/send_prompts_mcs.py send   --manifest generated/<prefix>/mcs-manifest.json \
  --agents <ids> --hello 1 [--mail 1 --anon 1 --auth 1] --out results-mcs.json
```

**Coherence (MCS).** `hello` is always coherent. `MCP Mail access` / `Custom MCP Anon access` /
`Custom MCP Auth access` are sent **only** to an MCS agent whose manifest `tools` list declares the tool
(`"mail"` / `"anon"` / `"auth"`); otherwise the engine skips them (`N/A`, like the S2S guard). `discover`
sets `tools: []`, so by default only `hello` is sent — enable a category by editing the agent's `tools`.
A base MCS-OH agent with no generative/topic answer returns its **greeting**, which is a valid `hello`
response (the engine falls back to the greeting when the answer stream is empty).

## Notes / guardrails
- **Never** include the trailing `(condition)` in the message sent to an agent.
- Prompts are chosen at random (with replacement) from each category, so counts may exceed the pool.
- `{ANON_SERVER}` / `{AUTH_SERVER}` in the library are replaced with `ext_<prefix>Anon` /
  `ext_<prefix>Auth` (override with `--anon-server` / `--auth-server`).
- The Digital Worker (ACA-DW) is **not** an HTTP/SPA agent — it is triggered by **email** to its mailbox
  and is out of scope for this engine; a future extension could add an email-trigger sender.
