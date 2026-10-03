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
CONVERTER = ROOT / "scripts/advanced-dedup/convert-model.py"
CONVERTER_SPEC = importlib.util.spec_from_file_location("advanced_dedup_converter", CONVERTER)
converter = importlib.util.module_from_spec(CONVERTER_SPEC)
CONVERTER_SPEC.loader.exec_module(converter)
FIXTURE_MANIFEST = ROOT / "Tests/Fixtures/AdvancedDedup/manifest.json"
FIXTURE_HASH = json.loads(FIXTURE_MANIFEST.read_text())["content_sha256"]


class ResearchProtocolTests(unittest.TestCase):
    @staticmethod
    def acceptance_results(n=100, failures=0):
        protocol_path = ROOT / "docs/research/advanced-dedup/protocol.json"
        protocol = json.loads(protocol_path.read_text())
        protocol_sha = hashlib.sha256(protocol_path.read_bytes()).hexdigest()
        bindings = {name: "a" * 64 for name in ("protocolSHA256", "datasetSHA256",
                    "calibrationSHA256", "sealedResultsSHA256", "modelSHA256",
                    "preprocessSHA256", "profileSHA256")}
        bindings["protocolSHA256"] = protocol_sha
        sealed = {name: {"queries": minimum, "failedGroups": 0}
                  for name, minimum in protocol["minimum_queries_by_stratum"].items()}
        sealed["false_skip"] = {"queries": n, "failedGroups": failures}
        return protocol, {"bindings": bindings, "protocolSHA256": protocol_sha,
                          "expectedProtocolSHA256": protocol_sha, "artifactBytesVerified": True,
                          "calibrationFrozenBeforeSealed": True,
                          "conversion": {"maxAbsError": 0.001, "minCosine": 0.9999},
                          "sealedStatistics": {"bySplitAndStratum": {"sealed": sealed}},
                          "publicRegression": {"caseCount": 44, "passCount": 44,
                                               "contentFailures": [], "actionFailures": []},
                          "performance": {"scenarios": [
                              {"assetCount": 100000, "editedFraction": fraction,
                               "representationCount": int(100000 * (1 + fraction)),
                               "hotQueryP95MS": 100, "incrementalP95MS": 1000,
                               "hotQuerySamplesMS": [100] * 20,
                               "incrementalSamplesMS": [1000] * 20,
                               "peakRSSBytes": 1000000000, "realAssetCount": 100000,
                               "provenance": "audited-real-media",
                               "catalogDatasetSHA256": bindings["datasetSHA256"]}
                              for fraction in (0, 0.5, 1)]}}

    def testZeroErrorsCanStillFailConfidenceBound(self):
        protocol, results = self.acceptance_results()
        self.assertGreater(1 - 0.025 ** (1 / 100), 0.0001)
        verdict = research.verify_acceptance(protocol, results)
        self.assertEqual(verdict["reasons"], ["false_skip confidence bound", "false_skip independent minimum"])

    def testRejectsPerfectSafetyWithZeroRecall(self):
        protocol, results = self.acceptance_results(n=36887)
        results["sealedStatistics"]["bySplitAndStratum"]["sealed"]["renamed_metadata"]["failedGroups"] = 108
        verdict = research.verify_acceptance(protocol, results)
        self.assertEqual(verdict["reasons"], ["renamed_metadata recall bound"])

    def testGateRejectsChangedProtocolOrMissingMeasurements(self):
        protocol, results = self.acceptance_results(n=36887)
        results["expectedProtocolSHA256"] = "1" * 64
        results["performance"]["scenarios"][0].pop("hotQueryP95MS")
        verdict = research.verify_acceptance(protocol, results)
        self.assertEqual(verdict["reasons"], ["performance measurements incomplete", "protocol binding"])

    def testAnyFalseSkipFailsSealedGate(self):
        protocol, results = self.acceptance_results(n=100000, failures=1)
        verdict = research.verify_acceptance(protocol, results)
        self.assertEqual(verdict["reasons"], ["observed false skip"])

    def testAllocatedExactBoundsAtPredeclaredMinima(self):
        self.assertLessEqual(research._one_sided_error_upper(36887, 0, 0.025), 0.0001)
        self.assertGreater(research._one_sided_error_upper(36886, 0, 0.025), 0.0001)
        self.assertLessEqual(research._one_sided_error_upper(108, 0, 0.004), 0.05)
        self.assertGreater(research._one_sided_error_upper(107, 0, 0.004), 0.05)
        self.assertGreater(research._one_sided_error_upper(108, 1, 0.004), 0.05)

    def testGateRecomputesP95FromRawSamples(self):
        protocol, results = self.acceptance_results(n=36887)
        self.assertTrue(research.verify_acceptance(protocol, results)["pass"])
        results["performance"]["scenarios"][0]["hotQueryP95MS"] = 1
        verdict = research.verify_acceptance(protocol, results)
        self.assertEqual(verdict["reasons"], ["performance measurements incomplete"])

    def testAcceptanceCLIRequiresActualArtifactsBeforeWriting(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entry = self.entry(root, "negative", "family", "group", "sealed")
            dataset = root / "dataset.json"
            dataset.write_text(json.dumps({"root": str(root), "entries": [entry]}))
            results = root / "results.json"
            results.write_text("{}")
            output = root / "acceptance"
            result = subprocess.run([sys.executable, str(SCRIPT), "accept", "--protocol",
                                     str(ROOT / "docs/research/advanced-dedup/protocol.json"),
                                     "--dataset", str(dataset), "--results", str(results),
                                     "--output-dir", str(output)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("results.profile", result.stderr)
            self.assertFalse(output.exists())

    def testPositiveImportNeedsContentRecognition(self):
        protocol = json.loads((ROOT / "docs/research/advanced-dedup/protocol.json").read_text())
        dataset = {"entries": [{"query_id": "upgrade", "split": "sealed",
                                "stratum": "compression_downscale", "split_group": "family",
                                "expected_action": "importFile",
                                "expected_candidates": [{"id": "original"}]}]}
        swift = {"queries": [{"id": "upgrade", "action": "importFile",
                              "content": "notDuplicate", "matchedKeys": []}]}
        result = research.query_level_statistics(dataset, swift, protocol)
        self.assertEqual(result["bySplitAndStratum"]["sealed"]["compression_downscale"]["failedGroups"], 1)
        self.assertFalse(result["queryOutcomes"][0]["contentPass"])
        self.assertTrue(result["queryOutcomes"][0]["actionPass"])

    def testCandidateRecallNeedsRequiredCandidateIdentity(self):
        protocol = json.loads((ROOT / "docs/research/advanced-dedup/protocol.json").read_text())
        dataset = {"entries": [{"query_id": "retrieval", "split": "sealed",
                                "stratum": "candidate_recall", "split_group": "family",
                                "expected_action": "skip",
                                "expected_candidates": [{"id": "required"}]}]}
        swift = {"queries": [{"id": "retrieval", "action": "skip",
                              "content": "duplicate", "matchedKeys": ["unrelated"]}]}
        result = research.query_level_statistics(dataset, swift, protocol)
        self.assertEqual(result["bySplitAndStratum"]["sealed"]["candidate_recall"]["failedGroups"], 1)
        self.assertFalse(result["queryOutcomes"][0]["retrievalHit"])
        self.assertTrue(result["queryOutcomes"][0]["actionPass"])

    def testApprovedExactBackendIdentifier(self):
        protocol_path = ROOT / "docs/research/advanced-dedup/protocol.json"
        protocol = json.loads(protocol_path.read_text())
        resources = protocol["resources"]
        profile = {"fingerprint": {"version": "version", "modelSHA256": "a" * 64},
                   "policyVersion": "binding", "threshold": 0.8, "backend": "exact-f32-v1",
                   "resources": {"inferenceConcurrency": resources["inference_concurrency"],
                                 "batchSize": resources["batch_size"],
                                 "maxInFlightTasks": resources["max_in_flight_tasks"],
                                 "decodeConcurrency": resources["decode_concurrency"],
                                 "photoRequestConcurrency": resources["photo_request_concurrency"],
                                 "maxDecodedBytes": resources["max_decoded_bytes"],
                                 "catalogBatchSize": resources["catalog_batch_size"],
                                 "requestTimeoutSeconds": resources["request_timeout_seconds"],
                                 "retryDelaysSeconds": resources["retry_delays_seconds"],
                                 "progressPublishIntervalSeconds": resources["progress_publish_interval_seconds"]},
                   "evidenceCandidateLimit": resources["max_candidate_representations"],
                   "acceptanceID": "research:" + hashlib.sha256(protocol_path.read_bytes()).hexdigest()}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "profile.json"
            path.write_text(json.dumps(profile))
            self.assertEqual(research._validated_profile(path, profile["acceptanceID"][9:], protocol), profile)

    def testSavedPublicReportRetainsEveryVectorBinding(self):
        swift = {"protocolSHA256": "p", "queries": [{
            "id": "one", "queryVectorSHA256": "q", "candidates": [{
                "key": "candidate-only", "vectorSHA256": "c", "score": 0.9}],
            "content": "duplicate", "action": "skip", "matchedKeys": ["candidate-only"]}]}
        batch = {"queries": [{"id": "one", "vectorSHA256": "q", "candidates": [{
            "key": "candidate-only", "vectorSHA256": "c"}]}]}
        swift["batchSHA256"] = hashlib.sha256(json.dumps(batch, sort_keys=True).encode()).hexdigest()
        report = research.public_evaluation_evidence(swift, batch)
        self.assertEqual(report["swift"]["queries"][0]["candidates"][0]["vectorSHA256"], "c")
        self.assertEqual(report["swiftBatch"]["queries"][0]["candidates"][0]["vectorSHA256"], "c")
        self.assertEqual(report["swift"]["batchSHA256"], swift["batchSHA256"])
        altered = json.loads(json.dumps(report))
        altered["swiftBatch"]["queries"][0]["candidates"][0]["vectorSHA256"] = "tampered"
        with self.assertRaisesRegex(ValueError, "batch hash mismatch"):
            research.public_evaluation_evidence(altered["swift"], altered["swiftBatch"])

    def testZeroNegativeQueriesCannotPass(self):
        protocol = json.loads((ROOT / "docs/research/advanced-dedup/protocol.json").read_text())
        dataset = {"entries": [{"query_id": "one", "split": "sealed",
                                "stratum": "hard_copy", "split_group": "group-one",
                                "expected_action": "skip"}]}
        swift = {"queries": [{"id": "one", "action": "skip"}]}
        result = research.query_level_statistics(dataset, swift, protocol)
        self.assertFalse(result["pass"])
        self.assertGreater(result["sealedShortfalls"]["false_skip"], 0)

    def testRepeatedPairsCountAsOneIndependentQueryGroup(self):
        protocol = json.loads((ROOT / "docs/research/advanced-dedup/protocol.json").read_text())
        dataset = {"entries": [{"query_id": name, "split": "sealed",
                                "stratum": "false_skip", "split_group": "one-session",
                                "expected_action": "importFile"} for name in ("one", "two")]}
        swift = {"queries": [{"id": name, "action": "importFile",
                              "candidates": [{"key": "a"}, {"key": "b"}]}
                             for name in ("one", "two")]}
        result = research.query_level_statistics(dataset, swift, protocol)
        self.assertEqual(result["bySplitAndStratum"]["sealed"]["false_skip"]["queries"], 1)
        self.assertEqual(result["sealedShortfalls"]["false_skip"], 36886)

    def testScoreRequiresExplicitProfile(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "score", "--protocol",
                                 "protocol.json", "--dataset", "dataset.json",
                                 "--vectors", "vectors", "--output", "out.json"],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--profile", result.stderr)

    def test_conversion_manifest_hash_uses_relative_paths_and_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / "model.mlpackage"
            (package / "Data").mkdir(parents=True)
            (package / "Manifest.json").write_bytes(b"{}")
            (package / "Data" / "weights.bin").write_bytes(b"abc")
            expected = converter.package_sha256(package)
            self.assertEqual(len(expected), 64)
            (package / "Data" / "weights.bin").write_bytes(b"abd")
            self.assertNotEqual(converter.package_sha256(package), expected)

    def test_conversion_manifest_boundaries_are_unambiguous(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / "first.mlpackage"
            second = root / "second.mlpackage"
            first.mkdir()
            second.mkdir()
            (first / "a").write_bytes(b"x\0b\0y")
            (second / "a").write_bytes(b"x")
            (second / "b").write_bytes(b"y")
            self.assertEqual(converter.package_sha256(first),
                             "687b7c969279950d5afa6a2e23eade95c6b35c79bd5ed2abe9cab59f9bba70bd")
            self.assertEqual(converter.package_sha256(second),
                             "fc30ed02e8ac87e6272d4d692bb62d5e7580638df5052fa841943d848c5b373b")

    def test_probe_rejects_caller_override_of_approved_protocol(self):
        base = ["bash", str(ROOT / "scripts/advanced-dedup/run-probe.sh"), "compare-tensors",
                "--profile", "missing", "--model", "missing", "--tensor-list", "missing",
                "--output-dir", "missing"]
        for extra, reason in [(["--min-cosine", "-1"], "reserved"),
                              (["--protocol-sha256", "0" * 64], "reserved"),
                              (["--profile", "another"], "duplicate")]:
            with self.subTest(extra=extra):
                result = subprocess.run(base + extra, capture_output=True, text=True, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(reason, result.stderr)

    def test_conversion_rejects_missing_explicit_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = subprocess.run(
                [sys.executable, str(CONVERTER), "--weights", str(root / "missing.pt"),
                 "--expected-weights-sha256", "0" * 64,
                 "--license-file", str(root / "missing-license"),
                 "--upstream-revision", "test", "--upstream-url", "https://example.invalid",
                 "--precision", "float32",
                 "--output-package", str(root / "model.mlpackage"),
                 "--provenance", str(root / "record.json")],
                capture_output=True, text=True, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / "model.mlpackage").exists())

    def test_conversion_rejects_unverified_weight_identity_before_importing_toolchain(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "weights.pt").write_bytes(b"not-the-verified-checkpoint")
            (root / "LICENSE").write_text("MIT License\n")
            result = subprocess.run(
                [sys.executable, str(CONVERTER), "--weights", str(root / "weights.pt"),
                 "--expected-weights-sha256", "0" * 64,
                 "--license-file", str(root / "LICENSE"),
                 "--upstream-revision", "test", "--upstream-url", "https://example.invalid",
                 "--precision", "float32", "--output-package", str(root / "model.mlpackage"),
                 "--provenance", str(root / "record.json")],
                capture_output=True, text=True, check=False,
            )
            self.assertIn("weights SHA256", result.stderr)
            self.assertFalse((root / "model.mlpackage").exists())

    def test_model_provenance_records_research_boundary(self):
        record = json.loads((ROOT / "docs/research/advanced-dedup/model-provenance.json").read_text())
        self.assertEqual(record["weightsSHA256"], record["officialTorchScriptSHA256"])
        self.assertEqual(len(record["modelSHA256"]), 64)
        self.assertIn("manifest.v2", record["modelSHA256ManifestEncoding"])
        self.assertEqual(record["conversion"]["computePrecision"], "float32")
        self.assertEqual(record["runtimeComputeUnits"], "cpuOnly")
        self.assertEqual(record["modelWeightsRedistributionLicenseStatus"], "unresolved")
        self.assertTrue(record["conversionEquivalence"]["pass"])
        self.assertFalse(record["releaseAccepted"])
        self.assertFalse(record["publicFixtureProbe"]["classificationEvaluated"])

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

    def test_same_query_bytes_cannot_cross_calibration_and_sealed_labels(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = self.entry(root, "a", "family-a", "group-a", "calibration")
            second = self.entry(root, "b", "family-b", "group-b", "sealed")
            (root / "b").write_bytes((root / "a").read_bytes())
            second["sha256"] = first["sha256"]
            with self.assertRaisesRegex(ValueError, "byte identity"):
                research.validate_dataset({"root": str(root), "entries": [first, second]}, FIXTURE_HASH)

    def test_same_query_bytes_cannot_inflate_sealed_group_count(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = self.entry(root, "a", "family-a", "group-a", "sealed")
            second = self.entry(root, "b", "family-b", "group-b", "sealed")
            (root / "b").write_bytes((root / "a").read_bytes())
            second["sha256"] = first["sha256"]
            with self.assertRaisesRegex(ValueError, "byte identity"):
                research.validate_dataset({"root": str(root), "entries": [first, second]}, FIXTURE_HASH)

    def test_query_and_true_match_candidate_cannot_leak_across_splits_in_either_order(self):
        for reversed_order in (False, True):
            with self.subTest(reversed_order=reversed_order), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                calibration = self.entry(root, "calibration", "family-a", "group-a", "calibration")
                sealed = self.entry(root, "sealed", "family-b", "group-b", "sealed")
                sealed["stratum"] = "renamed_metadata"
                sealed["expected_action"] = "skip"
                sealed["expected_candidates"] = [self.candidate(root, "calibration", sealed)]
                entries = [sealed, calibration] if reversed_order else [calibration, sealed]
                with self.assertRaisesRegex(ValueError, "byte identity"):
                    research.validate_dataset({"root": str(root), "entries": entries}, FIXTURE_HASH)

    def test_true_match_candidate_bytes_cannot_cross_audited_identities(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = self.entry(root, "a", "family-a", "group-a", "calibration")
            second = self.entry(root, "b", "family-b", "group-b", "sealed")
            for entry in (first, second):
                entry["stratum"] = "renamed_metadata"
                entry["expected_action"] = "skip"
            (root / "shared").write_bytes(b"true-match-representation")
            first["expected_candidates"] = [self.candidate(root, "shared", first)]
            second["expected_candidates"] = [self.candidate(root, "shared", second)]
            with self.assertRaisesRegex(ValueError, "byte identity"):
                research.validate_dataset({"root": str(root), "entries": [first, second]}, FIXTURE_HASH)

    def test_same_audited_identity_can_reuse_query_and_candidate_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = self.entry(root, "a", "family", "group", "sealed")
            second = self.entry(root, "b", "family", "group", "sealed")
            for entry in (first, second):
                entry["stratum"] = "renamed_metadata"
                entry["expected_action"] = "skip"
                entry["expected_candidates"] = [self.candidate(root, "a", entry)]
            result = research.validate_dataset({"root": str(root), "entries": [first, second]}, FIXTURE_HASH)
            self.assertEqual(result["independent_queries_by_split_and_stratum"],
                             {"sealed": {"renamed_metadata": 1}})

    def test_unrelated_distractor_gallery_can_be_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gallery = self.entry(root, "gallery", "gallery-family", "gallery-group", "distractor")
            gallery_alias = self.entry(root, "gallery-alias", "another-gallery-family",
                                       "another-gallery-group", "distractor")
            (root / "gallery-alias").write_bytes((root / "gallery").read_bytes())
            gallery_alias["sha256"] = gallery["sha256"]
            calibration = self.entry(root, "a", "family-a", "group-a", "calibration")
            sealed = self.entry(root, "b", "family-b", "group-b", "sealed")
            # A repeated unrelated gallery representation has no true-match ownership.
            result = research.validate_dataset({"root": str(root),
                                                "entries": [gallery, calibration, gallery_alias, sealed]}, FIXTURE_HASH)
            self.assertEqual(result["independent_queries_by_split"],
                             {"calibration": 1, "sealed": 1})

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
                                              "origin_sha256": entry["origin_sha256"],
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
    def candidate(cls, root, path, entry):
        return {"id": path, "representation": "photosOriginal", "path": path,
                "sha256": hashlib.sha256((root / path).read_bytes()).hexdigest(),
                "origin_sha256": entry["origin_sha256"], "width": 10, "height": 10,
                "license_record": cls.license()}

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
