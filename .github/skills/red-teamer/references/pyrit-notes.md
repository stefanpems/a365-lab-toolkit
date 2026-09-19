# Red Teamer — PyRIT design notes

How the Red Teamer integrates **Microsoft PyRIT** (https://github.com/microsoft/PyRIT) with this
workspace's lab agents, and why the integration is shaped this way.

## Roles in the attack loop
PyRIT owns the full loop; the workspace only supplies the *target*:

```
 objectives.md ──► PyRIT attack (prompt_sending / crescendo / …)
                     │  applies converters (mutations)
                     ▼
             A365LabTarget  ──►  send_prompts.send_to_agent()  ──►  lab agent (HTTP + Entra token)
                     ▲                                                     │
                     └───────────────── reply ◄────────────────────────────┘
                     │
                     ▼
             PyRIT scorer (SelfAskRefusalScorer, LLM judge)  ──►  attack succeeded? / defense held?
                     │
                     ▼
             PyRIT memory (SQLite, outside the repo)  +  redteam-results.json (git-ignored)
```

- **Target** = the lab agent (external system under test). Implemented by `a365_target.py`.
- **Adversary / judge model** = an OpenAI-compatible chat endpoint PyRIT calls for scoring (and, for
  multi-turn attacks, to drive the conversation). Point it at the **lab's Azure OpenAI / Foundry**
  deployment. Configured in `~/.pyrit/.env` — never in the repo.

## Why Framework mode (not the Scanner)
PyRIT's `pyrit_scan` Scanner assumes a standard OpenAI/Azure target. The lab agents are not that: each
`kind` (`aca`, `foundry-invocations`, `foundry-responses`, `foundry-prompt`) needs a different Entra
token audience and a different request/response body. `send_prompts.send_to_agent()` already encodes all
of that, so we wrap it in a custom PyRIT `PromptChatTarget` and drive it from a small Python runner.

## Why the Prompts Sender is reused
`send_prompts.py` already solves auth (MSAL SPA client, silent tokens) and per-kind dispatch. The adapter
**imports** it (`load_config`, `get_token`, `send_to_agent`) and calls `send_to_agent` from
`send_prompt_async`. `send_prompts.py` is **not modified** — zero regression to the Prompts Sender.

## One-time setup (outside the repo)

```powershell
# 1. Dedicated venv (git-ignored) with PyRIT — Python 3.12/3.13.
py -3.12 -m venv .venv-redteam
.\.venv-redteam\Scripts\python.exe -m pip install -r .github/skills/red-teamer/scripts/requirements.txt

# 2. PyRIT config in the user profile (NOT in the repo).
#    ~/.pyrit/.env  — the scorer/adversary chat endpoint (use the lab's Azure OpenAI):
#      OPENAI_CHAT_ENDPOINT="https://<account>.services.ai.azure.com/openai/v1"
#      OPENAI_CHAT_KEY="<key>"        # or use AAD; see PyRIT configuration docs
#      OPENAI_CHAT_MODEL="<deployment-name>"
#    ~/.pyrit/.pyrit_conf — minimal:
#      memory_db_type: in_memory
```

The runner initializes PyRIT with `initialize_pyrit(...)` and reads the scorer endpoint from the
environment, so no endpoint or key is ever stored in the workspace.

## Supported scope
- **Targets:** the six SPA-callable agents (`obo`, `s2s`, `obo-fh`, `s2s-fh`, `obo-fd`, `s2s-fd`).
- **Attacks:** single-turn `prompt_sending`, `many_shot`, `skeleton_key` (scorer only); multi-turn
  `crescendo`, `red_teaming`, `tap`, `pair` (need the adversary LLM in `~/.pyrit/.env`).
- **Objectives:** the categories in `references/objectives.md`, including the `multi-turn-*` sections.

## Multi-turn design (stateless targets)
The six SPA agents keep no server-side conversation (ACA ignores `history`; FH-OBO uses `store:False`;
FH-S2S/FD send no thread id). PyRIT multi-turn attacks assume the *target* holds the conversation, so:
- `A365LabTarget` declares native capabilities (`supports_multi_turn`, `supports_editable_history`,
  `supports_system_prompt`) via `_DEFAULT_CONFIGURATION`; otherwise the attacks raise a capability error.
- On each turn PyRIT hands the target the full normalized conversation; in `multi_turn` mode the adapter
  **flattens prior turns into one transcript** (mode: flattened-transcript) and sends it as the single
  agent message. `send_prompts.py` is never touched.
- Scorers: `crescendo` gets an empty `AttackScoringConfig` (PyRIT builds its default TASK_ACHIEVED float
  scorer); `red_teaming` gets the refusal-inverted objective scorer; `tap`/`pair` get `None` (PyRIT builds
  the default `FloatScaleThresholdScorer`, threshold 0.7). The adversary + these scorers read the same
  `~/.pyrit/.env` chat endpoint.

## Out of scope
- Digital Workers (ACA-DW, FH-DW): no synchronous endpoint (email-triggered).
- Copilot Studio (MCS-OH/NH): a future adapter over `send_prompts_mcs.py`.
