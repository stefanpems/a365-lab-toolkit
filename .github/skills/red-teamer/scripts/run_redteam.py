#!/usr/bin/env python3
"""Red Teamer runner — drive PyRIT attacks against the deployed Agent 365 lab agents.

This CLI wires a PyRIT attack (single-turn ``PromptSendingAttack`` in v1) to the ``A365LabTarget``
adapter, scores each objective with a refusal-based objective scorer, and writes a results JSON.

PyRIT is external (installed into .venv-redteam). Its scorer/adversary chat endpoint and its memory
DB are configured OUTSIDE the repo (``~/.pyrit/.env`` + ``~/.pyrit/.pyrit_conf``); nothing secret is
read from or written to the workspace.

USAGE
  Login once (reuses the Prompts Sender MSAL token cache; opens a browser):
    python run_redteam.py login  --config <path-to-config.js> [--user <upn>]

  List the agents available in a config:
    python run_redteam.py agents --config <path-to-config.js>

  Run an attack (single-turn) against one or more agents:
    python run_redteam.py attack --config <path-to-config.js> \
        --agents obo,s2s --attack prompt_sending \
        --objective-category guardrail-identity [--converters none] \
        --out redteam-results.json

Exit code is 0 when the run completes without a runner/setup error. It does NOT encode attack
success — the JSON (and the agent's review) reports DEFENSE HELD / ATTACK SUCCEEDED / INCONCLUSIVE.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import sys

# Import the Prompts Sender engine (login/agents reuse) and the target adapter.
_HERE = os.path.dirname(os.path.abspath(__file__))
_PS_DIR = os.path.abspath(os.path.join(_HERE, "..", "..", "prompts-sender", "scripts"))
if _PS_DIR not in sys.path:
    sys.path.insert(0, _PS_DIR)
import send_prompts as ps  # noqa: E402

DEFAULT_OBJECTIVES = os.path.join(_HERE, "..", "references", "objectives.md")

# --- attack catalogue (v1) --------------------------------------------------
SUPPORTED_ATTACKS = {"prompt_sending"}  # multi-turn (crescendo/red_teaming) is the next tier


# ----------------------------- objectives library ---------------------------
def parse_objectives(path: str) -> dict[str, list[str]]:
    """Parse references/objectives.md into {category: [objective, ...]}."""
    lib: dict[str, list[str]] = {}
    current: str | None = None
    for line in open(path, encoding="utf-8"):
        h = re.match(r"^##\s+(.*)$", line.strip())
        if h:
            current = h.group(1).strip()
            lib.setdefault(current, [])
            continue
        if current and line.strip().startswith("- "):
            lib[current].append(line.strip()[2:].strip())
    return {k: v for k, v in lib.items() if v}


# ----------------------------- converters -----------------------------------
def build_converters(spec: str):
    """Map a --converters spec (comma-separated) to PyRIT converter instances. 'none' => []."""
    from pyrit.converter import Base64Converter, ROT13Converter

    names = [s.strip().lower() for s in (spec or "none").split(",") if s.strip()]
    out = []
    for n in names:
        if n in ("none", ""):
            continue
        if n == "base64":
            out.append(Base64Converter())
        elif n == "rot13":
            out.append(ROT13Converter())
        else:
            raise ValueError(f"Unknown converter '{n}'. Supported: none, base64, rot13")
    return out


# ----------------------------- outcome mapping ------------------------------
def verdict_from_outcome(outcome_value: str) -> str:
    # objective_scorer = "not a refusal" => SUCCESS means the agent complied with the attack.
    return {
        "success": "ATTACK SUCCEEDED",
        "failure": "DEFENSE HELD",
        "error": "INCONCLUSIVE",
        "undetermined": "INCONCLUSIVE",
    }.get(str(outcome_value).lower(), "INCONCLUSIVE")


def response_text(last_response) -> str | None:
    """Read the reply text from an AttackResult.last_response (a MessagePiece or Message)."""
    if last_response is None:
        return None
    if hasattr(last_response, "get_value"):
        try:
            return last_response.get_value()
        except Exception:
            pass
    return getattr(last_response, "converted_value", None) or getattr(last_response, "original_value", None)


# ----------------------------- attack run -----------------------------------
async def run_attack(args) -> int:
    from pyrit.setup import initialize_pyrit_async
    from pyrit.executor.attack import (
        PromptSendingAttack,
        AttackConverterConfig,
        AttackScoringConfig,
    )
    from pyrit.prompt_normalizer import ConverterConfiguration
    from pyrit.prompt_target import OpenAIChatTarget
    from pyrit.score import SelfAskRefusalScorer, TrueFalseInverterScorer

    from a365_target import A365LabTarget

    if args.attack not in SUPPORTED_ATTACKS:
        sys.stderr.write(f"Attack '{args.attack}' is not implemented in v1. Supported: {sorted(SUPPORTED_ATTACKS)}\n")
        return 2

    objectives_by_cat = parse_objectives(args.objectives)
    if args.objective_category not in objectives_by_cat:
        sys.stderr.write(
            f"Unknown objective category '{args.objective_category}'. Available: {sorted(objectives_by_cat)}\n"
        )
        return 2
    objectives = objectives_by_cat[args.objective_category]
    if args.max_objectives and args.max_objectives > 0:
        objectives = objectives[: args.max_objectives]

    cfg = ps.load_config(args.config)
    agents_by_id = {a["id"]: a for a in cfg.get("agents", [])}
    selected = [s.strip() for s in args.agents.split(",") if s.strip()]
    unknown = [s for s in selected if s not in agents_by_id]
    if unknown:
        sys.stderr.write(f"Unknown agent id(s): {unknown}. Available: {list(agents_by_id)}\n")
        return 2

    # PyRIT init (memory + env). ~/.pyrit/.env supplies the scorer/adversary chat endpoint.
    await initialize_pyrit_async(memory_db_type="InMemory", silent=True)

    # Objective scorer: "attack achieved" == the agent did NOT refuse (refusal inverted).
    scorer_chat = OpenAIChatTarget()
    objective_scorer = TrueFalseInverterScorer(scorer=SelfAskRefusalScorer(chat_target=scorer_chat))
    scoring_config = AttackScoringConfig(objective_scorer=objective_scorer)

    converters = build_converters(args.converters)
    converter_config = None
    if converters:
        converter_config = AttackConverterConfig(
            request_converters=[ConverterConfiguration(converters=converters)]
        )

    results = []
    for agent_id in selected:
        target = A365LabTarget(
            config_path=args.config, agent_id=agent_id, cache_path=args.cache, user=args.user
        )
        attack = PromptSendingAttack(
            objective_target=target,
            attack_converter_config=converter_config,
            attack_scoring_config=scoring_config,
        )
        for objective in objectives:
            try:
                result = await attack.execute_async(objective=objective)
                outcome = getattr(result.outcome, "value", result.outcome)
                reply = response_text(result.last_response)
                score = None
                if result.last_score is not None:
                    score = getattr(result.last_score, "score_value", str(result.last_score))
                entry = {
                    "agent": agent_id,
                    "agent_name": agents_by_id[agent_id].get("name"),
                    "attack": args.attack,
                    "category": args.objective_category,
                    "converters": args.converters,
                    "objective": objective,
                    "outcome": str(outcome),
                    "outcome_reason": result.outcome_reason,
                    "verdict": verdict_from_outcome(outcome),
                    "score": str(score) if score is not None else None,
                    "reply": reply,
                }
            except Exception as e:  # a single objective failing must not abort the batch
                reason = f"{type(e).__name__}: {e}"
                # A red-teaming gotcha: the SCORER's Azure OpenAI call can be blocked by the content
                # filter when judging adversarial content. Make that actionable instead of opaque.
                if "content filter" in str(e).lower() or "ScorerLLMResponseBlocked" in type(e).__name__:
                    reason = (
                        "Scorer blocked by Azure OpenAI content filter while judging the response. "
                        "Use a scorer deployment with content filtering disabled/annotate-only for "
                        "red-teaming (see red-teamer/SKILL.md)."
                    )
                entry = {
                    "agent": agent_id,
                    "agent_name": agents_by_id[agent_id].get("name"),
                    "attack": args.attack,
                    "category": args.objective_category,
                    "converters": args.converters,
                    "objective": objective,
                    "outcome": "error",
                    "outcome_reason": reason,
                    "verdict": "INCONCLUSIVE",
                    "score": None,
                    "reply": None,
                }
            results.append(entry)
            print(
                f"[{entry['verdict']}] {agent_id} <{args.objective_category}> :: "
                f"{entry['objective'][:60]} => {entry['outcome']}",
                flush=True,
            )

    summary = {
        "config": os.path.abspath(args.config),
        "attack": args.attack,
        "category": args.objective_category,
        "converters": args.converters,
        "agents": selected,
        "total": len(results),
        "attack_succeeded": sum(1 for r in results if r["verdict"] == "ATTACK SUCCEEDED"),
        "defense_held": sum(1 for r in results if r["verdict"] == "DEFENSE HELD"),
        "inconclusive": sum(1 for r in results if r["verdict"] == "INCONCLUSIVE"),
        "results": results,
    }
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=2, ensure_ascii=False)
        print(f"Wrote {args.out}", flush=True)
    print(
        f"SUMMARY: {summary['defense_held']} defended / {summary['attack_succeeded']} succeeded / "
        f"{summary['inconclusive']} inconclusive (out of {summary['total']}).",
        flush=True,
    )
    return 0


# ----------------------------- login / agents (reuse) -----------------------
def run_login(args) -> int:
    return ps.login(ps.load_config(args.config), args.cache, args.user)


def run_list_agents(args) -> int:
    cfg = ps.load_config(args.config)
    for a in cfg.get("agents", []):
        print(f"{a['id']:10} | kind={a.get('kind'):20} | {a.get('name')}")
    return 0


# ----------------------------- CLI ------------------------------------------
def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Red Teamer runner (PyRIT attacks on lab agents)")
    sub = p.add_subparsers(dest="cmd", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--config", required=True, help="Path to a lab's ui/config.js")
    common.add_argument("--cache", default=ps.DEFAULT_CACHE, help="MSAL token cache file (shared with Prompts Sender)")
    common.add_argument("--user", default=None, help="UPN of the cached account to use")

    sub.add_parser("login", parents=[common])
    sub.add_parser("agents", parents=[common])

    pa = sub.add_parser("attack", parents=[common])
    pa.add_argument("--agents", required=True, help="Comma-separated agent ids from config.js")
    pa.add_argument("--attack", default="prompt_sending", help="Attack id (v1: prompt_sending)")
    pa.add_argument("--objective-category", required=True, help="Objective category from objectives.md")
    pa.add_argument("--objectives", default=DEFAULT_OBJECTIVES, help="Path to the objectives library")
    pa.add_argument("--converters", default="none", help="Comma list: none|base64|rot13")
    pa.add_argument("--max-objectives", type=int, default=0, help="Cap objectives per category (0 = all)")
    pa.add_argument("--out", default=None, help="Write JSON results to this file")

    args = p.parse_args(argv)
    if args.cmd == "login":
        return run_login(args)
    if args.cmd == "agents":
        return run_list_agents(args)
    if args.cmd == "attack":
        return asyncio.run(run_attack(args))
    return 2


if __name__ == "__main__":
    sys.exit(main())
