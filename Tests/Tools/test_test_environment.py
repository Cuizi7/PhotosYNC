import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/test-environment.py"


class TestEnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), "portable environment entry point must exist")
        spec = importlib.util.spec_from_file_location("test_environment_gate", SCRIPT)
        self.gate = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = self.gate
        spec.loader.exec_module(self.gate)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "Tests/Support").mkdir(parents=True)
        (self.root / "Tests/Fixtures/AdvancedDedup").mkdir(parents=True)
        self.file = self.root / "Tests/Fixtures/AdvancedDedup/fixture.bin"
        self.file.write_bytes(b"approved project test fixture")
        self.manifest = {"schemaVersion": 1, "pythonMinimum": [3, 10], "pillow": "12.3.0",
                         "files": {str(self.file.relative_to(self.root)): hashlib.sha256(self.file.read_bytes()).hexdigest()}}
        self.manifest_path = self.root / "Tests/Support/test-environment.json"
        self.manifest_path.write_text(json.dumps(self.manifest))

    def test_registered_corpus_is_checked_independent_of_ci(self):
        result = self.gate.verify_inputs(self.root)
        self.assertEqual(result["files_checked"], 1)
        self.file.write_bytes(b"unapproved change")
        with self.assertRaisesRegex(ValueError, "SHA256"):
            self.gate.verify_inputs(self.root)

    def test_external_dataset_and_symlink_cannot_enter_default_gate(self):
        with self.assertRaisesRegex(ValueError, "dataset"):
            self.gate.verify_inputs(self.root, requested_dataset="/private/production-copy")
        outside = self.root / "outside.bin"
        outside.write_bytes(self.file.read_bytes())
        self.file.unlink()
        self.file.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.gate.verify_inputs(self.root)

    def test_manifest_parent_escape_is_rejected(self):
        self.manifest["files"]["../private.sqlite"] = "0" * 64
        self.manifest_path.write_text(json.dumps(self.manifest))
        with self.assertRaisesRegex(ValueError, "relative"):
            self.gate.verify_inputs(self.root)

    def test_prepare_root_is_owned_work_directory_and_not_symlink(self):
        good = self.root / "work/test-env"
        self.gate.validate_prepare_root(self.root, good)
        with self.assertRaisesRegex(ValueError, "work"):
            self.gate.validate_prepare_root(self.root, self.root / "Library")
        (self.root / "work").mkdir()
        (self.root / "work/alias").symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.gate.validate_prepare_root(self.root, self.root / "work/alias/new")

    def test_deadline_stops_owned_child_and_does_not_accept_timeout(self):
        import time
        start = time.monotonic()
        with self.assertRaisesRegex(TimeoutError, "deadline"):
            self.gate.run_bounded([sys.executable, "-c", "import time; time.sleep(10)"],
                                  cwd=self.root, deadline=start + 0.1)
        self.assertLess(time.monotonic() - start, 2)

    def test_model_pointer_is_not_treated_as_downloaded_weights(self):
        self.file.write_text("version https://git-lfs.github.com/spec/v1\n")
        with self.assertRaisesRegex(ValueError, "SHA256"):
            self.gate.verify_inputs(self.root)

    def test_prepare_hydrates_lfs_without_installed_git_filters(self):
        weight = self.root / self.gate.MODEL_WEIGHT
        weight.parent.mkdir(parents=True)
        data = b"synthetic model for isolated LFS checkout"
        identity = hashlib.sha256(data).hexdigest()
        weight.write_text(f"version https://git-lfs.github.com/spec/v1\noid sha256:{identity}\nsize {len(data)}\n")
        (self.root / ".gitattributes").write_text(str(self.gate.MODEL_WEIGHT) + " filter=lfs diff=lfs merge=lfs -text\n")
        self.manifest["files"] = {str(self.gate.MODEL_WEIGHT):identity}
        self.manifest_path.write_text(json.dumps(self.manifest))
        isolated = {"GIT_CONFIG_GLOBAL":os.devnull,"GIT_CONFIG_SYSTEM":os.devnull}
        with patch.dict(os.environ, isolated):
            for args in (["init","-q"], ["add",".gitattributes",str(self.gate.MODEL_WEIGHT)],
                         ["-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","-qm","fixture"]):
                subprocess.run(["git",*args],cwd=self.root,check=True,capture_output=True)
            object_path = self.root / ".git/lfs/objects" / identity[:2] / identity[2:4] / identity
            object_path.parent.mkdir(parents=True); object_path.write_bytes(data)
            original = self.gate.run_bounded
            def run(command, **kwargs):
                if "checkout" in command: return original(command, **kwargs)
                if command[:3] == ["git","rev-parse","HEAD"]: return "synthetic-commit"
                return ""  # Network and pip are separate contracts; only checkout is real here.
            with patch.object(self.gate,"run_bounded",side_effect=run):
                self.gate.prepare(self.root, self.root / "work/prepared")
            self.assertEqual(weight.read_bytes(),data)
            config = subprocess.run(["git","config","--local","--get-regexp","filter.lfs"],cwd=self.root,capture_output=True,text=True)
            self.assertEqual(config.stdout, "", "Preparation must not modify repository Git configuration")


if __name__ == "__main__":
    unittest.main()
