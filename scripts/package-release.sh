#!/bin/zsh
# Package one clean, committed source snapshot without launching the app or touching user data.
set -euo pipefail

fail() {
  print -u2 "$1"
  exit "${2:-1}"
}

scale_profile=release
case $# in
  0) ;;
  2)
    [[ "$1" == '--scale-profile' && ( "$2" == 'release' || "$2" == 'full' ) ]] || \
      fail 'Usage: scripts/package-release.sh [--scale-profile release|full]' 64
    scale_profile="$2"
    ;;
  *) fail 'Usage: scripts/package-release.sh [--scale-profile release|full]' 64 ;;
esac

cd "${0:A:h:h}"
release_name=0.2.7
release_root="$PWD/outputs/releases"
final_release_dir="$release_root/$release_name"

[[ ! -e "$final_release_dir" && ! -L "$final_release_dir" ]] || \
  fail "Release already exists: $final_release_dir" 73
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || \
  fail 'Commit or remove tracked and non-ignored untracked changes before packaging.' 65

mkdir -p "$PWD/work" "$release_root"
[[ -d "$release_root" && ! -L "$release_root" ]] || \
  fail "Release root must be a regular directory: $release_root" 73

lock_dir="$release_root/.${release_name}.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  fail "Another package attempt holds the release lock: $lock_dir" 75
fi

staging_dir=''
cleanup() {
  local cleanup_exit_status=$?
  if [[ -n "$staging_dir" && ( -d "$staging_dir" || -L "$staging_dir" ) ]]; then
    rm -rf -- "$staging_dir"
  fi
  rmdir "$lock_dir" 2>/dev/null || true
  trap - EXIT HUP INT TERM
  exit "$cleanup_exit_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[[ ! -e "$final_release_dir" && ! -L "$final_release_dir" ]] || \
  fail "Release appeared while waiting for the lock: $final_release_dir" 73

source_commit=$(git rev-parse HEAD)
build_dir=$(mktemp -d "$PWD/work/release-${release_name}.XXXXXX")
source_dir="$build_dir/source"
validation_dir="$build_dir/validation"
validation_derived_data="$build_dir/ValidationDerivedData"
mkdir -p "$source_dir"
print "Build evidence: $build_dir"

# Keep archive creation offline and pointer-only even when Git applies LFS filters.
GIT_LFS_SKIP_SMUDGE=1 git archive "$source_commit" | tar -x -C "$source_dir"
# The controlled archive contains pointers. Hydrate only this immutable commit's local LFS
# object and verify the complete approved package before any build or validation.
env -u RQDATAC2_CONF python3 "$source_dir/scripts/advanced-dedup/release.py" \
  --hydrate-from "$PWD" --commit "$source_commit" --archive "$source_dir" \
  --resources "$source_dir/Sources/PhotoSyncCore/Resources/AdvancedDedup" \
  --output "$build_dir/hydrated-resources.json" > "$build_dir/hydration.log" 2>&1
cd "$source_dir"

env -u RQDATAC2_CONF python3 scripts/validate.py \
  --scale-profile "$scale_profile" \
  --output-dir "$validation_dir" \
  --derived-data "$validation_derived_data" > "$build_dir/validate.log" 2>&1

validation_json="$validation_dir/validation.json"
[[ -f "$validation_json" && ! -L "$validation_json" ]] || \
  fail "Validation completed without a regular success marker: $validation_json" 70

validation_summary=$(env -u RQDATAC2_CONF PYTHONDONTWRITEBYTECODE=1 python3 -c '
import sys
from pathlib import Path
from scripts.validate import read_json, validate_scale_evidence

evidence = read_json(Path(sys.argv[1]))
validate_scale_evidence(evidence, output_dir=Path(sys.argv[1]).parent, expected_profile=sys.argv[2])
try:
    test_count = evidence["xctest"]["test_count"]
    tool_test_count = evidence["tool_tests"]["test_count"]
    manifest = evidence["source"]["manifest_sha256"]
    continuation = evidence["continuation_race"]
    continuations = evidence["continuations"]
    advanced = evidence["advanced_dedup"]
except (KeyError, TypeError) as error:
    raise SystemExit("validation evidence is missing required fields") from error
if evidence.get("status") != "passed" or not isinstance(test_count, int) or test_count <= 0:
    raise SystemExit("validation evidence does not prove a passing non-empty XCTest run")
if not isinstance(tool_test_count, int) or tool_test_count <= 0:
    raise SystemExit("validation evidence does not prove passing Python tool tests")
if not isinstance(manifest, str) or len(manifest) != 64:
    raise SystemExit("validation evidence does not contain a source manifest hash")
if continuation.get("status") != "passed" or continuation.get("regression") != "continuation-race":
    raise SystemExit("validation evidence does not prove the continuation regression")
if set(continuations) != {"stamp", "advanced-preparation"} or any(item.get("status") != "passed" for item in continuations.values()):
    raise SystemExit("validation evidence lacks both continuation scenarios")
if any(not advanced.get(key) for key in ("resources_sha256", "model_regression_sha256", "runtime_load_sha256")):
    raise SystemExit("validation evidence lacks advanced model/runtime/resource gates")
scale = evidence["scale_validation"]
print("\t".join((str(test_count), str(tool_test_count), manifest, scale["profile"],
                 ",".join(scale["required_samples"]), ",".join(scale["executed_samples"]))))
' "$validation_json" "$scale_profile")
IFS=$'\t' read -r validation_test_count validation_tool_test_count validation_manifest_hash \
  validation_scale_profile validation_scale_required validation_scale_executed <<< "$validation_summary"

archive_source_manifest() {
  env -u RQDATAC2_CONF PYTHONDONTWRITEBYTECODE=1 python3 -c '
from pathlib import Path
from scripts.validate import build_source_manifest

print(build_source_manifest(Path.cwd()).digest)
'
}

require_validated_source_snapshot() {
  local current_manifest_hash
  current_manifest_hash=$(archive_source_manifest)
  [[ "$current_manifest_hash" == "$validation_manifest_hash" ]] || \
    fail 'Archived source changed after validation; refusing to publish.' 70
}

staging_dir=$(mktemp -d "$release_root/.${release_name}.staging.XXXXXX")
release_dir="$staging_dir"

env -u RQDATAC2_CONF xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$build_dir/ReleaseDerivedData" \
  CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build > "$build_dir/release-build.log" 2>&1
require_validated_source_snapshot

app_path="$release_dir/PhotosYNC.app"
ditto "$build_dir/ReleaseDerivedData/Build/Products/Release/PhotosYNC.app" "$app_path"
env -u RQDATAC2_CONF python3 scripts/advanced-dedup/release.py \
  --resources "$app_path/Contents/Frameworks/PhotoSyncCore.framework/Resources/AdvancedDedup" \
  --app "$app_path" --output "$build_dir/built-resources.json" > "$build_dir/resources.log" 2>&1
cmp "$build_dir/hydrated-resources.json" "$build_dir/built-resources.json" || fail 'Built resources differ from the hydrated archive.' 70
codesign --force --sign - --timestamp=none "$app_path/Contents/Frameworks/PhotoSyncCore.framework"
codesign --force --sign - --timestamp=none "$app_path"
codesign --verify --deep --strict --all-architectures "$app_path"
[[ -s "$app_path/Contents/Resources/Assets.car" && -s "$app_path/Contents/Resources/PhotosYNC.icns" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")" == '0.2.7' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")" == '15' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :PhotoSyncReleaseChannel' "$app_path/Contents/Info.plist")" == 'stable' ]]
for architecture in arm64 x86_64; do
  lipo "$app_path/Contents/MacOS/PhotosYNC" -verify_arch "$architecture"
  lipo "$app_path/Contents/Frameworks/PhotoSyncCore.framework/Versions/A/PhotoSyncCore" -verify_arch "$architecture"
done
scripts/build-dmg.sh "$app_path" "$release_dir/PhotosYNC-$release_name.dmg"
hdiutil verify "$release_dir/PhotosYNC-$release_name.dmg"

cp docs/release/0.2.7.md "$release_dir/RELEASE-NOTES.md"
cp CHANGELOG.md "$release_dir/CHANGELOG.md"
ditto "$validation_dir" "$release_dir/validation"
cp "$build_dir/validate.log" "$release_dir/validate.log"
cp "$build_dir/release-build.log" "$release_dir/release-build.log"
cp "$build_dir/built-resources.json" "$release_dir/resources.json"

validation_json_hash=$(shasum -a 256 "$release_dir/validation/validation.json" | awk '{print $1}')
validation_report_hash=$(shasum -a 256 "$release_dir/validation/validation-report.md" | awk '{print $1}')
continuation_result_hash=$(shasum -a 256 "$release_dir/validation/continuation-race/result.json" | awk '{print $1}')
{
  print "release=$release_name"
  print "source_commit=$source_commit"
  print 'build_number=15'
  print 'signing=ad-hoc; notarized=no'
  print 'architectures=arm64 x86_64'
  print 'minimum_macos=13.0'
  print 'validation_evidence=validation'
  print 'validation_json=validation/validation.json'
  print "validation_json_sha256=$validation_json_hash"
  print 'validation_report=validation/validation-report.md'
  print "validation_report_sha256=$validation_report_hash"
  print "validation_xctest_count=$validation_test_count"
  print "validation_tool_test_count=$validation_tool_test_count"
  print "validation_scale_profile=$validation_scale_profile"
  print "validation_scale_required_samples=$validation_scale_required"
  print "validation_scale_executed_samples=$validation_scale_executed"
  print "validation_source_manifest_sha256=$validation_manifest_hash"
  print "release_source_manifest_sha256=$(archive_source_manifest)"
  print 'validation_continuation_result=validation/continuation-race/result.json'
  print "validation_continuation_result_sha256=$continuation_result_hash"
  print 'advanced_dedup_resources=resources.json'
  print "advanced_dedup_resources_sha256=$(shasum -a 256 "$release_dir/resources.json" | awk '{print $1}')"
  print 'validation_advanced_continuation_result=validation/continuation-advanced-preparation/result.json'
  print "validation_advanced_continuation_sha256=$(shasum -a 256 "$release_dir/validation/continuation-advanced-preparation/result.json" | awk '{print $1}')"
  print 'release_build_log=release-build.log'
  print 'validation_wrapper_log=validate.log'
  xcodebuild -version
  print 'packaging_scripts_sha256:'
  shasum -a 256 scripts/package-release.sh scripts/build-dmg.sh scripts/validate.py scripts/advanced-dedup/release.py
} > "$release_dir/PhotosYNC.provenance"

(
  cd "$release_dir"
  find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
) > "$release_dir/SHA256SUMS"
(
  cd "$release_dir"
  shasum -a 256 -c SHA256SUMS
)

[[ ! -e "$final_release_dir" && ! -L "$final_release_dir" ]] || \
  fail "Release appeared before publication: $final_release_dir" 73
require_validated_source_snapshot
mv "$release_dir" "$final_release_dir"
staging_dir=''
print "Packaged $final_release_dir"
