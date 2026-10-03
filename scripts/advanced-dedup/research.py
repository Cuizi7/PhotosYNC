#!/usr/bin/env python3
"""Audit an advanced-dedup protocol and an explicit local dataset.

This tool reads bytes and metadata only. It does not infer labels, run a model,
select a threshold, or turn a protocol draft into measurement approval.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile


REPO_ROOT = Path(__file__).resolve().parents[2]
PUBLIC_MANIFEST = REPO_ROOT / "Tests/Fixtures/AdvancedDedup/manifest.json"
SPLITS = {"calibration", "sealed", "distractor", "public_regression"}
ACTIONS = {"importFile", "skip"}
REPRESENTATIONS = {"photosOriginal", "photosCurrent", "localPending",
                   "localImporting", "successHistory"}
COPY_STRATA = {"renamed_metadata", "compression_downscale", "format_change",
               "edited_representations", "hard_copy"}
RESOURCE_FIELDS = {"inference_concurrency", "batch_size", "max_in_flight_tasks",
                   "decode_concurrency", "photo_request_concurrency",
                   "max_decoded_bytes", "catalog_batch_size", "max_candidate_representations",
                   "request_timeout_seconds", "retry_delays_seconds",
                   "progress_publish_interval_seconds"}
PROTOCOL_FIELDS = {"approved", "confidence_level", "max_false_skip_upper_bound",
                   "min_copy_recall_by_stratum", "min_candidate_recall",
                   "minimum_queries_by_stratum", "max_hot_query_p95_ms",
                   "max_incremental_p95_ms", "max_peak_rss_bytes", "resources", "seed",
                   "sampling_unit", "alpha_allocation_by_stratum",
                   "conversion_max_abs_error", "conversion_min_cosine"}
APPROVED_METRIC_FIELDS = {"max_false_skip_upper_bound", "min_copy_recall_by_stratum",
                          "min_candidate_recall", "max_hot_query_p95_ms",
                          "max_incremental_p95_ms", "max_peak_rss_bytes"}


def _mapping(value, label):
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
    return value


def _required(document, fields, label):
    missing = fields - document.keys()
    if missing:
        raise ValueError(f"{label} missing: {', '.join(sorted(missing))}")


def _number(value, label, minimum=0, maximum=None, inclusive_min=False):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"{label} must be finite numeric")
    if value < minimum or (value == minimum and not inclusive_min):
        raise ValueError(f"{label} must exceed {minimum}")
    if maximum is not None and value > maximum:
        raise ValueError(f"{label} must be at most {maximum}")


def _positive_int(value, label):
    if type(value) is not int or value <= 0:
        raise ValueError(f"{label} must be a positive integer")


def _nonempty(value, label):
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label} must be nonempty text")


def _zero_error_minimum(target, alpha):
    # P(0 failures | true failure rate = target) = (1 - target) ** n.
    return math.ceil(math.log(alpha) / math.log1p(-target))


def validate_protocol(document: dict) -> dict:
    """Reject missing or inconsistent precommitted research targets."""
    _mapping(document, "protocol")
    _required(document, PROTOCOL_FIELDS, "protocol")
    if type(document["approved"]) is not bool:
        raise ValueError("approved must be boolean")
    if document["approved"]:
        approval = _mapping(document.get("approval"), "approval")
        _required(approval, {"date", "text", "approved_fields", "protocol_sha256"}, "approval")
        _nonempty(approval["date"], "approval.date")
        _nonempty(approval["text"], "approval.text")
        fields = approval["approved_fields"]
        if (not isinstance(fields, list) or not all(isinstance(field, str) for field in fields)
                or len(fields) != len(APPROVED_METRIC_FIELDS) or set(fields) != APPROVED_METRIC_FIELDS):
            raise ValueError("approval.approved_fields must enumerate the reviewed metric targets")
        draft = {key: value for key, value in document.items() if key != "approval"}
        draft["approved"] = False
        canonical = json.dumps(draft, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        if approval["protocol_sha256"] != hashlib.sha256(canonical).hexdigest():
            raise ValueError("approval.protocol_sha256 does not bind this draft")
    elif "approval" in document:
        raise ValueError("approval record requires approved=true")
    _nonempty(document.get("fixture_manifest_sha256"), "fixture_manifest_sha256")
    _number(document["confidence_level"], "confidence_level", maximum=1)
    if document["confidence_level"] == 1:
        raise ValueError("confidence_level must be below 1")
    _number(document["max_false_skip_upper_bound"], "max_false_skip_upper_bound", maximum=1)
    if document["max_false_skip_upper_bound"] == 1:
        raise ValueError("max_false_skip_upper_bound must be below 1")
    _number(document["min_candidate_recall"], "min_candidate_recall", maximum=1)
    if document["min_candidate_recall"] == 1:
        raise ValueError("min_candidate_recall must be below 1 for finite zero-error sizing")
    recalls = _mapping(document["min_copy_recall_by_stratum"], "min_copy_recall_by_stratum")
    if set(recalls) != COPY_STRATA:
        raise ValueError("min_copy_recall_by_stratum must name every fixed copy stratum")
    for name, value in recalls.items():
        _number(value, f"min_copy_recall_by_stratum.{name}", maximum=1)
        if value == 1:
            raise ValueError("copy recall target 1 has no finite zero-error sample size")
    alphas = _mapping(document["alpha_allocation_by_stratum"], "alpha_allocation_by_stratum")
    expected = COPY_STRATA | {"false_skip", "candidate_recall"}
    if set(alphas) != expected:
        raise ValueError("alpha_allocation_by_stratum must name each hypothesis")
    for name, value in alphas.items():
        _number(value, f"alpha_allocation_by_stratum.{name}", maximum=1)
    if not math.isclose(sum(alphas.values()), 1 - document["confidence_level"], abs_tol=1e-12):
        raise ValueError("alpha allocation must sum to 1 - confidence_level")
    counts = _mapping(document["minimum_queries_by_stratum"], "minimum_queries_by_stratum")
    if set(counts) != expected:
        raise ValueError("minimum_queries_by_stratum must name each hypothesis")
    risks = {"false_skip": document["max_false_skip_upper_bound"],
             "candidate_recall": 1 - document["min_candidate_recall"]}
    risks.update({name: 1 - recall for name, recall in recalls.items()})
    for name, target in risks.items():
        _positive_int(counts[name], f"minimum_queries_by_stratum.{name}")
        if counts[name] < _zero_error_minimum(target, alphas[name]):
            raise ValueError(f"minimum_queries_by_stratum.{name} cannot support the target")
    for name in ("max_hot_query_p95_ms", "max_incremental_p95_ms",
                 "max_peak_rss_bytes", "conversion_max_abs_error"):
        _number(document[name], name)
    _number(document["conversion_min_cosine"], "conversion_min_cosine", maximum=1)
    if type(document["seed"]) is not int or document["seed"] < 0:
        raise ValueError("seed must be a nonnegative integer")
    if document["sampling_unit"] != "split_group":
        raise ValueError("sampling_unit must be split_group to avoid correlated pair counts")
    resources = _mapping(document["resources"], "resources")
    _required(resources, RESOURCE_FIELDS, "resources")
    for name in RESOURCE_FIELDS - {"request_timeout_seconds", "retry_delays_seconds",
                                   "progress_publish_interval_seconds"}:
        _positive_int(resources[name], f"resources.{name}")
    for name in ("request_timeout_seconds", "progress_publish_interval_seconds"):
        _number(resources[name], f"resources.{name}")
    delays = resources["retry_delays_seconds"]
    if not isinstance(delays, list) or not delays:
        raise ValueError("resources.retry_delays_seconds must be a nonempty array")
    for index, delay in enumerate(delays):
        _number(delay, f"resources.retry_delays_seconds[{index}]")
    if resources["inference_concurrency"] != 1 or resources["batch_size"] != 1:
        raise ValueError("research baseline requires serial inference, batch 1")
    if resources["max_in_flight_tasks"] < resources["decode_concurrency"]:
        raise ValueError("max_in_flight_tasks cannot be below decode_concurrency")
    return {"approved": document["approved"], "sampling_unit": "split_group",
            "minimum_queries_by_stratum": counts.copy()}


def _sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _public_inventory(fixture_manifest_sha256):
    _nonempty(fixture_manifest_sha256, "fixture_manifest_sha256")
    manifest = json.loads(PUBLIC_MANIFEST.read_text())
    content_hash = manifest.pop("content_sha256")
    content_bytes = json.dumps(manifest, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    if hashlib.sha256(content_bytes).hexdigest() != content_hash:
        raise ValueError("public manifest content hash mismatch")
    if fixture_manifest_sha256 != content_hash:
        raise ValueError("fixture_manifest_sha256 does not identify the frozen public corpus")
    return ({image["sha256"] for image in manifest["images"]},
            {image["family_id"] for image in manifest["images"]},
            {source["split_group"] for source in manifest["sources"]},
            {source["original_sha256"] for source in manifest["sources"]
             if "original_sha256" in source})


def _file_record(record, root, label, public_hashes, split):
    _required(record, {"path", "sha256", "license_record"}, label)
    _nonempty(record["path"], f"{label}.path")
    relative = Path(record["path"])
    if relative.is_absolute() or ".." in relative.parts or not relative.parts:
        raise ValueError(f"{label}.path must stay below dataset root")
    path = root / relative
    if not path.resolve().is_relative_to(root) or not path.is_file():
        raise ValueError(f"{label}.path must be an existing file below dataset root")
    digest = record["sha256"]
    if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        raise ValueError(f"{label}.sha256 must be lowercase SHA256")
    if _sha256_file(path) != digest:
        raise ValueError(f"{label}.SHA256 does not match file bytes")
    license_record = _mapping(record["license_record"], f"{label}.license_record")
    _required(license_record, {"license", "source", "permission"}, f"{label}.license_record")
    for name in ("license", "source", "permission"):
        _nonempty(license_record[name], f"{label}.license_record.{name}")
    if digest in public_hashes and split != "public_regression":
        raise ValueError(f"{label} reuses public regression corpus bytes in {split}")
    return digest


def validate_dataset(document: dict, fixture_manifest_sha256: str) -> dict:
    """Check explicit local bytes and split independence without exposing content."""
    _mapping(document, "dataset")
    _required(document, {"root", "entries"}, "dataset")
    _nonempty(document["root"], "dataset.root")
    root = Path(document["root"]).expanduser().resolve()
    if not root.is_dir():
        raise ValueError("dataset.root must be an existing directory")
    entries = document["entries"]
    if not isinstance(entries, list) or not entries:
        raise ValueError("dataset.entries must be a nonempty array")
    content_hash = document.get("content_sha256")
    if content_hash is not None:
        if not isinstance(content_hash, str) or len(content_hash) != 64 or any(c not in "0123456789abcdef" for c in content_hash):
            raise ValueError("dataset.content_sha256 must be lowercase SHA256")
        if content_hash == fixture_manifest_sha256 and any(
                isinstance(entry, dict) and entry.get("split") != "public_regression" for entry in entries):
            raise ValueError("public regression corpus content hash cannot identify a sealed/calibration dataset")
        content = {key: value for key, value in document.items() if key != "content_sha256"}
        canonical = json.dumps(content, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        if hashlib.sha256(canonical).hexdigest() != content_hash:
            raise ValueError("dataset.content_sha256 does not match manifest content")
    public_hashes, public_families, public_groups, public_origins = _public_inventory(fixture_manifest_sha256)
    family_group = {}
    family_split = {}
    group_split = {}
    origin_identity = {}
    byte_identity = {}
    query_ids = set()
    groups_by_split = {split: set() for split in SPLITS}
    groups_by_stratum = {split: {} for split in SPLITS}
    for index, entry in enumerate(entries):
        label = f"entries[{index}]"
        _mapping(entry, label)
        _required(entry, {"query_id", "family_id", "split_group", "split", "stratum", "path",
                          "origin_sha256",
                          "sha256", "license_record", "expected_candidates", "expected_action"}, label)
        for name in ("query_id", "family_id", "split_group"):
            _nonempty(entry[name], f"{label}.{name}")
        query_id, family, group, split = (entry[name] for name in
                                          ("query_id", "family_id", "split_group", "split"))
        origin = entry["origin_sha256"]
        if not isinstance(origin, str) or len(origin) != 64 or any(c not in "0123456789abcdef" for c in origin):
            raise ValueError(f"{label}.origin_sha256 must be lowercase SHA256")
        if query_id in query_ids:
            raise ValueError(f"{label}.query_id repeated")
        query_ids.add(query_id)
        _nonempty(split, f"{label}.split")
        if split not in SPLITS:
            raise ValueError(f"{label}.split invalid")
        if split != "public_regression" and (family in public_families or group in public_groups or origin in public_origins):
            raise ValueError(f"{label} reuses public regression corpus lineage")
        stratum = entry["stratum"]
        _nonempty(stratum, f"{label}.stratum")
        if stratum not in COPY_STRATA | {"false_skip", "candidate_recall"}:
            raise ValueError(f"{label}.stratum invalid")
        _nonempty(entry["expected_action"], f"{label}.expected_action")
        if entry["expected_action"] not in ACTIONS:
            raise ValueError(f"{label}.expected_action invalid")
        if stratum == "false_skip" and entry["expected_action"] != "importFile":
            raise ValueError(f"{label}.false_skip requires expected_action=importFile")
        if family in family_group and family_group[family] != group:
            raise ValueError(f"family_id {family} assigned multiple split_group values")
        family_group[family] = group
        identity = (family, group, split)
        if origin in origin_identity and origin_identity[origin] != identity:
            raise ValueError(f"{label}.origin_sha256 relabelled across family/split_group/split")
        origin_identity[origin] = identity
        if (family in family_split and family_split[family] != split) or (group in group_split and group_split[group] != split):
            raise ValueError(f"family/split_group crosses split: {family}/{group}")
        family_split[family] = split
        group_split[group] = split
        query_digest = _file_record(entry, root, label, public_hashes, split)
        if split != "distractor":
            previous = byte_identity.setdefault(query_digest, identity)
            if previous != identity:
                raise ValueError(f"{label} verified byte identity conflicts with another audited query or match")
        candidates = entry["expected_candidates"]
        if not isinstance(candidates, list):
            raise ValueError(f"{label}.expected_candidates must be an array")
        if stratum != "false_skip" and not candidates:
            raise ValueError(f"{label}.expected_candidates required for positive stratum")
        if entry["expected_action"] == "skip" and not candidates:
            raise ValueError(f"{label}.expected_candidates required for skip action")
        candidate_ids = set()
        for candidate_index, candidate in enumerate(candidates):
            candidate_label = f"{label}.expected_candidates[{candidate_index}]"
            _mapping(candidate, candidate_label)
            _required(candidate, {"id", "representation", "width", "height", "path",
                                  "sha256", "origin_sha256", "license_record"}, candidate_label)
            if candidate["origin_sha256"] != origin:
                raise ValueError(f"{candidate_label}.origin_sha256 must reference query lineage")
            _nonempty(candidate["id"], f"{candidate_label}.id")
            if candidate["id"] in candidate_ids:
                raise ValueError(f"{candidate_label}.id repeated")
            candidate_ids.add(candidate["id"])
            _nonempty(candidate["representation"], f"{candidate_label}.representation")
            if candidate["representation"] not in REPRESENTATIONS:
                raise ValueError(f"{candidate_label}.representation invalid")
            for dimension in ("width", "height"):
                _positive_int(candidate[dimension], f"{candidate_label}.{dimension}")
            candidate_digest = _file_record(candidate, root, candidate_label, public_hashes, split)
            if split != "distractor":
                previous = byte_identity.setdefault(candidate_digest, identity)
                if previous != identity:
                    raise ValueError(f"{candidate_label} verified byte identity conflicts with another audited query or match")
        if split in {"calibration", "sealed"}:
            groups_by_split[split].add(group)
            groups_by_stratum[split].setdefault(stratum, set()).add(group)
    return {"entries": len(entries),
            "independent_queries_by_split": {split: len(groups) for split, groups in
                                             sorted(groups_by_split.items()) if groups},
            "independent_queries_by_split_and_stratum": {
                split: {name: len(groups) for name, groups in sorted(strata.items())}
                for split, strata in sorted(groups_by_stratum.items()) if strata}}


def _approved_protocol(path):
    raw = path.read_bytes()
    document = json.loads(raw)
    if not validate_protocol(document)["approved"]:
        raise ValueError("measurement requires an approved protocol")
    return document, hashlib.sha256(raw).hexdigest()


def _validated_profile(path, protocol_sha, protocol):
    profile = json.loads(path.read_text())
    _required(profile, {"fingerprint", "policyVersion", "threshold", "backend",
                        "resources", "evidenceCandidateLimit", "acceptanceID"}, "profile")
    if profile["acceptanceID"] != f"research:{protocol_sha}":
        raise ValueError("profile acceptanceID does not bind approved protocol bytes")
    if profile["backend"] != "exact-accelerate-f32":
        raise ValueError("profile backend must use the exact Swift scorer")
    _number(profile["threshold"], "profile.threshold", maximum=1)
    resources = _mapping(profile["resources"], "profile.resources")
    names = {"inference_concurrency": "inferenceConcurrency", "batch_size": "batchSize",
             "max_in_flight_tasks": "maxInFlightTasks", "decode_concurrency": "decodeConcurrency",
             "photo_request_concurrency": "photoRequestConcurrency",
             "max_decoded_bytes": "maxDecodedBytes", "catalog_batch_size": "catalogBatchSize",
             "request_timeout_seconds": "requestTimeoutSeconds",
             "retry_delays_seconds": "retryDelaysSeconds",
             "progress_publish_interval_seconds": "progressPublishIntervalSeconds"}
    for source, target in names.items():
        if resources.get(target) != protocol["resources"][source]:
            raise ValueError(f"profile.resources.{target} differs from approved protocol")
    if profile["evidenceCandidateLimit"] != protocol["resources"]["max_candidate_representations"]:
        raise ValueError("profile.evidenceCandidateLimit differs from approved protocol")
    return profile


def _vector_inventory(vectors, profile, protocol_sha):
    manifest_path = vectors / "fingerprints.json"
    manifest = json.loads(manifest_path.read_text())
    if (manifest["protocolSHA256"] != protocol_sha or
            manifest["fingerprintVersion"] != profile["fingerprint"]["version"] or
            manifest["modelSHA256"] != profile["fingerprint"]["modelSHA256"]):
        raise ValueError("R2 vector manifest binding mismatch")
    by_image = {}
    for record in manifest["records"]:
        digest = record["inputSHA256"]
        vector_name = record["vectorFile"]
        if vector_name != f"{digest}.f32":
            raise ValueError("R2 vector path is not bound to input SHA256")
        vector_path = vectors / vector_name
        if not vector_path.is_file() or vector_path.stat().st_size != 4096:
            raise ValueError("R2 vector bytes missing or wrong length")
        vector_sha = _sha256_file(vector_path)
        if digest in by_image and by_image[digest] != (vector_path, vector_sha):
            raise ValueError("R2 vector input SHA256 has conflicting records")
        by_image[digest] = (vector_path, vector_sha)
    return by_image, _sha256_file(manifest_path)


def _vector_reference(image, inventory):
    path, vector_sha = inventory[image["sha256"]]
    return {"vector": str(path.resolve()), "vectorSHA256": vector_sha}


def _run_swift_score(profile_path, queries, protocol_sha):
    with tempfile.TemporaryDirectory(prefix="photosync-r3-") as temporary:
        temporary = Path(temporary)
        batch = temporary / "batch.json"
        batch.write_text(json.dumps({"queries": queries}, sort_keys=True))
        output = temporary / "swift-output"
        subprocess.run([str(REPO_ROOT / "scripts/advanced-dedup/run-probe.sh"), "score-batch",
                        "--profile", str(profile_path), "--input", str(batch),
                        "--output-dir", str(output)], check=True, capture_output=True, text=True)
        result = json.loads((output / "query-results.json").read_text())
        if (result["protocolSHA256"] != protocol_sha or
                result["profileSHA256"] != _sha256_file(profile_path) or
                result["batchSHA256"] != _sha256_file(batch) or
                len(result["queries"]) != len(queries)):
            raise ValueError("Swift score result binding mismatch")
        return result


def query_level_statistics(dataset, swift_results, protocol):
    """Count independent query groups, never pairs or reusable distractors."""
    by_id = {query["id"]: query for query in swift_results["queries"]}
    entries = [entry for entry in dataset["entries"] if entry["split"] != "distractor"]
    if set(by_id) != {entry["query_id"] for entry in entries}:
        raise ValueError("Swift query result IDs differ from declared dataset queries")
    groups = {}
    for entry in entries:
        key = (entry["split"], entry["stratum"], entry["split_group"])
        observed = by_id[entry["query_id"]]
        correct = observed["action"] == entry["expected_action"]
        groups.setdefault(key, []).append(correct)
    per_split = {}
    for (split, stratum, _group), outcomes in groups.items():
        bucket = per_split.setdefault(split, {}).setdefault(stratum, {"queries": 0, "failedGroups": 0})
        bucket["queries"] += 1
        bucket["failedGroups"] += int(not all(outcomes))
    sealed = per_split.get("sealed", {})
    minimums = protocol["minimum_queries_by_stratum"]
    shortfalls = {name: max(0, minimum - sealed.get(name, {}).get("queries", 0))
                  for name, minimum in minimums.items()}
    # No statistical acceptance without the prescribed independent negative queries.
    passes_minimums = all(value == 0 for value in shortfalls.values())
    return {"bySplitAndStratum": per_split, "sealedShortfalls": shortfalls,
            "sealedMinimumsMet": passes_minimums,
            "pass": passes_minimums and all(bucket["failedGroups"] == 0
                                               for bucket in sealed.values())}


def score_dataset(protocol_path, dataset_path, vectors, profile_path, output):
    protocol, protocol_sha = _approved_protocol(protocol_path)
    dataset = json.loads(dataset_path.read_text())
    validate_dataset(dataset, protocol["fixture_manifest_sha256"])
    profile = _validated_profile(profile_path, protocol_sha, protocol)
    inventory, inventory_sha = _vector_inventory(vectors, profile, protocol_sha)
    public_hashes, _, _, _ = _public_inventory(protocol["fixture_manifest_sha256"])
    queries = []
    for entry in dataset["entries"]:
        if entry["split"] == "distractor":
            continue
        _positive_int(entry.get("width"), f"{entry['query_id']}.width")
        _positive_int(entry.get("height"), f"{entry['query_id']}.height")
        candidates = entry["expected_candidates"] + entry.get("gallery_candidates", [])
        if not candidates:
            raise ValueError(f"{entry['query_id']} has no designated candidate gallery")
        if len({item["id"] for item in candidates}) != len(candidates):
            raise ValueError(f"{entry['query_id']} repeats a candidate in its gallery")
        for index, item in enumerate(entry.get("gallery_candidates", [])):
            label = f"{entry['query_id']}.gallery_candidates[{index}]"
            _required(item, {"id", "representation", "width", "height", "path",
                             "sha256", "license_record"}, label)
            if item["representation"] not in REPRESENTATIONS:
                raise ValueError(f"{label}.representation invalid")
            _positive_int(item["width"], f"{label}.width")
            _positive_int(item["height"], f"{label}.height")
            _file_record(item, Path(dataset["root"]).expanduser().resolve(), label,
                         public_hashes, entry["split"])
        queries.append({"id": entry["query_id"], "size": {"width": entry["width"],
                        "height": entry["height"]}, **_vector_reference(entry, inventory),
                        "candidates": [{"key": item["id"], "origin": item["representation"],
                                        "size": {"width": item["width"], "height": item["height"]},
                                        **_vector_reference(item, inventory)} for item in candidates]})
    swift_results = _run_swift_score(profile_path, queries, protocol_sha)
    statistics = query_level_statistics(dataset, swift_results, protocol)
    report = {"protocolSHA256": protocol_sha, "datasetSHA256": _sha256_file(dataset_path),
              "profileSHA256": _sha256_file(profile_path), "vectorManifestSHA256": inventory_sha,
              "statistics": statistics, "swift": swift_results,
              "researchOnly": True}
    if output.exists():
        raise ValueError("output already exists")
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    return report


def evaluate_public(protocol_path, profile_path, model_path, fixture, output_dir):
    protocol, protocol_sha = _approved_protocol(protocol_path)
    profile = _validated_profile(profile_path, protocol_sha, protocol)
    # The existing frozen-corpus validator checks expected-results.json, review/manifest
    # bindings, every file byte, and all 44 approvals before the model is loaded.
    subprocess.run([sys.executable, str(REPO_ROOT / "scripts/dedup-fixtures/validate.py"),
                    "--dataset", str(fixture), "--require-approved"],
                   check=True, capture_output=True, text=True)
    manifest_path = fixture / "manifest.json"
    expected_path = fixture / "expected-results.json"
    manifest = json.loads(manifest_path.read_text())
    expected = json.loads(expected_path.read_text())
    if (manifest["content_sha256"] != protocol["fixture_manifest_sha256"] or
            expected["manifest_content_sha256"] != manifest["content_sha256"] or
            len(expected["cases"]) != 44):
        raise ValueError("frozen public corpus binding/count mismatch")
    if output_dir.exists():
        raise ValueError("output directory already exists")
    output_dir.mkdir(parents=False)
    list_path = output_dir / "input-list.json"
    list_path.write_text(json.dumps([str((fixture / item["file"]).resolve())
                                     for item in manifest["images"]]))
    vectors = output_dir / "vectors"
    subprocess.run([str(REPO_ROOT / "scripts/advanced-dedup/run-probe.sh"), "fingerprint",
                    "--profile", str(profile_path), "--model", str(model_path),
                    "--input-list", str(list_path), "--output-dir", str(vectors)],
                   check=True, capture_output=True, text=True)
    inventory, inventory_sha = _vector_inventory(vectors, profile, protocol_sha)
    images = {item["id"]: item for item in manifest["images"]}
    queries = []
    for case in expected["cases"]:
        image = images[case["query"]]
        candidates = [images[key] for key in case["candidates"]]
        queries.append({"id": case["id"], "size": {"width": image["width"],
                        "height": image["height"]}, **_vector_reference(image, inventory),
                        "candidates": [{"key": candidate["id"], "origin": "photosOriginal",
                                        "size": {"width": candidate["width"],
                                                 "height": candidate["height"]},
                                        **_vector_reference(candidate, inventory)}
                                       for candidate in candidates]})
    swift_results = _run_swift_score(profile_path, queries, protocol_sha)
    by_id = {item["id"]: item for item in swift_results["queries"]}
    cases = []
    for truth in expected["cases"]:
        observed = by_id[truth["id"]]
        wanted_content = ("notDuplicate" if truth["expected"]["content_result"] == "not_duplicate"
                          else "duplicate")
        wanted_action = ("importFile" if truth["expected"]["action"] == "import" else "skip")
        content_pass = observed["content"] == wanted_content
        action_pass = observed["action"] == wanted_action
        cases.append({"id": truth["id"], "query": truth["query"],
                      "gallery": truth["candidates"], "expectedContent": wanted_content,
                      "expectedAction": wanted_action, "observed": observed,
                      "contentPass": content_pass, "actionPass": action_pass,
                      "pass": content_pass and action_pass})
    report = {"protocolSHA256": protocol_sha,
              "expectedResultsSHA256": _sha256_file(expected_path),
              "manifestSHA256": _sha256_file(manifest_path),
              "profileSHA256": _sha256_file(profile_path),
              "modelPath": str(model_path), "vectorManifestSHA256": inventory_sha,
              "threshold": profile["threshold"],
              "thresholdStatus": "predeclared synthetic example; diagnostic only; not calibrated or accepted",
              "cases": cases, "caseCount": len(cases),
              "contentFailures": [case["id"] for case in cases if not case["contentPass"]],
              "actionFailures": [case["id"] for case in cases if not case["actionPass"]],
              "passCount": sum(case["pass"] for case in cases),
              "researchOnly": True}
    (output_dir / "public-evaluation.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    check = subcommands.add_parser("check-protocol")
    check.add_argument("--protocol", type=Path, required=True)
    check.add_argument("--dataset", type=Path, required=True)
    score = subcommands.add_parser("score")
    score.add_argument("--protocol", type=Path, required=True)
    score.add_argument("--dataset", type=Path, required=True)
    score.add_argument("--vectors", type=Path, required=True)
    score.add_argument("--profile", type=Path, required=True)
    score.add_argument("--output", type=Path, required=True)
    evaluate = subcommands.add_parser("evaluate")
    evaluate.add_argument("--protocol", type=Path, required=True)
    evaluate.add_argument("--profile", type=Path, required=True)
    evaluate.add_argument("--model", type=Path, required=True)
    evaluate.add_argument("--dataset", type=Path, required=True)
    evaluate.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.command == "score":
        try:
            report = score_dataset(args.protocol, args.dataset, args.vectors, args.profile, args.output)
        except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
            parser.exit(1, f"research score invalid: {error}\n")
        print(json.dumps(report["statistics"], sort_keys=True))
        return 0
    if args.command == "evaluate":
        try:
            report = evaluate_public(args.protocol, args.profile, args.model,
                                     args.dataset, args.output_dir)
        except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
            parser.exit(1, f"public evaluation invalid: {error}\n")
        print(json.dumps({"cases": report["caseCount"], "passed": report["passCount"],
                          "contentFailures": report["contentFailures"],
                          "actionFailures": report["actionFailures"]}, sort_keys=True))
        return 0
    try:
        protocol_bytes = args.protocol.read_bytes()
        protocol = json.loads(protocol_bytes)
        protocol_result = validate_protocol(protocol)
        dataset = json.loads(args.dataset.read_text())
        dataset_result = validate_dataset(dataset, protocol["fixture_manifest_sha256"])
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        parser.exit(1, f"research protocol invalid: {error}\n")
    sealed = dataset_result["independent_queries_by_split_and_stratum"].get("sealed", {})
    shortfalls = {name: minimum - sealed.get(name, 0)
                  for name, minimum in protocol_result["minimum_queries_by_stratum"].items()
                  if sealed.get(name, 0) < minimum}
    print(json.dumps({"protocol_sha256": hashlib.sha256(protocol_bytes).hexdigest(),
                      "protocol": protocol_result, "dataset": dataset_result,
                      "sealed_minimums_met": not shortfalls,
                      "sealed_shortfalls": shortfalls}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
