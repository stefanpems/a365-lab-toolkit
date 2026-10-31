---
name: google-ai-agent-create
description: 'Create a new managed Google AI ADK/Gemini agent, with automatic Agent Registry discovery. Use for create, provision, deploy or publish a Google agent. First identify project, location, explicit credential file, new agent name, model and existing runtime service account. Preview and confirm billable creation, then run the shared deterministic script.'
---

# Google AI Agent Create

## Identify first

Collect the project ID/number, location and explicit credential-file path. Then collect a new display name, a valid ADK identifier, Gemini model, instructions and an **existing runtime service-account email**.

Use the private target configuration described by [the target example](../google-ai-agent-test-prompts/assets/target.example.json); `agent` is not needed for creation. Fill a private copy of [the creation example](./assets/agent.example.json). Ask for missing parameters, never infer them from an earlier environment.

## Preview, confirm, execute

Use the shared [CLI](../google-ai-agent-test-prompts/scripts/google_ai_agents.py) and [dependencies](../google-ai-agent-test-prompts/scripts/requirements.txt).

```powershell
python .github\skills\google-ai-agent-test-prompts\scripts\google_ai_agents.py create --config "C:\private\google-ai.local.json" --spec "C:\private\agent.local.json"
```

Show the returned project, location, display name, model, runtime identity and instance limits. Explain that deployment and model use can incur charges. Use a structured control for confirmation.

After approval, execute the same command with `--apply --confirm "<exact display name>" --run-dir "<preview run_dir>"`. This is a second script invocation, not a new plan.

## Deployment contract

- Deploy a basic ADK/Gemini assistant on the managed Google AI Agent Engine runtime.
- The script sends a compressed inline package containing **only** the public [agent module](./assets/agent.py) and pinned [runtime requirements](./assets/requirements.txt). No local agent object, pickle, credential file or workspace directory is uploaded.
- Model/instruction settings are supplied as runtime configuration; the selected service account supplies runtime credentials.
- Default instance limits are zero minimum and one maximum. These reduce idle/scaling costs, not model charges.
- The selected model, runtime region, required APIs, billing and service-account permissions must already be available. Do not silently enable services or grant IAM roles.
- Agent Registry automatically indexes managed runtimes. The script verifies the resulting registry entry; `registry_pending` is not a claim that registration has completed.

## Repetition

Reuse `--run-dir` to poll a pending operation or finish registry verification without provisioning again. The script blocks duplicate display names and refuses to repeat an uncertain create request. Never switch to a new run directory just to bypass such a refusal.

Creation does not deploy arbitrary source trees, add tools, create service accounts or alter IAM. Ask for a separate, explicit task for those changes.
