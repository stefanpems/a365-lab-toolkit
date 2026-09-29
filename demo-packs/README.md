# Demo packs

> **Preview, not yet validated end to end:** the Demo Builder and this pack have been checked offline and read-only
> against a real tenant; a complete build in a new tenant has not been run yet.

A demo pack is the data of a complete, repeatable Agent 365 demo: a language-neutral `pack.json` plus one folder of
visible texts per language under `locales/<lang>/`. The [Demo Builder](../.github/agents/demo-builder.agent.md) builds
a pack in a tenant, [agent365-demo-reset](../.github/skills/agent365-demo-reset/SKILL.md) restores its starting
conditions and [agent365-demo-guide](../.github/skills/agent365-demo-guide/SKILL.md) generates its run of show.

| Pack | Story | Languages |
|---|---|---|
| [agent-governance](./agent-governance/README.md) | the Incentives Department of Contoso and its agents: inventory, lifecycle, ownership, access, compliance and protection (D1-D17) | en, it, fr, es, de |

Validate a pack (every locale, the iron naming rules, the fictional e-mail domains) with
`.github/skills/agent365-demo-builder/scripts/Test-DemoPack.ps1 -Pack <name>`. The environment variable
`DEMO_PACKS_ROOT` points the Demo Builder to packs kept outside this folder.
