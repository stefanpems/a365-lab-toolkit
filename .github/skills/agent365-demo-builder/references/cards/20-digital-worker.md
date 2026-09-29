# Digital Worker instance

The instance of "{{agents.recordsColleague.displayName}}" is an agent USER (it has a mailbox and a Teams presence). It
has the longest lead time of the build: create it first. Lead time: minutes to hours in the admin center, up to one day
before it is visible in Teams and Microsoft 365 Copilot (preview).

## 1. Licenses of the instances (admin)

Microsoft 365 admin center > Agents > All agents > **{{agents.recordsColleague.displayName}}** > Licenses: assign the
Frontier agent license, the Teams license and the Microsoft 365 Copilot license of the demo (docs/demo-environment-
prerequisites.md, license gate) > Save. New instances inherit them; the Copilot license gives the instance a mailbox.

## 2. Create the instance ({name:maker}, from Teams)

Signed in as **{name:maker}** ({upn:maker}) at https://teams.cloud.microsoft > Apps > Built for your org >
**{{agents.recordsColleague.manifest.nameShort}}** > Create instance:

- Name: `{{agents.recordsColleague.instance.displayName}}`
- Alias: `{{agents.recordsColleague.instance.alias}}`
- Managed by: {name:maker}
- The description field is read-only: it is the manifest short description ("{{agents.recordsColleague.manifest.descriptionShort}}").

Rules of the reference lab:

- Create instances only the way an enabled end user would: from **Teams**, signed in as that user; never the
  admin-center "+ Add instance". If the first attempt is silently dropped (no instance after about 5 minutes: a known
  preview issue), retry from Teams, then from the Microsoft 365 Copilot Agent Store.
- If "Create instance" is missing, the template's "who can create instances" (Publish to users > Activate) must include
  {name:maker}: admin fix.

## 3. Afterwards (scripted)

- The creator becomes owner AND sponsor of the instance identity: run `Set-DemoGovernance.ps1 -Step identities` to set
  the business sponsor ({name:director}).
- Verification is scripted (agent user, instance identity by blueprint, license count): agent365-lab-reporter.
- Then run the RC tests of the hand-out (Teams 1:1 chat as {name:maker}, e-mail to the instance).
