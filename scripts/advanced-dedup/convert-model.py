#!/usr/bin/env python3
"""Convert an explicitly supplied SSCD Large TorchScript model for offline research."""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def package_sha256(path: Path) -> str:
    """Hash a versioned, length-framed sorted relative-path/file-byte manifest."""
    digest = hashlib.sha256()
    entries = list(path.rglob("*"))
    if any(item.is_symlink() for item in entries):
        raise ValueError("model package contains a symbolic link")
    files = sorted((item for item in entries if item.is_file()),
                   key=lambda item: item.relative_to(path).as_posix().encode("utf-8"))
    if not files:
        raise ValueError("empty model package")
    digest.update(b"PhotoSync.mlpackage.manifest.v2\0")
    digest.update(len(files).to_bytes(8, "little"))
    for item in files:
        relative = item.relative_to(path).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(8, "little"))
        digest.update(relative)
        size = item.stat().st_size
        digest.update(size.to_bytes(8, "little"))
        read_bytes = 0
        with item.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
                read_bytes += len(chunk)
        if read_bytes != size:
            raise ValueError("model package changed while hashing")
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--expected-weights-sha256", required=True)
    parser.add_argument("--license-file", type=Path, required=True)
    parser.add_argument("--upstream-revision", required=True)
    parser.add_argument("--upstream-url", required=True)
    parser.add_argument("--precision", choices=("float16", "float32"), required=True)
    parser.add_argument("--output-package", type=Path, required=True)
    parser.add_argument("--provenance", type=Path, required=True)
    args = parser.parse_args()
    if not args.weights.is_file() or not args.license_file.is_file():
        parser.error("weights and MIT license file must already exist locally")
    if "MIT License" not in args.license_file.read_text(encoding="utf-8"):
        parser.error("license file does not contain the MIT text")
    weights_sha256 = file_sha256(args.weights)
    if weights_sha256 != args.expected_weights_sha256.lower():
        parser.error("weights SHA256 does not match the verified checkpoint")
    if args.output_package.exists() or args.provenance.exists():
        parser.error("output already exists; refusing to overwrite")
    import torch
    import coremltools as ct

    torch.set_num_threads(4)
    model = torch.jit.load(str(args.weights), map_location="cpu").eval()
    converted = ct.convert(
        model,
        inputs=[ct.TensorType(name="image", shape=(1, 3, 320, 320))],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16 if args.precision == "float16" else ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS13,
        skip_model_load=True,
    )
    args.output_package.parent.mkdir(parents=True, exist_ok=True)
    converted.save(str(args.output_package))
    sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-version"],
                         check=True, capture_output=True, text=True).stdout.strip()
    record = {
        "status": "research-conversion-unvalidated",
        "declaredUpstreamURL": args.upstream_url,
        "declaredUpstreamRevision": args.upstream_revision,
        "weightsLineageStatus": "unverified-local-TorchScript-source",
        "weightsSHA256": weights_sha256,
        "weightsBytes": args.weights.stat().st_size,
        "codeLicense": "MIT",
        "codeLicenseSHA256": file_sha256(args.license_file),
        "codeLicenseText": args.license_file.read_text(encoding="utf-8"),
        "modelWeightsRedistributionLicenseStatus": "unresolved",
        "torchVersion": torch.__version__,
        "coremltoolsVersion": ct.__version__,
        "pythonVersion": platform.python_version(),
        "macOSVersion": platform.mac_ver()[0],
        "macOSSDKVersion": sdk,
        "conversion": {
            "input": [1, 3, 320, 320], "inputName": "image",
            "outputName": "embedding", "format": "mlprogram",
            "computePrecision": args.precision, "minimumDeploymentTarget": "macOS13",
            "batchSize": 1, "skipModelLoad": True,
        },
        "modelSHA256": package_sha256(args.output_package),
        "modelSHA256ManifestEncoding": "PhotoSync.mlpackage.manifest.v2: UInt64LE count, path length/path, byte length/bytes",
    }
    args.provenance.parent.mkdir(parents=True, exist_ok=True)
    args.provenance.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({"modelSHA256": record["modelSHA256"], "status": record["status"]}))


if __name__ == "__main__":
    main()
