"""Release boundaries use synthetic objects; never load the private corpus here."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
import hashlib
import subprocess
import shutil
import json

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "dedup_release", ROOT / "scripts/advanced-dedup/release.py"
)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class AdvancedDedupReleaseTests(unittest.TestCase):
    def test_execution_policy_rejects_cpu_io_threshold_and_tensor_corruption(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            original = ROOT / release.RESOURCE_PATH
            shutil.copyfile(original / "execution-policy.json", root / "execution-policy.json")
            shutil.copytree(original / "ModelSelfTest", root / "ModelSelfTest")
            policy_path = root / "execution-policy.json"
            original_policy = policy_path.read_bytes()
            release.verify_execution_resources(root)
            for key, value in [("arm64", ["cpuOnly"]), ("x86_64", ["all"]),
                               ("inputType", "float16"), ("outputType", "float16"),
                               ("allowLowPrecisionAccumulationOnGPU", True), ("retryIntervalSeconds", 1),
                               ("modelSHA256", "0" * 64), ("selfTestManifestSHA256", "0" * 64)]:
                policy = json.loads(original_policy); policy[key] = value
                policy_path.write_text(json.dumps(policy))
                with self.assertRaises(ValueError, msg=key): release.verify_execution_resources(root)
            policy_path.write_bytes(original_policy)
            manifest_path = root / "ModelSelfTest/manifest.json"
            manifest = json.loads(manifest_path.read_bytes()); manifest["maxAbsError"] = 0.03
            manifest_path.write_text(json.dumps(manifest))
            with self.assertRaises(ValueError): release.verify_execution_resources(root)
            shutil.copyfile(original / "ModelSelfTest/manifest.json", manifest_path)
            tensor = root / "ModelSelfTest/input-0.f32"
            tensor.write_bytes(b"corrupt")
            with self.assertRaises(ValueError): release.verify_execution_resources(root)
            shutil.copyfile(original / "ModelSelfTest/input-0.f32", tensor)
            tensor.unlink(); tensor.symlink_to(original / "ModelSelfTest/input-0.f32")
            with self.assertRaises(ValueError): release.verify_execution_resources(root)


    def test_hydration_requires_exact_archive_pointer_and_local_object(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo, archive = root / "repo", root / "archive"
            repo.mkdir()
            archive.mkdir()

            def git(*args):
                return subprocess.check_output(["git", "-C", str(repo), *args])

            git("init", "-q")
            data = b"synthetic model bytes"
            oid = hashlib.sha256(data).hexdigest()
            pointer = f"version https://git-lfs.github.com/spec/v1\noid sha256:{oid}\nsize {len(data)}\n".encode()
            (repo / "weight.bin").write_bytes(pointer)
            git("add", "weight.bin")
            git(
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.invalid",
                "commit",
                "-qm",
                "fixture",
            )
            commit = git("rev-parse", "HEAD").decode().strip()
            target = archive / "weight.bin"
            target.write_bytes(pointer)
            objects = repo / ".git/lfs/objects"
            obj = objects / oid[:2] / oid[2:4] / oid
            with self.assertRaisesRegex(ValueError, "missing"):
                release.hydrate_file(repo, commit, archive, "weight.bin", objects)
            obj.parent.mkdir(parents=True)
            obj.write_bytes(b"corrupt")
            with self.assertRaisesRegex(ValueError, "identity"):
                release.hydrate_file(repo, commit, archive, "weight.bin", objects)
            obj.write_bytes(data)
            target.write_bytes(pointer.replace(b"size ", b"size 1"))
            with self.assertRaisesRegex(ValueError, "archived pointer"):
                release.hydrate_file(repo, commit, archive, "weight.bin", objects)
            target.write_bytes(pointer)
            release.hydrate_file(repo, commit, archive, "weight.bin", objects)
            self.assertEqual(target.read_bytes(), data)

    def test_release_requires_bound_records_model_and_license(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaises(ValueError):
                release.verify_resources(root)
            for name in release.RECORD_HASHES:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("{}")
            with self.assertRaises(ValueError):
                release.verify_resources(root)

    def test_actual_bound_bytes_reject_missing_license_model_and_changed_profile(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "resources"
            shutil.copytree(ROOT / release.RESOURCE_PATH, root)
            self.assertEqual(release.verify_resources(root)["status"], "passed")
            for name in [
                "profile.json",
                "decision.json",
                "LICENSE-SSCD.txt",
                "model-provenance.json",
                str(Path(release.MODEL) / release.WEIGHT),
            ]:
                path = root / name
                held = root.parent / "held"
                path.rename(held)
                with self.assertRaises(ValueError):
                    release.verify_resources(root)
                held.rename(path)
            profile = root / "profile.json"
            profile.write_bytes(profile.read_bytes() + b" ")
            with self.assertRaisesRegex(ValueError, "SHA256"):
                release.verify_resources(root)

    def test_built_app_rejects_payloads_outside_model_folder(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "App.app"
            resources = app / "Contents/Resources"
            resources.mkdir(parents=True)
            for name in [
                "private.jpg",
                "vectors.bin",
                "preview.html",
                "raw-research.csv",
            ]:
                payload = resources / name
                payload.write_bytes(b"synthetic forbidden payload")
                with self.assertRaisesRegex(ValueError, "Unexpected"):
                    release.verify_app(app)
                payload.unlink()

    def test_unlisted_images_or_research_material_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for extra in [
                "private.jpg",
                "vectors.bin",
                "preview.html",
                "research/report.json",
            ]:
                path = root / extra
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"not allowed")
                with self.assertRaisesRegex(ValueError, "Unexpected"):
                    release.verify_allowed_files(root)
                path.unlink()
