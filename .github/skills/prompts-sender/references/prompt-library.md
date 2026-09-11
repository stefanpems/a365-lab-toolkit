# Prompts Sender — prompt library

Random source of prompts for the **Prompts Sender** agent. Four categories, four prompts each.

Format (one prompt per bullet):

```
- <prompt text to send> (<success condition to look for in the response>)
```

Rules for the engine / agent:
- When **sending** a prompt, use only the text **before** the trailing `(...)`. The parenthesised part
  is the **success condition** and must **never** be included in the message sent to the agent.
- The success condition is what the caller looks for in the agent's response to decide PASS/FAIL. It is
  evaluated semantically (case-insensitive, substring or meaning), not as an exact string match.
- `{ANON_SERVER}` / `{AUTH_SERVER}` are placeholders for the lab's custom BYO MCP server names
  (e.g. `ext_a09091Anon` / `ext_a09091Auth`). The engine substitutes them from `--anon-server` /
  `--auth-server` (defaults derived from the lab prefix: `ext_<prefix>Anon` / `ext_<prefix>Auth`).

## hello
- Hello! (got an answer)
- Hi there — are you online? (a greeting or acknowledgement)
- Please greet me. (a greeting)
- Say hi and confirm you are ready. (a confirmation that it is ready)

## MCP Mail access
- Give me the title of the last email I received. (an email title)
- What is the subject of the most recent message in my inbox? (a subject line)
- Who sent me my most recent email? (a sender name or address)
- How many messages are currently in my inbox? (a number)

## Custom MCP Anon access
- Call the server_time tool on {ANON_SERVER} and return its exact response. (a current UTC date/time)
- Use {ANON_SERVER} hash_text to hash the word "agent" and show the result. (a hash value)
- Run outbound_connectivity_check on {ANON_SERVER} and report the result. (a connectivity result)
- Call whoami_anon on {ANON_SERVER} and show its response. (an anonymous/no-auth identity note)

## Custom MCP Auth access
- Call whoami on {AUTH_SERVER} and show authorization_token_forwarded. (authorization_token_forwarded is true)
- Use {AUTH_SERVER} token_claims and show my user_principal_name. (a user principal name / email)
- Call whoami on {AUTH_SERVER} and tell me the token_type. (token_type is delegated)
- Ask {AUTH_SERVER} whoami for the caller's object id. (an object id / GUID)
