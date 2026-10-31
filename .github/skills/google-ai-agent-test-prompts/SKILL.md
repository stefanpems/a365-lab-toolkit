---
name: google-ai-agent-test-prompts
description: 'Send X test prompts to a named Google AI agent and obtain its responses. Use when asked to send prompts, smoke-test, exercise, or identify what a Google agent can do. With no prompt text, send "Who are you and what can you do?" X times (once when X is omitted). Resolve project, location, explicit credentials and the registry/runtime target before execution.'
---

# Google AI Agent Test Prompts

## Identify first

Obtain the project ID/number, location, explicit credential-file path, agent selector and resource kind. Ask only for missing values. A full `projects/.../locations/.../agents/...` name identifies a registry entry; `reasoningEngines/...` identifies a managed runtime. An ambiguous display name must be resolved by the user.

Keep the filled [target example](./assets/target.example.json), credentials and custom prompt files private. Never reuse the example's placeholders or a previous run's target as real values.

## Execute

Use the shared [CLI](./scripts/google_ai_agents.py) in a dedicated Python environment with [these dependencies](./scripts/requirements.txt). Send the whole batch in one process:

```powershell
python .github\skills\google-ai-agent-test-prompts\scripts\google_ai_agents.py send --config "C:\private\google-ai.local.json" --count 3
```

- Default text: **`Who are you and what can you do?`**. Repeat it exactly X times; X defaults to one.
- Custom text: repeat `--prompt "..."`, or use `--prompts-file` with a private JSON array. One supplied prompt is repeated X times; otherwise exactly X texts are required. If X is omitted, use the number of supplied texts.
- The batch shares one conversation. Registry entries advertising A2A use the ADK A2A client; other managed ADK agents use the native session/stream-query APIs.
- Optional `--expected-text` performs a deterministic, case-insensitive substring check. Otherwise a non-empty response is the success condition; do not imply semantic evaluation.
- Add `--run-dir` to choose a private output directory. Without it, the script creates one under the user's private Copilot data directory.

The JSON summary reports counts and a private `responses_file`. Its `responses` array contains each full prompt, answer, elapsed time and result. Read only the entries the user requests. Do not move transcripts into the public checkout.

## Failures and repetition

The script performs pagination and exact-name resolution itself. On `AMBIGUOUS_AGENT`, ask the user to select a full name. On authentication errors, request usable explicit credentials; do not start browser or device-code authentication.

Completed batches can be read again with the same `--run-dir` without resending prompts. Interrupted batches are **not replayed automatically**, because the remote agent may already have processed a message. Report partial private results and obtain permission for a fresh batch.
