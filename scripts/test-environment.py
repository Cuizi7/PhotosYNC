#!/usr/bin/env python3
"""Prepare or check the repository's portable test inputs; never open Photos."""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import time


REPO = Path(__file__).resolve().parent.parent
MANIFEST = Path("Tests/Support/test-environment.json")
CORPUS = Path("Tests/Fixtures/AdvancedDedup")
MODEL_WEIGHT = Path("Sources/PhotoSyncCore/Resources/AdvancedDedup/SSCDLarge.mlpackage/Data/com.apple.CoreML/weights/weight.bin")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def regular_input(root: Path, relative: str) -> Path:
    name = Path(relative)
    if name.is_absolute() or ".." in name.parts or not name.parts:
        raise ValueError("Test input must be a repository-relative path")
    path = root / name
    if any(p.is_symlink() for p in [path, *path.parents] if p != root.parent):
        raise ValueError(f"Test input symlink rejected: {relative}")
    if not path.is_file():
        raise ValueError(f"Missing test input: {relative}")
    return path


def verify_inputs(root: Path, requested_dataset: str | None = None) -> dict:
    root = root.resolve()
    if requested_dataset and Path(requested_dataset).resolve() != (root / CORPUS).resolve():
        raise ValueError("External dataset is not allowed by the portable gate")
    manifest_path = regular_input(root, str(MANIFEST))
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("schemaVersion") != 1 or not isinstance(manifest.get("files"), dict) or not manifest["files"]:
        raise ValueError("Invalid test input manifest")
    for relative, expected in manifest["files"].items():
        path = regular_input(root, relative)
        if not isinstance(expected, str) or sha256(path) != expected:
            raise ValueError(f"Test input SHA256 mismatch: {relative}")
    return {"files_checked": len(manifest["files"]), "manifest_sha256": sha256(manifest_path)}


def validate_prepare_root(repo: Path, root: Path) -> None:
    work = repo.resolve() / "work"
    if not root.is_absolute() or not root.resolve().is_relative_to(work) or root.resolve() == work:
        raise ValueError("Environment root must be inside this checkout's work directory")
    current = root
    while current != repo and current != current.parent:
        if current.is_symlink():
            raise ValueError("Environment root contains a symlink")
        current = current.parent
    if root.exists():
        raise ValueError("Environment root already exists; choose a new work directory")


def run_bounded(command: list[str], *, cwd: Path, deadline: float, environment: dict | None = None,
                log_path: Path | None = None) -> str:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("Test environment deadline exceeded")
    child_env = dict(os.environ if environment is None else environment)
    child_env.pop("RQDATAC2_CONF", None)
    with subprocess.Popen(command, cwd=cwd, env=child_env, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True, start_new_session=True) as process:
        output = ""
        try:
            output, _ = process.communicate(timeout=remaining)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                output, _ = process.communicate(timeout=0.5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                output, _ = process.communicate(timeout=0.5)
            raise TimeoutError("Test environment deadline exceeded") from None
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try: process.communicate(timeout=0.5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate(timeout=0.5)
                try: os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError: pass
            if log_path is not None:
                with log_path.open("a") as stream: stream.write(output + "\n")
        if process.returncode:
            raise ValueError(f"{Path(command[0]).name} failed ({process.returncode}): {output[-1500:]}")
    return output.strip()


def prepare(repo: Path, root: Path) -> Path:
    validate_prepare_root(repo, root)
    deadline = time.monotonic() + 600
    manifest = json.loads((repo / MANIFEST).read_text())
    weight = repo / MODEL_WEIGHT
    expected = manifest["files"][str(MODEL_WEIGHT)]
    if weight.is_symlink():
        raise ValueError("Model symlink rejected")
    if weight.exists() and sha256(weight) != expected:
        with weight.open("rb") as source:
            pointer = source.read(128).startswith(b"version https://git-lfs.github.com/spec/v1\n")
        if not pointer:
            raise ValueError("Refusing to overwrite modified model bytes")
    root.mkdir(parents=True)
    if not weight.exists() or sha256(weight) != expected:
        commit = run_bounded(["git", "rev-parse", "HEAD"], cwd=repo, deadline=deadline)
        run_bounded(["git", "lfs", "fetch", "origin", commit], cwd=repo, deadline=deadline)
        # A git-lfs executable does not imply `git lfs install` was run. Supply
        # filters for this command only; never rewrite the user's Git config.
        run_bounded(["git", "-c", "filter.lfs.process=git-lfs filter-process", "-c", "filter.lfs.required=true",
                     "-c", "filter.lfs.clean=git-lfs clean -- %f", "-c", "filter.lfs.smudge=git-lfs smudge -- %f",
                     "lfs", "checkout", str(MODEL_WEIGHT)], cwd=repo, deadline=deadline)
    verify_inputs(repo)
    run_bounded([sys.executable, "-m", "venv", str(root / "venv")], cwd=repo, deadline=deadline)
    python = root / "venv/bin/python"
    env = dict(os.environ, PIP_CACHE_DIR=str(root / "pip-cache"), PIP_DISABLE_PIP_VERSION_CHECK="1")
    run_bounded([str(python), "-m", "pip", "install", "--require-hashes", "--only-binary=:all:",
                 "-r", str(repo / "scripts/requirements-test.txt")], cwd=repo, deadline=deadline, environment=env)
    run_bounded([str(python), str(repo / "scripts/test-environment.py"), "--check", "--output",
                 str(root / "environment.json")], cwd=repo, deadline=deadline)
    return root / "environment.json"


def check(repo: Path) -> dict:
    manifest = json.loads((repo / MANIFEST).read_text())
    if list(sys.version_info[:2]) < manifest["pythonMinimum"]:
        raise ValueError("Python 3.10 or later is required")
    if platform.system() != "Darwin":
        raise ValueError("Native validation requires macOS")
    inputs = verify_inputs(repo, os.environ.get("PHOTOSYNC_REGRESSION_DATASET"))
    if importlib.metadata.version("Pillow") != manifest["pillow"]:
        raise ValueError("Pillow version differs from the test lock")
    for name in manifest["tools"]:
        if shutil.which(name) is None:
            raise ValueError(f"Missing test tool: {name}")
    deadline = time.monotonic() + 60
    return {"status": "passed", "schema_version": 1, "inputs": inputs,
            "python": platform.python_version(), "pillow": importlib.metadata.version("Pillow"),
            "macos": platform.mac_ver()[0], "architecture": platform.machine(),
            "xcode": run_bounded(["xcodebuild", "-version"], cwd=repo, deadline=deadline),
            "swift": run_bounded(["xcrun", "swift", "--version"], cwd=repo, deadline=deadline),
            "photos_access": "not_requested", "network": "not_required_after_prepare"}


def main() -> int:
    def cancelled(signum, frame): raise InterruptedError(f"Environment preparation cancelled by signal {signum}")
    signal.signal(signal.SIGTERM, cancelled)
    signal.signal(signal.SIGINT, cancelled)
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--prepare", action="store_true")
    modes.add_argument("--check", action="store_true")
    parser.add_argument("--root", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        if args.prepare:
            if args.root is None:
                raise ValueError("--prepare requires --root")
            report = prepare(REPO, args.root)
        else:
            if args.output is None or not args.output.is_absolute() or args.output.exists() or args.output.is_symlink():
                raise ValueError("--check requires a new absolute --output file")
            evidence = check(REPO)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n")
            report = args.output
        print(f"Test environment ready: {report}")
        return 0
    except (OSError, ValueError, TimeoutError, importlib.metadata.PackageNotFoundError) as error:
        print(f"Test environment failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
