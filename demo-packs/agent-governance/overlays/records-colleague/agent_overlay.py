"""Demo-pack overlay of the records-office AI teammate (ACA-DW): role prompt, in-process registration tool and
localized greetings / per-turn identity notes (OVERLAY_TEXTS, read by agent_identity.py). All data is fictional.
"""

import itertools
from datetime import datetime, timezone

from overlay_tools import ORG, OVERLAY, make_tool

OVERLAY_PROMPT = OVERLAY.get("rolePrompt", "")
OVERLAY_TEXTS = dict(OVERLAY.get("texts", {}))

_COUNTER = itertools.count(123)


async def _register(sender: str, subject: str, attachments: int = 0) -> dict:
    now = datetime.now(timezone.utc)
    return {
        "record_number": f"{ORG.get('recordIdPrefix', 'REC-')}{next(_COUNTER):06d} {ORG.get('fictionalSuffix', '')}".strip(),
        "date": now.strftime("%d/%m/%Y %H:%M UTC"),
        "sender": sender,
        "subject": subject,
        "attachments": attachments,
        "office": OVERLAY.get("strings", {}).get("office", ""),
    }


OVERLAY_TOOLS = [
    make_tool(OVERLAY["tools"]["register"], _register, {"sender": str, "subject": str, "attachments": int}, defaults={"attachments": 0}),
]
