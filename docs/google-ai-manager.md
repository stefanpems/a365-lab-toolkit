# Google AI Manager

The [Google AI Manager](../.github/agents/google-ai-manager.agent.md) is a GitHub Copilot custom agent for managing **Google AI** agents. It does not deploy a management agent to Google.

Its three skills share one deterministic [Python CLI](../.github/skills/google-ai-agent-test-prompts/scripts/google_ai_agents.py):

| Skill | Operation |
|---|---|
| [Test prompts](../.github/skills/google-ai-agent-test-prompts/SKILL.md) | Send a complete batch and retain full responses privately. |
| [Create](../.github/skills/google-ai-agent-create/SKILL.md) | Deploy a managed ADK/Gemini assistant and verify automatic catalog discovery. |
| [Delete](../.github/skills/google-ai-agent-delete/SKILL.md) | Resolve, confirm, delete and verify the exact managed runtime. |

Select **Google AI Manager** in Copilot and request, for example, **"Send 3 test prompts to agent Example Assistant"**. With no supplied text, the script sends **"Who are you and what can you do?"** three times. With no count, it sends that prompt once.

## Fixed onboarding order

The manager follows the shared [operator guide](../.github/skills/google-ai-agent-test-prompts/references/operator-guide.md):

1. Check the computer/interpreter for required tools before collecting cloud parameters. Explain missing installations first and request approval; never install silently.
2. Before asking for values, give detailed console-navigation instructions for the selected action.
3. Request complete agent/project-console URLs wherever possible and derive their project, region and resource ID. Ask only for missing values.
4. Explicitly offer **an existing credential file** or **interactive isolated Edge authentication**.
5. Execute the action with the selected explicit credentials and retain confirmation gates.
6. Always show **every complete received prompt response in chat**, including repeated replies and partial results when a later prompt fails. Summaries and links alone are insufficient.

For existing agents, open Google Cloud Console, select the project, navigate to **Agent Platform > Agent Registry > Agents**, open each target's details, and copy the full browser address with Ctrl+L/Ctrl+C. One address normally supplies the project, location and registry ID.

Explicit parameters and private configuration remain supported. Existing agents may also be identified by exact display name, ID or full resource name:

- `registry`: `projects/PROJECT_ID/locations/REGION/agents/REGISTRY_ID`
- `runtime`: `projects/PROJECT_ID/locations/REGION/reasoningEngines/RUNTIME_ID`

The two IDs are not interchangeable. Exact display names can be ambiguous; the script lists candidates rather than choosing the first match. Runtime names are resolved inside the requested project and location.

## Check prerequisites before setup

The checker needs no third-party Python packages, performs no login and installs nothing. Its PowerShell wrapper can report missing Python before attempting to execute Python:

```powershell
& .github\skills\google-ai-agent-test-prompts\scripts\Test-GoogleAiEnvironment.ps1
# Or select an already known dedicated interpreter explicitly:
& .github\skills\google-ai-agent-test-prompts\scripts\Test-GoogleAiEnvironment.ps1 -PythonPath "<Python executable>"
```

Its JSON lists installed package versions, missing base prerequisites, additional browser prerequisites and official installation links. A missing dependency returns exit `2` with `installation_required`. File authentication does not require Google Cloud CLI or Edge. Browser authentication additionally requires both; rerun the check with `-AuthMode browser` after the user selects it.

Only after explaining missing dependencies and obtaining approval, create/install into a dedicated environment:

Use Python 3.11 or later; the workflow is tested with Python 3.12. Create a dedicated environment rather than changing the repository's shared Python environment:

```powershell
$python = "$env:LOCALAPPDATA\google-ai-manager\.venv\Scripts\python.exe"
py -3.12 -m venv "$env:LOCALAPPDATA\google-ai-manager\.venv"
& $python -m pip install -r .github\skills\google-ai-agent-test-prompts\scripts\requirements.txt
```

Copy the placeholder-only [target configuration](../.github/skills/google-ai-agent-test-prompts/assets/target.example.json) **outside the checkout**, fill it locally, and supply its path with `--config`. Relative credential paths in that file are resolved relative to the file, not to the current directory. CLI flags can override its fields.

The scripts accept an explicit Google credential file supported by `google-auth`, such as a service-account, workforce/workload federation or separately obtained user-ADC file. Treat it as sensitive and trusted input. Use an existing credential file; do not create long-lived keys merely to use this tool.

Action commands load the selected credential file explicitly; they never fall back to shared default ADC or start a hidden login. SDK calls receive a process-only, run-specific context. Google credentials are not forwarded to arbitrary agent-card URLs.

### Fully supported browser authentication

After the user explicitly chooses browser mode, use the committed standard-library helper in a **separate process**:

```powershell
& $python .github\skills\google-ai-agent-test-prompts\scripts\google_ai_environment.py auth-browser --project "<derived project>" --auth-dir "C:\private\new-google-auth-session" --edge-profile-directory "<approved existing Work profile directory>"
```

The helper discovers Google Cloud CLI and Edge (or accepts `--gcloud-path` / `--edge-path`), launches only external Edge with the explicitly approved existing Work profile, waits for interactive OAuth, sets the quota project only in that dedicated credential store, and returns `credentials_file`.

Pass **that returned file path** unchanged to `--credentials-file` on all discover, send, create and delete calls. Reuse it for all agents and both preview/apply calls in the request; do not repeat login per prompt. Browser-generated user ADC and existing supported credential files use the same action implementation.

Isolation applies to Google configuration and token files; it does not mean creating an InPrivate, guest or temporary Edge profile. No shared accounts or token caches are switched, copied or overwritten. Browser mode requires a new directory; both modes reject shared default Google credential-store paths. Missing/expired credentials or a failed browser flow require an explicit operator decision; there is no device-code fallback.

## Commands

From the repository root:

```powershell
$script = ".github\skills\google-ai-agent-test-prompts\scripts\google_ai_agents.py"
& $python $script discover --config "C:\private\google-ai.local.json"
& $python $script send --config "C:\private\google-ai.local.json" --count 3
& $python $script send --config "C:\private\google-ai.local.json" --prompt "Introduce yourself." --prompt "List your capabilities."
# Minimal input: the script extracts project, location and registry ID.
& $python $script send --agent-url "<complete agent console URL>" --credentials-file "C:\private\session.credentials.json" --count 3
```

Custom prompt arrays belong in private JSON files passed with `--prompts-file`. One custom text is repeated X times; multiple texts must match X, or define the count when X is omitted. A batch retains one conversation. Optional `--expected-text` checks a case-insensitive substring; otherwise success means a non-empty textual response, not an LLM-based quality judgment.

Default `--transport auto` prefers native session/query APIs whenever the resolved managed ADK agent supports them, including registry entries that also advertise A2A. This avoids dependence on inconsistent A2A card-interface routes. Otherwise registry A2A agents use the ADK remote-agent client. Explicit `--transport native` and `--transport a2a` are available. Transport is selected before sending; failures never trigger automatic replay through another transport.

For multiple agents, run one complete batch per URL with the same explicit credentials and separate private run directories. Display every returned answer for every agent, not just counts.

### Create

Fill a private copy of [the creation specification](../.github/skills/google-ai-agent-create/assets/agent.example.json). Supply an available Gemini model and an existing runtime service account with the required permissions.

Before collecting these values, guide the user to the project's dashboard/settings and request its complete URL; to Model Garden/deployment details for the exact model ID; and to IAM & Admin > Service Accounts for the existing runtime account's Email. Ask for the region only if it is absent from the URL. The new display name/instructions are user choices; the internal ADK identifier is derived unless explicitly supplied.

```powershell
& $python $script create --config "C:\private\google-ai.local.json" --spec "C:\private\agent.local.json"
# A project-console URL can replace a separate project ID:
& $python $script create --project-url "<complete project console URL>" --location "<region if missing>" --credentials-file "C:\private\session.credentials.json" --spec "C:\private\agent.local.json"
# After reviewing and approving the preview:
& $python $script create --config "C:\private\google-ai.local.json" --spec "C:\private\agent.local.json" --apply --confirm "Example Assistant" --run-dir "C:\private\the-preview-run"
```

Inline-source deployment uploads only two allowlisted assets: the agent module and pinned runtime dependencies. It does not serialize the operator's local agent object or credentials, copy the checkout, or require a staging bucket. Model/instructions are runtime environment settings; the runtime uses its selected service account.

The script waits for deployment, verifies the runtime, and checks Agent Registry's automatic registration. Required Google APIs, billing, model availability and IAM permissions must already be configured. This tool does not enable APIs, create identities or grant roles. Charges depend on the selected runtime/model; the default scaling range is zero to one instance.

### Delete

```powershell
& $python $script delete --config "C:\private\google-ai.local.json"
# After reviewing and approving the exact runtime:
& $python $script delete --config "C:\private\google-ai.local.json" --apply --confirm "projects/PROJECT_ID/locations/REGION/reasoningEngines/RUNTIME_ID" --run-dir "C:\private\the-preview-run"
```

Child resources are retained by default. `--force` must be separately reviewed and approved, using a new preview when changing that setting. Only the resolved managed runtime and, when explicitly forced, its children are deleted. Other projects, service accounts, IAM roles and buckets are untouched.

## Results, failures and repeatability

- Prompt-command JSON stdout includes complete replies in `responses`, with agent, prompt indexes/text, timings and status. Errors after partial completion include replies already received. Treat stdout as private transcript data; it contains no credential contents.
- The Copilot agent always presents those full replies directly in chat. Transcript links and summary tables are supplementary, not replacements.
- Full prompt/response pairs and durable operation state are in `state.json` under a private per-run directory. The default root is the user's `~\.copilot\google-ai-manager\runs` directory. Choose another private location with `--run-dir`.
- Exit `0`: completed or preview awaiting confirmation; `2`: explicit error; `3`: expected-text check failed; `4`: a cloud operation or catalog synchronization is still pending.
- Reuse a run directory to poll a pending operation without submitting another create/delete. A request fingerprint prevents reusing it for different input.
- Completed prompt batches are not resent. Interrupted batches are refused rather than replayed, because the service may already have processed a message.
- Read-only API calls retry selected transient HTTP errors. Mutating requests and prompt sends do not retry automatically.
- Atomic private-state updates retry only Windows file-contention errors, at most five local replace attempts with bounded backoff and explicit warnings. These retries never repeat a Google request; persistent or other permission errors still fail explicitly.
- A definite API rejection leaves a mutation eligible for an explicit retry after the operator fixes the cause. Timeouts and unknown server outcomes remain uncertain and are not replayed.
- An uncertain mutation is not reported as success. Preserve its run directory and inspect the operation before deciding what to do next.
- Runtime deletion is verified by HTTP 404; automatic catalog synchronization may take longer.

## Public-repository hygiene

All committed examples contain placeholders only. Actual project/account identifiers, credential files, filled specifications, prompt libraries, transcripts, operation state and deployment output must remain outside the checkout or under an ignored `.google-ai-private` directory. The scripts reject other in-checkout private paths.

The root ignore rules protect this private directory, Google ADC files, common credential-file names, local Google profiles and run directories. Ignore rules are a safety net, not permission to commit private data with `git add -f`. Do not paste credentials into chat or public issues, commit local run artifacts, or copy real target values into these examples.

## Local validation

The tests use mocked Google and A2A transports; they do not authenticate or mutate Google resources:

```powershell
& $python -m unittest discover -s .github\skills\google-ai-agent-test-prompts\tests -v
```

References: [managed inline-source deployment](https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/deploy-an-agent), [ADK runtime invocation](https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/use-an-adk-agent), and [automatic registry synchronization](https://docs.cloud.google.com/agent-registry/automatic-registration).
