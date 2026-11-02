from __future__ import annotations

import argparse
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

import botocore.session
from botocore.exceptions import ClientError
from botocore.validate import validate_parameters
from botocore import xform_name


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
import aws_ai_agents as agents


ACCOUNT = "123456789012"
REGION = "eu-north-1"
RUNTIME_ID = "AwsAssistant-AbCdEf1234"
RUNTIME_ARN = f"arn:aws:bedrock-agentcore:{REGION}:{ACCOUNT}:runtime/{RUNTIME_ID}"
CLASSIC_ID = "ABCDEFGHIJ"
CLASSIC_ARN = f"arn:aws:bedrock:{REGION}:{ACCOUNT}:agent/{CLASSIC_ID}"
TAGS = {agents.OWNER_TAG: agents.MANAGER, "aws-ai-manager-account": ACCOUNT}
ROLE = f"arn:aws:iam::{ACCOUNT}:role/agent-role"
MODELS = {
    "resources": [f"arn:aws:bedrock:{REGION}::foundation-model/amazon.nova-micro-v1:0"],
    "destination_regions": [REGION], "model_id": "amazon.nova-micro-v1:0",
}


class FakeContext:
    def __init__(self):
        self.account_id = ACCOUNT
        self.region = REGION
        self.identity = {"Account": ACCOUNT, "Arn": f"arn:aws:iam::{ACCOUNT}:user/operator"}
        self.clients = {name: MagicMock(name=name) for name in (
            "bedrock", "bedrock-agentcore-control", "bedrock-agentcore",
            "bedrock-agent", "bedrock-agent-runtime", "iam", "s3",
        )}
        self.client("bedrock-agentcore-control").list_agent_runtimes.return_value = {"agentRuntimes": []}
        self.client("bedrock-agentcore-control").get_agent_runtime.return_value = {
            "agentRuntimeArn": RUNTIME_ARN, "agentRuntimeId": RUNTIME_ID,
            "agentRuntimeName": "AwsAssistant", "status": "READY",
        }
        self.client("bedrock-agentcore-control").list_tags_for_resource.return_value = {"tags": TAGS}
        self.client("bedrock-agentcore-control").list_agent_runtime_endpoints.return_value = {"runtimeEndpoints": []}
        self.client("bedrock-agent").list_agents.return_value = {"agentSummaries": []}
        self.client("bedrock-agent").get_agent.return_value = {"agent": {
            "agentArn": CLASSIC_ARN, "agentId": CLASSIC_ID,
            "agentName": "AwsClassicAssistant", "agentStatus": "PREPARED",
        }}
        self.client("bedrock-agent").list_tags_for_resource.return_value = {"tags": TAGS}
        self.client("bedrock-agent").list_agent_aliases.return_value = {"agentAliasSummaries": []}
        self.client("bedrock-agent").list_agent_action_groups.return_value = {"actionGroupSummaries": []}
        self.client("bedrock-agent").list_agent_knowledge_bases.return_value = {"agentKnowledgeBaseSummaries": []}
        self.client("bedrock-agent").list_agent_collaborators.return_value = {"agentCollaboratorSummaries": []}

    def client(self, name):
        return self.clients[name]

    def require_nonroot(self):
        agents.AwsContext.require_nonroot(self)


def spec(service="agentcore"):
    return {
        "service": service,
        "name": "AwsAssistant" if service == "agentcore" else "AwsClassicAssistant",
        "model_id": MODELS["model_id"],
        "instructions": "You are a helpful assistant. Answer clearly and accurately.",
        "max_tokens": 4096,
        "allow_cross_region": False,
        "existing_classic_customer": service == "bedrock",
        "execution_role_arn": ROLE,
        **({"artifact_bucket": "private-agent-artifacts"} if service == "agentcore" else {}),
    }


def target(service="agentcore"):
    return {
        "service": service,
        "id": RUNTIME_ID if service == "agentcore" else CLASSIC_ID,
        "arn": RUNTIME_ARN if service == "agentcore" else CLASSIC_ARN,
        "name": "AwsAssistant" if service == "agentcore" else "AwsClassicAssistant",
    }


class BaseCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name)
        self.context = FakeContext()

        def private(value):
            path = Path(value)
            path.mkdir(parents=True, exist_ok=True)
            return path

        self.private = patch.object(agents, "private_directory", side_effect=private)
        self.private.start()
        self.addCleanup(self.private.stop)

    def args(self, action, **values):
        return argparse.Namespace(
            **{
                "action": action, "run_dir": str(self.path / action), "apply": False,
                "confirm": None, "force": False, "timeout": 1, "count": None,
                "prompt": None, "prompts_file": None, "expected_text": None,
                "qualifier": None, "alias_id": None,
                **values,
            }
        )

    def assert_requests_valid(self, context=None):
        models = botocore.session.get_session()
        for service, client in (context or self.context).clients.items():
            service_model = models.get_service_model(service)
            methods = {xform_name(name): name for name in service_model.operation_names}
            for name, method in client._mock_children.items():
                if name in methods:
                    shape = service_model.operation_model(methods[name]).input_shape
                    for call in method.call_args_list:
                        self.assertFalse(call.args, (service, name))
                        validate_parameters(call.kwargs, shape)


class ReferenceTests(unittest.TestCase):
    def test_runtime_arn_derives_scope(self):
        parsed = agents.reference(RUNTIME_ARN)
        self.assertEqual((parsed["service"], parsed["region"], parsed["account_id"]), ("agentcore", REGION, ACCOUNT))

    def test_console_runtime_singular_and_plural(self):
        for route in ("runtime", "runtimes", "agent-runtime"):
            with self.subTest(route=route):
                parsed = agents.reference(
                    f"https://{REGION}.console.aws.amazon.com/bedrock-agentcore/home?region={REGION}#/{route}/{RUNTIME_ID}"
                )
                self.assertEqual(parsed["value"], RUNTIME_ID)

    def test_classic_alias_url(self):
        parsed = agents.reference(
            f"https://console.aws.amazon.com/bedrock/home?region={REGION}#/agents/{CLASSIC_ID}/aliases/ZYXWVUTSRQ"
        )
        self.assertEqual(parsed["qualifier"], "ZYXWVUTSRQ")
        self.assertEqual(parsed["service"], "bedrock")

    def test_encoded_arn_in_console_url(self):
        from urllib.parse import quote
        parsed = agents.reference(
            f"https://console.aws.amazon.com/bedrock-agentcore/home?region={REGION}#/runtime/{quote(RUNTIME_ARN, safe='')}"
        )
        self.assertEqual(parsed["account_id"], ACCOUNT)

    def test_rejects_conflicting_service_or_region(self):
        for value, service in (
            (RUNTIME_ARN, "bedrock"),
            (f"https://eu-west-1.console.aws.amazon.com/bedrock/home?region={REGION}#/agents/{CLASSIC_ID}", None),
        ):
            with self.subTest(value=value), self.assertRaises(ValueError):
                agents.reference(value, service)

    def test_rejects_external_hosts_home_urls_and_unknown_arns(self):
        for value in (
            "https://console.aws.amazon.com.attacker.test/bedrock/home#/agents/ABCDEFGHIJ",
            "https://console.aws.amazon.com/bedrock/home?region=eu-north-1",
            "arn:aws:s3:::example",
            "https://console.aws.amazon.com/unknown/home#/agents/ABCDEFGHIJ",
        ):
            with self.subTest(value=value), self.assertRaises(ValueError):
                agents.reference(value)

    def test_exact_name_requires_service(self):
        with self.assertRaises(ValueError):
            agents.reference("FriendlyAssistant")
        self.assertEqual(agents.reference("FriendlyAssistant", "agentcore")["value"], "FriendlyAssistant")


class PromptTests(unittest.TestCase):
    def args(self, **values):
        return argparse.Namespace(count=None, prompt=None, prompts_file=None, **values)

    def test_defaults(self):
        self.assertEqual(agents.prompts(self.args()), [agents.DEFAULT_PROMPT])

    def test_default_prompt_repeats_exact_count(self):
        args = self.args()
        args.count = 7
        self.assertEqual(agents.prompts(args), [agents.DEFAULT_PROMPT] * 7)

    def test_multiple_prompts_infer_count(self):
        args = self.args()
        args.prompt = ["First", "Second"]
        self.assertEqual(agents.prompts(args), ["First", "Second"])

    def test_single_custom_prompt_repeats(self):
        args = self.args()
        args.prompt, args.count = ["Hello"], 3
        self.assertEqual(agents.prompts(args), ["Hello"] * 3)

    def test_invalid_count_and_lengths(self):
        for count, values in ((0, None), (-1, None), (3, ["one", "two"]), (1, [""])):
            args = self.args()
            args.count, args.prompt = count, values
            with self.subTest(count=count, values=values), self.assertRaises(ValueError):
                agents.prompts(args)


class DiscoveryTests(BaseCase):
    def test_all_pages_and_duplicate_names_are_rejected(self):
        client = self.context.client("bedrock-agentcore-control")
        client.list_agent_runtimes.side_effect = [
            {"agentRuntimes": [{"agentRuntimeId": RUNTIME_ID, "agentRuntimeName": "Same", "agentRuntimeArn": RUNTIME_ARN}], "nextToken": "next"},
            {"agentRuntimes": [{"agentRuntimeId": "OtherAgent-1234567890", "agentRuntimeName": "Same",
                                "agentRuntimeArn": RUNTIME_ARN.replace(RUNTIME_ID, "OtherAgent-1234567890")}]},
        ]
        with self.assertRaisesRegex(ValueError, "found 2"):
            agents.resolve(self.context, agents.reference("Same", "agentcore"))
        self.assertEqual(client.list_agent_runtimes.call_count, 2)
        self.assert_requests_valid()

    def test_repeated_pagination_token_fails(self):
        client = MagicMock()
        client.operation.return_value = {"items": [], "nextToken": "same"}
        with self.assertRaisesRegex(ValueError, "repeated"):
            agents.paginate(client, "operation", "items")

    def test_cross_scope_rejected_before_listing(self):
        selected = agents.reference(RUNTIME_ARN.replace(ACCOUNT, "999999999999"))
        with self.assertRaisesRegex(ValueError, "account_id"):
            agents.resolve(self.context, selected)
        self.context.client("bedrock-agentcore-control").list_agent_runtimes.assert_not_called()


class ModelTests(BaseCase):
    def foundation(self, available=True):
        client = self.context.client("bedrock")
        client.get_foundation_model.return_value = {"modelDetails": {
            "modelId": MODELS["model_id"], "modelArn": MODELS["resources"][0],
            "inferenceTypesSupported": ["ON_DEMAND"], "inputModalities": ["TEXT"], "outputModalities": ["TEXT"],
        }}
        client.get_foundation_model_availability.return_value = {
            "authorizationStatus": "AUTHORIZED" if available else "NOT_AUTHORIZED",
            "entitlementAvailability": "AVAILABLE", "regionAvailability": "AVAILABLE",
            "agreementAvailability": {"status": "AVAILABLE"},
        }

    def test_regional_model_access_is_verified(self):
        self.foundation()
        self.assertEqual(agents.model_resources(self.context, MODELS["model_id"], False), MODELS)
        self.assert_requests_valid()

    def test_unavailable_model_is_not_success(self):
        self.foundation(False)
        with self.assertRaisesRegex(ValueError, "not ready"):
            agents.model_resources(self.context, MODELS["model_id"], False)

    def test_embedding_model_is_not_a_text_agent_model(self):
        self.foundation()
        client = self.context.client("bedrock")
        client.get_foundation_model.return_value["modelDetails"]["outputModalities"] = ["EMBEDDING"]
        with self.assertRaisesRegex(ValueError, "text-generation"):
            agents.model_resources(self.context, MODELS["model_id"], False)
        client.get_foundation_model_availability.assert_not_called()

    def test_cross_region_profile_requires_acknowledgement(self):
        client = self.context.client("bedrock")
        client.get_inference_profile.return_value = {
            "inferenceProfileArn": f"arn:aws:bedrock:{REGION}:{ACCOUNT}:inference-profile/eu.amazon.nova-micro-v1:0",
            "status": "ACTIVE",
            "models": [{"modelArn": MODELS["resources"][0].replace(REGION, "eu-west-1")}],
        }
        with self.assertRaisesRegex(ValueError, "across regions"):
            agents.model_resources(self.context, "eu.amazon.nova-micro-v1:0", False)
        allowed = agents.model_resources(self.context, "eu.amazon.nova-micro-v1:0", True)
        self.assertEqual(allowed["destination_regions"], ["eu-west-1"])
        self.assert_requests_valid()


class PlanTests(BaseCase):
    def test_preview_does_not_execute_mutations(self):
        args = self.args("create")
        run = agents.Run(args, self.context, {"name": "one"}, lambda: {"confirmation": "one"})
        self.assertFalse(run.preview_result()["applied"])
        self.assertEqual(run.journal, {})

    def test_apply_requires_original_preview_and_exact_confirmation(self):
        args = self.args("create", apply=True, confirm="one")
        with self.assertRaisesRegex(ValueError, "preview first"):
            agents.Run(args, self.context, {"name": "one"}, lambda: {})
        args.apply = False
        agents.Run(args, self.context, {"name": "one"}, lambda: {"confirmation": "one"})
        args.apply, args.confirm = True, "wrong"
        with self.assertRaisesRegex(ValueError, "exact confirmation"):
            agents.Run(args, self.context, {"name": "one"}, lambda: {})

    def test_changed_spec_invalidates_preview(self):
        args = self.args("create")
        agents.Run(args, self.context, {"name": "one"}, lambda: {"confirmation": "one"})
        args.apply, args.confirm = True, "one"
        with self.assertRaisesRegex(ValueError, "differs"):
            agents.Run(args, self.context, {"name": "two"}, lambda: {})

    def test_completed_step_is_not_replayed(self):
        args = self.args("create")
        run = agents.Run(args, self.context, {}, lambda: {"confirmation": "one"})
        operation = MagicMock(return_value={"id": "created"})
        self.assertEqual(run.call("step", operation), {"id": "created"})
        self.assertEqual(run.call("step", operation), {"id": "created"})
        operation.assert_called_once()

    def test_uncertain_write_is_never_replayed(self):
        args = self.args("create")
        run = agents.Run(args, self.context, {}, lambda: {"confirmation": "one"})
        operation = MagicMock(side_effect=TimeoutError("Connection lost"))
        with self.assertRaises(TimeoutError):
            run.call("step", operation)
        with self.assertRaisesRegex(ValueError, "uncertain"):
            run.call("step", operation)
        operation.assert_called_once()


class MutationTests(BaseCase):
    def test_setup_preview_and_apply_use_valid_schemas_and_separate_spec(self):
        prepared = spec()
        prepared.pop("execution_role_arn")
        prepared.pop("artifact_bucket")
        names = agents.setup_names(self.context, prepared)
        role = {
            "Arn": f"arn:aws:iam::{ACCOUNT}:role/{names['role_name']}",
            "Tags": [{"Key": key, "Value": value} for key, value in names["tags"].items()],
        }
        iam, s3 = self.context.client("iam"), self.context.client("s3")
        iam.get_role.side_effect = [
            ClientError({"Error": {"Code": "NoSuchEntity"}}, "GetRole"), {"Role": role},
        ]
        iam.create_role.return_value = {"Role": role}
        s3.head_bucket.side_effect = ClientError({"Error": {"Code": "NoSuchBucket"}}, "HeadBucket")
        args = self.args("setup")
        with patch.object(agents, "model_resources", return_value=MODELS):
            preview = agents.setup(self.context, args, prepared)
            iam.create_role.assert_not_called()
            s3.create_bucket.assert_not_called()
            args.apply, args.confirm = True, preview["confirmation"]
            result = agents.setup(self.context, args, prepared)
        self.assertTrue(result["ok"])
        saved = json.loads(Path(result["create_spec"]).read_text())
        self.assertEqual(saved["execution_role_arn"], role["Arn"])
        self.assertEqual(saved["artifact_bucket"], names["bucket"])
        self.assertEqual(s3.create_bucket.call_args.kwargs["CreateBucketConfiguration"], {"LocationConstraint": REGION})
        self.assert_requests_valid()

    def test_agentcore_create_schema_and_resumption_do_not_repeat_create(self):
        client = self.context.client("bedrock-agentcore-control")
        client.create_agent_runtime.return_value = {"agentRuntimeId": RUNTIME_ID, "agentRuntimeArn": RUNTIME_ARN}
        self.context.client("s3").put_object.return_value = {"VersionId": "version-one"}
        artifact = self.path / "package.zip"
        artifact.write_bytes(b"test package")
        args = self.args("create")
        with (
            patch.object(agents, "model_resources", return_value=MODELS),
            patch.object(agents, "validate_prerequisites"),
            patch.object(agents, "package_agent", return_value=artifact),
        ):
            preview = agents.create(self.context, args, spec())
            client.create_agent_runtime.assert_not_called()
            args.apply, args.confirm = True, preview["confirmation"]
            result = agents.create(self.context, args, spec())
            self.assertTrue(result["ok"])
            agents.create(self.context, args, spec())
        client.create_agent_runtime.assert_called_once()
        self.context.client("s3").put_object.assert_called_once()
        location = client.create_agent_runtime.call_args.kwargs["agentRuntimeArtifact"]["codeConfiguration"]["code"]["s3"]
        self.assertEqual(location["versionId"], "version-one")
        self.assert_requests_valid()

    def test_classic_create_honors_max_tokens_and_publishes_alias(self):
        client = self.context.client("bedrock-agent")
        client.create_agent.return_value = {"agent": {
            "agentId": CLASSIC_ID, "agentArn": CLASSIC_ARN,
        }}
        client.prepare_agent.return_value = {}
        client.create_agent_alias.return_value = {"agentAlias": {"agentAliasId": "ZYXWVUTSRQ"}}
        client.get_agent_alias.return_value = {"agentAlias": {"agentAliasStatus": "PREPARED"}}
        args = self.args("create")
        with patch.object(agents, "model_resources", return_value=MODELS), patch.object(agents, "validate_prerequisites"):
            preview = agents.create(self.context, args, spec("bedrock"))
            args.apply, args.confirm = True, preview["confirmation"]
            result = agents.create(self.context, args, spec("bedrock"))
        self.assertEqual(result["alias_id"], "ZYXWVUTSRQ")
        configuration = client.create_agent.call_args.kwargs["promptOverrideConfiguration"]
        self.assertEqual(configuration["promptConfigurations"][0]["inferenceConfiguration"]["maximumLength"], 4096)
        self.assert_requests_valid()

    def test_unmanaged_agent_is_never_deleted_even_with_force(self):
        client = self.context.client("bedrock-agentcore-control")
        client.list_tags_for_resource.return_value = {"tags": {}}
        with self.assertRaisesRegex(ValueError, "not owned"):
            agents.deletion_snapshot(self.context, target())
        client.delete_agent_runtime.assert_not_called()

    def test_classic_external_associations_are_refused(self):
        client = self.context.client("bedrock-agent")
        client.list_agent_knowledge_bases.return_value = {"agentKnowledgeBaseSummaries": [{"knowledgeBaseId": "external"}]}
        with self.assertRaisesRegex(ValueError, "Detach"):
            agents.deletion_snapshot(self.context, target("bedrock"))

    def test_delete_waits_for_not_found(self):
        selected = agents.reference(RUNTIME_ARN)
        args = self.args("delete")
        with patch.object(agents, "resolve", return_value=target()):
            preview = agents.delete(self.context, args, selected)
        self.context.client("bedrock-agentcore-control").delete_agent_runtime.return_value = {"status": "DELETING"}
        args.apply, args.confirm = True, preview["confirmation"]
        missing = ClientError({"Error": {"Code": "ResourceNotFoundException"}}, "GetAgentRuntime")
        self.context.client("bedrock-agentcore-control").get_agent_runtime.side_effect = [
            {"agentRuntimeArn": RUNTIME_ARN}, missing,
        ]
        result = agents.delete(self.context, args, selected)
        self.assertEqual(result["verified"], "ResourceNotFound")
        self.assert_requests_valid()

    def test_delete_resume_handles_accepted_child_still_deleting(self):
        selected = agents.reference(RUNTIME_ARN)
        child = {"service": "agentcore", "arn": RUNTIME_ARN + "/runtime-endpoint/custom", "name": "custom"}
        snapshot = {"agent": target(), "tags": TAGS, "children": [child]}
        args = self.args("delete", force=True)
        with patch.object(agents, "resolve", return_value=target()), patch.object(agents, "deletion_snapshot", return_value=snapshot):
            preview = agents.delete(self.context, args, selected)
            args.apply, args.confirm = True, preview["confirmation"]
            client = self.context.client("bedrock-agentcore-control")
            client.delete_agent_runtime_endpoint.return_value = {"status": "DELETING"}
            client.delete_agent_runtime.return_value = {"status": "DELETING"}
            with patch.object(agents, "wait_for", side_effect=TimeoutError("Still deleting")):
                with self.assertRaises(TimeoutError):
                    agents.delete(self.context, args, selected)
            with patch.object(agents, "wait_for", return_value={"deleted": True}):
                self.assertTrue(agents.delete(self.context, args, selected)["deleted"])
        client.delete_agent_runtime_endpoint.assert_called_once()

    def test_new_child_after_preview_is_not_deleted(self):
        selected = agents.reference(RUNTIME_ARN)
        snapshot = {"agent": target(), "tags": TAGS, "children": []}
        args = self.args("delete", force=True)
        with patch.object(agents, "resolve", return_value=target()), patch.object(agents, "deletion_snapshot", return_value=snapshot):
            preview = agents.delete(self.context, args, selected)
        args.apply, args.confirm = True, preview["confirmation"]
        changed = {**snapshot, "children": [{
            "service": "agentcore", "arn": RUNTIME_ARN + "/runtime-endpoint/new", "name": "new",
        }]}
        with patch.object(agents, "deletion_snapshot", return_value=changed):
            with self.assertRaisesRegex(ValueError, "changed"):
                agents.delete(self.context, args, selected)
        self.context.client("bedrock-agentcore-control").delete_agent_runtime.assert_not_called()

    def test_known_parent_deletion_resumes_polling_only(self):
        selected = agents.reference(RUNTIME_ARN)
        snapshot = {"agent": target(), "tags": TAGS, "children": []}
        args = self.args("delete")
        with patch.object(agents, "resolve", return_value=target()), patch.object(agents, "deletion_snapshot", return_value=snapshot):
            preview = agents.delete(self.context, args, selected)
            args.apply, args.confirm = True, preview["confirmation"]
            self.context.client("bedrock-agentcore-control").delete_agent_runtime.return_value = {"status": "DELETING"}
            with patch.object(agents, "wait_for", side_effect=TimeoutError("Still deleting")):
                with self.assertRaises(TimeoutError):
                    agents.delete(self.context, args, selected)
        with patch.object(agents, "deletion_snapshot") as inspect_children, patch.object(agents, "wait_for", return_value={"deleted": True}):
            self.assertTrue(agents.delete(self.context, args, selected)["deleted"])
        inspect_children.assert_not_called()
        self.context.client("bedrock-agentcore-control").delete_agent_runtime.assert_called_once()

    def test_force_classic_delete_removes_only_managed_alias_and_checks_not_found(self):
        selected = agents.reference(CLASSIC_ARN)
        client = self.context.client("bedrock-agent")
        client.list_agent_aliases.return_value = {"agentAliasSummaries": [
            {"agentAliasId": "ZYXWVUTSRQ", "agentAliasName": "managed"},
        ]}
        client.delete_agent_alias.return_value = {}
        client.get_agent_alias.side_effect = ClientError({"Error": {"Code": "ResourceNotFoundException"}}, "GetAgentAlias")
        client.delete_agent.return_value = {"agentStatus": "DELETING"}
        args = self.args("delete", force=True)
        with patch.object(agents, "resolve", return_value=target("bedrock")):
            preview = agents.delete(self.context, args, selected)
        args.apply, args.confirm = True, preview["confirmation"]
        missing = ClientError({"Error": {"Code": "ResourceNotFoundException"}}, "GetAgent")
        client.get_agent.side_effect = [
            {"agent": {"agentArn": CLASSIC_ARN}}, missing,
        ]
        result = agents.delete(self.context, args, selected)
        self.assertTrue(result["deleted"])
        client.delete_agent.assert_called_once_with(agentId=CLASSIC_ID, skipResourceInUseCheck=False)
        client.delete_agent_alias.assert_called_once_with(agentId=CLASSIC_ID, agentAliasId="ZYXWVUTSRQ")
        self.assert_requests_valid()

    def test_each_endpoint_delete_has_its_own_idempotency_token(self):
        selected = agents.reference(RUNTIME_ARN)
        children = [
            {"service": "agentcore", "arn": RUNTIME_ARN + f"/runtime-endpoint/{name}", "name": name}
            for name in ("first", "second")
        ]
        snapshot = {"agent": target(), "tags": TAGS, "children": children}
        args = self.args("delete", force=True)
        client = self.context.client("bedrock-agentcore-control")
        client.delete_agent_runtime_endpoint.return_value = {"status": "DELETING"}
        client.delete_agent_runtime.return_value = {"status": "DELETING"}
        with patch.object(agents, "resolve", return_value=target()), patch.object(agents, "deletion_snapshot", return_value=snapshot):
            preview = agents.delete(self.context, args, selected)
            args.apply, args.confirm = True, preview["confirmation"]
            with patch.object(agents, "wait_for", return_value={"deleted": True}):
                agents.delete(self.context, args, selected)
        tokens = [call.kwargs["clientToken"] for call in client.delete_agent_runtime_endpoint.call_args_list]
        self.assertEqual(len(set(tokens)), 2)
        self.assert_requests_valid()


class StreamTests(unittest.TestCase):
    def test_large_multibyte_runtime_response_is_complete(self):
        answer = "A" * 100000 + "\u20ac" + "Z" * 100000
        payload = json.dumps({"result": answer}, ensure_ascii=False).encode()
        stream = MagicMock()
        stream.iter_chunks.return_value = [payload[index:index + 1] for index in range(len(payload))]
        self.assertEqual(agents.runtime_answer({"response": stream, "contentType": "application/json"}), answer)
        stream.close.assert_called_once()

    def test_sse_multiline_and_done(self):
        stream = io.BytesIO(b'data: {"text": "first"}\r\n\r\ndata: {"text": "second"}\n\ndata: [DONE]\n\n')
        self.assertEqual(agents.runtime_answer({"response": stream, "contentType": "text/event-stream"}), "firstsecond")
        self.assertTrue(stream.closed)

    def test_errors_and_unknown_shapes_are_not_answers(self):
        for value in ({"error": "failed"}, {"unknown": "value"}, {"result": "partial", "stop_reason": "max_tokens"}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                agents.answer_text(value)

    def test_classic_decodes_split_unicode_bytes(self):
        stream = MagicMock()
        text = "Full \u20ac response"
        value = text.encode()
        stream.__iter__.return_value = [
            {"chunk": {"bytes": value[:6]}}, {"chunk": {"bytes": value[6:]}},
        ]
        self.assertEqual(agents.classic_answer({"completion": stream}), text)
        stream.close.assert_called_once()

    def test_classic_return_control_is_explicit_error(self):
        stream = MagicMock()
        stream.__iter__.return_value = [{"returnControl": {"invocationId": "external"}}]
        with self.assertRaisesRegex(ValueError, "external action"):
            agents.classic_answer({"completion": stream})


class SendTests(BaseCase):
    def invoke(self, args, replies, service="agentcore"):
        selected = agents.reference(RUNTIME_ARN if service == "agentcore" else CLASSIC_ARN)
        client = self.context.client("bedrock-agentcore")
        client.invoke_agent_runtime.side_effect = replies
        with patch.object(agents, "resolve", return_value=target(service)):
            return agents.send(self.context, args, [selected])

    def test_count_full_replies_and_conversation(self):
        args = self.args("send", count=3)
        replies = [
            {"contentType": "application/json", "response": io.BytesIO(json.dumps({"result": f"complete answer {index}"}).encode())}
            for index in range(3)
        ]
        result = self.invoke(args, replies)
        self.assertTrue(result["ok"])
        self.assertEqual([item["answer"] for item in result["responses"]], [f"complete answer {index}" for index in range(3)])
        self.assertEqual(len({item["session_id"] for item in result["responses"]}), 1)
        self.assert_requests_valid()

    def test_expected_text_failure_keeps_full_answer(self):
        args = self.args("send", expected_text="missing")
        answer = "Not the expected text, but still the full answer."
        result = self.invoke(args, [{
            "contentType": "application/json", "response": io.BytesIO(json.dumps({"result": answer}).encode()),
        }])
        self.assertFalse(result["ok"])
        self.assertEqual(result["responses"][0]["answer"], answer)

    def test_partial_batch_returns_received_answers_and_failure(self):
        args = self.args("send", count=2)
        result = self.invoke(args, [
            {"contentType": "application/json", "response": io.BytesIO(b'{"result":"first full reply"}')},
            ClientError({"Error": {"Code": "AccessDeniedException", "Message": "Denied"}}, "InvokeAgentRuntime"),
        ])
        self.assertFalse(result["ok"])
        self.assertEqual(result["responses"][0]["answer"], "first full reply")
        self.assertEqual(result["responses"][1]["status"], "error")
        self.assertEqual(json.loads(Path(result["responses_file"]).read_text())["responses"], result["responses"])

    def test_existing_response_run_is_not_resent(self):
        args = self.args("send")
        directory = Path(args.run_dir)
        directory.mkdir()
        (directory / "responses.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "will not be resent"):
            agents.send(self.context, args, [agents.reference(RUNTIME_ARN)])
        self.context.client("bedrock-agentcore").invoke_agent_runtime.assert_not_called()

    def test_wrong_service_option_is_not_silently_ignored(self):
        args = self.args("send", alias_id="ZYXWVUTSRQ")
        with self.assertRaisesRegex(ValueError, "only to Bedrock"):
            self.invoke(args, [])


if __name__ == "__main__":
    unittest.main()
