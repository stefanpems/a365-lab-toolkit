# ACA-OBO / ACA-S2S — Agent 365 observability (admin center activity)

**Symptom.** In the Microsoft 365 admin center (**Agents → All agents**), ACA-OBO and ACA-S2S agents
created by the Lab Builder showed **Active users 0** and **Total sessions 0**, even after many prompts
from the web UI or the [Prompts Sender](../.github/skills/prompts-sender/SKILL.md). ACA-DW agents (Teams)
and FD agents (Foundry platform) showed activity.

## Root cause

The admin center activity comes from the spans the agent exports to **Agent 365 observability**
([agent activity](https://learn.microsoft.com/microsoft-365/admin/manage/agent-details#agent-activity):
*Active users* = distinct Entra users, *Sessions* = conversations, new one after 30 min of inactivity;
[attribute reference](https://learn.microsoft.com/microsoft-agent-365/developer/observability-attribute-reference):
`user.id`, `gen_ai.conversation.id`, `gen_ai.agent.id`, … are mandatory). The ACA samples exported
**nothing** for the web UI path:

1. The SPA endpoint **`/chat` has no Bot Framework TurnContext and set no baggage**, so the gen_ai spans
   (`invoke_agent`, `chat`, `execute_tool`) carried neither `microsoft.tenant.id` nor `gen_ai.agent.id`.
   The exporter drops such spans before sending: with `A365_OBSERVABILITY_LOG_LEVEL=DEBUG` the container
   logs `[Agent365Exporter] N spans skipped due to missing tenant or agent ID` →
   `No eligible genAI spans to export; nothing exported`.
2. **No exporter token on `/chat`**: the token was cached only on the agentic `/api/messages` path, and
   only when `AUTH_HANDLER_NAME` is set (never for ACA-S2S).
3. **Agent Framework stamps a random `gen_ai.agent.id`** (a new UUID per `Agent`) on `invoke_agent`,
   AFTER the span starts — baggage cannot override it, so even a tagged turn would be attributed to an
   unknown agent (the export URL `{agentId}` must equal the authenticated agent identity, else 403).

`ENABLE_A365_OBSERVABILITY_EXPORTER=false` in `.env.template` is **not** a cause: `.env` is not in the
image, and the code passes `a365_enable_observability_exporter=True`, which wins over the variable.

## Fix (ACA-OBO + ACA-S2S templates)

[`a365_observability.py`](../aca/obo/a365_observability.py) (same file in `aca/s2s`) implements the
documented **"Agent 365-enabled using S2S"** flow
([observability authentication](https://learn.microsoft.com/microsoft-agent-365/developer/observability-authentication-setup)):

| Piece | What it does |
| --- | --- |
| Token | Blueprint credentials + `fmi_path=<agent identity appId>` → agentic application token → the **agent identity** exchanges it (`client_assertion`) for an app-only token on `api://9b975845-388f-4429-889e-eab1ef63949c/.default`. The identity inherits `Agent365.Observability.OtelWrite` from the blueprint (granted by `a365 setup all`). |
| Route | `use_microsoft_opentelemetry(..., a365_use_s2s_endpoint=True, a365_token_resolver=a365obs.resolve_token)` → `/observabilityService/tenants/{tenant}/otlp/agents/{agentId}/traces`. |
| Baggage | `/chat`: tenant, agent identity, agent name, blueprint id, channel `web`, a conversation id (new thread = empty SPA history, or 30 min idle), `user.id` = the signed-in user's Entra object id, `user.email`, `user.name`, `client.address`, `server.address`. `/api/messages`: the same identity + the activity's user, conversation and channel. |
| Agent id | `bind_agent_identity()` sets the Agent Framework agent's `id`/`name` to the agent identity so `invoke_agent` matches. |

Both entry points (`/chat` and `/api/messages`) use the same app-only token and route. **ACA-DW is
unchanged** (its agentic `/api/messages` flow already exports). Application Insights export is
unchanged (same `enable_azure_monitor` switch); spans simply gain the attributes above, and the role
name becomes the app (`OTEL_SERVICE_NAME`) instead of `unknown_service`.

### Configuration

| Variable | Set by | Meaning |
| --- | --- | --- |
| `A365_AGENT_ID` | `deploy-aca.ps1` / `deploy-aca-S2S.ps1` | Agent identity appId (the registry's *Agent ID*, **not** the blueprint). Resolved from `a365.generated.config.json` (`agenticAppId`) or by the identity display name in Entra (validated against the blueprint); override with `-AgentId`. Without it the startup log warns and `/chat` is not exported. |
| `OTEL_SERVICE_NAME` | deploy scripts | Application Insights role name (`cloud_RoleName`). |
| `A365_AGENT_NAME` | optional | Span agent name; defaults to the Container App name (`CONTAINER_APP_NAME`). |
| `A365_OBSERVABILITY_LOG_LEVEL` | optional, temporary | `DEBUG` logs span filtering and every export result (`HTTP 200 success … rejectedSpans`). |

## Verify

1. **Startup** (container log / App Insights `traces`):
   `Agent 365 observability: S2S export as agent identity <A365_AGENT_ID> …`.
2. **Quick check** — set `A365_OBSERVABILITY_LOG_LEVEL=DEBUG`, send 2–3 prompts from the web UI or the
   Prompts Sender, then look for `Exporting N spans to endpoint: …/observabilityService/…/agents/<id>/…`
   and `HTTP 200 success … "rejectedSpans":0`. Remove the variable afterwards. At INFO level a failed
   export still logs a WARNING (401/429/5xx) or an ERROR (403, "No token resolved").
3. **Application Insights** (when configured):

   ```kusto
   dependencies
   | where timestamp > ago(1h)
   | extend op = tostring(customDimensions["gen_ai.operation.name"])
   | where op in ("invoke_agent", "chat", "execute_tool")
   | project timestamp, cloud_RoleName, name, op,
             agentId = tostring(customDimensions["gen_ai.agent.id"]),
             userId  = tostring(customDimensions["user.id"]),
             conv    = tostring(customDimensions["gen_ai.conversation.id"])
   ```

   Every row must show the agent identity appId, a user id and a conversation id.
4. **Admin center** — **Agents → All agents → <agent> → Activity**: users and sessions appear after the
   service's processing delay (hours).

## Port the fix to an existing ACA-OBO / ACA-S2S agent

For an agent scaffolded before this change (sources in `generated/<prefix>/<agent>/`):

1. Copy `a365_observability.py` from the matching template (`aca/obo` or `aca/s2s`).
2. `host_agent_server.py`: if it equals the old template, replace it with the new one; otherwise apply the
   template diff (imports, `use_microsoft_opentelemetry(...)`, `_setup_observability_token`,
   `_turn_baggage`, the `/chat` baggage block).
3. `agent.py`: add `import a365_observability as a365obs` and call `a365obs.bind_agent_identity(...)`
   on every `Agent` before it runs (see the template diff) — keep any local customizations.
4. Rebuild and roll the image without touching secrets:
   `az acr build -r <acr> -t <app>:<tag> --no-logs .` then
   `az containerapp update -n <app> -g <rg> --image <acr>.azurecr.io/<app>:<tag> --set-env-vars A365_AGENT_ID=<agent identity appId>`.
5. Verify as above. **Rollback**: `az containerapp update -n <app> -g <rg> --image <previous image> --remove-env-vars A365_AGENT_ID`
   (the previous image stays in the registry).

## Not covered here

- **FH-OBO / FH-S2S** (`foundry-hosted/`): the container code has the same gap (no baggage, no S2S
  route), but it does not affect the admin center — the Foundry hosting platform reports their activity
  (verified: lab FH-OBO/FH-S2S agents show active users and sessions). No change needed.
- **ACA-DW**: by code inspection, its `invoke_agent` spans still carry Agent Framework's random id (the
  `chat`/`execute_tool` spans are attributed through baggage); the DW activity already shows in the
  admin center, so the DW template is intentionally left unchanged.
