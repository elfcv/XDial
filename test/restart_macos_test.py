import json
import os
import subprocess
import unittest
from pathlib import Path


class RestartReportGenerationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        default = Path(__file__).resolve().parents[1] / "scripts/restart-macos-app.sh"
        script = Path(os.environ.get("XDIAL_RESTART_SCRIPT_PATH", default)).read_text()
        # Execute the real shell function, without running any App lifecycle
        # operations or replacing Python/JSON parsing with a test double.
        function = script.split("state_fields() {", 1)[1].split("\n}\n", 1)[0]
        cls.command = "state_fields() {" + function + '\n}\nstate_fields "$1" "$2"'
        cls.failure_condition = script.split("\t\treport_failed=0\n", 1)[1].split(
            "\n\t\t# attempts_used", 1)[0]
        start = script.index('\t\tif [[ "${installation_state}" == "ready" ]]')
        cls.ready_condition = script[start:script.index('\n\tfi\n\tsleep', start)]

    def fields(self, transaction="new", started_at=1001, state="failed", baseline="old"):
        report = {"transaction_id": transaction, "started_at": started_at, "state": state}
        if state == "failed":
            report["error"] = {"code": "fixture-failure"}
        result = subprocess.run(
            ["bash", "-c", self.command, "restart-report-test", baseline, "1000"],
            input=json.dumps({"connectionReport": report}),
            capture_output=True, text=True, check=True)
        values = result.stdout.strip().split("|")
        self.assertEqual(len(values), 9)
        return values

    def rejected(self, values, baseline="old"):
        command = '''
report_state=$1
has_error=$2
report_is_new=$3
transaction_id=$4
baseline_transaction_id=$5
baseline_report_failed=0
report_failed=0
saw_failed_connection=0
''' + self.failure_condition + '\nprintf "%s" "$saw_failed_connection"'
        result = subprocess.run(
            ["bash", "-c", command, "restart-failure-test",
             values[4], values[5], values[8], values[7], baseline],
            capture_output=True, text=True, check=True)
        return result.stdout == "1"

    def accepted(self, values, installation="ready"):
        command = '''
installation_state=$1
desired_state=connected
engine_state=connected
report_state=$2
report_is_new=$3
is_busy=0
ready_state=""
for sample in fixture; do
''' + self.ready_condition + '\ndone\nprintf "%s" "$ready_state"'
        result = subprocess.run(
            ["bash", "-c", command, "restart-ready-test", installation,
             values[4], values[8]], capture_output=True, text=True, check=True)
        return result.stdout == "connected"

    def test_predecessor_teardown_failure_is_not_a_new_attempt(self):
        values = self.fields(transaction="old", started_at=937)
        self.assertEqual(values[4:6], ["failed", "1"])
        self.assertEqual(values[8], "0")
        self.assertFalse(self.rejected(values))

    def test_predecessor_id_is_not_new_even_with_recent_timestamp(self):
        self.assertEqual(self.fields(transaction="old")[8], "0")

    def test_different_historical_journal_is_not_a_new_attempt(self):
        values = self.fields(transaction="historical", started_at=900)
        self.assertEqual(values[8], "0")
        self.assertFalse(self.rejected(values))

    def test_current_failed_attempt_is_still_detected(self):
        values = self.fields()
        self.assertEqual(values[4:6], ["failed", "1"])
        self.assertEqual(values[8], "1")
        self.assertTrue(self.rejected(values))

    def test_current_commit_is_a_fresh_success(self):
        values = self.fields(state="committed")
        self.assertEqual(values[8], "1")
        self.assertTrue(self.accepted(values))

    def test_historical_commit_cannot_accept_the_new_start(self):
        values = self.fields(transaction="old", started_at=937, state="committed")
        self.assertFalse(self.accepted(values))

    def test_fresh_commit_cannot_accept_an_unfinished_installation(self):
        self.assertFalse(self.accepted(self.fields(state="committed"), installation="installing"))

    def test_no_baseline_still_requires_a_fresh_report(self):
        self.assertEqual(self.fields(baseline="", started_at=900)[8], "0")
        self.assertEqual(self.fields(baseline="")[8], "1")

    def test_missing_or_invalid_start_time_is_not_proof_of_a_new_attempt(self):
        for started_at in (None, "invalid", 0):
            with self.subTest(started_at=started_at):
                self.assertEqual(self.fields(started_at=started_at)[8], "0")


if __name__ == "__main__":
    unittest.main()
