---
name: aws-ai-agent-create
description: 'Create a managed AWS AI agent: a Python Bedrock Converse assistant on Amazon Bedrock AgentCore Runtime, or a native Bedrock Agents Classic agent for an existing eligible customer. Check local prerequisites, explain console/model/role retrieval, choose isolated Edge browser or dedicated temporary credentials, preview billable creation, and require exact confirmation.'
---

# Create an AWS AI agent

Read the [operator guide](../aws-ai-agent-test-prompts/references/operator-guide.md).

1. Check local prerequisites, explain console URL/account/region retrieval, then explicitly select isolated browser authentication or a dedicated temporary-credentials file.
2. If the user has only created an AWS account, route through [initial setup](../aws-ai-agent-setup/SKILL.md). Do not assume a model, execution role or artifact bucket exists.
3. Ask for AgentCore or Classic, agent name, model ID, instructions and role ARN. AgentCore also needs a private same-region S3 artifact bucket. Never offer Classic as available for a new account.
4. Start from the secret-free [AgentCore example](assets/agentcore.example.json) or [Classic example](assets/bedrock.example.json); replace the model placeholder after regional discovery. Keep the working specification outside the repository. Set the Classic example's acknowledgement to true only after the user explicitly confirms an eligible existing account.
5. Run `create --spec ...` without `--apply`. Review exact account/region/model, execution role, package contents, destination regions and costs. Duplicate names are refused.
6. Collect human approval and the exact agent name. Rerun with `--apply --confirm <name>` and the same specification and `--run-dir`.
7. Wait for AWS readiness and report the full ARN/ID and default endpoint or Classic live alias ID. A pending/failed state is not a successful deployment.

AgentCore deploys only the committed [assistant](assets/agent.py), its configuration and
[pinned dependencies](assets/requirements.txt), packaged for Linux ARM64/Python 3.13.
It needs no Docker, ECR, CodeBuild or optional AWS Agent Toolkit installation.
Setup and create never run without separate approval.

Use the [shared script](../aws-ai-agent-test-prompts/scripts/aws_ai_agents.py).
Do not automatically retry uncertain writes or adopt a conflicting existing resource.
