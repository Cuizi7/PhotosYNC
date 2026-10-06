import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import shutil
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


class ProbeBridgeCacheTests(unittest.TestCase):
    def test_c_header_modulemap_and_flags_invalidate_cached_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            driver = root / "scripts/advanced-dedup/run-probe.sh"
            driver.parent.mkdir(parents=True)
            shutil.copy2(ROOT / "scripts/advanced-dedup/run-probe.sh", driver)
            shutil.copy2(SCRIPT, driver.parent / "research.py")
            protocol = root / "docs/research/advanced-dedup/protocol.json"
            protocol.parent.mkdir(parents=True)
            shutil.copy2(ROOT / "docs/research/advanced-dedup/protocol.json", protocol)
            bridge = root / "Sources/PhotoSyncCore/Storage/SQLiteVectorQuery"
            bridge.mkdir(parents=True)
            files = [bridge / name for name in ("SQLiteVectorQuery.c", "SQLiteVectorQuery.h", "module.modulemap")]
            for path in files:
                path.write_text("initial input\n")
            (bridge.parents[1] / "Dummy.swift").write_text("// fake source\n")
            main = root / "Tools/AdvancedDedupProbe/main.swift"
            main.parent.mkdir(parents=True); main.write_text("// fake source\n")
            profile = root / "profile.json"; profile.write_text("{}")
            fake_bin = root / "fake-bin"; fake_bin.mkdir()
            compiler = fake_bin / "xcrun"
            compiler.write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
args = sys.argv[1:]
if args[0] == "--sdk" or "--version" in args:
    print("fixed test compiler and SDK")
    raise SystemExit(0)
output = Path(args[args.index("-o") + 1])
if args[0] == "clang":
    assert "-fno-fast-math" in args and "-ffp-contract=off" in args
    output.write_bytes(b"fake object")
elif args[0] == "swiftc":
    assert any(value.endswith(".o") for value in args)
    counter = Path(os.environ["PHOTOSYNC_TEST_COMPILATIONS"])
    counter.write_text(str(int(counter.read_text()) + 1) if counter.exists() else "1")
    output.write_text("#!/bin/sh\\nexit 0\\n"); output.chmod(0o755)
else:
    raise SystemExit(91)
''')
            compiler.chmod(0o755)
            counter = root / "compile-count"
            environment = dict(os.environ, PATH=str(fake_bin) + os.pathsep + os.environ["PATH"],
                               PHOTOSYNC_TEST_COMPILATIONS=str(counter))
            def run():
                result = subprocess.run(["bash", str(driver), "validate-profile", "--profile", str(profile),
                                         "--output-dir", str(root / "out")], env=environment, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                return int(counter.read_text())
            self.assertEqual(run(), 1)
            self.assertEqual(run(), 1)
            for expected, path in enumerate(files, 2):
                path.write_text(path.read_text() + "changed input\n")
                self.assertEqual(run(), expected, path.name)
            driver.write_text(driver.read_text().replace("-O3", "-O2"))
            self.assertEqual(run(), 5)


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
                          "sealedOutcomes": [{"split": "sealed", "stratum": "false_skip",
                                              "expectedAction": "importFile", "observedAction": "importFile"}],
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

    def testPositiveUpgradeWrongSkipFailsAcrossStrata(self):
        protocol, results = self.acceptance_results(n=36887)
        entry = {"query_id": "upgrade", "split": "sealed", "stratum": "compression_downscale",
                 "split_group": "one", "expected_action": "importFile",
                 "expected_candidates": [{"id": "original"}]}
        observed = {"queries": [{"id": "upgrade", "content": "duplicate", "action": "skip",
                                 "matchedKeys": ["original"]}]}
        statistics = research.query_level_statistics({"entries": [entry]}, observed, protocol)
        self.assertEqual(statistics["bySplitAndStratum"]["sealed"]["compression_downscale"]
                         ["failedGroups"], 0)
        self.assertEqual(statistics["bySplitAndStratum"]["sealed"]["compression_downscale"]
                         ["actionFailedGroups"], 1)
        results["sealedOutcomes"] = statistics["queryOutcomes"]
        self.assertIn("observed false skip", research.verify_acceptance(protocol, results)["reasons"])

    def testCandidateRecallWrongSkipFailsButExtraImportIsNotUnsafeSkip(self):
        protocol, results = self.acceptance_results(n=36887)
        results["sealedOutcomes"] = [{"split": "sealed", "stratum": "candidate_recall",
                                      "expectedAction": "importFile", "observedAction": "skip",
                                      "retrievalHit": True}]
        self.assertIn("observed false skip", research.verify_acceptance(protocol, results)["reasons"])
        results["sealedOutcomes"] = [{"split": "sealed", "stratum": "renamed_metadata",
                                      "expectedAction": "skip", "observedAction": "importFile",
                                      "contentPass": True, "retrievalHit": True}]
        self.assertNotIn("observed false skip", research.verify_acceptance(protocol, results)["reasons"])

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

    def testLegacyAcceptanceCLIRejectsNewActiveScopeBeforeWriting(self):
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
            self.assertIn("new 33-case scope requires next-study protocol/evidence binding", result.stderr)
            self.assertFalse(output.exists())

    def testLegacyPublicEntryRejectsScopeBeforeProtocolOrModelUse(self):
        fixture = ROOT / "Tests/Fixtures/AdvancedDedup"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            protocol = root / "arbitrary-protocol.json"
            protocol.write_text(json.dumps({"fixture_manifest_sha256": "f" * 64}))
            output = root / "public-score"
            with self.assertRaisesRegex(ValueError, "new 33-case scope requires next-study protocol/evidence binding"):
                research.evaluate_public(protocol, root / "missing-profile", root / "missing-model",
                                         fixture, output)
            self.assertFalse(output.exists())
            with self.assertRaisesRegex(ValueError, "new 33-case scope requires next-study protocol/evidence binding"):
                research.accept_evidence(protocol, root / "missing-dataset", root / "missing-results",
                                         root / "acceptance")
            self.assertFalse((root / "acceptance").exists())

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

    def test_same_group_bytes_cannot_change_origin(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = self.entry(root, "first", "family", "group", "sealed")
            second = self.entry(root, "second", "family", "group", "sealed")
            (root / "second").write_bytes((root / "first").read_bytes())
            second["sha256"] = first["sha256"]
            second["origin_sha256"] = "f" * 64
            with self.assertRaisesRegex(ValueError, "byte identity"):
                research.validate_dataset({"root": str(root), "entries": [first, second]}, FIXTURE_HASH)

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


class ResearchAcceptanceArtifactTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temporary.name)
        cls.protocol_path = ROOT / "docs/research/advanced-dedup/protocol.json"
        cls.protocol = json.loads(cls.protocol_path.read_text())
        protocol_sha = hashlib.sha256(cls.protocol_path.read_bytes()).hexdigest()
        model_sha = "a" * 64
        mean, std = [0.0] * 3, [1.0] * 3
        bits = lambda value: str(struct.unpack("<I", struct.pack("<f", value))[0])
        fields = ["sscd-preprocess-v1", model_sha, "320", "stretchFullFrame", "sRGB"]
        fields += [bits(value) for value in mean + std]
        fingerprint_version = hashlib.sha256("\n".join(fields).encode()).hexdigest()
        policy_fields = ["advanced-dedup-policy-v1", fingerprint_version,
                         str(struct.unpack("<Q", struct.pack("<d", 0.8))[0]),
                         "exact-f32-v1", "cover-if-both-sorted-pixel-edges-gte-v1"]
        policy_sha = hashlib.sha256(b"".join(len(value.encode()).to_bytes(8, "little")
                             + value.encode() for value in policy_fields)).hexdigest()
        resource_names = {"inference_concurrency": "inferenceConcurrency", "batch_size": "batchSize",
                          "max_in_flight_tasks": "maxInFlightTasks", "decode_concurrency": "decodeConcurrency",
                          "photo_request_concurrency": "photoRequestConcurrency",
                          "max_decoded_bytes": "maxDecodedBytes", "catalog_batch_size": "catalogBatchSize",
                          "request_timeout_seconds": "requestTimeoutSeconds",
                          "retry_delays_seconds": "retryDelaysSeconds",
                          "progress_publish_interval_seconds": "progressPublishIntervalSeconds"}
        cls.profile = {"fingerprint": {"version": fingerprint_version, "modelSHA256": model_sha,
                       "inputSide": 320, "resizeMode": "stretchFullFrame", "colorSpace": "sRGB",
                       "mean": mean, "std": std}, "policyVersion": policy_sha, "threshold": 0.8,
                       "backend": "exact-f32-v1",
                       "resources": {target: cls.protocol["resources"][source]
                                     for source, target in resource_names.items()},
                       "evidenceCandidateLimit": 200000,
                       "acceptanceID": "research:" + protocol_sha}
        cls.profile_path = cls.root / "profile.json"
        cls.profile_path.write_text(json.dumps(cls.profile))
        query = ResearchProtocolTests.entry(cls.root, "query", "query-family", "query-group", "sealed")
        distractor = ResearchProtocolTests.entry(cls.root, "distractor", "other-family",
                                                    "other-group", "distractor")
        for entry in (query, distractor):
            entry.update({"width": 10, "height": 10, "representation": "photosOriginal"})
        cls.dataset = {"root": str(cls.root), "entries": [query, distractor]}
        cls.dataset_path = cls.root / "dataset.json"
        cls.dataset_path.write_text(json.dumps(cls.dataset))
        cls.vectors = cls.root / "vectors"
        cls.vectors.mkdir()
        records = []
        for index, entry in enumerate((query, distractor)):
            values = [0.0] * 1024
            values[index] = 1.0
            vector_name = f"{entry['sha256']}.f32"
            vector = cls.vectors / vector_name
            vector.write_bytes(struct.pack("<1024f", *values))
            records.append({"inputSHA256": entry["sha256"], "vectorFile": vector_name,
                            "vectorSHA256": hashlib.sha256(vector.read_bytes()).hexdigest()})
        (cls.vectors / "fingerprints.json").write_text(json.dumps({
            "protocolSHA256": protocol_sha, "modelSHA256": model_sha,
            "fingerprintVersion": fingerprint_version, "records": records}))
        cls.output = cls.root / "sealed-score.json"
        cls.report = research.score_dataset(cls.protocol_path, cls.dataset_path, cls.vectors,
                                             cls.profile_path, cls.output, "sealed")
        cls.public_fixture = cls.root / "public"
        cls.public_fixture.mkdir()
        public_images = [{"id": name, "sha256": item["sha256"], "width": 10, "height": 10}
                         for name, item in (("query", query), ("distractor", distractor))]
        public_manifest = {"images": public_images}
        public_truth = {"cases": [{"id": "P001", "query": "query",
                                   "candidates": ["distractor"]}]}
        (cls.public_fixture / "manifest.json").write_text(json.dumps(public_manifest))
        (cls.public_fixture / "expected-results.json").write_text(json.dumps(public_truth))
        vector_inventory, vector_manifest_sha = research._vector_inventory(
            cls.vectors, cls.profile, protocol_sha)
        public_queries = research._public_queries(public_manifest, public_truth, vector_inventory)
        swift, batch = research._run_swift_score(cls.profile_path, public_queries, protocol_sha)
        cls.public_report = {"vectorManifestPath": str(cls.vectors / "fingerprints.json"),
                             "vectorManifestSHA256": vector_manifest_sha,
                             "swift": swift, "swiftBatch": batch}

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def testSyntheticFullCatalogArtifactAuditSucceedsWithoutAcceptance(self):
        statistics = research._audit_catalog_score(self.report, self.dataset, "sealed",
            self.profile_path, self.profile, self.protocol)
        self.assertEqual(statistics["bySplitAndStratum"]["sealed"]["false_skip"]["queries"], 1)
        self.assertTrue(statistics["queryOutcomes"][0]["metricPass"])
        self.assertFalse(statistics["sealedMinimumsMet"])
        self.assertEqual(len(json.loads(Path(self.report["catalogPath"]).read_text())["candidates"]), 1)

    def testOmittedAuditedDistractorFailsCatalogAudit(self):
        report = json.loads(json.dumps(self.report))
        catalog = self.root / "omitted-catalog.json"
        catalog.write_text(json.dumps({"candidates": []}))
        report["catalogPath"] = str(catalog)
        report["catalogSHA256"] = hashlib.sha256(catalog.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError, "full catalog"):
            research._audit_catalog_score(report, self.dataset, "sealed",
                                          self.profile_path, self.profile, self.protocol)

    def testSameDistractorBytesWithDifferentOriginsDoNotMakeDistinctAssets(self):
        first = ResearchProtocolTests.entry(self.root, "same-file", "family-one",
                                            "group-one", "distractor")
        second = ResearchProtocolTests.entry(self.root, "other-label", "family-two",
                                             "group-two", "distractor")
        second["path"] = first["path"]
        second["sha256"] = first["sha256"]
        dataset = {"root": str(self.root), "entries": [first, second]}
        research.validate_dataset(dataset, FIXTURE_HASH)
        self.assertEqual(len({entry["origin_sha256"] for entry in dataset["entries"]}), 2)
        self.assertFalse(research._distractor_catalog_sufficient(dataset["entries"], minimum=2))
        second["path"] = "other-label"
        second["sha256"] = hashlib.sha256((self.root / "other-label").read_bytes()).hexdigest()
        self.assertTrue(research._distractor_catalog_sufficient(dataset["entries"], minimum=2))
        second["origin_sha256"] = first["origin_sha256"]
        self.assertFalse(research._distractor_catalog_sufficient(dataset["entries"], minimum=2))

    def testChangedQueryDimensionsOrDecisionsFailArtifactAudit(self):
        dimensions = json.loads(json.dumps(self.report))
        dimensions["swiftBatch"]["queries"][0]["size"] = {"width": 1, "height": 1}
        with self.assertRaisesRegex(ValueError, "audited dataset"):
            research._audit_catalog_score(dimensions, self.dataset, "sealed",
                                          self.profile_path, self.profile, self.protocol)
        decisions = json.loads(json.dumps(self.report))
        decisions["swift"]["queries"][0]["action"] = "skip"
        with self.assertRaisesRegex(ValueError, "shared Swift scorer"):
            research._audit_catalog_score(decisions, self.dataset, "sealed",
                                          self.profile_path, self.profile, self.protocol)

    def testChangedVectorBytesFailR2ManifestBinding(self):
        from shutil import copytree
        mutated = self.root / "mutated-vectors"
        copytree(self.vectors, mutated)
        manifest = json.loads((mutated / "fingerprints.json").read_text())
        vector = mutated / manifest["records"][0]["vectorFile"]
        vector.write_bytes(b"x" * 4096)
        report = json.loads(json.dumps(self.report))
        report["vectorManifestPath"] = str(mutated / "fingerprints.json")
        with self.assertRaisesRegex(ValueError, "actual vector bytes"):
            research._audit_catalog_score(report, self.dataset, "sealed",
                                          self.profile_path, self.profile, self.protocol)

    def testPublicArtifactAuditRejectsDimensionsDecisionsAndMissingResults(self):
        self.assertEqual(research._audit_public_score(self.public_report, self.profile_path,
            self.profile, self.report["protocolSHA256"], self.public_fixture)["queries"][0]["action"],
            "importFile")
        dimensions = json.loads(json.dumps(self.public_report))
        dimensions["swiftBatch"]["queries"][0]["size"] = {"width": 1, "height": 1}
        with self.assertRaisesRegex(ValueError, "frozen images, dimensions or gallery"):
            research._audit_public_score(dimensions, self.profile_path, self.profile,
                                         self.report["protocolSHA256"], self.public_fixture)
        decisions = json.loads(json.dumps(self.public_report))
        decisions["swift"]["queries"][0]["content"] = "duplicate"
        decisions["swift"]["queries"][0]["action"] = "skip"
        with self.assertRaisesRegex(ValueError, "shared Swift scorer"):
            research._audit_public_score(decisions, self.profile_path, self.profile,
                                         self.report["protocolSHA256"], self.public_fixture)
        truncated = json.loads(json.dumps(self.public_report))
        truncated["swift"]["queries"][0]["candidates"] = []
        with self.assertRaisesRegex(ValueError, "incomplete"):
            research._audit_public_score(truncated, self.profile_path, self.profile,
                                         self.report["protocolSHA256"], self.public_fixture)


if __name__ == "__main__":
    unittest.main()
