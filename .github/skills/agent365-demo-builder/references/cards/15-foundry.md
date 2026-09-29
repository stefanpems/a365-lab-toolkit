# Foundry prompt agent

Portal: https://ai.azure.com, the Foundry project of the lab. The Lab Builder deploys **{agent:applicationReview}**
(FD-OBO) with its knowledge files and tools from the demo overlay; this card only checks it and adds what is done in
the portal. Reference: docs/setup-MAF-FD-OBO.md.

## 1. Check the agent

Project > Agents > **{agent:applicationReview}**:

- Knowledge (file search): the three fictional cases and "{{knowledge.documents.reviewProcedure.file}}".
- Tools: the Microsoft Learn MCP server **without** an allowed-tools list. This is a deliberate weakness (D14): do not
  restrict it.
- Instructions: the role prompt of the overlay (demo language).

## 2. Guardrail (D14)

The agent's guardrail deliberately lacks the jailbreak control (weakness shown in D14): keep the guardrail the
reference lab uses and do not add that control. The live demo shows the finding; do not fix it before the run.

## 3. Publish and first use

Publish the agent as described in docs/setup-MAF-FD-OBO.md, then run its tests from the hand-out (web UI tab,
{name:maker}). If the first call fails once with a transient HTTP 400 (an invented tool argument), retry it.
