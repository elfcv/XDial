import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import uuid


spec = importlib.util.spec_from_file_location("jev_loop", Path(__file__).resolve().parents[1] / "scripts/jev_loop.py")
jev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(jev)


def observation(**overrides):
    value = dict(id=str(uuid.uuid4()), startedAt="2026-10-01T00:00:00Z",
                 observedAt="2026-10-01T00:00:01Z", status="failed", inFlight=False,
                 activeRelationship="source", candidateState="failed", cancellationRequested=False,
                 timedOut=False, errorCode="switch-host-failed", failedTaskKinds=["line"],
                 transitions=["preparing", "failed"], sameScenario=False, channel="debug",
                 sourceRevision="a" * 40, buildVersion="202610160001")
    return dict(value, **overrides)


def response(investigate=0.9):
    def choice(name, options):
        return dict(type="choice", name=name, choice=options[0], confidence=0.9,
                    probabilities=[dict(value=x, probability=1 if i == 0 else 0)
                                   for i, x in enumerate(options)])
    return dict(model="gpt-6-luna", usage=dict(input_tokens=42), answers=[
        dict(type="predicate", name="needs_investigation", probability=investigate),
        choice("suspected_layer", ["host", "provider", "line", "environment", "unknown"]),
        choice("severity", ["low", "medium", "high"])])


class InputTests(unittest.TestCase):
    def test_subscription_uses_saved_login_and_isolates_analysis(self):
        payload = dict(needs_investigation=True, confidence=0.8, suspected_layer="host", severity="medium")
        def fake_run(arguments, **kwargs):
            self.assertIn('forced_login_method="chatgpt"', arguments)
            self.assertIn("read-only", arguments)
            self.assertNotIn("--model", arguments)
            self.assertNotEqual(kwargs["cwd"], jev.ROOT)
            for secret in ("OPENAI_API_KEY", "CODEX_API_KEY", "GH_TOKEN", "GITHUB_TOKEN"):
                self.assertNotIn(secret, kwargs["env"])
            output = Path(arguments[arguments.index("--output-last-message") + 1])
            jev.atomic_json(output, payload)
            return json.dumps(dict(type="turn.completed", usage=dict(input_tokens=123)))
        with patch.dict(os.environ, {"CODEX_API_KEY": "DO_NOT_USE", "OPENAI_API_KEY": "DO_NOT_USE"}):
            with patch.object(jev, "run", side_effect=fake_run):
                result = jev.decide_with_codex(jev.sanitized_observation(observation()))
        self.assertEqual(result["provider"], "codex")
        self.assertEqual(result["score_kind"], "model_self_reported_confidence")
        self.assertEqual(result["input_tokens"], 123)
        self.assertNotIn("probabilities", json.dumps(result))
        self.assertTrue(jev.warrants_repair(result))
        result["confidence"] = 0.6
        self.assertFalse(jev.warrants_repair(result))
        result.update(needs_investigation=False, confidence=1.0)
        self.assertFalse(jev.warrants_repair(result))

    def test_subscription_rejects_non_boolean_or_missing_judgment(self):
        def fake_run(arguments, **_):
            output = Path(arguments[arguments.index("--output-last-message") + 1])
            jev.atomic_json(output, dict(needs_investigation=1, confidence=0.9,
                                         suspected_layer="host", severity="medium"))
            return ""
        with patch.object(jev, "run", side_effect=fake_run), self.assertRaises(ValueError):
            jev.decide_with_codex(jev.sanitized_observation(observation()))

    def test_subscription_login_status_can_be_on_stderr(self):
        with patch.object(jev.subprocess, "run", return_value=SimpleNamespace(
                returncode=0, stdout="", stderr="Logged in using ChatGPT\n")):
            self.assertTrue(jev.subscription_ready())
        with patch.object(jev.subprocess, "run", return_value=SimpleNamespace(
                returncode=0, stdout="", stderr="Logged in using an API key\n")):
            self.assertFalse(jev.subscription_ready())

    def test_only_allowlisted_facts_leave_the_worker(self):
        raw = observation(profileJSON="PRIVATE_PROFILE", message="PRIVATE_PASSWORD",
                          scenarioName="PRIVATE_NAME", underlay={"ssid": "PRIVATE_SSID"},
                          errorCode={"private": "PRIVATE_CODE"}, sourceRevision="PRIVATE_REVISION")
        safe = jev.sanitized_observation(raw)
        text = json.dumps(safe)
        self.assertNotIn("PRIVATE", text)
        self.assertNotIn(raw["id"], text)
        self.assertEqual(safe["error_code"], "unclassified")
        self.assertEqual(safe["source_revision"], "unversioned")

    def test_malformed_types_fail_closed(self):
        for key in ("status", "candidateState", "activeRelationship", "channel", "failedTaskKinds", "transitions"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                jev.sanitized_observation(observation(**{key: [{}]}))
        for key in ("inFlight", "cancellationRequested", "timedOut", "sameScenario"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                jev.sanitized_observation(observation(**{key: 1}))

    def test_cancellation_and_unknown_remain_facts(self):
        safe = jev.sanitized_observation(observation(status="reconciling", inFlight=True,
                                                   activeRelationship="unknown", cancellationRequested=True))
        self.assertEqual(safe["status"], "reconciling")
        self.assertTrue(safe["in_flight"])
        self.assertEqual(safe["active_relationship"], "unknown")
        self.assertEqual(jev.sanitized_observation(observation(candidateState="rolled_back"))["candidate_state"], "rolled_back")

    def test_response_rejects_refusal_nan_duplicates_and_free_text(self):
        cases = []
        for mutate in (
            lambda x: x["answers"].__setitem__(0, None),
            lambda x: x["answers"][0].update(type="refusal"),
            lambda x: x["answers"][0].update(probability=float("nan")),
            lambda x: x["answers"][0].update(probability=True),
            lambda x: x["answers"][1].update(choice={}),
            lambda x: x["answers"][1]["probabilities"].__setitem__(0, None),
            lambda x: x["answers"][1]["probabilities"][0].update(value=[]),
            lambda x: x["answers"][1]["probabilities"][0].update(probability=0.1),
            lambda x: x.update(model="PRIVATE_TEXT"),
        ):
            payload = response()
            mutate(payload)
            cases.append(payload)
        for payload in cases:
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                jev.parse_decision(payload)

    def test_api_request_and_response_contract(self):
        connection = Mock()
        connection.__enter__ = Mock(return_value=connection)
        connection.__exit__ = Mock(return_value=False)
        connection.read.return_value = json.dumps(response()).encode()
        opener = Mock()
        opener.open.return_value = connection
        with patch.object(jev.urllib.request, "build_opener", return_value=opener):
            result = jev.decide(jev.sanitized_observation(observation()), "TEST_KEY")
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, jev.API_URL)
        body = json.loads(request.data)
        self.assertEqual(body["model"], "gpt-6-luna")
        self.assertEqual(len(body["questions"]), 3)
        self.assertEqual(result["input_tokens"], 42)
        self.assertIn("question_sha256", result)


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.args = SimpleNamespace(observations=root / "input.json", state_dir=root / "state",
                                    acceptance=root / "acceptance.json", repo="owner/repo",
                                    decision_provider="api",
                                    publish=False, repair=False, max_decisions=100, max_repairs=3, max_cards=10)
        jev.atomic_json(self.args.acceptance, dict(schema_version=1, status="pending", criteria=[]))
        self.decision = Mock(return_value=jev.parse_decision(response()))
        self.publisher = Mock(return_value=dict(url="https://github.com/owner/repo/issues/1", closed=False))
        self.repairer = Mock(return_value=dict(status="draft_created", url="https://github.com/owner/repo/pull/2"))
        self.complete_pr = Mock(return_value=dict(status="draft_created", url="https://github.com/owner/repo/pull/2"))
        self.environment = patch.dict(os.environ, {"OPENAI_API_KEY": "TEST_KEY"})
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def process(self, values, state=None):
        jev.atomic_json(self.args.observations, dict(schemaVersion=1, observations=values))
        return jev.process_once(self.args, state if state is not None else {},
                                self.decision, self.publisher, self.repairer, self.complete_pr)

    def test_complete_pipeline_deduplicates_but_retains_occurrences(self):
        self.args.publish = self.args.repair = True
        first, second = observation(), observation()
        state = self.process([first, second])
        state = self.process([first, second], state)
        self.assertEqual(self.decision.call_count, 2)
        self.publisher.assert_called_once()
        self.repairer.assert_called_once()
        self.assertEqual(len(state["groups"]), 1)
        card = json.loads(next((self.args.state_dir / "cards").glob("*.json")).read_text())
        self.assertEqual(card["occurrences"], 2)
        self.assertEqual(card["acceptance"]["status"], "pending")
        self.assertNotIn("TEST_KEY", json.dumps(state))
        self.assertEqual((self.args.state_dir / "state.json").stat().st_mode & 0o777, 0o600)

    def test_no_key_keeps_local_evidence_without_claiming_a_decision(self):
        with patch.dict(os.environ, {}, clear=True):
            state = self.process([observation()])
        self.decision.assert_not_called()
        self.assertEqual(len(state["groups"]), 1)
        card = json.loads(next((self.args.state_dir / "cards").glob("*.json")).read_text())
        self.assertIsNone(card["decision"])
        self.assertIn("等待", card["decision_status"])

    def test_subscription_runs_without_api_key_and_changes_provider_cache(self):
        raw = observation()
        state = self.process([raw])
        self.args.decision_provider = "codex"
        self.decision.return_value = dict(provider="codex", needs_investigation=False, confidence=0.9)
        with patch.dict(os.environ, {}, clear=True):
            state = self.process([raw], state)
            self.process([raw], state)
        self.assertEqual(self.decision.call_count, 2)
        self.assertIsNone(self.decision.call_args.args[1])
        self.assertEqual(state["observations"][raw["id"]]["decision_provider"], "codex")
        self.assertEqual(len(state["groups"]), 1)

    def test_subscription_login_pending_keeps_cards_without_spending_budget(self):
        self.args.decision_provider = "codex"
        self.args.codex_ready = False
        state = self.process([observation()])
        self.decision.assert_not_called()
        self.assertEqual(state["decision_calls"], 0)
        self.assertEqual(len(state["groups"]), 1)

    def test_success_and_cancel_negative_samples_do_not_create_issues(self):
        self.decision.return_value = jev.parse_decision(response(0.1))
        state = self.process([observation(status="committed"), observation(status="cancelled")])
        self.assertEqual(len(state["observations"]), 2)
        self.assertFalse(state["groups"])
        self.publisher.assert_not_called()

    def test_in_flight_is_only_examined_when_stale(self):
        raw = observation(status="reconciling", inFlight=True, activeRelationship="unknown")
        with patch.object(jev.time, "time", return_value=jev.timestamp(raw["observedAt"]) + 20):
            self.process([raw])
        self.decision.assert_not_called()
        state = self.process([raw])
        self.assertEqual(len(state["groups"]), 1)
        safe = self.decision.call_args.args[0]
        self.assertEqual(safe["status"], "reconciling")
        self.assertTrue(safe["in_flight"])

    def test_corrupt_record_does_not_block_good_record(self):
        state = self.process([None, observation(status=[]), observation()])
        self.assertEqual(state["invalid_observations"], 2)
        self.decision.assert_called_once()

    def test_failure_backoff_and_restart_do_not_repeat_successful_decisions(self):
        self.args.publish = True
        self.publisher.side_effect = RuntimeError("failed")
        raw = observation()
        state = self.process([raw])
        self.assertEqual(next(iter(state["groups"].values()))["publish_error"], "github_unavailable")
        disk = json.loads((self.args.state_dir / "state.json").read_text())
        self.process([raw], disk)
        self.decision.assert_called_once()
        self.publisher.assert_called_once()

    def test_api_failures_backoff_and_daily_budget_is_persisted_first(self):
        self.args.max_decisions = 1
        def fail(*_):
            saved = json.loads((self.args.state_dir / "state.json").read_text())
            self.assertEqual(saved["decision_calls"], 1)
            raise RuntimeError("unavailable")
        self.decision.side_effect = fail
        raws = [observation(), observation()]
        state = self.process(raws)
        self.process(raws, state)
        self.decision.assert_called_once()
        self.assertEqual(state["decision_calls"], 1)

    def test_closed_issue_and_repair_failure_are_not_retried_automatically(self):
        self.args.publish = self.args.repair = True
        self.publisher.return_value["closed"] = True
        self.process([observation()])
        self.repairer.assert_not_called()
        self.publisher.return_value["closed"] = False
        self.repairer.side_effect = RuntimeError("unsafe change")
        raw = observation(errorCode="switch-timeout")
        state = self.process([raw])
        self.process([raw], state)
        self.repairer.assert_called_once()
        self.assertEqual(next(iter(state["groups"].values()))["repair"]["status"], "needs_developer_review")

    def test_limits_do_not_discard_existing_evidence(self):
        self.args.publish = True
        self.args.max_cards = 1
        state = self.process([observation(), observation(errorCode="switch-timeout")])
        self.assertEqual(len(state["groups"]), 2)
        self.publisher.assert_called_once()
        with patch.object(jev, "MAX_GROUPS", 2):
            state = self.process([observation(errorCode="switch-invalid-response")], state)
        self.assertEqual(len(state["groups"]), 2)
        self.assertEqual(next(iter(state["observations"].values()))["disposition"], "group_limit_reached")

    def test_pushed_candidate_resumes_pr_creation_after_restart_without_agent(self):
        self.args.publish = self.args.repair = True
        self.repairer.return_value = dict(status="awaiting_pr", head="a" * 40, base="b" * 40,
                                          pr_attempts=0, retry_after=0)
        self.complete_pr.side_effect = RuntimeError("temporary GitHub failure")
        state = self.process([observation()])
        candidate = next(iter(state["groups"].values()))["repair"]
        self.assertEqual(candidate["status"], "awaiting_pr")
        self.assertEqual(candidate["pr_attempts"], 1)
        disk = json.loads((self.args.state_dir / "state.json").read_text())
        self.complete_pr.side_effect = None
        with patch.object(jev.time, "time", return_value=candidate["retry_after"] + 1):
            state = self.process([], disk)
        self.repairer.assert_called_once()
        self.assertEqual(self.complete_pr.call_count, 2)
        self.assertEqual(next(iter(state["groups"].values()))["repair"]["status"], "draft_created")

    def test_private_acceptance_is_excluded_from_public_cards(self):
        jev.atomic_json(self.args.acceptance, dict(schema_version=1, status="defined", criteria=["PRIVATE_STANDARD"]))
        self.process([observation()])
        card = json.loads(next((self.args.state_dir / "cards").glob("*.json")).read_text())
        self.assertIn("PRIVATE_STANDARD", jev.card_markdown(card))
        self.assertNotIn("PRIVATE_STANDARD", jev.card_markdown(card, public=True))
        self.assertNotIn("PRIVATE_STANDARD", json.dumps(self.decision.call_args.args))

    def test_interrupted_last_pr_attempt_cannot_exceed_retry_budget(self):
        self.args.publish = self.args.repair = True
        self.repairer.return_value = dict(status="awaiting_pr", head="a" * 40, base="b" * 40,
                                          pr_attempts=3, retry_after=0)
        state = self.process([observation()])
        self.complete_pr.assert_not_called()
        self.assertEqual(next(iter(state["groups"].values()))["repair"]["status"], "needs_developer_review")


class RepairBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.worktree = self.root / "checkout"
        self.worktree.mkdir()
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Jev Tests")
        self.write("macos/Tests/FixtureTests.swift", "// base\n")
        self.write("AGENTS.md", "trusted rules\n")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.base = self.git("rev-parse", "HEAD").strip()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.worktree, text=True, stderr=subprocess.DEVNULL)

    def write(self, path, contents):
        target = self.worktree / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(contents)

    def test_valid_source_and_regression_are_staged(self):
        self.write("macos/Tests/FixtureTests.swift", "// regression\n")
        self.write("core/fix.go", "package core\n")
        self.assertTrue(jev.prepare_candidate(self.worktree, self.base))
        self.assertIn("core/fix.go", self.git("diff", "--cached", "--name-only"))

    def test_staged_protected_changes_cannot_escape_inspection(self):
        self.write("AGENTS.md", "bypass controls\n")
        self.git("add", "AGENTS.md")
        self.write("macos/Tests/FixtureTests.swift", "// regression\n")
        with self.assertRaisesRegex(RuntimeError, "protected"):
            jev.prepare_candidate(self.worktree, self.base)

    def test_deleted_protected_path_and_symlinks_are_rejected(self):
        self.git("rm", "-q", "AGENTS.md")
        with self.assertRaisesRegex(RuntimeError, "protected"):
            jev.prepare_candidate(self.worktree, self.base)
        self.git("reset", "--hard", "HEAD")
        (self.worktree / "macos/Tests/Secret.swift").symlink_to("/etc/hosts")
        with self.assertRaisesRegex(RuntimeError, "protected"):
            jev.prepare_candidate(self.worktree, self.base)

    def test_missing_regression_and_binary_are_rejected(self):
        self.write("core/fix.go", "package core\n")
        with self.assertRaisesRegex(RuntimeError, "regression"):
            jev.prepare_candidate(self.worktree, self.base)
        self.write("macos/Tests/FixtureTests.swift", "binary\0payload")
        with self.assertRaisesRegex(RuntimeError, "binary"):
            jev.prepare_candidate(self.worktree, self.base)

    def test_executable_mode_changes_are_rejected(self):
        self.write("macos/Tests/FixtureTests.swift", "// regression\n")
        (self.worktree / "macos/Tests/FixtureTests.swift").chmod(0o755)
        with self.assertRaisesRegex(RuntimeError, "permissions"):
            jev.prepare_candidate(self.worktree, self.base)

    def test_orchestrator_always_creates_draft_and_removes_credentials(self):
        card = dict(fingerprint="a" * 16, observation=jev.sanitized_observation(observation()),
                    decision=jev.parse_decision(response()), acceptance=dict(status="pending"))
        def fake_run(args, **kwargs):
            if args[:3] == ["gh", "issue", "view"]:
                return "OPEN"
            if args[:3] == ["git", "remote", "get-url"]:
                return "git@github.com:owner/repo.git"
            if args[:3] == ["gh", "pr", "list"]:
                return "[]"
            if args[:2] == ["git", "rev-parse"]:
                return "a" * 40
            if args[:2] == ["git", "ls-remote"]:
                return "a" * 40 + "\trefs/heads/jev/scenario-switch/" + card["fingerprint"]
            if args[:2] == ["codex", "exec"]:
                self.assertNotIn("OPENAI_API_KEY", kwargs["env"])
                self.assertNotIn("GH_TOKEN", kwargs["env"])
                self.assertIn("workspace-write", args)
                self.assertIn("sandbox_workspace_write.network_access=false", args)
            if args[:3] == ["gh", "pr", "create"]:
                self.assertIn("--draft", args)
                return "https://github.com/owner/repo/pull/2"
            return ""
        with patch.object(jev, "run", side_effect=fake_run), patch.object(jev, "prepare_candidate", return_value=True):
            result = jev.repair(card, "https://github.com/owner/repo/issues/1", "owner/repo", self.root)
            self.assertEqual(result["status"], "awaiting_pr")
            result = jev.complete_repair_pr(card["fingerprint"], result, "owner/repo", self.root)
        self.assertEqual(result["status"], "draft_created")

    def test_changed_remote_candidate_is_never_published(self):
        with patch.object(jev, "run", side_effect=["[]", "b" * 40 + "\trefs/heads/jev/scenario-switch/" + "c" * 16]) as run:
            with self.assertRaisesRegex(RuntimeError, "changed after validation"):
                jev.complete_repair_pr("c" * 16, dict(head="a" * 40, base="d" * 40), "owner/repo", self.root)
        self.assertFalse(any(call.args[0][:3] == ["gh", "pr", "create"] for call in run.call_args_list))


if __name__ == "__main__":
    unittest.main()
