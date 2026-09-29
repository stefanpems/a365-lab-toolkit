"""Shared helper of the demo-pack overlays: localized strings + in-process tools whose NAMES come from the locale.

The Demo Builder copies this file, the overlay's ``agent_overlay.py`` and a generated ``overlay_strings.json``
(org + overlay texts of the chosen language) into the scaffolded agent folder. Tool and parameter names are
language-specific, so each tool is generated as a real function (name, docstring, annotated parameters) that
forwards to a language-neutral implementation.
"""

import json
import keyword
from pathlib import Path
from typing import Annotated, Any, Callable, Dict, Optional

STRINGS: Dict[str, Any] = json.loads(Path(__file__).with_name("overlay_strings.json").read_text(encoding="utf-8"))
ORG: Dict[str, Any] = STRINGS.get("org", {})
OVERLAY: Dict[str, Any] = STRINGS.get("overlay", {})


def make_tool(spec: Dict[str, Any], impl: Callable[..., Any], types: Dict[str, type],
              defaults: Optional[Dict[str, Any]] = None) -> Callable[..., Any]:
    """Builds an async function tool named ``spec["name"]`` whose parameters are ``spec["params"][key]["name"]``.

    ``impl`` is an async callable receiving the canonical (language-neutral) keyword arguments.
    """
    from pydantic import Field  # lazy: overlays without tools (e.g. the Foundry one) must not need pydantic

    params = spec.get("params") or {}
    defaults = defaults or {}
    ns: Dict[str, Any] = {"Annotated": Annotated, "Field": Field, "_impl": impl}
    sig, call = [], []
    for key in sorted(params, key=lambda k: k in defaults):  # parameters with a default go last
        name = params[key]["name"]
        if not name.isidentifier() or keyword.iskeyword(name):
            raise ValueError(f"invalid parameter name {name!r}")
        ns[f"_t_{name}"], ns[f"_d_{name}"] = types[key], params[key].get("description", "")
        default = ""
        if key in defaults:
            ns[f"_v_{name}"] = defaults[key]
            default = f" = _v_{name}"
        sig.append(f"{name}: Annotated[_t_{name}, Field(description=_d_{name})]{default}")
        call.append(f"{key!r}: {name}")
    fname = spec["name"]
    if not fname.isidentifier() or keyword.iskeyword(fname):
        raise ValueError(f"invalid tool name {fname!r}")
    exec(f"async def {fname}({', '.join(sig)}):\n    return await _impl(**{{{', '.join(call)}}})\n", ns)  # noqa: S102
    fn = ns[fname]
    fn.__doc__ = spec.get("description", "")
    return fn
