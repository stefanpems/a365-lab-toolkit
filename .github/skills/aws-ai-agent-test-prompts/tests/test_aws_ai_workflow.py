from __future__ import annotations

import argparse
import asyncio
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import MagicMock, patch
import zipfile


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
import aws_ai_agents as agents
import aws_ai_environment as environment


ROOT = SCRIPTS.parents[3]
SKILLS = SCRIPTS.parents[1]


class EnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name)

    def test_isolation_removes_all_inherited_aws_providers_and_endpoints(self):
        inherited = {
            "AWS_ACCESS_KEY_ID": "do-not-use", "AWS_SECRET_ACCESS_KEY": "do-not-use",
            "AWS_SESSION_TOKEN": "do-not-use", "AWS_WEB_IDENTITY_TOKEN_FILE": "shared",
            "AWS_CONTAINER_CREDENTIALS_FULL_URI": "http://example.test/credentials",
            "AWS_ENDPOINT_URL": "https://example.test", "AWS_PROFILE": "shared",
            "AWS_CONFIG_FILE": "shared-config",
        }
        with patch.dict(os.environ, inherited):
            isolated = environment.isolated_environment(self.path, "eu-north-1")
        for key in inherited:
            if key not in {"AWS_PROFILE", "AWS_CONFIG_FILE"}:
                self.assertNotIn(key, isolated)
        self.assertEqual(isolated["AWS_PROFILE"], "aws-ai-manager")
        for key in ("AWS_CONFIG_FILE", "AWS_SHARED_CREDENTIALS_FILE", "AWS_LOGIN_CACHE_DIRECTORY"):
            self.assertTrue(Path(isolated[key]).is_relative_to(self.path))
        self.assertEqual(isolated["AWS_EC2_METADATA_DISABLED"], "true")
        self.assertEqual(isolated["AWS_PAGER"], "")

    def test_process_environment_is_restored_even_on_failure(self):
        original = os.environ.copy()
        with self.assertRaises(RuntimeError):
            with environment.process_environment({"ONLY_PRIVATE": "yes"}):
                self.assertEqual(dict(os.environ), {"ONLY_PRIVATE": "yes"})
                raise RuntimeError("test")
        self.assertEqual(dict(os.environ), original)

    def credentials_file(self, extra=""):
        path = self.path / "temporary.ini"
        path.write_text(
            "[aws-ai-manager]\naws_access_key_id = temporary\n"
            "aws_secret_access_key = temporary-secret\naws_session_token = temporary-token\n" + extra,
            encoding="utf-8",
        )
        return path

    def test_file_auth_requires_temporary_credentials_and_expiration(self):
        expiry = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
        path = self.credentials_file(f"expiration = {expiry}\n")
        credentials = environment.dedicated_credentials(path, "aws-ai-manager")
        self.assertEqual(set(credentials), {"aws_access_key_id", "aws_secret_access_key", "aws_session_token"})
        path.write_text("[aws-ai-manager]\naws_access_key_id=x\naws_secret_access_key=y\n")
        with self.assertRaisesRegex(ValueError, "session token"):
            environment.dedicated_credentials(path, "aws-ai-manager")

    def test_file_auth_rejects_credential_process_and_expired_tokens(self):
        for extra in ("credential_process = unwanted-command\n", "expiration = 2000-01-01T00:00:00Z\n"):
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                environment.dedicated_credentials(self.credentials_file(extra), "aws-ai-manager")

    def test_file_auth_rejects_shared_default_store_without_reading_it(self):
        fake_home = self.path / "home"
        shared = fake_home / ".aws"
        shared.mkdir(parents=True)
        path = shared / "credentials"
        path.touch()
        with patch.object(Path, "home", return_value=fake_home), patch.object(Path, "read_text") as read:
            with self.assertRaisesRegex(ValueError, "dedicated"):
                environment.dedicated_credentials(path, "aws-ai-manager")
        read.assert_not_called()

    def test_private_storage_rejects_repository_home_and_unowned_directory(self):
        for path in (ROOT / "private", Path.home(), self.path):
            if path == self.path:
                (path / "unrelated.txt").touch()
            with self.subTest(path=path), self.assertRaises(ValueError):
                environment.private_directory(path)

    def test_browser_uses_explicit_edge_profile_and_isolated_cache(self):
        private = self.path / "authentication"
        private.mkdir()
        runner = MagicMock()
        with (
            patch.object(environment, "private_directory", return_value=private),
            patch.object(environment.shutil, "which", return_value=r"C:\AWS\aws.exe"),
            patch.object(environment, "cli_version", return_value=(2, 32, 0)),
            patch.object(environment, "edge_profile", return_value=Path(r"C:\Edge\msedge.exe")),
            patch.object(environment.subprocess, "run", runner),
        ):
            result = environment.browser_authenticate(private, "eu-north-1", "Default", "operator@example.com")
        command = runner.call_args.args[0]
        self.assertIn("login", command)
        self.assertNotIn("--remote", command)
        self.assertNotIn("--use-device-code", command)
        child = runner.call_args.kwargs["env"]
        self.assertIn('--profile-directory="Default"', child["BROWSER"])
        self.assertEqual(child["AWS_LOGIN_CACHE_DIRECTORY"], str(private / "login-cache"))
        self.assertTrue(result["isolated"])

    def test_browser_failure_is_reported_without_fallback(self):
        private = self.path / "auth"
        private.mkdir()
        with (
            patch.object(environment, "private_directory", return_value=private),
            patch.object(environment.shutil, "which", return_value="aws"),
            patch.object(environment, "cli_version", return_value=(2, 32, 0)),
            patch.object(environment, "edge_profile", return_value=Path(r"C:\Edge\msedge.exe")),
            patch.object(environment.subprocess, "run", side_effect=subprocess.CalledProcessError(1, ["aws", "login"])) as run,
        ):
            with self.assertRaises(subprocess.CalledProcessError):
                environment.browser_authenticate(private, "eu-north-1", "Default", "operator@example.com")
        run.assert_called_once()
        self.assertFalse((private / "authentication.json").exists())

    def test_sdk_context_never_uses_default_credentials(self):
        args = argparse.Namespace(
            account_id="123456789012", region="eu-north-1", timeout=180,
            credentials_file="dedicated.ini", credentials_profile="aws-ai-manager",
        )
        credentials = {
            "aws_access_key_id": "temporary", "aws_secret_access_key": "temporary-secret",
            "aws_session_token": "temporary-token",
        }
        session = MagicMock()
        session.client.return_value.get_caller_identity.return_value = {
            "Account": args.account_id, "Arn": f"arn:aws:iam::{args.account_id}:user/operator",
        }
        with patch.object(agents, "load_credentials", return_value=credentials), patch("boto3.Session", return_value=session) as factory:
            context = agents.AwsContext(args, self.path)
        factory.assert_called_once_with(region_name=args.region, **credentials)
        self.assertEqual(context.config.retries["total_max_attempts"], 1)
        self.assertTrue(context.config.ignore_configured_endpoint_urls)


class SpecificationTests(unittest.TestCase):
    def write_spec(self, value):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        path = Path(temporary.name) / "spec.json"
        path.write_text(json.dumps(value))
        return str(path)

    def valid(self):
        return {
            "service": "agentcore", "name": "AwsAssistant", "model_id": "amazon.nova-micro-v1:0",
            "instructions": "You are a helpful assistant. Answer clearly and accurately.",
        }

    def test_classic_needs_explicit_existing_customer_acknowledgement(self):
        value = {**self.valid(), "service": "bedrock"}
        with self.assertRaisesRegex(ValueError, "closed to new"):
            agents.load_spec(self.write_spec(value), None)
        value["existing_classic_customer"] = True
        self.assertTrue(agents.load_spec(self.write_spec(value), None)["existing_classic_customer"])

    def test_invalid_names_types_unknown_fields_and_model_placeholder(self):
        for replacement in (
            {"name": "not-valid-for-agentcore"}, {"max_tokens": True},
            {"max_tokens": 0}, {"allow_cross_region": "true"}, {"unapproved": "field"},
            {"model_id": "REPLACE_WITH_MODEL"},
        ):
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                agents.load_spec(self.write_spec({**self.valid(), **replacement}), None)

    def test_optional_resource_fields_are_strings(self):
        for field in ("execution_role_arn", "artifact_bucket"):
            with self.subTest(field=field), self.assertRaises(ValueError):
                agents.load_spec(self.write_spec({**self.valid(), field: 42}), None)

    def test_changed_sources_are_bound_to_plan(self):
        hashes = agents.source_hashes()
        self.assertEqual(set(hashes), {"agent.py", "requirements.txt"})
        self.assertTrue(all(re.fullmatch(r"[a-f0-9]{64}", item) for item in hashes.values()))


class PackagingTests(unittest.TestCase):
    def test_package_is_allowlisted_arm64_and_preserves_no_credentials(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        directory = Path(temporary.name)
        run = types.SimpleNamespace(path=directory)
        (directory / "credentials").write_text("never upload this")

        def install(command, **kwargs):
            destination = Path(command[command.index("--target") + 1])
            destination.mkdir()
            (destination / "dependency.py").write_text("VALUE = 1\n")

        settings = {"model_id": "amazon.nova-micro-v1:0", "instructions": "Instructions", "max_tokens": 4096}
        with patch.object(agents.subprocess, "run", side_effect=install) as installer:
            package = agents.package_agent(run, settings)
            repeated = agents.package_agent(run, settings)
        self.assertEqual(repeated, package)
        installer.assert_called_once()
        command = installer.call_args.args[0]
        self.assertIn("manylinux2014_aarch64", command)
        self.assertIn("3.13", command)
        self.assertIn("--only-binary=:all:", command)
        with zipfile.ZipFile(package) as archive:
            self.assertEqual(set(archive.namelist()), {"dependency.py", "agent.py", "agent_config.json"})
            self.assertEqual(json.loads(archive.read("agent_config.json")), settings)
            self.assertEqual(archive.getinfo("agent.py").external_attr >> 16, 0o100644)

    def test_tampered_package_is_rejected(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        directory = Path(temporary.name)
        (directory / "package.zip").write_bytes(b"tampered")
        (directory / "package.sha256").write_text("wrong")
        with self.assertRaisesRegex(ValueError, "modified"):
            agents.package_agent(types.SimpleNamespace(path=directory), {})


class AssistantTests(unittest.TestCase):
    def load_assistant(self):
        name = "aws_manager_assistant_test"
        module_spec = importlib.util.spec_from_file_location(name, agents.ASSETS / "agent.py")
        module = importlib.util.module_from_spec(module_spec)
        runtime = types.ModuleType("bedrock_agentcore.runtime")
        app = MagicMock()
        app.entrypoint.side_effect = lambda function: function
        runtime.BedrockAgentCoreApp = MagicMock(return_value=app)
        model = MagicMock()
        settings = {
            "model_id": "amazon.nova-micro-v1:0",
            "instructions": "You are a helpful assistant.", "max_tokens": 4096,
        }
        with (
            patch.dict(sys.modules, {"bedrock_agentcore.runtime": runtime}),
            patch.dict(os.environ, {"AWS_REGION": "eu-north-1"}),
            patch.object(Path, "read_text", return_value=json.dumps(settings)),
            patch("boto3.client", return_value=model),
        ):
            module_spec.loader.exec_module(module)
        return module, model

    def test_assistant_keeps_conversation_and_complete_answer(self):
        module, model = self.load_assistant()
        model.converse.side_effect = [
            {"output": {"message": {"role": "assistant", "content": [{"text": "First"}, {"text": " full reply"}]}}, "stopReason": "end_turn"},
            {"output": {"message": {"role": "assistant", "content": [{"text": "Second reply"}]}}, "stopReason": "end_turn"},
        ]
        self.assertEqual(module.invoke({"prompt": "Hello"})["result"], "First full reply")
        self.assertEqual(module.invoke({"prompt": "Continue"})["result"], "Second reply")
        self.assertEqual(len(model.converse.call_args.kwargs["messages"]), 3)
        self.assertEqual(model.converse.call_args.kwargs["inferenceConfig"]["maxTokens"], 4096)

    def test_model_limit_or_error_does_not_commit_partial_history(self):
        module, model = self.load_assistant()
        model.converse.return_value = {
            "output": {"message": {"role": "assistant", "content": [{"text": "partial"}]}},
            "stopReason": "max_tokens",
        }
        with self.assertRaisesRegex(ValueError, "max_tokens"):
            module.invoke({"prompt": "Hello"})
        self.assertEqual(module.messages, [])
        with self.assertRaisesRegex(ValueError, "nonempty"):
            module.invoke({"prompt": ""})

    @unittest.skipUnless(importlib.util.find_spec("bedrock_agentcore"), "Install the runtime asset requirements for the real SDK integration test.")
    def test_real_runtime_sdk_http_invocation_and_health(self):
        async def request(app, method, path, body=b""):
            scope = {
                "type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1",
                "method": method, "scheme": "http", "path": path, "raw_path": path.encode(),
                "query_string": b"", "root_path": "", "headers": [(b"content-type", b"application/json")],
                "client": ("127.0.0.1", 12345), "server": ("127.0.0.1", 8080),
            }
            received = False
            outgoing = []

            async def receive():
                nonlocal received
                if not received:
                    received = True
                    return {"type": "http.request", "body": body, "more_body": False}
                await asyncio.Event().wait()

            async def send(message):
                outgoing.append(message)

            await asyncio.wait_for(app(scope, receive, send), timeout=15)
            status = next(item["status"] for item in outgoing if item["type"] == "http.response.start")
            data = b"".join(item.get("body", b"") for item in outgoing if item["type"] == "http.response.body")
            return status, json.loads(data)

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            shutil.copyfile(agents.ASSETS / "agent.py", directory / "agent.py")
            (directory / "agent_config.json").write_text(json.dumps({
                "model_id": "amazon.nova-micro-v1:0",
                "instructions": "You are a helpful assistant.", "max_tokens": 4096,
            }), encoding="utf-8")
            loader = importlib.util.spec_from_file_location("native_sdk_assistant", directory / "agent.py")
            module = importlib.util.module_from_spec(loader)
            model = MagicMock()
            model.converse.return_value = {
                "output": {"message": {"role": "assistant", "content": [{"text": "Complete native SDK reply"}]}},
                "stopReason": "end_turn",
            }
            with (
                environment.process_environment(environment.isolated_environment(directory, "eu-north-1")),
                patch("boto3.client", return_value=model),
            ):
                loader.loader.exec_module(module)
                status, response = asyncio.run(request(module.app, "POST", "/invocations", b'{"prompt":"Hello"}'))
                self.assertEqual((status, response["result"]), (200, "Complete native SDK reply"))
                ping_status, _ = asyncio.run(request(module.app, "GET", "/ping"))
                self.assertEqual(ping_status, 200)


class CustomizationTests(unittest.TestCase):
    def paths(self):
        return [
            ROOT / ".github" / "agents" / "aws-ai-manager.agent.md",
            *[SKILLS / name / "SKILL.md" for name in (
                "aws-ai-agent-setup", "aws-ai-agent-create",
                "aws-ai-agent-test-prompts", "aws-ai-agent-delete",
            )],
        ]

    def test_frontmatter_is_discoverable_and_skill_names_match(self):
        for path in self.paths():
            text = path.read_text(encoding="utf-8")
            with self.subTest(path=path):
                self.assertTrue(text.startswith("---\n"))
                header = text.split("---", 2)[1]
                self.assertRegex(header, r"(?m)^description: '.+'\s*$")
                if path.name == "SKILL.md":
                    self.assertIn(f"name: {path.parent.name}\n", header)
                else:
                    self.assertIn("name: AWS AI Manager\n", header)

    def test_related_markdown_links_resolve(self):
        paths = [
            *self.paths(), ROOT / "docs" / "aws-ai-manager.md",
            SCRIPTS.parent / "references" / "operator-guide.md",
        ]
        for path in paths:
            text = path.read_text(encoding="utf-8")
            for match in re.finditer(r"\[[^\]]+\]\(([^)]+)\)", text):
                link = match[1].split("#")[0]
                if not link or "://" in link:
                    continue
                with self.subTest(path=path, link=link):
                    self.assertTrue((path.parent / link).resolve().exists())

    def test_cli_help_needs_no_authentication(self):
        with redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as exit_code:
            agents.main(["--help"])
        self.assertEqual(exit_code.exception.code, 0)

    def test_invalid_scope_returns_structured_error_without_signing_in(self):
        with redirect_stderr(io.StringIO()) as output, patch.object(agents, "AwsContext") as context:
            status = agents.main(["check-account", "--auth-dir", "unused", "--account-id", "invalid", "--region", "eu-north-1"])
        self.assertEqual(status, 1)
        self.assertFalse(json.loads(output.getvalue())["ok"])
        context.assert_not_called()

    def test_main_prints_full_partial_batch_and_exits_nonzero(self):
        answer = "complete reply " * 10000
        outcome = {"ok": False, "responses": [{"answer": answer}, {"status": "error", "error": "Denied"}]}
        context = MagicMock()
        with (
            tempfile.TemporaryDirectory() as temporary,
            patch.object(agents, "private_directory", return_value=Path(temporary)),
            patch.object(agents, "AwsContext", return_value=context),
            patch.object(agents, "execute", return_value=outcome),
            redirect_stdout(io.StringIO()) as output,
        ):
            status = agents.main([
                "send", "--auth-dir", temporary, "--run-dir", str(Path(temporary) / "run"),
                "--account-id", "123456789012", "--region", "eu-north-1",
                "--agent", "arn:aws:bedrock-agentcore:eu-north-1:123456789012:runtime/Agent-AbCdEf1234",
            ])
        self.assertEqual(status, 1)
        self.assertEqual(json.loads(output.getvalue())["responses"][0]["answer"], answer)


if __name__ == "__main__":
    unittest.main()
