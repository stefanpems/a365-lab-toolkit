# Test-prompt library (systematic tool-verification prompts)

Use this after each agent goes live to prove its features and its attached tools actually work. At the
**Test now** gate, emit ONLY the rows whose **Applies to** matches the agent being tested — by its
**type** (OBO / S2S / DW) and the **MCP servers actually attached** to it (from `agents[].tools` +
`customMcp.attachTo`). Never show a Mail prompt to an agent without `mcp_MailTools`, a Work IQ prompt to
an agent without that server, or a custom-tool prompt to an agent the custom MCP was not attached to.

Substitutions: `<agent>` = the agent name; `<name>` = the custom-MCP name/prefix; `<auth-app-id>` = the
auth resource app id; `<me>` = the signed-in user's email address.

> ⛔ **Before a web-UI test (OBO / S2S): tell the user IN BOLD to HARD-RELOAD the SWA first.** The agent's
> tab was just (re)deployed into `config.js`; a browser tab left open from before is running the STALE
> config, so the new/updated tab will be missing or won't answer. Instruct a hard refresh of
> `https://<swa-host>` (Ctrl+F5 / Ctrl+Shift+R), or close and reopen the URL. Say this ABOVE the prompts,
> every time. (Teams/DW needs no reload.)

## 1. Baseline — every agent
| Prompt | What proves it worked | Applies to |
| --- | --- | --- |
| `Hello — reply with one short sentence confirming you are online.` | The agent replies at all (connectivity + model wired) | ALL |
| `List, by name, the tools you currently have access to.` | It names the attached servers/tools. ⚠️ An LLM can miscount its own tools — always confirm a specific tool with its tool-specific prompt below, not with this answer alone | ALL (most useful when ≥1 MCP is attached) |
| `Can you read the content of https://example.com/ or at least tell me whether it is reachable (HTTP 200)?` | **Web access** (`fetch_url`, always on): it reports **HTTP 200 — reachable** AND the real page content (title *Example Domain*, "…for use in documentation examples…"). A refusal ("I can't browse") or invented content = the tool was NOT called. For FD agents it works only if `deploy-web-fetch.ps1` passed (FD `.env` has `WEB_FETCH_MCP_URL`) | ALL 8 code types: ACA-/FH-OBO/S2S/DW, FD-OBO/S2S (OBO, S2S **and** DW — no token/connection needed). NOT MCS |
| **Conversation memory** — send these THREE prompts in a row, in the SAME tab / Teams chat: `What is the capital of France?` → `How many districts does it have?` → `Which one is the most populous?` | **Short memory** (last 3 exchanges, always on): turn 2 answers **20 arrondissements** and turn 3 the **15th arrondissement** WITHOUT the user repeating "Paris". Asking "which city?" at turn 2 = no memory. Memory lives in the web UI tab (a page reload starts a fresh conversation) or, for DW, in the agent container per Teams chat (reset on container restart) | ALL 8 code types (web UI for OBO/S2S, **Teams** for DW). NOT MCS |

## 2. Mail (`mcp_MailTools`) — delegated; OBO / DW only (S2S is app-only, no delegated Mail)
| Prompt | What proves it worked | Applies to |
| --- | --- | --- |
| `List my last 2 received emails — for each show only the date, the subject and the sender, nothing else.` | Real recent dates/subjects/senders (invented data = the tool was NOT called) | OBO, DW with `mcp_MailTools` |
| `Send an email to <me> with subject "A365 lab test" and body "hello from <agent>", then confirm it was sent.` | The email actually arrives in the mailbox | OBO, DW with `mcp_MailTools` |

## 3. Work IQ (`mcp_CalendarTools`, `mcp_TeamsTools`, `mcp_SharePointTools`, …) — delegated; OBO / DW only
| Prompt | What proves it worked | Applies to |
| --- | --- | --- |
| `Using <that Work IQ tool>, list my next 3 calendar events (or my 3 most recent Teams messages).` | Real data from your own account | OBO, DW with that Work IQ server |

## 4. Custom MCP — anonymous server (`ext_<name>Anon`, NoAuth)
| Prompt | What proves it worked | Applies to |
| --- | --- | --- |
| `Call the ext_<name>Anon server's server_time tool and show the exact UTC time it returns.` | A real current time (a past/invented time = the tool was NOT called) | agents with `ext_<name>Anon` attached (OBO) |
| `Call the ext_<name>Anon server's hash_text tool on the text "agent365" with algo sha256 and show the digest.` | Digest equals the true sha256 of `agent365` | as above |
| `Call the ext_<name>Anon server's outbound_connectivity_check tool and show the HTTP status and latency.` | `reachable: true` + an HTTP status | as above |
| `Call the ext_<name>Anon server's whoami_anon tool and show the JSON.` | `authorization_header_present: false` (the NoAuth path) | as above |

## 5. Custom MCP — authenticated server (`ext_<name>Auth`, EntraOAuth) — OBO only
| Prompt | What proves it worked | Applies to |
| --- | --- | --- |
| `Call the ext_<name>Auth server's whoami tool (the authenticated EntraOAuth one) and show the exact JSON it returns.` | **`authorization_token_forwarded: true`**, `token_type: delegated`, your `user_principal_name`, `audience: api://<auth-app-id>`, `scopes: access_as_agent` | OBO with `ext_<name>Auth` |
| `Call the ext_<name>Auth server's token_claims tool and show the decoded claims.` | Decoded delegated claims of the signed-in user | OBO with `ext_<name>Auth` |
| `Call the ext_<name>Auth server's propagate_to_graph tool and show the resolved_identity from Microsoft Graph /me.` | `flow: on-behalf-of`, `success: true`, `resolved_identity` = you | OBO with `ext_<name>Auth` **and** `propagateToGraph` configured |

## 6. S2S — identity-agnostic only
| Prompt | What proves it worked | Applies to |
| --- | --- | --- |
| `Summarize the CAP theorem in two sentences.` | The agent responds (needs no user context or tools) | S2S |

## Agent-type nuances (state these when offering the test)
- **OBO** — the custom **auth `whoami` MUST return `authorization_token_forwarded: true`** (delegated,
  YOUR `upn`). If it returns `false`, that is a **bug** (the connector must be EntraOAuth AND the server
  must read headers with `get_http_headers(include_all=True)`), not a preview limitation.
- **S2S** — app-only identity; the custom MCP and delegated Work IQ tools are **not attached** (by design).
  It DOES have web access (`fetch_url`, the Baseline web prompt) — a tool-backed check that needs no user
  context.
  ⛔ **Do NOT ask an S2S agent to describe its own identity** — an LLM does not know its runtime token and
  will confidently MISREPORT it (observed: an S2S agent claimed it was *"acting on behalf of the signed-in
  user"*, which is the OBO model). Use the identity-agnostic prompt only to confirm it responds; explain
  that S2S's app-only identity is used for **downstream** calls (client-credentials of the blueprint app),
  and is shown empirically only by the custom auth `whoami` — which OBO/DW can use but S2S cannot in this lab.
- **DW** — test in **Teams** on the hired instance; the custom MCP is **not** available to DW (connection
  ownership limitation). Test Mail / Work IQ delegated as the agent's own user.
