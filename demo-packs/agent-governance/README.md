# Demo pack: agent governance

A complete Agent 365 governance demo around one fictional process: the **Incentives Department** of Contoso runs the
**Innovation Grant 2026**, with many agents built on every platform and many people who create, use, sponsor, approve,
block and audit them. The [Demo Builder](../../.github/agents/demo-builder.agent.md) builds it in any tenant, the
[demo reset](../../.github/skills/agent365-demo-reset/SKILL.md) keeps it repeatable and the
[demo guide](../../.github/skills/agent365-demo-guide/SKILL.md) runs it. All people, businesses, documents and data are
fictional.

Languages: en, it, fr, es, de. Start with the license gate in
[docs/demo-environment-prerequisites.md](../../docs/demo-environment-prerequisites.md).

> **Preview, not yet validated end to end:** the pack was derived from a reference lab built by hand and has been
> checked offline and read-only against a real tenant; a complete build with the Demo Builder in a new tenant has not
> been run yet.

## Story alignment

The target is the current Demo Kit story, **D1-D15 only**. The cast, persona responsibilities and demo memberships
follow story sections 4.3-4.4. D9 owns risk-based Conditional Access; D15 combines the confidential-data check,
the related Defender incident and the Purview risky-agent investigation.

**Manual checkpoint: D14 still needs operator reconciliation.** Its existing definition is deliberately unchanged.
Do not treat this pack as fully story-aligned, or a successful locale validation as proof that this checkpoint is done.

The pack keeps the existing Reports Monitor test twin for D9 so confirming its risk does not alter the main agent's
D10 access-package starting conditions.

## Files

| Path | Content |
|---|---|
| `pack.json` | language-neutral definition: license roles, personas, groups, knowledge, demo MCP servers and pool, agents with their starting state, operator slots, tests, governance, acts, demos (D1-D15 with lead times and manual resets), timeline |
| `locales/<lang>/core.json` | every visible text of the demo in that language: organization, persona names, agent names and instructions, MCP server and tool names, governance object names, prompts |
| `locales/<lang>/knowledge.json` | the fictional documents (Word, PDF, Excel) built by `New-DemoKnowledge.ps1` |
| `locales/<lang>/tests.json` | test prompts and expected results (same ids in every language) |
| `overlays/` | per-agent additions to the Lab Builder samples (role prompt and in-process tools, generated in the demo language) |
| `mcp/` | the demo MCP backends (one image, one container per backend, tools generated from the locale) |
| [OPERATOR-SLOTS.md](./OPERATOR-SLOTS.md), `operator-slots.template.json` | the few protection-test inputs that are not shipped: the operator fills them per lab |

Every name must respect the platform limits: `Test-DemoPack.ps1` checks each locale against the iron rules of the
Lab Builder (`text-limits.json`) before anything is created.

### Adding a language

Copy `locales/en` to `locales/<lang>`, translate the values (never the keys, the ids or the `{{...}}` placeholders),
keep every e-mail address on a reserved example domain, add the language to `locales` in `pack.json`, then run
`Test-DemoPack.ps1 -Locale <lang>` until it reports no error.

## Personas

| Key | Story | Example name (en) | Demos |
|---|---|---|---|
| `aiAdmin` | AI administrator: opens the registry, decides, blocks, reassigns | Grace Collins | D1, D2, D3, D4, D5, D6, D7, D8 |
| `identityAdmin` | identity and access: Conditional Access, entitlement management, attributes | Paul Greene | D9, D10, D11 |
| `complianceOfficer` | compliance and privacy: audit, Communication Compliance, eDiscovery, DSPM | Ellen Costello | D12, D13, D15 |
| `socAnalyst` | SOC analyst: posture, real-time protection, incidents, hunting | Mark Gallagher | D14 |
| `maker` | business maker of the department and registry OWNER of the agents | Luke Byrne | D6 |
| `caseOfficer` | case officer of the secondary office: the end user | Anna Walsh | D5, D12, D14 |
| `director` | director of the department and Entra SPONSOR (business owner) of the agents | Sylvia Coleman | D10, D15 |
| `programLead` | circulars lead; author of the rejected request (D4), digital-colleague creator (D7), web-app user (D9, D10) | Martha Nolan | D4, D7, D9, D10 |
| `orphanLeaver` | creator of the orphan agent; NO manager on purpose; permanently deleted (hard delete) before the demo | Frank Rourke | D1 |
| `d8Leaver` | creator of the forms agent; manager = maker; permanently deleted before the D8 rule runs | Claire Lynch | D8 |

Profiles P1-P6 and P8 are the pre-authenticated story profiles. P7 is the existing administrator's backup, not a new
persona to provision. The program lead and the two leavers are story users, not additional numbered browser profiles.

## Agents

| Key | Platform | Name (en) | Demos |
|---|---|---|---|
| `recordsColleague` | code ACA-DW | Records Colleague | D7, D13 |
| `recordsAssistant` | code ACA-OBO | Records Assistant | D2, D6 |
| `reportsMonitor` | code ACA-S2S | Reports Monitor | D9, D10, D11 |
| `reportsMonitorTest` | code ACA-S2S | Reports Monitor – Test | D9, D11 |
| `applicationReview` | code FD-OBO | Application Review | D1 |
| `grantsDesk` | copilotStudio MCS-NH | Grants Desk | D1, D5, D8 |
| `grantsDeskPilot` | copilotStudio MCS-NH | Grants Desk – Pilot | D5, D8 |
| `siteInspections` | copilotStudio MCS-NH | Site Inspection Requests | D4, D8 |
| `communicationsAssistant` | copilotStudio MCS-OH | Communications Assistant | D1, D8, D14 |
| `faqPrototype` | copilotStudio MCS-OH | Business FAQ (prototype) | Legacy compatibility only |
| `circularsAssistant` | agentBuilder | Circulars Assistant | D1, D15 |
| `formsAssistant` | agentBuilder | Forms Assistant | D8 |
| `personalContacts` | agentBuilder | Personal Contacts Draft | D1, D4 |
| `casesAssistant` | agentBuilder (with a custom skill) | Cases Assistant | D15 |

## Demos

| Demo | Act | Title | Portal | Minutes |
|---|---|---|---|---|
| D1 | 1 | Single registry and agent ID card | microsoft365Admin | 4-6 |
| D2 | 1 | The agent map | microsoft365Admin | 1-2 |
| D3 | 1 | Connected platforms (registry sync) | microsoft365Admin | 0-2.5 |
| D4 | 2 | Controlled onboarding: request, approval, template | microsoft365Admin | 3-5 |
| D5 | 2 | Agent in production: block and unblock | microsoft365Admin | 4-6 |
| D6 | 2 | Governing tools: block and approve | microsoft365Admin | 2-4 |
| D7 | 2 | The digital colleague | microsoft365Admin | 3-6 |
| D8 | 2 | Automation rules: templates and ownerless agents | microsoft365Admin | 1.5-3 |
| D9 | 2 | Conditional Access for risky agents | entra | 2.5-4 |
| D10 | 2 | Time-bound access with access packages | entra | 2-4 |
| D11 | 2 | Security attributes and What If | entra | 2-3 |
| D12 | 2 | Audit and Communication Compliance on agent interactions | purview | 3-5 |
| D13 | 2 | eDiscovery on interactions with agents | purview | 2-4 |
| D14 | 3 | Security posture of the agents | defender | 2-3 |
| D15 | 3 | Confidential data stays confidential | purview | 4-7 |

The protection demos are referred to by code only; their inputs are operator slots.

## Compatibility objects

`faqPrototype` and `governance.defender.rtpRule` are retained as **legacy compatibility data**, not as current-story
requirements. Their demo lists are empty. Do not create them for a new lab unless the operator explicitly requests
the legacy setup; the prototype remains outside the Lab Builder plan. Keep their locale keys for already-built labs.
The default Copilot Studio environment and relaxed authentication are not prerequisites of the current story.

The retired `FQ-01` and `RA-08` tests and `slot-2` are no longer in the current test hand-out or operator-slot template.
Keep the remaining slot ids stable; do not renumber an existing lab's operator file.

## Teardown

1. Restore what was changed only for the demo: the Power Platform setting "Authentication for agents" of the default
   environment (only if a legacy prototype was explicitly requested and the setting was relaxed) and the content filter of the Foundry deployment
   used by the review agent (back to the default policy, then delete the custom one).
2. The [Lab Cleaner](../../.github/agents/lab-cleaner.agent.md) removes what is tagged with the lab: resource groups
   (lab agents, web UI of the lab, `<prefix>-demomcp-rg`), Entra apps and agent identities, agent licenses, Copilot
   Studio solutions of the lab. If a legacy FAQ prototype exists, it lives outside the lab plan (default environment):
   delete it in Copilot Studio.
3. The demo MCP servers (`ext_...`) cannot be deleted through the platform API: Reject the pending requests and Block
   the approved servers in the Microsoft 365 admin center > Agents > Tools. Their names stay reserved.
4. Demo extras, removed by hand (Microsoft Entra, Microsoft 365, Purview, Defender): the persona users and the demo
   groups, the SharePoint site of the knowledge, the Agent Builder agents (with their custom skills), the direct
   application permission of the test twin, the access package and then its catalog,
   the Conditional Access policies, the admin-center templates and tags, the Purview label, DLP policy, audit
   retention policy, Communication Compliance policy and eDiscovery case, any legacy Defender real-time protection rule and
   saved hunting queries. `generated/<prefix>/demo/state.json` lists what the build created (users, groups, MCP
   registrations with their Entra apps, governance objects).
5. Custom security attributes and attribute sets cannot be deleted: deactivate the attribute (and its values).
6. Delete `generated/<prefix>/` (it holds the lab state, the MSAL caches and the operator slots file).
