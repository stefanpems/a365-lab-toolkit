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

# --- attack catalogue -------------------------------------------------------
# needs_adversary : requires an adversarial LLM (OpenAIChatTarget read from ~/.pyrit/.env).
# multi_turn      : the target must receive the accumulated conversation; the adapter flattens it
#                   into a single transcript because the lab agents are stateless per call.
# scoring         : 'standard'  -> AttackScoringConfig(objective_scorer = refusal-inverted LLM judge)
#                   'crescendo' -> empty AttackScoringConfig (Crescendo builds its default float scorer)
#                   'tap'       -> None (TAP/PAIR build the default FloatScaleThresholdScorer)
ATTACK_SPECS = {
    "prompt_sending": {"needs_adversary": False, "multi_turn": False, "scoring": "standard"},
    "many_shot":      {"needs_adversary": False, "multi_turn": False, "scoring": "standard"},
    "skeleton_key":   {"needs_adversary": False, "multi_turn": False, "scoring": "standard"},
    "crescendo":      {"needs_adversary": True,  "multi_turn": True,  "scoring": "crescendo"},
    "red_teaming":    {"needs_adversary": True,  "multi_turn": True,  "scoring": "standard"},
    "tap":            {"needs_adversary": True,  "multi_turn": True,  "scoring": "tap"},
    "pair":           {"needs_adversary": True,  "multi_turn": True,  "scoring": "tap"},
}
SUPPORTED_ATTACKS = set(ATTACK_SPECS)


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


# ----------------------------- attack factory -------------------------------
def build_objective_scorer(scorer_chat):
    """The refusal-inverted LLM judge: 'attack achieved' == the agent did NOT refuse."""
    from pyrit.score import SelfAskRefusalScorer, TrueFalseInverterScorer

    return TrueFalseInverterScorer(scorer=SelfAskRefusalScorer(chat_target=scorer_chat))


def build_scoring_config(scoring_kind: str, scorer_chat):
    """Return the attack_scoring_config for a scoring kind (None => PyRIT builds its own default)."""
    from pyrit.executor.attack import AttackScoringConfig

    if scoring_kind == "standard":
        return AttackScoringConfig(objective_scorer=build_objective_scorer(scorer_chat))
    if scoring_kind == "crescendo":
        # Empty config => CrescendoAttack builds its default TASK_ACHIEVED float-scale scorer.
        return AttackScoringConfig()
    if scoring_kind == "tap":
        # None => TAP/PAIR build the default FloatScaleThresholdScorer (threshold 0.7).
        return None
    raise ValueError(f"Unknown scoring kind: {scoring_kind}")


def build_adversarial_config():
    """The adversarial LLM that drives multi-turn attacks (OpenAIChatTarget from ~/.pyrit/.env)."""
    from pyrit.executor.attack import AttackAdversarialConfig
    from pyrit.prompt_target import OpenAIChatTarget

    return AttackAdversarialConfig(target=OpenAIChatTarget())


def build_attack(attack_id: str, *, target, scoring, converter_config, adversarial, args):
    """Construct the PyRIT attack instance for one agent target."""
    from pyrit.executor.attack import (
        CrescendoAttack,
        ManyShotJailbreakAttack,
        PAIRAttack,
        PromptSendingAttack,
        RedTeamingAttack,
        SkeletonKeyAttack,
        TreeOfAttacksWithPruningAttack,
    )

    if attack_id == "prompt_sending":
        return PromptSendingAttack(
            objective_target=target,
            attack_converter_config=converter_config,
            attack_scoring_config=scoring,
        )
    if attack_id == "many_shot":
        return ManyShotJailbreakAttack(
            objective_target=target,
            attack_scoring_config=scoring,
            example_count=args.example_count,
        )
    if attack_id == "skeleton_key":
        return SkeletonKeyAttack(objective_target=target, attack_scoring_config=scoring)
    if attack_id == "crescendo":
        return CrescendoAttack(
            objective_target=target,
            attack_adversarial_config=adversarial,
            attack_scoring_config=scoring,
            max_turns=args.max_turns,
            max_backtracks=args.max_backtracks,
        )
    if attack_id == "red_teaming":
        return RedTeamingAttack(
            objective_target=target,
            attack_adversarial_config=adversarial,
            attack_scoring_config=scoring,
            max_turns=args.max_turns,
        )
    if attack_id == "tap":
        return TreeOfAttacksWithPruningAttack(
            objective_target=target,
            attack_adversarial_config=adversarial,
            attack_scoring_config=scoring,
            tree_width=args.tree_width,
            tree_depth=args.tree_depth,
            branching_factor=args.branching_factor,
        )
    if attack_id == "pair":
        return PAIRAttack(
            objective_target=target,
            attack_adversarial_config=adversarial,
            attack_scoring_config=scoring,
            tree_width=args.tree_width,
            tree_depth=args.tree_depth,
        )
    raise ValueError(f"Unsupported attack: {attack_id}")


def _is_content_filter_block(e: Exception) -> bool:
    """True when an exception is an Azure OpenAI content-filter / prompt-shield block (scorer or adversary)."""
    msg = str(e).lower()
    needles = ("content filter", "content_filter", "content management policy", "responsibleaipolicy")
    return any(n in msg for n in needles) or "ScorerLLMResponseBlocked" in type(e).__name__


# ----------------------------- attack run -----------------------------------
async def run_attack(args) -> int:
    from pyrit.setup import initialize_pyrit_async
    from pyrit.executor.attack import AttackConverterConfig
    from pyrit.prompt_normalizer import ConverterConfiguration
    from pyrit.prompt_target import OpenAIChatTarget

    from a365_target import A365LabTarget

    if args.attack not in ATTACK_SPECS:
        sys.stderr.write(
            f"Attack '{args.attack}' is not supported. Supported: {sorted(ATTACK_SPECS)}\n"
        )
        return 2
    spec = ATTACK_SPECS[args.attack]

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

    scorer_chat = OpenAIChatTarget()
    scoring = build_scoring_config(spec["scoring"], scorer_chat)

    adversarial = None
    if spec["needs_adversary"]:
        try:
            adversarial = build_adversarial_config()
        except Exception as e:  # a missing/unreachable adversary endpoint must fail clearly, not silently
            sys.stderr.write(
                f"Attack '{args.attack}' requires an adversary LLM, but it could not be built from "
                f"~/.pyrit/.env: {type(e).__name__}: {e}\n"
            )
            return 2

    converters = build_converters(args.converters)
    converter_config = None
    if converters:
        converter_config = AttackConverterConfig(
            request_converters=[ConverterConfiguration(converters=converters)]
        )

    results = []
    for agent_id in selected:
        target = A365LabTarget(
            config_path=args.config,
            agent_id=agent_id,
            cache_path=args.cache,
            user=args.user,
            multi_turn=spec["multi_turn"],
        )
        attack = build_attack(
            args.attack,
            target=target,
            scoring=scoring,
            converter_config=converter_config,
            adversarial=adversarial,
            args=args,
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
                    "multi_turn": spec["multi_turn"],
                    "turns": getattr(result, "executed_turns", None),
                    "objective": objective,
                    "outcome": str(outcome),
                    "outcome_reason": result.outcome_reason,
                    "verdict": verdict_from_outcome(outcome),
                    "score": str(score) if score is not None else None,
                    "reply": reply,
                }
            except Exception as e:  # a single objective failing must not abort the batch
                reason = f"{type(e).__name__}: {e}"
                # A red-teaming gotcha: the SCORER's or the ADVERSARY's Azure OpenAI call can be
                # blocked by the content filter when handling adversarial content. Make it actionable.
                if _is_content_filter_block(e):
                    reason = (
                        "Blocked by Azure OpenAI content filter while the scorer/adversary handled "
                        "adversarial content. Use a deployment with content filtering disabled/"
                        "annotate-only for red-teaming (see red-teamer/SKILL.md)."
                    )
                entry = {
                    "agent": agent_id,
                    "agent_name": agents_by_id[agent_id].get("name"),
                    "attack": args.attack,
                    "category": args.objective_category,
                    "converters": args.converters,
                    "multi_turn": spec["multi_turn"],
                    "turns": None,
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
        "multi_turn": spec["multi_turn"],
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
    pa.add_argument("--attack", default="prompt_sending", help="Attack id: " + ", ".join(sorted(ATTACK_SPECS)))
    pa.add_argument("--objective-category", required=True, help="Objective category from objectives.md")
    pa.add_argument("--objectives", default=DEFAULT_OBJECTIVES, help="Path to the objectives library")
    pa.add_argument("--converters", default="none", help="Comma list: none|base64|rot13")
    pa.add_argument("--max-objectives", type=int, default=0, help="Cap objectives per category (0 = all)")
    # Multi-turn knobs (crescendo/red_teaming/tap/pair). Modest defaults bound token/TPM cost.
    pa.add_argument("--max-turns", type=int, default=6, help="Multi-turn: max turns (crescendo/red_teaming)")
    pa.add_argument("--max-backtracks", type=int, default=5, help="Crescendo: max backtracks")
    pa.add_argument("--tree-width", type=int, default=3, help="TAP/PAIR: tree width")
    pa.add_argument("--tree-depth", type=int, default=3, help="TAP/PAIR: tree depth")
    pa.add_argument("--branching-factor", type=int, default=2, help="TAP: branching factor")
    pa.add_argument("--example-count", type=int, default=20, help="many_shot: number of jailbreak examples")
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
