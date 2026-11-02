---
name: google-ai-agent-create
description: 'Create a managed Google AI ADK/Gemini agent with automatic registry discovery. Use for create, provision, deploy or publish. First check local prerequisites, explain console-URL and model/service-account retrieval, and explicitly choose credential-file or isolated Edge authentication. Collect minimum inputs, preview and confirm billable creation, then run the shared script.'
---

# Google AI Agent Create

## Mandatory shared workflow

Follow the [operator guide](../google-ai-agent-test-prompts/references/operator-guide.md) in order: check this computer first, announce any missing installations before other questions, explain the creation-specific console navigation, collect only missing values and explicitly choose credential-file or isolated Edge authentication.

Before the input form, explain how to select the project and copy its complete console URL, obtain the desired Gemini model ID from Model Garden/deployment details, and copy an existing runtime service-account **Email** from IAM & Admin > Service Accounts. Ask separately for a region only if absent from the URL.

Also collect the new display name and instructions, or accept a private [creation specification](./assets/agent.example.json). Derive the internal ADK identifier; do not request it unnecessarily. A staging bucket, organization ID or service-account key is not needed.

For browser mode, use the committed helper once and pass its returned `credentials_file` to both preview and apply, exactly as with an existing credential file. Never infer a previous environment.

## Preview, confirm, execute

Use the shared [CLI](../google-ai-agent-test-prompts/scripts/google_ai_agents.py) and [dependencies](../google-ai-agent-test-prompts/scripts/requirements.txt).

```powershell
python .github\skills\google-ai-agent-test-prompts\scripts\google_ai_agents.py create --project-url "<complete project console URL>" --location "<region if missing from URL>" --credentials-file "C:\private\session.credentials.json" --spec "C:\private\agent.local.json"
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
