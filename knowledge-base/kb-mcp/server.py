"""
Knowledge-base MCP shim (NoAuth) for Agent 365.

STANDALONE — part of the knowledge-base toolkit, not Lab Builder. This single-container MCP
server exposes a SHARED INDEXED COPY of documents (an Azure AI Search index built by
ingest_docs.py) as a search tool that any OBO/S2S agent can call through the Agent 365 Tool
Gateway.

Design mirrors custom-mcp/server.py:
  * ONE server at the ROOT path '/mcp' (Agent 365 registration rejects multi-segment paths).
  * NoAuth: no caller token is forwarded. Because this is a *shared* copy (identical results for
    every caller, no per-user filtering), the server queries Azure AI Search with its OWN
    read-only QUERY key — supplied via the SEARCH_QUERY_KEY env var (an ACA secret). This is the
    correct model for the user's chosen "shared indexed copy"; it does NOT enforce per-user
    SharePoint permissions.

Environment:
  SEARCH_ENDPOINT    https://<service>.search.windows.net
  SEARCH_INDEX       index name (e.g. docs4agents-idx)
  SEARCH_QUERY_KEY   read-only query key
  PORT               listen port (default 8000)
"""

from __future__ import annotations

import os

from fastmcp import FastMCP

SEARCH_ENDPOINT = os.environ.get("SEARCH_ENDPOINT", "").rstrip("/")
SEARCH_INDEX = os.environ.get("SEARCH_INDEX", "")
SEARCH_QUERY_KEY = os.environ.get("SEARCH_QUERY_KEY", "")

mcp = FastMCP("knowledge-base")


def _search_client():
    from azure.core.credentials import AzureKeyCredential
    from azure.search.documents import SearchClient

    if not (SEARCH_ENDPOINT and SEARCH_INDEX and SEARCH_QUERY_KEY):
        raise RuntimeError(
            "Search configuration missing: set SEARCH_ENDPOINT, SEARCH_INDEX and SEARCH_QUERY_KEY."
        )
    return SearchClient(SEARCH_ENDPOINT, SEARCH_INDEX, AzureKeyCredential(SEARCH_QUERY_KEY))


@mcp.tool
def search_customer_docs(query: str, top: int = 5) -> dict:
    """Search the shared knowledge base (an indexed copy of the source documents) and return the
    most relevant passages with their title and source URL.

    Args:
        query: A natural-language question or keywords about the document content.
        top: Maximum number of passages to return (1-10).
    """
    top = max(1, min(int(top), 10))
    client = _search_client()
    results = client.search(
        search_text=query,
        top=top,
        query_type="semantic",
        semantic_configuration_name="default",
        select=["title", "content", "sourceUrl", "lastModified"],
    )
    passages = []
    for r in results:
        content = r.get("content", "") or ""
        # Trim very long documents so the tool response stays within a useful size.
        snippet = content if len(content) <= 4000 else content[:4000] + " …"
        passages.append({
            "title": r.get("title", ""),
            "sourceUrl": r.get("sourceUrl", ""),
            "lastModified": r.get("lastModified", ""),
            "score": r.get("@search.score"),
            "content": snippet,
        })
    return {
        "query": query,
        "index": SEARCH_INDEX,
        "count": len(passages),
        "results": passages,
        "note": "Shared indexed copy; results are identical for every caller (no per-user filtering).",
    }


@mcp.tool
def list_knowledge_titles() -> dict:
    """List the titles of the documents currently in the shared knowledge base."""
    client = _search_client()
    results = client.search(search_text="*", top=50, select=["title", "sourceUrl", "lastModified"])
    titles = [{"title": r.get("title", ""), "sourceUrl": r.get("sourceUrl", ""),
               "lastModified": r.get("lastModified", "")} for r in results]
    return {"index": SEARCH_INDEX, "count": len(titles), "documents": titles}


def _add_probes(app):
    """GET '/' and '/health' so ACA / Agent 365 reachability probes succeed."""
    from starlette.responses import JSONResponse

    async def health(_request):
        return JSONResponse({"status": "ok", "server": "/mcp", "index": SEARCH_INDEX})

    app.router.routes.append(_route("/", health))
    app.router.routes.append(_route("/health", health))
    return app


def _route(path, endpoint):
    from starlette.routing import Route
    return Route(path, endpoint)


def build_app():
    app = mcp.http_app(path="/mcp")
    return _add_probes(app)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(build_app(), host="0.0.0.0", port=int(os.environ.get("PORT", "8000")))
