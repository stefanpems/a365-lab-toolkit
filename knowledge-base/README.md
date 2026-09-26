# Knowledge-base toolkit (standalone, post-hoc)

Attach a **shared, indexed copy** of SharePoint documents to the OBO and S2S agents of an
Agent 365 lab, as a searchable tool.

This toolkit is **standalone** and **not part of Lab Builder**. It runs **after** a lab has been
created by Lab Builder and only edits that lab's already-generated agent folders (plus its own
Azure resources). It never modifies Lab Builder itself, and its Azure resources are tagged
`a365component=knowledge-base` (never `a365lab`), so the Lab Cleaner never deletes them.

## What it builds

```
SharePoint (.docx …) ──ingest──▶ Azure AI Search index (shared copy)
                                        ▲
                                        │ query key (read-only)
                          kb-mcp shim (Azure Container App, NoAuth, /mcp)
                                        ▲
                                        │ Agent 365 Tool Gateway (ext_<name>)
        ACA-OBO/S2S · FH-OBO/S2S · FD-OBO  ── search_customer_docs ──▶
```

- **Shared indexed copy**: the documents are indexed once; every caller gets identical results.
  This does **not** enforce per-user SharePoint permissions. (For per-user permission passthrough
  you would use Foundry IQ remote SharePoint instead — a different, preview path.)
- The MCP shim mirrors the existing [`custom-mcp/`](../custom-mcp/) pattern (single server at the
  root `/mcp`, NoAuth), so it attaches to every agent family through the same
  `a365 develop add-mcp-servers` flow that the lab already uses.

## Prerequisites

- `az login` as a user who can create resources in the target subscription **and** read the
  SharePoint site (for the DIA lab: `admin@<tenant>.onmicrosoft.com`).
- Azure CLI, the `containerapp` extension (installed automatically), Python 3.10+, and the
  `a365` CLI for registration/attach.
- Same Microsoft Entra tenant for Azure and SharePoint.

## Steps

```powershell
cd knowledge-base

# 1-3 in one go (provision search + ingest docs + deploy the MCP shim):
./run-all.ps1 -Subscription <sub> -ResourceGroup kb-docs4agents-rg -Location swedencentral `
    -SearchService kbdocs4agents<rand> `
    -FolderUrl "https://<tenant>.sharepoint.com/sites/docs4agents/Shared%20Documents/Forms/AllItems.aspx"

# 4. Register the server in Agent 365 (prompts; dry-run first):
a365 develop-mcp register-external-mcp-server -f .\register-kb.json --dry-run
a365 develop-mcp register-external-mcp-server -f .\register-kb.json
#    Then APPROVE it in the M365 admin center (Agents > Tools).

# 5. Attach to every OBO/S2S agent of the lab (edits ToolingManifest.json / .env only):
./attach-to-lab.ps1 -LabPrefix lab12

# 6. Redeploy the agents you attached (the script prints the exact per-agent commands):
#    ACA -> ./deploy-aca.ps1   FH -> azd deploy   FD -> python deploy_agent.py
```

You can also run the steps individually: `provision-search.ps1`, `ingest/ingest_docs.py`,
`deploy-kb-mcp.ps1`, then `attach-to-lab.ps1`. Every step is idempotent and re-runnable.

## Files

| File | Purpose |
| --- | --- |
| `provision-search.ps1` | Create/reuse Azure AI Search; record endpoint + keys in `kb.state.json`. |
| `ingest/ingest_docs.py` | Download SharePoint files via Graph, extract text, upload to the index. |
| `kb-mcp/` | NoAuth MCP shim (`server.py`, `Dockerfile`, `requirements.txt`) querying the index. |
| `deploy-kb-mcp.ps1` | Build + deploy the shim to ACA; render `register-kb.json`. |
| `register-kb.template.json` | Agent 365 registration payload template. |
| `attach-to-lab.ps1` | Attach the registered server to a lab's OBO/S2S agents (post-hoc). |
| `run-all.ps1` | Orchestrate steps 1–3. |

## Notes & limitations

- `kb.state.json` holds the search keys and is **gitignored** — do not commit it.
- The copy is a **snapshot**: later edits in SharePoint are not synced. Re-run
  `ingest/ingest_docs.py` to refresh the index.
- `FD-S2S` is skipped: Foundry declarative S2S has no tool-attach path.
- **DW agents** (ACA-DW, FH-DW) are attached best-effort via the same gateway flow (agentic identity).
- Attaching updates each agent's tool config only; a **redeploy** is required to take effect.
- Teardown: delete the resource group `kb-docs4agents-rg` and, in Agent 365, unregister the
  `ext_<name>` server (see `custom-mcp/cleanup-registration.ps1` for the pattern).

## Known caveats (observed in real tenants)

- **File download auth.** In tenants where the Azure CLI's delegated Graph token lacks
  `Files.Read.All`/`Sites.Read.All`, SharePoint download URLs return 401. Use an **app-only**
  Graph token (an app with `Sites.Read.All`, admin-consented) by setting
  `KB_GRAPH_TENANT_ID` / `KB_GRAPH_CLIENT_ID` / `KB_GRAPH_CLIENT_SECRET` before running the ingest.
- **Encrypted Office files.** A password-encrypted `.docx` (OLE2 with an `EncryptedPackage`
  stream) can't be indexed without its password. Provide it with `--doc-password` or the
  `KB_DOC_PASSWORD` env var (type it directly into the terminal; never commit it). Without it the
  file is skipped with a clear message and the others still index.
- **Registration name reserved after a failure.** A failed `register-external-mcp-server` can
  leave a Power Platform custom connector that reserves the display name (`<serverName>P`), causing
  `ApiDisplayNameIsInUse` on retry. Remove the leftover connector (see
  `custom-mcp/cleanup-registration.ps1`) or choose a fresh `-ServerName`.
- **Tenant admin approval.** After registration the server must be approved by a tenant admin in
  the Microsoft 365 admin center (Agents > Tools) before the gateway routes calls at runtime.
  Attaching the tool to agents does not require approval; runtime invocation does.
