---
name: aws-ai-agent-delete
description: 'Delete one managed AWS AgentCore Runtime or Bedrock Agents Classic agent after exact discovery and human confirmation. Check prerequisites, explain full console URL retrieval, choose isolated Edge authentication or a dedicated temporary-credentials file, verify ownership/account/region, preview all affected resources, and require separate force approval for managed children.'
---

# Delete a managed AWS AI agent

Read the [operator guide](../aws-ai-agent-test-prompts/references/operator-guide.md).

1. Check local prerequisites and explain how to copy the agent's complete details URL before collecting identifiers.
2. Select isolated browser authentication or an existing dedicated temporary-credentials file using input controls. Never switch shared AWS profiles or use shared token caches.
3. Collect the expected account ID and one complete console URL/ARN or exact scoped name. Discover exactly one agent; reject ambiguous, cross-account/region and unmanaged targets.
4. Run the [shared script](../aws-ai-agent-test-prompts/scripts/aws_ai_agents.py) `delete` without `--apply`. Show the exact ARN, all versions, ownership tags, child resources and retained resources/costs.
5. If managed child endpoints/aliases exist, offer a separate `--force` preview and obtain distinct approval. Unrelated children or Classic action groups/knowledge-base/collaborator associations are refused even with force.
6. Ask for explicit approval and the exact full ARN as confirmation. Apply the same saved preview using the same private run directory and flags.
7. Wait until AWS reports the exact resource as not found. Only then report verified deletion. Pending/failed/denied states are errors, never success.
8. List retained IAM roles/policies, S3 bucket/objects and CloudWatch logs; they are not deleted and may continue to cost money. Do not silently broaden agent deletion into infrastructure cleanup.

Deletion never removes accounts, models, roles, buckets, logs, credentials or unrelated resources.
Do not automatically replay uncertain mutations.
