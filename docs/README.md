# Agent 365 × Agent Framework — sample agents documentation

Documentation for a family of test agents built on the **Microsoft Agent Framework** and
integrated with **Microsoft Agent 365**, spanning three authentication models (OBO, S2S,
Digital Worker) across three hosting/dev models: **Azure Container Apps (ACA)**, **Foundry
Hosted (FH)**, and **Foundry Declarative / prompt agents (FD)**.

## Start here

- **[00-introduction.md](00-introduction.md)** — concepts, naming convention, capability
  comparison, architectures, Tool Gateway integration, observability, governance & security,
  and the mapping to the reference implementation.

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
| MAF-FD-DW | Foundry Declarative (prompt agent → autopilot) | Digital Worker | [setup-MAF-FD-DW.md](setup-MAF-FD-DW.md) |

## Web UI

The OBO and S2S agents (ACA, Foundry Hosted, and Foundry Declarative) are exercised from the
MSAL web SPA in `ui/`. Digital Workers are used directly from Teams / Outlook / Office.

- **[setup-web-ui.md](setup-web-ui.md)** — deploy and configure the web SPA (app registration,
  Entra consent, Azure RBAC, `config.js`, Static Web Apps deploy).
