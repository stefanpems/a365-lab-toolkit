"""Demo-pack overlay of the reports monitor (ACA-S2S, autonomous, own identity): role prompt + two tools.

- read reports: fictional anomaly reports of the locale, time-shifted to "the last 24 hours".
- find officers: directory lookup in Microsoft Entra ID with the agent's OWN identity (agent identity token from the
  blueprint through the federated fmi_path flow). Without the Graph User.Read.All permission (granted by the access
  package of D10) it reports "not authorized"; when Conditional Access blocks the agent identity (D9/D17) it reports
  the block. Outcome texts come from the locale.
"""

import logging
import os
from datetime import datetime, timedelta, timezone

from overlay_tools import ORG, OVERLAY, make_tool

logger = logging.getLogger(__name__)
_S = OVERLAY.get("strings", {})
_LOGIN = "https://login.microsoftonline.com"
_GRAPH = "https://graph.microsoft.com/v1.0"

OVERLAY_PROMPT = OVERLAY.get("rolePrompt", "")


async def _read_reports() -> list:
    now = datetime.now(timezone.utc)
    out = []
    for r in OVERLAY.get("reports", []):
        rec = {k: v for k, v in r.items() if k != "hoursAgo"}
        rec[_S.get("receivedAt", "received")] = (now - timedelta(hours=float(r.get("hoursAgo", 0)))).strftime("%d/%m/%Y %H:%M UTC")
        out.append(rec)
    return out


async def _agent_graph_token() -> str:
    import httpx  # in the agent image (ACA samples depend on httpx)

    tenant = os.getenv("CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID", "")
    blueprint = os.getenv("CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID", "")
    secret = os.getenv("CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET", "")
    agent_id = os.getenv("AGENT_IDENTITY_ID", "")
    if not (tenant and blueprint and secret and agent_id):
        raise RuntimeError(_S.get("incompleteConfig", "incomplete agent identity configuration"))
    url = f"{_LOGIN}/{tenant}/oauth2/v2.0/token"
    async with httpx.AsyncClient(timeout=20) as client:
        r1 = await client.post(url, data={"client_id": blueprint, "client_secret": secret, "grant_type": "client_credentials",
                                          "scope": "api://AzureADTokenExchange/.default", "fmi_path": agent_id})
        j1 = r1.json()
        if "access_token" not in j1:
            raise RuntimeError(f"blueprint token: {j1.get('error')}: {str(j1.get('error_description', ''))[:300]}")
        r2 = await client.post(url, data={"client_id": agent_id, "grant_type": "client_credentials",
                                          "scope": "https://graph.microsoft.com/.default",
                                          "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                                          "client_assertion": j1["access_token"]})
        j2 = r2.json()
        if "access_token" not in j2:
            raise RuntimeError(f"agent token: {j2.get('error')}: {str(j2.get('error_description', ''))[:300]}")
        return j2["access_token"]


async def _find_officers(office: str) -> dict:
    import httpx

    try:
        token = await _agent_graph_token()
    except Exception as exc:
        msg = str(exc)
        blocked = "AADSTS53003" in msg or "onditional" in msg
        logger.warning("find officers: token failure: %s", msg)
        # A blocked identity and a missing permission must never read the same on screen: explicit reason code.
        return {"outcome": _S.get("blockedByCa" if blocked else "authError", msg[:80]),
                "reason": "access_blocked" if blocked else "token_error", "detail": msg[:300], "officers": []}
    department = ORG.get("department", "")
    params = {"$filter": f"department eq '{department}'", "$select": "displayName,jobTitle,mail,officeLocation",
              "$count": "true", "$top": "50"}
    async with httpx.AsyncClient(timeout=20) as client:
        r = await client.get(f"{_GRAPH}/users", params=params,
                             headers={"Authorization": f"Bearer {token}", "ConsistencyLevel": "eventual"})
    if r.status_code in (401, 403):
        return {"outcome": _S.get("notAuthorized", "not authorized"), "reason": "permission_missing",
                "detail": f"HTTP {r.status_code}", "officers": []}
    r.raise_for_status()
    wanted = office.strip().lower()
    users = [u for u in r.json().get("value", []) if (u.get("officeLocation") or "").strip().lower() == wanted]
    return {"outcome": _S.get("ok", "ok"), "office": office,
            "officers": [{"name": u.get("displayName"), "role": u.get("jobTitle"), "email": u.get("mail")} for u in users]}


_T = OVERLAY.get("tools", {})
OVERLAY_TOOLS = [
    make_tool(_T["readReports"], _read_reports, {}),
    make_tool(_T["findOfficers"], _find_officers, {"office": str}),
]
