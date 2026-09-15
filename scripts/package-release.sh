#!/bin/zsh
# Package a clean source snapshot without launching the app or touching user data.
set -euo pipefail
cd "${0:A:h:h}"
release_name=0.1.0-beta
release_dir="$PWD/outputs/releases/$release_name"
[[ ! -e "$release_dir" ]] || { print -u2 "Release already exists: $release_dir"; exit 73; }
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || { print -u2 'Commit tracked changes before packaging.'; exit 65; }
source_commit=$(git rev-parse HEAD)
mkdir -p work outputs/releases
final_release_dir=$release_dir
build_dir=$(mktemp -d "$PWD/work/release-${release_name}.XXXXXX")
release_dir="$build_dir/package"
mkdir -p "$release_dir"
print "Build evidence: $build_dir"
source_dir="$build_dir/source"
mkdir -p "$source_dir"
git archive "$source_commit" | tar -x -C "$source_dir"
cd "$source_dir"
xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$build_dir/DerivedData" \
  CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build > "$build_dir/build.log" 2>&1
app_path="$release_dir/PhotosYNC.app"
ditto "$build_dir/DerivedData/Build/Products/Release/PhotosYNC.app" "$app_path"
codesign --force --sign - --timestamp=none "$app_path/Contents/Frameworks/PhotoSyncCore.framework"
codesign --force --sign - --timestamp=none "$app_path"
codesign --verify --deep --strict --all-architectures "$app_path"
[[ -s "$app_path/Contents/Resources/Assets.car" && -s "$app_path/Contents/Resources/PhotosYNC.icns" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")" == '0.1.0' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")" == '1' ]]
lipo "$app_path/Contents/MacOS/PhotosYNC" -verify_arch arm64 x86_64
lipo "$app_path/Contents/Frameworks/PhotoSyncCore.framework/Versions/A/PhotoSyncCore" -verify_arch arm64 x86_64
scripts/build-dmg.sh "$app_path" "$release_dir/PhotosYNC-$release_name.dmg"
hdiutil verify "$release_dir/PhotosYNC-$release_name.dmg"
cp docs/release/0.1.0-beta.md "$release_dir/RELEASE-NOTES.md"
{
  print "release=$release_name"
  print "source_commit=$source_commit"
  print "build_number=1"
  print "signing=ad-hoc; notarized=no"
  print "architectures=arm64 x86_64"
  print "minimum_macos=13.0"
  print "build_evidence=$build_dir"
  xcodebuild -version
  (cd "$release_dir" && shasum -a 256 PhotosYNC.app/Contents/MacOS/PhotosYNC \
    PhotosYNC.app/Contents/Frameworks/PhotoSyncCore.framework/Versions/A/PhotoSyncCore \
    PhotosYNC.app/Contents/Resources/Assets.car PhotosYNC.app/Contents/Resources/PhotosYNC.icns \
    "PhotosYNC-$release_name.dmg")
  shasum -a 256 scripts/package-release.sh scripts/build-dmg.sh
} > "$release_dir/PhotosYNC.provenance"
(cd "$release_dir" && shasum -a 256 "PhotosYNC-$release_name.dmg" > SHA256SUMS)
mv "$release_dir" "$final_release_dir"
print "Packaged $final_release_dir"
