"""Instance identity for the Digital Worker samples: greet and answer with the INSTANCE name.

One container (ACA-DW) or hosted agent (FH-DW) serves EVERY instance hired from the same agent template, and each
instance is an agent user with its own display name (e.g. "Contoso Protocol Desk Milan"). The name is therefore read
from each activity (``activity.recipient.name`` = the agent user that received it) instead of being hard-coded or
taken from the Python class name. ``AGENT_DISPLAY_NAME`` (env) is only the fallback when the channel omits it.

The agent instructions are built once and shared by every instance and caller of the process, so
:func:`with_identity` prepends a short per-turn system note with the instance name and the current caller.

Greetings are in English on purpose (the customer's language is unknown); a lab can localize them.
KEEP THIS FILE BYTE-IDENTICAL in aca/dw/ and foundry-hosted/dw/src/hello_world_a365_agent/ (the Lab Builder
scaffolder warns if the copies drift).
"""

from __future__ import annotations

import os
from typing import Any, Optional


def agent_display_name(context: Any) -> Optional[str]:
    """Display name of the instance that received the activity, else ``AGENT_DISPLAY_NAME``, else ``None``."""
    try:
        recipient = getattr(getattr(context, "activity", None), "recipient", None)
        name = (getattr(recipient, "name", None) or "").strip()
    except Exception:
        name = ""
    return name or (os.environ.get("AGENT_DISPLAY_NAME", "").strip() or None)


def welcome_text(agent_name: Optional[str]) -> str:
    who = f"**{agent_name}**, your AI teammate" if agent_name else "your AI teammate"
    return f"👋 **Hi there!** I'm {who}.\n\nHow can I help you today?"


def hired_text(agent_name: Optional[str]) -> str:
    who = f" I'm **{agent_name}**." if agent_name else ""
    return f"Thank you for hiring me!{who} Looking forward to assisting you in your professional journey!"


def goodbye_text() -> str:
    return "Thank you for your time, I enjoyed working with you."


def with_identity(turn_input: Any, agent_name: Optional[str], user_name: Optional[str] = None) -> Any:
    """Prepend a per-turn system note (instance name + current caller) to an Agent Framework turn input.

    ``turn_input`` is a plain string or a message list (see ``conversation_memory.to_messages``). Returns it
    unchanged when neither name is known.
    """
    parts = []
    if agent_name:
        parts.append(f"Your name (the name of this agent instance) is \"{agent_name}\": always use it when you "
                     "introduce yourself or sign a message.")
    if user_name:
        parts.append(f"You are talking with: {user_name}.")
    if not parts:
        return turn_input
    from agent_framework import Message

    note = Message("system", [" ".join(parts)])
    if isinstance(turn_input, str):
        return [note, Message("user", [turn_input])]
    return [note] + list(turn_input)
