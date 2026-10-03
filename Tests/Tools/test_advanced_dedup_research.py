import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/advanced-dedup/research.py"
SPEC = importlib.util.spec_from_file_location("advanced_dedup_research", SCRIPT)
research = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(research)
FIXTURE_MANIFEST = ROOT / "Tests/Fixtures/AdvancedDedup/manifest.json"
FIXTURE_HASH = json.loads(FIXTURE_MANIFEST.read_text())["content_sha256"]


class ResearchProtocolTests(unittest.TestCase):
    def test_protocol_has_no_implicit_targets(self):
        with self.assertRaises(ValueError):
            research.validate_protocol({})

    def test_approved_protocol_binds_stricter_false_skip_target(self):
        document = json.loads((ROOT / "docs/research/advanced-dedup/protocol.json").read_text())
        result = research.validate_protocol(document)
        self.assertTrue(result["approved"])
        self.assertEqual(document["max_false_skip_upper_bound"], 0.0001)
        self.assertEqual(result["minimum_queries_by_stratum"]["false_skip"], 36887)
        self.assertEqual(result["sampling_unit"], "split_group")

    def test_unapproved_protocol_remains_a_valid_draft(self):
        document = json.loads((ROOT / "docs/research/advanced-dedup/protocol.json").read_text())
        document["approved"] = False
        document.pop("approval", None)
        self.assertFalse(research.validate_protocol(document)["approved"])

    def test_alpha_allocation_and_sample_size_cannot_be_weakened(self):
        document = json.loads((ROOT / "docs/research/advanced-dedup/protocol.json").read_text())
        document["approved"] = False
        del document["approval"]
        document["alpha_allocation_by_stratum"]["false_skip"] = 0.05
        with self.assertRaisesRegex(ValueError, "alpha"):
            research.validate_protocol(document)
        document["alpha_allocation_by_stratum"]["false_skip"] = 0.025
        document["minimum_queries_by_stratum"]["false_skip"] = 1
        with self.assertRaisesRegex(ValueError, "minimum_queries"):
            research.validate_protocol(document)

    def test_approval_needs_binding_record(self):
        document = json.loads((ROOT / "docs/research/advanced-dedup/protocol.json").read_text())
        del document["approval"]
        with self.assertRaisesRegex(ValueError, "approval"):
            research.validate_protocol(document)

    def test_approval_records_which_targets_user_chose(self):
        document = json.loads((ROOT / "docs/research/advanced-dedup/protocol.json").read_text())
        del document["approval"]["approved_fields"]
        with self.assertRaisesRegex(ValueError, "approved_fields"):
            research.validate_protocol(document)

    def test_approval_binding_rejects_later_resource_change(self):
        document = json.loads((ROOT / "docs/research/advanced-dedup/protocol.json").read_text())
        document["resources"]["max_in_flight_tasks"] = 3
        with self.assertRaisesRegex(ValueError, "approval"):
            research.validate_protocol(document)

    def test_protocol_resources_include_timeout_retry_and_publish_limits(self):
        document = json.loads((ROOT / "docs/research/advanced-dedup/protocol.json").read_text())
        document["approved"] = False
        del document["approval"]
        del document["resources"]["request_timeout_seconds"]
        with self.assertRaisesRegex(ValueError, "request_timeout_seconds"):
            research.validate_protocol(document)

    def test_family_leakage_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entries = [self.entry(root, "a", "family", "session", "calibration"),
                       self.entry(root, "b", "family", "session", "sealed")]
            with self.assertRaisesRegex(ValueError, "split"):
                research.validate_dataset({"root": str(root), "entries": entries}, FIXTURE_HASH)

    def test_split_group_leakage_rejected_across_families(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entries = [self.entry(root, "a", "family-a", "session", "calibration"),
                       self.entry(root, "b", "family-b", "session", "sealed")]
            with self.assertRaisesRegex(ValueError, "split"):
                research.validate_dataset({"root": str(root), "entries": entries}, FIXTURE_HASH)

    def test_public_fixture_is_not_a_sealed_set(self):
        public = json.loads(FIXTURE_MANIFEST.read_text())["images"][0]
        with self.assertRaisesRegex(ValueError, "public"):
            research.validate_dataset({
                "root": str(FIXTURE_MANIFEST.parent),
                "entries": [{"query_id": "sealed-1", "family_id": "family-1",
                             "split_group": "group-1", "split": "sealed", "stratum": "false_skip",
                             "path": public["file"], "sha256": public["sha256"],
                             "origin_sha256": hashlib.sha256(b"independent-source").hexdigest(),
                             "license_record": self.license(), "expected_candidates": [],
                             "expected_action": "importFile"}],
            }, FIXTURE_HASH)

    def test_public_corpus_content_hash_cannot_label_a_sealed_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entry = self.entry(root, "a", "family", "group", "sealed")
            with self.assertRaisesRegex(ValueError, "public"):
                research.validate_dataset({"root": str(root), "content_sha256": FIXTURE_HASH,
                                           "entries": [entry]}, FIXTURE_HASH)

    def test_public_lineage_cannot_enter_sealed_set_with_new_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entry = self.entry(root, "new-byte-variant", "cc-01-1", "strawberry-session", "sealed")
            with self.assertRaisesRegex(ValueError, "public"):
                research.validate_dataset({"root": str(root), "entries": [entry]}, FIXTURE_HASH)

    def test_public_manifest_content_hash_is_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entry = self.entry(root, "a", "family", "group", "sealed")
            altered = json.loads(FIXTURE_MANIFEST.read_text())
            altered["images"][0]["sha256"] = "0" * 64
            altered_path = root / "altered-manifest.json"
            altered_path.write_text(json.dumps(altered))
            with patch.object(research, "PUBLIC_MANIFEST", altered_path):
                with self.assertRaisesRegex(ValueError, "public manifest"):
                    research.validate_dataset({"root": str(root), "entries": [entry]}, FIXTURE_HASH)

    def test_cli_reports_sealed_shortfalls_without_disclosing_content(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entry = self.entry(root, "secret-byte-name", "family", "group", "sealed")
            dataset = root / "dataset.json"
            dataset.write_text(json.dumps({"root": str(root), "entries": [entry]}))
            command = [sys.executable, str(SCRIPT), "check-protocol", "--protocol",
                       str(ROOT / "docs/research/advanced-dedup/protocol.json"),
                       "--dataset", str(dataset)]
            result = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            output = json.loads(result.stdout)
            self.assertFalse(output["sealed_minimums_met"])
            self.assertEqual(output["sealed_shortfalls"]["false_skip"], 36886)
            self.assertNotIn("secret-byte-name", result.stdout)

    def test_origin_hash_cannot_be_relabelled_across_splits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = self.entry(root, "a", "family-a", "group-a", "calibration")
            second = self.entry(root, "b", "family-b", "group-b", "sealed")
            second["origin_sha256"] = first["origin_sha256"]
            with self.assertRaisesRegex(ValueError, "origin"):
                research.validate_dataset({"root": str(root), "entries": [first, second]}, FIXTURE_HASH)

    def test_repeat_variants_do_not_increase_independent_query_count(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entries = [self.entry(root, f"v{i}", "family", "session", "sealed")
                       for i in range(10)]
            result = research.validate_dataset({"root": str(root), "entries": entries}, FIXTURE_HASH)
            self.assertEqual(result["independent_queries_by_split"], {"sealed": 1})
            self.assertEqual(result["independent_queries_by_split_and_stratum"],
                             {"sealed": {"false_skip": 1}})

    def test_hash_and_license_evidence_are_required(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entry = self.entry(root, "a", "family", "session", "calibration")
            entry["sha256"] = "0" * 64
            with self.assertRaisesRegex(ValueError, "SHA256"):
                research.validate_dataset({"root": str(root), "entries": [entry]}, FIXTURE_HASH)
            entry["sha256"] = hashlib.sha256((root / "a").read_bytes()).hexdigest()
            entry["license_record"] = {}
            with self.assertRaisesRegex(ValueError, "license"):
                research.validate_dataset({"root": str(root), "entries": [entry]}, FIXTURE_HASH)

    def test_candidate_representation_has_real_dimensions_and_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entry = self.entry(root, "a", "family", "session", "sealed")
            entry["expected_candidates"] = [{"id": "c", "representation": "photosOriginal",
                                              "path": "a", "sha256": entry["sha256"],
                                              "width": 0, "height": 10,
                                              "license_record": self.license()}]
            with self.assertRaisesRegex(ValueError, "width"):
                research.validate_dataset({"root": str(root), "entries": [entry]}, FIXTURE_HASH)

    def test_malformed_dataset_field_types_fail_as_validation_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entry = self.entry(root, "a", "family", "group", "sealed")
            with self.assertRaises(ValueError):
                research.validate_dataset({"root": 7, "entries": [entry]}, FIXTURE_HASH)
            entry["stratum"] = []
            with self.assertRaises(ValueError):
                research.validate_dataset({"root": str(root), "entries": [entry]}, FIXTURE_HASH)

    def test_positive_stratum_requires_candidate_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entry = self.entry(root, "copy", "copy-family", "copy-group", "sealed")
            entry["stratum"] = "renamed_metadata"
            with self.assertRaisesRegex(ValueError, "expected_candidates"):
                research.validate_dataset({"root": str(root), "entries": [entry]}, FIXTURE_HASH)

    def test_false_skip_stratum_cannot_contain_expected_skip(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entry = self.entry(root, "a", "family", "group", "sealed")
            entry["expected_action"] = "skip"
            with self.assertRaisesRegex(ValueError, "false_skip"):
                research.validate_dataset({"root": str(root), "entries": [entry]}, FIXTURE_HASH)

    @staticmethod
    def license():
        return {"license": "self-created", "source": "unit fixture", "permission": "local test"}

    @classmethod
    def entry(cls, root, query_id, family_id, split_group, split):
        payload = query_id.encode()
        (root / query_id).write_bytes(payload)
        return {"query_id": query_id, "family_id": family_id,
                "split_group": split_group, "split": split, "stratum": "false_skip", "path": query_id,
                "sha256": hashlib.sha256(payload).hexdigest(),
                "origin_sha256": hashlib.sha256(family_id.encode()).hexdigest(),
                "license_record": cls.license(), "expected_candidates": [],
                "expected_action": "importFile"}


if __name__ == "__main__":
    unittest.main()
