"""Demo-pack overlay of the application-review agent (FD-OBO, Foundry prompt agent): localized role prompt + extra
tools applied by deploy_agent.py (OVERLAY_FD): the public Microsoft Learn MCP server WITHOUT an allowed-tools list
(an intentional weakness that Defender reports in D14) and a File search vector store built from ./knowledge
(the fictional application files and the review procedure of the chosen language).
"""

from overlay_tools import OVERLAY

OVERLAY_PROMPT = OVERLAY.get("rolePrompt", "")
OVERLAY_FD = {
    "mcp": [
        {"label": "microsoft_learn", "url": "https://learn.microsoft.com/api/mcp",
         "description": OVERLAY.get("learnMcpDescription", "Microsoft Learn"), "allowedTools": None},
    ],
    "fileSearch": {"storeName": OVERLAY.get("vectorStoreName", "knowledge"), "dir": "knowledge"},
}
