#!/usr/bin/env python3
"""Exact-byte resource and local LFS archive gate. Never downloads or uploads."""

from __future__ import annotations
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import struct
import subprocess

RESOURCE_PATH = Path("Sources/PhotoSyncCore/Resources/AdvancedDedup")
MODEL = "SSCDLarge.mlpackage"
WEIGHT = "Data/com.apple.CoreML/weights/weight.bin"
MODEL_SHA = "026e7a43660e29c307941a88dbe35b9c14468693333ff926e9b984eef3b4b8d0"
WEIGHT_SHA = "be1b28a5be24ca216884b6a04db291f58bd484328ac5307f9577fd27295cb338"
WEIGHT_SIZE = 88329408
LICENSE_SHA = "da6d3703ed11cbe42bd212c725957c98da23cbff1998c05fa4b3d976d1a58e93"
RECORD_HASHES = {
    "decision.json": "b32b332696bb716942ef5274856ddcba6d3d4d8f4a05e2925e6e264b5da337da",
    "profile.json": "25749a222f56277607a85004edb43b594a7595406d4a63112631dd4cc00f00d8",
    "regression.json": "17da760deff666a9328c15d2f65e22b1a49adc8f1151a72ce24c16605b6cf6e5",
    "closeout.json": "6d15fd23ce895a43e1707e4b1afba51a7b2cc98a6fb724a960f48803fd5ebf79",
    "LICENSE-SSCD.txt": LICENSE_SHA,
    "execution-policy.json": "03e34635df8a05e5b9e7d519dc4c1a0577a8f83ea771e237d2b085c9eb11e90e",
    "ModelSelfTest/manifest.json": "8dfb4ccac57943db5ed867d180916dc6477fa8377017ef9e1b1cdf19e0c993f9",
    "model-provenance.json": "22f0e8b27ed5f7644831e5ec9de5dd2320457f319be29163a3dc757afcfcbf94",
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
        | {"execution-policy.json", "ModelSelfTest/manifest.json"}
        | {f"ModelSelfTest/{kind}-{i}.f32" for kind in ("input", "reference") for i in range(4)}
    )
    for path in root.rglob("*"):
        if path.is_symlink() or (
            not path.is_dir() and path.relative_to(root).as_posix() not in allowed
        ):
            raise ValueError(f"Unexpected release resource: {path.relative_to(root)}")


def verify_execution_resources(root: Path) -> None:
    policy = json.loads((root / "execution-policy.json").read_bytes())
    expected = {
        "schemaVersion": 1, "id": "fp16-ane-gpu-v1",
        "arm64": ["cpuAndNeuralEngine", "cpuAndGPU"], "x86_64": ["cpuAndGPU"],
        "maxFallbacks": 1, "inputType": "float32", "outputType": "float32",
        "allowLowPrecisionAccumulationOnGPU": False, "retryIntervalSeconds": 60,
        "modelSHA256": MODEL_SHA,
        "fingerprintVersion": "ec805406fa61e91384e4bf29ae29a52694b80e3755afd7768da80a6db70c9a1d",
        "selfTestManifestSHA256": "8dfb4ccac57943db5ed867d180916dc6477fa8377017ef9e1b1cdf19e0c993f9",
    }
    if policy != expected:
        raise ValueError("Execution policy identity/IO/backend mismatch")
    folder = root / "ModelSelfTest"
    manifest_path = folder / "manifest.json"
    if folder.is_symlink() or manifest_path.is_symlink() or sha256(manifest_path) != policy["selfTestManifestSHA256"]:
        raise ValueError("Self-test manifest identity mismatch")
    manifest = json.loads(manifest_path.read_bytes())
    if (manifest["schemaVersion"] != 1 or manifest["inputShape"] != [1, 3, 320, 320]
            or manifest["outputShape"] != [1, 1024] or manifest["inputType"] != "float32"
            or manifest["outputType"] != "float32" or manifest["comparison"] != "l2_normalized_float32"
            or manifest["maxAbsError"] != 0.02 or manifest["minCosine"] != 0.999 or len(manifest["cases"]) != 4):
        raise ValueError("Self-test shape/IO/threshold mismatch")
    for i, case in enumerate(manifest["cases"]):
        for kind, length in [("input", 1228800), ("reference", 4096)]:
            item = case[kind]
            path = folder / f"{kind}-{i}.f32"
            if (item["path"] != path.name or item["bytes"] != length or path.is_symlink()
                    or not path.is_file() or path.stat().st_size != length or sha256(path) != item["sha256"]):
                raise ValueError("Missing/corrupt self-test tensor identity")
            values = struct.unpack(f"<{length // 4}f", path.read_bytes())
            if not all(math.isfinite(value) for value in values):
                raise ValueError("Non-finite self-test values")
            if kind == "reference" and not any(values):
                raise ValueError("Zero reference vector")


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
    verify_execution_resources(root)
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
        or provenance.get("executionPolicyID") != "fp16-ane-gpu-v1"
        or provenance.get("conversion", {}).get("computePrecision") != "float16"
        or provenance.get("conversion", {}).get("inputType") != "float32"
        or provenance.get("conversion", {}).get("outputType") != "float32"
        or provenance.get("fingerprintVersion") != "ec805406fa61e91384e4bf29ae29a52694b80e3755afd7768da80a6db70c9a1d"
        or provenance.get("executionPolicySHA256") != sha256(root / "execution-policy.json")
        or provenance.get("selfTestManifestSHA256") != sha256(root / "ModelSelfTest/manifest.json")
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
        "execution_policy_id": "fp16-ane-gpu-v1",
        "self_test_manifest_sha256": sha256(root / "ModelSelfTest/manifest.json"),
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
        allowed_synthetic = (path.resolve().is_relative_to(resource_root)
            and path.resolve().relative_to(resource_root).as_posix() in {
                f"ModelSelfTest/{kind}-{i}.f32" for kind in ("input", "reference") for i in range(4)})
        if (path.suffix.lower() in forbidden and not allowed_synthetic) or (
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
