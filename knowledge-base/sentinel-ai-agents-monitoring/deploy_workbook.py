"""Deploy the (patched) "AI Agents Monitoring" workbook of davidalonsod/Dalonso-Security-Repo to one Log Analytics
workspace - either the Microsoft Sentinel workspace or the workspace behind an Application Insights resource.

Patches applied to the upstream workbook:
  * Workspace parameter -> multi-select with "All" (default = all selectable workspaces).
  * The 21 Advanced Hunting tiles are bound to the author's own workspace (CyberSOC): rebound to --sentinel-workspace.
  * When the target is NOT the Sentinel workspace, tables that exist only in Sentinel (SecurityAlert, IdentityInfo,
    CopilotActivity, CloudAppEvents, ...) are read cross-workspace from --sentinel-workspace (otherwise those tiles
    fail with "Syntax Error"). Omit --sentinel-workspace to leave them as they are.
The workbook id is deterministic (uuid5 of the target workspace id): re-running updates the same workbook.
"""
import argparse, json, os, re, shutil, subprocess, sys, urllib.error, urllib.request, uuid

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("--workbook", required=True, help="Path to AI-Agents-Monitoring-Workbook.workbook")
ap.add_argument("--target-workspace", required=True, help="Resource id of the Log Analytics workspace the workbook reads")
ap.add_argument("--sentinel-workspace", help="Resource id of the Sentinel workspace (Advanced Hunting + cross-workspace tables)")
ap.add_argument("--resource-group", help="Resource group that hosts the workbook (default: the target workspace RG)")
ap.add_argument("--location", help="Azure region of the workbook resource (default: the target workspace region)")
ap.add_argument("--display-name", default="AI Agents Monitoring")
ap.add_argument("--category", choices=["sentinel", "workbook"], help="Default: sentinel if target == sentinel workspace")
ap.add_argument("--tag", action="append", default=[], help="key=value (repeatable)")
ap.add_argument("--what-if", action="store_true", help="Write the request body next to the workbook and do not deploy")
a = ap.parse_args()

AZ = shutil.which("az") or sys.exit("Azure CLI (az) not found")
target = a.target_workspace.strip()
sentinel = (a.sentinel_workspace or "").strip()
is_sentinel = bool(sentinel) and sentinel.lower() == target.lower()
parts = target.strip("/").split("/")
sub, ws_rg = parts[1], parts[3]


def az(*args):
    p = subprocess.run([AZ, *args, "-o", "json"], capture_output=True, text=True, encoding="utf-8", errors="replace")
    if p.returncode:
        sys.exit(p.stderr.strip()[-1500:])
    return json.loads(p.stdout or "null")


XWS = re.compile(r"""(?<![\w."'])(SecurityAlert|SecurityIncident|IdentityInfo|CopilotActivity|OpenAIChatCompletions|"""
                 r"""ASimAgentEventLogs|CloudAppEvents|AgentsInfo|OfficeActivity|SigninLogs)\b(?!\s*\()(?!["'])""")


def patch(o):
    if isinstance(o, dict):
        if o.get("name") == "Workspace" and o.get("type") == 5:
            o["multiSelect"] = True
            o.setdefault("typeSettings", {})["additionalResourceOptions"] = ["value::all"]
            o["defaultValue"] = "value::all"
        if o.get("queryType") == "advancedHunting" and sentinel:
            o["crossComponentResources"] = [sentinel]
        if sentinel and not is_sentinel and isinstance(o.get("query"), str) and o.get("queryType") in (None, 0):
            o["query"] = XWS.sub(lambda m: f'workspace("{sentinel}").{m.group(1)}', o["query"])
        for v in o.values():
            patch(v)
    elif isinstance(o, list):
        for v in o:
            patch(v)


wb = json.load(open(a.workbook, encoding="utf-8"))
patch(wb)
wb["fallbackResourceIds"] = [target]

location = a.location or az("rest", "--method", "get", "--url",
                            f"https://management.azure.com{target}?api-version=2022-10-01", "--query", "location")
rg = a.resource_group or ws_rg
category = a.category or ("sentinel" if is_sentinel else "workbook")
tags = dict(t.split("=", 1) for t in a.tag)
wid = str(uuid.uuid5(uuid.NAMESPACE_URL, "a365-ai-agents-monitoring:" + target.lower()))
body = {"location": location, "kind": "shared", "tags": {**tags, "hidden-title": a.display_name},
        "properties": {"displayName": a.display_name, "serializedData": json.dumps(wb, ensure_ascii=False),
                       "category": category, "sourceId": target.lower(), "version": "Notebook/1.0"}}
url = (f"https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/"
       f"Microsoft.Insights/workbooks/{wid}?api-version=2022-04-01")

if a.what_if:
    out = os.path.splitext(a.workbook)[0] + f".{wid}.body.json"
    json.dump(body, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"WHATIF: PUT {url}\n        body -> {out}")
    sys.exit(0)

token = az("account", "get-access-token", "--resource", "https://management.azure.com/", "--query", "accessToken")
# Direct HTTPS call: az rest drops the emoji / non-ASCII characters of the workbook body on Windows.
req = urllib.request.Request(url, method="PUT", data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
                             headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json; charset=utf-8"})
try:
    with urllib.request.urlopen(req) as resp:
        res = json.loads(resp.read().decode("utf-8"))
except urllib.error.HTTPError as e:
    sys.exit(f"HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:1500]}")
r = {"id": res["id"], "name": res["properties"]["displayName"], "category": res["properties"]["category"]}
tenant = az("account", "show", "--query", "tenantDefaultDomain || tenantId")
print(json.dumps(r, indent=1))
print(f"Open: https://portal.azure.com/#@{tenant}/resource{r['id']}/workbook")
