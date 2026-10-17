# Operator slots

Some demo steps need operator-provided test inputs. They are not part of this repository: each locale has only an
empty slot, identified by an id. The operator writes the values in a local file, never committed:

```
generated/<prefix>/demo/operator-slots.json
```

The format is in [operator-slots.template.json](./operator-slots.template.json): one object per locale, one string
per slot id. The scripts read the file, never print its values and report only which slots are filled.

The current ids are `slot-1`, `slot-3`, `slot-4` and `slot-5`. `slot-2` is retired; existing operator files may keep it,
but new builds do not require it. Do not renumber the remaining slots.

D14 is prepared and reconciled manually by the operator. Do not print its inputs or infer that it is ready from a
successful pack validation.

| Slot | Demo | Where it is used | Reference for building it |
|---|---|---|---|
| slot-1 | D14 (variant A), D15 | Invisible run (white, 1 pt) at the end of the forms notice in the notices folder, read by the communications assistant | [Copilot Studio external threat detection](https://learn.microsoft.com/microsoft-copilot-studio/external-security-provider) |
| slot-3 | D12 | Prompt of the case officer to an agent in Microsoft 365 Copilot (test CC-01) | [Communication Compliance for Copilot](https://learn.microsoft.com/purview/communication-compliance-copilot) |
| slot-4 | D12 | Second prompt of test CC-01; it should contain one of the locale's `governance.communicationComplianceKeywords` | [Communication Compliance for Copilot](https://learn.microsoft.com/purview/communication-compliance-copilot) |
| slot-5 | D15 | Prompt of the case officer to the communications assistant the day before the demo (incident) | [AI agent protection in Defender](https://learn.microsoft.com/defender-xdr/security-for-ai/ai-agent-inventory) |

Rules for every value:
- write it in the demo language;
- use only fictional data and reserved example domains (`example.com`, `example.org`, `example.net`, `*.example`);
- never include a real secret, credential or personal data;
- keep it short (one or two sentences).

Checks (no value is ever printed): `Test-DemoPack.ps1 -OperatorSlots generated/<prefix>/demo/operator-slots.json`.
When slot-1 is empty, `New-DemoKnowledge.ps1` writes the notice without it and reports the slot as not filled:
D14 variant A and the D15 incident cannot be shown until it is filled and the knowledge is regenerated.