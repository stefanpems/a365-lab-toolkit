"""Discover, provision, exercise and safely remove managed AWS AI agents."""

from __future__ import annotations

import argparse
import codecs
import configparser
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import Callable
from urllib.parse import parse_qs, unquote, urlencode, urlsplit
import uuid
import zipfile

from aws_ai_environment import (
    isolated_environment, load_credentials, private_directory,
    process_environment, read_json, write_json,
)


MANAGER = "aws-ai-manager"
OWNER_TAG = "managed-by"
ASSETS = Path(__file__).resolve().parents[2] / "aws-ai-agent-create" / "assets"
DEFAULT_PROMPT = "Who are you and what can you do?"
CLASSIC_NOTICE = (
    "Bedrock Agents Classic is closed to new customers since July 30, 2026. "
    "Use AgentCore for a new AWS account."
)
SERVICES = ("agentcore", "bedrock")


def digest(value: object) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=True).encode()).hexdigest()


def aws_error_code(error: Exception) -> str:
    response = getattr(error, "response", {})
    return response.get("Error", {}).get("Code", "")


def is_missing(error: Exception) -> bool:
    return aws_error_code(error) in {"ResourceNotFoundException", "NoSuchEntity", "NoSuchBucket", "404"}


def paginate(client, operation: str, key: str, **parameters) -> list[dict]:
    records: list[dict] = []
    seen: set[str] = set()
    while True:
        page = getattr(client, operation)(**parameters)
        records.extend(page.get(key, []))
        token = page.get("nextToken")
        if not token:
            return records
        if token in seen:
            raise ValueError(f"{operation} returned a repeated pagination token.")
        seen.add(token)
        parameters = {**parameters, "nextToken": token}


def reference(value: str, service: str | None = None) -> dict:
    parsed = {"value": value, "service": service, "region": None, "account_id": None, "qualifier": None}
    if value.startswith("https://"):
        url = urlsplit(value)
        host = url.hostname or ""
        if url.username or url.password or url.port not in {None, 443} or not (
            host == "console.aws.amazon.com" or host.endswith(".console.aws.amazon.com")
        ):
            raise ValueError("Only official commercial AWS console URLs are supported.")
        inferred = "agentcore" if url.path.startswith("/bedrock-agentcore/") else (
            "bedrock" if url.path.startswith("/bedrock/") else None
        )
        if inferred is None:
            raise ValueError("Copy the complete AgentCore Runtime or Bedrock Agents console URL.")
        regions = parse_qs(url.query).get("region", [])
        if len(regions) > 1:
            raise ValueError("The console URL contains ambiguous region parameters.")
        host_region = host.split(".")[0] if host.endswith(".console.aws.amazon.com") else None
        if host_region and not re.fullmatch(r"[a-z]{2}(?:-[a-z]+)+-\d", host_region):
            host_region = None
        if regions and host_region and regions[0] != host_region:
            raise ValueError("The console URL contains conflicting regions.")
        parsed["region"] = regions[0] if regions else host_region
        route = unquote(unquote(url.fragment))
        prefix = r"(?:^|/)(?:runtime|runtimes|agent-runtime)/" if inferred == "agentcore" else r"(?:^|/)agents/"
        match = re.search(
            prefix + r"(arn:aws:(?:bedrock-agentcore|bedrock):[^:]+:\d{12}:(?:runtime|agent)/[^/?#]+|[^/?#]+)",
            route,
        )
        if match is None:
            raise ValueError("The URL must identify one agent, not the agents list.")
        value = match.group(1)
        qualifier = re.search(r"/(?:endpoints|runtime-endpoints|aliases|alias)/([^/?#]+)", route)
        if qualifier:
            parsed["qualifier"] = qualifier.group(1)
        if service and service != inferred:
            raise ValueError("The requested service conflicts with the console URL.")
        parsed["service"] = inferred
    if value.startswith("arn:"):
        match = re.fullmatch(
            r"arn:aws:(bedrock-agentcore|bedrock):([^:]+):(\d{12}):(runtime|agent)/([^/]+)", value
        )
        if match is None or (
            (match[1], match[4]) not in {("bedrock-agentcore", "runtime"), ("bedrock", "agent")}
        ):
            raise ValueError("Only an AgentCore Runtime ARN or Bedrock agent ARN is accepted.")
        inferred = "agentcore" if match[1] == "bedrock-agentcore" else "bedrock"
        if parsed["service"] and parsed["service"] != inferred:
            raise ValueError("The requested service conflicts with the resource ARN.")
        if parsed["region"] and parsed["region"] != match[2]:
            raise ValueError("The console URL and resource ARN contain different regions.")
        parsed.update(service=inferred, region=match[2], account_id=match[3])
        value = match[5]
    if parsed["service"] is None:
        if re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*-[A-Za-z0-9]{10}", value):
            parsed["service"] = "agentcore"
        elif re.fullmatch(r"[A-Za-z0-9]{10}", value):
            parsed["service"] = "bedrock"
        else:
            raise ValueError("Specify --service when selecting an agent by name.")
    if not value or any(character in value for character in "/\\?#"):
        raise ValueError("Invalid agent identifier or name.")
    parsed["value"] = value
    return parsed


def load_spec(path: str, service: str | None) -> dict:
    spec = read_json(Path(path))
    allowed = {
        "service", "name", "model_id", "instructions", "execution_role_arn",
        "artifact_bucket", "max_tokens", "allow_cross_region", "existing_classic_customer",
    }
    if set(spec) - allowed:
        raise ValueError(f"Unknown specification fields: {', '.join(sorted(set(spec) - allowed))}.")
    if service and spec.get("service", service) != service:
        raise ValueError("--service conflicts with the specification.")
    spec.setdefault("service", service)
    if spec["service"] not in SERVICES:
        raise ValueError("The specification must select agentcore or bedrock.")
    name = spec.get("name")
    pattern = r"[A-Za-z][A-Za-z0-9_]{0,47}" if spec["service"] == "agentcore" else r"(?:[A-Za-z0-9][_-]?){1,100}"
    if not isinstance(name, str) or re.fullmatch(pattern, name) is None:
        raise ValueError("Invalid service-specific agent name; AgentCore allows letters, digits and underscores.")
    for field in ("model_id", "instructions"):
        if not isinstance(spec.get(field), str) or not spec[field].strip() or "REPLACE_WITH_" in spec[field]:
            raise ValueError(f"Set a nonempty {field} in the specification.")
    if not 40 <= len(spec["instructions"]) <= 4000:
        raise ValueError("Instructions must contain 40-4000 characters.")
    spec.setdefault("max_tokens", 4096)
    if type(spec["max_tokens"]) is not int or not 1 <= spec["max_tokens"] <= 32768:
        raise ValueError("max_tokens must be an integer between 1 and 32768.")
    for field in ("allow_cross_region", "existing_classic_customer"):
        spec.setdefault(field, False)
        if type(spec[field]) is not bool:
            raise ValueError(f"{field} must be a JSON boolean.")
    if spec["service"] == "bedrock" and not spec["existing_classic_customer"]:
        raise ValueError(CLASSIC_NOTICE + " Explicit existing_classic_customer=true is required.")
    for field in ("execution_role_arn", "artifact_bucket"):
        if field in spec and (not isinstance(spec[field], str) or not spec[field].strip()):
            raise ValueError(f"{field} must be a nonempty string when supplied.")
    return spec


class AwsContext:
    def __init__(self, args: argparse.Namespace, auth_dir: Path):
        import boto3
        from botocore.config import Config

        self.account_id = args.account_id
        self.region = args.region
        credentials = load_credentials(
            auth_dir, self.region, args.credentials_file, args.credentials_profile
        )
        self.session = boto3.Session(region_name=self.region, **credentials)
        self.config = Config(
            region_name=self.region, connect_timeout=20, read_timeout=args.timeout,
            retries={"total_max_attempts": 1}, ignore_configured_endpoint_urls=True,
        )
        self.clients: dict = {}
        self.identity = self.client("sts").get_caller_identity()
        if self.identity["Account"] != self.account_id:
            raise ValueError("The signed-in AWS account does not match --account-id.")
        if not self.identity["Arn"].startswith("arn:aws:"):
            raise ValueError("This manager currently supports the commercial AWS partition only.")

    def client(self, name: str):
        if name not in self.clients:
            self.clients[name] = self.session.client(name, config=self.config)
        return self.clients[name]

    def require_nonroot(self) -> None:
        if self.identity["Arn"].endswith(":root"):
            raise ValueError("Do not use the root identity. Complete the non-root onboarding first.")


def model_resources(context: AwsContext, model_id: str, allow_cross_region: bool) -> dict:
    bedrock = context.client("bedrock")
    profile = ":inference-profile/" in model_id or ":application-inference-profile/" in model_id or (
        model_id.startswith(("eu.", "us.", "apac.", "global."))
    )
    if profile:
        details = bedrock.get_inference_profile(inferenceProfileIdentifier=model_id)
        arn = details["inferenceProfileArn"]
        parts = arn.split(":")
        if parts[3] != context.region or parts[4] != context.account_id:
            raise ValueError("The inference profile belongs to a different account or region.")
        models = [item["modelArn"] for item in details["models"]]
        regions = sorted({item.split(":")[3] for item in models})
        if any(region != context.region for region in regions) and not allow_cross_region:
            raise ValueError(
                "This inference profile can route data across regions. Review destination regions "
                "and explicitly set allow_cross_region=true; no region will be changed silently."
            )
        if details.get("status") != "ACTIVE":
            raise ValueError("The selected inference profile is not active.")
        return {
            "resources": sorted({arn, *models}), "destination_regions": regions, "model_id": model_id,
            "availability_notice": "An active profile does not prove provider entitlement or Converse compatibility; review the backing model.",
        }
    details = bedrock.get_foundation_model(modelIdentifier=model_id)["modelDetails"]
    arn = details["modelArn"]
    if arn.split(":")[3] != context.region:
        raise ValueError("The model ARN belongs to a different region.")
    if "TEXT" not in details.get("inputModalities", []) or "TEXT" not in details.get("outputModalities", []):
        raise ValueError("Select a text-generation model compatible with Bedrock Converse, not an embedding/image model.")
    if "ON_DEMAND" not in details.get("inferenceTypesSupported", []):
        raise ValueError("Select an on-demand model or an explicit inference profile.")
    availability = bedrock.get_foundation_model_availability(modelId=details["modelId"])
    if any(availability.get(key) != expected for key, expected in {
        "authorizationStatus": "AUTHORIZED", "entitlementAvailability": "AVAILABLE",
        "regionAvailability": "AVAILABLE",
    }.items()) or availability.get("agreementAvailability", {}).get("status") != "AVAILABLE":
        raise ValueError(f"The model is not ready for this account/region: {json.dumps(availability, default=str)}")
    return {"resources": [arn], "destination_regions": [context.region], "model_id": details["modelId"]}


def list_agents(context: AwsContext, service: str) -> list[dict]:
    if service == "agentcore":
        summaries = paginate(context.client("bedrock-agentcore-control"), "list_agent_runtimes", "agentRuntimes")
        return [{
            "service": service, "id": item["agentRuntimeId"], "name": item["agentRuntimeName"],
            "arn": item["agentRuntimeArn"],
        } for item in summaries]
    summaries = paginate(context.client("bedrock-agent"), "list_agents", "agentSummaries")
    return [{
        "service": service, "id": item["agentId"], "name": item["agentName"],
        "arn": f"arn:aws:bedrock:{context.region}:{context.account_id}:agent/{item['agentId']}",
    } for item in summaries]


def get_agent(context: AwsContext, target: dict) -> dict:
    if target["service"] == "agentcore":
        value = context.client("bedrock-agentcore-control").get_agent_runtime(agentRuntimeId=target["id"])
        if value["agentRuntimeArn"] != target["arn"]:
            raise ValueError("The returned runtime ARN does not match the selected target.")
        return value
    value = context.client("bedrock-agent").get_agent(agentId=target["id"])["agent"]
    if value["agentArn"] != target["arn"]:
        raise ValueError("The returned Bedrock agent ARN does not match the selected target.")
    return value


def resolve(context: AwsContext, selected: dict) -> dict:
    for field, expected in (("region", context.region), ("account_id", context.account_id)):
        if selected[field] and selected[field] != expected:
            raise ValueError(f"The selected agent conflicts with the expected {field}.")
    matches = [
        item for item in list_agents(context, selected["service"])
        if selected["value"] in {item["id"], item["name"]}
    ]
    if len(matches) != 1:
        raise ValueError(f"Expected one exact agent match; found {len(matches)}. Use the complete ARN or console URL.")
    target = matches[0]
    get_agent(context, target)
    return target


def tags_for(context: AwsContext, target: dict) -> dict:
    client = context.client("bedrock-agentcore-control" if target["service"] == "agentcore" else "bedrock-agent")
    return client.list_tags_for_resource(resourceArn=target["arn"]).get("tags", {})


def require_owned(context: AwsContext, target: dict) -> dict:
    tags = tags_for(context, target)
    if tags.get(OWNER_TAG) != MANAGER or tags.get("aws-ai-manager-account") != context.account_id:
        raise ValueError("Refusing to delete an agent or child resource not owned by AWS AI Manager.")
    return tags


class Run:
    def __init__(self, args: argparse.Namespace, context: AwsContext, request: dict, preview: Callable[[], dict]):
        self.path = private_directory(args.run_dir)
        self.plan_path = self.path / "plan.json"
        self.journal_path = self.path / "journal.json"
        scope = {"action": args.action, "account_id": context.account_id, "region": context.region, "request": request}
        if args.apply:
            if not self.plan_path.is_file():
                raise ValueError("Run a preview first and reuse its exact --run-dir for apply.")
            self.plan = read_json(self.plan_path)
            if self.plan.get("scope") != scope:
                raise ValueError("The requested operation differs from the saved preview.")
            if args.confirm != self.plan["details"]["confirmation"]:
                raise ValueError("The exact confirmation text from the preview is required.")
        else:
            if self.plan_path.exists():
                self.plan = read_json(self.plan_path)
                if self.plan.get("scope") != scope:
                    raise ValueError("Use a new private run directory for a different operation.")
            else:
                self.plan = {"scope": scope, "details": preview(), "token": str(uuid.uuid4())}
                write_json(self.plan_path, self.plan)
        self.details = self.plan["details"]
        self.journal = read_json(self.journal_path) if self.journal_path.exists() else {}

    def preview_result(self) -> dict:
        return {
            "ok": True, "applied": False, "run_dir": str(self.path),
            "plan_sha256": digest(self.plan), **self.details,
        }

    def call(self, step: str, operation: Callable[[], dict]) -> dict:
        existing = self.journal.get(step)
        if existing:
            if existing["state"] == "complete":
                return existing["result"]
            raise ValueError(
                f"Step {step} has an uncertain outcome. Inspect the exact AWS resource and journal; "
                "this manager will not automatically repeat the mutation."
            )
        self.journal[step] = {"state": "pending", "started_at": datetime.now(timezone.utc).isoformat()}
        write_json(self.journal_path, self.journal)
        result = operation()
        self.journal[step] = {"state": "complete", "result": result}
        write_json(self.journal_path, self.journal)
        return result


def wait_for(
    fetch: Callable[[], dict], status_key: str, ready: set[str], timeout: int, *, deleted: bool = False
) -> dict:
    from botocore.exceptions import ClientError

    deadline = time.monotonic() + timeout
    while True:
        try:
            value = fetch()
        except ClientError as error:
            if deleted and is_missing(error):
                return {"deleted": True}
            raise
        status = value.get(status_key)
        if deleted:
            if status and ("FAILED" in status):
                raise ValueError(f"Deletion failed: {json.dumps(value, default=str)}")
        elif status in ready:
            return value
        elif status and ("FAILED" in status):
            raise ValueError(f"The AWS operation failed: {json.dumps(value, default=str)}")
        if time.monotonic() >= deadline:
            raise TimeoutError("The AWS operation is still pending. Reuse this run directory to check it, not to recreate it.")
        time.sleep(3)


def setup_names(context: AwsContext, spec: dict) -> dict:
    suffix = digest([context.account_id, context.region, spec["service"], spec["name"]])[:12]
    return {
        "role_name": f"a365-aws-ai-{spec['service']}-{suffix}",
        "bucket": f"a365-aws-ai-{context.account_id}-{context.region}-{suffix}",
        "tags": {OWNER_TAG: MANAGER, "aws-ai-manager-account": context.account_id, "aws-ai-manager-key": suffix},
    }


def setup_policy(context: AwsContext, spec: dict, names: dict, models: dict) -> tuple[dict, dict]:
    service = "bedrock-agentcore.amazonaws.com" if spec["service"] == "agentcore" else "bedrock.amazonaws.com"
    source = (
        f"arn:aws:bedrock-agentcore:{context.region}:{context.account_id}:runtime/{spec['name']}-*"
        if spec["service"] == "agentcore"
        else f"arn:aws:bedrock:{context.region}:{context.account_id}:agent/*"
    )
    trust = {"Version": "2012-10-17", "Statement": [{
        "Effect": "Allow", "Principal": {"Service": service}, "Action": "sts:AssumeRole",
        "Condition": {"StringEquals": {"aws:SourceAccount": context.account_id}, "ArnLike": {"aws:SourceArn": source}},
    }]}
    statements = [{
        "Sid": "InvokeSelectedModel", "Effect": "Allow",
        "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
        "Resource": models["resources"],
    }]
    if spec["service"] == "agentcore":
        log_group = f"arn:aws:logs:{context.region}:{context.account_id}:log-group:/aws/bedrock-agentcore/runtimes/{spec['name']}-*"
        statements.extend([{
            "Sid": "ReadDeployment", "Effect": "Allow",
            "Action": ["s3:GetObject", "s3:GetObjectVersion"],
            "Resource": [f"arn:aws:s3:::{names['bucket']}/aws-ai-manager/*"],
        }, {
            "Sid": "RuntimeLogs", "Effect": "Allow",
            "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:DescribeLogStreams", "logs:PutLogEvents"],
            "Resource": [log_group, f"{log_group}:log-stream:*"],
        }, {
            "Sid": "DescribeLogGroups", "Effect": "Allow", "Action": ["logs:DescribeLogGroups"],
            "Resource": [f"arn:aws:logs:{context.region}:{context.account_id}:log-group:*"],
        }])
    return trust, {"Version": "2012-10-17", "Statement": statements}


def setup(context: AwsContext, args: argparse.Namespace, spec: dict) -> dict:
    from botocore.exceptions import ClientError

    if spec.get("execution_role_arn") or spec.get("artifact_bucket"):
        raise ValueError("Setup creates new prerequisites. Omit existing role/bucket fields or proceed directly to create.")
    models = model_resources(context, spec["model_id"], spec["allow_cross_region"])
    names = setup_names(context, spec)
    trust, policy = setup_policy(context, spec, names, models)
    iam = context.client("iam")
    s3 = context.client("s3") if spec["service"] == "agentcore" else None

    def preview() -> dict:
        try:
            iam.get_role(RoleName=names["role_name"])
        except ClientError as error:
            if not is_missing(error):
                raise
        else:
            raise ValueError("The setup role already exists. Use its saved create-spec or choose a different agent name.")
        if s3:
            try:
                s3.head_bucket(Bucket=names["bucket"], ExpectedBucketOwner=context.account_id)
            except ClientError as error:
                if not is_missing(error):
                    raise
            else:
                raise ValueError("The setup bucket already exists; it will not be adopted or modified.")
        return {
            "confirmation": f"{context.account_id}/{context.region}/{spec['name']}",
            "service": spec["service"], "role_name": names["role_name"],
            "artifact_bucket": names["bucket"] if s3 else None,
            "trust_policy": trust, "execution_policy": policy,
            "destination_regions": models["destination_regions"],
            "cost_notice": "IAM is not billed. S3 storage, AgentCore runtime, model inference and logs can incur charges.",
            "retained_on_agent_deletion": ["execution role", "artifact bucket and objects", "CloudWatch logs"],
        }

    run = Run(args, context, {"spec": spec, "models": models}, preview)
    if not args.apply:
        return run.preview_result()
    tag_list = [{"Key": key, "Value": value} for key, value in names["tags"].items()]
    created = run.call("create-role", lambda: iam.create_role(
        RoleName=names["role_name"], AssumeRolePolicyDocument=json.dumps(trust),
        Description="Execution role for one AWS AI Manager agent.", Tags=tag_list,
    ))
    current_role = iam.get_role(RoleName=names["role_name"])["Role"]
    if {item["Key"]: item["Value"] for item in current_role.get("Tags", [])} != names["tags"]:
        raise ValueError("The setup role ownership tags changed; no policy will be written.")
    run.call("role-policy", lambda: iam.put_role_policy(
        RoleName=names["role_name"], PolicyName=MANAGER, PolicyDocument=json.dumps(policy),
    ))
    if s3:
        parameters = {"Bucket": names["bucket"]}
        if context.region != "us-east-1":
            parameters["CreateBucketConfiguration"] = {"LocationConstraint": context.region}
        run.call("create-bucket", lambda: s3.create_bucket(**parameters))
        owner = {"Bucket": names["bucket"], "ExpectedBucketOwner": context.account_id}
        run.call("block-public-access", lambda: s3.put_public_access_block(
            **owner, PublicAccessBlockConfiguration={
                "BlockPublicAcls": True, "IgnorePublicAcls": True,
                "BlockPublicPolicy": True, "RestrictPublicBuckets": True,
            },
        ))
        run.call("bucket-ownership", lambda: s3.put_bucket_ownership_controls(
            **owner, OwnershipControls={"Rules": [{"ObjectOwnership": "BucketOwnerEnforced"}]},
        ))
        run.call("bucket-encryption", lambda: s3.put_bucket_encryption(
            **owner, ServerSideEncryptionConfiguration={
                "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}],
            },
        ))
        run.call("bucket-versioning", lambda: s3.put_bucket_versioning(
            **owner, VersioningConfiguration={"Status": "Enabled"},
        ))
        run.call("bucket-tags", lambda: s3.put_bucket_tagging(**owner, Tagging={"TagSet": tag_list}))
    output_spec = {**spec, "execution_role_arn": created["Role"]["Arn"]}
    if s3:
        output_spec["artifact_bucket"] = names["bucket"]
    write_json(run.path / "create-spec.json", output_spec)
    return {
        "ok": True, "applied": True, "create_spec": str(run.path / "create-spec.json"),
        "execution_role_arn": output_spec["execution_role_arn"],
        "artifact_bucket": output_spec.get("artifact_bucket"),
        "next_step": "Preview create using the generated create-spec; creation requires separate approval.",
    }


def validate_prerequisites(context: AwsContext, spec: dict) -> None:
    role = spec.get("execution_role_arn", "")
    match = re.fullmatch(rf"arn:aws:iam::{context.account_id}:role/(.+)", role)
    if match is None:
        raise ValueError("Set execution_role_arn to a role in the expected account, or run setup first.")
    details = context.client("iam").get_role(RoleName=match[1].split("/")[-1])["Role"]
    if details["Arn"] != role:
        raise ValueError("The execution role ARN does not match.")
    principal = "bedrock-agentcore.amazonaws.com" if spec["service"] == "agentcore" else "bedrock.amazonaws.com"
    statements = details["AssumeRolePolicyDocument"]["Statement"]
    if isinstance(statements, dict):
        statements = [statements]
    if not any(
        statement.get("Effect") == "Allow"
        and isinstance(statement.get("Principal"), dict)
        and "sts:AssumeRole" in (
            [statement.get("Action")] if isinstance(statement.get("Action"), str) else statement.get("Action", [])
        )
        and principal in (
            [statement.get("Principal", {}).get("Service")]
            if isinstance(statement.get("Principal", {}).get("Service"), str)
            else statement.get("Principal", {}).get("Service", [])
        )
        for statement in statements
    ):
        raise ValueError("The execution role does not trust the selected AWS agent service.")
    if spec["service"] == "agentcore":
        bucket = spec.get("artifact_bucket")
        if not isinstance(bucket, str) or not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", bucket):
            raise ValueError("Set artifact_bucket to an existing private bucket, or run setup first.")
        s3 = context.client("s3")
        owner = {"Bucket": bucket, "ExpectedBucketOwner": context.account_id}
        s3.head_bucket(**owner)
        location = s3.get_bucket_location(**owner).get("LocationConstraint") or "us-east-1"
        if location == "EU":
            location = "eu-west-1"
        if location != context.region:
            raise ValueError("The artifact bucket must be in the selected runtime region.")
        block = s3.get_public_access_block(**owner)["PublicAccessBlockConfiguration"]
        if not all(block.get(key) is True for key in (
            "BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets"
        )):
            raise ValueError("The artifact bucket must block all public access.")


def source_hashes() -> dict:
    return {
        name: hashlib.sha256((ASSETS / name).read_bytes()).hexdigest()
        for name in ("agent.py", "requirements.txt")
    }


def package_agent(run: Run, spec: dict) -> Path:
    package = run.path / "package.zip"
    stamp = run.path / "package.sha256"
    if package.exists():
        if not stamp.is_file() or stamp.read_text(encoding="ascii").strip() != hashlib.sha256(package.read_bytes()).hexdigest():
            raise ValueError("The saved deployment package was modified.")
        return package
    dependencies = run.path / "dependencies"
    if dependencies.exists():
        raise ValueError("An incomplete dependency build exists. Inspect it and use a new preview run.")
    subprocess.run(
        [sys.executable, "-m", "pip", "install", "--disable-pip-version-check", "--no-compile",
         "--only-binary=:all:", "--platform", "manylinux2014_aarch64", "--implementation", "cp",
         "--python-version", "3.13", "--abi", "cp313", "--target", str(dependencies),
         "--requirement", str(ASSETS / "requirements.txt")],
        check=True, stdout=sys.stderr, stderr=sys.stderr, timeout=600,
    )
    files = {path.relative_to(dependencies).as_posix(): path.read_bytes()
             for path in sorted(dependencies.rglob("*")) if path.is_file() and "__pycache__" not in path.parts}
    if "agent.py" in files or "agent_config.json" in files:
        raise ValueError("A dependency conflicts with the allowlisted agent files.")
    files["agent.py"] = (ASSETS / "agent.py").read_bytes()
    files["agent_config.json"] = json.dumps({
        key: spec[key] for key in ("model_id", "instructions", "max_tokens")
    }, ensure_ascii=True, sort_keys=True).encode()
    if sum(map(len, files.values())) > 750 * 1024 * 1024:
        raise ValueError("The deployment package exceeds the 750 MiB uncompressed limit.")
    with zipfile.ZipFile(package, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, contents in sorted(files.items()):
            entry = zipfile.ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, contents)
    if package.stat().st_size > 250 * 1024 * 1024:
        raise ValueError("The deployment ZIP exceeds the 250 MiB compressed limit.")
    stamp.write_text(hashlib.sha256(package.read_bytes()).hexdigest() + "\n", encoding="ascii")
    return package


def create(context: AwsContext, args: argparse.Namespace, spec: dict) -> dict:
    models = model_resources(context, spec["model_id"], spec["allow_cross_region"])
    validate_prerequisites(context, spec)

    def preview() -> dict:
        if any(item["name"] == spec["name"] for item in list_agents(context, spec["service"])):
            raise ValueError("An agent with that exact name already exists.")
        return {
            "confirmation": spec["name"], "service": spec["service"],
            "name": spec["name"], "model": models,
            "execution_role_arn": spec["execution_role_arn"],
            "artifact_bucket": spec.get("artifact_bucket"),
            "cost_notice": "Creating and invoking this agent can incur runtime, model, S3 and logging charges.",
            "deployment": "Allowlisted Python 3.13 ARM64 ZIP; no Docker or arbitrary workspace upload."
            if spec["service"] == "agentcore" else "Classic agent, preparation and a tagged live alias.",
        }

    request = {"spec": spec, "models": models}
    if spec["service"] == "agentcore":
        request["sources"] = source_hashes()
    run = Run(args, context, request, preview)
    if not args.apply:
        return run.preview_result()
    existing = list_agents(context, spec["service"])
    saved = run.journal.get("create-agent", {})
    saved_result = saved.get("result", {})
    own_id = saved_result.get("agentRuntimeId") or saved_result.get("agent", {}).get("agentId")
    if any(item["name"] == spec["name"] and item["id"] != own_id for item in existing):
        raise ValueError("A new conflicting agent appeared after preview; no agent will be created.")
    tags = {OWNER_TAG: MANAGER, "aws-ai-manager-account": context.account_id, "aws-ai-manager-run": run.plan["token"]}
    if spec["service"] == "agentcore":
        client = context.client("bedrock-agentcore-control")
        artifact = package_agent(run, spec)
        object_key = f"aws-ai-manager/{run.plan['token']}/agent.zip"

        def upload() -> dict:
            with artifact.open("rb") as stream:
                return context.client("s3").put_object(
                    Bucket=spec["artifact_bucket"], Key=object_key, Body=stream,
                    ExpectedBucketOwner=context.account_id, IfNoneMatch="*",
                    ServerSideEncryption="AES256", Tagging=urlencode(tags),
                )

        uploaded = run.call("upload-code", upload)
        location = {"bucket": spec["artifact_bucket"], "prefix": object_key}
        if uploaded.get("VersionId"):
            location["versionId"] = uploaded["VersionId"]
        result = run.call("create-agent", lambda: client.create_agent_runtime(
            agentRuntimeName=spec["name"], clientToken=run.plan["token"],
            agentRuntimeArtifact={"codeConfiguration": {
                "code": {"s3": location}, "runtime": "PYTHON_3_13", "entryPoint": ["agent.py"],
            }},
            networkConfiguration={"networkMode": "PUBLIC"},
            roleArn=spec["execution_role_arn"],
            lifecycleConfiguration={"idleRuntimeSessionTimeout": 300, "maxLifetime": 1800},
            tags=tags,
        ))
        target = {
            "service": "agentcore", "id": result["agentRuntimeId"],
            "arn": result["agentRuntimeArn"], "name": spec["name"],
        }
        wait_for(lambda: get_agent(context, target), "status", {"READY"}, args.timeout)
        require_owned(context, target)
        return {"ok": True, "applied": True, "agent": target, "qualifier": "DEFAULT", "run_dir": str(run.path)}
    client = context.client("bedrock-agent")
    result = run.call("create-agent", lambda: client.create_agent(
        agentName=spec["name"], agentResourceRoleArn=spec["execution_role_arn"],
        foundationModel=spec["model_id"], instruction=spec["instructions"],
        idleSessionTTLInSeconds=300, clientToken=run.plan["token"], tags=tags,
        promptOverrideConfiguration={"promptConfigurations": [{
            "promptType": "ORCHESTRATION",
            "inferenceConfiguration": {"maximumLength": spec["max_tokens"]},
        }]},
    ))["agent"]
    target = {"service": "bedrock", "id": result["agentId"], "arn": result["agentArn"], "name": spec["name"]}
    require_owned(context, target)
    current = get_agent(context, target)
    if not run.journal.get("prepare-agent"):
        wait_for(lambda: get_agent(context, target), "agentStatus", {"NOT_PREPARED", "PREPARED"}, args.timeout)
        run.call("prepare-agent", lambda: client.prepare_agent(agentId=target["id"]))
    elif current["agentStatus"] == "FAILED":
        raise ValueError(f"Classic preparation failed: {json.dumps(current, default=str)}")
    wait_for(lambda: get_agent(context, target), "agentStatus", {"PREPARED"}, args.timeout)
    alias = run.call("create-alias", lambda: client.create_agent_alias(
        agentId=target["id"], agentAliasName="managed", clientToken=run.plan["token"], tags=tags,
    ))["agentAlias"]
    wait_for(
        lambda: client.get_agent_alias(agentId=target["id"], agentAliasId=alias["agentAliasId"])["agentAlias"],
        "agentAliasStatus", {"PREPARED"}, args.timeout,
    )
    return {
        "ok": True, "applied": True, "agent": target,
        "alias_id": alias["agentAliasId"], "run_dir": str(run.path),
    }


def deletion_snapshot(context: AwsContext, target: dict) -> dict:
    tags = require_owned(context, target)
    children = []
    if target["service"] == "agentcore":
        client = context.client("bedrock-agentcore-control")
        endpoints = paginate(client, "list_agent_runtime_endpoints", "runtimeEndpoints", agentRuntimeId=target["id"])
        for item in endpoints:
            if item["name"] != "DEFAULT":
                child = {"service": "agentcore", "arn": item["agentRuntimeEndpointArn"], "name": item["name"]}
                require_owned(context, child)
                children.append(child)
    else:
        client = context.client("bedrock-agent")
        for operation, key in (
            ("list_agent_action_groups", "actionGroupSummaries"),
            ("list_agent_knowledge_bases", "agentKnowledgeBaseSummaries"),
            ("list_agent_collaborators", "agentCollaboratorSummaries"),
        ):
            if paginate(client, operation, key, agentId=target["id"], agentVersion="DRAFT"):
                raise ValueError("The Classic agent has external action groups, knowledge bases or collaborators. Detach them manually first.")
        aliases = paginate(client, "list_agent_aliases", "agentAliasSummaries", agentId=target["id"])
        for item in aliases:
            if item["agentAliasId"] != "TSTALIASID":
                child = {
                    "service": "bedrock", "arn": f"{target['arn'].replace(':agent/', ':agent-alias/')}/{item['agentAliasId']}",
                    "id": item["agentAliasId"], "name": item["agentAliasName"],
                }
                require_owned(context, child)
                children.append(child)
    return {"agent": target, "tags": tags, "children": sorted(children, key=lambda child: child["arn"])}


def delete(context: AwsContext, args: argparse.Namespace, selected: dict) -> dict:
    from botocore.exceptions import ClientError

    def preview() -> dict:
        target = resolve(context, selected)
        snapshot = deletion_snapshot(context, target)
        return {
            "confirmation": target["arn"], "snapshot": snapshot,
            "force_required": bool(snapshot["children"]),
            "deletes": "The selected agent and all its versions; only listed manager-owned children with --force.",
            "retained": ["IAM roles and policies", "S3 buckets and objects", "CloudWatch logs", "models", "unrelated resources"],
            "cost_notice": "Retained storage and logs can continue to incur charges.",
        }

    run = Run(args, context, {"selected": selected, "force": args.force}, preview)
    if not args.apply:
        return run.preview_result()
    snapshot = run.details["snapshot"]
    target = snapshot["agent"]
    try:
        get_agent(context, target)
    except ClientError as error:
        if is_missing(error):
            return {"ok": True, "deleted": True, "agent": target, "verified": "ResourceNotFound", "retained": run.details["retained"]}
        raise
    status_key = "status" if target["service"] == "agentcore" else "agentStatus"
    if run.journal.get("delete-agent", {}).get("state") == "complete":
        wait_for(lambda: get_agent(context, target), status_key, set(), args.timeout, deleted=True)
        return {
            "ok": True, "deleted": True, "agent": target, "verified": "ResourceNotFound",
            "retained": run.details["retained"], "run_dir": str(run.path),
        }
    current = deletion_snapshot(context, target)
    completed_children = {
        name.removeprefix("delete-child-") for name, value in run.journal.items()
        if name.startswith("delete-child-") and value["state"] == "complete"
    }
    original_children = {child["arn"]: child for child in snapshot["children"]}
    current_children = {child["arn"]: child for child in current["children"]}
    changed = current["agent"] != snapshot["agent"] or current["tags"] != snapshot["tags"]
    changed = changed or any(original_children.get(arn) != child for arn, child in current_children.items())
    changed = changed or any(
        child["name"] not in completed_children
        for arn, child in original_children.items() if arn not in current_children
    )
    if changed:
        raise ValueError("The agent ownership or child-resource set changed after preview. Create a fresh deletion preview.")
    if snapshot["children"] and not args.force:
        raise ValueError("The listed managed children require a new --force preview and separate human approval.")
    if target["service"] == "agentcore":
        client = context.client("bedrock-agentcore-control")
        for child in snapshot["children"]:
            step = f"delete-child-{child['name']}"
            run.call(step, lambda child=child: client.delete_agent_runtime_endpoint(
                agentRuntimeId=target["id"], endpointName=child["name"],
                clientToken=str(uuid.uuid5(uuid.UUID(run.plan["token"]), child["arn"])),
            ))
            wait_for(
                lambda child=child: client.get_agent_runtime_endpoint(
                    agentRuntimeId=target["id"], endpointName=child["name"]
                ), "status", set(), args.timeout, deleted=True,
            )
        run.call("delete-agent", lambda: client.delete_agent_runtime(
            agentRuntimeId=target["id"], clientToken=run.plan["token"],
        ))
        status_key = "status"
    else:
        client = context.client("bedrock-agent")
        for child in snapshot["children"]:
            run.call(f"delete-child-{child['name']}", lambda child=child: client.delete_agent_alias(
                agentId=target["id"], agentAliasId=child["id"],
            ))
            wait_for(
                lambda child=child: client.get_agent_alias(
                    agentId=target["id"], agentAliasId=child["id"]
                )["agentAlias"], "agentAliasStatus", set(), args.timeout, deleted=True,
            )
        run.call("delete-agent", lambda: client.delete_agent(agentId=target["id"], skipResourceInUseCheck=False))
        status_key = "agentStatus"
    wait_for(lambda: get_agent(context, target), status_key, set(), args.timeout, deleted=True)
    return {
        "ok": True, "deleted": True, "agent": target, "verified": "ResourceNotFound",
        "retained": run.details["retained"], "run_dir": str(run.path),
    }


def prompts(args: argparse.Namespace) -> list[str]:
    if args.prompt and args.prompts_file:
        raise ValueError("Use --prompt or --prompts-file, not both.")
    supplied = args.prompt
    if args.prompts_file:
        path = Path(args.prompts_file).expanduser().resolve(strict=True)
        if ASSETS.parents[3] in path.parents:
            raise ValueError("Keep private prompts files outside the repository.")
        supplied = json.loads(path.read_text(encoding="utf-8-sig"))
    if supplied is None:
        supplied = [DEFAULT_PROMPT]
    if not isinstance(supplied, list) or not supplied or any(
        not isinstance(item, str) or not item.strip() for item in supplied
    ):
        raise ValueError("Prompts must be a nonempty JSON array of nonempty strings.")
    count = args.count if args.count is not None else (len(supplied) if len(supplied) > 1 else 1)
    if type(count) is not int or count < 1:
        raise ValueError("--count must be a positive integer.")
    if len(supplied) == 1:
        return supplied * count
    if len(supplied) != count:
        raise ValueError("The prompt-array length must equal --count, or provide one prompt to repeat.")
    return supplied


def answer_text(value: object) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        if value.get("error"):
            raise ValueError(f"The agent returned an error: {json.dumps(value, ensure_ascii=True)}")
        if value.get("stop_reason") == "max_tokens" or value.get("stopReason") == "max_tokens":
            raise ValueError("The model response reached its output limit; it is not a complete response.")
        for key in ("result", "response", "output", "text", "content", "message"):
            if key in value:
                return answer_text(value[key])
    if isinstance(value, list):
        return "".join(answer_text(item) for item in value)
    raise ValueError("Unsupported agent response shape; no answer will be guessed.")


def runtime_answer(response: dict) -> str:
    body = response["response"]
    decoder = codecs.getincrementaldecoder("utf-8")()
    try:
        chunks = body.iter_chunks() if hasattr(body, "iter_chunks") else iter(lambda: body.read(65536), b"")
        text = "".join(decoder.decode(chunk) for chunk in chunks) + decoder.decode(b"", final=True)
    finally:
        body.close()
    content_type = response.get("contentType", "").lower()
    if "text/event-stream" in content_type:
        pieces = []
        for event in re.split(r"\r?\n\r?\n", text):
            if any(line.startswith("event:") and line[6:].strip().lower() == "error" for line in event.splitlines()):
                raise ValueError(f"The agent returned an SSE error: {event}")
            data = "\n".join(line[5:].lstrip(" ") for line in event.splitlines() if line.startswith("data:"))
            if not data or data == "[DONE]":
                continue
            try:
                decoded = json.loads(data)
            except json.JSONDecodeError:
                decoded = data
            pieces.append(answer_text(decoded))
        return "".join(pieces)
    if "json" in content_type:
        return answer_text(json.loads(text))
    if content_type.startswith("text/plain"):
        return text
    raise ValueError(f"Unsupported AgentCore response content type: {content_type}.")


def classic_answer(response: dict) -> str:
    stream = response["completion"]
    parts: list[bytes] = []
    try:
        for event in stream:
            if "chunk" in event:
                parts.append(event["chunk"]["bytes"])
            elif "returnControl" in event:
                raise ValueError("The agent requested external action execution; this test runner does not execute tools.")
            elif any(key.endswith("Exception") for key in event):
                raise ValueError(f"The Classic response stream failed: {json.dumps(event, default=str)}")
            elif set(event) - {"trace", "files"}:
                raise ValueError("The Classic stream returned an unsupported event.")
    finally:
        stream.close()
    return b"".join(parts).decode("utf-8")


def send(context: AwsContext, args: argparse.Namespace, selections: list[dict]) -> dict:
    from botocore.exceptions import BotoCoreError, ClientError

    batch = prompts(args)
    run_dir = private_directory(args.run_dir)
    responses_file = run_dir / "responses.json"
    if responses_file.exists():
        raise ValueError("This run already contains responses. Choose a new run directory; prompts will not be resent.")
    targets = [resolve(context, selected) for selected in selections]
    if len({target["arn"] for target in targets}) != len(targets):
        raise ValueError("The same agent was selected more than once.")
    if args.alias_id and not any(item["service"] == "bedrock" for item in targets):
        raise ValueError("--alias-id applies only to Bedrock Agents Classic.")
    if args.qualifier and not any(item["service"] == "agentcore" for item in targets):
        raise ValueError("--qualifier applies only to AgentCore Runtime.")
    prepared = []
    for target, selected in zip(targets, selections):
        metadata = get_agent(context, target)
        if target["service"] == "agentcore":
            if metadata.get("authorizerConfiguration"):
                raise ValueError("OAuth-protected runtimes are not supported by this SigV4 test runner.")
            if metadata.get("protocolConfiguration", {}).get("serverProtocol", "HTTP") != "HTTP":
                raise ValueError("Only HTTP prompt agents are supported; MCP/A2A endpoints are not prompt endpoints.")
            if metadata["status"] != "READY":
                raise ValueError("The selected AgentCore runtime is not ready.")
            qualifier = args.qualifier or selected["qualifier"] or "DEFAULT"
            if args.qualifier and selected["qualifier"] and args.qualifier != selected["qualifier"]:
                raise ValueError("--qualifier conflicts with the console URL.")
        else:
            qualifier = args.alias_id or selected["qualifier"] or "TSTALIASID"
            if args.alias_id and selected["qualifier"] and args.alias_id != selected["qualifier"]:
                raise ValueError("--alias-id conflicts with the console URL.")
            if not re.fullmatch(r"[A-Za-z0-9]{10}", qualifier):
                raise ValueError("A Classic alias ID must contain exactly ten letters/digits.")
        prepared.append((target, qualifier))
    result = {"ok": False, "status": "in_progress", "responses_file": str(responses_file), "responses": []}
    write_json(responses_file, result)
    for target, qualifier in prepared:
        session_id = str(uuid.uuid4())
        for index, prompt in enumerate(batch):
            record = {
                "agent": target, "prompt": prompt, "session_id": session_id,
                "qualifier": qualifier, "status": "pending",
            }
            result["responses"].append(record)
            write_json(responses_file, result)
            started = time.monotonic()
            try:
                if target["service"] == "agentcore":
                    response = context.client("bedrock-agentcore").invoke_agent_runtime(
                        agentRuntimeArn=target["arn"], runtimeSessionId=session_id, qualifier=qualifier,
                        contentType="application/json", accept="application/json",
                        payload=json.dumps({"prompt": prompt}, ensure_ascii=True).encode(),
                    )
                    answer = runtime_answer(response)
                else:
                    response = context.client("bedrock-agent-runtime").invoke_agent(
                        agentId=target["id"], agentAliasId=qualifier, sessionId=session_id,
                        inputText=prompt, enableTrace=False, endSession=index == len(batch) - 1,
                    )
                    answer = classic_answer(response)
                if not answer.strip():
                    raise ValueError("The agent returned an empty answer.")
                passed = args.expected_text is None or args.expected_text.casefold() in answer.casefold()
                record.update(answer=answer, status="passed" if passed else "failed")
            except (BotoCoreError, ClientError, ValueError, UnicodeError, OSError) as error:
                record.update(status="error", error=str(error))
                result.update(ok=False, status="failed", error=str(error))
                return result
            finally:
                record["elapsed_seconds"] = round(time.monotonic() - started, 3)
                write_json(responses_file, result)
    result["ok"] = all(record["status"] == "passed" for record in result["responses"])
    result["status"] = "completed" if result["ok"] else "failed"
    write_json(responses_file, result)
    return result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    for action in ("check-account", "models", "list", "setup", "create", "send", "delete"):
        command = commands.add_parser(action)
        command.add_argument("--auth-dir", required=True)
        command.add_argument("--credentials-file")
        command.add_argument("--credentials-profile", default=MANAGER)
        command.add_argument("--account-id", required=True)
        command.add_argument("--region")
        command.add_argument("--service", choices=SERVICES)
        command.add_argument("--timeout", type=int, default=1800 if action in {"setup", "create", "delete"} else 180)
        if action in {"setup", "create", "send", "delete"}:
            command.add_argument("--run-dir", required=True)
        if action in {"setup", "create", "delete"}:
            command.add_argument("--apply", action="store_true")
            command.add_argument("--confirm")
        if action in {"setup", "create"}:
            command.add_argument("--spec", required=True)
        if action in {"send", "delete"}:
            command.add_argument("--agent", "--agent-url", action="append", required=True)
        if action == "delete":
            command.add_argument("--force", action="store_true")
        if action == "send":
            command.add_argument("--count", type=int)
            command.add_argument("--prompt", action="append")
            command.add_argument("--prompts-file")
            command.add_argument("--expected-text")
            command.add_argument("--qualifier")
            command.add_argument("--alias-id")
        if action == "models":
            command.add_argument("--model-id")
            command.add_argument("--allow-cross-region", action="store_true")
    return parser


def execute(context: AwsContext, args: argparse.Namespace, spec: dict | None, selections: list[dict]) -> dict:
    if args.action == "check-account":
        return {
            "ok": not context.identity["Arn"].endswith(":root"), "identity": context.identity,
            "region": context.region, "classic_notice": CLASSIC_NOTICE,
            "next_step": "Use a non-root identity; then list models and preview setup.",
        }
    context.require_nonroot()
    if args.action == "models":
        if args.model_id:
            return {"ok": True, **model_resources(context, args.model_id, args.allow_cross_region)}
        models = context.client("bedrock").list_foundation_models(byOutputModality="TEXT")["modelSummaries"]
        profiles = paginate(context.client("bedrock"), "list_inference_profiles", "inferenceProfileSummaries")
        return {
            "ok": True, "models": models, "inference_profiles": profiles,
            "notice": "Check the selected model with models --model-id before setup. Profiles may route across regions.",
        }
    if args.action == "list":
        if args.service is None:
            raise ValueError("Select --service agentcore or bedrock explicitly; Classic is not available to new customers.")
        return {"ok": True, "agents": list_agents(context, args.service)}
    if args.action in {"setup", "create"}:
        if spec is None:
            raise ValueError("A validated agent specification is required.")
        return setup(context, args, spec) if args.action == "setup" else create(context, args, spec)
    if args.action == "send":
        return send(context, args, selections)
    return delete(context, args, selections[0])


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if not re.fullmatch(r"\d{12}", args.account_id):
            raise ValueError("--account-id must contain exactly 12 digits.")
        if args.timeout < 1:
            raise ValueError("--timeout must be positive.")
        spec = load_spec(args.spec, args.service) if args.action in {"setup", "create"} else None
        selections = [reference(value, args.service) for value in getattr(args, "agent", [])]
        if args.action == "delete" and len(selections) != 1:
            raise ValueError("Preview and confirm one deletion at a time.")
        regions = {item["region"] for item in selections if item["region"]}
        if args.region:
            regions.add(args.region)
        if len(regions) != 1:
            raise ValueError("Select exactly one explicit region, using --region or the complete console URL/ARN.")
        args.region = regions.pop()
        if not re.fullmatch(r"[a-z]{2}(?:-[a-z]+)+-\d", args.region):
            raise ValueError("Invalid AWS region identifier.")
        if any(item["account_id"] not in {None, args.account_id} for item in selections):
            raise ValueError("The selected ARN conflicts with --account-id.")
        if args.action == "send":
            prompts(args)
            if args.expected_text is not None and not args.expected_text.strip():
                raise ValueError("--expected-text must be nonempty when supplied.")
        try:
            from botocore.exceptions import BotoCoreError, ClientError
        except ImportError as error:
            raise ValueError("Install the pinned scripts/requirements.txt in a dedicated Python environment first.") from error
        private = private_directory(args.auth_dir)
        with process_environment(isolated_environment(private, args.region)):
            context = AwsContext(args, private)
            try:
                result = execute(context, args, spec, selections)
            except (BotoCoreError, ClientError) as error:
                raise ValueError(f"AWS request failed ({aws_error_code(error) or type(error).__name__}): {error}") from error
        print(json.dumps(result, indent=2, ensure_ascii=True, default=str))
        return 0 if result.get("ok", False) else 1
    except (ValueError, OSError, TimeoutError, configparser.Error, subprocess.SubprocessError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=True), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
