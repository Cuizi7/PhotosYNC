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
DATASET=''
PROFILE=''
case "$COMMAND" in
  fingerprint) LIST_FLAG=--input-list ;;
  compare-tensors) LIST_FLAG=--tensor-list ;;
  score-batch) LIST_FLAG=--input ;;
  score-catalog) LIST_FLAG=--input ;;
  search-benchmark) LIST_FLAG=--vectors ;;
  combined-benchmark) LIST_FLAG=--vectors ;;
  validate-profile) LIST_FLAG=--profile ;;
  evaluate) LIST_FLAG=--dataset ;;
  *) echo 'probe: unknown command' >&2; exit 2 ;;
esac
SEEN_FLAGS='|'
while (( $# )); do
  FLAG="$1"
  shift
  case "$FLAG" in
    --profile|--output-dir|"$LIST_FLAG") ;;
    --model)
      [[ "$COMMAND" == fingerprint || "$COMMAND" == compare-tensors ||
         "$COMMAND" == evaluate || "$COMMAND" == combined-benchmark ]] || exit 2 ;;
    --input-list)
      [[ "$COMMAND" == combined-benchmark ]] || exit 2 ;;
    --catalog)
      [[ "$COMMAND" == score-catalog ]] || exit 2 ;;
    --asset-count|--edited-fraction)
      [[ "$COMMAND" == search-benchmark || "$COMMAND" == combined-benchmark ]] || exit 2 ;;
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
  if [[ "$FLAG" == --dataset ]]; then DATASET="$1"; fi
  if [[ "$FLAG" == --profile ]]; then PROFILE="$1"; fi
  shift
done
REQUIRED_FLAGS=(--profile --output-dir)
if [[ "$COMMAND" != validate-profile ]]; then REQUIRED_FLAGS+=("$LIST_FLAG"); fi
if [[ "$COMMAND" == fingerprint || "$COMMAND" == compare-tensors || "$COMMAND" == evaluate ]]; then
  REQUIRED_FLAGS+=(--model)
fi
if [[ "$COMMAND" == search-benchmark ]]; then
  REQUIRED_FLAGS+=(--asset-count --edited-fraction)
fi
if [[ "$COMMAND" == combined-benchmark ]]; then
  REQUIRED_FLAGS+=(--model --input-list --asset-count --edited-fraction)
fi
if [[ "$COMMAND" == score-catalog ]]; then REQUIRED_FLAGS+=(--catalog); fi
for REQUIRED in "${REQUIRED_FLAGS[@]}"; do
  if [[ "$SEEN_FLAGS" != *"|$REQUIRED|"* ]]; then
    echo "probe: missing option $REQUIRED" >&2
    exit 2
  fi
done

# One read and one R1 validation produce the immutable values passed to Swift.
APPROVED_BINDING="$(python3 - "$ROOT" "$PROTOCOL" "$PROFILE" "$COMMAND" <<'PY'
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

root, path, profile_path, command = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4]
spec = importlib.util.spec_from_file_location("advanced_dedup_research", root / "scripts/advanced-dedup/research.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
raw = path.read_bytes()
document = json.loads(raw)
protocol = module.validate_protocol(document)
if not protocol["approved"]:
    raise ValueError("research protocol has not been approved")
if command in {"score-batch", "score-catalog", "search-benchmark", "combined-benchmark", "evaluate"}:
    module._validated_profile(Path(profile_path), hashlib.sha256(raw).hexdigest(), document)
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
if [[ "$COMMAND" == evaluate ]]; then
  # The frozen expected-results binding must pass before decoding or scoring any image.
  python3 "$ROOT/scripts/dedup-fixtures/validate.py" --dataset "$DATASET" --require-approved >/dev/null
  exec python3 "$ROOT/scripts/advanced-dedup/research.py" evaluate \
    --protocol "$PROTOCOL" "${ARGS[@]:1}"
fi
mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
xcrun swiftc -O -module-cache-path "$MODULE_CACHE" -module-name AdvancedDedupProbe \
  "$ROOT/Sources/PhotoSyncCore/Matching/AdvancedDedupTypes.swift" \
  "$ROOT/Sources/PhotoSyncCore/Matching/ExactVectorIndex.swift" \
  "$ROOT/Sources/PhotoSyncCore/Matching/AdvancedDuplicatePolicy.swift" \
  "$ROOT/Sources/PhotoSyncCore/Fingerprinting/ImagePreprocessor.swift" \
  "$ROOT/Sources/PhotoSyncCore/Fingerprinting/CoreMLFingerprinter.swift" \
  "$ROOT/Tools/AdvancedDedupProbe/main.swift" \
  -o "$BIN"
exec "$BIN" "${ARGS[@]}" --approved-protocol-json "$APPROVED_BINDING"
