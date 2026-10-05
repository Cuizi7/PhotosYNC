"""Executable contract tests for the local release validation gate."""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


WORKTREE_ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = WORKTREE_ROOT / "scripts" / "validate.py"
PACKAGER = WORKTREE_ROOT / "scripts" / "package-release.sh"
BUILD_DMG = WORKTREE_ROOT / "scripts" / "build-dmg.sh"


class ReleaseFixture:
    """A committed, minimal repository exercised through the real entry points."""

    def __init__(self, temporary_directory: tempfile.TemporaryDirectory[str]) -> None:
        self.root = Path(temporary_directory.name) / "repository"
        self.events = Path(temporary_directory.name) / "events.log"
        self.bin_dir = Path(temporary_directory.name) / "bin"
        self.root.mkdir()
        self.bin_dir.mkdir()
        self._write_repository()
        self._write_fake_tools()
        subprocess.run(["git", "init", "--quiet"], cwd=self.root, check=True)
        subprocess.run(["git", "config", "user.email", "tests@example.invalid"], cwd=self.root, check=True)
        subprocess.run(["git", "config", "user.name", "Release gate tests"], cwd=self.root, check=True)
        hooks_directory = self.root / ".fixture-hooks"
        hooks_directory.mkdir()
        subprocess.run(["git", "config", "commit.gpgsign", "false"], cwd=self.root, check=True)
        subprocess.run(["git", "config", "core.hooksPath", str(hooks_directory)], cwd=self.root, check=True)
        subprocess.run(["git", "add", "."], cwd=self.root, check=True)
        subprocess.run(["git", "commit", "--quiet", "-m", "fixture"], cwd=self.root, check=True)

    def environment(self, **overrides: str) -> dict[str, str]:
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{self.bin_dir}:{environment['PATH']}",
                "FAKE_EVENTS": str(self.events),
                "RQDATAC2_CONF": "must-not-reach-child-tools",
            }
        )
        environment.update(overrides)
        return environment

    def run_validator(self, output_dir: Path, derived_data: Path, **environment: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "scripts/validate.py", "--output-dir", str(output_dir), "--derived-data", str(derived_data)],
            cwd=self.root,
            env=self.environment(**environment),
            text=True,
            capture_output=True,
            check=False,
        )

    def run_packager(self, **environment: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["zsh", "scripts/package-release.sh"],
            cwd=self.root,
            env=self.environment(**environment),
            text=True,
            capture_output=True,
            check=False,
        )

    def event_lines(self) -> list[str]:
        if not self.events.exists():
            return []
        return self.events.read_text().splitlines()

    def release_path(self) -> Path:
        return self.root / "outputs" / "releases" / "0.1.0"

    def _write_repository(self) -> None:
        for relative in ("scripts", "Tests/Tools", "docs/release", "PhotoSync.xcodeproj"):
            (self.root / relative).mkdir(parents=True, exist_ok=True)
        shutil.copy2(VALIDATOR, self.root / "scripts" / "validate.py")
        shutil.copy2(PACKAGER, self.root / "scripts" / "package-release.sh")
        shutil.copy2(BUILD_DMG, self.root / "scripts" / "build-dmg.sh")
        (self.root / ".gitignore").write_text("/work/\n/outputs/releases/\n")
        (self.root / "PhotoSync.xcodeproj" / "project.pbxproj").write_text("fixture project\n")
        (self.root / "Sources").mkdir()
        (self.root / "Sources" / "fixture.swift").write_text("let fixture = true\n")
        (self.root / "docs/release/0.1.0.md").write_text("fixture release notes\n")
        (self.root / "CHANGELOG.md").write_text("fixture changelog\n")
        (self.root / "Tests/Tools/test_fixture.py").write_text(
            "import unittest\n\n"
            "class FixtureTests(unittest.TestCase):\n"
            "    def test_synthetic_fixture_passes(self):\n"
            "        self.assertEqual('fixture', 'fixture')\n\n"
            "if __name__ == '__main__':\n"
            "    unittest.main()\n"
        )
        for directory in ("scripts/advanced-dedup", "scripts/dedup-fixtures"):
            (self.root / directory).mkdir()
        # Physical resource/model work is replaced only in this synthetic CLI
        # orchestration fixture; exact-byte gates have their own independent tests.
        (self.root / "scripts/advanced-dedup/release.py").write_text(
            "import argparse,json,os,sys\nfrom pathlib import Path\n"
            "p=argparse.ArgumentParser();p.add_argument('--output');a,_=p.parse_known_args()\n"
            "if os.environ.get('FAKE_RESOURCE_MODE') == 'fail': sys.exit(25)\n"
            "if a.output: Path(a.output).write_text(json.dumps({'status':'passed'}))\n"
        )
        (self.root / "scripts/dedup-fixtures/validate.py").write_text(
            "import os,sys\nif os.environ.get('FAKE_FIXTURE_MODE') == 'fail': sys.exit(26)\n"
        )
        (self.root / "scripts/test-continuation-race.py").write_text(
            textwrap.dedent(
                """\
                import argparse
                import json
                import os
                from pathlib import Path
                import sys

                parser = argparse.ArgumentParser()
                parser.add_argument("--output-dir", required=True)
                parser.add_argument("--scenario", required=True)
                args = parser.parse_args()
                with Path(os.environ["FAKE_EVENTS"]).open("a") as events:
                    events.write("continuation:%s\\n" % os.environ.get("RQDATAC2_CONF", "absent"))
                if (os.environ.get("FAKE_PROBE_MODE") == "fail" or
                    (os.environ.get("FAKE_PROBE_MODE") == "advanced-fail" and args.scenario == "advanced-preparation")):
                    sys.exit(23)
                output = Path(args.output_dir)
                output.mkdir(parents=True)
                (output / "probe evidence with spaces.txt").write_text("synthetic evidence")
                json.dump(
                    {"status": "passed", "regression": "continuation-race", "scenario": args.scenario,
                     "runs": {"green": {"exit_code": 0, "timed_out": False, "fixture_result": {"status": "passed"}},
                              "red": {"exit_code": 1, "timed_out": False, "fixture_result": {"status": "failed", "failure_stage": "assertion", "assertion": "post_resume_waiting_sources"}}}},
                    (output / "result.json").open("w"),
                )
                """
            )
        )

    def _write_fake_tools(self) -> None:
        self._write_tool("xcodebuild", _FAKE_XCODEBUILD)
        self._write_tool("xcrun", _FAKE_XCRUN)
        self._write_tool("codesign", _FAKE_CODESIGN)
        self._write_tool("lipo", "#!/bin/sh\nexit 0\n")
        self._write_tool("ditto", "#!/bin/sh\ncp -R \"$1\" \"$2\"\n")
        self._write_tool("hdiutil", _FAKE_HDIUTIL)

    def _write_tool(self, name: str, content: str) -> None:
        path = self.bin_dir / name
        path.write_text(content)
        path.chmod(0o755)


class ReleaseValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.fixture = ReleaseFixture(self.temporary_directory)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_validator_success_records_the_real_completed_stages(self) -> None:
        output_dir = Path(self.temporary_directory.name) / "validation"
        derived_data = Path(self.temporary_directory.name) / "derived-data"

        result = self.fixture.run_validator(output_dir, derived_data)

        self.assertEqual(result.returncode, 0, result.stderr)
        evidence = json.loads((output_dir / "validation.json").read_text())
        self.assertEqual(evidence["status"], "passed")
        self.assertEqual(evidence["xctest"]["test_count"], 7)
        self.assertEqual(evidence["tool_tests"]["test_count"], 1)
        self.assertEqual(evidence["continuation_race"]["status"], "passed")
        self.assertTrue((output_dir / "validation-report.md").is_file())
        self.assertNotIn("must-not-reach-child-tools", "\n".join(self.fixture.event_lines()))
        self.assertEqual(
            [line.split(":", 1)[0] for line in self.fixture.event_lines()],
            ["xcodebuild", "xcrun", "xcodebuild", "xcrun", "xcodebuild", "xcrun", "xcrun", "xcrun", "xcrun", "continuation", "continuation"],
        )

    def test_validator_build_failure_stops_before_xctest_and_never_marks_success(self) -> None:
        output_dir = Path(self.temporary_directory.name) / "validation"
        result = self.fixture.run_validator(
            output_dir,
            Path(self.temporary_directory.name) / "derived-data",
            FAKE_XCODEBUILD_MODE="fail-debug-build",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((output_dir / "validation.json").exists())
        self.assertEqual([line.split(":", 1)[0] for line in self.fixture.event_lines()], ["xcodebuild", "xcrun", "xcodebuild"])

    def test_validator_rejects_nonzero_zero_and_failed_xctest_summaries(self) -> None:
        for mode in ("nonzero", "zero", "failed-summary"):
            with self.subTest(mode=mode):
                output_dir = Path(self.temporary_directory.name) / f"validation-{mode}"
                result = self.fixture.run_validator(
                    output_dir,
                    Path(self.temporary_directory.name) / f"derived-data-{mode}",
                    FAKE_XCTEST_MODE=mode,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((output_dir / "validation.json").exists())
                self.assertFalse((output_dir / "continuation-race" / "result.json").exists())

    def test_validator_rejects_tool_or_continuation_failures_without_success_marker(self) -> None:
        for label, environment in (
            ("resources", {"FAKE_RESOURCE_MODE": "fail"}),
            ("fixtures", {"FAKE_FIXTURE_MODE": "fail"}),
            ("tool-tests", {}),
            ("continuation", {"FAKE_PROBE_MODE": "fail"}),
            ("advanced-continuation", {"FAKE_PROBE_MODE": "advanced-fail"}),
        ):
            with self.subTest(label=label):
                temporary_directory = tempfile.TemporaryDirectory()
                fixture = ReleaseFixture(temporary_directory)
                output_dir = Path(temporary_directory.name) / f"validation-{label}"
                if label == "tool-tests":
                    (fixture.root / "Tests/Tools/test_fixture.py").write_text(
                        "import unittest\n\n"
                        "class FixtureTests(unittest.TestCase):\n"
                        "    def test_synthetic_fixture_fails(self):\n"
                        "        self.fail('synthetic tool regression')\n"
                    )
                result = fixture.run_validator(
                    output_dir,
                    Path(temporary_directory.name) / f"derived-data-{label}",
                    **environment,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((output_dir / "validation.json").exists())
                temporary_directory.cleanup()

    def test_validator_timeout_kills_only_its_own_process_group(self) -> None:
        module = self._load_validator_module()
        log_path = Path(self.temporary_directory.name) / "timeout.log"

        with self.assertRaises(module.PhaseFailure) as raised:
            module.run_command(
                [sys.executable, "-c", "import time; time.sleep(60)"],
                cwd=self.fixture.root,
                environment=self.fixture.environment(),
                log_path=log_path,
                timeout_seconds=0.05,
                label="timeout-fixture",
            )

        self.assertIn("timed out", str(raised.exception))
        self.assertTrue(log_path.exists())

    def test_packager_disables_lfs_smudge_before_exact_pointer_hydration(self) -> None:
        # A real configured LFS filter may hydrate during git archive itself.
        # The packager must override an inherited opt-in before that boundary.
        real_git = shutil.which("git")
        self.assertIsNotNone(real_git)
        self.fixture._write_tool(
            "git",
            '#!/bin/sh\nif [ "$1" = archive ] && [ "${GIT_LFS_SKIP_SMUDGE:-}" != 1 ]; then exit 86; fi\n'
            f'exec "{real_git}" "$@"\n',
        )
        result = self.fixture.run_packager(GIT_LFS_SKIP_SMUDGE="0")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_packager_validates_archived_snapshot_before_release_build_and_publishes_evidence(self) -> None:
        result = self.fixture.run_packager()

        self.assertEqual(result.returncode, 0, result.stderr)
        release = self.fixture.release_path()
        self.assertTrue((release / "validation" / "validation.json").is_file())
        self.assertTrue((release / "validation" / "validation-report.md").is_file())
        self.assertEqual((release / "CHANGELOG.md").read_text(), "fixture changelog\n")
        self.assertTrue((release / "SHA256SUMS").is_file())
        self.assertIn(
            "./validation/continuation-race/probe evidence with spaces.txt",
            (release / "SHA256SUMS").read_text(),
        )
        self.assertIn("validation_json=validation/validation.json", (release / "PhotosYNC.provenance").read_text())
        events = self.fixture.event_lines()
        self.assertLess(events.index("continuation:absent"), next(index for index, line in enumerate(events) if line == "xcodebuild:release"))
        self.assertTrue(any(line == "hdiutil:verify" for line in events))
        self.assert_no_transient_release_paths(self.fixture)

    def test_packager_never_publishes_after_validation_or_distribution_failure(self) -> None:
        cases = {
            "validation-build": {"FAKE_XCODEBUILD_MODE": "fail-debug-build"},
            "validation-xctest": {"FAKE_XCTEST_MODE": "failed-summary"},
            "validation-probe": {"FAKE_PROBE_MODE": "fail"},
            "release-source-mutation": {"FAKE_XCODEBUILD_MODE": "mutate-archive-release"},
            "codesign": {"FAKE_CODESIGN_MODE": "fail"},
            "dmg-verify": {"FAKE_HDIUTIL_MODE": "fail-verify"},
        }
        for label, environment in cases.items():
            with self.subTest(label=label):
                temporary_directory = tempfile.TemporaryDirectory()
                fixture = ReleaseFixture(temporary_directory)
                try:
                    result = fixture.run_packager(**environment)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(fixture.release_path().exists())
                    self.assert_no_transient_release_paths(fixture)
                finally:
                    temporary_directory.cleanup()

    def test_packager_refuses_dirty_untracked_existing_and_locked_release_paths(self) -> None:
        cases = ("dirty", "untracked", "file", "directory", "symlink", "lock")
        for case in cases:
            with self.subTest(case=case):
                temporary_directory = tempfile.TemporaryDirectory()
                fixture = ReleaseFixture(temporary_directory)
                try:
                    release = fixture.release_path()
                    if case == "dirty":
                        (fixture.root / "docs/release/0.1.0.md").write_text("changed\n")
                    elif case == "untracked":
                        (fixture.root / "untracked.txt").write_text("untracked\n")
                    elif case == "file":
                        release.parent.mkdir(parents=True, exist_ok=True)
                        release.write_text("preserve\n")
                    elif case == "directory":
                        release.mkdir(parents=True)
                        (release / "preserve.txt").write_text("preserve\n")
                    elif case == "symlink":
                        release.parent.mkdir(parents=True, exist_ok=True)
                        release.symlink_to(fixture.root / "missing-release-target")
                    else:
                        lock = release.parent / ".0.1.0.lock"
                        lock.mkdir(parents=True)
                    result = fixture.run_packager()
                    self.assertNotEqual(result.returncode, 0)
                    if case == "file":
                        self.assertEqual(release.read_text(), "preserve\n")
                    elif case == "directory":
                        self.assertEqual((release / "preserve.txt").read_text(), "preserve\n")
                    elif case == "symlink":
                        self.assertTrue(release.is_symlink())
                    else:
                        self.assertFalse(release.exists())
                finally:
                    temporary_directory.cleanup()

    def _load_validator_module(self):
        spec = importlib.util.spec_from_file_location("release_validation_under_test", VALIDATOR)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        return module

    def assert_no_transient_release_paths(self, fixture: ReleaseFixture) -> None:
        release_root = fixture.release_path().parent
        self.assertFalse((release_root / ".0.1.0.lock").exists())
        self.assertEqual(list(release_root.glob(".0.1.0.staging.*")), [])


_FAKE_XCODEBUILD = """#!/bin/sh
set -eu
if [ "${1:-}" = "-version" ]; then
    printf 'xcodebuild:version\\n' >> "$FAKE_EVENTS"
    printf 'Xcode fake 1.0\\n'
    exit 0
fi
derived=''
configuration=''
previous=''
for argument in "$@"; do
    if [ "$previous" = '-derivedDataPath' ]; then derived="$argument"; fi
    if [ "$previous" = '-configuration' ]; then configuration="$argument"; fi
    previous="$argument"
done
case " $* " in
  *' build-for-testing '*)
    if [ "$configuration" = 'Release' ]; then
      printf 'xcodebuild:scale\\n' >> "$FAKE_EVENTS"
      mkdir -p "$derived/Build/Products/Release/PhotoSyncCoreTests.xctest"
      exit 0
    fi
    printf 'xcodebuild:debug\\n' >> "$FAKE_EVENTS"
    if [ "${FAKE_XCODEBUILD_MODE:-}" = 'fail-debug-build' ]; then exit 17; fi
    mkdir -p "$derived/Build/Products/Debug/PhotoSyncCoreTests.xctest"
    ;;
  *)
    if [ "$configuration" = 'Release' ]; then
      printf 'xcodebuild:release\\n' >> "$FAKE_EVENTS"
      if [ "${FAKE_XCODEBUILD_MODE:-}" = 'fail-release-build' ]; then exit 18; fi
      if [ "${FAKE_XCODEBUILD_MODE:-}" = 'mutate-archive-release' ]; then
        printf 'mutated after validation\\n' >> Sources/release-build-mutation.swift
      fi
      app="$derived/Build/Products/Release/PhotosYNC.app"
      mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks/PhotoSyncCore.framework/Versions/A"
      cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleExecutable</key><string>PhotosYNC</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>6</string>
<key>PhotoSyncReleaseChannel</key><string>stable</string>
</dict></plist>
PLIST
      printf '#!/bin/sh\\nexit 0\\n' > "$app/Contents/MacOS/PhotosYNC"
      chmod +x "$app/Contents/MacOS/PhotosYNC"
      printf 'asset' > "$app/Contents/Resources/Assets.car"
      printf 'icon' > "$app/Contents/Resources/PhotosYNC.icns"
      : > "$app/Contents/Frameworks/PhotoSyncCore.framework/Versions/A/PhotoSyncCore"
    fi
    ;;
esac
"""

_FAKE_XCRUN = """#!/bin/sh
set -eu
printf 'xcrun:%s:%s\\n' "${1:-}" "${RQDATAC2_CONF:-absent}" >> "$FAKE_EVENTS"
if [ "${1:-}" = 'swift' ]; then
  printf 'Swift fake 1.0\\n'
  exit 0
fi
if [ "${1:-}" != 'xctest' ]; then exit 19; fi
if [ -n "${PHOTOSYNC_SCALE_REPRESENTATIONS:-}" ]; then
  sample="$PHOTOSYNC_SCALE_REPRESENTATIONS"
  if [ "${PHOTOSYNC_SCALE_HISTORY:-0}" != 0 ]; then sample="$sample-history-$PHOTOSYNC_SCALE_HISTORY"; fi
  printf '{"representations":%s,"success_history_vectors":%s,"budget_pass":true,"large_source_samples":[{},{}]}' "$PHOTOSYNC_SCALE_REPRESENTATIONS" "${PHOTOSYNC_SCALE_HISTORY:-0}" > "$PHOTOSYNC_ACCEPTANCE_OUTPUT/scale-$sample.json"
  printf "Test Suite 'Selected tests' passed at fixture.\\n"
  printf 'Executed 1 test, with 0 failures\\n'
  exit 0
fi
case "${FAKE_XCTEST_MODE:-success}" in
  success)
    printf '{"case_count":33,"duplicate_count":14,"skip_count":11}' > "$PHOTOSYNC_ACCEPTANCE_OUTPUT/model-regression.json"
    printf '{"legacy_imports":1,"one_changed_inferences":1,"unchanged_inferences":0}' > "$PHOTOSYNC_ACCEPTANCE_OUTPUT/runtime-load.json"
    mkdir -p "$PHOTOSYNC_MODEL_CACHE_DIR"
    printf 'synthetic compiled bytes' > "$PHOTOSYNC_MODEL_CACHE_DIR/fixture.bin"
    printf "Test Suite 'All tests' passed at fixture.\\n"
    printf '\\t Executed 7 tests, with 0 failures (0 unexpected) in 0.001 seconds\\n'
    ;;
  nonzero)
    printf "Test Suite 'All tests' failed at fixture.\\n"
    printf '\\t Executed 7 tests, with 1 failure (1 unexpected) in 0.001 seconds\\n'
    exit 21
    ;;
  zero)
    printf "Test Suite 'All tests' passed at fixture.\\n"
    printf '\\t Executed 0 tests, with 0 failures (0 unexpected) in 0.001 seconds\\n'
    ;;
  failed-summary)
    printf "Test Suite 'All tests' failed at fixture.\\n"
    printf '\\t Executed 7 tests, with 1 failure (1 unexpected) in 0.001 seconds\\n'
    ;;
  *) exit 22 ;;
esac
"""

_FAKE_CODESIGN = """#!/bin/sh
set -eu
printf 'codesign:%s\\n' "${RQDATAC2_CONF:-absent}" >> "$FAKE_EVENTS"
[ "${FAKE_CODESIGN_MODE:-}" != 'fail' ]
"""

_FAKE_HDIUTIL = """#!/bin/sh
set -eu
case "${1:-}" in
  create)
    printf 'hdiutil:create\\n' >> "$FAKE_EVENTS"
    for last; do :; done
    : > "$last"
    ;;
  verify)
    printf 'hdiutil:verify\\n' >> "$FAKE_EVENTS"
    [ "${FAKE_HDIUTIL_MODE:-}" != 'fail-verify' ]
    ;;
  *) exit 31 ;;
esac
"""


if __name__ == "__main__":
    unittest.main()
