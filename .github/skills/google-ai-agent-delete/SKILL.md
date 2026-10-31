---
name: google-ai-agent-delete
description: 'Delete a managed Google AI agent after exact target discovery and human confirmation. Use for delete, remove or tear down a Google agent. First identify project, location, explicit credential file and registry/runtime selector. Resolve the real managed runtime, preview it, then use the deterministic script; child-resource deletion requires explicit force approval.'
---

# Google AI Agent Delete

## Identify first

Obtain the project ID/number, location, explicit credential-file path, exact agent selector and resource kind. Use a private copy of [the target example](../google-ai-agent-test-prompts/assets/target.example.json).

A registry entry is **not** the runtime. The script maps it to a managed `reasoningEngines` resource in the selected project/location. Unsupported or cross-project references are refused. Never delete an arbitrary external endpoint or a catalog record as a substitute for deleting the runtime.

## Preview, confirm, execute

Use the shared [CLI](../google-ai-agent-test-prompts/scripts/google_ai_agents.py) and [dependencies](../google-ai-agent-test-prompts/scripts/requirements.txt).

```powershell
python .github\skills\google-ai-agent-test-prompts\scripts\google_ai_agents.py delete --config "C:\private\google-ai.local.json"
```

Show the full runtime name, project, location and `force` setting. Ask the user to confirm this exact target with a structured control.

After approval, repeat the command with `--apply --confirm "<full runtime resource name>" --run-dir "<preview run_dir>"`.

The default does **not** delete child resources. If Google reports existing sessions or other children, explain the impact and obtain separate approval before using `--force`. Preview the changed force setting in a new run before applying it.

## Verification and repetition

- The script polls the recorded long-running operation and verifies that the exact runtime returns HTTP 404 before reporting completion.
- Agent Registry synchronizes the removal automatically; catalog visibility can lag behind runtime deletion.
- Reuse a pending run's `--run-dir`. A completed run verifies absence without deleting another agent, even if the original display name is later reused.
- On uncertainty or ambiguity, stop and report the saved run directory. Never issue speculative DELETE retries.
- Do not delete the Google project, credential file, service account, IAM roles, buckets, models or unrelated resources.
