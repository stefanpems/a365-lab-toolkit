// ============================================================================
// Runtime configuration for the Agent Framework Agents UI.
// One vertical tab is rendered per entry in "agents".
// Each agent needs its Container App base URL and the Entra scope used to call it.
// ============================================================================
window.APP_CONFIG = {
  msal: {
    // SPA app registration "agentframework-ui-spa"
    clientId: "f9fe265c-5fc4-4a4e-8885-600746b05542",
    authority: "https://login.microsoftonline.com/863ee9e2-ebff-43d4-a0c8-4f224aefc536"
  },
  agents: [
    {
      id: "s2s",
      kind: "aca",
      name: "AgentFrameworkS2SSample (ACA, S2S)",
      description: "S2S blueprint agent. The /chat endpoint validates the user's Entra token and replies via the LLM.",
      apiBase: "https://agentframework-s2s-sample.thankfulcoast-e0e43978.polandcentral.azurecontainerapps.io",
      scope: "api://894f3b9c-aa7b-450d-b3c4-20bf5c931022/access_agent_as_user"
    },
    {
      id: "obo",
      kind: "aca",
      name: "AgentFrameworkSample (ACA, OBO)",
      description: "OBO agent. /chat uses the user's delegated Mail token and sends email from their mailbox.",
      apiBase: "https://agentframework-sample.icybush-c1787b58.polandcentral.azurecontainerapps.io",
      scope: "ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/McpServers.Mail.All"
    },
    {
      // Foundry Hosted Agent (OBO) — Invocations protocol.
      // Two tokens: `endpointScope` authenticates the call to the Foundry gateway
      // (Authorization header); `mailScope` is the delegated Mail token sent in the
      // body as `mail_token` so the agent sends mail from the signed-in user's mailbox.
      id: "obo-fh",
      kind: "foundry-invocations",
      name: "OBO Foundry Hosted (invocations)",
      description: "Foundry Hosted Agent (OBO). Gateway auth + mail_token in the body; sends email from your mailbox.",
      endpoint: "https://cog-z2qo7tuwnjouk.services.ai.azure.com/api/projects/agent365-obo-agentframeworkfh-py/agents/agentframeworkFH-OBO-agent/endpoint/protocols/invocations?api-version=v1",
      endpointScope: "https://ai.azure.com/.default",
      mailScope: "ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/McpServers.Mail.All",
      // Prefix for a PER-USER server session id (see app.js). Foundry sessions are bound
      // to the identity that created them, so a fixed/shared id causes
      // "session_not_accessible" (403) for other users.
      sessionPrefix: "obo"
    },
    {
      // Foundry Hosted Agent (S2S) — Responses protocol (OpenAI-compatible /responses).
      // Acts with its OWN identity: one token (endpointScope) authenticates to the Foundry
      // gateway; no user/mail token. Body: { input }  ->  output[].content[].text.
      id: "s2s-fh",
      kind: "foundry-responses",
      name: "S2S Foundry Hosted (responses)",
      description: "Foundry Hosted Agent (S2S). Its own identity; conversational assistant.",
      endpoint: "https://cog-iodjlgvedslrg.services.ai.azure.com/api/projects/agent365-s2s-agentframeworkfh-py/agents/agentframeworkFH-S2S-agent/endpoint/protocols/openai/responses?api-version=v1",
      endpointScope: "https://ai.azure.com/.default"
    },
    {
      // Foundry DECLARATIVE (prompt) agent — OBO.
      // Not a hosted container: the agent is a platform-run prompt agent (model +
      // instructions + Mail MCP tool). Invoked via the PROJECT-level Responses API with an
      // `agent_reference` in the body. The Mail MCP Authorization header is a template
      // resolved per request from the `mail_token` structured input, so mail is sent from
      // the signed-in user's mailbox (OBO).
      //   endpoint = {project_endpoint}/openai/v1/responses
      //   body     = { input, agent_reference, structured_inputs: { mail_token } }
      id: "obo-fd",
      kind: "foundry-prompt",
      name: "OBO Foundry Declarative (prompt agent)",
      description: "Foundry prompt agent (OBO). Project Responses API + agent_reference; the Mail token is passed as a structured input and email is sent from your mailbox.",
      endpoint: "https://cog-z2qo7tuwnjouk.services.ai.azure.com/api/projects/agent365-obo-agentframeworkfh-py/openai/v1/responses",
      endpointScope: "https://ai.azure.com/.default",
      agentName: "agentframeworkFD-OBO-agent",
      mailScope: "ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/McpServers.Mail.All"
    },
    {
      // Foundry DECLARATIVE (prompt) agent — S2S (own identity).
      // Same project Responses API + agent_reference, but NO mail token: the agent acts with
      // its own identity and has no Mail tool (a pure S2S identity cannot use the delegated
      // Mail MCP). callFoundryPrompt still passes the signed-in user's verified profile in
      // `input` so the agent can personalize replies / answer "who am I".
      id: "s2s-fd",
      kind: "foundry-prompt",
      name: "S2S Foundry Declarative (prompt agent)",
      description: "Foundry prompt agent (S2S). Own identity; conversational assistant, no mailbox access.",
      endpoint: "https://cog-z2qo7tuwnjouk.services.ai.azure.com/api/projects/agent365-obo-agentframeworkfh-py/openai/v1/responses",
      endpointScope: "https://ai.azure.com/.default",
      agentName: "agentframeworkFD-S2S-agent"
    }
  ]
};
