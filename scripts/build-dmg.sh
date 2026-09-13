#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 "Usage: $0 /absolute/path/to/PhotoSync.app /absolute/path/to/PhotoSync.dmg"
  exit 64
}

fail() {
  print -u2 "$1"
  exit "$2"
}

canonical_path() {
  realpath "$1"
}

is_within() {
  local child=$1
  local parent=$2
  [[ "$child" == "$parent" || "$child" == "$parent/"* ]]
}

[[ $# -eq 2 ]] || usage

app_path=$1
dmg_path=$2

[[ "$app_path" = /* && "$dmg_path" = /* ]] || usage
[[ -d "$app_path" && "$app_path" == *.app ]] || {
  fail "App bundle not found: $app_path" 66
}
[[ "$dmg_path" == *.dmg ]] || fail "Output path must end in .dmg: $dmg_path" 64

output_dir=${dmg_path:h}
[[ -d "$output_dir" ]] || {
  fail "Output directory does not exist: $output_dir" 73
}

app_path=$(canonical_path "$app_path")
output_dir=$(canonical_path "$output_dir")
[[ ! -e "$dmg_path" ]] || dmg_path=$(canonical_path "$dmg_path")
is_within "$dmg_path" "$app_path" && fail "Output DMG must not be inside the app bundle: $dmg_path" 64

plist_path="$app_path/Contents/Info.plist"
[[ -f "$plist_path" ]] || fail "Missing app Info.plist: $plist_path" 66
plutil -lint "$plist_path" >/dev/null || fail "Invalid app Info.plist: $plist_path" 66
package_type=$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$plist_path" 2>/dev/null) || \
  fail "Missing CFBundlePackageType in app Info.plist: $plist_path" 66
[[ "$package_type" == "APPL" ]] || fail "Invalid CFBundlePackageType in app Info.plist: $plist_path" 66
executable_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist_path" 2>/dev/null) || \
  fail "Missing CFBundleExecutable in app Info.plist: $plist_path" 66
[[ -n "$executable_name" && "$executable_name" != */* ]] || \
  fail "Invalid CFBundleExecutable in app Info.plist: $plist_path" 66
executable_path="$app_path/Contents/MacOS/$executable_name"
[[ -f "$executable_path" && -x "$executable_path" ]] || \
  fail "App executable is missing or not executable: $executable_path" 66

stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/photosync-dmg.XXXXXX")
cleanup() {
  rm -rf -- "$stage_dir"
}
trap cleanup EXIT HUP INT TERM

ditto "$app_path" "$stage_dir/${app_path:t}"
ln -s /Applications "$stage_dir/Applications"

hdiutil create -volname "PhotoSync" -srcfolder "$stage_dir" -ov -format UDZO "$dmg_path"
print "Created $dmg_path"
