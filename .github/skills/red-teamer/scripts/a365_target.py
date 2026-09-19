#!/usr/bin/env python3
"""PyRIT target adapter — reach an Agent 365 lab agent as a PyRIT PromptTarget.

This is the ONLY glue between Microsoft PyRIT (external, installed in .venv-redteam) and this
workspace. It subclasses PyRIT's ``PromptTarget`` and delegates the actual send to the **Prompts
Sender** engine (``send_prompts.py``), which already knows how to authenticate (MSAL SPA client,
delegated tokens) and how to shape the request/response for each agent ``kind`` (aca,
foundry-invocations, foundry-responses, foundry-prompt).

Design rules (see red-teamer/SKILL.md):
  * PyRIT is never vendored — only imported from the venv.
  * ``send_prompts.py`` is imported as a library and NEVER modified.
  * One target instance == one lab agent (selected by its config.js id).

Validated against PyRIT 1.1.0:
  * abstract method to implement is ``_send_prompt_to_target_async(*, normalized_conversation)``;
  * the current turn is ``normalized_conversation[-1]``; its text is ``message.get_value()``;
  * responses are built with ``construct_response_from_request(request=<MessagePiece>, ...)``.
"""
from __future__ import annotations

import asyncio
import os
import sys

from pyrit.models import Message, construct_response_from_request
from pyrit.prompt_target import PromptTarget
from pyrit.prompt_target.common.target_capabilities import TargetCapabilities
from pyrit.prompt_target.common.target_configuration import TargetConfiguration

# Import the Prompts Sender engine as a library (never modified). It lives in a sibling skill folder.
_HERE = os.path.dirname(os.path.abspath(__file__))
_PS_DIR = os.path.abspath(os.path.join(_HERE, "..", "..", "prompts-sender", "scripts"))
if _PS_DIR not in sys.path:
    sys.path.insert(0, _PS_DIR)
import send_prompts as ps  # noqa: E402


class A365LabTarget(PromptTarget):
    """A PyRIT target that sends a single-turn text prompt to one Agent 365 lab agent."""

    # Multi-turn attacks (crescendo/red_teaming/tap/pair) require the target to natively advertise
    # multi-turn + editable-history support. The lab agents are stateless, so in multi_turn mode this
    # adapter flattens the whole normalized conversation into one request (mode: flattened-transcript);
    # from PyRIT's perspective the capability is provided natively (no history squashing/adaptation).
    _DEFAULT_CONFIGURATION = TargetConfiguration(
        capabilities=TargetCapabilities(
            supports_multi_turn=True,
            supports_editable_history=True,
            supports_system_prompt=True,
        )
    )

    def __init__(
        self,
        *,
        config_path: str,
        agent_id: str,
        cache_path: str | None = None,
        user: str | None = None,
        multi_turn: bool = False,
        custom_configuration: TargetConfiguration | None = None,
    ) -> None:
        super().__init__(custom_configuration=custom_configuration)
        self._cfg = ps.load_config(config_path)
        agents = {a["id"]: a for a in self._cfg.get("agents", [])}
        if agent_id not in agents:
            raise ValueError(f"Unknown agent id '{agent_id}'. Available: {sorted(agents)}")
        self._agent = agents[agent_id]
        self._agent_id = agent_id
        self._cache_path = cache_path or ps.DEFAULT_CACHE
        self._user = user
        # Multi-turn attacks (crescendo/red_teaming/tap/pair) drive a growing conversation. The lab
        # agents are stateless per call, so in multi_turn mode we flatten the accumulated turns into
        # a single transcript (mode: flattened-transcript) — send_prompts.py is never modified.
        self._multi_turn = multi_turn

    @property
    def agent_id(self) -> str:
        return self._agent_id

    def _validate_request(self, *, normalized_conversation: list[Message]) -> None:
        if not normalized_conversation:
            raise ValueError("Empty conversation.")
        pieces = normalized_conversation[-1].message_pieces
        if len(pieces) != 1:
            raise ValueError("A365LabTarget only supports a single text piece per turn.")
        if pieces[0].converted_value_data_type != "text":
            raise ValueError("A365LabTarget only supports text prompts.")

    def _compose_prompt(self, conversation: list[Message]) -> str:
        """Single-turn: the last message text. Multi-turn: flatten the prior turns into a transcript so
        a stateless lab agent still 'sees' the accumulated conversation context."""
        if not self._multi_turn or len(conversation) <= 1:
            return conversation[-1].get_value()
        labels = {"user": "User", "assistant": "Assistant", "system": "System"}
        lines = []
        for msg in conversation[:-1]:
            role = getattr(msg.message_pieces[0], "role", "user")
            lines.append(f"{labels.get(role, str(role).capitalize())}: {msg.get_value()}")
        current = conversation[-1].get_value()
        return (
            "Continue this conversation. Earlier turns are provided for context only:\n"
            + "\n".join(lines)
            + "\n\nUser: "
            + current
        )

    async def _send_prompt_to_target_async(self, *, normalized_conversation: list[Message]) -> list[Message]:
        message = normalized_conversation[-1]
        request = message.message_pieces[0]
        prompt_text = self._compose_prompt(normalized_conversation)

        # send_prompts.send_to_agent is synchronous (requests + MSAL); run it off the event loop.
        loop = asyncio.get_running_loop()
        out = await loop.run_in_executor(
            None,
            lambda: ps.send_to_agent(self._cfg, self._cache_path, self._user, self._agent, prompt_text),
        )
        reply = out.get("reply")
        if reply is None:
            reply = out.get("raw") or ""
        response = construct_response_from_request(request=request, response_text_pieces=[str(reply)])
        return [response]

    async def cleanup_target_async(self) -> None:
        """No persistent resources to release (auth/token cache is owned by send_prompts)."""
        return None
