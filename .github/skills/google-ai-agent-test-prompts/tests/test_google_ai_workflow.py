from __future__ import annotations

import asyncio
from contextlib import ExitStack, redirect_stderr, redirect_stdout
from io import StringIO
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

from test_google_ai_agents import (
    FakeCredentials, REGISTRY, RUNTIME, WorkflowTestBase, manager, registry_record,
    runtime_record,
)
import google_ai_environment as environment


AGENT_URL = (
    "https://console.cloud.google.com/agent-platform/agent-registry/agents/"
    "europe-west1/example-agent/overview?project=example-project&cloudshell=true"
)


class MinimalInputTests(WorkflowTestBase):
    def arguments(self, *values: str):
        return manager.parser().parse_args([
            "send", "--credentials-file", str(self.scope.credentials_file), *values,
        ])

    def test_one_console_url_supplies_project_location_and_registry_id(self) -> None:
        scope, selector, kind = manager.load_inputs(self.arguments("--agent-url", AGENT_URL))
        self.assertEqual((scope.project, scope.location, kind), ("example-project", "europe-west1", "registry"))
        self.assertEqual(selector, REGISTRY.replace("123456789012", "example-project"))

    def test_agent_url_without_overview_is_supported(self) -> None:
        first = manager.console_url_inputs(AGENT_URL)
        second = manager.console_url_inputs(AGENT_URL.replace("/overview?", "?"))
        self.assertEqual(first, second)

    def test_full_resource_also_supplies_scope_without_extra_questions(self) -> None:
        scope, selector, kind = manager.load_inputs(self.arguments("--agent", RUNTIME))
        self.assertEqual((scope.project, scope.location), ("123456789012", "europe-west1"))
        self.assertEqual((selector, kind), (RUNTIME, "runtime"))

    def test_project_url_only_needs_a_missing_region(self) -> None:
        args = self.arguments(
            "--project-url", "https://console.cloud.google.com/home/dashboard?project=example-project",
            "--location", "europe-west1", "--agent", "Example Assistant",
        )
        scope, _, _ = manager.load_inputs(args)
        self.assertEqual(scope.project, "example-project")
        args.location = None
        with self.assertRaises(manager.WorkflowError):
            manager.load_inputs(args)

    def test_private_configuration_can_contain_only_url_and_credentials(self) -> None:
        config = self.directory / "target.json"
        config.write_text(json.dumps({
            "agent_url": AGENT_URL, "credentials_file": "example.credentials.json",
        }), encoding="utf-8")
        scope, selector, _ = manager.load_inputs(
            manager.parser().parse_args(["send", "--config", str(config)])
        )
        self.assertEqual(scope.credentials_file, self.scope.credentials_file)
        self.assertTrue(selector.endswith("/example-agent"))

    def test_project_scope_url_does_not_replace_an_explicit_agent(self) -> None:
        _, selector, _ = manager.load_inputs(self.arguments(
            "--project-url", AGENT_URL, "--agent", "Another Assistant",
        ))
        self.assertEqual(selector, "Another Assistant")

    def test_creation_uses_an_existing_agent_url_only_for_scope(self) -> None:
        args = manager.parser().parse_args([
            "create", "--project-url", AGENT_URL,
            "--credentials-file", str(self.scope.credentials_file),
            "--spec", str(self.directory / "agent.json"),
        ])
        scope, selector, _ = manager.load_inputs(args)
        self.assertEqual((scope.project, scope.location), ("example-project", "europe-west1"))
        self.assertIsNone(selector)

    def test_full_resource_cannot_override_a_conflicting_project_url(self) -> None:
        with self.assertRaises(manager.WorkflowError):
            manager.load_inputs(self.arguments(
                "--project-url", AGENT_URL,
                "--agent", "projects/different-project/locations/europe-west1/agents/example-agent",
            ))

    def test_conflicting_scope_is_rejected_before_authentication(self) -> None:
        for extra in (
            ["--project", "different-project"],
            ["--location", "us-central1"],
            ["--project-url", "https://console.cloud.google.com/home/dashboard?project=different-project"],
        ):
            with self.subTest(extra=extra), self.assertRaises(manager.WorkflowError):
                manager.load_inputs(self.arguments("--agent-url", AGENT_URL, *extra))

    def test_untrusted_or_ambiguous_console_urls_are_rejected(self) -> None:
        for url in (
            AGENT_URL.replace("https://", "http://"),
            AGENT_URL.replace("console.cloud.google.com", "example.com"),
            AGENT_URL.replace("console.cloud.google.com", "console.cloud.google.com.example.com"),
            AGENT_URL.replace("console.cloud.google.com", "user@console.cloud.google.com"),
            AGENT_URL + "&project=another-project",
            "https://console.cloud.google.com/home/dashboard?project=example-project",
        ):
            with self.subTest(url=url), self.assertRaises(manager.WorkflowError):
                manager.console_url_inputs(url, require_agent=True)

    def test_internal_identifier_is_derived_deterministically(self) -> None:
        spec = self.spec()
        spec.pop("agent_name")
        first = manager.validate_spec(spec)
        second = manager.validate_spec(spec)
        self.assertEqual(first["agent_name"], "example_assistant")
        self.assertEqual(first, second)
        self.assertEqual(manager.validate_spec({**spec, "display_name": "3 assistants"})["agent_name"], "agent_3_assistants")
        self.assertEqual(manager.validate_spec({**spec, "display_name": "class"})["agent_name"], "agent_class")

    def test_explicit_file_cannot_select_the_shared_default_adc_store(self) -> None:
        with patch.dict(os.environ, {"APPDATA": str(self.directory)}):
            shared = self.directory / "gcloud" / "application_default_credentials.json"
            args = manager.parser().parse_args([
                "send", "--agent-url", AGENT_URL, "--credentials-file", str(shared),
            ])
            with self.assertRaises(manager.WorkflowError) as raised:
                manager.load_inputs(args)
        self.assertEqual(raised.exception.code, "UNSAFE_AUTH_PATH")


class PrerequisiteTests(unittest.TestCase):
    def versions(self, name: str) -> str:
        return {
            "google-adk": "2.12.0", "google-auth": "2.62.0",
            "httpx": "0.28.1", "requests": "2.32.5",
        }.get(name, "0.1.0")

    def test_missing_dependencies_are_reported_without_installing_or_logging_in(self) -> None:
        with (
            patch.object(environment, "installed_version", return_value=None),
            patch.object(environment, "find_gcloud", return_value=None),
            patch.object(environment, "find_edge", return_value=None),
            patch.object(environment.subprocess, "run") as run,
            patch.object(environment.runpy, "run_path") as login,
        ):
            result = environment.environment_report("browser")
        self.assertEqual(result["status"], "installation_required")
        self.assertIn("google-adk", result["missing"])
        self.assertIn("Google Cloud CLI (Google Cloud SDK)", result["missing"])
        run.assert_not_called()
        login.assert_not_called()

    def test_file_mode_does_not_require_browser_toolkits(self) -> None:
        with (
            patch.object(environment, "installed_version", side_effect=self.versions),
            patch.object(environment, "find_gcloud", return_value=None),
            patch.object(environment, "find_edge", return_value=None),
        ):
            result = environment.environment_report("file")
        self.assertEqual(result["status"], "ready")
        self.assertEqual(result["missing"], [])
        self.assertIn("Microsoft Edge", result["browser_additional_missing"])

    def test_incompatible_package_versions_require_setup(self) -> None:
        def versions(name: str) -> str:
            return "3.0.0" if name == "google-auth" else self.versions(name)
        with (
            patch.object(environment, "installed_version", side_effect=versions),
            patch.object(environment, "find_gcloud", return_value=None),
            patch.object(environment, "find_edge", return_value=None),
        ):
            result = environment.environment_report("file")
        self.assertEqual(result["status"], "installation_required")
        self.assertIn("google-auth: incompatible installed version", result["missing"])

    def test_powershell_wrapper_reports_a_missing_python_without_running_it(self) -> None:
        shell = shutil.which("pwsh")
        if shell is None:
            self.skipTest("PowerShell is unavailable on this test host.")
        script = Path(environment.__file__).with_name("Test-GoogleAiEnvironment.ps1")
        result = subprocess.run(
            [shell, "-NoProfile", "-File", str(script), "-PythonPath", str(script.with_name("missing-python.exe"))],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "installation_required")

    def test_checker_runs_without_any_site_packages(self) -> None:
        result = subprocess.run(
            [sys.executable, "-S", environment.__file__, "check", "--auth-mode", "file"],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["status"], "installation_required")
        self.assertIn("google-adk", report["missing"])
        self.assertNotIn("Traceback", result.stderr)

    def test_powershell_wrapper_reports_old_python_before_loading_the_helper(self) -> None:
        shell = shutil.which("pwsh")
        if shell is None:
            self.skipTest("PowerShell is unavailable on this test host.")
        with tempfile.TemporaryDirectory(prefix="google-ai-old-python-") as directory:
            fake = Path(directory) / "old-python.ps1"
            called = Path(directory) / "calls.txt"
            escaped_path = str(called).replace("'", "''")
            fake.write_text(
                "param([string]$c)\n"
                f"Add-Content -LiteralPath '{escaped_path}' -Value 'called'\n"
                "'{\"major\":3,\"minor\":8}'\nexit 0\n",
                encoding="utf-8",
            )
            result = subprocess.run(
                [shell, "-NoProfile", "-File", str(Path(environment.__file__).with_name("Test-GoogleAiEnvironment.ps1")), "-PythonPath", str(fake)],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(report["status"], "installation_required")
            self.assertIn("3.8", report["missing"][0])
            self.assertEqual(called.read_text(encoding="utf-8").splitlines(), ["called"])


class BrowserAuthenticationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="google-ai-browser-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.auth_dir = self.directory / "private-auth"
        self.gcloud = self.directory / "sdk" / "bin" / "gcloud.cmd"
        self.gcloud.parent.mkdir(parents=True)
        self.gcloud.write_text("", encoding="utf-8")
        launcher = self.directory / "sdk" / "lib" / "gcloud.py"
        launcher.parent.mkdir()
        launcher.write_text("", encoding="utf-8")
        self.edge = self.directory / "msedge.exe"
        self.edge.write_text("", encoding="utf-8")
        self.local = self.directory / "local"
        (self.local / "Microsoft" / "Edge" / "User Data" / "Default").mkdir(parents=True)
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.dict(os.environ, {
            "LOCALAPPDATA": str(self.local),
            "CLOUDSDK_CONFIG": str(self.directory / "shared-do-not-touch"),
            "GOOGLE_APPLICATION_CREDENTIALS": str(self.directory / "shared-do-not-read.json"),
        }))
        self.stack.enter_context(patch.object(sys, "argv", list(sys.argv)))
        self.stack.enter_context(patch.object(sys, "path", list(sys.path)))
        self.stack.enter_context(patch.object(environment.webbrowser, "open"))
        self.stack.enter_context(patch.object(environment.webbrowser, "register"))
        self.browser = MagicMock()
        self.browser.open.return_value = True
        self.controller = self.stack.enter_context(
            patch.object(environment.webbrowser, "BackgroundBrowser", return_value=self.browser)
        )
        self.stack.enter_context(patch.object(environment, "environment_report", return_value={
            "status": "ready", "gcloud_path": str(self.gcloud), "edge_path": str(self.edge),
        }))

    def write_credentials(self, *, quota: bool = True) -> None:
        value = {
            "type": "authorized_user", "client_id": "example-client",
            "client_secret": "not-a-real-client-secret",
            "refresh_token": "not-a-real-refresh-token",
        }
        if quota:
            value["quota_project_id"] = "example-project"
        (self.auth_dir / "application_default_credentials.json").write_text(
            json.dumps(value), encoding="utf-8"
        )

    def test_browser_uses_only_approved_edge_profile_and_isolated_credentials(self) -> None:
        def login(*args: object, **kwargs: object) -> None:
            self.assertEqual(os.environ["CLOUDSDK_CONFIG"], str(self.auth_dir))
            self.assertNotIn("GOOGLE_APPLICATION_CREDENTIALS", os.environ)
            self.assertIn("--launch-browser", sys.argv)
            self.assertNotIn("--use-device-code", sys.argv)
            environment.webbrowser.open("https://accounts.google.com/o/oauth2/auth")
            self.write_credentials()
        with patch.object(environment.runpy, "run_path", side_effect=login):
            result = environment.browser_authenticate("example-project", self.auth_dir, "Default")
        self.assertEqual(result["status"], "authenticated")
        self.controller.assert_called_once_with([str(self.edge), "--profile-directory=Default", "%s"])
        self.browser.open.assert_called_once()
        self.assertEqual(result["credentials_file"], str(self.auth_dir / "application_default_credentials.json"))
        self.assertFalse((self.directory / "shared-do-not-touch").exists())

    def test_browser_generated_file_is_accepted_by_every_action(self) -> None:
        with patch.object(environment.runpy, "run_path", side_effect=lambda *a, **k: self.write_credentials()):
            result = environment.browser_authenticate("example-project", self.auth_dir, "Default")
        spec = self.directory / "agent.json"
        spec.write_text("{}", encoding="utf-8")
        for action in ("discover", "send", "create", "delete"):
            arguments = [
                action, "--agent-url", AGENT_URL,
                "--credentials-file", result["credentials_file"],
            ]
            if action == "create":
                arguments += ["--spec", str(spec)]
            scope, _, _ = manager.load_inputs(manager.parser().parse_args(arguments))
            credentials = manager.configure_authentication(scope, self.directory / action)
            self.assertEqual(credentials.quota_project_id, "example-project")
            self.assertEqual(scope.credentials_file, Path(result["credentials_file"]))

    def test_existing_authentication_directory_is_not_overwritten(self) -> None:
        self.auth_dir.mkdir()
        self.write_credentials()
        before = (self.auth_dir / "application_default_credentials.json").read_bytes()
        with patch.object(environment.runpy, "run_path") as login, self.assertRaises(environment.WorkflowError) as raised:
            environment.browser_authenticate("example-project", self.auth_dir, "Default")
        self.assertEqual(raised.exception.code, "AUTH_DIRECTORY_IN_USE")
        self.assertEqual((self.auth_dir / "application_default_credentials.json").read_bytes(), before)
        login.assert_not_called()

    def test_missing_profile_does_not_fall_back_to_default_or_temporary_browser(self) -> None:
        with patch.object(environment.runpy, "run_path") as login, self.assertRaises(environment.WorkflowError) as raised:
            environment.browser_authenticate("example-project", self.auth_dir, "Unknown Profile")
        self.assertEqual(raised.exception.code, "MISSING_EDGE_PROFILE")
        login.assert_not_called()

    def test_existing_cache_without_an_adc_file_is_not_reused(self) -> None:
        self.auth_dir.mkdir()
        (self.auth_dir / "credentials.db").write_text("Example existing store.", encoding="utf-8")
        with patch.object(environment.runpy, "run_path") as login, self.assertRaises(environment.WorkflowError) as raised:
            environment.browser_authenticate("example-project", self.auth_dir, "Default")
        self.assertEqual(raised.exception.code, "AUTH_DIRECTORY_IN_USE")
        login.assert_not_called()

    def test_shared_default_directory_is_rejected_even_when_absent(self) -> None:
        with (
            patch.dict(os.environ, {"APPDATA": str(self.directory / "roaming")}),
            patch.object(environment.runpy, "run_path") as login,
            self.assertRaises(environment.WorkflowError) as raised,
        ):
            environment.browser_authenticate(
                "example-project", self.directory / "roaming" / "gcloud", "Default"
            )
        self.assertEqual(raised.exception.code, "UNSAFE_AUTH_PATH")
        login.assert_not_called()

    def test_failed_browser_login_has_no_device_code_fallback(self) -> None:
        with (
            patch.object(environment.runpy, "run_path", side_effect=SystemExit(1)) as login,
            self.assertRaises(environment.WorkflowError) as raised,
        ):
            environment.browser_authenticate("example-project", self.auth_dir, "Default")
        self.assertEqual(raised.exception.code, "BROWSER_AUTH_FAILED")
        self.assertEqual(login.call_count, 1)

    def test_edge_launch_failure_is_explicit(self) -> None:
        self.browser.open.return_value = False
        def login(*args: object, **kwargs: object) -> None:
            environment.webbrowser.open("https://accounts.google.com/o/oauth2/auth")
        with patch.object(environment.runpy, "run_path", side_effect=login), self.assertRaises(environment.WorkflowError) as raised:
            environment.browser_authenticate("example-project", self.auth_dir, "Default")
        self.assertEqual(raised.exception.code, "BROWSER_FAILED")

    def test_quota_project_is_set_only_under_the_isolated_context(self) -> None:
        def quota(*args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
            self.assertEqual(os.environ["CLOUDSDK_CONFIG"], str(self.auth_dir))
            self.assertIn("set-quota-project", args[0])
            self.write_credentials()
            return subprocess.CompletedProcess(args[0], 0, "", "")
        with (
            patch.object(environment.runpy, "run_path", side_effect=lambda *a, **k: self.write_credentials(quota=False)),
            patch.object(environment.subprocess, "run", side_effect=quota) as run,
        ):
            result = environment.browser_authenticate("example-project", self.auth_dir, "Default")
        self.assertEqual(result["status"], "authenticated")
        run.assert_called_once()

    def test_quota_authorization_failure_does_not_change_authentication_mode(self) -> None:
        with (
            patch.object(environment.runpy, "run_path", side_effect=lambda *a, **k: self.write_credentials(quota=False)) as login,
            patch.object(environment.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "Example permission denial.")),
            self.assertRaises(environment.WorkflowError) as raised,
        ):
            environment.browser_authenticate("example-project", self.auth_dir, "Default")
        self.assertEqual(raised.exception.code, "QUOTA_PROJECT_FAILED")
        self.assertEqual(raised.exception.details["auth_dir"], str(self.auth_dir))
        self.assertEqual(login.call_count, 1)


class ExplicitReplyTests(WorkflowTestBase):
    def test_auto_transport_prefers_native_even_when_registry_advertises_a2a(self) -> None:
        record = registry_record()
        record["protocols"] = [{"type": "A2A_AGENT"}]
        target = manager.Target(REGISTRY, "Example Assistant", "registry", record)
        runtime = manager.Target(RUNTIME, "Example Assistant", "runtime", runtime_record())
        self.assertEqual(manager.select_transport(target, runtime, "auto"), "native")
        self.assertEqual(manager.select_transport(target, runtime, "a2a"), "a2a")
        without_native = manager.Target(RUNTIME, "Example Assistant", "runtime", {"spec": {}})
        self.assertEqual(manager.select_transport(target, without_native, "auto"), "a2a")
        with self.assertRaises(manager.WorkflowError):
            manager.select_transport(target, without_native, "native")

    def test_full_repeated_answers_are_in_success_and_cached_results(self) -> None:
        answer = "A complete answer. " * 400
        @manager.asynccontextmanager
        async def replies(*args: object, **kwargs: object):
            async def send(prompt: str) -> str:
                return answer
            yield send
        target = manager.Target(RUNTIME, "Example Assistant", "runtime", runtime_record())
        journal = self.journal()
        with patch.object(manager, "conversation", replies):
            result = asyncio.run(manager.send_batch(self.api, target, ["Hello."] * 2, journal, 5, None))
        self.assertEqual([item["response"] for item in result["responses"]], [answer, answer])
        repeated = asyncio.run(manager.send_batch(self.api, target, ["Hello."] * 2, journal, 5, None))
        self.assertEqual(repeated["responses"], result["responses"])
        with (
            patch.object(sys, "argv", ["google_ai_agents.py", "send"]),
            patch.object(manager, "execute", return_value=result),
            redirect_stdout(StringIO()) as output,
        ):
            self.assertEqual(manager.main(), 0)
        self.assertEqual(json.loads(output.getvalue())["responses"][1]["response"], answer)

    def test_partial_failure_includes_every_answer_already_received(self) -> None:
        @manager.asynccontextmanager
        async def replies(*args: object, **kwargs: object):
            calls = 0
            async def send(prompt: str) -> str:
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise manager.WorkflowError("EXAMPLE_FAILURE", "The second prompt failed.")
                return "The complete first answer."
            yield send
        target = manager.Target(RUNTIME, "Example Assistant", "runtime", runtime_record())
        arguments = [
            "google_ai_agents.py", "send", "--agent-url", AGENT_URL,
            "--credentials-file", str(self.scope.credentials_file),
            "--count", "2", "--run-dir", str(self.directory / "partial"),
        ]
        with (
            patch.object(sys, "argv", arguments),
            patch.object(manager, "configure_authentication", return_value=FakeCredentials()),
            patch.object(manager, "GoogleApi", return_value=self.api),
            patch.object(self.api, "resolve", return_value=target),
            patch.object(manager, "conversation", replies),
            redirect_stderr(StringIO()) as errors,
        ):
            self.assertEqual(manager.main(), 2)
        result = json.loads(errors.getvalue().splitlines()[-1])
        self.assertEqual(result["in_flight"], 2)
        self.assertEqual(result["display_name"], "Example Assistant")
        self.assertEqual(result["responses"][0]["response"], "The complete first answer.")
        self.assertEqual(len(result["responses"]), 1)


class DurableStateTests(WorkflowTestBase):
    def blocked(self) -> PermissionError:
        error = PermissionError("Example Windows file contention.")
        error.winerror = 5
        return error

    def test_transient_windows_contention_retries_only_the_local_replace(self) -> None:
        path = self.directory / "state.json"
        manager.atomic_write(path, {"previous": True})
        original = Path.replace
        attempts = 0
        def replace(source: Path, target: Path) -> Path:
            nonlocal attempts
            attempts += 1
            if attempts < 3:
                raise self.blocked()
            return original(source, target)
        with (
            patch.object(Path, "replace", autospec=True, side_effect=replace),
            patch.object(manager.time, "sleep") as sleep,
            self.assertLogs(manager.__name__, level="WARNING") as logs,
        ):
            manager.atomic_write(path, {"complete": True})
        self.assertEqual(json.loads(path.read_text(encoding="utf-8")), {"complete": True})
        self.assertEqual(attempts, 3)
        self.assertEqual(sleep.call_count, 2)
        self.assertEqual(len(logs.records), 2)

    def test_persistent_windows_contention_fails_after_five_attempts(self) -> None:
        path = self.directory / "state.json"
        manager.atomic_write(path, {"previous": True})
        with (
            patch.object(Path, "replace", side_effect=self.blocked()) as replace,
            patch.object(manager.time, "sleep") as sleep,
            self.assertLogs(manager.__name__, level="WARNING"),
            self.assertRaises(PermissionError),
        ):
            manager.atomic_write(path, {"must_not_appear": True})
        self.assertEqual(replace.call_count, 5)
        self.assertEqual(sleep.call_count, 4)
        self.assertLessEqual(sum(call.args[0] for call in sleep.call_args_list), 0.75)
        self.assertEqual(json.loads(path.read_text(encoding="utf-8")), {"previous": True})
        self.assertEqual(list(self.directory.glob("*.tmp")), [])

    def test_other_permission_errors_are_not_retried(self) -> None:
        path = self.directory / "state.json"
        with (
            patch.object(Path, "replace", side_effect=PermissionError("Example permanent permission denial.")) as replace,
            patch.object(manager.time, "sleep") as sleep,
            self.assertRaises(PermissionError),
        ):
            manager.atomic_write(path, {"complete": False})
        self.assertEqual(replace.call_count, 1)
        sleep.assert_not_called()


class GuidanceContractTests(unittest.TestCase):
    def test_manager_requires_the_same_order_for_all_skills(self) -> None:
        path = manager.REPO_ROOT / ".github" / "agents" / "google-ai-manager.agent.md"
        text = path.read_text(encoding="utf-8")
        headings = (
            "Check the computer first.", "Guide before asking.", "Ask for the minimum.",
            "Ask the authentication mode explicitly.", "Execute the selected skill.",
            "Show every received answer.",
        )
        positions = [text.index(heading) for heading in headings]
        self.assertEqual(positions, sorted(positions))
        for name in ("google-ai-agent-create", "google-ai-agent-delete", "google-ai-agent-test-prompts"):
            skill = manager.REPO_ROOT / ".github" / "skills" / name / "SKILL.md"
            body = skill.read_text(encoding="utf-8")
            self.assertIn("operator-guide.md", body)
            self.assertIn("isolated Edge", body)

    def test_guide_covers_minimal_console_input_and_complete_replies(self) -> None:
        path = Path(environment.__file__).parents[1] / "references" / "operator-guide.md"
        text = path.read_text(encoding="utf-8")
        for required in (
            "Ctrl+L", "one URL per agent", "IAM & Admin > Service Accounts",
            "Model Garden", "auth-browser", "returned", "complete received answer",
            "including identical repeated answers", "Do not switch authentication methods",
        ):
            self.assertIn(required, text)


if __name__ == "__main__":
    unittest.main()
