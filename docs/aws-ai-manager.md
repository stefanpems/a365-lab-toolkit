# AWS AI Manager

The [AWS AI Manager](../.github/agents/aws-ai-manager.agent.md) custom agent manages AWS agents
from GitHub Copilot using the same create/test/delete workflow as Google AI Manager, plus a
guided setup for a brand-new AWS account.

## Capabilities

- Discover agents from complete console URLs, ARNs or exact scoped names.
- Send a requested number of prompts and show every complete reply; optionally check expected text.
- Create a managed Python Bedrock Converse assistant on **Amazon Bedrock AgentCore Runtime**.
- Create/test/delete **Bedrock Agents Classic** agents for existing eligible AWS customers.
- Preview a scoped execution role and private encrypted/versioned artifact bucket for first use.
- Use isolated interactive external Edge sign-in or a dedicated temporary-credentials file.
- Preview and confirm mutations, persist private operation journals, refuse unmanaged deletion,
  and verify the resulting AWS state.

**Important:** AWS closed Bedrock Agents Classic to new customers on **July 30, 2026**.
For an account created after that date, use AgentCore. Classic compatibility does not grant
entitlement, and Amazon Bedrock foundation models remain available independently of Classic.

## Starting with only an AWS account

If you are looking at **Welcome to AWS! / Get started by connecting your agent**, begin with
[A1: leave the welcome screen and identify your account](#a1-dismiss-the-welcome-screen-and-find-the-account-id).
The [step-by-step appendices](#appendix-aws-console-walkthroughs) were last updated on **2026-11-02**.
They distinguish the new project-based AWS experience from accounts created using the advanced
sign-up flow; the root-user, IAM-user and region-selection steps are not interchangeable.

1. **Secure the account.** Follow [A2: enable MFA](#a2-enable-mfa-for-the-correct-identity) and
   [A3: use a non-root operator](#a3-confirm-or-create-a-non-root-operator). New-experience projects
   use AWS Builder ID, not a root console login. For an account with a root identity, protect it
   with MFA and reserve it for account administration. Never create root access keys or paste
   passwords, access keys or session tokens into chat.
2. **Review billing.** Confirm the account is active and eligible for the selected services.
   Follow [A4: inspect credits and configure cost controls](#a4-review-billing-and-configure-cost-controls).
   Budget email alerts are not hard spending caps; new-experience project spend limits are a
   separate control. Runtime, inference, S3 and logs can incur charges.
3. **Confirm the region deliberately.** Follow
   [A6: find the region and check availability](#a6-confirm-the-region-and-choose-a-text-model).
   A new-experience project has an assigned region; do not activate advanced features merely to
   change it. AgentCore and the selected model must both be available in the agreed region.
   Cross-region routing is not supported by the new experience without advanced features and,
   where supported, needs separate acknowledgement.
4. **Select AWS AI Manager** in the agent picker and say:
   `Set up AWS AI Manager from a new account.`
   See [A7: the guided manager workflow](#a7-run-the-manager-with-separate-approvals).
   The wizard checks Python/SDK prerequisites before asking for unexplained resource identifiers.
5. **Choose authentication.** Prefer console login in your explicitly confirmed existing external
   Edge Work profile. Follow [A5: prepare isolated authentication](#a5-prepare-isolated-authentication),
   including AWS CLI v2.32.0+ and, for an IAM console identity, `SignInLocalDevelopmentAccess`.
   Install the CLI only after reviewing the request
   (Windows package: `winget install --id Amazon.AWSCLI -e`). The optional AWS Agent Toolkit is not required.
6. **If you use an IAM Identity Center access portal**, follow
   [A5's temporary-credentials procedure](#a5-prepare-isolated-authentication) instead of assuming
   that a standard portal session supports console `aws login`. Do not confuse this flow with
   AWS Builder ID project sign-in, or configure shared SSO caches as a workaround.
7. **Verify identity and model.** Supply the expected 12-digit account ID from
   [A1](#a1-dismiss-the-welcome-screen-and-find-the-account-id) and the region/model from
   [A6](#a6-confirm-the-region-and-choose-a-text-model), then use read-only account/model discovery.
   Prefer an available on-demand Amazon text model compatible with Converse for the first agent.
   Third-party providers can have agreements, marketplace permissions or use-case forms;
   these are never accepted automatically.
8. **Review initial setup.** Follow [A7](#a7-run-the-manager-with-separate-approvals).
   The wizard shows the exact new role/trust/model permissions and,
   for AgentCore, private same-region deployment bucket. It does not alter preexisting resources.
   An operator with sufficient IAM/service/S3 permissions must approve this one-time setup.
9. **Approve creation separately.** Continue with [A7](#a7-run-the-manager-with-separate-approvals).
   Review the name/model/instructions, expected costs and
   generated private specification, then confirm the exact name. The manager packages only
   its committed assistant and pinned ARM64 dependencies. No Docker or container registry is needed.
10. **Test and clean up deliberately.** Send a small requested batch, read every reply, then
    preview deletion when finished, as described in [A7](#a7-run-the-manager-with-separate-approvals).
    Agent deletion retains IAM/S3/log infrastructure and its possible storage charges;
    it is not an account-wide cleanup.

No AWS resource is provisioned merely by installing or creating this custom agent.
No shared default AWS/GitHub/Azure/Google authentication context is changed.

### Finding the first inputs

- **Welcome screen:** close the optional toolkit walkthrough to reach the normal AWS console.
  Follow [A1](#a1-dismiss-the-welcome-screen-and-find-the-account-id); no toolkit connection is necessary.
- **Account ID:** use the account menu or the project's **Additional info** page in AWS Settings.
  [A1](#a1-dismiss-the-welcome-screen-and-find-the-account-id) covers both paths.
  The script compares the 12-digit value with the authenticated identity.
- **MFA:** use AWS Settings for AWS Builder ID, or **Security credentials** for a root identity.
  Follow the matching branch in [A2](#a2-enable-mfa-for-the-correct-identity).
- **Non-root console identity:** new-experience users already access projects through roles.
  IAM console-user creation is an alternative only for accounts that support it.
  [A3](#a3-confirm-or-create-a-non-root-operator) explains the choices and permission implications.
  The manager does not attach administrator policies or grant itself additional permissions.
- **Region:** find the project's assigned region, or use the region selector where available.
  [A6](#a6-confirm-the-region-and-choose-a-text-model) explains how to keep it consistent through
  discovery, setup and creation. Do not copy a region merely from a documentation example.
- **First model:** the wizard's read-only `models` command lists regional text models and
  inference profiles; follow [A6](#a6-confirm-the-region-and-choose-a-text-model) instead of guessing
  an ID. Model access, IAM permission and model price are separate concerns.
- **Role and bucket:** no ARN knowledge is needed for the first AgentCore agent. The separately
  approved setup generates their names and returns a ready-to-use private creation specification;
  see [A7](#a7-run-the-manager-with-separate-approvals).
- **Existing agent:** navigate to **Amazon Bedrock AgentCore > Runtime**, open the agent details
  and copy the complete browser URL. For an eligible Classic account, open
  **Amazon Bedrock > Agents**, select the agent and optionally its published alias.
  Follow [A8](#a8-copy-an-existing-agent-url) if you are unfamiliar with service navigation.

## Skills and scripts

| Workflow | Skill |
|---|---|
| New-account onboarding and prerequisites | [aws-ai-agent-setup](../.github/skills/aws-ai-agent-setup/SKILL.md) |
| Create a managed AWS agent | [aws-ai-agent-create](../.github/skills/aws-ai-agent-create/SKILL.md) |
| Send prompts and show full replies | [aws-ai-agent-test-prompts](../.github/skills/aws-ai-agent-test-prompts/SKILL.md) |
| Delete one managed AWS agent | [aws-ai-agent-delete](../.github/skills/aws-ai-agent-delete/SKILL.md) |

The [operator guide](../.github/skills/aws-ai-agent-test-prompts/references/operator-guide.md)
contains the complete PowerShell examples, authentication model, setup/create/send/delete commands,
confirmation contract, supported response shapes, costs and offline validation command.

The shared [AWS CLI script](../.github/skills/aws-ai-agent-test-prompts/scripts/aws_ai_agents.py)
provides `check-account`, `models`, `list`, `setup`, `create`, `send` and `delete`.
The [environment helper](../.github/skills/aws-ai-agent-test-prompts/scripts/aws_ai_environment.py)
provides local `check` and isolated interactive `browser` sign-in.

## Permissions and limits

Initial setup needs permission to create the specifically previewed IAM execution role/inline policy
and S3 bucket/security settings. Creation needs the relevant agent APIs, resource tagging, scoped
`iam:PassRole`, IAM role inspection, and S3 artifact access for AgentCore. Discovery needs list/get
permissions; sending needs the selected invocation API; deletion needs the exact delete/tag/list/get APIs.
Generated execution policies restrict inference to the selected model/profile and, for AgentCore,
deployment reads and runtime logs. They do not grant the operator administrator access.

The manager does not automatically grant its operator permissions, change organizational SCPs,
accept provider terms, request quotas, enable regions or subscriptions, create users/keys, deploy
AgentCore Harness, register agents in AWS Agent Registry, attach tools/knowledge bases, or manage
Agent 365 integration. Errors remain visible for an administrator to resolve.

## Official AWS references

- [Classic maintenance mode and new-customer restriction](https://docs.aws.amazon.com/bedrock/latest/userguide/agents-classic-maintenance-mode.html)
- [AgentCore supported regions](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agentcore-regions.html)
- [AgentCore Python direct deployment](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-get-started-code-deploy-python.html)
- [AgentCore execution permissions](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-permissions.html)
- [Console credentials for local development and isolated login cache](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html)
- [Bedrock model availability API](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_GetFoundationModelAvailability.html)
- [AgentCore pricing](https://aws.amazon.com/bedrock/agentcore/pricing/)
- [Bedrock model pricing](https://aws.amazon.com/bedrock/pricing/)

## Appendix: AWS console walkthroughs

**Last updated: 2026-11-02.** Navigation was checked against the official AWS documentation linked
below, not against a live authenticated console session. AWS can change labels and screen layouts;
available pages also depend on sign-up type, account plan and permissions.

Use external Microsoft Edge with your existing, explicitly confirmed Work profile for all browser
steps. Sign in interactively; never send passwords, MFA codes, QR codes, access keys or session
tokens to the manager. These instructions describe actions for you to review and perform; reading
them does not authorize the manager to change your account.

If a named control is missing, first check which account experience you are using. Do not upgrade
your plan, activate advanced features, subscribe to a model or broaden permissions just to make a
screen match this guide. In particular, activating advanced features removes existing project
spend limits and changes account administration.

### A1. Dismiss the welcome screen and find the account ID

**Last updated: 2026-11-02.**

1. Open the [AWS Management Console](https://aws.amazon.com/console/) in external Edge Work.
   Choose **Sign in to the Console** if you are not already signed in, and use your existing login.
2. If the **Welcome to AWS!** overlay offers **Copy Agent Toolkit setup prompt**, close the overlay
   using the **X** in its upper-right corner. You do not need to copy the prompt, install Kiro,
   connect an agent or complete **Next: your first project** to use this manager.
3. Open the account/project menu at the top right. If it offers **Manage projects**, choose it
   to open [AWS Settings](https://settings.aws.com). This is the new project-based experience:
   - Select your existing project to open its details.
   - In **Overview**, expand **Additional info**.
   - Copy the 12-digit **Account ID** and record **Region**, including its code, such as `eu-north-1`.
   - Your project name, AWS Builder ID email and organization ID are not the account ID.
4. For the advanced/traditional console, copy the 12-digit number next to **Account** in the
   account menu. If necessary, choose **Security credentials** and look under
   **Account details > AWS account ID**. A federated role might not have a **Security credentials**
   entry; use the **Account** number instead.
5. Record whether you use AWS Builder ID/project access, an IAM user, an IAM Identity Center
   access portal, another federated role, or root. A project owner can have administrator
   permissions without being the root user. Do not infer identity type from the welcome overlay alone.

**Checkpoint:** you have the intended project's/account's 12-digit ID and know which sign-in
branch to follow. No new project or AWS resource was needed.

AWS references: [find account identifiers](https://docs.aws.amazon.com/accounts/latest/reference/manage-acct-identifiers.html),
[new AWS experience](https://docs.aws.amazon.com/accounts/latest/reference/sign-in-new.html).

### A2. Enable MFA for the correct identity

**Last updated: 2026-11-02.**

AWS recommends phishing-resistant passkeys/security keys where possible. The concrete
authenticator-app paths below are an alternative; keep a second recovery method in a secure place.

#### New experience: protect AWS Builder ID

If you sign in with **Continue with Google**, **Apple**, **GitHub** or **Amazon**, secure that
provider's sign-in using its MFA procedure instead; the AWS reference below links to each provider's
instructions. For AWS Builder ID email/password sign-in, follow these steps:

1. Open [AWS Settings](https://settings.aws.com).
2. In the navigation pane, choose **Manage security and sign-in**. AWS redirects you to your
   AWS Builder ID profile; open **Security** if it is not already selected.
3. Choose **Register device**, then **Authenticator app**. Alternatively, choose **Security key**
   and follow the operating-system prompts for your supported device.
4. For an authenticator app, choose **Show QR code**, open your phone's authenticator app,
   add an account and scan the code. Keep the QR code and secret key private.
5. Enter the current code in **Authenticator code**, then choose **Assign MFA**.
   Use **Rename** to give the registered device a recognizable name.
6. Confirm the device appears in the MFA device list.

New-experience project accounts do not have a root console login to secure or recover.
Do not try the root-user procedure for one of these projects.

#### Accounts with a root login: protect root, then stop using it for daily work

1. Only for an account that has root credentials, open AWS console sign-in, choose **Root user**
   and sign in with that account's root email and password.
2. Open the account menu at the top right and choose **Security credentials**.
3. Find **Multi-Factor Authentication (MFA)** and choose **Assign MFA device**.
4. Enter a device name, choose **Authenticator app**, then **Next**.
5. Choose **Show QR code** and scan it with your authenticator app.
6. Enter one code in **MFA code 1**, wait for the next code and enter it in **MFA code 2**.
   Choose **Add MFA**, then confirm the device is listed.
7. Continue with [A3](#a3-confirm-or-create-a-non-root-operator) before running the manager.
   Never create root access keys or use root to deploy/test the agent.

AWS references: [AWS Settings MFA](https://docs.aws.amazon.com/accounts/latest/reference/register-mfa-devices.html),
[root MFA](https://docs.aws.amazon.com/IAM/latest/UserGuide/enable-virt-mfa-for-root.html).

### A3. Confirm or create a non-root operator

**Last updated: 2026-11-02.**

#### New experience: use your existing project access

1. In [AWS Settings](https://settings.aws.com), select the existing project identified in
   [A1](#a1-dismiss-the-welcome-screen-and-find-the-account-id), then open its AWS console.
2. Use your existing AWS Builder ID/project session. AWS supplies a human-access role;
   you do not need a second identity merely to avoid root. New-experience projects do not support
   creating IAM users with console access.
3. Only if another person needs access, choose **Team > Invite new team member**, enter their
   email, select the intended project and review before choosing **Send invitation**.
   This is optional: invited team members receive administrator access to the project's AWS
   resources, not a restricted testing account.
4. Continue to [A5](#a5-prepare-isolated-authentication). The read-only account check must confirm
   the expected project account and a non-root identity. Existing project permissions do not
   override service availability, account restrictions or cost controls.

#### Advanced/traditional account: prefer federation; create an IAM user only deliberately

AWS recommends federation and temporary credentials for human access. If an administrator already
gave you a suitable federated identity, use it; an IAM Identity Center access-portal session follows
the file procedure in [A5](#a5-prepare-isolated-authentication).

If you have only root credentials and deliberately choose a dedicated IAM console user for this lab,
an authorized administrator can follow these steps. They do not apply to a Builder ID-owned project,
including one whose organization later activated advanced features.

1. In the console's top **Search** box, type `IAM` and open **IAM**.
   Expand the navigation pane using the menu icon if it is collapsed.
2. Choose **Users > Create user** and enter a name such as `AwsAiManagerOperator`.
3. Select **Provide user access to the AWS Management Console**, then **I want to create an IAM user**.
   Choose an autogenerated password and retain the requirement to change it at first sign-in.
4. Choose **Next**, then **Add user to group**. Select an administrator-approved operator group,
   or choose **Create group** and name it, for example, `AwsAiManagerOperators`.
5. When creating the group, select `SignInLocalDevelopmentAccess` and the approved service policies.
   That sign-in policy alone does not grant Bedrock, AgentCore, IAM or S3 provisioning permissions.
   Review the [permissions requirements](#permissions-and-limits) before proceeding.
   For an isolated lab you own, `AdministratorAccess` is a possible explicitly accepted bootstrap
   choice, but grants full account control and is not a least-privilege testing policy.
   Do not select it by default for a shared/organizational account or just to bypass an error.
   If you have not approved the required permissions, stop here rather than guessing.
6. Choose **Create user group** if applicable, select the group, then **Next**.
   Review the permissions and choose **Create user** only when they are intentional.
7. On **Retrieve password**, keep the console sign-in URL, username and temporary password in your
   private password manager. Do not save credential exports in the repository or paste them into chat.
8. As an authorized administrator, open **IAM > Users > AwsAiManagerOperator > Security credentials**.
   Under **Multi-factor authentication (MFA)**, choose **Assign MFA device** and register the
   operator's device. The authenticator-app flow uses a device name and two consecutive codes.
9. Use the user's console sign-in URL in external Edge Work, sign in as that user, change the
   initial password and complete MFA. Verify the account menu shows the operator, not root.
   Do not create access keys: the browser helper obtains temporary credentials.

Initial setup needs elevated, reviewed provisioning rights; everyday discovery/testing should use
appropriately reduced permissions. The manager does not grant itself permissions or change policies.

AWS references: [access-management differences](https://docs.aws.amazon.com/accounts/latest/reference/sign-up-for-aws.html),
[invite team members](https://docs.aws.amazon.com/accounts/latest/reference/invite-team-members.html),
[IAM user creation](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_users_create.html),
[IAM user MFA](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_mfa_enable_virtual.html).

### A4. Review billing and configure cost controls

**Last updated: 2026-11-02.**

#### New experience: AWS Settings billing and optional project spend limits

1. Open [AWS Settings](https://settings.aws.com) as the project owner and choose **Billing**.
2. Review whether you have the Free Plan or Paid Plan, remaining credits and their expiration,
   and the charges/forecast under **Cost by project**. Under **Inspect costs**, choose **View**
   for a project's detailed cost breakdown when available.
3. Do not choose **Upgrade** just to follow this guide. A Paid Plan upgrade is a separate,
   irreversible billing decision, applies across your projects and can incur charges beyond credits.
4. If you are already on a Paid Plan and intentionally want a project spend limit, find the project
   in **Cost by project**, choose **Set limit**, review the recommended/custom amount and choose
   **Set spend limit** only after accepting it. AWS enforces a minimum of the greater of USD 20 or
   its estimated spend; do not mistake an example budget amount for an available limit.
5. Review any optional early controls before saving them. A spend limit can pause project resources;
   it is not just an email alert. Its calculation is pre-tax and excludes credits.
   Read AWS's pause, reactivation and data-retention conditions before relying on it.
6. Confirm the intended limit is shown for the correct project. Do not activate advanced features
   to expose a different billing page: activation removes project spend limits.

#### Advanced/traditional account: create an alert-only monthly budget

1. Use the console **Search** box to open **Billing and Cost Management**.
   Review **Free Tier**, **Credits** and **Bills** as available for your account.
   If billing access is denied, have the account administrator review billing access separately;
   do not grant broad service permissions as a workaround.
2. In the navigation pane, choose **Budgets > Create budget**.
3. Under **Budget setup**, choose **Use a template (simplified)**.
4. Choose **Monthly cost budget**, enter a recognizable budget name, your own monthly amount
   and the email address that should receive alerts.
5. Review the template's actual/forecast thresholds, account scope, credit treatment and other
   settings. Choose **Create budget** only after reviewing them; no automated budget action is needed.
6. Open the resulting budget and confirm the amount, monthly period and alert recipients.
   Complete any recipient verification requested by AWS.

**Checkpoint:** you understand the plan and the chosen cost control. A budget notification does not
stop resources, cost data can be delayed, and neither credits nor an email alert guarantee zero charges.

AWS references: [AWS Settings billing](https://docs.aws.amazon.com/accounts/latest/reference/view-billing-information.html),
[project spend limits](https://docs.aws.amazon.com/accounts/latest/reference/create-spend-limit.html),
[Paid Plan upgrade implications](https://docs.aws.amazon.com/accounts/latest/reference/upgrade-account.html),
[budget templates](https://docs.aws.amazon.com/cost-management/latest/userguide/budget-templates.html),
[advanced-feature implications](https://docs.aws.amazon.com/accounts/latest/reference/activate-advanced-features.html).

### A5. Prepare isolated authentication

**Last updated: 2026-11-02.**

First select one authentication method in the manager's input controls. The following branches are
alternatives, not instructions to configure every method. Use only a non-root identity.

#### Browser: supported project, IAM or federated console session

1. Let the manager run its local prerequisite check. Browser mode needs Python, the project's SDK
   dependencies, AWS CLI **v2.32.0 or later**, and the confirmed existing external Edge Work profile.
   Review missing dependencies before approving installation; use a dedicated Python environment.
2. For an IAM console user, an administrator must grant `SignInLocalDevelopmentAccess` in addition
   to the reviewed service permissions. If it was not added in [A3](#a3-confirm-or-create-a-non-root-operator):
   - Open **IAM > Users**, choose the operator and open **Permissions**.
   - Choose **Add permissions**, then the option to **Attach policies directly**.
   - Search for `SignInLocalDevelopmentAccess`, select it, choose **Next**, review, then **Add permissions**.
   For a new-experience project session, use its existing project role; do not create an IAM user
   or edit AWS-managed project roles to imitate this IAM-user procedure.
3. Select browser authentication in the manager. It must use its helper and a dedicated private
   authentication directory outside the repository, not a shared/default AWS profile or cache.
   Do not run bare `aws login`, `aws configure` or copied toolkit setup commands yourself.
4. When the helper opens external Edge Work, sign in interactively if needed. On the AWS session
   chooser, select the exact project/account recorded in [A1](#a1-dismiss-the-welcome-screen-and-find-the-account-id).
   A project name alone is not sufficient if several sessions/accounts are available.
5. Review the requested local-development access and approve only the intended non-root session.
   Do not authorize root, switch Edge profiles, or copy passwords/codes into chat.
6. Return to VS Code and wait for the read-only `check-account` result. Confirm the account ID and
   identity match your expectation. On a mismatch or failed sign-in, stop and investigate;
   do not switch methods, regions or shared profiles automatically.

The optional welcome-screen AWS Agent Toolkit is not needed. The manager's helper isolates its
configuration, credentials and login cache without changing scheduled tasks or shared authentication.

#### IAM Identity Center access portal: dedicated temporary-credentials file

Use this branch for a standard AWS access-portal identity rather than trying to make it an IAM user.
AWS Builder ID project sessions described above are a different console-login path.

1. Obtain the AWS access-portal sign-in URL from your administrator or invitation email.
   It is not necessarily the generic AWS console URL.
2. Open it in external Edge Work and sign in interactively with MFA.
3. On **Accounts**, expand the account whose 12-digit ID matches your intended account.
   If no account/role appears, an administrator must assign access; do not create keys to work around it.
4. Beside the approved role/permission set, choose **Access keys** or
   **Command line or programmatic access**, depending on the displayed label.
5. In **Get credentials**, select **PowerShell** if requested, then find
   **Option 2: Add a profile to your AWS credentials file**.
6. Copy the temporary INI credentials block into a new private file outside the repository,
   for example `C:\Private\AwsAiManager\temporary.ini`, using a local editor. Keep the access key,
   secret key and **session token** together; give the block a distinct section name such as
   `[aws-ai-manager]`. Restrict file access to the intended Windows user and SYSTEM.
   Despite the portal's generic instructions, do not paste into the shared `.aws\credentials` file.
7. Give the manager only the private file path and section name, never the contents.
   This SDK/file path does not require installing AWS CLI solely to read the credentials.
8. Run the manager's read-only account check. When credentials expire, repeat the portal procedure
   manually and review the renewed file; do not configure shared SSO caches or use static access keys.

AWS references: [console login requirements](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html),
[project console sessions](https://docs.aws.amazon.com/accounts/latest/reference/connect-ai-coding-tool.html),
[manual portal credentials](https://docs.aws.amazon.com/singlesignon/latest/userguide/howtogetcredentials.html#how-to-get-temp-credentials-manual).
The generic AWS CLI/toolkit examples in those references are not substitutes for this manager's
isolated helper; do not follow shared-profile setup or device-code flows.

### A6. Confirm the region and choose a text model

**Last updated: 2026-11-02.**

1. For a new-experience project, open **AWS Settings**, select the project, then open
   **Overview > Additional info > Region**. Record its region code. The region is assigned when
   the project is created; a missing region selector is not an error. For example, a project
   showing **Europe (Stockholm)** uses `eu-north-1`; this is an example, not a recommendation to move.
2. For an advanced/traditional account with region selection, open a regional service such as
   **Amazon Bedrock**, then inspect the region selector in the top navigation. Select a different
   region only deliberately, before provisioning, and record its code. Switching the console region
   does not move existing resources.
3. Check the [AgentCore region table](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agentcore-regions.html)
   for **AgentCore Runtime microVMs**, not only Harness or Runtime Instances.
   Also check the chosen model's [regional availability](https://docs.aws.amazon.com/bedrock/latest/userguide/models-regions.html).
   The manager's Runtime and its selected model must be usable in the agreed region.
4. In the console **Search** box, type `Bedrock` and open **Amazon Bedrock**.
   Choose **Model catalog** in the navigation pane. Filter for provider **Amazon** and text models,
   open a candidate's details and record its model ID, not just its display name.
   Do not open a playground and submit a prompt as part of this read-only inspection.
5. Review the model's on-demand availability, Converse compatibility and
   [input/output token pricing](https://aws.amazon.com/bedrock/pricing/), together with
   [AgentCore runtime pricing](https://aws.amazon.com/bedrock/agentcore/pricing/) and S3/log costs.
6. Ask the manager for read-only `models` discovery and a check of the selected model ID.
   Do not copy a fixed model ID from an unrelated region or assume catalog visibility grants access.
   If no suitable in-region on-demand Amazon text model is available, stop and review the options.
7. Do not accept marketplace terms, submit provider forms, subscribe, create provisioned throughput
   or invoke a third-party model just to test access. First invocation can itself initiate a
   subscription and acceptance of provider terms. Cross-region inference is not a workaround for
   new-experience project restrictions; elsewhere it still requires separate explicit review.

**Checkpoint:** you have an agreed account, region and checked model ID, understand the prices,
and have not run inference or accepted provider terms during discovery.

AWS references: [project regions](https://docs.aws.amazon.com/accounts/latest/reference/project-regions.html),
[new-experience service restrictions](https://docs.aws.amazon.com/accounts/latest/reference/supported-services-sign-up-new.html),
[model access and first-use behavior](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html).

### A7. Run the manager with separate approvals

**Last updated: 2026-11-02.**

1. In VS Code, open Copilot Chat, open the agent picker and select **AWS AI Manager**.
   Send: `Set up AWS AI Manager from a new account.`
   This is the repository's custom agent, not the AWS welcome-screen toolkit.
2. Let it check local prerequisites. Review any proposed installation and private directory before
   approving it. Installing dependencies does not authorize cloud changes.
3. Supply the account ID, region and chosen authentication method from
   [A1](#a1-dismiss-the-welcome-screen-and-find-the-account-id),
   [A5](#a5-prepare-isolated-authentication) and
   [A6](#a6-confirm-the-region-and-choose-a-text-model).
   Have it verify the account/non-root identity and selected model read-only before setup.
4. For a new account, choose **AgentCore Runtime**, give the agent a name and English instructions,
   and request the initial **setup preview only**. You do not need to create a role or bucket
   manually or know what an ARN is: the preview explains their names, trust, permissions,
   encryption, region and expected costs.
5. Review those exact IAM/S3 changes. Approve setup only if you accept them and the operator has
   the required permissions. The manager must use the exact preview confirmation and private run
   directory. A permissions error is not permission to grant itself administrator access.
6. After verified setup, keep the generated private `create-spec.json` path.
   Request the **agent creation preview**, review the model/name/instructions and charges, then
   approve creation separately with the exact requested name. Setup approval does not cover creation.
   There is no need to click **Create runtime** in the AWS console as well.
7. Once creation is verified, request one test prompt first. Read the complete prompt and reply;
   only send additional prompts when you intend to incur the corresponding inference/runtime usage.
8. When finished, request discovery and a **deletion preview**. Review the exact runtime ARN and
   confirm only that resource. Child-resource removal, if needed, requires its own force preview
   and approval. The manager must verify deletion, not just report that AWS accepted the request.
9. Review costs again using [A4](#a4-review-billing-and-configure-cost-controls).
   Agent deletion retains IAM roles, S3 artifacts/buckets and logs; storage charges can remain.
   Do not close the account or bulk-delete infrastructure as a substitute for reviewed cleanup.

For exact commands and private file locations, see the
[operator guide](../.github/skills/aws-ai-agent-test-prompts/references/operator-guide.md).
None of these approvals authorizes changing a shared default authentication context.

### A8. Copy an existing agent URL

**Last updated: 2026-11-02.**

1. Confirm the account and region using [A1](#a1-dismiss-the-welcome-screen-and-find-the-account-id)
   and [A6](#a6-confirm-the-region-and-choose-a-text-model).
2. Use the console's top **Search** box to open **Amazon Bedrock AgentCore**.
   Expand the navigation pane if necessary and choose **Runtime**.
3. Select the existing runtime to open its detail page. Copy the complete URL from Edge's address
   bar, not the generic console home, a list-page URL, or a temporary signed invocation URL.
4. Give that resource URL to AWS AI Manager and request read-only discovery first.
   The manager checks the embedded service/account/region and rejects ambiguous references.
5. Only for an existing eligible Classic customer, the corresponding console path is
   **Amazon Bedrock > Agents > your agent**, then optionally its published alias.
   This is not the creation path for a new AWS account.

Return to the [starting checklist](#starting-with-only-an-aws-account).
