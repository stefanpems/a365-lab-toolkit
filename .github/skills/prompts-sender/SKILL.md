# Prompts Sender — skill

Operational knowledge for the **Prompts Sender** agent. It sends batches of prompts to the
SPA-callable Lab Builder agents (the six OBO/S2S agents exposed in a lab's web UI) and checks each
response against a success condition. It runs **interactively** (asks the operator) or **unattended**
(all inputs on the command line — for GitHub Copilot CLI launched by Windows Task Scheduler).

## Components (this skill folder)
- `references/prompt-library.md` — the random source of prompts. Four categories, four prompts each.
  Every prompt ends with a `(success condition)`; the sender **strips** that parenthesis before sending
  and uses it only to judge the response.
- `scripts/send_prompts.py` — the engine: reads a lab's `ui/config.js`, authenticates via MSAL (the
  SPA public client), picks random prompts, sends them, records responses, and writes JSON results.
- `scripts/requirements.txt` — `msal`, `requests`.

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
2. **Locate the lab config** — ask for the lab prefix (e.g. `a09091`) and use
   `generated/<prefix>/<prefix>-ui/config.js`, or ask for an explicit `config.js` path. Run
   `python send_prompts.py agents --config <config.js>` to list the agent ids.
3. **Which agents** — multi-select from the listed ids (`obo`, `s2s`, `obo-fh`, `s2s-fh`, `obo-fd`,
   `s2s-fd`).
4. **How many prompts per category** — always ask the `hello` count. Ask the `MCP Mail access` /
   `Custom MCP Anon access` / `Custom MCP Auth access` counts **only if at least one OBO agent is
   selected**, and apply those three categories **only to the OBO agents**. When the selection mixes S2S
   and tool categories, **split the run into separate `send` invocations** — `hello` to all selected
   agents, and the tool categories to the OBO agents only — never a single combined `send`.
5. **Ensure sign-in** — if there is no cached account, run `login` first (browser).
6. **Send** — run `send_prompts.py send` with the chosen ids/counts and `--out results.json`.
7. **Evaluate + report** — read `results.json`; for each entry judge whether `condition` is satisfied in
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

## Notes / guardrails
- **Never** include the trailing `(condition)` in the message sent to an agent.
- Prompts are chosen at random (with replacement) from each category, so counts may exceed the pool.
- `{ANON_SERVER}` / `{AUTH_SERVER}` in the library are replaced with `ext_<prefix>Anon` /
  `ext_<prefix>Auth` (override with `--anon-server` / `--auth-server`).
- The Digital Worker (ACA-DW) is **not** an HTTP/SPA agent — it is triggered by **email** to its mailbox
  and is out of scope for this engine; a future extension could add an email-trigger sender.
