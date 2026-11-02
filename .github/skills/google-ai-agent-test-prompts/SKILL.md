---
name: google-ai-agent-test-prompts
description: 'Send X test prompts to Google AI agents, create agent traffic, and always show every complete reply. First check local prerequisites, explain how to copy agent-console URLs, and ask explicitly for credential-file or isolated Edge authentication. With no text, send "Who are you and what can you do?" X times per agent, once when X is omitted.'
---

# Google AI Agent Test Prompts

## Mandatory shared workflow

Follow the [operator guide](./references/operator-guide.md) in order: **check prerequisites; explain console navigation; collect minimum input; explicitly choose file or isolated Edge authentication; execute; show every complete answer**.

Before asking for parameters, explain how to open Google Cloud Console, select the project, navigate to Agent Platform > Agent Registry > Agents, open each agent and copy its complete browser address. Ask for **one URL per agent**, not separate project/region/registry IDs. The CLI derives those values.

Ask explicitly whether the user has a credential file or wants browser authentication. Use the committed browser helper when selected, then pass its returned `credentials_file` to every action. Use one authentication session for the entire multi-agent request. Keep [configuration examples](./assets/target.example.json), credentials and prompt files private when filled.

## Execute

Use the shared [CLI](./scripts/google_ai_agents.py) in a dedicated Python environment with [these dependencies](./scripts/requirements.txt). Send the whole batch in one process:

```powershell
python .github\skills\google-ai-agent-test-prompts\scripts\google_ai_agents.py send --agent-url "<complete agent console URL>" --credentials-file "C:\private\session.credentials.json" --count 3
```

- Default text: **`Who are you and what can you do?`**. Repeat it exactly X times; X defaults to one.
- Custom text: repeat `--prompt "..."`, or use `--prompts-file` with a private JSON array. One supplied prompt is repeated X times; otherwise exactly X texts are required. If X is omitted, use the number of supplied texts.
- Each agent's batch shares one conversation. Run one action process per target URL, not one process per prompt. A count of X means X prompts **per agent**; state the total.
- Default `--transport auto` prefers native managed ADK session/query APIs, avoiding inconsistent A2A card routes. Use A2A only when native methods are unavailable or the user explicitly requests `--transport a2a`. Never replay uncertain sends through another transport automatically.
- Optional `--expected-text` performs a deterministic, case-insensitive substring check. Otherwise a non-empty response is the success condition; do not imply semantic evaluation.
- Add `--run-dir` to choose a private output directory. Without it, the script creates one under the user's private Copilot data directory.

The JSON result contains `responses`: every full prompt, answer, elapsed time and result, plus the private `responses_file`. **Always display each agent's complete answers in chat, labeled by prompt number/text, including identical repeated answers.** Counts, excerpts, summaries or file links alone are insufficient. If a later send fails, display the replies already received and identify the unanswered prompts. Do not move transcripts into the public checkout.

## Failures and repetition

The script performs pagination and exact-name resolution itself. On `AMBIGUOUS_AGENT`, explain how to open the intended agent's details and ask for its complete URL. On authentication errors, explain the failure and ask whether to use a usable credential file or explicitly retry the isolated Edge flow. No device-code or shared-cache fallback is allowed.

Completed batches can be read again with the same `--run-dir` without resending prompts. Interrupted batches are **not replayed automatically**, because the remote agent may already have processed a message. Report partial private results and obtain permission for a fresh batch.
