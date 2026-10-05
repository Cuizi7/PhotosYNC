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
import json
import os
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
    arguments = parser().parse_args(arguments)
    source_root = Path(__file__).resolve().parent.parent
    output_dir = arguments.output_dir
    output_created = False

    try:
        prepare_paths(source_root=source_root, output_dir=output_dir, derived_data=arguments.derived_data)
        output_dir.mkdir()
        output_created = True
        validate(source_root=source_root, output_dir=output_dir, derived_data=arguments.derived_data)
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


def validate(*, source_root: Path, output_dir: Path, derived_data: Path) -> None:
    environment = child_environment()
    for name in ("PHOTOSYNC_SCALE_REPRESENTATIONS", "PHOTOSYNC_SCALE_HISTORY", "PHOTOSYNC_SCALE_BUILD_CONFIGURATION"):
        environment.pop(name, None)
    if environment.get("CI", "").lower() in {"1", "true", "yes"}:
        raise ValidationError("The authorized local corpus includes non-redistributable user photos; public CI is not approved.")
    environment["PHOTOSYNC_REGRESSION_DATASET"] = str(source_root / "Tests/Fixtures/AdvancedDedup")
    environment["PHOTOSYNC_ACCEPTANCE_OUTPUT"] = str(output_dir)
    environment["PHOTOSYNC_MODEL_CACHE_DIR"] = str(derived_data / "model-cache")
    resources = run_command(
        [sys.executable, "scripts/advanced-dedup/release.py", "--resources",
         str(source_root / "Sources/PhotoSyncCore/Resources/AdvancedDedup"),
         "--output", str(output_dir / "resources.json")], cwd=source_root, environment=environment,
        log_path=output_dir / "resources.log", timeout_seconds=60, label="fixed model resources")
    fixtures = run_command(
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

    xcode_version = run_command(
        ["xcodebuild", "-version"],
        cwd=source_root,
        environment=environment,
        log_path=output_dir / "xcodebuild-version.log",
        timeout_seconds=TOOLCHAIN_TIMEOUT_SECONDS,
        label="xcodebuild version",
    )
    swift_version = run_command(
        ["xcrun", "swift", "--version"],
        cwd=source_root,
        environment=environment,
        log_path=output_dir / "swift-version.log",
        timeout_seconds=TOOLCHAIN_TIMEOUT_SECONDS,
        label="Swift version",
    )
    build = run_command(
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

    xctest = run_command(
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
    scale_build = run_command(
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
    for count, history_count in ((100000, 0), (150000, 0), (200000, 0), (200000, 100000)):
        sample = str(count) if history_count == 0 else f"{count}-history-{history_count}"
        scale_environment = dict(environment, PHOTOSYNC_SCALE_REPRESENTATIONS=str(count),
                                 PHOTOSYNC_SCALE_HISTORY=str(history_count), PHOTOSYNC_SCALE_BUILD_CONFIGURATION="Release")
        scale = run_command(
            ["xcrun", "xctest", "-XCTest",
             "PhotoSyncCoreTests.AdvancedDedupRegressionTests/testControlledScaleThroughActualGraph", str(scale_bundle)],
            cwd=source_root, environment=scale_environment, log_path=output_dir / f"scale-{sample}.log",
            timeout_seconds=XCTEST_TIMEOUT_SECONDS, label=f"actual graph synthetic {count} representations + {history_count} history")
        output = read_log(scale.log_path)
        summaries = XCTEST_SUMMARY.findall(output)
        if not summaries or tuple(map(int, summaries[-1])) != (1, 0) or "Selected tests' passed" not in output:
            raise ValidationError(f"Scale {count} did not finish its one selected XCTest")
        report = output_dir / f"scale-{sample}.json"
        result = json.loads(report.read_text())
        if result.get("representations") != count or result.get("success_history_vectors") != history_count or result.get("budget_pass") is not True:
            raise ValidationError(f"Scale {count} failed current runtime/resource budgets")
        if count == 200000 and len(result.get("large_source_samples", [])) != 2:
            raise ValidationError("Maximum scale lacks both representative large-source measurements")
        scale_results[sample] = {"result": report.name, "result_sha256": sha256_file(report)}
        scale_phases.append(phase_record(f"scale-{sample}", scale, output_dir))

    tool_tests = run_command(
        [
            sys.executable,
            "-m",
            "unittest",
            "discover",
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

    continuations = {}
    continuation_phases = []
    for scenario in ("stamp", "advanced-preparation"):
        name = "continuation-race" if scenario == "stamp" else "continuation-advanced-preparation"
        continuation_output = output_dir / name
        continuation = run_command(
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
    model_result = json.loads((output_dir / "model-regression.json").read_text())
    runtime_result = json.loads((output_dir / "runtime-load.json").read_text())
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
            phase_record("build-for-testing", build, output_dir),
            phase_record("xctest", xctest, output_dir),
            phase_record("tool-tests", tool_tests, output_dir),
            phase_record("resources", resources, output_dir),
            phase_record("fixtures", fixtures, output_dir),
        ] + scale_phases + continuation_phases,
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
            "model_regression_sha256": sha256_file(output_dir / "model-regression.json"),
            "runtime_load_sha256": sha256_file(output_dir / "runtime-load.json"),
        },
    }
    write_text(output_dir / "validation-report.md", format_report(evidence))
    write_json(output_dir / "validation.json", evidence)


def child_environment() -> dict[str, str]:
    environment = os.environ.copy()
    environment.pop("RQDATAC2_CONF", None)
    # Python test discovery must not mutate the frozen source snapshot with .pyc files.
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    return environment


def run_command(
    command: Sequence[str],
    *,
    cwd: Path,
    environment: dict[str, str],
    log_path: Path,
    timeout_seconds: float,
    label: str,
) -> CommandResult:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
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
                terminate_process_group(process)
                elapsed = time.monotonic() - started
                raise PhaseFailure(
                    f"{label} timed out after {elapsed:.1f}s; see {log_path.name}."
                ) from error
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
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            return
        process.wait()


def validate_xctest_summary(log_path: Path) -> int:
    output = read_log(log_path)
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
            f"XCTest: {evidence['xctest']['test_count']} tests, 0 failures",
            f"Python tool tests: {evidence['tool_tests']['test_count']} tests, OK",
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
