import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("portable_validator", ROOT / "scripts/validate.py")
gate = importlib.util.module_from_spec(spec); sys.modules[spec.name] = gate; spec.loader.exec_module(gate)


class PortableValidationContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_scenarios_require_named_passes_not_aggregate_count(self):
        scenario = {"schemaVersion":1, "scenarios":[{"id":"R01", "tests":["StartupTests/testRestart"]}]}
        manifest = self.root / "scenarios.json"; manifest.write_text(json.dumps(scenario))
        swift = self.root / "swift.log"; tools = self.root / "tools.log"; tools.write_text("Ran 10 tests\nOK\n")
        swift.write_text("All tests passed\nExecuted 900 tests, with 0 failures\n")
        with self.assertRaises(gate.ValidationError): gate.validate_runtime_scenarios(manifest, swift, tools)
        swift.write_text("Test Case '-[PhotoSyncCoreTests.StartupTests testRestart]' passed (0.2 seconds).\n")
        self.assertEqual(gate.validate_runtime_scenarios(manifest, swift, tools), ["R01"])
        scenario["scenarios"].append(scenario["scenarios"][0]); manifest.write_text(json.dumps(scenario))
        with self.assertRaises(gate.ValidationError): gate.validate_runtime_scenarios(manifest, swift, tools)

    def test_unknown_skip_is_rejected_even_when_all_tests_pass(self):
        log = self.root / "test.log"
        log.write_text("Test Case '-[PhotoSyncCoreTests.NewTests testBroken]' skipped (0.1 seconds).\nTest Suite 'All tests' passed\nExecuted 9 tests, with 1 test skipped and 0 failures\n")
        with self.assertRaises(gate.ValidationError): gate.validate_xctest_summary(log)

    def test_overall_deadline_cannot_be_extended_by_a_long_phase(self):
        log = self.root / "deadline.log"
        started = time.monotonic()
        with self.assertRaises(gate.PhaseFailure):
            gate.run_command([sys.executable,"-c","import time; time.sleep(10)"], cwd=self.root,
                environment=gate.child_environment(), log_path=log, timeout_seconds=10, label="deadline probe", deadline=started + 0.1)
        self.assertLess(time.monotonic() - started, 2)

    def test_focused_evidence_cannot_satisfy_canonical_or_native(self):
        evidence = {"status":"passed", "scope":"focused", "ui_profile":"none"}
        with self.assertRaises(gate.ValidationError): gate.validate_portable_evidence(evidence, self.root, expected_ui_profile="none")
        evidence["scope"] = "canonical"
        with self.assertRaises(gate.ValidationError): gate.validate_portable_evidence(evidence, self.root, expected_ui_profile="native")

    def test_packaging_controller_enforces_shortened_phase_deadline(self):
        code = "import os,time; from pathlib import Path; Path(os.environ['PHOTOSYNC_PACKAGE_DEADLINE_FILE']).write_text(str(time.monotonic()+0.1)); time.sleep(10)"
        started = time.monotonic()
        result = subprocess.run([sys.executable,str(ROOT / "scripts/run-bounded.py"),"--timeout","10","--package","--",sys.executable,"-c",code], capture_output=True, text=True)
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertLess(time.monotonic() - started, 2)

    def test_default_environment_cannot_inherit_private_replay_or_child_controls(self):
        unsafe = {key:"/private/previous-diagnostic" for key in ("PHOTOSYNC_SQLITE_REPLAY_BATCH", "PHOTOSYNC_SQLITE_REPLAY_PROFILE",
            "PHOTOSYNC_SYNTHETIC_PHASE", "PHOTOSYNC_SYNTHETIC_SESSION", "PHOTOSYNC_SYNTHETIC_CHECKPOINT",
            "PHOTOSYNC_MODEL_CACHE_DIR", "PHOTOSYNC_ACCEPTANCE_OUTPUT", "PHOTOSYNC_UI_OUTPUT")}
        with patch.dict(os.environ, {**unsafe, "PHOTOSYNC_VALIDATION_DEADLINE":"123.5", "PHOTOSYNC_REGRESSION_DATASET":"/wrong-input"}):
            environment = gate.child_environment()
        self.assertTrue(set(unsafe).isdisjoint(environment))
        self.assertEqual(environment["PHOTOSYNC_VALIDATION_DEADLINE"], "123.5")
        self.assertEqual(environment["PHOTOSYNC_REGRESSION_DATASET"], "/wrong-input", "External corpus must be rejected by the input gate, not silently ignored")

    def test_interrupted_validation_reaps_its_independent_child_session(self):
        worker = self.root / "worker.py"; marker = self.root / "child.pid"
        child = "import os,time;from pathlib import Path;Path(" + repr(str(marker)) + ").write_text(str(os.getpid()));time.sleep(30)"
        worker.write_text("import importlib.util,sys,signal\nfrom pathlib import Path\n"
            "s=importlib.util.spec_from_file_location('cancel_gate'," + repr(str(ROOT / "scripts/validate.py")) + ")\n"
            "g=importlib.util.module_from_spec(s);sys.modules[s.name]=g;s.loader.exec_module(g)\n"
            "def stop(*args): raise KeyboardInterrupt()\nsignal.signal(signal.SIGTERM,stop)\n"
            "g.run_command([sys.executable,'-c'," + repr(child) + "],cwd=Path(" + repr(str(self.root)) + "),environment=g.child_environment(),log_path=Path(" + repr(str(self.root / "child.log")) + "),timeout_seconds=30,label='owned child')\n")
        process = subprocess.Popen([sys.executable, str(worker)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        child_pid = None
        try:
            deadline = time.monotonic() + 3
            while not marker.exists() and time.monotonic() < deadline and process.poll() is None: time.sleep(0.01)
            self.assertTrue(marker.exists(), "Child did not reach test barrier")
            child_pid = int(marker.read_text())
            process.terminate(); process.wait(timeout=3)
            with self.assertRaises(ProcessLookupError): os.kill(child_pid, 0)
        finally:
            if process.poll() is None: process.kill(); process.wait(timeout=1)
            if child_pid:
                try: os.killpg(child_pid, signal.SIGKILL)
                except ProcessLookupError: pass


if __name__ == "__main__": unittest.main()
