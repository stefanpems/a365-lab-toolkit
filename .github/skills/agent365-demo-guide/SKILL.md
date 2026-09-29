---
name: agent365-demo-guide
description: 'Run a demo built by the Demo Builder: generate the run of show of the lab (one card per demo, in act order, in English with the localized names, prompts and expected results), rehearse demos one at a time with the pre-flight and the reset, and run the live event. Use when the user wants the demo script, the run of show, to rehearse a demo, to know who does what in each demo, or to prepare the day of the event. Trigger phrases: demo guide, run of show, demo script, rehearse the demo, how do I run D5, prepare the event day.'
argument-hint: 'A lab prefix and, optionally, the demos (e.g. D4,D5)'
---

# Agent 365 demo guide

Turns a lab built by the [Demo Builder](../agent365-demo-builder/SKILL.md) into a runnable show. The run of show is
generated from the demo pack and the lab (`scripts/New-DemoGuide.ps1 -Prefix <p> [-Demo D4,D5]` →
`generated/<prefix>/demo/guide/run-of-show.md`), so it always matches the language and the names of that lab. Each
card says: title, act, time, product status, portal, who signs in (persona and UPN), agents and their starting state,
the governance objects shown, the prompts of the linked tests with their expected result, the pre-flight command and
what the demo leaves behind (reset class, lead time, manual resets).

> **Preview, not yet validated end to end** (see the [Demo Builder](../agent365-demo-builder/SKILL.md)).

## Rules

- **Operator text in English, prompts in the demo language.** The cards are English; prompts and expected results
  come from the locale of the lab and are shown as they must be typed.
- **Protection demos by code only** (C6, C7, D16, D17 and the protection tests of D12): their inputs are operator
  slots, shown as "fill slot-N"; the operator takes them from `generated/<prefix>/demo/operator-slots.json`. Never
  write, quote or paraphrase them in chat or files.
- **The story persona acts in the portal** (approvals, blocks, requests): the audit trail shown later must name that
  person. Use one browser profile per persona, signed in before the run.
- **Demo moments are live**: a step that is itself part of a demo (for example the D8 reassignment rule) is never done
  in advance; the pre-flight only confirms that its conditions are there.
- **Say "preview" aloud** when the status of a card says so.
- **Freeze on the day**: no configuration change at T0 (timeline of the pack); only the smoke test.

## Rehearsal (one demo at a time)

1. `Get-DemoState.ps1 -Prefix <p> -Demo <id>` ([agent365-demo-reset](../agent365-demo-reset/SKILL.md)): fix every KO.
2. Walk the card with the user, **one step per turn**: say who does what where, wait until the user reports it done,
   verify by read-back when a script can, then give the next step.
3. After the demo: if its reset class is `consumes` or `time`, run `Reset-DemoState.ps1 -Prefix <p> -Demo <id>` (dry
   run, then `-Apply`) and the manual resets of the card; note how long the effects took.

## The event

- **T-1 evening**: full `Reset-DemoState.ps1 -Apply`, the manual resets of every demo, then `Get-DemoState.ps1`: no KO.
  Blocks, installs and owner changes need the night to propagate.
- **T0**: smoke test (`Get-DemoState.ps1`), personas signed in, the run of show open, fallback screenshots ready for
  every preview feature.
- **Afterwards**: `Reset-DemoState.ps1` to reuse the lab, or the teardown in
  [demo-packs/agent-governance/README.md](../../../demo-packs/agent-governance/README.md#teardown).
