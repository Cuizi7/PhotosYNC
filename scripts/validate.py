#!/usr/bin/env python3
"""Run the local PhotosYNC release gate against one source snapshot.

The validator deliberately builds Debug for XCTest and leaves the optimized
Release build to ``package-release.sh``.  Both commands are invoked from the
same archived source tree by the packager, so testability never changes the
distribution binary.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import functools
import importlib.util
import json
import math
import os
import platform
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time
from typing import Any, Sequence


BUILD_TIMEOUT_SECONDS = 20 * 60
XCTEST_TIMEOUT_SECONDS = 10 * 60
TOOLS_TIMEOUT_SECONDS = 5 * 60
CONTINUATION_TIMEOUT_SECONDS = 5 * 60
TOOLCHAIN_TIMEOUT_SECONDS = 60
PERFORMANCE_CONTRACT = "background-preparation-v2"
PREPARATION_P95_BUDGET_MS = 2000
SCALE_PROFILES = {
    "release": ((200000, 100000),),
    "full": ((100000, 0), (150000, 0), (200000, 0), (200000, 100000)),
}
CANONICAL_BUDGET_SECONDS = {"release": 25 * 60, "full": 35 * 60}
RUNTIME_SCENARIOS = [f"R{i:02}" for i in range(1, 17)]
ALLOWED_XCTEST_SKIPS = {
    "AdvancedDedupRegressionTests/testControlledScaleThroughActualGraph": "Scale sampling is an explicit canonical subprocess",
    "AdvancedDedupRegressionTests/testExistingVectorReplayUsesSQLiteBackend": "Saved-vector replay requires explicit local inputs",
}

EXCLUDED_MANIFEST_DIRECTORIES = {
    ".git",
    ".superpowers",
    ".worktrees",
    "__pycache__",
    "work",
    "worktrees",
    "outputs",
}
XCTEST_SUMMARY = re.compile(r"Executed\s+(\d+)\s+tests?,\s+with\s+(?:\d+\s+tests?\s+skipped\s+and\s+)?(\d+)\s+failures?", re.IGNORECASE)
UNITTEST_SUMMARY = re.compile(r"Ran\s+(\d+)\s+tests?\s+in", re.IGNORECASE)


class ValidationError(RuntimeError):
    """A failed release gate with preserved local evidence."""


class PhaseFailure(ValidationError):
    """A command could not prove a required validation phase."""


@dataclass(frozen=True)
class CommandResult:
    command: tuple[str, ...]
    log_path: Path
    elapsed_seconds: float


@dataclass(frozen=True)
class SourceManifest:
    entries: list[dict[str, Any]]
    digest: str


def parser() -> argparse.ArgumentParser:
    argument_parser = argparse.ArgumentParser(
        description="Build and run the complete PhotosYNC local release validation gate."
    )
    argument_parser.add_argument(
        "--scale-profile", choices=tuple(SCALE_PROFILES), default="release",
        help="release: maximum mixed sample (default); full: all four scale/distribution samples.",
    )
    argument_parser.add_argument("--ui-profile", choices=("none", "native"), default="none")
    argument_parser.add_argument("--ui-allow-focus", action="store_true",
                                 help="Explicitly permit the isolated native UI host to take focus.")
    argument_parser.add_argument(
        "--output-dir",
        type=Path,
        required=True,
        help="New absolute directory for validation evidence. Existing paths, including symlinks, are refused.",
    )
    argument_parser.add_argument(
        "--derived-data",
        type=Path,
        required=True,
        help="New absolute Xcode DerivedData path. Existing paths are refused to prevent stale test bundles.",
    )
    return argument_parser


def main(arguments: Sequence[str] | None = None) -> int:
    install_cancellation_handlers()
    arguments = parser().parse_args(arguments)
    source_root = Path(__file__).resolve().parent.parent
    output_dir = arguments.output_dir
    output_created = False

    try:
        prepare_paths(source_root=source_root, output_dir=output_dir, derived_data=arguments.derived_data)
        output_dir.mkdir()
        output_created = True
        validate(source_root=source_root, output_dir=output_dir, derived_data=arguments.derived_data,
                 scale_profile=arguments.scale_profile, ui_profile=arguments.ui_profile, ui_allow_focus=arguments.ui_allow_focus)
    except (OSError, ValidationError, json.JSONDecodeError) as error:
        if output_created:
            write_failure(output_dir, error)
        print(f"Validation failed: {error}", file=sys.stderr)
        return 1

    print(f"Validation passed: {output_dir / 'validation.json'}")
    return 0


def prepare_paths(*, source_root: Path, output_dir: Path, derived_data: Path) -> None:
    if not output_dir.is_absolute() or not derived_data.is_absolute():
        raise ValidationError("--output-dir and --derived-data must be absolute paths.")
    if path_exists(output_dir):
        raise ValidationError(f"Validation output path already exists: {output_dir}.")
    if path_exists(derived_data):
        raise ValidationError(f"DerivedData path already exists: {derived_data}.")
    if paths_overlap(output_dir, derived_data):
        raise ValidationError("Validation output and DerivedData paths must not overlap.")
    if not output_path_is_allowed(output_dir, source_root) or not output_path_is_allowed(
        derived_data, source_root
    ):
        raise ValidationError(
            "Validation output and DerivedData must be outside the source snapshot or inside its ignored work directory."
        )
    if not (source_root / "PhotoSync.xcodeproj").is_dir():
        raise ValidationError(f"Missing Xcode project in source snapshot: {source_root}.")
    if not (source_root / "Tests" / "Tools").is_dir():
        raise ValidationError("Missing tracked Python tool tests.")
    if not (source_root / "scripts" / "test-continuation-race.py").is_file():
        raise ValidationError("Missing tracked continuation-race validator.")
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    derived_data.parent.mkdir(parents=True, exist_ok=True)


def validate(*, source_root: Path, output_dir: Path, derived_data: Path, scale_profile: str = "release",
             ui_profile: str = "none", ui_allow_focus: bool = False) -> None:
    started = time.monotonic()
    deadline = started + CANONICAL_BUDGET_SECONDS[scale_profile]
    if inherited := os.environ.get("PHOTOSYNC_VALIDATION_DEADLINE"):
        try: inherited_deadline = float(inherited)
        except ValueError as error: raise ValidationError("Invalid inherited validation deadline") from error
        if not math.isfinite(inherited_deadline): raise ValidationError("Invalid inherited validation deadline")
        deadline = min(deadline, inherited_deadline)
    run = functools.partial(run_command, deadline=deadline)
    if ui_profile == "native" and not ui_allow_focus:
        raise ValidationError("Native UI requires explicit --ui-allow-focus; no foreground actions were attempted.")
    environment = child_environment()
    for name in ("PHOTOSYNC_SCALE_REPRESENTATIONS", "PHOTOSYNC_SCALE_HISTORY", "PHOTOSYNC_SCALE_BUILD_CONFIGURATION"):
        environment.pop(name, None)
    # CI and local runs share the same exact approved-input gate; never substitute
    # an external dataset or bypass the gate by removing an environment variable.
    environment_check = run([sys.executable, "scripts/test-environment.py", "--check", "--output", str(output_dir / "environment.json")],
        cwd=source_root, environment=environment, log_path=output_dir / "environment.log", timeout_seconds=60, label="portable test environment")
    environment["PHOTOSYNC_REGRESSION_DATASET"] = str(source_root / "Tests/Fixtures/AdvancedDedup")
    environment["PHOTOSYNC_ACCEPTANCE_OUTPUT"] = str(output_dir)
    environment["PHOTOSYNC_MODEL_CACHE_DIR"] = str(derived_data / "model-cache")
    resources = run(
        [sys.executable, "scripts/advanced-dedup/release.py", "--resources",
         str(source_root / "Sources/PhotoSyncCore/Resources/AdvancedDedup"),
         "--output", str(output_dir / "resources.json")], cwd=source_root, environment=environment,
        log_path=output_dir / "resources.log", timeout_seconds=60, label="fixed model resources")
    fixtures = run(
        [sys.executable, "scripts/dedup-fixtures/validate.py", "--dataset",
         str(source_root / "Tests/Fixtures/AdvancedDedup"), "--require-approved"],
        cwd=source_root, environment=environment, log_path=output_dir / "fixtures.log",
        timeout_seconds=60, label="approved fixture integrity")
    before_manifest = build_source_manifest(source_root)
    write_json(
        output_dir / "source-manifest.json",
        {
            "sha256": before_manifest.digest,
            "entry_count": len(before_manifest.entries),
            "entries": before_manifest.entries,
        },
    )

    xcode_version = run(
        ["xcodebuild", "-version"],
        cwd=source_root,
        environment=environment,
        log_path=output_dir / "xcodebuild-version.log",
        timeout_seconds=TOOLCHAIN_TIMEOUT_SECONDS,
        label="xcodebuild version",
    )
    swift_version = run(
        ["xcrun", "swift", "--version"],
        cwd=source_root,
        environment=environment,
        log_path=output_dir / "swift-version.log",
        timeout_seconds=TOOLCHAIN_TIMEOUT_SECONDS,
        label="Swift version",
    )
    build = run(
        [
            "xcodebuild",
            "-project",
            "PhotoSync.xcodeproj",
            "-scheme",
            "PhotoSync",
            "-configuration",
            "Debug",
            "-destination",
            "platform=macOS",
            "-derivedDataPath",
            str(derived_data),
            "CODE_SIGNING_ALLOWED=NO",
            "build-for-testing",
        ],
        cwd=source_root,
        environment=environment,
        log_path=output_dir / "build-for-testing.log",
        timeout_seconds=BUILD_TIMEOUT_SECONDS,
        label="build-for-testing",
    )

    test_bundle = derived_data / "Build" / "Products" / "Debug" / "PhotoSyncCoreTests.xctest"
    if not test_bundle.is_dir() or test_bundle.is_symlink():
        raise ValidationError(f"build-for-testing did not create the expected test bundle: {test_bundle}.")

    native_phases = []
    native_evidence = None
    if ui_profile == "native":
        print(f"Native UI review will appear at {output_dir / 'native/index.html'}", flush=True)
        native = run([sys.executable, "Tests/UIReview/run-native-scenes.py", "--derived-data", str(derived_data),
            "--output-dir", str(output_dir / "native"), "--allow-focus", "--timeout", str(min(480, deadline - time.monotonic()))],
            cwd=source_root, environment=environment, log_path=output_dir / "native.log", timeout_seconds=480, label="native Settings/MenuBarExtra review")
        native_phases.append(phase_record("native-ui", native, output_dir))
        native_evidence = {"result":"native/native-scenes.json", "sha256":sha256_file(output_dir / "native/native-scenes.json")}

    xctest = run(
        ["xcrun", "xctest", str(test_bundle)],
        cwd=source_root,
        environment=environment,
        log_path=output_dir / "xctest.log",
        timeout_seconds=XCTEST_TIMEOUT_SECONDS,
        label="complete XCTest suite",
    )
    xctest_count = validate_xctest_summary(xctest.log_path)

    # Performance budgets apply to the optimized product code. Testability only
    # exposes internal APIs to this isolated test host; the packager still makes
    # its own normal Release build after canonical validation.
    scale_derived = derived_data / "ScaleRelease"
    scale_build = run(
        ["xcodebuild", "-project", "PhotoSync.xcodeproj", "-scheme", "PhotoSync",
         "-configuration", "Release", "-destination", "platform=macOS",
         "-derivedDataPath", str(scale_derived), "CODE_SIGNING_ALLOWED=NO", "ENABLE_TESTABILITY=YES", "build-for-testing"],
        cwd=source_root, environment=environment, log_path=output_dir / "scale-build.log",
        timeout_seconds=BUILD_TIMEOUT_SECONDS, label="optimized scale test host")
    scale_bundle = scale_derived / "Build/Products/Release/PhotoSyncCoreTests.xctest"
    if not scale_bundle.is_dir() or scale_bundle.is_symlink():
        raise ValidationError("Optimized scale test bundle missing")
    scale_results = {}
    scale_phases = [phase_record("scale-build", scale_build, output_dir)]
    for count, history_count in SCALE_PROFILES[scale_profile]:
        sample = str(count) if history_count == 0 else f"{count}-history-{history_count}"
        scale_environment = dict(environment, PHOTOSYNC_SCALE_REPRESENTATIONS=str(count),
                                 PHOTOSYNC_SCALE_HISTORY=str(history_count), PHOTOSYNC_SCALE_BUILD_CONFIGURATION="Release")
        scale = run(
            ["xcrun", "xctest", "-XCTest",
             "PhotoSyncCoreTests.AdvancedDedupRegressionTests/testControlledScaleThroughActualGraph", str(scale_bundle)],
            cwd=source_root, environment=scale_environment, log_path=output_dir / f"scale-{sample}.log",
            timeout_seconds=XCTEST_TIMEOUT_SECONDS, label=f"actual graph synthetic {count} representations + {history_count} history")
        output = read_log(scale.log_path)
        summaries = XCTEST_SUMMARY.findall(output)
        if not summaries or tuple(map(int, summaries[-1])) != (1, 0) or "Selected tests' passed" not in output:
            raise ValidationError(f"Scale {count} did not finish its one selected XCTest")
        report = output_dir / f"scale-{sample}.json"
        validate_scale_result(read_json(report), count=count, history_count=history_count)
        scale_results[sample] = {"result": report.name, "result_sha256": sha256_file(report)}
        scale_phases.append(phase_record(f"scale-{sample}", scale, output_dir))

    tool_tests = run(
        [
            sys.executable,
            "-m",
            "unittest",
            "discover",
            "-v",
            "-s",
            str(source_root / "Tests" / "Tools"),
            "-p",
            "test_*.py",
        ],
        cwd=source_root,
        environment=environment,
        log_path=output_dir / "tool-tests.log",
        timeout_seconds=TOOLS_TIMEOUT_SECONDS,
        label="Python tool tests",
    )
    tool_test_count = validate_unittest_summary(tool_tests.log_path)
    executed_scenarios = validate_runtime_scenarios(source_root / "Tests/Support/RuntimeScenarios.json", xctest.log_path, tool_tests.log_path)
    runtime_artifacts = validate_runtime_artifacts(output_dir)

    continuations = {}
    continuation_phases = []
    for scenario in ("stamp", "advanced-preparation"):
        name = "continuation-race" if scenario == "stamp" else "continuation-advanced-preparation"
        continuation_output = output_dir / name
        continuation = run(
            [sys.executable, "scripts/test-continuation-race.py", "--output-dir", str(continuation_output),
             "--scenario", scenario], cwd=source_root, environment=environment,
            log_path=output_dir / f"{name}.log", timeout_seconds=CONTINUATION_TIMEOUT_SECONDS,
            label=f"{scenario} continuation regression")
        result = validate_continuation_result(continuation_output / "result.json")
        if result.get("scenario") != scenario:
            raise ValidationError("Continuation evidence scenario mismatch")
        continuations[scenario] = {
            "status": result["status"], "regression": result["regression"],
            "result": relative_to_output(continuation_output / "result.json", output_dir),
            "result_sha256": sha256_file(continuation_output / "result.json"),
            "log": relative_to_output(continuation.log_path, output_dir),
        }
        continuation_phases.append(phase_record(name, continuation, output_dir))
    execution_result = json.loads((output_dir / "model-execution.json").read_text())
    validate_model_execution(execution_result)
    model_result = json.loads((output_dir / "model-regression.json").read_text())
    runtime_result = json.loads((output_dir / "runtime-load.json").read_text())
    validate_preparation_budget(runtime_result, label="Runtime")
    if (model_result.get("case_count"), model_result.get("duplicate_count"), model_result.get("skip_count")) != (33, 14, 11):
        raise ValidationError("Missing complete actual-model 33-case regression evidence")
    if runtime_result.get("legacy_imports") != 1 or runtime_result.get("one_changed_inferences") != 1 or runtime_result.get("unchanged_inferences") != 0:
        raise ValidationError("Missing nonempty actual runtime integration evidence")

    compiled_cache = build_source_manifest(derived_data / "model-cache")
    if not compiled_cache.entries:
        raise ValidationError("Actual model compilation cache is absent")
    write_json(output_dir / "compiled-cache.json", {"manifest_sha256": compiled_cache.digest,
        "entries": compiled_cache.entries, "scope": "current OS/CoreML compilation only; not portable source-model identity"})
    after_manifest = build_source_manifest(source_root)
    if after_manifest.digest != before_manifest.digest or after_manifest.entries != before_manifest.entries:
        raise ValidationError("Source snapshot changed while validation was running; refusing to record success.")

    evidence = {
        "status": "passed",
        "scope": "canonical",
        "ui_profile": ui_profile,
        "native_ui": native_evidence,
        "required_scenarios": RUNTIME_SCENARIOS,
        "executed_scenarios": executed_scenarios,
        "runtime_scenarios_sha256": sha256_file(source_root / "Tests/Support/RuntimeScenarios.json"),
        "runtime_artifacts": runtime_artifacts,
        "environment": {"result":"environment.json", "sha256":sha256_file(output_dir / "environment.json")},
        "timing_budget": {"maximum_seconds":CANONICAL_BUDGET_SECONDS[scale_profile], "elapsed_seconds":time.monotonic() - started,
                          "remaining_seconds":max(0, deadline - time.monotonic())},
        "coverage_gaps": ["Real Photos/iCloud writes and historical OS/hardware are not exercised by this synthetic gate"] + ([] if ui_profile == "native" else ["Native scene UI not selected"]),
        "scale_validation": {
            "profile": scale_profile,
            "required_samples": scale_sample_names(scale_profile),
            "executed_samples": list(scale_results),
        },
        "created_at": datetime.now(timezone.utc).isoformat(),
        "source": {
            "root": ".",
            "manifest_sha256": before_manifest.digest,
            "manifest_sha256_after": after_manifest.digest,
            "entry_count": len(before_manifest.entries),
            "unchanged_after_validation": True,
        },
        "configuration": {
            "scheme": "PhotoSync",
            "test_configuration": "Debug",
            "test_destination": "platform=macOS",
            "test_bundle": "Build/Products/Debug/PhotoSyncCoreTests.xctest",
            "release_configuration": "Release",
        },
        "toolchain": {
            "xcodebuild": phase_record("xcodebuild-version", xcode_version, output_dir),
            "swift": phase_record("swift-version", swift_version, output_dir),
        },
        "phases": [
            phase_record("environment", environment_check, output_dir),
            phase_record("build-for-testing", build, output_dir),
            phase_record("xctest", xctest, output_dir),
            phase_record("tool-tests", tool_tests, output_dir),
            phase_record("resources", resources, output_dir),
            phase_record("fixtures", fixtures, output_dir),
        ] + native_phases + scale_phases + continuation_phases,
        "xctest": {
            "test_count": xctest_count,
            "log": relative_to_output(xctest.log_path, output_dir),
        },
        "tool_tests": {
            "test_count": tool_test_count,
            "log": relative_to_output(tool_tests.log_path, output_dir),
        },
        "continuation_race": continuations["stamp"],
        "continuations": continuations,
        "advanced_dedup": {
            "scale": scale_results,
            "resources": "resources.json", "model_regression": "model-regression.json", "runtime_load": "runtime-load.json",
            "resources_sha256": sha256_file(output_dir / "resources.json"),
            "model_execution": "model-execution.json",
            "model_execution_sha256": sha256_file(output_dir / "model-execution.json"),
            "model_regression_sha256": sha256_file(output_dir / "model-regression.json"),
            "runtime_load_sha256": sha256_file(output_dir / "runtime-load.json"),
        },
    }
    validate_scale_evidence(evidence, output_dir=output_dir, expected_profile=scale_profile)
    validate_portable_evidence(evidence, output_dir, expected_ui_profile=ui_profile)
    write_text(output_dir / "validation-report.md", format_report(evidence))
    write_json(output_dir / "validation.json", evidence)


def child_environment() -> dict[str, str]:
    environment = os.environ.copy()
    environment.pop("RQDATAC2_CONF", None)
    # Optional private replay and synthetic child controls are never inherited
    # by the public gate. The dataset is retained for the input gate to reject;
    # the owned overall deadline is the only inherited execution control.
    for name in list(environment):
        if name.startswith("PHOTOSYNC_") and name not in {"PHOTOSYNC_VALIDATION_DEADLINE", "PHOTOSYNC_REGRESSION_DATASET"}:
            environment.pop(name)
    # Python test discovery must not mutate the frozen source snapshot with .pyc files.
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    return environment


def install_cancellation_handlers() -> None:
    def cancelled(signum, frame):
        raise InterruptedError(f"Validation cancelled by signal {signum}")
    signal.signal(signal.SIGTERM, cancelled)
    signal.signal(signal.SIGINT, cancelled)


def validate_runtime_scenarios(manifest_path: Path, swift_log: Path, tools_log: Path) -> list[str]:
    manifest = read_json(manifest_path)
    if manifest.get("schemaVersion") != 1 or not manifest.get("scenarios"):
        raise ValidationError("Runtime scenario manifest missing")
    passed = {cls + "/" + method for cls, method in re.findall(
        r"Test Case '-\[PhotoSyncCoreTests\.(\w+) (\w+)\]' passed", read_log(swift_log))}
    tool_output = read_log(tools_log)
    seen = []
    for scenario in manifest["scenarios"]:
        identity = scenario.get("id")
        if not isinstance(identity, str) or identity in seen: raise ValidationError("Duplicate/missing scenario identity")
        tests, tool_tests = scenario.get("tests", []), scenario.get("toolTests", [])
        if not tests and not tool_tests: raise ValidationError(f"Scenario {identity} has no behavior checks")
        if not set(tests).issubset(passed): raise ValidationError(f"Scenario {identity} did not execute every required XCTest")
        for test in tool_tests:
            cls, method = test.rsplit(".", 1)
            pattern = re.escape(method) + r" \(" + re.escape(cls) + r"(?:\." + re.escape(method) + r")?\)[^\n]*\.\.\. ok"
            if not re.search(pattern, tool_output): raise ValidationError(f"Scenario {identity} did not execute tool check {test}")
        seen.append(identity)
    return seen


def validate_runtime_artifacts(output: Path) -> dict[str, dict[str, str]]:
    restart = read_json(output / "runtime-restart.json")
    if not isinstance(restart, list) or [r.get("phase") for r in restart] != ["seed", "resume", "settled"]:
        raise ValidationError("Missing three-process cold restart evidence")
    if len({r.get("pid") for r in restart}) != 3 or any(not isinstance(r.get("pid"), int) or r["pid"] <= 1 for r in restart):
        raise ValidationError("Cold restart reused a process")
    if [r.get("modelCalls") for r in restart] != [1000, 0, 0] or [r.get("liveReads") for r in restart] != [0, 40, 0] or [r.get("creates") for r in restart] != [0, 1, 0] or restart[-1].get("imported") != 201:
        raise ValidationError("Cold restart lost history, repeated analysis or skipped actual submission")
    resumed_events = restart[1].get("events", [])
    times = {}
    for row in resumed_events: times.setdefault(row.get("kind"), row.get("monotonicOffset"))
    for event in ("first_source_entry", "first_submit_completed"):
        try: elapsed = times[event] - times["runtime_started"]
        except (KeyError, TypeError) as error: raise ValidationError("Missing cold startup event") from error
        if not isinstance(elapsed, (float, int)) or not math.isfinite(elapsed) or not 0 <= elapsed < 2:
            raise ValidationError("Synthetic dependency-ready startup exceeded 2 seconds")
    checkpoints = ["intent", "placeholder", "system-committed", "verified", "retirement-unconfirmed", "retirement-confirmed"]
    crash = read_json(output / "runtime-crash-boundaries.json")
    if not isinstance(crash, list) or [r.get("checkpoint") for r in crash] != checkpoints:
        raise ValidationError("Missing durable crash boundaries")
    for row in crash:
        name = row["checkpoint"]
        if row.get("creates") != (0 if name == "intent" else 1) or row.get("retires") != (0 if name in {"intent", "placeholder"} else 1) or row.get("unknown") is not (name in {"intent", "placeholder", "retirement-unconfirmed"}):
            raise ValidationError("Crash evidence repeated or invented an external mutation")
    sequences = read_json(output / "runtime-sequences.json")
    if not isinstance(sequences, list) or [r.get("seed") for r in sequences] != list(range(1, 21)) or any(len(r.get("events", [])) != 40 or r.get("creates") != 1 for r in sequences):
        raise ValidationError("Missing bounded twenty-seed recovery evidence")
    return {name: {"result":name + ".json", "sha256":sha256_file(output / (name + ".json"))}
            for name in ("runtime-restart", "runtime-crash-boundaries", "runtime-sequences")}


def validate_portable_evidence(evidence: dict, output: Path, *, expected_ui_profile: str) -> None:
    if evidence.get("scope") != "canonical" or evidence.get("status") != "passed": raise ValidationError("Focused or incomplete evidence is not canonical")
    if evidence.get("ui_profile") != expected_ui_profile: raise ValidationError("UI profile mismatch")
    if evidence.get("required_scenarios") != RUNTIME_SCENARIOS or evidence.get("executed_scenarios") != RUNTIME_SCENARIOS:
        raise ValidationError("Missing, duplicate or extra required runtime scenarios")
    source_root = Path(__file__).resolve().parent.parent
    if evidence.get("runtime_scenarios_sha256") != sha256_file(source_root / "Tests/Support/RuntimeScenarios.json"):
        raise ValidationError("Runtime scenario identity mismatch")
    timing = evidence.get("timing_budget", {})
    elapsed, maximum = timing.get("elapsed_seconds"), timing.get("maximum_seconds")
    if not isinstance(elapsed, (int, float)) or not math.isfinite(elapsed) or not isinstance(maximum, (int, float)) or not 0 <= elapsed <= maximum <= 35 * 60:
        raise ValidationError("Missing or exceeded canonical time budget")
    entry = evidence.get("environment", {})
    if entry.get("result") != "environment.json" or entry.get("sha256") != sha256_file(output / "environment.json"):
        raise ValidationError("Environment evidence identity mismatch")
    environment = read_json(output / "environment.json")
    if environment.get("status") != "passed" or environment.get("inputs", {}).get("files_checked", 0) <= 0:
        raise ValidationError("Missing approved environment/input proof")
    if evidence.get("runtime_artifacts") != validate_runtime_artifacts(output): raise ValidationError("Runtime artifact hashes changed")
    if expected_ui_profile == "native":
        entry = evidence.get("native_ui", {}) or {}
        path = output / "native/native-scenes.json"
        if entry.get("result") != "native/native-scenes.json" or entry.get("sha256") != sha256_file(path): raise ValidationError("Native UI evidence changed")
        native = read_json(path)
        if native.get("status") != "passed" or native.get("scope") != "native" or native.get("sourceManifestSHA256") != evidence.get("source", {}).get("manifest_sha256"):
            raise ValidationError("Native UI did not review this canonical source")
        matrix = source_root / "Tests/UIReview/native-scenarios.json"
        if native.get("scenarioManifestSHA256") != sha256_file(matrix): raise ValidationError("Native scenario identity mismatch")
        bundle = path.parent / "PhotosYNC Native Review.app"
        executable_name = native.get("appExecutable")
        if native.get("engine") != "xcuitest" or not isinstance(executable_name, str) or Path(executable_name).name != executable_name:
            raise ValidationError("Native evidence did not use the isolated XCUITest app")
        if (native.get("binarySHA256") != sha256_file(bundle / "Contents/MacOS" / executable_name)
                or native.get("coreFrameworkSHA256") != sha256_file(bundle / "Contents/Frameworks/PhotoSyncCore.framework/PhotoSyncCore")):
            raise ValidationError("Native app binary changed after review")
        spec = importlib.util.spec_from_file_location("photosync_native_consumer", source_root / "Tests/UIReview/run-native-scenes.py")
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        try:
            test_log = path.parent / "xctest.log"
            if native.get("uiTestLogSHA256") != sha256_file(test_log): raise ValueError("Native UI test log changed")
            module.validate_xcuitest_log(read_log(test_log))
            module.validate_matrix(native["frames"], read_json(matrix))
            review = native.get("review", {})
            review_path = path.parent / "ui-review.json"
            if review.get("sha256") != sha256_file(review_path): raise ValueError("Native review receipt changed")
            receipt = read_json(review_path)
            if not native["reviewStartedAt"] <= receipt.get("reviewedAt", 0) <= native["reviewDeadline"]: raise ValueError("Native review was not timely")
            module.validate_review(native, receipt, path.parent, check_deadline=False)
        except (KeyError, TypeError, ValueError) as error: raise ValidationError(str(error)) from error
    elif evidence.get("native_ui") is not None: raise ValidationError("Unselected UI evidence cannot be mixed into a run")


def validate_model_execution(report: dict[str, Any]) -> None:
    expected = {
        "schemaVersion": 1, "policyID": "fp16-ane-gpu-v1",
        "modelSHA256": "026e7a43660e29c307941a88dbe35b9c14468693333ff926e9b984eef3b4b8d0",
        "fingerprintVersion": "fb20bd364a329b23363c0178af9b6af33657feedecdd7c7485531bedd43e242c",
        "selfTestManifestSHA256": "8dfb4ccac57943db5ed867d180916dc6477fa8377017ef9e1b1cdf19e0c993f9",
    }
    if any(report.get(key) != value for key, value in expected.items()):
        raise ValidationError("Missing/wrong FP16 model execution identity")
    configurations = report.get("configurations")
    requested = ["cpuAndNeuralEngine", "cpuAndGPU"] if platform.machine() == "arm64" else ["cpuAndGPU"]
    if not isinstance(configurations, list) or [item.get("requested") for item in configurations] != requested:
        raise ValidationError("Missing approved native configuration evidence")
    for item in configurations:
        golden = item.get("selfTests")
        if not isinstance(golden, list) or len(golden) != 4:
            raise ValidationError("Missing four-instance golden evidence")
        if [entry.get("case") for entry in golden] != [str(i) for i in range(4)]:
            raise ValidationError("Golden cases incomplete or duplicated")
        for entry in golden:
            try:
                max_abs, cosine = float(entry["maxAbs"]), float(entry["cosine"])
            except (KeyError, ValueError, TypeError) as error:
                raise ValidationError("Invalid numerical self-test evidence") from error
            if (entry.get("result") != "passed" or not math.isfinite(max_abs) or not math.isfinite(cosine)
                    or max_abs < 0 or max_abs > 0.02 or cosine < 0.999 or cosine > 1.00001):
                raise ValidationError("Native model instance failed golden thresholds")


def validate_preparation_budget(result: Any, *, label: str) -> None:
    if (not isinstance(result, dict)
            or result.get("performance_contract") != PERFORMANCE_CONTRACT
            or result.get("preparation_p95_budget_ms") != PREPARATION_P95_BUDGET_MS):
        raise ValidationError(f"{label} preparation contract/budget identity is missing or incorrect")
    for field in ("hot_preparation_ms", "source_incremental_ms"):
        timings = result.get(field)
        p95 = timings.get("p95") if isinstance(timings, dict) else None
        if (type(p95) not in (int, float)
                or not 0 <= p95 <= PREPARATION_P95_BUDGET_MS
                or not math.isfinite(p95)):
            raise ValidationError(f"{label} {field} preparation P95 must be finite and within 0..{PREPARATION_P95_BUDGET_MS} ms")


def scale_sample_names(profile: str) -> list[str]:
    return [str(count) if history == 0 else f"{count}-history-{history}" for count, history in SCALE_PROFILES[profile]]


def read_json(path: Path) -> Any:
    """Evidence must not silently discard duplicate keys or accept NaN/Infinity."""
    def object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValidationError(f"Duplicate JSON key in {path.name}: {key}")
            result[key] = value
        return result

    def invalid_constant(value: str) -> None:
        raise ValidationError(f"Non-finite JSON number in {path.name}: {value}")

    return json.loads(path.read_text(), object_pairs_hook=object_pairs, parse_constant=invalid_constant)


def validate_scale_result(result: Any, *, count: int, history_count: int) -> None:
    validate_preparation_budget(result, label=f"Scale {count}")
    rss = result.get("rss_peak_bytes")
    if (result.get("representations") != count or result.get("success_history_vectors") != history_count
            or result.get("budget_pass") is not True or result.get("index_change_ready_within_2s") is not True
            or type(rss) is not int or not 0 < rss <= 4 * 1024**3):
        raise ValidationError(f"Scale {count} failed current runtime/resource budgets")
    observations = result.get("index_change_sample_count_per_operation")
    if (result.get("delta_path_verified") is not True or type(observations) is not int or observations < 5
            or not isinstance(result.get("query_io"), dict) or not isinstance(result.get("unchanged_full_io"), dict)):
        raise ValidationError(f"Scale {count} lacks verified delta/write measurements")
    row_keys = {"rows." + table for table in (
        "photos_representation", "fingerprint_task", "photos_index_exclusion", "dedup_index_state")}
    for field in ("query_io", "unchanged_full_io"):
        rows = result[field]
        if (not row_keys.issubset(rows) or any(type(value) is not int or value < 0
                for key, value in rows.items() if key.startswith("rows."))):
            raise ValidationError(f"Scale {count} lacks valid per-table row-write observations")
    if any(value != 0 for key, value in result["query_io"].items() if key.startswith("rows.")):
        raise ValidationError(f"Scale {count} query wrote persistent rows")
    if any(result["unchanged_full_io"]["rows." + table] != 0 for table in ("photos_representation", "fingerprint_task")):
        raise ValidationError(f"Scale {count} unchanged inventory rewrote representation/task rows")
    if history_count == 100000:
        idle = result.get("idle_60s")
        if not isinstance(idle, dict) or not isinstance(idle.get("after"), dict):
            raise ValidationError("Maximum scale lacks 60-second idle/resume resource evidence")
        values = (idle.get("elapsed_seconds"), idle["after"].get("footprint_bytes"),
                  idle["after"].get("rss_bytes"), idle.get("resume_query_ms"))
        if (any(type(value) not in (int, float) or not math.isfinite(value) for value in values)
                or values[0] < 60 or values[1] <= 0 or values[2] <= 0 or values[3] < 0):
            raise ValidationError("Maximum scale lacks 60-second idle/resume resource evidence")
    if count == 200000 and (not isinstance(result.get("large_source_samples"), list) or len(result["large_source_samples"]) != 2):
        raise ValidationError("Maximum scale lacks both representative large-source measurements")


def validate_scale_evidence(evidence: Any, *, output_dir: Path, expected_profile: str) -> None:
    """Used by both producer and packager; never trust a profile's claimed set."""
    required = scale_sample_names(expected_profile)
    contract = evidence.get("scale_validation") if isinstance(evidence, dict) else None
    if (not isinstance(contract, dict) or contract.get("profile") != expected_profile
            or contract.get("required_samples") != required or contract.get("executed_samples") != required):
        raise ValidationError("Scale profile/required/executed samples do not match the requested profile")
    advanced = evidence.get("advanced_dedup")
    results = advanced.get("scale") if isinstance(advanced, dict) else None
    if not isinstance(results, dict) or set(results) != set(required):
        raise ValidationError("Scale evidence does not contain exactly the required samples")
    phases = evidence.get("phases")
    if not isinstance(phases, list) or any(not isinstance(p, dict) or not isinstance(p.get("name"), str) for p in phases):
        raise ValidationError("Scale execution phases are malformed")
    if [p["name"] for p in phases if p["name"].startswith("scale-")] != ["scale-build", *[f"scale-{s}" for s in required]]:
        raise ValidationError("Scale execution phases are missing, duplicated or unexpected")
    report_files = {p.name for p in output_dir.glob("scale-*.json")}
    if "scale-2.json" in report_files:
        # Complete XCTest also exercises the measurement harness on two rows.
        # Keep/validate that functional evidence, but do not claim it as a
        # profile's optimized performance sample or allow other extra reports.
        smoke = output_dir / "scale-2.json"
        if not smoke.is_file() or smoke.is_symlink():
            raise ValidationError("Functional scale smoke must be a regular report")
        validate_scale_result(read_json(smoke), count=2, history_count=0)
        report_files.remove(smoke.name)
    if report_files != {f"scale-{s}.json" for s in required}:
        raise ValidationError("Scale report files are missing or unexpected")
    for (count, history), sample in zip(SCALE_PROFILES[expected_profile], required):
        entry = results[sample]
        path = output_dir / f"scale-{sample}.json"
        if (not isinstance(entry, dict) or entry.get("result") != path.name or not path.is_file()
                or path.is_symlink() or entry.get("result_sha256") != sha256_file(path)):
            raise ValidationError(f"Scale {sample} report path/hash does not match")
        validate_scale_result(read_json(path), count=count, history_count=history)


def run_command(
    command: Sequence[str],
    *,
    cwd: Path,
    environment: dict[str, str],
    log_path: Path,
    timeout_seconds: float,
    label: str,
    deadline: float | None = None,
) -> CommandResult:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    if deadline is not None:
        timeout_seconds = min(timeout_seconds, deadline - started)
    if timeout_seconds <= 0: raise PhaseFailure(f"Overall deadline expired before {label}.")
    try:
        with log_path.open("wb") as log_file:
            process = subprocess.Popen(
                [str(argument) for argument in command],
                cwd=cwd,
                env=environment,
                stdin=subprocess.DEVNULL,
                stdout=log_file,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            try:
                return_code = process.wait(timeout=timeout_seconds)
            except subprocess.TimeoutExpired as error:
                elapsed = time.monotonic() - started
                raise PhaseFailure(
                    f"{label} timed out after {elapsed:.1f}s; see {log_path.name}."
                ) from error
            finally:
                if process.poll() is None:
                    terminate_process_group(process)
    except OSError as error:
        raise PhaseFailure(f"{label} could not start: {error}.") from error

    elapsed = time.monotonic() - started
    if return_code != 0:
        raise PhaseFailure(f"{label} exited with status {return_code}; see {log_path.name}.")
    return CommandResult(tuple(str(argument) for argument in command), log_path, elapsed)


def terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    """Terminate only the session started by ``run_command`` after a timeout."""

    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    # A group leader exiting does not prove its descendants stopped. Finish
    # reaping this owned group even when a descendant ignored SIGTERM.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=1)


def validate_xctest_summary(log_path: Path) -> int:
    output = read_log(log_path)
    skipped = re.findall(r"Test Case '-\[PhotoSyncCoreTests\.(\w+) (\w+)\]' skipped", output)
    for cls, method in skipped:
        identity = cls + "/" + method
        reason = ALLOWED_XCTEST_SKIPS.get(identity)
        if reason is None or not re.search(re.escape(f"[PhotoSyncCoreTests.{cls} {method}]") + r"[^\n]*" + re.escape(reason), output):
            raise ValidationError(f"Unapproved XCTest skip: {identity}")
    skipped_totals = re.findall(r"Executed\s+\d+\s+tests?,\s+with\s+(\d+)\s+tests?\s+skipped", output)
    if skipped_totals and int(skipped_totals[-1]) != len(skipped): raise ValidationError("Unidentified XCTest skips")
    summaries = XCTEST_SUMMARY.findall(output)
    if not summaries:
        raise ValidationError("XCTest output did not contain a completed test summary.")
    test_count, failure_count = (int(value) for value in summaries[-1])
    has_all_tests_passed = bool(
        re.search(r"(?:Test Suite ['\"]All tests['\"]|All tests)\s+passed", output, re.IGNORECASE)
    )
    if test_count <= 0 or failure_count != 0 or not has_all_tests_passed:
        raise ValidationError(
            "XCTest must report All tests passed with a positive test count and zero failures."
        )
    return test_count


def validate_unittest_summary(log_path: Path) -> int:
    output = read_log(log_path)
    summaries = UNITTEST_SUMMARY.findall(output)
    if not summaries:
        raise ValidationError("Python tool test output did not contain a completed test summary.")
    test_count = int(summaries[-1])
    if test_count <= 0 or not re.search(r"^OK(?:\s|$)", output, re.MULTILINE):
        raise ValidationError("Python tool tests must report a positive test count and OK.")
    return test_count


def validate_continuation_result(result_path: Path) -> dict[str, Any]:
    if not result_path.is_file() or result_path.is_symlink():
        raise ValidationError("Continuation-race regression did not write a regular result.json.")
    with result_path.open(encoding="utf-8") as result_file:
        result = json.load(result_file)
    if not isinstance(result, dict):
        raise ValidationError("Continuation-race result.json must contain an object.")
    if result.get("status") != "passed" or result.get("regression") != "continuation-race":
        raise ValidationError("Continuation-race result.json did not prove the expected passing regression.")
    runs = result.get("runs", {})
    green, red = runs.get("green", {}), runs.get("red", {})
    if (green.get("exit_code") != 0 or green.get("timed_out") is not False or
        green.get("fixture_result", {}).get("status") != "passed" or
        not isinstance(red.get("exit_code"), int) or red["exit_code"] == 0 or red.get("timed_out") is not False or
        red.get("fixture_result", {}).get("status") != "failed" or
        red.get("fixture_result", {}).get("failure_stage") != "assertion" or
        red.get("fixture_result", {}).get("assertion") != "post_resume_waiting_sources"):
        raise ValidationError("Continuation evidence lacks successful GREEN and intended assertion-failing RED")
    return result


def build_source_manifest(source_root: Path) -> SourceManifest:
    entries: list[dict[str, Any]] = []
    for current_root, directory_names, file_names in os.walk(source_root, topdown=True, followlinks=False):
        current_path = Path(current_root)
        retained_directories: list[str] = []
        for directory_name in sorted(directory_names):
            path = current_path / directory_name
            relative = path.relative_to(source_root)
            if should_exclude(relative):
                continue
            mode = os.lstat(path).st_mode
            if stat.S_ISLNK(mode):
                entries.append(manifest_symlink_entry(relative, path, mode))
            elif stat.S_ISDIR(mode):
                retained_directories.append(directory_name)
            else:
                raise ValidationError(f"Unexpected source directory entry: {relative}.")
        directory_names[:] = retained_directories

        for file_name in sorted(file_names):
            path = current_path / file_name
            relative = path.relative_to(source_root)
            if should_exclude(relative):
                continue
            mode = os.lstat(path).st_mode
            if stat.S_ISLNK(mode):
                entries.append(manifest_symlink_entry(relative, path, mode))
            elif stat.S_ISREG(mode):
                entries.append(
                    {
                        "path": relative.as_posix(),
                        "type": "file",
                        "mode": stat.S_IMODE(mode),
                        "sha256": sha256_file(path),
                    }
                )
            else:
                raise ValidationError(f"Unexpected source file entry: {relative}.")

    encoded_entries = json.dumps(entries, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
    return SourceManifest(entries=entries, digest=hashlib.sha256(encoded_entries).hexdigest())


def should_exclude(relative: Path) -> bool:
    return bool(relative.parts) and (
        relative.parts[0] in EXCLUDED_MANIFEST_DIRECTORIES or "__pycache__" in relative.parts
    )


def manifest_symlink_entry(relative: Path, path: Path, mode: int) -> dict[str, Any]:
    return {
        "path": relative.as_posix(),
        "type": "symlink",
        "mode": stat.S_IMODE(mode),
        "target": os.readlink(path),
    }


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source_file:
        for chunk in iter(lambda: source_file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def phase_record(name: str, result: CommandResult, output_dir: Path) -> dict[str, Any]:
    return {
        "name": name,
        "command": display_command(result.command, output_dir),
        "log": relative_to_output(result.log_path, output_dir),
        "elapsed_seconds": round(result.elapsed_seconds, 3),
    }


def display_command(command: Sequence[str], output_dir: Path) -> list[str]:
    displayed: list[str] = []
    for argument in command:
        if argument.startswith(str(output_dir)):
            displayed.append("<validation-output>")
        elif Path(argument).is_absolute():
            displayed.append("<absolute-path>")
        else:
            displayed.append(argument)
    return displayed


def relative_to_output(path: Path, output_dir: Path) -> str:
    return path.relative_to(output_dir).as_posix()


def read_log(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def write_json(path: Path, value: Any) -> None:
    write_text(path, json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


def write_text(path: Path, value: str) -> None:
    temporary_path = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    try:
        temporary_path.write_text(value, encoding="utf-8")
        os.replace(temporary_path, path)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def write_failure(output_dir: Path, error: BaseException) -> None:
    try:
        write_text(output_dir / "failure.txt", f"Validation failed: {error}\n")
    except OSError:
        pass


def format_report(evidence: dict[str, Any]) -> str:
    return "\n".join(
        [
            "# PhotosYNC validation",
            "",
            "Status: passed",
            f"Scope: {evidence['scope']}",
            f"UI profile: {evidence['ui_profile']}",
            f"Runtime scenarios: {', '.join(evidence['executed_scenarios'])}",
            f"Wall time: {evidence['timing_budget']['elapsed_seconds']:.1f}s / {evidence['timing_budget']['maximum_seconds']}s maximum",
            f"XCTest: {evidence['xctest']['test_count']} tests, 0 failures",
            f"Python tool tests: {evidence['tool_tests']['test_count']} tests, OK",
            f"Scale profile: {evidence['scale_validation']['profile']}",
            f"Required scale samples: {', '.join(evidence['scale_validation']['required_samples'])}",
            f"Executed scale samples: {', '.join(evidence['scale_validation']['executed_samples'])}",
            "Continuation race: passed",
            f"Source manifest: {evidence['source']['manifest_sha256']}",
            "",
            "The tests used Debug build-for-testing. The release packager builds the optimized Universal Release app from the same source snapshot after this evidence succeeds.",
            "",
        ]
    )


def path_exists(path: Path) -> bool:
    return os.path.lexists(path)


def is_within(child: Path, parent: Path) -> bool:
    try:
        child.resolve().relative_to(parent.resolve())
    except ValueError:
        return False
    return True


def paths_overlap(first: Path, second: Path) -> bool:
    return is_within(first, second) or is_within(second, first)


def output_path_is_allowed(path: Path, source_root: Path) -> bool:
    return not is_within(path, source_root) or is_within(path, source_root / "work")


if __name__ == "__main__":
    raise SystemExit(main())
