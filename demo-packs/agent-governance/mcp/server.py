"""Demo MCP backends of the agent-governance demo pack (NoAuth, fictional data), one image for every backend.

Each container hosts ONE server at '/mcp' (Agent 365 registration needs a single-segment path), selected with
MCP_SERVER_MODE = records | companies | deadlines | forms. Names, descriptions, parameters and data come from
mcp-config.json (written by Deploy-DemoMcp.ps1 from the chosen locale), so the tool names are in the demo language
and unique across all servers (checked by Test-DemoPack.ps1 before any deployment). GET '/' and '/health' -> 200.
"""
from __future__ import annotations

import itertools
import json
import keyword
import os
import random
from datetime import datetime, timezone
from pathlib import Path
from typing import Annotated, Any, Callable, Dict

from fastmcp import FastMCP
from pydantic import Field

CONFIG: Dict[str, Any] = json.loads(Path(__file__).with_name("mcp-config.json").read_text(encoding="utf-8"))
ORG: Dict[str, Any] = CONFIG.get("org", {})
MODE = os.environ.get("MCP_SERVER_MODE", "records").strip()
SPEC: Dict[str, Any] = CONFIG["servers"][MODE]
server = FastMCP(name=SPEC.get("name") or SPEC.get("base") or MODE, instructions=SPEC.get("description", ""))
_COUNTER = itertools.count(123)
_REGISTRY: Dict[str, dict] = {}


def _tool(key: str, impl: Callable[..., Any], types: Dict[str, type]) -> None:
    """Registers tool `key` with its localized name, description and parameter names (canonical kwargs to impl)."""
    spec = SPEC["tools"][key]
    params = spec.get("params") or {}
    ns: Dict[str, Any] = {"Annotated": Annotated, "Field": Field, "_impl": impl}
    sig, call = [], []
    for pk, p in params.items():
        name = p["name"]
        if not name.isidentifier() or keyword.iskeyword(name):
            raise ValueError(f"invalid parameter name {name!r}")
        ns[f"_t_{name}"], ns[f"_d_{name}"] = types[pk], p.get("description", "")
        sig.append(f"{name}: Annotated[_t_{name}, Field(description=_d_{name})]")
        call.append(f"{pk!r}: {name}")
    fname = spec["name"]
    exec(f"def {fname}({', '.join(sig)}):\n    return _impl(**{{{', '.join(call)}}})\n", ns)  # noqa: S102
    server.tool(name=fname, description=spec.get("description", ""))(ns[fname])


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%d/%m/%Y %H:%M UTC")


if MODE == "records":
    S = SPEC.get("strings", {})

    def _register(sender: str, subject: str) -> dict:
        number = f"{ORG.get('recordIdPrefix', 'REC-')}{next(_COUNTER):06d}"
        rec = {"record_number": f"{number} {ORG.get('fictionalSuffix', '')}".strip(), "date": _now(),
               "sender": sender, "subject": subject, "office": S.get("office", "")}
        _REGISTRY[number] = rec
        return rec

    def _status(number: str) -> dict:
        if random.random() < float(os.environ.get("FAILURE_RATE", "0.5")):
            raise RuntimeError(S.get("failure", "service temporarily unavailable (simulated error)"))
        key = number.strip().split(" ")[0].upper()
        rec = _REGISTRY.get(key)
        return {"record_number": key, "status": S.get("registered") if rec else S.get("notFound"),
                "assigned_to": S.get("assignedTo") if rec else None}

    _tool("register", _register, {"sender": str, "subject": str})
    _tool("status", _status, {"number": str})

elif MODE == "companies":
    S = SPEC.get("strings", {})
    DATA = {"".join(ch for ch in c["vat"] if ch.isalnum()).upper(): c for c in SPEC.get("data", [])}

    def _find(vat: str) -> dict:
        key = "".join(ch for ch in vat if ch.isalnum()).upper()
        c = DATA.get(key)
        if not c:
            return {"vat": key, "outcome": S.get("notFound", "not found")}
        return {"vat": key, "name": c["name"], "legal_form": c["legalForm"], "city": c["city"],
                "registered_email": c["registeredEmail"], "status": S.get("active", "active"), "outcome": S.get("found", "found")}

    _tool("find", _find, {"vat": str})

else:  # deadlines | forms: a single read-only listing tool
    DATA = SPEC.get("data", {})

    def _list() -> dict:
        return DATA

    _tool("list", _list, {})


async def _probe(_request):
    from starlette.responses import JSONResponse

    return JSONResponse({"status": "ok", "server": MODE, "mcp": "/mcp"})


server.custom_route("/", methods=["GET"])(_probe)
server.custom_route("/health", methods=["GET"])(_probe)
app = server.http_app(path="/mcp")

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8000")))
