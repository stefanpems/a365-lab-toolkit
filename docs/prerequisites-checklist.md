# Central prerequisites checklist

Use this checklist before deploying the solution into a new Microsoft 365 tenant and Azure
subscription. It consolidates the prerequisites from the individual setup guides; those guides
remain the source for the deployment steps themselves.

This document deliberately distinguishes:

- **pre-existing prerequisites**, which must be ready before a deployment starts;
- **resources created by the deployment**, which are listed separately and must not be
  mistaken for pre-existing dependencies;
- **deployment operator permissions** from permissions later assigned to end users or agent
  identities.

## Scope legend

| Scope | Agent types |
| --- | --- |
| **ALL** | All nine agent variants |
| **ACA** | MAF-ACA-OBO, MAF-ACA-S2S, MAF-ACA-DW |
| **FH** | MAF-FH-OBO, MAF-FH-S2S, MAF-FH-DW |
| **FD** | MAF-FD-OBO, MAF-FD-S2S, MAF-FD-DW |
| **OBO** | MAF-ACA-OBO, MAF-FH-OBO, MAF-FD-OBO |
| **S2S** | MAF-ACA-S2S, MAF-FH-S2S, MAF-FD-S2S |
| **DW** | MAF-ACA-DW, MAF-FH-DW, MAF-FD-DW |
| **Web UI** | Optional SPA used with OBO and S2S agents; not used by DW agents |

When a row names a more specific scope, that scope takes precedence over these groups.

## 0. Target environment and deployment choices

- [ ] **[ALL]** Record the target Microsoft Entra tenant ID and primary domain.
- [ ] **[ALL]** Record the target Azure subscription ID and confirm that it belongs to the
  intended tenant.
- [ ] **[ALL]** Select the agent variants to deploy; do not assume that all nine variants are
  required.
- [ ] **[ALL]** Choose resource names and one or more supported Azure regions. Values embedded
  in the setup guides are examples from the original lab and must not be reused blindly.
- [ ] **[FH, FD]** Choose a neutral Foundry account/project name. One project can host FH and
  FD agents across authentication models; only agent names should contain `FH`, `FD`, `OBO`,
  `S2S`, or `DW`.
- [ ] **[Web UI]** Decide whether to deploy the optional SPA. DW agents are consumed through
  Teams, Outlook, or Office and do not use it.

## 1. Local tools on the deployment workstation

### Required by all selected variants

- [ ] **[ALL]** Git is installed and the repository is cloned locally.
- [ ] **[ALL]** PowerShell 5.1 or later is available. PowerShell 7 is recommended for the
  scripts and commands in this repository.
- [ ] **[ALL]** Azure CLI (`az`) is installed and can authenticate explicitly to the target
  tenant and subscription.
- [ ] **[ALL]** Python is installed. Use **Python 3.12+** for ACA and **Python 3.13+** for FH;
  the FD requirements are compatible with the Python versions supported by their pinned SDKs.

### Variant-specific tools

- [ ] **[ACA]** Agent 365 CLI (`a365`), version 1.1.x or later, is installed.
- [ ] **[ACA]** A compatible .NET runtime for `a365` is installed.
- [ ] **[ACA]** `uv` is installed and available on `PATH`.
- [ ] **[FH]** Azure Developer CLI (`azd`) is installed.
- [ ] **[FH-OBO, FH-S2S]** The `microsoft.foundry` extension is installed for `azd`.
- [ ] **[FH]** Both `az login` and `azd auth login` can be completed. They use separate token
  stores.
- [ ] **[FH-DW]** Docker is available only if optional local `azd ai agent` commands will be
  used. The normal image build runs in Azure Container Registry.
- [ ] **[FD]** `venv` and `pip` are available; install each variant's `requirements.txt` in a
  dedicated virtual environment.
- [ ] **[Web UI]** Node.js and `npx` are installed for the Azure Static Web Apps CLI.
- [ ] **[Optional local ACA test]** VS Code with the Python Debugger and Microsoft 365 Agents
  Playground support is available.

### Authentication sanity check

- [ ] **[ALL]** Before any provisioning command, verify the active identity, tenant, and
  subscription with `az account show`.
- [ ] **[FH]** Verify the active `azd` environment and authentication separately from Azure
  CLI authentication.
- [ ] **[ALL]** Do not store client secrets, model keys, generated tenant configuration, or
  deployment tokens in tracked files.

## 2. Licenses and tenant features

- [ ] **[DW] Mandatory** The target tenant is enrolled in the Frontier program.
- [ ] **[DW] Mandatory** A Global Administrator has accepted the Agent 365 terms of service
  in the Microsoft 365 admin center.
- [ ] **[ACA-DW, FH-DW] Mandatory** The tenant has at least one Microsoft 365 Copilot or
  Microsoft Agent 365 entitlement, including an eligible M365 E7 / Frontier Suite offer.
- [ ] **[ACA-DW, FH-DW] Mandatory per instance** Capacity is available for the Agent 365 /
  `Frontier for AI Teammates` license assigned through the AI-teammate policy template.
- [ ] **[FD-DW] Mandatory per instance** Capacity is available for `Microsoft 365 Frontier
  for Autopilot`, assigned by the own-identity policy template during approval.
- [ ] **[DW] Recommended for full functionality** Confirm the required Microsoft 365 E5,
  Teams Enterprise, and Microsoft 365 Copilot entitlements for the intended mailbox, Teams,
  OneDrive, and Copilot experience.
- [ ] **[OBO, S2S]** No Frontier enrollment or agent-user license is required.

> DW licenses are assigned to agent instances from **Agents / Registry / Instances**, or by
> the approval policy template. They are not assigned under **Users / Active users**.

## 3. Cloud resources and subscription readiness

### Subscription and providers

- [ ] **[ALL]** The target Azure subscription is active, has sufficient quota, and permits
  resource creation in the selected regions.
- [ ] **[ACA]** Resource providers `Microsoft.App`, `Microsoft.ContainerRegistry`, and
  `Microsoft.OperationalInsights` can be registered in the subscription.
- [ ] **[FH, FD]** Resource providers `Microsoft.CognitiveServices` and
  `Microsoft.MachineLearningServices` can be registered in the subscription.
- [ ] **[FH-DW, FD-DW]** Resource provider `Microsoft.BotService` can be registered.
- [ ] **[FH]** The selected region supports Foundry hosted agents and the required model.
- [ ] **[ACA]** The selected region has Azure Container Apps environment capacity.

Provider registration is a subscription change. It can be performed during setup only by an
identity that has the corresponding permission; otherwise a subscription administrator must
register the providers beforehand.

### Pre-existing services

- [ ] **[ACA] Mandatory** An Azure OpenAI resource and compatible Chat Completions model
  deployment exist. Record endpoint, deployment name, API version, and a supported
  authentication credential. The current ACA scripts consume an API key.
- [ ] **[FH-OBO, FH-S2S] Mandatory unless provisioning a new project** A Foundry account and
  project are selected. A compatible chat model such as `gpt-4.1` must be deployable; the
  model can be deployed between `azd provision` and `azd deploy`.
- [ ] **[FD] Mandatory** A Foundry account/project with a deployed compatible chat model
  already exists. The FD scripts create agent definitions, not the account, project, or model.
- [ ] **[ACA-S2S, ACA-DW] Current-script dependency** A Log Analytics workspace exists and
  its resource group/name are configured in `deploy-aca-S2S.ps1` or `deploy-aca-DW.ps1`.
  Alternatively, adapt the scripts to create a workspace or use no-log mode before deploying
  into a clean subscription.
- [ ] **[Web UI]** Decide whether to reuse an Azure Static Web App or create one during setup.
  No pre-existing Static Web App is required.

### Resources created by the deployment

The following are normally outputs of the setup, not prerequisites:

| Scope | Resources normally created |
| --- | --- |
| ACA | Resource group, Container Apps environment, Container Registry/build, Container App |
| FH-OBO / FH-S2S | Foundry hosted agent and versions; `azd provision` can create/select supporting Foundry resources |
| FH-DW | Foundry account/project, model deployment, ACR, Bot Service, monitoring, identities, hosted agent |
| FD-OBO / FD-S2S | Prompt-agent definition/version in the selected existing Foundry project |
| FD-DW | Prompt-agent version and Bot Service; the Foundry project/model must already exist |
| Web UI | SPA app registration and, when selected, Azure Static Web App |

## 4. Permissions in the target tenant

This section concerns Microsoft Entra and Microsoft 365 permissions. Azure RBAC is listed in
the next section.

### Deployment operator and admin participation

- [ ] **[ACA]** The operator has **Agent ID Developer**, or equivalent rights, to create and
  manage agent blueprints.
- [ ] **[ACA]** A **Global Administrator** is available for all organization-wide admin
  consent prompts. Using a Global Administrator as the operator satisfies both requirements
  but is not required for every command.
- [ ] **[FH-DW, FD-DW]** A tenant administrator is available to approve and activate the
  published Digital Worker in the Microsoft 365 admin center.
- [ ] **[DW]** A Global Administrator is available to accept the Agent 365 terms, apply the
  own-identity policy template, accept permissions, and authorize instance creation.
- [ ] **[FH-DW]** The deployment identity can add itself as an owner of the generated
  blueprint application and create the OAuth2 grants used by the post-provision scripts, or a
  tenant administrator will perform those actions.
- [ ] **[FH-DW]** The operator can configure the blueprint's Bot ID in the Teams Developer
  Portal.

### Agent and application consent

- [ ] **[ACA-OBO, ACA-DW]** Admin consent can be granted for the blueprint permissions created
  by `a365 setup permissions mcp` and `a365 setup permissions bot`, including Agent 365 Tools,
  Messaging Bot, Observability, Graph/Power Platform permissions used by the sample.
- [ ] **[ACA-S2S]** Admin consent can be granted for the inheritable application permissions
  configured by `a365 setup all --authmode s2s --m365`.
- [ ] **[OBO using Mail]** Delegated Agent 365 Tools permission `McpServers.Mail.All` is
  available and admin-consented for the client that obtains the user's token.
- [ ] **[S2S using an optional Work IQ tool] Conditional** The target tool exposes an
  application app role, that role is assigned to the agent/blueprint service principal, and
  admin consent is granted. The sample S2S agents do not require Mail and run without it.
- [ ] **[S2S sending mail] Conditional** An application access policy authorizes the sender
  mailbox in addition to the tool/API application permission.
- [ ] **[FH, FD, optional Agent 365 telemetry]** The
  `Agent365.Observability.OtelWrite` app role can be assigned to the generated Foundry agent
  identity service principal.

### Optional Web UI application

- [ ] **[Web UI]** A single-page application registration exists in the target tenant with
  the local and deployed redirect URIs.
- [ ] **[Web UI]** Microsoft Graph `openid profile offline_access` has an explicit
  AllPrincipals grant where tenant user-consent policy requires it.
- [ ] **[Web UI + FH/FD]** Azure Machine Learning Services `user_impersonation` is configured
  and admin-consented for `https://ai.azure.com/.default`.
- [ ] **[Web UI + OBO Mail]** Agent 365 Tools `McpServers.Mail.All` is configured and
  admin-consented.
- [ ] **[Web UI + ACA-OBO]** The ACA OBO delegated scope is configured and consented.
- [ ] **[Web UI + ACA-S2S]** `api://<s2s-app-id>/access_agent_as_user` is configured and
  consented.

## 5. Permissions in the Azure subscription

### Deployment operator

- [ ] **[ACA-OBO, ACA-S2S, ACA-DW]** The operator has **Contributor** on the target
  subscription or intended resource groups. Additional rights are needed if the operator must
  create role assignments or register providers and those actions are not delegated
  separately.
- [ ] **[FH-OBO, FH-S2S]** The operator has **Foundry Project Manager** for deployment and
  sufficient rights to create or select the supporting Azure resources.
- [ ] **[FH-DW]** The operator has **Owner** on the target subscription, as required by the
  current Bicep/post-provision flow to create resources and role assignments.
- [ ] **[FD-OBO, FD-S2S]** The operator has **Foundry User** on the project and **Cognitive
  Services User** on the Foundry account.
- [ ] **[FD-DW]** The operator has **Foundry User** on the project and **Azure Bot Service
  Contributor**, Contributor, or Owner on the resource group that contains the Foundry
  account.
- [ ] **[Provider registration]** The operator has `*/register/action` for each required
  resource provider, or an administrator has registered the providers in advance.

### Runtime and invoking identities

- [ ] **[FH-OBO]** Users who invoke the Invocations endpoint are members of a group assigned
  **Cognitive Services User** on the Foundry account.
- [ ] **[FH-S2S]** Users who invoke the Responses endpoint are members of a group assigned
  **Foundry Project Runtime User** or **Cognitive Services User** on the Foundry account.
- [ ] **[FD]** Users or automation identities that invoke prompt agents have **Cognitive
  Services User** on the Foundry account.
- [ ] **[FH-DW]** The Bicep/post-provision identity is allowed to create role assignments;
  the deployment grants ACR Pull and Cognitive Services User to generated identities.
- [ ] **[Web UI + FH/FD]** End users are in the Azure RBAC access group for the Foundry
  account. Entra consent alone does not authorize Foundry invocation.

## 6. Current portability decisions to resolve before a clean-tenant deployment

These are implementation assumptions in the current repository, not platform prerequisites:

- [ ] Parameterize or replace lab-specific tenant IDs, subscription IDs, resource names,
  regions, endpoints, and model names in configuration files and scripts.
- [ ] Decide whether ACA-S2S and ACA-DW should create their own Log Analytics workspace,
  accept one as a parameter, or use the ACA-OBO no-log pattern.
- [ ] Review the destructive behavior of `aca/obo/deploy-aca.ps1`: it deletes its configured
  resource group before recreation. Use a dedicated resource group and explicit target
  subscription.
- [ ] Reset generated `a365.generated.config.json` state before creating blueprints in the
  new tenant, and never reuse secrets from the original tenant.
- [ ] Replace API keys and client secrets with the target environment's credentials; keep
  them outside Git.
- [ ] Confirm model availability and quota in the selected region before selecting deployment
  names or capacities.

## Source guides

- [MAF-ACA-OBO](setup-MAF-ACA-OBO.md), [MAF-ACA-S2S](setup-MAF-ACA-S2S.md),
  [MAF-ACA-DW](setup-MAF-ACA-DW.md)
- [MAF-FH-OBO](setup-MAF-FH-OBO.md), [MAF-FH-S2S](setup-MAF-FH-S2S.md),
  [MAF-FH-DW](setup-MAF-FH-DW.md)
- [MAF-FD-OBO](setup-MAF-FD-OBO.md), [MAF-FD-S2S](setup-MAF-FD-S2S.md),
  [MAF-FD-DW](setup-MAF-FD-DW.md)
- [Web UI](setup-web-ui.md)