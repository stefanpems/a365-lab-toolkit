---
name: aws-ai-agent-setup
description: 'Onboard a brand-new AWS account for AWS AI Manager. Use for initial AWS setup, prerequisites, isolated Edge console sign-in or a dedicated temporary-credentials file, non-root/MFA guidance, region/model discovery, and previewing an execution role and private AgentCore artifact bucket. No cloud changes until separately confirmed. Bedrock Agents Classic is existing-customer-only.'
---

# Set up AWS AI Manager

Read the [operator guide](../aws-ai-agent-test-prompts/references/operator-guide.md) and
[new-account walkthrough](../../../docs/aws-ai-manager.md#starting-with-only-an-aws-account).

1. Run `aws_ai_environment.py check` from the shared scripts directory. Explain missing Python/SDK dependencies and, only for browser mode, AWS CLI v2.32.0+ and Edge.
2. Explain that AgentCore Runtime is the supported path for a new account; Classic is not open to new customers.
3. Guide the user through securing root with MFA, creating a non-root identity with the needed permissions and `SignInLocalDevelopmentAccess`, and reviewing billing/budget alerts. Do not perform root administration or change policies without approval.
4. Ask for the expected account ID, region (the welcome screen's region is only a starting point), and authentication method using input controls. Browser mode must use the confirmed existing Edge Work profile; file mode requires an existing dedicated temporary-credentials file, never keys pasted into chat.
5. Run isolated authentication, then `check-account`. Stop on an account mismatch or root identity. Never fall back to another authentication method automatically.
6. Run `models`; explain how to choose a supported text model, price, on-demand availability and possible cross-region inference. Check the selected model with `models --model-id`. Never automatically accept provider agreements.
7. Ask for the agent service/name, model and instructions. Write a secret-free private specification in English, outside the repository. For Classic, require explicit existing-customer acknowledgement.
8. If an execution role/private bucket already exists, collect their identifiers and proceed to create. Otherwise run `setup` **without** `--apply`. Explain the scoped role/trust policy, private encrypted/versioned bucket, retained resources and charges.
9. Ask for explicit approval of the preview and exact confirmation. Only then rerun the same command with `--apply --confirm`, using the same private run directory.
10. Return the generated `create-spec.json` path and continue with the create skill only after a separate creation approval. Never merge setup and agent creation into one blanket confirmation.

Shared scripts:
- [Environment and browser authentication](../aws-ai-agent-test-prompts/scripts/aws_ai_environment.py)
- [AWS operations](../aws-ai-agent-test-prompts/scripts/aws_ai_agents.py)
- [Local SDK requirements](../aws-ai-agent-test-prompts/scripts/requirements.txt)
