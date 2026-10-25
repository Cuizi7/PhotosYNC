#!/usr/bin/env python3
"""Run an explicit, bounded development suite; never emit canonical evidence."""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import time


SUITES = {
    "startup": ["StartupRecoveryTests", "AdvancedRuntimeTests"],
    "recovery": ["EngineTests", "LivePhotoCoordinatorTests", "LivePhotoInventoryTests", "LivePhotoStoreTests", "StoreTests", "RuntimeEventSequenceTests"],
    "ui": ["AppViewTests", "AppModelTests", "GlobalStatusTests", "SyncStatusPresentationTests"],
    "tools": [],
}


def validate_selected_output(output: str, required: list[str]) -> int:
    summaries = re.findall(r"Executed\s+(\d+)\s+tests?,\s+with\s+(?:\d+\s+tests?\s+skipped\s+and\s+)?(\d+)\s+failures?", output)
    passed = {cls for cls, _ in re.findall(r"Test Case '-\[PhotoSyncCoreTests\.(\w+) (\w+)\]' passed", output)}
    if not summaries or int(summaries[-1][0]) <= 0 or int(summaries[-1][1]) != 0 or "Selected tests' passed" not in output or not set(required).issubset(passed):
        raise ValueError("Selected suite did not execute every required class with passing results")
    return int(summaries[-1][0])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=SUITES, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--derived-data", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    spec = importlib.util.spec_from_file_location("photosync_focused_validation", root / "scripts/validate.py")
    gate = importlib.util.module_from_spec(spec); sys.modules[spec.name] = gate; spec.loader.exec_module(gate)
    gate.install_cancellation_handlers()
    started = time.monotonic(); deadline = started + 480
    try:
        gate.prepare_paths(source_root=root, output_dir=args.output_dir, derived_data=args.derived_data)
        args.output_dir.mkdir()
        environment = gate.child_environment()
        def run(command, name, seconds):
            return gate.run_command(command, cwd=root, environment=environment, log_path=args.output_dir / (name + ".log"),
                                    timeout_seconds=seconds, deadline=deadline, label=name)
        before = gate.build_source_manifest(root)
        run([sys.executable, "scripts/test-environment.py", "--check", "--output", str(args.output_dir / "environment.json")], "environment", 60)
        if args.suite == "tools":
            result = run([sys.executable, "-m", "unittest", "discover", "-v", "-s", "Tests/Tools", "-p", "test_*.py"], "tools", 300)
            count = gate.validate_unittest_summary(result.log_path)
        else:
            run(["xcodebuild", "-project", "PhotoSync.xcodeproj", "-scheme", "PhotoSync", "-destination", "platform=macOS",
                 "-derivedDataPath", str(args.derived_data), "CODE_SIGNING_ALLOWED=NO", "ONLY_ACTIVE_ARCH=YES", "build-for-testing"], "build", 300)
            bundle = args.derived_data / "Build/Products/Debug/PhotoSyncCoreTests.xctest"
            result = run(["xcrun", "xctest", "-XCTest", ",".join("PhotoSyncCoreTests." + item for item in SUITES[args.suite]), str(bundle)], "tests", 180)
            count = validate_selected_output(result.log_path.read_text(), SUITES[args.suite])
        after = gate.build_source_manifest(root)
        if before.digest != after.digest: raise ValueError("Source changed during focused verification")
        gate.write_json(args.output_dir / "focused.json", {"scope":"focused", "status":"passed", "suite":args.suite,
            "source_manifest_sha256":before.digest, "test_count":count, "elapsed_seconds":time.monotonic() - started,
            "maximum_seconds":480, "canonical":False})
        print(f"Focused {args.suite} passed: {args.output_dir / 'focused.json'}")
        return 0
    except (OSError, ValueError, gate.ValidationError) as error:
        if args.output_dir.is_dir(): gate.write_json(args.output_dir / "focused-failure.json", {"scope":"focused", "status":"failed", "reason":str(error)})
        print(f"Focused verification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__": raise SystemExit(main())
