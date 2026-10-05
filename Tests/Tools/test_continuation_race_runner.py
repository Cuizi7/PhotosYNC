import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


WORKTREE_ROOT = Path(__file__).resolve().parents[2]
RUNNER = WORKTREE_ROOT / "scripts" / "test-continuation-race.py"
FIXTURE = WORKTREE_ROOT / "Tests" / "Regression" / "ContinuationRace.swift"


class ContinuationRaceRunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.repository = self.root / "repository"
        self.script = self.repository / "scripts" / RUNNER.name
        self.fixture = self.repository / "Tests" / "Regression" / FIXTURE.name
        self.engine = self.repository / "Sources" / "PhotoSyncCore" / "Sync" / "SyncEngine.swift"
        self.fake_bin = self.root / "fake-bin"
        self.script.parent.mkdir(parents=True)
        self.fixture.parent.mkdir(parents=True)
        self.engine.parent.mkdir(parents=True)
        self.fake_bin.mkdir()
        shutil.copy2(RUNNER, self.script)
        shutil.copy2(FIXTURE, self.fixture)
        self.engine.write_text(self.engine_source(), encoding="utf-8")
        profile = self.repository / "docs/research/advanced-dedup/integration-profile.json"
        profile.parent.mkdir(parents=True)
        profile.write_text("{}", encoding="utf-8")
        self.write_fake_xcrun()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_success_requires_expected_green_and_red_fixture_results(self) -> None:
        output = self.root / "success"

        result = self.run_runner(output)

        self.assertEqual(result.returncode, 0, result.stderr)
        evidence = json.loads((output / "result.json").read_text(encoding="utf-8"))
        self.assertEqual(evidence["status"], "passed")
        self.assertEqual(evidence["runs"]["green"]["fixture_result"]["status"], "passed")
        red = evidence["runs"]["red"]["fixture_result"]
        self.assertEqual(red["assertion"], "post_resume_waiting_sources")
        self.assertEqual(red["observation"]["row_state"], "skipped")
        self.assertGreaterEqual(int(red["observation"]["waiting_sources"]), 1)

        preserved = (output / "result.json").read_bytes()
        repeated = self.run_runner(output)
        self.assertNotEqual(repeated.returncode, 0)
        self.assertEqual((output / "result.json").read_bytes(), preserved)

    def test_scenarios_instrument_and_mutate_only_the_selected_branch(self) -> None:
        source = self.engine_source()
        for scenario in ("stamp", "advanced-preparation"):
            with self.subTest(scenario=scenario):
                output = self.root / scenario
                result = self.run_runner(output, scenario=scenario)
                self.assertEqual(result.returncode, 0, result.stderr)
                evidence = json.loads((output / "result.json").read_text(encoding="utf-8"))
                self.assertEqual(evidence["scenario"], scenario)
                green = (output / "green/PhotoSyncCore/Sync/SyncEngine.swift").read_text()
                red = (output / "red/PhotoSyncCore/Sync/SyncEngine.swift").read_text()
                guard = "guard pendingStampFailureID == record.id else { continue }"
                self.assertEqual(green.count(guard), 2)
                self.assertEqual(red.count(guard), 1)
                self.assertIn("private var pendingStampFailureID: UUID?", red)
                self.assertIn("pendingStampFailureID == fileID", red)
                selected_method = "func retry(" if scenario == "stamp" else "func advancedRetry("
                selected = red.split(selected_method, 1)[1].split("\n    }", 1)[0]
                self.assertIn("await integrationRetryGate.wait()", selected)
                self.assertNotIn(guard, selected)
                self.assertEqual(self.engine.read_text(), source)
                command = json.loads((output / "green/run-command.json").read_text())
                self.assertEqual(command[-2:], ["--scenario", scenario])

    def test_anchor_mismatch_fails_without_pass_marker(self) -> None:
        self.engine.write_text("actor SyncEngine {}\n", encoding="utf-8")
        before = self.engine.read_bytes()
        output = self.root / "anchor-mismatch"

        result = self.run_runner(output)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("anchor", result.stderr.lower())
        self.assertFalse((output / "result.json").exists())
        self.assertEqual(self.failure(output)["status"], "failed")
        self.assertEqual(self.engine.read_bytes(), before)

    def test_duplicate_anchor_fails_without_mutating_source(self) -> None:
        source = self.engine_source()
        duplicate = "                            try await store.recordRetry(fileID: record.id, attemptID: nil, nextRetry: nextRetry(for: record), error: message, definitelyNotCommitted: true)\n"
        self.engine.write_text(source + duplicate, encoding="utf-8")
        before = self.engine.read_bytes()
        output = self.root / "duplicate-anchor"

        result = self.run_runner(output)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exactly once", result.stderr)
        self.assertFalse((output / "result.json").exists())
        self.assertEqual(self.engine.read_bytes(), before)

    def test_compile_failure_cannot_write_pass_marker(self) -> None:
        output = self.root / "compile-failure"

        result = self.run_runner(output, mode="compile-fail")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("compilation failed", self.failure(output)["error"])
        self.assertFalse((output / "result.json").exists())
        self.assertTrue((output / "green" / "compile.stderr.log").is_file())

    def test_hung_child_is_killed_and_cannot_write_pass_marker(self) -> None:
        output = self.root / "hung-child"
        started = time.monotonic()

        result = self.run_runner(output, mode="hung-child", timeout_seconds="0.2")

        self.assertNotEqual(result.returncode, 0)
        self.assertLess(time.monotonic() - started, 5)
        self.assertIn("timed out", self.failure(output)["error"])
        self.assertFalse((output / "result.json").exists())

    def test_nonfinite_timeout_is_rejected_before_creating_evidence(self) -> None:
        output = self.root / "nonfinite-timeout"

        result = self.run_runner(output, timeout_seconds="nan")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("finite", result.stderr)
        self.assertFalse(output.exists())

    def run_runner(
        self, output: Path, *, mode: str = "success", timeout_seconds: str = "2", scenario: str = "stamp"
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["PATH"] = f"{self.fake_bin}{os.pathsep}{environment['PATH']}"
        environment["FAKE_XCRUN_MODE"] = mode
        environment.pop("RQDATAC2_CONF", None)
        return subprocess.run(
            [sys.executable, str(self.script), "--output-dir", str(output), "--timeout-seconds", timeout_seconds, "--scenario", scenario],
            cwd=self.repository,
            env=environment,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )

    def failure(self, output: Path) -> dict[str, object]:
        return json.loads((output / "failure.json").read_text(encoding="utf-8"))

    def write_fake_xcrun(self) -> None:
        path = self.fake_bin / "xcrun"
        path.write_text(
            """#!/usr/bin/env python3
import os
from pathlib import Path
import sys

if len(sys.argv) < 2 or sys.argv[1] != \"swiftc\":
    raise SystemExit(90)
if os.environ.get(\"FAKE_XCRUN_MODE\") == \"compile-fail\":
    print(\"fake compiler failure\", file=sys.stderr)
    raise SystemExit(19)
arguments = sys.argv[2:]
try:
    output = Path(arguments[arguments.index(\"-o\") + 1])
except (ValueError, IndexError):
    raise SystemExit(91)
mode = os.environ.get(\"FAKE_XCRUN_MODE\", \"success\")
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(f\"\"\"#!/usr/bin/env python3
import json
from pathlib import Path
import sys
import time

mode = {mode!r}
if mode == \"hung-child\":
    time.sleep(30)
arguments = sys.argv[1:]
evidence = Path(arguments[arguments.index(\"--evidence-dir\") + 1])
evidence.mkdir(parents=True, exist_ok=True)
if \"red\" in Path(sys.argv[0]).parts:
    (evidence / \"fixture.json\").write_text(json.dumps({{\"status\": \"failed\", \"failure_stage\": \"assertion\", \"assertion\": \"post_resume_waiting_sources\", \"observation\": {{\"row_state\": \"skipped\", \"waiting_sources\": \"1\"}}}}))
    raise SystemExit(1)
(evidence / \"fixture.json\").write_text(json.dumps({{\"status\": \"passed\", \"observation\": {{}}}}))
\"\"\", encoding=\"utf-8\")
output.chmod(0o755)
""",
            encoding="utf-8",
        )
        path.chmod(0o755)

    def engine_source(self) -> str:
        return """import Foundation
actor SyncEngine {
    private var pendingStampFailureID: UUID?

    func retry(record: Record, message: String) async {
                        pendingStampFailureID = record.id
                        defer { pendingStampFailureID = nil }
                        do {
                            try await store.recordRetry(fileID: record.id, attemptID: nil, nextRetry: nextRetry(for: record), error: message, definitelyNotCommitted: true)
                        } catch let error as SyncStoreError {
                        }
                        guard pendingStampFailureID == record.id else { continue }
                        recordRoundFailure(context.roundID)
    }

    func advancedRetry(record: Record, error: Error) async {
                        pendingStampFailureID = record.id
                        defer { pendingStampFailureID = nil }
                        do {
                            try await store.recordRetry(fileID: record.id, attemptID: nil, nextRetry: nextRetry(for: record),
                                                        error: error.localizedDescription, definitelyNotCommitted: true)
                        } catch let storeError as SyncStoreError {
                        }
                        guard pendingStampFailureID == record.id else { continue }
                        recordRoundFailure(context.roundID)
    }

    private func recordRoundFailure(_ roundID: UUID, fileLevel: Bool = false) {}

    private func resolveSourceIssue(_ sourceID: UUID, key: String, runID: UUID? = nil, fileID: UUID? = nil, attemptID: UUID? = nil) {
        if let fileID, key == issueKey(for: fileID), pendingStampFailureID == fileID {
            pendingStampFailureID = nil
        }
    }
}
"""


if __name__ == "__main__":
    unittest.main()
