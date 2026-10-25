import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/run-focused-tests.py"


class FocusedTestsEntryTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), "bounded focused entry point is required")
        spec = importlib.util.spec_from_file_location("focused_entry", SCRIPT)
        self.gate = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.gate)

    def test_no_test_or_missing_selected_suite_is_failure(self):
        valid = "Test Case '-[PhotoSyncCoreTests.EngineTests testExample]' passed (0.01 seconds).\nTest Suite 'Selected tests' passed\nExecuted 1 test, with 0 failures\n"
        self.assertEqual(self.gate.validate_selected_output(valid, ["EngineTests"]), 1)
        for output, required in [(valid, ["EngineTests", "StoreTests"]),
                                 (valid.replace("Executed 1 test", "Executed 0 tests"), ["EngineTests"]),
                                 (valid.replace("0 failures", "1 failure"), ["EngineTests"])]:
            with self.assertRaises(ValueError): self.gate.validate_selected_output(output, required)

    def test_unknown_suite_is_rejected_before_any_work(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--suite", "full-release"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid choice", result.stderr)


if __name__ == "__main__": unittest.main()
