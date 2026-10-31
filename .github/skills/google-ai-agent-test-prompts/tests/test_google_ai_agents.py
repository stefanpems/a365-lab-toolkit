from __future__ import annotations

import ast
import asyncio
import base64
from collections.abc import AsyncGenerator
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import MagicMock, patch

from google.auth.credentials import Credentials
import httpx
import yaml


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
import google_ai_agents as manager


RUNTIME = "projects/123456789012/locations/europe-west1/reasoningEngines/100"
REGISTRY = "projects/123456789012/locations/europe-west1/agents/example-agent"
OPERATION = RUNTIME + "/operations/example-operation"


class FakeCredentials(Credentials):
    def __init__(self) -> None:
        super().__init__()
        self.token = "example-test-token"

    def refresh(self, request: object) -> None:
        self.token = "example-test-token"


def runtime_record(name: str = RUNTIME) -> manager.JsonObject:
    return {
        "name": name,
        "displayName": "Example Assistant",
        "spec": {
            "classMethods": [
                {"name": "async_create_session"}, {"name": "async_stream_query"}
            ]
        },
    }


def registry_record() -> manager.JsonObject:
    return {
        "name": REGISTRY,
        "displayName": "Example Assistant",
        "attributes": {manager.RUNTIME_REFERENCE: {"uri": "//aiplatform.googleapis.com/" + RUNTIME}},
        "protocols": [],
    }


class WorkflowTestBase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="google-ai-manager-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        credential_file = self.directory / "example.credentials.json"
        credential_file.write_text("{}", encoding="utf-8")
        self.scope = manager.Scope("example-project", "europe-west1", credential_file)
        self.api = manager.GoogleApi(self.scope, FakeCredentials())
        self.addCleanup(self.api.close)
        self.implicit_auth = patch(
            "google.auth.default",
            side_effect=AssertionError("Shared default credentials must not be used."),
        )
        self.implicit_auth.start()
        self.addCleanup(self.implicit_auth.stop)

    def journal(self, name: str = "run") -> manager.Journal:
        return manager.Journal(self.directory / name, {"operation": name})

    def spec(self) -> manager.JsonObject:
        return manager.validate_spec({
            "display_name": "Example Assistant",
            "agent_name": "example_assistant",
            "model": "example-model",
            "instruction": "Use fictional examples.",
            "service_account": "example-runtime@example-project.iam.gserviceaccount.com",
        })


class WorkflowTests(WorkflowTestBase):
    def test_default_prompt_and_explicit_count(self) -> None:
        self.assertEqual(manager.build_prompts(None, None), [manager.DEFAULT_PROMPT])
        self.assertEqual(manager.build_prompts(4, None), [manager.DEFAULT_PROMPT] * 4)
        self.assertEqual(manager.DEFAULT_PROMPT, "Who are you and what can you do?")

    def test_custom_prompt_shapes(self) -> None:
        self.assertEqual(manager.build_prompts(3, ["Hello."]), ["Hello."] * 3)
        self.assertEqual(manager.build_prompts(None, ["First.", "Second."]), ["First.", "Second."])
        with self.assertRaises(manager.WorkflowError):
            manager.build_prompts(3, ["First.", "Second."])

    def test_invalid_prompt_inputs_fail(self) -> None:
        for count, values in ((0, None), (-1, None), (True, None), (1, [" "]), (1, [])):
            with self.subTest(count=count, values=values), self.assertRaises(manager.WorkflowError):
                manager.build_prompts(count, values)

    def test_pagination_collects_all_pages(self) -> None:
        with patch.object(self.api, "request", side_effect=[
            {"agents": [registry_record()], "nextPageToken": "next"},
            {"agents": [{**registry_record(), "name": REGISTRY + "-2"}]},
        ]) as request:
            self.assertEqual(len(self.api.list_resources("registry")), 2)
            self.assertEqual(request.call_args_list[1].kwargs["params"]["pageToken"], "next")

    def test_repeated_pagination_token_fails(self) -> None:
        with patch.object(self.api, "request", return_value={"agents": [], "nextPageToken": "same"}):
            with self.assertRaisesRegex(manager.WorkflowError, "pagination"):
                self.api.list_resources("registry")

    def test_ambiguous_names_do_not_select_first(self) -> None:
        with patch.object(self.api, "list_resources", return_value=[
            registry_record(), {**registry_record(), "name": REGISTRY + "-2"},
        ]):
            with self.assertRaises(manager.WorkflowError) as raised:
                self.api.resolve("Example Assistant", "registry")
        self.assertEqual(raised.exception.code, "AMBIGUOUS_AGENT")
        self.assertEqual(len(raised.exception.details["candidates"]), 2)

    def test_full_project_id_alias_resolves_canonical_number(self) -> None:
        with patch.object(self.api, "list_resources", return_value=[registry_record()]):
            selector = REGISTRY.replace("123456789012", self.scope.project)
            self.assertEqual(self.api.resolve(selector, "registry").name, REGISTRY)
            with self.assertRaises(manager.WorkflowError):
                self.api.resolve(REGISTRY.replace("123456789012", "other-project"), "registry")

    def test_registry_runtime_mapping_checks_scope(self) -> None:
        record = registry_record()
        record["attributes"][manager.RUNTIME_REFERENCE]["uri"] = RUNTIME.replace("123456789012", self.scope.project)
        target = manager.Target(REGISTRY, "Example Assistant", "registry", record)
        with patch.object(self.api, "list_resources", return_value=[runtime_record()]):
            self.assertEqual(self.api.managed_runtime(target).name, RUNTIME)
            record["attributes"][manager.RUNTIME_REFERENCE]["uri"] = RUNTIME.replace("123456789012", "other-project")
            with self.assertRaises(manager.WorkflowError):
                self.api.managed_runtime(target)

    def test_runtime_urn_is_recognized(self) -> None:
        value = {"agentId": "urn:agent:projects-example:projects:123456789012:locations:europe-west1:aiplatform:reasoningEngines:100"}
        self.assertEqual(manager.runtime_reference(value), RUNTIME)
        self.assertIsNone(manager.runtime_reference({"agentId": "unrelated"}))

    def test_journal_rejects_different_requests(self) -> None:
        self.journal()
        with self.assertRaisesRegex(manager.WorkflowError, "different request"):
            manager.Journal(self.directory / "run", {"operation": "other"})

    def test_journal_lock_prevents_parallel_execution(self) -> None:
        journal = self.journal()
        with journal.locked(), self.assertRaises(manager.WorkflowError):
            with journal.locked():
                self.fail("A concurrent run acquired the lock.")
        self.assertFalse((journal.directory / "execution.lock").exists())

    def test_private_paths_are_not_allowed_in_public_folders(self) -> None:
        with self.assertRaises(manager.WorkflowError):
            manager.private_path(manager.REPO_ROOT / "google-ai.local.json")
        path = manager.REPO_ROOT / ".google-ai-private" / "target.json"
        self.assertEqual(manager.private_path(path), path)

    def test_explicit_authentication_is_process_isolated(self) -> None:
        with patch.dict("os.environ", {}, clear=True), patch(
            "google.auth.load_credentials_from_file", return_value=(FakeCredentials(), None)
        ) as load:
            manager.configure_authentication(self.scope, self.directory)
            import os
            self.assertEqual(os.environ["GOOGLE_APPLICATION_CREDENTIALS"], str(self.scope.credentials_file))
            self.assertEqual(os.environ["CLOUDSDK_CONFIG"], str(self.directory / "gcloud-config"))
            self.assertEqual(load.call_args.args[0], str(self.scope.credentials_file))

    def test_configuration_relative_credentials_and_cli_overrides(self) -> None:
        config = self.directory / "target.json"
        config.write_text(json.dumps({
            "project": self.scope.project, "location": self.scope.location,
            "credentials_file": "example.credentials.json", "agent": REGISTRY,
        }), encoding="utf-8")
        args = manager.parser().parse_args(["send", "--config", str(config)])
        scope, selector, kind = manager.load_inputs(args)
        self.assertEqual(scope.credentials_file, self.scope.credentials_file)
        self.assertEqual((selector, kind), (REGISTRY, "registry"))

    def test_missing_identification_prevents_authentication(self) -> None:
        args = manager.parser().parse_args(["send", "--count", "2"])
        with patch.object(manager, "configure_authentication") as auth:
            with self.assertRaises(manager.WorkflowError):
                manager.execute(args)
            auth.assert_not_called()

    def test_empty_expected_text_prevents_execution(self) -> None:
        args = manager.parser().parse_args([
            "send", "--project", self.scope.project, "--location", self.scope.location,
            "--credentials-file", str(self.scope.credentials_file), "--agent", REGISTRY,
            "--expected-text", "",
        ])
        with patch.object(manager, "configure_authentication") as auth:
            with self.assertRaises(manager.WorkflowError) as raised:
                manager.execute(args)
            auth.assert_not_called()
        self.assertEqual(raised.exception.code, "INVALID_EXPECTED_TEXT")

    def test_failure_retains_the_exact_private_run_directory(self) -> None:
        args = manager.parser().parse_args([
            "send", "--project", self.scope.project, "--location", self.scope.location,
            "--credentials-file", str(self.scope.credentials_file), "--agent", REGISTRY,
            "--run-dir", str(self.directory / "execution"),
        ])
        with (
            patch.object(manager, "configure_authentication", return_value=FakeCredentials()),
            patch.object(manager, "GoogleApi", return_value=self.api),
            patch.object(self.api, "resolve", side_effect=manager.WorkflowError("EXAMPLE_FAILURE", "Example failure.")),
            self.assertRaises(manager.WorkflowError) as raised,
        ):
            manager.execute(args)
        self.assertEqual(raised.exception.details["run_dir"], str(self.directory / "execution"))
        self.assertEqual(raised.exception.details["phase"], "planned")

    def test_location_and_resource_kind_must_match(self) -> None:
        common = [
            "send", "--project", self.scope.project, "--location", self.scope.location,
            "--credentials-file", str(self.scope.credentials_file),
        ]
        for tail in (
            ["--agent", REGISTRY.replace("europe-west1", "us-central1")],
            ["--agent", RUNTIME, "--resource-kind", "registry"],
        ):
            with self.subTest(tail=tail), self.assertRaises(manager.WorkflowError):
                manager.load_inputs(manager.parser().parse_args(common + tail))

    def test_source_archive_is_deterministic_and_allowlisted(self) -> None:
        archive = manager.source_archive()
        self.assertEqual(archive, manager.source_archive())
        with tarfile.open(fileobj=io.BytesIO(base64.b64decode(archive)), mode="r:gz") as package:
            self.assertEqual(package.getnames(), ["agent.py", "requirements.txt"])
            for entry in package.getmembers():
                self.assertTrue(entry.isfile())
                self.assertNotIn("..", entry.name)
            source = package.extractfile("agent.py")
            self.assertIsNotNone(source)
            ast.parse(source.read().decode("utf-8"))

    def test_creation_payload_has_no_operator_credentials(self) -> None:
        payload = manager.creation_payload(self.scope, self.spec(), "example-run")
        self.assertEqual(payload["spec"]["sourceCodeSpec"]["pythonSpec"]["entrypointModule"], "agent")
        self.assertEqual(payload["spec"]["sourceCodeSpec"]["pythonSpec"]["version"], "3.12")
        self.assertEqual(payload["spec"]["deploymentSpec"]["minInstances"], 0)
        self.assertEqual(payload["labels"]["managed_by"], "google-ai-manager")
        environment = {entry["name"]: entry["value"] for entry in payload["spec"]["deploymentSpec"]["env"]}
        self.assertEqual(environment["GOOGLE_AGENT_NAME"], self.spec()["agent_name"])
        self.assertEqual(environment["GOOGLE_AGENT_MODEL"], self.spec()["model"])
        self.assertEqual(environment["GOOGLE_AGENT_INSTRUCTION"], self.spec()["instruction"])
        self.assertNotIn("GOOGLE_APPLICATION_CREDENTIALS", environment)
        serialized = json.dumps(payload)
        self.assertNotIn(str(self.scope.credentials_file), serialized)
        self.assertNotIn("example-test-token", serialized)
        self.assertEqual(payload["spec"]["serviceAccount"], self.spec()["service_account"])

    def test_invalid_creation_specs_are_rejected(self) -> None:
        for changes in (
            {"agent_name": "name with spaces"}, {"agent_name": "class"}, {"agent_name": "user"},
            {"model": ""}, {"service_account": "not-an-email"},
            {"min_instances": 2, "max_instances": 1}, {"max_instances": True},
            {"unexpected": "field"},
        ):
            with self.subTest(changes=changes), self.assertRaises(manager.WorkflowError):
                manager.validate_spec({**self.spec(), **changes})

    def test_create_preview_does_not_mutate(self) -> None:
        with patch.object(self.api, "list_resources", return_value=[]), patch.object(self.api, "request") as request:
            result = manager.create_agent(self.api, self.spec(), self.journal(), False, None, 1, 0)
        self.assertEqual(result["status"], "needs_confirmation")
        request.assert_not_called()

    def test_create_requires_exact_confirmation(self) -> None:
        with patch.object(self.api, "list_resources", return_value=[]), patch.object(self.api, "request") as request:
            with self.assertRaises(manager.WorkflowError):
                manager.create_agent(self.api, self.spec(), self.journal(), True, "wrong", 1, 0)
        request.assert_not_called()

    def test_local_packaging_failure_does_not_mark_a_cloud_submission(self) -> None:
        journal = self.journal()
        with (
            patch.object(self.api, "list_resources", return_value=[]),
            patch.object(manager, "creation_payload", side_effect=OSError("Local package unavailable.")),
            patch.object(self.api, "request") as request,
            self.assertRaises(OSError),
        ):
            manager.create_agent(self.api, self.spec(), journal, True, "Example Assistant", 1, 0)
        self.assertEqual(journal.state["phase"], "planned")
        request.assert_not_called()

    def test_create_duplicate_display_name_is_refused(self) -> None:
        with patch.object(self.api, "list_resources", return_value=[runtime_record()]):
            with self.assertRaises(manager.WorkflowError) as raised:
                manager.create_agent(self.api, self.spec(), self.journal(), True, "Example Assistant", 1, 0)
        self.assertEqual(raised.exception.code, "AGENT_ALREADY_EXISTS")

    def test_create_pending_operation_resumes_without_another_post(self) -> None:
        journal = self.journal()
        with (
            patch.object(self.api, "list_resources", return_value=[]),
            patch.object(self.api, "request", return_value={"name": OPERATION}) as request,
            patch.object(self.api, "wait_operation", return_value=None),
        ):
            result = manager.create_agent(self.api, self.spec(), journal, True, "Example Assistant", 1, 0)
        self.assertEqual(result["status"], "pending")
        request.assert_called_once()
        with (
            patch.object(self.api, "runtime", return_value=runtime_record()),
            patch.object(self.api, "wait_operation", return_value={"name": RUNTIME}),
            patch.object(self.api, "list_resources", return_value=[registry_record()]),
            patch.object(self.api, "request") as request,
        ):
            result = manager.create_agent(self.api, self.spec(), self.journal(), True, "Example Assistant", 1, 0)
        self.assertEqual(result["status"], "complete")
        request.assert_not_called()

    def test_pending_registration_does_not_recreate_runtime(self) -> None:
        journal = self.journal()
        journal.save(phase="deployed", runtime=RUNTIME)
        with (
            patch.object(self.api, "runtime", return_value=runtime_record()),
            patch.object(self.api, "list_resources", return_value=[]),
            patch.object(self.api, "request") as request,
        ):
            result = manager.create_agent(self.api, self.spec(), journal, True, "Example Assistant", 1, 0)
        self.assertEqual(result["status"], "registry_pending")
        request.assert_not_called()

    def test_registration_matches_project_id_alias(self) -> None:
        record = registry_record()
        record["attributes"][manager.RUNTIME_REFERENCE]["uri"] = RUNTIME.replace(
            "123456789012", self.scope.project
        )
        with patch.object(self.api, "list_resources", return_value=[record]):
            self.assertEqual(manager.find_registration(self.api, RUNTIME, 0), REGISTRY)

    def test_rejected_create_can_be_explicitly_retried(self) -> None:
        journal = self.journal()
        rejected = manager.WorkflowError(
            "GOOGLE_API_ERROR", "Permission denied.", details={"http_status": 403}
        )
        with (
            patch.object(self.api, "list_resources", return_value=[]),
            patch.object(self.api, "request", side_effect=rejected) as request,
            self.assertRaises(manager.WorkflowError),
        ):
            manager.create_agent(self.api, self.spec(), journal, True, "Example Assistant", 1, 0)
        self.assertEqual(request.call_count, 1)
        self.assertEqual(journal.state["phase"], "planned")

    def test_unknown_create_failure_remains_uncertain(self) -> None:
        journal = self.journal()
        uncertain = manager.WorkflowError(
            "GOOGLE_API_ERROR", "Unknown server outcome.", details={"http_status": 503}
        )
        with (
            patch.object(self.api, "list_resources", return_value=[]),
            patch.object(self.api, "request", side_effect=uncertain),
            self.assertRaises(manager.WorkflowError),
        ):
            manager.create_agent(self.api, self.spec(), journal, True, "Example Assistant", 1, 0)
        self.assertEqual(journal.state["phase"], "submitting")

    def test_uncertain_creation_is_not_replayed(self) -> None:
        journal = self.journal()
        journal.save(phase="submitting")
        with patch.object(self.api, "request") as request, self.assertRaises(manager.WorkflowError) as raised:
            manager.create_agent(self.api, self.spec(), journal, True, "Example Assistant", 1, 0)
        self.assertEqual(raised.exception.code, "UNCERTAIN_CREATION")
        request.assert_not_called()

    def test_delete_preview_does_not_mutate(self) -> None:
        target = manager.Target(RUNTIME, "Example Assistant", "runtime", runtime_record())
        with patch.object(self.api, "resolve", return_value=target), patch.object(self.api, "request") as request:
            result = manager.delete_agent(self.api, "Example Assistant", "runtime", self.journal(), False, None, False, 1)
        self.assertEqual(result["confirm"], RUNTIME)
        self.assertFalse(result["force"])
        request.assert_not_called()

    def test_delete_requires_exact_runtime_confirmation(self) -> None:
        target = manager.Target(RUNTIME, "Example Assistant", "runtime", runtime_record())
        with patch.object(self.api, "resolve", return_value=target), patch.object(self.api, "request") as request:
            with self.assertRaises(manager.WorkflowError):
                manager.delete_agent(self.api, "Example Assistant", "runtime", self.journal(), True, "Example Assistant", False, 1)
        request.assert_not_called()

    def test_delete_is_verified_and_idempotent(self) -> None:
        journal = self.journal()
        target = manager.Target(RUNTIME, "Example Assistant", "runtime", runtime_record())
        with (
            patch.object(self.api, "resolve", return_value=target),
            patch.object(self.api, "request", return_value={"name": OPERATION}) as request,
            patch.object(self.api, "wait_operation", return_value={}),
            patch.object(self.api, "runtime", return_value=None),
        ):
            result = manager.delete_agent(self.api, "Example Assistant", "runtime", journal, True, RUNTIME, False, 1)
            self.assertEqual(request.call_args.kwargs["params"], {"force": "false"})
        self.assertEqual(result["status"], "complete")
        with (
            patch.object(self.api, "runtime", return_value=None),
            patch.object(self.api, "resolve") as resolve,
            patch.object(self.api, "request") as request,
        ):
            repeated = manager.delete_agent(self.api, "Example Assistant", "runtime", self.journal(), True, RUNTIME, False, 1)
        self.assertTrue(repeated["already_deleted"])
        resolve.assert_not_called()
        request.assert_not_called()

    def test_delete_pending_operation_resumes_without_delete(self) -> None:
        journal = self.journal()
        journal.save(phase="deleting", runtime=RUNTIME, cloud_operation=OPERATION)
        with (
            patch.object(self.api, "wait_operation", return_value={}),
            patch.object(self.api, "runtime", return_value=None),
            patch.object(self.api, "request") as request,
        ):
            result = manager.delete_agent(self.api, "Example Assistant", "runtime", journal, True, RUNTIME, True, 1)
        self.assertEqual(result["status"], "complete")
        request.assert_not_called()

    def test_rejected_delete_retains_reviewed_target(self) -> None:
        journal = self.journal()
        target = manager.Target(RUNTIME, "Example Assistant", "runtime", runtime_record())
        rejected = manager.WorkflowError(
            "GOOGLE_API_ERROR", "Child resources exist.", details={"http_status": 412}
        )
        with (
            patch.object(self.api, "resolve", return_value=target),
            patch.object(self.api, "request", side_effect=rejected),
            self.assertRaises(manager.WorkflowError),
        ):
            manager.delete_agent(self.api, "Example Assistant", "runtime", journal, True, RUNTIME, False, 1)
        self.assertEqual(journal.state["phase"], "reviewed")
        self.assertEqual(journal.state["runtime"], RUNTIME)

    def test_completed_operation_does_not_hide_existing_runtime(self) -> None:
        journal = self.journal()
        journal.save(phase="deleting", runtime=RUNTIME, cloud_operation=OPERATION)
        with (
            patch.object(self.api, "wait_operation", return_value={}),
            patch.object(self.api, "runtime", return_value=runtime_record()),
            self.assertRaises(manager.WorkflowError) as raised,
        ):
            manager.delete_agent(self.api, "Example Assistant", "runtime", journal, True, RUNTIME, False, 1)
        self.assertEqual(raised.exception.code, "DELETE_NOT_VERIFIED")

    def test_changed_delete_target_is_refused(self) -> None:
        journal = self.journal()
        journal.save(phase="reviewed", runtime=RUNTIME)
        replacement = runtime_record(RUNTIME + "1")
        target = manager.Target(replacement["name"], "Example Assistant", "runtime", replacement)
        with patch.object(self.api, "resolve", return_value=target), self.assertRaises(manager.WorkflowError) as raised:
            manager.delete_agent(self.api, "Example Assistant", "runtime", journal, True, replacement["name"], False, 1)
        self.assertEqual(raised.exception.code, "TARGET_CHANGED")

    def test_operation_error_is_explicit(self) -> None:
        with patch.object(self.api, "request", return_value={"done": True, "error": {"message": "Build failed."}}):
            with self.assertRaises(manager.WorkflowError) as raised:
                self.api.wait_operation(OPERATION, 1)
        self.assertEqual(raised.exception.code, "OPERATION_FAILED")

    def test_get_retries_but_post_does_not(self) -> None:
        response = MagicMock()
        response.__enter__.return_value = response
        response.status_code = 503
        response.headers = {"content-type": "application/json"}
        response.json.return_value = {"error": {"message": "Temporarily unavailable."}}
        with patch.object(self.api.http, "request", return_value=response) as request, patch.object(manager.time, "sleep"):
            with self.assertRaises(manager.WorkflowError):
                self.api.request("GET", "https://example.googleapis.com/v1/resource")
            self.assertEqual(request.call_count, 3)
            request.reset_mock()
            with self.assertRaises(manager.WorkflowError):
                self.api.request("POST", "https://example.googleapis.com/v1/resource")
            self.assertEqual(request.call_count, 1)

    def test_thoughts_and_partial_events_are_not_replies(self) -> None:
        self.assertEqual(manager.event_text({"partial": True, "content": {"parts": [{"text": "partial"}]}}), "")
        self.assertEqual(manager.event_text({"output": {"content": {"parts": [
            {"text": "private reasoning", "thought": True}, {"text": "Public answer."},
        ]}}}), "Public answer.")


class TransportTests(WorkflowTestBase):
    def test_a2a_batch_reuses_real_runner_and_one_registry_client(self) -> None:
        from google.adk.agents import BaseAgent
        from google.adk.agents.invocation_context import InvocationContext
        from google.adk.events import Event
        from google.genai import types

        calls: list[tuple[str, str]] = []
        registry_calls: list[str] = []

        class FakeAgent(BaseAgent):
            async def _run_async_impl(
                self, ctx: InvocationContext
            ) -> AsyncGenerator[Event, None]:
                calls.append((ctx.session.id, ctx.user_content.parts[0].text))
                yield Event(
                    author=self.name,
                    content=types.Content(
                        role="model", parts=[types.Part(text="I can explain my capabilities.")]
                    ),
                )

        class Registry:
            def __init__(inner, *, project_id: str, location: str) -> None:
                self.assertEqual((project_id, location), (self.scope.project, self.scope.location))
                registry_calls.append("initialize")

            def get_remote_a2a_agent(inner, name: str, *, httpx_client: httpx.AsyncClient):
                self.assertEqual(name, REGISTRY)
                registry_calls.append("resolve")
                return FakeAgent(name="example_remote")

        record = registry_record()
        record["protocols"] = [{"type": "A2A_AGENT"}]
        target = manager.Target(REGISTRY, "Example Assistant", "registry", record)
        runtime = manager.Target(RUNTIME, "Example Assistant", "runtime", runtime_record())
        with (
            patch.object(self.api, "managed_runtime", return_value=runtime),
            patch("google.adk.integrations.agent_registry.AgentRegistry", Registry),
        ):
            result = asyncio.run(manager.send_batch(
                self.api, target, manager.build_prompts(2, None), self.journal(), 5, "capabilities"
            ))
        self.assertEqual((result["sent"], result["passed"]), (2, 2))
        self.assertEqual(registry_calls, ["initialize", "resolve"])
        self.assertEqual([prompt for _, prompt in calls], [manager.DEFAULT_PROMPT] * 2)
        self.assertEqual(calls[0][0], calls[1][0])

    def test_native_batch_sends_exact_count_in_one_conversation(self) -> None:
        requests_seen: list[httpx.Request] = []
        original_client = httpx.AsyncClient

        def handler(request: httpx.Request) -> httpx.Response:
            requests_seen.append(request)
            body = json.loads(request.content)
            if request.url.path.endswith(":query"):
                self.assertEqual(body["classMethod"], "async_create_session")
                return httpx.Response(200, json={"output": {"id": "example-session"}})
            self.assertEqual(body["input"]["session_id"], "example-session")
            self.assertEqual(body["input"]["message"], manager.DEFAULT_PROMPT)
            return httpx.Response(200, headers={"content-type": "text/event-stream"}, text=(
                'event: message\n'
                'data: {"output":{"partial":true,"content":{"parts":[{"text":"partial"}]}}}\n\n'
                'data: {"output":{"content":{"parts":[{"text":"Example answer."}]}}}\n\n'
                'data: [DONE]\n\n'
            ))

        def client_factory(**kwargs: object) -> httpx.AsyncClient:
            return original_client(transport=httpx.MockTransport(handler), **kwargs)

        target = manager.Target(RUNTIME, "Example Assistant", "runtime", runtime_record())
        journal = self.journal()
        with patch.object(manager.httpx, "AsyncClient", side_effect=client_factory):
            result = asyncio.run(manager.send_batch(
                self.api, target, manager.build_prompts(3, None), journal, 5, "answer"
            ))
        self.assertEqual((result["sent"], result["passed"]), (3, 3))
        self.assertEqual(len(requests_seen), 4)
        self.assertTrue(all(request.headers["Authorization"] == "Bearer example-test-token" for request in requests_seen))
        self.assertEqual(len(journal.state["responses"]), 3)
        self.assertEqual(journal.state["responses"][0]["response"], "Example answer.")
        with patch.object(manager, "conversation") as conversation:
            repeated = asyncio.run(manager.send_batch(self.api, target, [manager.DEFAULT_PROMPT] * 3, journal, 5, "answer"))
        self.assertEqual(repeated, result)
        conversation.assert_not_called()

    def test_credentials_cannot_be_sent_to_an_external_agent_url(self) -> None:
        async def probe() -> None:
            with patch.object(self.api.credentials, "before_request") as before:
                async with httpx.AsyncClient(
                    auth=manager.ScopedGoogleAuth(self.api, RUNTIME),
                    transport=httpx.MockTransport(lambda request: self.fail("Untrusted request reached transport.")),
                ) as client:
                    with self.assertRaises(manager.WorkflowError):
                        await client.get("https://example.com/agent-card")
                before.assert_not_called()
        asyncio.run(probe())

    def test_credentials_cannot_be_sent_to_a_different_runtime(self) -> None:
        async def probe() -> None:
            auth = manager.ScopedGoogleAuth(self.api, RUNTIME)
            request = httpx.Request("GET", f"{self.scope.runtime_url}/{RUNTIME}1/a2a/v1/card")
            with self.assertRaises(manager.WorkflowError):
                await anext(auth.async_auth_flow(request))
        asyncio.run(probe())

    def test_interrupted_batch_is_not_replayed(self) -> None:
        journal = self.journal()
        journal.save(phase="sending", in_flight=1)
        target = manager.Target(RUNTIME, "Example Assistant", "runtime", runtime_record())
        with patch.object(manager, "conversation") as conversation, self.assertRaises(manager.WorkflowError) as raised:
            asyncio.run(manager.send_batch(self.api, target, [manager.DEFAULT_PROMPT], journal, 5, None))
        self.assertEqual(raised.exception.code, "UNCERTAIN_PROMPT_BATCH")
        conversation.assert_not_called()

    def test_empty_response_is_an_error(self) -> None:
        @manager.asynccontextmanager
        async def empty_conversation(*args: object, **kwargs: object):
            async def send(prompt: str) -> str:
                return ""
            yield send
        target = manager.Target(RUNTIME, "Example Assistant", "runtime", runtime_record())
        with patch.object(manager, "conversation", empty_conversation), self.assertRaises(manager.WorkflowError) as raised:
            asyncio.run(manager.send_batch(self.api, target, ["Hello."], self.journal(), 5, None))
        self.assertEqual(raised.exception.code, "EMPTY_RESPONSE")

    def test_failed_expected_text_is_not_success(self) -> None:
        @manager.asynccontextmanager
        async def sample_conversation(*args: object, **kwargs: object):
            async def send(prompt: str) -> str:
                return "Example answer."
            yield send
        target = manager.Target(RUNTIME, "Example Assistant", "runtime", runtime_record())
        with patch.object(manager, "conversation", sample_conversation):
            result = asyncio.run(manager.send_batch(self.api, target, ["Hello."], self.journal(), 5, "missing"))
        self.assertEqual(result["status"], "test_failed")
        self.assertEqual(result["passed"], 0)


class CustomizationTests(unittest.TestCase):
    def test_frontmatter_names_and_skill_links(self) -> None:
        root = manager.REPO_ROOT / ".github"
        files = [root / "agents" / "google-ai-manager.agent.md"] + [
            root / "skills" / name / "SKILL.md"
            for name in ("google-ai-agent-test-prompts", "google-ai-agent-create", "google-ai-agent-delete")
        ]
        for path in files:
            with self.subTest(path=path):
                text = path.read_text(encoding="utf-8")
                self.assertTrue(text.startswith("---\n"))
                metadata = yaml.safe_load(text.split("---", 2)[1])
                self.assertTrue(metadata["description"])
                if path.name == "SKILL.md":
                    self.assertEqual(metadata["name"], path.parent.name)
                    self.assertLessEqual(len(metadata["description"]), 1024)
                else:
                    self.assertEqual(metadata["name"], "Google AI Manager")
                self.assertLess(len(text.splitlines()), 150)
                for target in re.findall(r"\[[^\]]+\]\(([^)]+)\)", text):
                    if not target.startswith(("https://", "http://", "#")):
                        self.assertTrue(
                            (path.parent / target.split("#", 1)[0]).resolve().exists(),
                            f"Missing relative link in {path.name}: {target}",
                        )

    def test_private_paths_are_ignored_and_examples_remain_publishable(self) -> None:
        paths = [
            ".google-ai-private/target.json",
            ".google-ai-private/replies.json",
            "google-ai-runs/example/state.json",
            "google-ai.local.json",
            "application_default_credentials.json",
            "google-credentials-example.json",
            "service-account-example.json",
            "service_account_example.json",
            "example.credentials.json",
            "gcloud-config/credentials.db",
            ".config/gcloud/access_tokens.db",
        ]
        for path in paths:
            with self.subTest(path=path):
                result = subprocess.run(
                    ["git", "check-ignore", "--no-index", "--quiet", path],
                    cwd=manager.REPO_ROOT, check=False,
                )
                self.assertEqual(result.returncode, 0)
        for path in (
            manager.CREATE_ASSETS / "agent.example.json",
            manager.CREATE_ASSETS / "agent.py",
            SCRIPTS.parent / "assets" / "target.example.json",
        ):
            result = subprocess.run(
                ["git", "check-ignore", "--no-index", "--quiet", str(path)],
                cwd=manager.REPO_ROOT, check=False,
            )
            self.assertEqual(result.returncode, 1)


if __name__ == "__main__":
    unittest.main()
