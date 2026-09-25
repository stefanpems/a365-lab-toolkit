"""Short conversation memory for the Agent 365 lab agents (the last N user/assistant exchanges).

Two carriers, chosen for MINIMUM infrastructure (no database, no cache, no new Azure resource):

* **Client-carried window** (web-UI agents: ACA-OBO/S2S, FH-OBO; FH-S2S and FD get it as a Responses
  ``input`` list). The SPA keeps the conversation in the browser and sends the last N exchanges with
  every request; the agent re-validates it with :func:`sanitize_history` and prepends it to the turn
  (:func:`to_messages`). Stateless on the server, so it works with any number of replicas/restarts.
* **In-process window** (:class:`ConversationMemory`) for the Digital Workers (ACA-DW / FH-DW): Teams /
  Bot Framework sends no history, so the agent keeps a small per-conversation sliding window in memory,
  keyed by the Bot Framework conversation id + the caller. It is lost on restart and is NOT shared
  across replicas (the lab's DW containers run a single replica). A durable store (e.g. Azure Table /
  Blob / Cosmos DB) is the upgrade path if persistence across restarts is ever needed.

Guardrails: only ``user`` / ``assistant`` roles are accepted (never ``system``/``tool`` — a client can't
inject instructions through the history), each message is truncated, and the window is re-capped
server-side whatever the client sends. ``MEMORY_TURNS`` (env, default 3; 0 disables) sets the window.

KEEP THIS FILE BYTE-IDENTICAL in every agent sample that ships it: aca/{obo,s2s,dw}/,
foundry-hosted/obo/ and foundry-hosted/dw/src/hello_world_a365_agent/ (canonical copy: aca/obo/; the
Lab Builder scaffolder warns if a copy drifts). FH-S2S and FD need no copy: the web UI sends them the
window as a Responses ``input`` message list, which the platform handles natively.
"""

from __future__ import annotations

import os
import threading
import time
from collections import OrderedDict
from typing import Any


def _int_env(name: str, default: int) -> int:
    try:
        return max(0, int(os.environ.get(name, default)))
    except (TypeError, ValueError):
        return default


MAX_TURNS = _int_env("MEMORY_TURNS", 3)                     # exchanges (user + assistant) kept
MAX_CHARS_PER_MESSAGE = _int_env("MEMORY_MAX_CHARS", 4000)  # per remembered message
MAX_CONVERSATIONS = _int_env("MEMORY_MAX_CONVERSATIONS", 500)  # in-process LRU cap (DW)
TTL_SECONDS = _int_env("MEMORY_TTL_SECONDS", 3600)          # idle expiry of an in-process window (DW)

_ROLES = ("user", "assistant")


def sanitize_history(raw: Any, max_turns: int | None = None, max_chars: int | None = None) -> list[dict[str, str]]:
    """Normalize a client-supplied history into ``[{"role", "content"}]``.

    Keeps only well-formed ``user`` / ``assistant`` text messages, truncates each one, returns at most
    the last ``max_turns`` exchanges (``2 * max_turns`` messages) and never starts on an assistant turn.
    Anything malformed yields ``[]`` (the turn simply runs without memory).
    """
    turns = MAX_TURNS if max_turns is None else max(0, max_turns)
    limit = MAX_CHARS_PER_MESSAGE if max_chars is None else max(1, max_chars)
    if turns == 0 or not isinstance(raw, list):
        return []
    clean: list[dict[str, str]] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        role = str(item.get("role", "")).strip().lower()
        content = item.get("content")
        if role not in _ROLES or not isinstance(content, str) or not content.strip():
            continue
        clean.append({"role": role, "content": content.strip()[:limit]})
    clean = clean[-(2 * turns):]
    while clean and clean[0]["role"] != "user":
        clean.pop(0)
    return clean


def to_messages(history: list[dict[str, str]], message: str) -> Any:
    """Build the Agent Framework input for one turn: the remembered exchanges + the new user message.

    Returns the plain string when there is no history (identical to the pre-memory behavior).
    """
    if not history:
        return message
    from agent_framework import Message

    msgs = [Message(h["role"], [h["content"]]) for h in history]
    msgs.append(Message("user", [message]))
    return msgs


class ConversationMemory:
    """In-process per-conversation sliding window (Digital Workers). Thread-safe, bounded, expiring."""

    def __init__(
        self,
        max_turns: int | None = None,
        max_conversations: int | None = None,
        ttl_seconds: int | None = None,
        max_chars: int | None = None,
    ) -> None:
        self.max_turns = MAX_TURNS if max_turns is None else max(0, max_turns)
        self.max_conversations = MAX_CONVERSATIONS if max_conversations is None else max(1, max_conversations)
        self.ttl_seconds = TTL_SECONDS if ttl_seconds is None else max(0, ttl_seconds)
        self.max_chars = MAX_CHARS_PER_MESSAGE if max_chars is None else max(1, max_chars)
        self._data: OrderedDict[str, tuple[float, list[dict[str, str]]]] = OrderedDict()
        self._lock = threading.Lock()

    @staticmethod
    def key_for(context: Any) -> str | None:
        """Conversation key from a Bot Framework TurnContext: conversation id + the caller's id."""
        try:
            activity = context.activity
            conv = getattr(getattr(activity, "conversation", None), "id", None)
            frm = getattr(activity, "from_property", None)
            who = getattr(frm, "aad_object_id", None) or getattr(frm, "id", None) or ""
            return f"{conv}|{who}" if conv else None
        except Exception:
            return None

    def get(self, key: str | None) -> list[dict[str, str]]:
        if not key or self.max_turns == 0:
            return []
        with self._lock:
            entry = self._data.get(key)
            if not entry:
                return []
            stamp, msgs = entry
            if self.ttl_seconds and time.monotonic() - stamp > self.ttl_seconds:
                del self._data[key]
                return []
            return [dict(m) for m in msgs]

    def add_exchange(self, key: str | None, user_message: str, assistant_reply: str) -> None:
        if not key or self.max_turns == 0 or not user_message or not assistant_reply:
            return
        with self._lock:
            _, msgs = self._data.get(key, (0.0, []))
            msgs = msgs + [
                {"role": "user", "content": user_message.strip()[: self.max_chars]},
                {"role": "assistant", "content": assistant_reply.strip()[: self.max_chars]},
            ]
            self._data[key] = (time.monotonic(), msgs[-(2 * self.max_turns):])
            self._data.move_to_end(key)
            while len(self._data) > self.max_conversations:
                self._data.popitem(last=False)

    def clear(self, key: str | None) -> None:
        if key:
            with self._lock:
                self._data.pop(key, None)
