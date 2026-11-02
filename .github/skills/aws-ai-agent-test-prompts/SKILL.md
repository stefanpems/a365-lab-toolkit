---
name: aws-ai-agent-test-prompts
description: 'Send X test prompts to AWS AI agents and always show every complete reply. Supports IAM-authenticated HTTP AgentCore Runtime agents and Bedrock Agents Classic aliases, automatic discovery from full AWS console URLs/ARNs or exact scoped names, isolated Edge browser or dedicated temporary credentials, and optional expected-text checks. Default prompt: Who are you and what can you do? Once when X is omitted.'
---

# Send prompts to AWS AI agents

Read the [operator guide](references/operator-guide.md).

1. Run the [local prerequisite check](scripts/aws_ai_environment.py) before collecting setup inputs.
2. Explain how to open the agent's details in the AWS console and copy its complete URL. A welcome/home/list URL does not identify an agent.
3. Ask explicitly for isolated browser authentication in the confirmed existing external Edge Work profile or an existing dedicated temporary-credentials file path. Never request secrets or use shared credential stores/device-code flows.
4. Collect the expected account ID and complete agent URL(s), ARN(s), or exact names with service and region. Discover agents without guessing. Cross-account/region conflicts and ambiguous names are errors.
5. Ask for count and optional prompts/success text. With no prompt text, use `Who are you and what can you do?`; with no count, send it once per agent. A single supplied prompt repeats; a prompt array must match the requested count.
6. Explain that model inference/runtime calls may cost money. A direct user request to send the specified prompts authorizes that batch, not resource creation or new provider subscriptions.
7. Execute one [shared-script](scripts/aws_ai_agents.py) `send` command per scoped batch. Keep one conversation per agent and use a new private run directory. Never resend automatically after an uncertain result.
8. Display **every full prompt and full reply**, in order, even when a later request fails or the expected text is missing. Also report elapsed time/check results and the private `responses.json` path; a path or summary alone is insufficient.

The runner supports the `prompt` JSON request and JSON/text/SSE response contract.
It does not execute returned external actions, authenticate OAuth endpoints, or treat MCP/A2A
servers as prompt endpoints. Such cases fail explicitly rather than returning fabricated answers.
