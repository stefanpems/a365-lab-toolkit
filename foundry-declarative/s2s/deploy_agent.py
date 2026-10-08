"""Deploy (create/update) the S2S Foundry *declarative* (prompt) agent — no manual portal steps.

Creates a new immutable agent **version** in the Foundry project with:
  * model        = FOUNDRY_MODEL_NAME (default gpt-4.1)
  * instructions = AGENT_PROMPT
  * tools        = only the web-access 'fetch_url' MCP tool (when WEB_FETCH_MCP_URL is set);
                   no Mail / user-data tools — acts with its own identity.

Auth to create the version uses DefaultAzureCredential (your `az login`). You need a role on
the Foundry project that allows agent authoring (e.g. Azure AI User / Cognitive Services User).
"""

from __future__ import annotations

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import MCPTool, PromptAgentDefinition
from azure.identity import DefaultAzureCredential

import time

import agent_config as cfg


def _overlay_tools(project) -> list:
    """Extra tools of a demo-pack overlay (cfg.OVERLAY_FD): MCP servers and a File search vector store."""
    extra = []
    for m in cfg.OVERLAY_FD.get("mcp", []):
        kw = dict(server_label=m["label"], server_url=m["url"], require_approval="never")
        if m.get("description"):
            kw["server_description"] = m["description"]
        if m.get("allowedTools"):
            kw["allowed_tools"] = m["allowedTools"]
        extra.append(MCPTool(**kw))
    fs = cfg.OVERLAY_FD.get("fileSearch")
    if fs:
        import glob
        import os

        folder = os.path.join(os.path.dirname(os.path.abspath(__file__)), fs.get("dir", "knowledge"))
        files = sorted(glob.glob(os.path.join(folder, "*")))
        from azure.ai.projects.models import FileSearchTool

        if not files:
            raise SystemExit(f"ERROR: overlay File search: no files in {folder}.")
        # The overlay's knowledge IS the agent: a version without it must never be created silently. One retry
        # covers a transient failure (e.g. the first az token request timing out); then the deploy stops.
        for attempt in (1, 2):
            try:
                oai = project.get_openai_client()
                store = oai.vector_stores.create(name=fs.get("storeName", "knowledge"))
                for path in files:
                    with open(path, "rb") as fh:
                        oai.vector_stores.files.upload_and_poll(vector_store_id=store.id, file=fh)
                    print(f"File search: indexed {os.path.basename(path)}")
                extra.append(FileSearchTool(vector_store_ids=[store.id]))
                break
            except Exception as exc:
                if attempt == 2:
                    raise SystemExit(f"ERROR: overlay File search not configured ({exc}). Fix it and re-run (nothing was deployed).")
                print(f"WARNING: overlay File search failed ({exc}); retrying once in 15 s...")
                time.sleep(15)
    return extra


def main() -> None:
    # One credential for every call; process_timeout 60 s: the default 10 s of the Azure CLI credential can expire on the
    # first, cold 'az account get-access-token' (seen with a fresh az profile).
    project = AIProjectClient(endpoint=cfg.PROJECT_ENDPOINT, credential=DefaultAzureCredential(process_timeout=60))

    tools = []
    # Web access: the lab's web-fetch MCP server's 'fetch_url' (anonymous), attached directly (no token).
    if cfg.WEB_FETCH_MCP_URL:
        tools.append(
            MCPTool(
                server_label="web_fetch",
                server_url=cfg.WEB_FETCH_MCP_URL,
                server_description="Checks whether a public web page is reachable (HTTP status) and reads its text.",
                require_approval="never",
                allowed_tools=["fetch_url"],
            )
        )

    # Demo-pack overlay (none in a plain lab).
    tools.extend(_overlay_tools(project))

    definition = PromptAgentDefinition(
        model=cfg.MODEL,
        instructions=cfg.AGENT_PROMPT,
        tools=tools or None,
    )

    agent = project.agents.create_version(agent_name=cfg.AGENT_NAME, definition=definition)
    print(f"Deployed prompt agent: name={agent.name} version={agent.version}")
    print(f"Project: {cfg.PROJECT_ENDPOINT}")
    print(f"Model:   {cfg.MODEL}")


if __name__ == "__main__":
    main()
