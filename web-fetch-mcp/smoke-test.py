"""Smoke test for a deployed web-fetch MCP server (needs `pip install fastmcp`).

Usage:  python smoke-test.py https://<prefix>-webfetch-ca.<env>.azurecontainerapps.io/mcp
Exit 0 = 'fetch_url' is listed and returns HTTP 200 for https://example.com/ and refuses the
Azure metadata endpoint (SSRF guard). The deploy script performs an equivalent check in PowerShell.
"""

import asyncio
import sys

from fastmcp import Client


async def main(url: str) -> int:
    async with Client(url) as client:
        tools = [t.name for t in await client.list_tools()]
        print("tools:", tools)
        if "fetch_url" not in tools:
            return 1
        ok = await client.call_tool("fetch_url", {"url": "https://example.com/", "max_chars": 300})
        ok_data = ok.structured_content or ok.data or {}
        print("fetch_url(https://example.com/):", str(ok_data)[:400])
        imds = await client.call_tool("fetch_url", {"url": "http://169.254.169.254/metadata/instance"})
        imds_data = imds.structured_content or imds.data or {}
        print("fetch_url(IMDS):", str(imds_data)[:300])
        if ok_data.get("http_status") != 200:
            return 2
        if imds_data.get("reachable"):
            return 3
        return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main(sys.argv[1])))
