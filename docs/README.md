# Agent 365 × Agent Framework — sample agents documentation

> **Before starting any setup:** read and complete the
> **[central prerequisites checklist](prerequisites-checklist.md)** for the target tenant,
> Azure subscription, and deployment workstation.

Documentation for a family of test agents built on the **Microsoft Agent Framework** and
integrated with **Microsoft Agent 365**, spanning three authentication models (OBO, S2S,
Digital Worker) across three hosting/dev models: **Azure Container Apps (ACA)**, **Foundry
Hosted (FH)**, and **Foundry Declarative / prompt agents (FD)**.

This README is the documentation entry point. The introduction is a deeper architecture and
concepts reference, not a competing entry page.

## Recommended reading order

1. **[Central prerequisites checklist](prerequisites-checklist.md)** — validate a new tenant,
   subscription, deployment workstation, licenses, and permissions; each requirement states
   which agent variants it applies to.
2. **[Introduction and architecture reference](00-introduction.md)** — understand the
   hosting/authentication models, capabilities, identity flows, Tool Gateway, observability,
   governance, and security.
3. Choose only the agent variants you need from the setup-guide table below.
4. If required, deploy the optional **[Web UI](setup-web-ui.md)** after its OBO/S2S agents.

## Documentation map

- **[prerequisites-checklist.md](prerequisites-checklist.md)** — central, scoped readiness
  checklist for clean-tenant deployments.
- **[00-introduction.md](00-introduction.md)** — conceptual and architectural reference.

## Setup guides (one per agent type)

| Type | Hosting | Auth | Guide |
| --- | --- | --- | --- |
| MAF-ACA-OBO | Azure Container Apps | On-Behalf-Of | [setup-MAF-ACA-OBO.md](setup-MAF-ACA-OBO.md) |
| MAF-ACA-S2S | Azure Container Apps | Service-to-Service | [setup-MAF-ACA-S2S.md](setup-MAF-ACA-S2S.md) |
| MAF-ACA-DW | Azure Container Apps | Digital Worker (AI teammate) | [setup-MAF-ACA-DW.md](setup-MAF-ACA-DW.md) |
| MAF-FH-OBO | Foundry Hosted | On-Behalf-Of (Invocations) | [setup-MAF-FH-OBO.md](setup-MAF-FH-OBO.md) |
| MAF-FH-S2S | Foundry Hosted | Service-to-Service (Responses) | [setup-MAF-FH-S2S.md](setup-MAF-FH-S2S.md) |
| MAF-FH-DW | Foundry Hosted (container + Bot Service) | Digital Worker (AI teammate) | [setup-MAF-FH-DW.md](setup-MAF-FH-DW.md) |
| MAF-FD-OBO | Foundry Declarative (prompt agent) | On-Behalf-Of | [setup-MAF-FD-OBO.md](setup-MAF-FD-OBO.md) |
| MAF-FD-S2S | Foundry Declarative (prompt agent) | Service-to-Service | [setup-MAF-FD-S2S.md](setup-MAF-FD-S2S.md) |

> **⛔ MAF-FD-DW is not available (platform limitation).** A Foundry **prompt/declarative agent
> cannot be published as an Agent 365 autopilot Digital Worker**; a hired instance is permanently
> silent in Teams by design. Per Microsoft Learn, **only Foundry _hosted_ agents can be published as
> autopilot blueprints**
> ([Supported agent types](https://learn.microsoft.com/azure/foundry/agents/concepts/agent-365-integration#supported-agent-types)).
> Use **[MAF-FH-DW](setup-MAF-FH-DW.md)** for a Teams Digital Worker; a declarative agent remains fully
> usable through the Responses API ([MAF-FD-OBO](setup-MAF-FD-OBO.md), [MAF-FD-S2S](setup-MAF-FD-S2S.md)).

## Web UI

The OBO and S2S agents (ACA, Foundry Hosted, and Foundry Declarative) are exercised from the
MSAL web SPA in `ui/`. Digital Workers are used directly from Teams / Outlook / Office.

- **[setup-web-ui.md](setup-web-ui.md)** — deploy and configure the web SPA (app registration,
  Entra consent, Azure RBAC, `config.js`, Static Web Apps deploy).
