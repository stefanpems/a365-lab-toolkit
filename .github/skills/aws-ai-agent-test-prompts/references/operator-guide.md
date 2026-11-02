# AWS AI Manager operator guide

## Supported surfaces

| Surface | Create | Send/read replies | Delete |
|---|---|---|---|
| AgentCore Runtime, IAM-authenticated HTTP | Allowlisted Python Bedrock Converse assistant, direct ZIP deployment | `{"prompt": "..."}` input; JSON, text or SSE output | Manager-tagged runtime, all versions; tagged custom endpoints only with separate force approval |
| Bedrock Agents Classic | Native agent, prepare, tagged live alias; existing eligible customers only | Draft test alias or explicitly selected alias | Manager-tagged agent; tagged aliases only with separate force approval |

AWS closed Classic to new customers on July 30, 2026. A new account must use AgentCore.
An acknowledgement in the specification does not enable Classic entitlement.
This manager does not manage foundation models, AgentCore Harness configurations, AWS Agent Registry
entries, knowledge bases, tools or Agent 365 registrations.

## Fixed onboarding order

1. Check local Python/dependencies; for browser mode also check AWS CLI and the confirmed Edge Work profile.
2. Explain console navigation and minimum inputs. Do not start by asking a beginner for unexplained ARNs.
3. Explicitly choose a dedicated temporary-credentials file or isolated interactive console sign-in.
4. Verify account, non-root principal and region, then discover/check the selected model.
5. If needed, preview setup of a scoped execution role and private artifact bucket; obtain separate approval.
6. Preview agent creation; obtain separate approval.
7. Send only the requested prompt batch, showing every complete reply.
8. For deletion, discover, preview, confirm the full ARN and verify AWS reports the exact resource not found.

See the [new-account walkthrough](../../../../docs/aws-ai-manager.md#starting-with-only-an-aws-account).

## Private paths and dependencies

All commands below are PowerShell, run from the repository root. Use absolute paths and a private directory outside the repository.
The authentication, runs and Python environment directories must be distinct.
The scripts reject the shared home AWS directory, repository storage and nonempty directories
not marked as their own. Private data is protected with a user/SYSTEM Windows ACL or mode 0700 on Unix.

```powershell
$scripts = (Resolve-Path ".github\skills\aws-ai-agent-test-prompts\scripts").Path
$python = "C:\Private\AwsAiManager\python\Scripts\python.exe"
$auth = "C:\Private\AwsAiManager\auth"
$account = "123456789012"
$region = "eu-north-1"
$cli = Join-Path $scripts "aws_ai_agents.py"
& $python (Join-Path $scripts "aws_ai_environment.py") check
```

If Python or the SDK is missing, explain and obtain approval before installation:

```powershell
python -m venv "C:\Private\AwsAiManager\python"
& $python -m pip install -r (Join-Path $scripts "requirements.txt")
```

The local pinned SDK is independent of the runtime's pinned Linux ARM64 dependencies.
AgentCore's deployment bundle is assembled only from those downloaded dependencies,
the committed assistant and the selected model/instructions/token limit. Nothing else
from the workspace or local authentication directory is uploaded.

## Authentication

### Browser

Requires AWS CLI v2.32.0+ and an existing, explicitly confirmed Edge Work profile.
Use the profile and work email confirmed by local instructions or by the user; never publish
personal profile details in workspace examples.

```powershell
& $python (Join-Path $scripts "aws_ai_environment.py") browser `
  --auth-dir $auth --region $region --edge-profile "Default" `
  --work-email "operator@example.com"
$scope = @("--auth-dir", $auth, "--account-id", $account, "--region", $region)
& $python $cli check-account @scope
```

The helper uses AWS's same-device authorization-code console login, opens external Edge
through its explicit `BROWSER` command, and isolates `AWS_CONFIG_FILE`,
`AWS_SHARED_CREDENTIALS_FILE`, `AWS_LOGIN_CACHE_DIRECTORY` and profile selection in the
child process. The SDK receives only temporary exported credentials in memory.
Inherited AWS credentials, metadata providers and endpoint overrides are not used.
The parent environment, shared default profile, shared login/SSO caches and scheduled tasks
are unchanged. There is no remote/device-code fallback or logout/profile-switch operation.

For an IAM console identity, grant `SignInLocalDevelopmentAccess` in addition to the selected
service permissions. IAM Identity Center identities cannot use `aws login`; use their portal's
temporary credentials in a dedicated file instead. Do not run `aws configure sso` or SSO login
against the shared default cache as a workaround.

### Dedicated temporary-credentials file

Collect only the existing file path and its section name, never its secret contents.
The file must be outside the repository and shared AWS stores, with this structure:

```ini
[aws-ai-manager]
aws_access_key_id = TEMPORARY_ACCESS_KEY
aws_secret_access_key = TEMPORARY_SECRET_KEY
aws_session_token = TEMPORARY_SESSION_TOKEN
```

An optional timezone-qualified ISO `expiration` is validated. Static long-lived keys,
role/SSO/credential-process directives and default-provider fallback are not supported.

```powershell
$scope = @("--auth-dir", $auth, "--account-id", $account, "--region", $region,
  "--credentials-file", "C:\Private\AwsAiManager\temporary.ini",
  "--credentials-profile", "aws-ai-manager")
& $python $cli check-account @scope
```

## Discover models and agents

```powershell
& $python $cli models @scope
& $python $cli models @scope --model-id "<selected-regional-model-id>"
& $python $cli list @scope --service agentcore
```

For a beginner, prefer an available on-demand Amazon text model compatible with Bedrock Converse.
Do not assume the example region has a particular model. Review the current model price and
provider requirements. Availability checks are read-only and do not accept agreements or run inference.
Inference profiles include their foundation-model ARNs in the execution policy.
Cross-region routing requires `allow_cross_region: true` in the specification and human review.
An active inference profile alone does not prove provider entitlement or Converse compatibility;
review its backing model and verify inference with the separately requested prompt batch.

Agent references accept full commercial AWS console URLs, runtime/agent ARNs, or exact names.
Names require an explicit service. Lists are fully paginated; zero/multiple matches are errors.
If `--region` is omitted, it must be unambiguously present in the URL or ARN. A conflicting
account/service/region is rejected, never silently replaced.

## Setup and create

Copy an example to private storage, replace the model placeholder, and set English instructions:

- [AgentCore specification](../../aws-ai-agent-create/assets/agentcore.example.json)
- [Classic specification](../../aws-ai-agent-create/assets/bedrock.example.json)

The Classic example deliberately sets `existing_classic_customer: false`.
Change it to true only after the user explicitly confirms an eligible existing account.

For a new account, setup creates a role restricted to the selected model and, for AgentCore,
a private encrypted/versioned same-region artifact bucket. It does not create access keys,
enable marketplace subscriptions or alter preexisting roles/buckets.

```powershell
$spec = "C:\Private\AwsAiManager\agent.json"
$setupRun = "C:\Private\AwsAiManager\runs\setup-001"
& $python $cli setup @scope --spec $spec --run-dir $setupRun
# After explicit review and approval, use the exact confirmation returned above:
& $python $cli setup @scope --spec $spec --run-dir $setupRun `
  --apply --confirm "123456789012/eu-north-1/AwsAssistant"
```

Setup writes a private `create-spec.json` containing the role ARN and bucket name.
Alternatively supply an existing same-account role and, for AgentCore, private same-region bucket
in the specification. Their identity, ownership/region and public-access block are checked.
IAM propagation, service quotas or provider restrictions can still cause AWS to reject deployment;
report such errors, do not automatically repeat writes.

```powershell
$createSpec = Join-Path $setupRun "create-spec.json"
$createRun = "C:\Private\AwsAiManager\runs\create-001"
& $python $cli create @scope --spec $createSpec --run-dir $createRun
# Separate creation approval:
& $python $cli create @scope --spec $createSpec --run-dir $createRun `
  --apply --confirm "AwsAssistant"
```

The AgentCore build installs pinned binary wheels for Linux ARM64/Python 3.13 into private
run storage; no Docker/ECR/CodeBuild is required. The content-addressed, allowlisted source
is bound to the preview. Unique S3 keys are never overwritten and object versions are pinned
when bucket versioning is enabled. Runtime sessions have a 300-second idle timeout and
1800-second maximum lifetime.

## Send prompts

```powershell
$agent = "arn:aws:bedrock-agentcore:eu-north-1:123456789012:runtime/AwsAssistant-AbCdEf1234"
& $python $cli send @scope --agent $agent --count 3 `
  --run-dir "C:\Private\AwsAiManager\runs\send-001"
```

With no prompt, send `Who are you and what can you do?`; no count means once per agent.
Use repeatable `--agent`, repeatable `--prompt`, or a private JSON array via `--prompts-file`.
One supplied prompt repeats; multiple prompts must match count (or infer count when omitted).
Use `--expected-text` for a case-insensitive check without modifying or shortening the answer.
Each agent has its own conversation; all prompts for that agent share its session.

For Classic, use `--alias-id` for a published alias or its alias details URL. Otherwise the
runner explicitly uses AWS's `TSTALIASID` draft-test alias. AgentCore defaults to `DEFAULT`
or a selected `--qualifier`. OAuth, MCP/A2A and external return-control execution are not
implemented by this prompt runner.

Replies are not truncated locally. Every complete reply must also be displayed in chat.
Pending requests and every received answer/error are persisted privately; an existing response
run is never replayed automatically. A failed expected-text check exits nonzero while preserving
the full answer.

## Delete

```powershell
$deleteRun = "C:\Private\AwsAiManager\runs\delete-001"
& $python $cli delete @scope --agent $agent --run-dir $deleteRun
& $python $cli delete @scope --agent $agent --run-dir $deleteRun --apply --confirm $agent
```

Only manager-tagged resources in the exact account/region are eligible. All agent versions are
deleted. If manager-owned custom endpoints or Classic aliases are listed, obtain separate approval
and create a fresh preview with `--force` before applying. Force never bypasses ownership.
Classic action groups, knowledge-base associations and collaborators must be detached manually.
Deletion is successful only after AWS returns resource-not-found, not merely after HTTP 202.

IAM roles/policies, S3 artifacts/buckets and logs are deliberately retained. They may keep costing
money. Their cleanup is outside this agent-deletion command and needs a separate reviewed action.

## Failures and repeatability

- Mutations require `--apply`, exact confirmation and the original private preview directory.
- Scope/specification/source changes invalidate the preview. New operations need new run directories.
- Writes use a persistent step journal, explicit idempotency tokens where AWS supports them and
  disabled SDK retries. A successful response is reused, not reissued; a pending/uncertain write
  stops for inspection. There is no blanket retry or fabricated success.
- Read-only polling can resume known successful create/delete operations using the same run.
- Do not share private journals, credentials, instructions or full responses through issues/commits.
- AWS CLI/SDK errors, unavailable models, ambiguous targets and invalid response shapes are explicit
  nonzero failures. Do not fall back to another service, account, region, browser or authentication method.

## Validation

```powershell
& $python -m unittest discover `
  -s (Join-Path $scripts "..\tests") -v
```

The suite uses mocked/stubbed AWS services and never signs in or creates billable resources.
Install the runtime asset requirements in the dedicated test environment to include the real
AgentCore SDK HTTP/health integration test; otherwise that optional test is explicitly skipped.
Live checks need an explicitly approved non-root account, regional model access and service quotas.
