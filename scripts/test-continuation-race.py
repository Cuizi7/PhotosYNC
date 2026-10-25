#!/usr/bin/env python3
"""Run the isolated continuation-race regression against disposable Core sources.

The checked-in SyncEngine is never modified.  This runner copies its current source tree, injects
one gate after the selected uniquely identified no-attempt retry write, observes round failures,
and proves both sides of the test:
the guarded implementation passes and a narrowly mutated historical implementation fails the
specific post-resume waiting assertion.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import difflib
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from typing import Any, Sequence


REPO_ROOT = Path(__file__).resolve().parents[1]
CORE_RELATIVE = Path("Sources/PhotoSyncCore")
PROBE_RELATIVE = Path("Tests/Regression/ContinuationRace.swift")
ENGINE_RELATIVE = Path("Sync/SyncEngine.swift")
RETRY_ANCHOR = (
    "try await store.recordRetry(fileID: record.id, attemptID: nil, "
    "nextRetry: nextRetry(for: record), error: message, definitelyNotCommitted: true)"
)
ADVANCED_RETRY_ANCHOR = (
    "try await store.recordRetry(fileID: record.id, attemptID: nil, nextRetry: nextRetry(for: record),\n"
    "                                                        error: error.localizedDescription, definitelyNotCommitted: true)"
)
GATE_LINE = "await integrationRetryGate.wait()"
EXPECTED_RED_ASSERTION = "post_resume_waiting_sources"
VECTOR_BRIDGE_FLAGS = ["-O3", "-fno-fast-math", "-ffp-contract=off"]


class RunnerError(RuntimeError):
    """An expected gate failure with a concise public error message."""


@dataclass
class ProcessResult:
    command: list[str]
    exit_code: int | None
    timed_out: bool
    elapsed_seconds: float


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", choices=("stamp", "advanced-preparation"), default="stamp",
                        help="Retry continuation to exercise (default: stamp).")
    parser.add_argument("--output-dir", required=True, type=Path, help="A new absolute evidence directory.")
    parser.add_argument(
        "--timeout-seconds",
        default=45.0,
        type=positive_seconds,
        help="Bound for each compiler or probe process (default: 45).",
    )
    return parser.parse_args()


def positive_seconds(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("timeout must be a number") from error
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError("timeout must be a finite number greater than zero")
    return parsed


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_tree(path: Path) -> str:
    digest = hashlib.sha256()
    for child in sorted(item for item in path.rglob("*") if item.is_file()):
        digest.update(child.relative_to(path).as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(bytes.fromhex(sha256_file(child)))
    return digest.hexdigest()


def write_json(path: Path, value: Any) -> None:
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False
        ) as handle:
            temporary_path = Path(handle.name)
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary_path, path)
    finally:
        if temporary_path is not None and temporary_path.exists():
            temporary_path.unlink()


def write_text(path: Path, value: str) -> None:
    path.write_text(value, encoding="utf-8")


def checked_source_paths() -> tuple[Path, Path, Path]:
    core = REPO_ROOT / CORE_RELATIVE
    probe = REPO_ROOT / PROBE_RELATIVE
    engine = core / ENGINE_RELATIVE
    if not core.is_dir() or not engine.is_file() or not probe.is_file():
        raise RunnerError("Continuation race sources are missing from this snapshot.")
    return core, engine, probe


def require_new_absolute_directory(path: Path) -> Path:
    if not path.is_absolute():
        raise RunnerError("--output-dir must be an absolute path.")
    if path.exists() or path.is_symlink():
        raise RunnerError(f"Refusing to overwrite continuation-race evidence: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.mkdir()
    return path


def replace_unique(text: str, expected: str, replacement: str, name: str) -> str:
    count = text.count(expected)
    if count != 1:
        raise RunnerError(f"{name} must occur exactly once; found {count}.")
    return text.replace(expected, replacement, 1)


def instrument_green_engine(original: str, scenario: str = "stamp") -> str:
    if GATE_LINE in original:
        raise RunnerError("SyncEngine already contains the continuation probe gate.")
    anchor = RETRY_ANCHOR if scenario == "stamp" else ADVANCED_RETRY_ANCHOR
    count = original.count(anchor)
    if count != 1:
        raise RunnerError(f"The no-attempt recordRetry anchor must occur exactly once; found {count}.")
    indentation = original[original.rfind("\n", 0, original.index(anchor)) + 1 : original.index(anchor)]
    result = original.replace(anchor, f"{anchor}\n{indentation}{GATE_LINE}", 1)
    if result.count(GATE_LINE) != 1:
        raise RunnerError("The continuation probe gate was not inserted exactly once.")
    round_anchor = "    private func recordRoundFailure(_ roundID: UUID, fileLevel: Bool = false) {"
    return replace_unique(result, round_anchor, round_anchor + "\n        integrationRoundFailures.record()",
                          "round-failure observation anchor")


def mutate_historical_behavior(green: str) -> str:
    """Remove only the selected branch's post-write guard; keep shared cancellation intact."""

    before_gate, separator, after_gate = green.partition(GATE_LINE)
    if not separator or GATE_LINE in after_gate:
        raise RunnerError("Historical mutation requires exactly one continuation probe gate.")
    before_failure, separator, after_failure = after_gate.partition("recordRoundFailure(context.roundID)")
    if not separator:
        raise RunnerError("Selected retry branch has no round-failure publication.")
    guard = "                        guard pendingStampFailureID == record.id else { continue }\n"
    before_failure = replace_unique(before_failure, guard, "", "selected pending retry identity guard")
    return before_gate + GATE_LINE + before_failure + separator + after_failure


def unified_diff(before: str, after: str, fromfile: str, tofile: str) -> str:
    return "".join(
        difflib.unified_diff(
            before.splitlines(keepends=True),
            after.splitlines(keepends=True),
            fromfile=fromfile,
            tofile=tofile,
        )
    )


def stop_own_process_group(process: subprocess.Popen[str]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired as error:
        raise RunnerError("Timed-out continuation child did not exit after its own process group was killed.") from error


def run_process(
    command: Sequence[str], *, cwd: Path, timeout_seconds: float, stdout_path: Path, stderr_path: Path
) -> ProcessResult:
    environment = os.environ.copy()
    # No credential/configuration needed for an isolated Swift process; do not propagate it into
    # captured evidence even when a caller happens to have it in their shell.
    environment.pop("RQDATAC2_CONF", None)
    start = time.monotonic()
    with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
        process = subprocess.Popen(
            list(command),
            cwd=cwd,
            env=environment,
            text=True,
            stdout=stdout,
            stderr=stderr,
            start_new_session=True,
        )
        try:
            exit_code = process.wait(timeout=timeout_seconds)
            return ProcessResult(list(command), exit_code, False, time.monotonic() - start)
        except subprocess.TimeoutExpired:
            stop_own_process_group(process)
            return ProcessResult(list(command), process.returncode, True, time.monotonic() - start)
        finally:
            if process.poll() is None:
                stop_own_process_group(process)


def compile_probe(scenario: Path, timeout_seconds: float) -> ProcessResult:
    source_directory = scenario / "PhotoSyncCore"
    fixture = scenario / "ContinuationRace.swift"
    executable = scenario / "continuation-race"
    source_files = sorted(source_directory.rglob("*.swift"))
    if not source_files:
        raise RunnerError(f"No Core Swift files were copied for {scenario.name}.")
    bridge = source_directory / "Storage/SQLiteVectorQuery"
    object_file = scenario / "SQLiteVectorQuery.o"
    c_command = ["xcrun", "clang", *VECTOR_BRIDGE_FLAGS, "-c", str(bridge / "SQLiteVectorQuery.c"), "-o", str(object_file)]
    write_json(scenario / "bridge-compile-command.json", c_command)
    c_result = run_process(c_command, cwd=scenario, timeout_seconds=timeout_seconds,
                           stdout_path=scenario / "bridge-compile.stdout.log", stderr_path=scenario / "bridge-compile.stderr.log")
    if c_result.timed_out:
        raise RunnerError(f"{scenario.name} SQLite vector bridge compilation timed out.")
    if c_result.exit_code != 0:
        raise RunnerError(f"{scenario.name} SQLite vector bridge compilation failed; inspect bridge-compile.stderr.log.")
    command = [
        "xcrun",
        "swiftc",
        "-parse-as-library",
        "-module-name",
        "PhotoSyncCore",
        "-I", str(bridge),
        "-module-cache-path", str(scenario / "module-cache"),
        *map(str, source_files),
        str(fixture),
        str(object_file),
        "-o",
        str(executable),
        "-framework",
        "Photos",
        "-framework",
        "AVFoundation",
        "-framework",
        "ImageIO",
        "-framework",
        "UniformTypeIdentifiers",
        "-lsqlite3",
        "-framework", "Accelerate",
    ]
    write_json(scenario / "compile-command.json", command)
    result = run_process(
        command,
        cwd=scenario,
        timeout_seconds=timeout_seconds,
        stdout_path=scenario / "compile.stdout.log",
        stderr_path=scenario / "compile.stderr.log",
    )
    if result.timed_out:
        raise RunnerError(f"{scenario.name} continuation probe compilation timed out.")
    if result.exit_code != 0 or not executable.is_file():
        raise RunnerError(f"{scenario.name} continuation probe compilation failed; inspect compile.stderr.log.")
    return result


def run_probe(scenario: Path, timeout_seconds: float, probe_scenario: str = "stamp") -> ProcessResult:
    evidence_directory = scenario / "fixture-evidence"
    command = [str(scenario / "continuation-race"), "--evidence-dir", str(evidence_directory),
               "--scenario", probe_scenario]
    write_json(scenario / "run-command.json", command)
    return run_process(
        command,
        cwd=scenario,
        timeout_seconds=timeout_seconds,
        stdout_path=scenario / "run.stdout.log",
        stderr_path=scenario / "run.stderr.log",
    )


def fixture_result(scenario: Path) -> dict[str, Any]:
    path = scenario / "fixture-evidence" / "fixture.json"
    if not path.is_file():
        raise RunnerError(f"{scenario.name} probe did not write fixture-evidence/fixture.json.")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise RunnerError(f"{scenario.name} fixture evidence is not valid JSON.") from error
    if not isinstance(value, dict):
        raise RunnerError(f"{scenario.name} fixture evidence must be an object.")
    return value


def validate_green(result: ProcessResult, fixture: dict[str, Any]) -> None:
    if result.timed_out:
        raise RunnerError("Green continuation probe timed out.")
    if result.exit_code != 0:
        raise RunnerError("Green continuation probe failed; inspect green/run.stderr.log.")
    if fixture.get("status") != "passed":
        raise RunnerError("Green continuation probe exited successfully without a passed fixture result.")


def validate_red(result: ProcessResult, fixture: dict[str, Any]) -> None:
    if result.timed_out:
        raise RunnerError("Red continuation mutation timed out instead of proving its expected assertion.")
    if result.exit_code == 0:
        raise RunnerError("Red continuation mutation unexpectedly passed.")
    observation = fixture.get("observation")
    if not isinstance(observation, dict):
        raise RunnerError("Red continuation mutation did not record an assertion observation.")
    try:
        waiting_sources = int(observation.get("waiting_sources", "0"))
    except (TypeError, ValueError) as error:
        raise RunnerError("Red continuation mutation recorded a non-numeric waiting-source count.") from error
    if (
        fixture.get("status") != "failed"
        or fixture.get("failure_stage") != "assertion"
        or fixture.get("assertion") != EXPECTED_RED_ASSERTION
        or observation.get("row_state") != "skipped"
        or waiting_sources < 1
    ):
        raise RunnerError(
            "Red continuation mutation did not fail the expected skipped-row waiting assertion."
        )


def prepare_scenario(
    output: Path, name: str, core: Path, probe: Path, engine_after: str
) -> Path:
    scenario = output / name
    shutil.copytree(core, scenario / "PhotoSyncCore")
    shutil.copy2(probe, scenario / "ContinuationRace.swift")
    engine = scenario / "PhotoSyncCore" / ENGINE_RELATIVE
    write_text(engine, engine_after)
    write_json(
        scenario / "source.json",
        {
            "core_tree_sha256": sha256_tree(scenario / "PhotoSyncCore"),
            "sync_engine_sha256": sha256_file(engine),
            "fixture_sha256": sha256_file(scenario / "ContinuationRace.swift"),
        },
    )
    return scenario


def relative_result(output: Path, result: ProcessResult, scenario: Path, fixture: dict[str, Any]) -> dict[str, Any]:
    return {
        **asdict(result),
        "scenario": scenario.relative_to(output).as_posix(),
        "fixture_result": fixture,
    }


def run(args: argparse.Namespace, output: Path) -> dict[str, Any]:
    core, engine, probe = checked_source_paths()
    original = engine.read_text(encoding="utf-8")
    green_engine = instrument_green_engine(original, args.scenario)
    red_engine = mutate_historical_behavior(green_engine)
    write_text(output / "instrumentation-green.diff", unified_diff(original, green_engine, "SyncEngine.swift", "green/SyncEngine.swift"))
    write_text(output / "instrumentation-red.diff", unified_diff(green_engine, red_engine, "green/SyncEngine.swift", "red/SyncEngine.swift"))
    source_hashes = {
        "core_tree_sha256": sha256_tree(core),
        "sync_engine_sha256": sha256_file(engine),
        "fixture_sha256": sha256_file(probe),
        "green_sync_engine_sha256": hashlib.sha256(green_engine.encode("utf-8")).hexdigest(),
        "red_sync_engine_sha256": hashlib.sha256(red_engine.encode("utf-8")).hexdigest(),
        "vector_bridge_compile_flags": VECTOR_BRIDGE_FLAGS,
    }
    if args.scenario == "advanced-preparation":
        source_hashes["profile_sha256"] = sha256_file(REPO_ROOT / "docs/research/advanced-dedup/integration-profile.json")
    write_json(output / "source-hashes.json", source_hashes)

    green = prepare_scenario(output, "green", core, probe, green_engine)
    if args.scenario == "advanced-preparation":
        shutil.copy2(REPO_ROOT / "docs/research/advanced-dedup/integration-profile.json", green / "integration-profile.json")
    green_compile = compile_probe(green, args.timeout_seconds)
    green_run = run_probe(green, args.timeout_seconds, args.scenario)
    if green_run.timed_out:
        raise RunnerError("Green continuation probe timed out.")
    if green_run.exit_code != 0:
        raise RunnerError("Green continuation probe failed; inspect green/run.stderr.log.")
    green_fixture = fixture_result(green)
    validate_green(green_run, green_fixture)

    red = prepare_scenario(output, "red", core, probe, red_engine)
    if args.scenario == "advanced-preparation":
        shutil.copy2(REPO_ROOT / "docs/research/advanced-dedup/integration-profile.json", red / "integration-profile.json")
    red_compile = compile_probe(red, args.timeout_seconds)
    red_run = run_probe(red, args.timeout_seconds, args.scenario)
    if red_run.timed_out:
        raise RunnerError("Red continuation mutation timed out instead of proving its expected assertion.")
    if red_run.exit_code == 0:
        raise RunnerError("Red continuation mutation unexpectedly passed.")
    red_fixture = fixture_result(red)
    validate_red(red_run, red_fixture)

    return {
        "status": "passed",
        "regression": "continuation-race",
        "scenario": args.scenario,
        "source": source_hashes,
        "instrumentation": {
            "green_diff": "instrumentation-green.diff",
            "green_diff_sha256": sha256_file(output / "instrumentation-green.diff"),
            "red_diff": "instrumentation-red.diff",
            "red_diff_sha256": sha256_file(output / "instrumentation-red.diff"),
        },
        "timeout_seconds": args.timeout_seconds,
        "runs": {
            "green_compile": relative_result(output, green_compile, green, {"status": "passed"}),
            "green": relative_result(output, green_run, green, green_fixture),
            "red_compile": relative_result(output, red_compile, red, {"status": "passed"}),
            "red": relative_result(output, red_run, red, red_fixture),
        },
    }


def main() -> int:
    def cancelled(signum, frame): raise InterruptedError(f"Continuation cancelled by signal {signum}")
    signal.signal(signal.SIGTERM, cancelled)
    signal.signal(signal.SIGINT, cancelled)
    args = parse_arguments()
    output: Path | None = None
    try:
        output = require_new_absolute_directory(args.output_dir)
        result = run(args, output)
        write_json(args.output_dir / "result.json", result)
        print(f"CONTINUATION_RACE_PASS {args.output_dir}")
        return 0
    except (OSError, RunnerError, subprocess.SubprocessError, ValueError) as error:
        if output is not None and output.exists():
            write_json(
                output / "failure.json",
                {"status": "failed", "regression": "continuation-race", "error": str(error)},
            )
        print(f"CONTINUATION_RACE_FAIL {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
