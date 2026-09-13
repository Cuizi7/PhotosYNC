#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 "Usage: $0 /absolute/path/to/PhotoSync.app /absolute/path/to/PhotoSync.dmg"
  exit 64
}

[[ $# -eq 2 ]] || usage

app_path=$1
dmg_path=$2

[[ "$app_path" = /* && "$dmg_path" = /* ]] || usage
[[ -d "$app_path" && "$app_path" == *.app ]] || {
  print -u2 "App bundle not found: $app_path"
  exit 66
}

output_dir=${dmg_path:h}
[[ -d "$output_dir" ]] || {
  print -u2 "Output directory does not exist: $output_dir"
  exit 73
}

stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/photosync-dmg.XXXXXX")
cleanup() {
  rm -rf -- "$stage_dir"
}
trap cleanup EXIT HUP INT TERM

ditto "$app_path" "$stage_dir/PhotoSync.app"
ln -s /Applications "$stage_dir/Applications"

hdiutil create -volname "PhotoSync" -srcfolder "$stage_dir" -ov -format UDZO "$dmg_path"
print "Created $dmg_path"
