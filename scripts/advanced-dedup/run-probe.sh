#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/work/advanced-dedup-probe"
MODULE_CACHE="$ROOT/work/advanced-dedup-module-cache"
export PHOTOSYNC_MODEL_CACHE_DIR="$ROOT/work/advanced-dedup-compiled-cache"
PROTOCOL="$ROOT/docs/research/advanced-dedup/protocol.json"

# Refuse caller-controlled gate fields and duplicate options before touching a model.
ARGS=("$@")
if (( $# < 1 )); then
  echo 'probe: missing command' >&2
  exit 2
fi
COMMAND="$1"
shift
case "$COMMAND" in
  fingerprint) LIST_FLAG=--input-list ;;
  compare-tensors) LIST_FLAG=--tensor-list ;;
  *) echo 'probe: unknown command' >&2; exit 2 ;;
esac
SEEN_FLAGS='|'
while (( $# )); do
  FLAG="$1"
  shift
  case "$FLAG" in
    --profile|--model|--output-dir|"$LIST_FLAG") ;;
    --approved-protocol-json|--protocol-sha256|--max-decoded-bytes|--max-abs-error|--min-cosine)
      echo "probe: reserved approved-protocol option $FLAG" >&2; exit 2 ;;
    *) echo "probe: unknown option $FLAG" >&2; exit 2 ;;
  esac
  if [[ "$SEEN_FLAGS" == *"|$FLAG|"* ]]; then
    echo "probe: duplicate option $FLAG" >&2
    exit 2
  fi
  if (( $# < 1 )) || [[ "$1" == --* ]]; then
    echo "probe: missing value for $FLAG" >&2
    exit 2
  fi
  SEEN_FLAGS="$SEEN_FLAGS$FLAG|"
  shift
done
for REQUIRED in --profile --model --output-dir "$LIST_FLAG"; do
  if [[ "$SEEN_FLAGS" != *"|$REQUIRED|"* ]]; then
    echo "probe: missing option $REQUIRED" >&2
    exit 2
  fi
done

# One read and one R1 validation produce the immutable values passed to Swift.
APPROVED_BINDING="$(python3 - "$ROOT" "$PROTOCOL" <<'PY'
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
print(json.dumps({
    "bindingVersion": 1,
    "protocolSHA256": hashlib.sha256(raw).hexdigest(),
    "maxDecodedBytes": resources["max_decoded_bytes"],
    "maxAbsError": document["conversion_max_abs_error"],
    "minCosine": document["conversion_min_cosine"],
}, sort_keys=True, separators=(",", ":")))
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
exec "$BIN" "${ARGS[@]}" --approved-protocol-json "$APPROVED_BINDING"
