#!/usr/bin/env python3
"""Prove request confirmation races in a disposable source copy, never the shipping runtime.

Output must be a new directory. Optional narrow mutants must fail the named assertion;
compilation failure, zero tests, timeout or a different assertion is not valid RED evidence.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def replace_once(source: str, anchor: str, replacement: str) -> str:
    if source.count(anchor) != 1:
        raise RuntimeError(f"Expected one injection anchor: {anchor!r}")
    return source.replace(anchor, replacement, 1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--mutation", choices=("none", "unfenced-consume", "late-registration"), default="none")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    copy = output / "source"
    files = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root).decode().split("\0")
    for name in filter(None, files):
        source = root / name
        if source.is_symlink() or not source.is_file():
            raise RuntimeError(f"Cannot snapshot source file: {name}")
        destination = copy / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
    runtime = copy / "Sources/PhotoSyncApp/SyncRuntime.swift"
    original = runtime.read_text()
    fixture = (root / "Tests/Regression/ReconciliationRequestRaces.swift").read_text()
    runtime_support, test_support = fixture.split("// RUNTIME SUPPORT\n", 1)[1].split("// TEST SUPPORT\n", 1)
    patched = replace_once(original, "actor SyncRuntime {", """actor SyncRuntime {
    private var coverageReplyProbe: ReconciliationRaceGate?
    private var eventReceiptProbe: ReconciliationRaceGate?
    func holdCoverageReply(using gate: ReconciliationRaceGate) { coverageReplyProbe = gate }
    func holdEventReceipt(using gate: ReconciliationRaceGate) { eventReceiptProbe = gate }
    func capturedAdvancedWorkForRace() -> Task<Void, Never>? { advancedWork }""")
    anchor = "        let receipt = await advancedGraph?.coordinator.libraryChanged(event)"
    patched = replace_once(patched, anchor, anchor + "\n        if let gate = eventReceiptProbe { eventReceiptProbe = nil; await gate.hold() }")
    anchor = "        let covered = await graph.coordinator.reconciliationCovers(change: receipt)"
    patched = replace_once(patched, anchor, anchor + "\n        if covered, let gate = coverageReplyProbe { coverageReplyProbe = nil; await gate.hold() }")
    if args.mutation == "unfenced-consume":
        patched = replace_once(patched, "if covered && pendingFullChangeSerial == receipt", "if covered")
    if args.mutation == "late-registration":
        patched = replace_once(patched, "        await consumeCoveredFullChange()\n        await tick()", "        await tick()")
    runtime.write_text(patched + "\n" + runtime_support)
    tests = copy / "Tests/PhotoSyncCoreTests/AdvancedRuntimeTests.swift"
    tests.write_text(tests.read_text() + "\n" + test_support)
    commands = [
        ["xcodebuild", "-project", "PhotoSync.xcodeproj", "-scheme", "PhotoSync", "-destination", "platform=macOS", "-derivedDataPath", str(output / "derived"), "CODE_SIGNING_ALLOWED=NO", "build-for-testing"],
        ["xcrun", "xctest", "-XCTest", ",".join("PhotoSyncCoreTests.AdvancedRuntimeTests/" + name for name in ["testCoverageReplyPreservesNewFullContextForceAndPermissionRequests", "testDelayedCoveredReceiptDoesNotRequestAnotherCatalog"]), str(output / "derived/Build/Products/Debug/PhotoSyncCoreTests.xctest")],
    ]
    results = []
    for index, command in enumerate(commands):
        log = output / ("build.log" if index == 0 else "tests.log")
        with log.open("w") as handle:
            result = subprocess.run(command, cwd=copy, stdout=handle, stderr=subprocess.STDOUT, timeout=600 if index == 0 else 90)
        results.append({"command": command, "exitCode": result.returncode, "log": log.name})
        if index == 0 and result.returncode != 0:
            raise RuntimeError("Scratch build failed; this is not RED evidence")
    text = (output / "tests.log").read_text()
    expected = {"unfenced-consume": "coverage_reply_preserves_new_", "late-registration": "delayed_covered_receipt"}
    passed = results[-1]["exitCode"] == 0 and "Executed 2 tests, with 0 failures" in text
    if args.mutation != "none":
        assertion_lines = [line for line in text.splitlines() if " error: " in line]
        passed = results[-1]["exitCode"] != 0 and "Executed 2 tests" in text and bool(assertion_lines) and all(expected[args.mutation] in line and "XCTAssertEqual failed" in line for line in assertion_lines)
    report = {"passed": passed, "mutation": args.mutation, "runtimeSHA256": hashlib.sha256(original.encode()).hexdigest(), "results": results}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": passed, "mutation": args.mutation, "report": str(output / "report.json")}))
    if not passed:
        raise RuntimeError("Scratch tests did not produce the required GREEN or intended RED")


if __name__ == "__main__":
    main()
