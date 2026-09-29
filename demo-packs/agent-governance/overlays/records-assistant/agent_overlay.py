"""Demo-pack overlay of the records assistant (ACA-OBO): localized role prompt only.

The records tools come from the registered BYO MCP server (Agent 365 gateway) attached to the agent; the prompt
names them so the model picks them. By design the prompt does NOT restrict recipients or contents: the demo shows
the platform real-time protection doing that (D16, variant B).
"""

from overlay_tools import OVERLAY

OVERLAY_PROMPT = OVERLAY.get("rolePrompt", "")
OVERLAY_TOOLS: list = []
