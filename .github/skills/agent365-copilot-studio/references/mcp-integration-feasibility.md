# MCS + A365 tool gateway MCP — feasibility & how-to

Can an MCS (Copilot Studio) agent consume the Agent 365 tool-gateway MCP servers (Mail, custom Anon/Auth)?
**Yes for Mail (official, tested pattern); experimental for the custom ext_ servers.** Copilot Studio can
call an ATG MCP server through a custom Entra client app + OAuth 2.0 — this is documented by Microsoft
("Connect an MCP server through Agent 365 Tooling Gateway"), using the SAME ATG resource app the lab uses
for Mail (`ea9ffc3e-8a23-4a7d-836d-234d7c7565c1`).

## Why this is different from ACA/FH/FD tool attach
An A365 blueprint agent (ACA/FH/FD) gets its gateway token from its blueprint identity. An MCS agent is
NOT an A365 blueprint — it authenticates to the ATG with **its own Entra client app** (delegated, the
signing-in user), configured as an MCP tool's OAuth connection. So the wiring is: **custom Entra app +
ATG delegated scope + admin consent + Copilot Studio MCP tool (OAuth 2.0 Manual)**.

## Steps (Mail — confirmed)
1. Run `scripts/New-McsMcpClientApp.ps1 -Tools Mail -Tenant <target>` (az logged into the target tenant).
   It creates the Entra app, adds the `McpServers.Mail.All` delegated permission on the ATG, grants admin
   consent, writes the client secret to a gitignored file, and prints the OAuth values.
2. In Copilot Studio -> your agent -> **Tools -> Add a tool -> Model Context Protocol** (New tool):
   - Server name: `A365 Mail (ATG)`; Server URL: `https://agent365.svc.cloud.microsoft/agents/servers/mcp_MailTools`
   - Authentication: **OAuth 2.0 -> Manual**, with:
     - Client ID / Client secret: from step 1 (secret from the gitignored file)
     - Authorization URL: `https://login.microsoftonline.com/<tenant>/oauth2/v2.0/authorize`
     - Token URL / Refresh URL: `https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token`
     - Scope: `ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/.default`
3. Create -> copy the **callback URL** -> add it as a Web redirect URI on the app
   (`az ad app update --id <appId> --web-redirect-uris <callback>`).
4. Create a new connection (sign in) -> Add to agent -> Publish.

## Custom Anon / Auth (ext_<prefix>Anon / ext_<prefix>Auth) — experimental
The custom BYO servers are reached through the same gateway host
(`https://agent365.svc.cloud.microsoft/agents/servers/ext_<prefix>Anon|Auth`), but they add BYO-specific
requirements that are NOT fully validated from Copilot Studio yet:
- The ext_ server must be **admin-approved** in the M365 admin center (as for ACA/FH agents).
- The BYO tool only returns data once the **invoking user created the one-time Power Platform connection**
  for that connector (Anon = NoAuth connection; Auth = OAuth sign-in connection) — see the custom-mcp
  skill. From an MCS agent the invoking identity is the signed-in maker/user, so the same per-user
  connection model applies.
- The Auth server additionally forwards the user's token to the BYO server; whether the MCS OAuth-tool
  token is forwarded with the shape the BYO server expects (`authorization_token_forwarded: true`) is
  UNVERIFIED. Treat Anon as "likely works (NoAuth)", Auth as "needs validation".

Recommendation: offer Mail as the supported MCP integration for MCS today; offer Anon/Auth as an
**opt-in experimental** step with the caveats above, and validate before relying on them. Do not claim
Auth works until a whoami test returns `authorization_token_forwarded: true` from an MCS agent.

## Automation boundary
The Entra side (app + permission + consent) is fully scriptable (`New-McsMcpClientApp.ps1`). The MCP tool
addition + connection in Copilot Studio is an **interactive maker-portal step** (not pac-scriptable), so
the wizard treats it as a guided step with the exact field values above.
