"""Publish the DW declarative agent as an Agent 365 **autopilot** in Microsoft Teams / M365.

Implements the REST flow (steps 1, 2, 4) from
https://learn.microsoft.com/azure/foundry/agents/how-to/publish-copilot-virtual-network
for a PUBLIC Foundry project (no VNet step 5 needed):

  1. identity : GET the agent's instance_identity.principal_id (+ tenant id).
  2. bot      : create an Azure Bot Service (bot-service.bicep) wired to the agent's
                activity endpoint; connect the Teams channel. Returns its ARM id.
  3. publish  : call the Microsoft 365 publish API (publishAsAutopilot / publishScope).

Sub-commands:
  python publish_autopilot.py identity      # step 1 only (safe, read-only)
  python publish_autopilot.py bot           # step 2 (CREATES an Azure Bot Service resource)
  python publish_autopilot.py publish       # step 4 (submits the M365 publish request)
  python publish_autopilot.py all           # 1 -> 2 -> 3

Prereqs: az login (Owner/Contributor or Azure Bot Service Contributor on the RG; Foundry User
on the project), and the Microsoft.BotService provider registered.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

import requests

import agent_config as cfg

API = "api-version=v1"
FEATURES = {"Foundry-Features": "AgentEndpoints=V1Preview,HostedAgents=V1Preview"}


def _az(args: list[str]) -> str:
    out = subprocess.run(["az", *args], capture_output=True, text=True, shell=True)
    if out.returncode != 0:
        raise RuntimeError(f"az {' '.join(args)} failed:\n{out.stderr.strip()}")
    return out.stdout.strip()


def get_token() -> str:
    return _az(["account", "get-access-token", "--resource", "https://ai.azure.com",
                "--query", "accessToken", "-o", "tsv"])


def get_tenant() -> str:
    return _az(["account", "show", "--query", "tenantId", "-o", "tsv"])


def get_asset(token: str) -> dict:
    """Return the prompt agent's asset identifiers for the digital-worker publish.

    A Foundry prompt agent version DOES carry a ManagedAgentIdentityBlueprint plus an
    agent_guid — exactly what the AzureML digital-worker publish needs.
    """
    url = f"{cfg.PROJECT_ENDPOINT}/agents/{cfg.AGENT_NAME}?{API}"
    r = requests.get(url, headers={"Authorization": f"Bearer {token}", **FEATURES}, timeout=60)
    r.raise_for_status()
    v = r.json()["versions"]["latest"]
    return {
        "agent_guid": v["agent_guid"],
        "blueprint_client_id": v["blueprint"]["client_id"],
        "instance_principal_id": v["instance_identity"]["principal_id"],
    }


def _account_project() -> tuple[str, str]:
    # PROJECT_ENDPOINT = https://<account>.services.ai.azure.com/api/projects/<project>
    host = cfg.PROJECT_ENDPOINT.split("//", 1)[1].split("/", 1)[0]
    account = host.split(".", 1)[0]
    project = cfg.PROJECT_ENDPOINT.rstrip("/").rsplit("/", 1)[-1]
    return account, project


def dw_publish(token: str, asset: dict) -> dict:
    """Publish the prompt agent as a Digital Worker via the AzureML agent-asset API — the
    same mechanism the FH-DW uses. This yields the own-identity policy template + license."""
    account, project = _account_project()
    sub = _az(["account", "show", "--query", "id", "-o", "tsv"])
    loc = os.environ.get("LOCATION") or _az([
        "cognitiveservices", "account", "show", "-n", account, "-g", cfg.RESOURCE_GROUP,
        "--query", "location", "-o", "tsv"])
    ws = f"{account}@{project}@AML"
    bp = asset["blueprint_client_id"]
    url = (f"https://{loc}.api.azureml.ms/agent-asset/v2.0/subscriptions/{sub}"
           f"/resourceGroups/{cfg.RESOURCE_GROUP}/providers/Microsoft.MachineLearningServices"
           f"/workspaces/{ws}/microsoft365/publish")
    body = {
        "agentGuid": asset["agent_guid"],
        "botId": bp,
        "publishAsDigitalWorker": True,
        "appPublishScope": cfg.PUBLISH_SCOPE,
        "subscriptionId": sub,
        "agentName": cfg.AGENT_NAME,
        "appVersion": cfg.PUBLISH_APP_VERSION,
        "shortDescription": cfg.PUBLISH_SHORT_DESC,
        "fullDescription": cfg.PUBLISH_FULL_DESC,
        "developerName": cfg.PUBLISH_DEVELOPER,
        "developerWebsiteUrl": "https://azure.microsoft.com",
        "privacyUrl": "https://privacy.microsoft.com",
        "termsOfUseUrl": "https://www.microsoft.com/legal/terms-of-use",
        # NOTE: this AzureML agent-asset path (publishAsDigitalWorker) does NOT honor
        # optionalPermissionScopes — the field is silently ignored, so MCP tool scopes (e.g. Mail)
        # never reach the blueprint. To declare inheritable MCP scopes for a DW, publish via the
        # agent endpoint ({project}/agents/<name>/microsoft365/publish, publishAsAutopilot=true) with
        # optionalPermissionScopes, as foundry-hosted/dw/scripts/publish-digital-worker.ps1 does.
        "useAgenticUserTemplate": True,
        "agenticUserTemplate": {
            "Id": "digitalWorkerTemplate",
            "File": "agenticUserTemplateManifest.json",
            "SchemaVersion": "0.1.0-preview",
            "AgentIdentityBlueprintId": bp,
            "CommunicationProtocol": "activityProtocol",
        },
    }
    print(f"Digital-worker publish via AzureML ({loc}, scope={cfg.PUBLISH_SCOPE})...")
    print(f"  agentGuid={asset['agent_guid']} blueprint(botId)={bp}")
    r = requests.post(url, headers={"Authorization": f"Bearer {token}",
                                    "Content-Type": "application/json",
                                    "Accept": "application/json"}, json=body, timeout=180)
    if not r.ok:
        raise RuntimeError(f"DW publish failed {r.status_code}: {r.text}")
    return r.json()


def get_identity(token: str) -> dict:
    url = f"{cfg.PROJECT_ENDPOINT}/agents/{cfg.AGENT_NAME}?{API}"
    r = requests.get(url, headers={"Authorization": f"Bearer {token}", **FEATURES}, timeout=60)
    r.raise_for_status()
    data = r.json()
    ident = data.get("instance_identity") or {}
    if not ident.get("principal_id"):
        raise RuntimeError(
            "The agent has no instance_identity.principal_id yet. Make sure the agent version "
            f"is deployed (run deploy_agent.py). Raw agent payload:\n{json.dumps(data, indent=2)[:1500]}"
        )
    return ident


def create_bot(principal_id: str, tenant: str) -> str:
    print("Registering Microsoft.BotService provider (idempotent)...")
    _az(["provider", "register", "--namespace", "Microsoft.BotService"])
    print(f"Creating Azure Bot Service '{cfg.BOT_NAME}' in RG '{cfg.RESOURCE_GROUP}'...")
    _az([
        "deployment", "group", "create",
        "--resource-group", cfg.RESOURCE_GROUP,
        "--template-file", "bot-service.bicep",
        "--parameters",
        f"botName={cfg.BOT_NAME}",
        f"displayName={cfg.PUBLISH_DISPLAY_NAME}",
        f"msaAppId={principal_id}",
        f"tenantId={tenant}",
        f"endpoint={cfg.activity_endpoint()}",
        "-o", "none",
    ])
    arm_id = _az(["bot", "show", "--name", cfg.BOT_NAME,
                  "--resource-group", cfg.RESOURCE_GROUP, "--query", "id", "-o", "tsv"])
    print(f"Bot Service ARM id: {arm_id}")
    return arm_id


def enable_protocol(token: str) -> None:
    """Step 3 (optional): explicitly add the `activity` protocol + BotService auth scheme.

    The publish API normally does this automatically; doing it explicitly can surface a
    clearer error and, if the publish upstream keeps failing, pre-enables message delivery.
    Keeps `responses` + `Entra` so the Foundry portal/SDK keep working.
    """
    scheme = "BotServiceTenant" if cfg.PUBLISH_SCOPE.lower() == "tenant" else "BotServiceRbac"
    url = f"{cfg.PROJECT_ENDPOINT}/agents/{cfg.AGENT_NAME}?{API}"
    body = {
        "agent_endpoint": {
            "protocol_configuration": {"responses": {}, "activity": {}},
            "authorization_schemes": [{"type": "Entra"}, {"type": scheme}],
        }
    }
    print(f"Enabling activity protocol + {scheme} on the agent...")
    r = requests.patch(url, headers={"Authorization": f"Bearer {token}",
                                     "Content-Type": "application/merge-patch+json", **FEATURES},
                       json=body, timeout=60)
    if not r.ok:
        raise RuntimeError(f"Enable-protocol failed {r.status_code}: {r.text}")
    print("Activity protocol + auth scheme enabled.")


def publish(token: str, bot_arm_id: str) -> dict:
    url = f"{cfg.PROJECT_ENDPOINT}/agents/{cfg.AGENT_NAME}/microsoft365/publish?{API}"
    body = {
        "agentDisplayName": cfg.PUBLISH_DISPLAY_NAME,
        "botServiceArmId": bot_arm_id,
        "publishScope": cfg.PUBLISH_SCOPE,
        "publishAsAutopilot": cfg.PUBLISH_AS_AUTOPILOT,
        "appVersion": cfg.PUBLISH_APP_VERSION,
        "shortDescription": cfg.PUBLISH_SHORT_DESC,
        "fullDescription": cfg.PUBLISH_FULL_DESC,
        "developerName": cfg.PUBLISH_DEVELOPER,
    }
    print(f"Publishing to M365 (scope={cfg.PUBLISH_SCOPE}, autopilot={cfg.PUBLISH_AS_AUTOPILOT})...")
    r = requests.post(url, headers={"Authorization": f"Bearer {token}",
                                    "Content-Type": "application/json", **FEATURES},
                      json=body, timeout=120)
    if not r.ok:
        raise RuntimeError(f"Publish failed {r.status_code}: {r.text}")
    return r.json()


def main() -> None:
    parser = argparse.ArgumentParser(description="Publish the DW declarative agent as an autopilot.")
    parser.add_argument("command", choices=["identity", "bot", "protocol", "publish", "dwpublish", "all"])
    args = parser.parse_args()

    token = get_token()

    if args.command == "dwpublish":
        # Digital-worker publish path (AzureML) — gives the own-identity + license template.
        asset = get_asset(token)
        print(f"agent_guid={asset['agent_guid']} blueprint_client_id={asset['blueprint_client_id']}")
        tenant = get_tenant()
        # The Bot Service msaAppId MUST be the blueprint appId for the digital-worker relay.
        create_bot(asset["blueprint_client_id"], tenant)
        result = dw_publish(token, asset)
        print("DW publish response:")
        print(json.dumps(result, indent=2))
        print("\nApprove in the Microsoft 365 admin center -> Agents -> Requests.")
        return

    if args.command == "protocol":
        enable_protocol(token)
        return

    if args.command in ("identity", "all", "bot"):
        ident = get_identity(token)
        print(f"instance_identity.principal_id = {ident['principal_id']}")
        print(f"instance_identity.client_id    = {ident.get('client_id')}")
        if args.command == "identity":
            return

    tenant = get_tenant()

    if args.command in ("bot", "all"):
        arm_id = create_bot(ident["principal_id"], tenant)
        if args.command == "bot":
            print("\nNext: run `python publish_autopilot.py publish` (bot ARM id is re-read by az).")
            return
    else:
        arm_id = _az(["bot", "show", "--name", cfg.BOT_NAME,
                      "--resource-group", cfg.RESOURCE_GROUP, "--query", "id", "-o", "tsv"])

    if args.command in ("publish", "all"):
        result = publish(token, arm_id)
        print("Publish response:")
        print(json.dumps(result, indent=2))
        print("\nIf publishScope=Tenant: approve the request in the Microsoft 365 admin center")
        print("  https://admin.cloud.microsoft/#/agents/all/requested")
        print("Then find the agent in Teams (Apps) and start a chat / create an instance.")


if __name__ == "__main__":
    try:
        main()
    except Exception as ex:  # noqa: BLE001
        print(f"ERROR: {ex}", file=sys.stderr)
        sys.exit(1)
