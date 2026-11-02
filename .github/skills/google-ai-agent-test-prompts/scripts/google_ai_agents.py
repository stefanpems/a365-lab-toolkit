from __future__ import annotations

import argparse
import asyncio
import base64
from collections.abc import AsyncGenerator, AsyncIterator, Awaitable, Callable, Generator
from contextlib import asynccontextmanager, contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
import gzip
import hashlib
import io
import json
import keyword
import logging
import os
from pathlib import Path
import re
import sys
import tarfile
import time
from typing import Any
from urllib.parse import parse_qs, urlsplit
import uuid

import google.auth
from google.auth.credentials import Credentials
from google.auth.exceptions import GoogleAuthError
from google.auth.transport.requests import AuthorizedSession, Request
import httpx
import requests

from google_ai_environment import (
    PRIVATE_ROOT, REPO_ROOT, WorkflowError, private_path, reject_shared_google_store,
)


JsonObject = dict[str, Any]
CREATE_ASSETS = Path(__file__).resolve().parents[2] / "google-ai-agent-create" / "assets"
DEFAULT_PROMPT = "Who are you and what can you do?"
CLOUD_SCOPE = "https://www.googleapis.com/auth/cloud-platform"
REGISTRY_URL = "https://agentregistry.googleapis.com/v1"
RUNTIME_REFERENCE = "agentregistry.googleapis.com/system/RuntimeReference"
RESOURCE_PATTERN = re.compile(
    r"^projects/([^/]+)/locations/([^/]+)/(agents|reasoningEngines)/([^/]+)$"
)


def object_value(value: object, label: str) -> JsonObject:
    if not isinstance(value, dict):
        raise WorkflowError("INVALID_RESPONSE", f"{label} must be a JSON object.")
    return value


def text_value(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise WorkflowError("INVALID_INPUT", f"{label} must be a non-empty string.")
    return value


def read_object(path: Path) -> JsonObject:
    with path.open(encoding="utf-8-sig") as handle:
        return object_value(json.load(handle), str(path))


def atomic_write(path: Path, value: JsonObject) -> None:
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(value, handle, ensure_ascii=True, indent=2)
            handle.write("\n")
        for attempt in range(5):
            try:
                temporary.replace(path)
                break
            except PermissionError as error:
                if getattr(error, "winerror", None) not in (5, 32, 33) or attempt == 4:
                    raise
                logging.getLogger(__name__).warning(
                    "Windows temporarily blocked the atomic state update; retrying the local write (%s/5). No cloud request is replayed.",
                    attempt + 1,
                )
                time.sleep(0.05 * 2**attempt)
    finally:
        temporary.unlink(missing_ok=True)


def digest(value: object) -> str:
    encoded = json.dumps(value, sort_keys=True, ensure_ascii=True).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def project_alias(name: str, project: str) -> str:
    return re.sub(r"^projects/[^/]+/", f"projects/{project}/", name)


def request_was_rejected(error: WorkflowError) -> bool:
    return error.code == "GOOGLE_API_ERROR" and error.details.get("http_status") in (
        400, 401, 403, 404, 405, 409, 412, 422, 429,
    )


@dataclass(frozen=True)
class Scope:
    project: str
    location: str
    credentials_file: Path

    @property
    def parent(self) -> str:
        return f"projects/{self.project}/locations/{self.location}"

    @property
    def runtime_url(self) -> str:
        return f"https://{self.location}-aiplatform.googleapis.com/v1"

    def public_identity(self) -> JsonObject:
        return {"project": self.project, "location": self.location}


@dataclass(frozen=True)
class Target:
    name: str
    display_name: str
    kind: str
    record: JsonObject


class Journal:
    def __init__(self, path: Path | None, request: JsonObject) -> None:
        self.directory = private_path(path or (PRIVATE_ROOT / "runs" / uuid.uuid4().hex))
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.path = self.directory / "state.json"
        request_hash = digest(request)
        if self.path.exists():
            self.state = read_object(self.path)
            if self.state.get("request_hash") != request_hash:
                raise WorkflowError("RUN_MISMATCH", "This run directory belongs to a different request.")
        else:
            self.state = {
                "request_hash": request_hash,
                "run_id": uuid.uuid4().hex,
                "phase": "planned",
                "responses": [],
                "created_at": datetime.now(timezone.utc).isoformat(),
            }
            self.save()

    def save(self, **updates: object) -> None:
        self.state.update(updates)
        atomic_write(self.path, self.state)

    def result(self, status: str, **values: object) -> JsonObject:
        return {"status": status, "run_dir": str(self.directory), **values}

    @contextmanager
    def locked(self) -> Generator[None, None, None]:
        path = self.directory / "execution.lock"
        try:
            descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError as error:
            raise WorkflowError(
                "RUN_LOCKED",
                "This run is already active. A lock left by an interrupted process must be reviewed before removal.",
            ) from error
        try:
            with os.fdopen(descriptor, "w", encoding="ascii") as handle:
                handle.write(str(os.getpid()))
            yield
        finally:
            path.unlink(missing_ok=True)


def configure_authentication(scope: Scope, run_dir: Path) -> Credentials:
    os.environ["CLOUDSDK_CONFIG"] = str(run_dir / "gcloud-config")
    os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = str(scope.credentials_file)
    os.environ["GOOGLE_CLOUD_PROJECT"] = scope.project
    os.environ["GOOGLE_CLOUD_LOCATION"] = scope.location
    os.environ["GOOGLE_GENAI_USE_VERTEXAI"] = "True"
    os.environ.pop("GOOGLE_API_KEY", None)
    os.environ.pop("GEMINI_API_KEY", None)
    credentials, _ = google.auth.load_credentials_from_file(
        str(scope.credentials_file), scopes=[CLOUD_SCOPE]
    )
    return credentials


def response_error(status: int, body: object) -> WorkflowError:
    data = body if isinstance(body, dict) else {}
    error = data.get("error", {})
    message = error.get("message", "The Google API request failed.") if isinstance(error, dict) else str(error)
    return WorkflowError("GOOGLE_API_ERROR", str(message), details={"http_status": status})


class GoogleApi:
    def __init__(self, scope: Scope, credentials: Credentials, timeout: float = 180) -> None:
        self.scope = scope
        self.credentials = credentials
        self.timeout = timeout
        self.http = AuthorizedSession(credentials, max_refresh_attempts=0)

    def close(self) -> None:
        self.http.close()

    def request(
        self,
        method: str,
        url: str,
        *,
        body: JsonObject | None = None,
        params: JsonObject | None = None,
        missing_ok: bool = False,
    ) -> JsonObject | None:
        for attempt in range(3):
            with self.http.request(
                method, url, json=body, params=params, timeout=(15, self.timeout),
                allow_redirects=False,
            ) as response:
                if missing_ok and response.status_code == 404:
                    return None
                if method == "GET" and response.status_code in (429, 500, 502, 503, 504) and attempt < 2:
                    time.sleep(2**attempt)
                    continue
                if not 200 <= response.status_code < 300:
                    content = response.json() if response.headers.get("content-type", "").startswith("application/json") else {}
                    raise response_error(response.status_code, content)
                return object_value(response.json(), "Google API response")
        raise WorkflowError("RETRY_EXHAUSTED", "The read-only Google API request failed.")

    def list_resources(self, kind: str) -> list[JsonObject]:
        collection = "agents" if kind == "registry" else "reasoningEngines"
        base = REGISTRY_URL if kind == "registry" else self.scope.runtime_url
        url = f"{base}/{self.scope.parent}/{collection}"
        resources: list[JsonObject] = []
        token = ""
        seen: set[str] = set()
        while True:
            data = self.request("GET", url, params={"pageSize": 100, "pageToken": token})
            data = object_value(data, "Resource list")
            page = data.get(collection, [])
            if not isinstance(page, list):
                raise WorkflowError("INVALID_RESPONSE", "The resource list is not an array.")
            resources.extend(object_value(item, "Resource") for item in page)
            token = data.get("nextPageToken", "")
            if not token:
                return resources
            if not isinstance(token, str) or token in seen:
                raise WorkflowError("INVALID_RESPONSE", "The API repeated an invalid pagination token.")
            seen.add(token)

    def resolve(self, selector: str, kind: str) -> Target:
        matches = []
        for record in self.list_resources(kind):
            name = text_value(record.get("name"), "Resource name")
            scoped_alias = project_alias(name, self.scope.project)
            if selector in (name, scoped_alias, name.rsplit("/", 1)[-1], record.get("displayName")):
                matches.append(record)
        if not matches:
            raise WorkflowError("AGENT_NOT_FOUND", "No agent matches the exact name or ID in the selected project and location.")
        if len(matches) != 1:
            raise WorkflowError(
                "AMBIGUOUS_AGENT", "Several agents match. Choose a full resource name.",
                details={"candidates": [record["name"] for record in matches]},
            )
        record = matches[0]
        return Target(record["name"], record.get("displayName", ""), kind, record)

    def managed_runtime(self, target: Target) -> Target:
        if target.kind == "runtime":
            return target
        reference = runtime_reference(target.record)
        for record in self.list_resources("runtime"):
            name = text_value(record.get("name"), "Runtime name")
            alias = project_alias(name, self.scope.project)
            if reference in (name, alias):
                return Target(record["name"], record.get("displayName", ""), "runtime", record)
        raise WorkflowError(
            "UNSUPPORTED_RUNTIME",
            "The registry entry does not resolve to a managed runtime in the selected project and location.",
        )

    def runtime(self, name: str, *, missing_ok: bool = False) -> JsonObject | None:
        return self.request("GET", f"{self.scope.runtime_url}/{name}", missing_ok=missing_ok)

    def wait_operation(self, name: str, timeout: float) -> JsonObject | None:
        pattern = rf"^projects/[^/]+/locations/{re.escape(self.scope.location)}/(?:reasoningEngines/[^/]+/)?operations/[^/]+$"
        if not re.fullmatch(pattern, name):
            raise WorkflowError("INVALID_RESPONSE", "The API returned an invalid operation name.")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            operation = object_value(
                self.request("GET", f"{self.scope.runtime_url}/{name}"), "Operation"
            )
            if operation.get("done"):
                if operation.get("error"):
                    error = object_value(operation["error"], "Operation error")
                    raise WorkflowError(
                        "OPERATION_FAILED", str(error.get("message", "The cloud operation failed.")),
                        details={"operation": name},
                    )
                return object_value(operation.get("response", {}), "Operation response")
            time.sleep(min(2, max(0, deadline - time.monotonic())))
        return None


def runtime_reference(record: JsonObject) -> str | None:
    attributes = record.get("attributes", {})
    reference = attributes.get(RUNTIME_REFERENCE, {}) if isinstance(attributes, dict) else {}
    uri = reference.get("uri", "") if isinstance(reference, dict) else ""
    match = re.search(r"projects/[^/]+/locations/[^/]+/reasoningEngines/[^/:?#]+", str(uri))
    if match:
        return match.group()
    match = re.search(
        r":projects:([^:]+):locations:([^:]+):(?:aiplatform:)?reasoningEngines:([^:]+)$",
        str(record.get("agentId", "")),
    )
    if match:
        return f"projects/{match[1]}/locations/{match[2]}/reasoningEngines/{match[3]}"
    return None


def build_prompts(count: int | None, prompts: list[str] | None) -> list[str]:
    values = [DEFAULT_PROMPT] if prompts is None else prompts
    if not values or any(not isinstance(value, str) or not value.strip() for value in values):
        raise WorkflowError("INVALID_PROMPTS", "Every prompt must be a non-empty string.")
    total = len(values) if count is None else count
    if type(total) is not int or total < 1:
        raise WorkflowError("INVALID_COUNT", "The prompt count must be a positive integer.")
    if len(values) == 1:
        return values * total
    if len(values) != total:
        raise WorkflowError("PROMPT_COUNT_MISMATCH", "Supply exactly X prompts or one prompt to repeat X times.")
    return values


class ScopedGoogleAuth(httpx.Auth):
    def __init__(self, api: GoogleApi, runtime_name: str) -> None:
        self.credentials = api.credentials
        self.host = f"{api.scope.location}-aiplatform.googleapis.com"
        alias = project_alias(runtime_name, api.scope.project)
        self.prefixes = tuple(
            f"/{version}/{name}" for version in ("v1", "v1beta1") for name in (runtime_name, alias)
        )

    async def async_auth_flow(
        self, request: httpx.Request
    ) -> AsyncGenerator[httpx.Request, httpx.Response]:
        if (
            request.url.scheme != "https"
            or request.url.host != self.host
            or request.url.port not in (None, 443)
            or not any(
                request.url.path.startswith(prefix + "/") or request.url.path.startswith(prefix + ":")
                for prefix in self.prefixes
            )
        ):
            raise WorkflowError("UNTRUSTED_ENDPOINT", "Refusing to send Google credentials outside the selected runtime.")
        headers: dict[str, str] = {}
        await asyncio.to_thread(
            self.credentials.before_request, Request(), request.method, str(request.url), headers
        )
        request.headers.update(headers)
        yield request


def event_text(value: object) -> str:
    event = object_value(value, "Agent event")
    if "output" in event:
        event = object_value(event["output"], "Agent event output")
    if event.get("error") or event.get("errorCode") or event.get("error_code"):
        raise WorkflowError("AGENT_ERROR", "The agent returned an error event.", details={"event": event})
    if event.get("partial"):
        return ""
    content = event.get("content", {})
    if not isinstance(content, dict):
        return ""
    parts = content.get("parts", [])
    if not isinstance(parts, list):
        raise WorkflowError("INVALID_RESPONSE", "Agent content parts must be an array.")
    return "".join(
        part["text"] for part in parts
        if isinstance(part, dict) and isinstance(part.get("text"), str) and not part.get("thought")
    )


async def stream_events(response: httpx.Response) -> AsyncIterator[JsonObject]:
    data_lines: list[str] = []
    async for line in response.aiter_lines():
        if line.startswith("data:"):
            data_lines.append(line[5:].lstrip())
        elif not line:
            if data_lines:
                data = "\n".join(data_lines)
                data_lines.clear()
                if data != "[DONE]":
                    yield object_value(json.loads(data), "Stream event")
        elif line.startswith((':', 'event:', 'id:', 'retry:')):
            continue
        elif data_lines:
            raise WorkflowError("INVALID_RESPONSE", "The event stream contains an invalid frame.")
        else:
            yield object_value(json.loads(line), "Stream event")
    if data_lines:
        data = "\n".join(data_lines)
        if data != "[DONE]":
            yield object_value(json.loads(data), "Stream event")


async def check_httpx(response: httpx.Response) -> None:
    if not 200 <= response.status_code < 300:
        await response.aread()
        body = response.json() if response.headers.get("content-type", "").startswith("application/json") else {}
        raise response_error(response.status_code, body)


@asynccontextmanager
async def conversation(
    api: GoogleApi, target: Target, runtime: Target, user_id: str, timeout: float,
    transport: str = "auto",
) -> AsyncGenerator[Callable[[str], Awaitable[str]], None]:
    selected_transport = select_transport(target, runtime, transport)
    async with httpx.AsyncClient(
        auth=ScopedGoogleAuth(api, runtime.name),
        timeout=httpx.Timeout(timeout, connect=15),
        follow_redirects=False,
    ) as http_client:
        if selected_transport == "a2a":
            from google.adk.agents.run_config import RunConfig, StreamingMode
            from google.adk.integrations.agent_registry import AgentRegistry
            from google.adk.runners import Runner
            from google.adk.sessions import InMemorySessionService
            from google.genai import types

            registry = await asyncio.to_thread(
                AgentRegistry, project_id=api.scope.project, location=api.scope.location
            )
            remote = await asyncio.to_thread(
                registry.get_remote_a2a_agent, target.name, httpx_client=http_client
            )
            sessions = InMemorySessionService()
            app_name = "google_ai_agent_test_prompts"
            session = await sessions.create_session(app_name=app_name, user_id=user_id)
            async with Runner(agent=remote, app_name=app_name, session_service=sessions) as runner:
                async def send_a2a(prompt: str) -> str:
                    parts: list[str] = []
                    async for event in runner.run_async(
                        user_id=user_id, session_id=session.id,
                        new_message=types.Content(role="user", parts=[types.Part(text=prompt)]),
                        run_config=RunConfig(streaming_mode=StreamingMode.NONE),
                    ):
                        if event.error_code:
                            raise WorkflowError("AGENT_ERROR", str(event.error_message or event.error_code))
                        parts.append(event_text(event.model_dump(mode="json", exclude_none=True)))
                    return "\n".join(part for part in parts if part)

                yield send_a2a
        else:
            create_method, query_method = native_methods(runtime)
            response = await http_client.post(
                f"{api.scope.runtime_url}/{runtime.name}:query",
                json={"classMethod": create_method, "input": {"user_id": user_id}},
            )
            await check_httpx(response)
            output = object_value(response.json(), "Session response").get("output")
            session_id = text_value(object_value(output, "Session output").get("id"), "Session ID")

            async def send_native(prompt: str) -> str:
                parts: list[str] = []
                async with http_client.stream(
                    "POST", f"{api.scope.runtime_url}/{runtime.name}:streamQuery",
                    params={"alt": "sse"},
                    json={
                        "classMethod": query_method,
                        "input": {"user_id": user_id, "session_id": session_id, "message": prompt},
                    },
                ) as stream:
                    await check_httpx(stream)
                    async for event in stream_events(stream):
                        parts.append(event_text(event))
                return "\n".join(part for part in parts if part)

            yield send_native


def native_methods(runtime: Target) -> tuple[str | None, str | None]:
    methods = object_value(runtime.record.get("spec", {}), "Runtime spec").get("classMethods", [])
    if not isinstance(methods, list):
        raise WorkflowError("INVALID_RESPONSE", "Runtime class methods must be an array.")
    names = {method.get("name") for method in methods if isinstance(method, dict)}
    return (
        next((name for name in ("async_create_session", "create_session") if name in names), None),
        next((name for name in ("async_stream_query", "stream_query") if name in names), None),
    )


def select_transport(target: Target, runtime: Target, requested: str) -> str:
    if requested not in ("auto", "native", "a2a"):
        raise WorkflowError("INVALID_TRANSPORT", "Choose auto, native or a2a.")
    native_ready = all(native_methods(runtime))
    protocols = target.record.get("protocols", [])
    if not isinstance(protocols, list):
        raise WorkflowError("INVALID_RESPONSE", "Registry protocols must be an array.")
    a2a_ready = target.kind == "registry" and any(
        isinstance(protocol, dict) and protocol.get("type") == "A2A_AGENT" for protocol in protocols
    )
    if requested in ("auto", "native") and native_ready:
        return "native"
    if requested in ("auto", "a2a") and a2a_ready:
        return "a2a"
    raise WorkflowError("UNSUPPORTED_AGENT", "The selected agent does not expose the requested native ADK or registry A2A transport.")


async def send_batch(
    api: GoogleApi, target: Target, prompts: list[str], journal: Journal,
    timeout: float, expected_text: str | None, transport: str = "auto",
) -> JsonObject:
    if journal.state["phase"] == "complete":
        return {
            **object_value(journal.state["result"], "Saved result"),
            "responses": journal.state["responses"],
        }
    if journal.state["phase"] != "planned":
        raise WorkflowError(
            "UNCERTAIN_PROMPT_BATCH",
            "An earlier execution was interrupted or failed. Review its private responses before intentionally starting a new batch.",
        )
    runtime = api.managed_runtime(target)
    selected_transport = select_transport(target, runtime, transport)
    journal.save(
        phase="sending", target=target.name, display_name=target.display_name,
        runtime=runtime.name, transport=selected_transport,
    )
    records: list[JsonObject] = []
    async with conversation(
        api, target, runtime, journal.state["run_id"], timeout, selected_transport
    ) as send:
        for index, prompt in enumerate(prompts, 1):
            journal.save(in_flight=index, responses=records)
            start = time.monotonic()
            async with asyncio.timeout(timeout):
                text = await send(prompt)
            if not text.strip():
                raise WorkflowError("EMPTY_RESPONSE", "The agent returned no textual response.", details={"prompt_index": index})
            passed = expected_text is None or expected_text.casefold() in text.casefold()
            records.append({
                "index": index, "prompt": prompt, "response": text,
                "passed": passed, "elapsed_seconds": round(time.monotonic() - start, 3),
            })
            journal.save(in_flight=None, responses=records)
    result = journal.result(
        "complete" if all(record["passed"] for record in records) else "test_failed",
        operation="send", agent=target.name, sent=len(records),
        passed=sum(record["passed"] for record in records),
        responses_file=str(journal.path), display_name=target.display_name,
        transport=selected_transport, responses=records,
    )
    journal.save(phase="complete", result=result)
    return result


def validate_spec(value: JsonObject) -> JsonObject:
    required = ("display_name", "instruction", "model", "service_account")
    for key in required:
        text_value(value.get(key), key)
    allowed = {*required, "agent_name", "description", "min_instances", "max_instances"}
    if value.keys() - allowed:
        raise WorkflowError("INVALID_SPEC", "The creation spec contains unknown fields.")
    if "agent_name" not in value:
        identifier = re.sub(r"[^a-z0-9_]+", "_", value["display_name"].lower()).strip("_")
        if not identifier:
            raise WorkflowError("INVALID_SPEC", "Supply agent_name when the display name cannot produce an ASCII ADK identifier.")
        if identifier[0].isdigit() or keyword.iskeyword(identifier) or identifier == "user":
            identifier = "agent_" + identifier
        value = {**value, "agent_name": identifier}
    agent_name = text_value(value["agent_name"], "agent_name")
    if (
        not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", agent_name)
        or keyword.iskeyword(agent_name) or agent_name == "user"
    ):
        raise WorkflowError("INVALID_SPEC", "agent_name must be a Python identifier.")
    if len(value["display_name"]) > 128:
        raise WorkflowError("INVALID_SPEC", "display_name exceeds 128 characters.")
    if not re.fullmatch(r"[^@\s]+@[^@\s]+\.iam\.gserviceaccount\.com", value["service_account"]):
        raise WorkflowError("INVALID_SPEC", "Provide the existing runtime service-account email.")
    minimum, maximum = value.get("min_instances", 0), value.get("max_instances", 1)
    if (
        type(minimum) is not int or type(maximum) is not int
        or not 0 <= minimum <= 75 or not 1 <= maximum <= 1000 or minimum > maximum
    ):
        raise WorkflowError("INVALID_SPEC", "Invalid min_instances/max_instances range.")
    description = value.get("description", "")
    if not isinstance(description, str):
        raise WorkflowError("INVALID_SPEC", "description must be a string.")
    return {**value, "description": description, "min_instances": minimum, "max_instances": maximum}


def source_archive() -> str:
    output = io.BytesIO()
    with gzip.GzipFile(fileobj=output, mode="wb", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as archive:
            for name in ("agent.py", "requirements.txt"):
                content = (CREATE_ASSETS / name).read_bytes()
                entry = tarfile.TarInfo(name)
                entry.size = len(content)
                entry.mode = 0o644
                archive.addfile(entry, io.BytesIO(content))
    return base64.b64encode(output.getvalue()).decode("ascii")


def creation_payload(scope: Scope, spec: JsonObject, run_id: str) -> JsonObject:
    properties = {
        "user_id": {"type": "string"}, "session_id": {"type": "string"},
        "message": {"type": "string"},
    }
    methods = [
        {
            "name": "async_create_session", "api_mode": "async",
            "parameters": {
                "type": "object", "properties": {"user_id": properties["user_id"]},
                "required": ["user_id"],
            },
        },
        {
            "name": "async_stream_query", "api_mode": "async_stream",
            "parameters": {
                "type": "object", "properties": properties, "required": ["user_id", "message"],
            },
        },
    ]
    env = {
        "GOOGLE_CLOUD_PROJECT": scope.project, "GOOGLE_CLOUD_LOCATION": scope.location,
        "GOOGLE_GENAI_USE_VERTEXAI": "True", "GOOGLE_AGENT_NAME": spec["agent_name"],
        "GOOGLE_AGENT_MODEL": spec["model"], "GOOGLE_AGENT_DESCRIPTION": spec["description"],
        "GOOGLE_AGENT_INSTRUCTION": spec["instruction"],
    }
    return {
        "displayName": spec["display_name"], "description": spec["description"],
        "labels": {"managed_by": "google-ai-manager", "manager_run": run_id},
        "spec": {
            "agentFramework": "google-adk", "serviceAccount": spec["service_account"],
            "sourceCodeSpec": {
                "inlineSource": {"sourceArchive": source_archive()},
                "pythonSpec": {
                    "version": "3.12", "entrypointModule": "agent",
                    "entrypointObject": "root_agent", "requirementsFile": "requirements.txt",
                },
            },
            "classMethods": methods,
            "deploymentSpec": {
                "env": [{"name": key, "value": val} for key, val in env.items()],
                "minInstances": spec["min_instances"], "maxInstances": spec["max_instances"],
            },
        },
    }


def find_registration(api: GoogleApi, runtime_name: str, wait_seconds: float) -> str | None:
    deadline = time.monotonic() + wait_seconds
    while True:
        matches = [
            record["name"] for record in api.list_resources("registry")
            if runtime_reference(record) in (runtime_name, project_alias(runtime_name, api.scope.project))
        ]
        if len(matches) > 1:
            raise WorkflowError("AMBIGUOUS_REGISTRATION", "Multiple registry entries refer to the created runtime.")
        if matches:
            return matches[0]
        if time.monotonic() >= deadline:
            return None
        time.sleep(min(2, max(0, deadline - time.monotonic())))


def create_agent(
    api: GoogleApi, spec: JsonObject, journal: Journal,
    apply: bool, confirm: str | None, timeout: float, registry_wait: float,
) -> JsonObject:
    runtime_name = journal.state.get("runtime")
    operation = journal.state.get("cloud_operation")
    if runtime_name:
        if api.runtime(runtime_name) is None:
            raise WorkflowError("RUNTIME_MISSING", "The recorded runtime no longer exists.")
    elif operation:
        response = api.wait_operation(operation, timeout)
        if response is None:
            return journal.result("pending", cloud_operation=operation)
        runtime_name = text_value(response.get("name"), "Created runtime name")
        journal.save(phase="deployed", runtime=runtime_name)
    else:
        if journal.state["phase"] != "planned":
            raise WorkflowError(
                "UNCERTAIN_CREATION",
                "The create request may have reached Google. Inspect the saved run and manager_run label; do not submit a second create request.",
                details={"manager_run": journal.state["run_id"]},
            )
        existing = [
            record["name"] for record in api.list_resources("runtime")
            if record.get("displayName") == spec["display_name"]
        ]
        if existing:
            raise WorkflowError("AGENT_ALREADY_EXISTS", "The display name is already in use.", details={"candidates": existing})
        if not apply:
            return journal.result(
                "needs_confirmation", operation="create", scope=api.scope.public_identity(),
                display_name=spec["display_name"], agent_name=spec["agent_name"], model=spec["model"],
                service_account=spec["service_account"], min_instances=spec["min_instances"],
                max_instances=spec["max_instances"], confirm=spec["display_name"],
            )
        if confirm != spec["display_name"]:
            raise WorkflowError("CONFIRMATION_REQUIRED", "Confirm the exact display name before provisioning billable resources.")
        payload = creation_payload(api.scope, spec, journal.state["run_id"])
        journal.save(phase="submitting")
        try:
            operation_data = object_value(
                api.request(
                    "POST", f"{api.scope.runtime_url}/{api.scope.parent}/reasoningEngines",
                    body=payload,
                ), "Create operation",
            )
        except WorkflowError as error:
            if request_was_rejected(error):
                journal.save(phase="planned")
            raise
        operation = text_value(operation_data.get("name"), "Create operation name")
        journal.save(phase="creating", cloud_operation=operation)
        response = api.wait_operation(operation, timeout)
        if response is None:
            return journal.result("pending", cloud_operation=operation)
        runtime_name = text_value(response.get("name"), "Created runtime name")
        journal.save(phase="deployed", runtime=runtime_name)
        api.runtime(runtime_name)
    registry_name = find_registration(api, runtime_name, registry_wait)
    if not registry_name:
        return journal.result("registry_pending", operation="create", runtime=runtime_name)
    result = journal.result("complete", operation="create", runtime=runtime_name, registry_agent=registry_name)
    journal.save(phase="complete", result=result)
    return result


def delete_agent(
    api: GoogleApi, selector: str, kind: str, journal: Journal,
    apply: bool, confirm: str | None, force: bool, timeout: float,
) -> JsonObject:
    runtime_name = journal.state.get("runtime")
    if journal.state["phase"] == "complete":
        if api.runtime(text_value(runtime_name, "Recorded runtime"), missing_ok=True) is not None:
            raise WorkflowError("DELETE_NOT_VERIFIED", "The recorded runtime still exists.")
        return journal.result("complete", operation="delete", runtime=runtime_name, already_deleted=True)
    operation = journal.state.get("cloud_operation")
    if operation:
        response = api.wait_operation(operation, timeout)
        if response is None:
            return journal.result("pending", cloud_operation=operation)
    else:
        if journal.state["phase"] not in ("planned", "reviewed"):
            raise WorkflowError("UNCERTAIN_DELETION", "Review the interrupted deletion before submitting another request.")
        target = api.resolve(selector, kind)
        runtime = api.managed_runtime(target)
        if runtime_name and runtime_name != runtime.name:
            raise WorkflowError("TARGET_CHANGED", "The selector now resolves to a different runtime. Review a new plan.")
        runtime_name = runtime.name
        if not apply:
            journal.save(phase="reviewed", runtime=runtime_name)
            return journal.result(
                "needs_confirmation", operation="delete", scope=api.scope.public_identity(),
                display_name=runtime.display_name, runtime=runtime_name, force=force,
                confirm=runtime_name,
            )
        if confirm != runtime_name:
            raise WorkflowError("CONFIRMATION_REQUIRED", "Confirm the exact full managed-runtime resource name.")
        journal.save(phase="deleting", runtime=runtime_name)
        try:
            operation_data = object_value(
                api.request(
                    "DELETE", f"{api.scope.runtime_url}/{runtime_name}",
                    params={"force": str(force).lower()},
                ), "Delete operation",
            )
        except WorkflowError as error:
            if request_was_rejected(error):
                journal.save(phase="reviewed")
            raise
        operation = text_value(operation_data.get("name"), "Delete operation name")
        journal.save(cloud_operation=operation)
        response = api.wait_operation(operation, timeout)
        if response is None:
            return journal.result("pending", cloud_operation=operation)
    if api.runtime(text_value(runtime_name, "Deleted runtime"), missing_ok=True) is not None:
        raise WorkflowError("DELETE_NOT_VERIFIED", "The operation completed but the managed runtime still exists.")
    result = journal.result(
        "complete", operation="delete", runtime=runtime_name,
        registry_sync="Automatic registry synchronization may be delayed.",
    )
    journal.save(phase="complete", result=result)
    return result


def console_url_inputs(value: str, *, require_agent: bool = False) -> dict[str, str]:
    try:
        parsed = urlsplit(value)
        if (
            parsed.scheme != "https" or parsed.hostname != "console.cloud.google.com"
            or parsed.port not in (None, 443) or parsed.username or parsed.password
        ):
            raise ValueError("Not a Google Cloud Console HTTPS URL.")
        query = parse_qs(parsed.query, keep_blank_values=True)
    except ValueError as error:
        raise WorkflowError("INVALID_CONSOLE_URL", "Copy the complete HTTPS address from Google Cloud Console.") from error
    result: dict[str, str] = {}
    for key in ("project", "location", "region"):
        values = query.get(key, [])
        if len(values) > 1 or values and not values[0]:
            raise WorkflowError("AMBIGUOUS_CONSOLE_URL", "The console URL contains an empty or repeated scope parameter.")
        if values:
            destination = "location" if key == "region" else key
            if destination in result and result[destination] != values[0]:
                raise WorkflowError("SCOPE_MISMATCH", "The console URL contains conflicting locations.")
            result[destination] = values[0]
    match = re.fullmatch(
        r"(?:/u/\d+)?/(?:agent-platform|vertex-ai)/agent-registry/agents/([^/]+)/([^/]+)(?:/overview)?/?",
        parsed.path,
    )
    if match:
        if result.get("location") not in (None, match[1]):
            raise WorkflowError("SCOPE_MISMATCH", "The console URL contains conflicting locations.")
        result.update(location=match[1], agent_id=match[2], resource_kind="registry")
    elif require_agent:
        raise WorkflowError("INVALID_AGENT_URL", "Open Agent Platform > Agent Registry > Agents, open the target agent, and copy its complete address.")
    return result


def matching_project(left: str, right: str) -> bool:
    return left == right or left.isdecimal() != right.isdecimal()


def load_inputs(args: argparse.Namespace) -> tuple[Scope, str | None, str]:
    config_path = private_path(args.config) if args.config else None
    config = read_object(config_path) if config_path else {}
    allowed = {"project", "location", "credentials_file", "agent", "agent_url", "project_url", "resource_kind"}
    if config.keys() - allowed:
        raise WorkflowError("INVALID_CONFIG", "The target configuration contains unknown fields.")
    selector = args.agent or config.get("agent_url") or config.get("agent")
    project_url = args.project_url or config.get("project_url")
    derived = console_url_inputs(text_value(project_url, "project_url")) if project_url else {}
    selector_from_url = False
    if selector is not None:
        selector = text_value(selector, "agent")
        selector_values: dict[str, str] = {}
        if selector.startswith(("https://", "http://")):
            selector_values = console_url_inputs(selector, require_agent=True)
            selector_from_url = True
            selector = None
        elif match := RESOURCE_PATTERN.fullmatch(selector):
            selector_values = {"project": match[1], "location": match[2]}
        for key in ("project", "location"):
            if key in derived and key in selector_values:
                compatible = matching_project(derived[key], selector_values[key]) if key == "project" else derived[key] == selector_values[key]
                if not compatible:
                    raise WorkflowError("SCOPE_MISMATCH", "The supplied console URLs or resources identify different environments.")
        derived.update(selector_values)
    project = text_value(args.project or config.get("project") or derived.get("project"), "project")
    location = text_value(args.location or config.get("location") or derived.get("location"), "location")
    if derived.get("project") and not matching_project(project, derived["project"]):
        raise WorkflowError("SCOPE_MISMATCH", "The console URL or resource identifies a different project.")
    if derived.get("location") not in (None, location):
        raise WorkflowError("SCOPE_MISMATCH", "The console URL or resource identifies a different location.")
    if not re.fullmatch(r"[a-z][a-z0-9-]{4,61}[a-z0-9]|\d{6,}", project):
        raise WorkflowError("INVALID_PROJECT", "Provide a Google project ID or project number.")
    if not re.fullmatch(r"[a-z][a-z0-9-]{1,62}", location):
        raise WorkflowError("INVALID_LOCATION", "Provide the Google location explicitly.")
    if selector_from_url:
        selector = f"projects/{project}/locations/{location}/agents/{derived['agent_id']}"
    credential_value = args.credentials_file or config.get("credentials_file")
    credential_path = Path(text_value(str(credential_value) if credential_value else None, "credentials_file"))
    if not credential_path.is_absolute() and config_path and not args.credentials_file:
        credential_path = config_path.parent / credential_path
    credential_path = private_path(credential_path)
    reject_shared_google_store(credential_path)
    if not credential_path.is_file():
        raise WorkflowError("MISSING_CREDENTIALS", "Select an existing credential file, or run the isolated Edge browser helper and supply its returned credential-file path. No shared ADC fallback is attempted.")
    inferred = None
    if selector and (match := RESOURCE_PATTERN.fullmatch(selector)):
        if match[2] != location:
            raise WorkflowError("SCOPE_MISMATCH", "The agent resource uses a different location.")
        inferred = "registry" if match[3] == "agents" else "runtime"
    kind = args.resource_kind or config.get("resource_kind") or inferred or "registry"
    if kind not in ("registry", "runtime") or inferred and inferred != kind:
        raise WorkflowError("RESOURCE_KIND_MISMATCH", "Select registry or runtime consistently with the resource name.")
    return Scope(project, location, credential_path), selector, kind


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description="Script-first Google AI agent management. Accepts explicit files or isolated browser credentials from google_ai_environment.py.")
    commands = root.add_subparsers(dest="command", required=True)
    for command in ("discover", "send", "create", "delete"):
        item = commands.add_parser(command)
        item.add_argument("--config", type=Path)
        item.add_argument("--project")
        item.add_argument("--project-url", help="Google Cloud Console URL from which to derive the project and any location.")
        item.add_argument("--location")
        item.add_argument("--credentials-file", type=Path)
        item.add_argument("--resource-kind", choices=("registry", "runtime"))
        item.add_argument("--agent", "--agent-url", help="Exact name, full resource name, or copied Agent Registry console URL.")
        item.add_argument("--run-dir", type=Path)
        item.add_argument("--timeout", type=float, default=1800 if command == "create" else 180)
        if command == "send":
            item.add_argument("--count", type=int)
            item.add_argument("--prompt", action="append")
            item.add_argument("--prompts-file", type=Path)
            item.add_argument("--expected-text")
            item.add_argument("--transport", choices=("auto", "native", "a2a"), default="auto")
        if command in ("create", "delete"):
            item.add_argument("--apply", action="store_true")
            item.add_argument("--confirm")
        if command == "create":
            item.add_argument("--spec", type=Path, required=True)
            item.add_argument("--registry-wait", type=float, default=30)
        if command == "delete":
            item.add_argument("--force", action="store_true")
    return root


def execute(args: argparse.Namespace) -> JsonObject:
    if args.timeout <= 0 or not args.timeout < float("inf"):
        raise WorkflowError("INVALID_TIMEOUT", "timeout must be a finite positive number.")
    scope, selector, kind = load_inputs(args)
    request: JsonObject = {"command": args.command, "scope": scope.public_identity(), "agent": selector, "kind": kind}
    prompts: list[str] = []
    spec: JsonObject = {}
    if args.command in ("send", "delete") and not selector:
        raise WorkflowError("MISSING_AGENT", "Identify the target agent before executing this skill.")
    if args.command == "send":
        if args.expected_text is not None and not args.expected_text.strip():
            raise WorkflowError("INVALID_EXPECTED_TEXT", "expected-text must not be empty.")
        values = args.prompt
        if args.prompts_file:
            if values:
                raise WorkflowError("INVALID_PROMPTS", "Use --prompt or --prompts-file, not both.")
            with private_path(args.prompts_file).open(encoding="utf-8-sig") as handle:
                values = json.load(handle)
            if not isinstance(values, list) or not values:
                raise WorkflowError("INVALID_PROMPTS", "The private prompt file must contain a non-empty JSON array.")
        prompts = build_prompts(args.count, values)
        request.update(prompts_hash=digest(prompts), expected_text=args.expected_text)
        if args.transport != "auto":
            request["transport"] = args.transport
    if args.command == "create":
        spec = validate_spec(read_object(private_path(args.spec)))
        if args.registry_wait < 0 or not args.registry_wait < float("inf"):
            raise WorkflowError("INVALID_TIMEOUT", "registry-wait must be finite and non-negative.")
        request["spec_hash"] = digest(spec)
        request["source_hash"] = digest(source_archive())
    if args.command == "delete":
        request["force"] = args.force
    journal = Journal(args.run_dir, request)
    with journal.locked():
        credentials = configure_authentication(scope, journal.directory)
        api = GoogleApi(scope, credentials, min(args.timeout, 180))
        try:
            if args.command == "discover":
                targets = [api.resolve(selector, kind).record] if selector else api.list_resources(kind)
                return journal.result(
                    "complete", operation="discover", scope=scope.public_identity(), resource_kind=kind,
                    agents=[{
                        "name": record["name"], "display_name": record.get("displayName", ""),
                        "runtime": runtime_reference(record) if kind == "registry" else record["name"],
                    } for record in targets],
                )
            if args.command == "send":
                if journal.state["phase"] == "complete":
                    return {
                        **object_value(journal.state["result"], "Saved result"),
                        "responses": journal.state["responses"],
                    }
                target = api.resolve(text_value(selector, "agent"), kind)
                return asyncio.run(send_batch(
                    api, target, prompts, journal, args.timeout, args.expected_text, args.transport
                ))
            if args.command == "create":
                return create_agent(api, spec, journal, args.apply, args.confirm, args.timeout, args.registry_wait)
            return delete_agent(
                api, text_value(selector, "agent"), kind, journal,
                args.apply, args.confirm, args.force, args.timeout,
            )
        except (
            WorkflowError, GoogleAuthError, requests.RequestException, httpx.HTTPError,
            TimeoutError, OSError, ValueError,
        ) as error:
            code = error.code if isinstance(error, WorkflowError) else type(error).__name__
            details = dict(error.details) if isinstance(error, WorkflowError) else {}
            details["run_dir"] = str(journal.directory)
            details["phase"] = journal.state["phase"]
            if args.command == "send":
                details["responses"] = journal.state["responses"]
                details["display_name"] = journal.state.get("display_name", "")
            for key in ("runtime", "cloud_operation", "in_flight"):
                if journal.state.get(key) is not None:
                    details[key] = journal.state[key]
            raise WorkflowError(code, str(error), details=details) from error
        finally:
            api.close()


def main() -> int:
    args = parser().parse_args()
    try:
        result = execute(args)
    except WorkflowError as error:
        print(json.dumps({"status": "error", "code": error.code, "message": str(error), **error.details}), file=sys.stderr)
        return 2
    except (GoogleAuthError, requests.RequestException, httpx.HTTPError, TimeoutError, OSError, ValueError) as error:
        print(json.dumps({"status": "error", "code": type(error).__name__, "message": str(error)}), file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=True))
    if result["status"] in ("pending", "registry_pending"):
        return 4
    return 3 if result["status"] == "test_failed" else 0


if __name__ == "__main__":
    raise SystemExit(main())
