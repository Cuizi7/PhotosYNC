#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/work/advanced-dedup-probe"
MODULE_CACHE="$ROOT/work/advanced-dedup-module-cache"
export PHOTOSYNC_MODEL_CACHE_DIR="$ROOT/work/advanced-dedup-compiled-cache"
PROTOCOL="$ROOT/docs/research/advanced-dedup/protocol.json"
PROTOCOL_SHA="$(python3 - "$ROOT" "$PROTOCOL" <<'PY'
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

root, path = Path(sys.argv[1]), Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("advanced_dedup_research", root / "scripts/advanced-dedup/research.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
raw = path.read_bytes()
document = json.loads(raw)
protocol = module.validate_protocol(document)
if not protocol["approved"]:
    raise ValueError("research protocol has not been approved")
resources = document["resources"]
if resources["inference_concurrency"] != 1 or resources["batch_size"] != 1:
    raise ValueError("probe requires serial single-item inference")
if resources["decode_concurrency"] != 1 or resources["max_decoded_bytes"] <= 0:
    raise ValueError("probe requires bounded serial decode")
print(hashlib.sha256(raw).hexdigest())
PY
)"
mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
xcrun swiftc -O -module-cache-path "$MODULE_CACHE" -module-name AdvancedDedupProbe \
  "$ROOT/Sources/PhotoSyncCore/Matching/AdvancedDedupTypes.swift" \
  "$ROOT/Sources/PhotoSyncCore/Fingerprinting/ImagePreprocessor.swift" \
  "$ROOT/Sources/PhotoSyncCore/Fingerprinting/CoreMLFingerprinter.swift" \
  "$ROOT/Tools/AdvancedDedupProbe/main.swift" \
  -o "$BIN"
exec "$BIN" "$@" --protocol-sha256 "$PROTOCOL_SHA" \
  --max-decoded-bytes "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["resources"]["max_decoded_bytes"])' "$PROTOCOL")" \
  --max-abs-error "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["conversion_max_abs_error"])' "$PROTOCOL")" \
  --min-cosine "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["conversion_min_cosine"])' "$PROTOCOL")"
