---
name: google-ai-agent-delete
description: 'Delete a managed Google AI agent after exact discovery and human confirmation. Use for delete, remove or tear down. First check prerequisites, explain how to copy its complete console URL, and explicitly choose credential-file or isolated Edge authentication. Resolve the managed runtime, preview it, and confirm deletion; child-resource deletion needs separate force approval.'
---

# Google AI Agent Delete

## Mandatory shared workflow

Follow the [operator guide](../google-ai-agent-test-prompts/references/operator-guide.md): check prerequisites first and explain missing installations; give detailed Google Console navigation **before** the parameter form; then explicitly offer credential-file or isolated Edge authentication.

Explain how to select the project, open Agent Platform > Agent Registry > Agents, open the target and copy its complete address. Ask for **one agent URL**, not separate project, region and ID fields. The script extracts them. Private [target configuration](../google-ai-agent-test-prompts/assets/target.example.json) is an alternative.

For browser mode, use the committed helper and pass its returned `credentials_file` to preview and apply. This is the same fully supported action path as existing-file authentication.

A registry entry is **not** the runtime. The script maps it to a managed `reasoningEngines` resource in the selected project/location. Unsupported or cross-project references are refused. Never delete an arbitrary external endpoint or a catalog record as a substitute for deleting the runtime.

## Preview, confirm, execute

Use the shared [CLI](../google-ai-agent-test-prompts/scripts/google_ai_agents.py) and [dependencies](../google-ai-agent-test-prompts/scripts/requirements.txt).

```powershell
python .github\skills\google-ai-agent-test-prompts\scripts\google_ai_agents.py delete --agent-url "<complete agent console URL>" --credentials-file "C:\private\session.credentials.json"
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
