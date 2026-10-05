#!/usr/bin/env python3
"""Exact-byte resource and local LFS archive gate. Never downloads or uploads."""

from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess

RESOURCE_PATH = Path("Sources/PhotoSyncCore/Resources/AdvancedDedup")
MODEL = "SSCDLarge.mlpackage"
WEIGHT = "Data/com.apple.CoreML/weights/weight.bin"
MODEL_SHA = "c0cb378982abd1bd775d377d4dfd66ac3469bce894d0834ed69c3c778fb3c9b3"
WEIGHT_SHA = "e67a9b7f25cfc0b0fc98eff41ff5357c4477c642aa2f4790ed4479b7a2a31917"
WEIGHT_SIZE = 176645312
LICENSE_SHA = "da6d3703ed11cbe42bd212c725957c98da23cbff1998c05fa4b3d976d1a58e93"
RECORD_HASHES = {
    "decision.json": "62cf88379adb7a1ff752b3e29d7a3a36ffdb5522f85c954d5dbae6eb3e3628da",
    "profile.json": "ca6250e3bcca3850b4b1d05279ad4feb4e9f02615aa30d03fc354dc54870e857",
    "regression.json": "c30e33331aa73a0e574c13d1648db2b2f65a7318023888db3c0a07b42ba4e5b6",
    "closeout.json": "a1815f2ba03887968ea6274b389f7011fb4c310b0205d40919e85740777e7278",
    "LICENSE-SSCD.txt": LICENSE_SHA,
    "model-provenance.json": "d59d381e71afd5bebf8d448f64a3d27c5019963228a3fc1a02d5be9ae5528a65",
}
MODEL_FILES = {"Manifest.json", "Data/com.apple.CoreML/model.mlmodel", WEIGHT}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def package_sha256(root: Path) -> str:
    files = sorted(
        (p for p in root.rglob("*") if p.is_file()),
        key=lambda p: p.relative_to(root).as_posix().encode(),
    )
    digest = hashlib.sha256(b"PhotoSync.mlpackage.manifest.v2\0")
    digest.update(struct.pack("<Q", len(files)))
    for path in files:
        name = path.relative_to(root).as_posix().encode()
        digest.update(struct.pack("<Q", len(name)))
        digest.update(name)
        digest.update(struct.pack("<Q", path.stat().st_size))
        with path.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
    return digest.hexdigest()


def verify_allowed_files(root: Path) -> None:
    allowed = (
        set(RECORD_HASHES)
        | {"model-provenance.json"}
        | {f"{MODEL}/{p}" for p in MODEL_FILES}
    )
    for path in root.rglob("*"):
        if path.is_symlink() or (
            not path.is_dir() and path.relative_to(root).as_posix() not in allowed
        ):
            raise ValueError(f"Unexpected release resource: {path.relative_to(root)}")


def verify_resources(root: Path) -> dict:
    if not root.is_dir() or root.is_symlink():
        raise ValueError("Missing regular AdvancedDedup resource directory")
    verify_allowed_files(root)
    hashes = {}
    for name, expected in RECORD_HASHES.items():
        path = root / name
        if not path.is_file() or sha256(path) != expected:
            raise ValueError(f"Missing or wrong SHA256: {name}")
        hashes[name] = expected
    model = root / MODEL
    weight = model / WEIGHT
    if (
        not weight.is_file()
        or weight.stat().st_size != WEIGHT_SIZE
        or sha256(weight) != WEIGHT_SHA
    ):
        raise ValueError(
            "Missing, corrupt or pointer-only model weights; hydrate the local LFS object first"
        )
    if package_sha256(model) != MODEL_SHA:
        raise ValueError("Model package identity mismatch")
    provenance_path = root / "model-provenance.json"
    if not provenance_path.is_file():
        raise ValueError("Missing model provenance")
    provenance = json.loads(provenance_path.read_text())
    if (
        provenance.get("modelSHA256") != MODEL_SHA
        or provenance.get("codeLicenseSHA256") != LICENSE_SHA
        or provenance.get("runtimeComputeUnits") != "cpuOnly"
        or provenance.get("conversion", {}).get("computePrecision") != "float32"
        or provenance.get("modelWeightsRedistributionLicenseStatus")
        != "MIT-upstream-explicit-weights-clarification"
        or provenance.get("weightsLicenseClarification", {}).get("url")
        != "https://github.com/facebookresearch/sscd-copy-detection/issues/12#issuecomment-1736328008"
    ):
        raise ValueError("Model provenance lacks the approved identity/license/backend")
    hashes["model-provenance.json"] = sha256(provenance_path)
    return {
        "status": "passed",
        "model_sha256": MODEL_SHA,
        "weight_sha256": WEIGHT_SHA,
        "weight_bytes": WEIGHT_SIZE,
        "files": hashes,
    }


def verify_app(app: Path) -> None:
    if not app.is_dir():
        raise ValueError("Missing built App bundle")
    forbidden = {
        ".jpg",
        ".jpeg",
        ".png",
        ".gif",
        ".tiff",
        ".webp",
        ".html",
        ".js",
        ".py",
        ".f32",
        ".npy",
        ".npz",
    }
    resource_root = (
        app / "Contents/Frameworks/PhotoSyncCore.framework/Resources/AdvancedDedup"
    ).resolve()
    app_resources = app / "Contents/Resources"
    for path in app_resources.rglob("*"):
        if path.is_file() and path.relative_to(app_resources).as_posix() not in {
            "Assets.car",
            "PhotosYNC.icns",
        }:
            raise ValueError(
                f"Unexpected App resource: {path.relative_to(app_resources)}"
            )
    core_resources = app / "Contents/Frameworks/PhotoSyncCore.framework/Resources"
    for path in core_resources.rglob("*"):
        if (
            path.is_file()
            and not path.resolve().is_relative_to(resource_root)
            and path.relative_to(core_resources).as_posix() != "Info.plist"
        ):
            raise ValueError(
                f"Unexpected Core resource: {path.relative_to(core_resources)}"
            )
    for path in app.rglob("*"):
        if not path.is_file():
            continue
        if path.suffix.lower() in forbidden or (
            path.suffix == ".json" and not path.resolve().is_relative_to(resource_root)
        ):
            raise ValueError(
                f"Unexpected corpus/research/prototype file in App: {path.relative_to(app)}"
            )


def hydrate_file(
    repo: Path, commit: str, archive: Path, relative: str, objects: Path
) -> None:
    if not re.fullmatch(r"[0-9a-f]{40,64}", commit):
        raise ValueError("Hydration requires an immutable full commit ID")
    pointer = subprocess.check_output(
        ["git", "-C", str(repo), "show", f"{commit}:{relative}"]
    )
    match = re.fullmatch(
        rb"version https://git-lfs.github.com/spec/v1\noid sha256:([0-9a-f]{64})\nsize ([0-9]+)\n",
        pointer,
    )
    target = archive / relative
    if (
        not match
        or target.is_symlink()
        or not target.is_file()
        or not target.resolve().is_relative_to(archive.resolve())
        or target.stat().st_size != len(pointer)
        or target.read_bytes() != pointer
    ):
        raise ValueError("Exact archived pointer differs from the requested commit")
    oid, size = match[1].decode(), int(match[2])
    obj = objects / oid[:2] / oid[2:4] / oid
    if not obj.is_file() or obj.is_symlink():
        raise ValueError(
            f"Local LFS object missing: {oid}; fetch explicitly before packaging"
        )
    if obj.stat().st_size != size or sha256(obj) != oid:
        raise ValueError(f"Local LFS object identity mismatch: {oid}")
    shutil.copyfile(obj, target)
    if target.stat().st_size != size or sha256(target) != oid:
        raise ValueError("Hydrated model identity mismatch")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path, required=True)
    parser.add_argument("--hydrate-from", type=Path)
    parser.add_argument("--commit")
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--app", type=Path)
    args = parser.parse_args()
    if args.hydrate_from:
        if not args.commit or not args.archive:
            parser.error("--hydrate-from needs --commit and --archive")
        environment = subprocess.check_output(
            ["git", "-C", str(args.hydrate_from), "lfs", "env"], text=True
        )
        objects = next(
            (
                Path(line.split("=", 1)[1])
                for line in environment.splitlines()
                if line.startswith("LocalMediaDir=")
            ),
            None,
        )
        if objects is None:
            raise ValueError("git lfs env did not expose local object storage")
        hydrate_file(
            args.hydrate_from,
            args.commit,
            args.archive,
            str(RESOURCE_PATH / MODEL / WEIGHT),
            objects,
        )
    result = verify_resources(args.resources)
    if args.app:
        expected = (
            args.app
            / "Contents/Frameworks/PhotoSyncCore.framework/Resources/AdvancedDedup"
        )
        if args.resources.resolve() != expected.resolve():
            raise ValueError(
                "--resources must identify the checked App's Core resources"
            )
        verify_app(args.app)
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(text)
    print(text, end="")


if __name__ == "__main__":
    main()
