# PhotoSync

PhotoSync v1 scans selected filesystem folders and adds eligible images and videos to the current macOS System Photo Library. It is intentionally one-way: source files stay in place, and PhotoSync never modifies or removes an existing Photos asset.

## Install a local build

The delivered `PhotoSync.app` and `PhotoSync.dmg` are local build artifacts with an ad-hoc signature. They are not Developer ID signed or notarized. Gatekeeper may prevent them opening until a signed and notarized distribution is produced.

For a local build on macOS 14 or later with Xcode installed:

```sh
xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync -configuration Release \
  -destination 'platform=macOS' -derivedDataPath work/Release \
  CODE_SIGNING_ALLOWED=NO build

mkdir -p outputs
ditto work/Release/Build/Products/Release/PhotoSync.app outputs/PhotoSync.app
scripts/build-dmg.sh "$PWD/outputs/PhotoSync.app" "$PWD/outputs/PhotoSync.dmg"
```

Open the DMG, drag `PhotoSync.app` to `Applications`, then launch it. The menu-bar app asks for read-write access to the **System Photo Library** only after you choose **Authorize Photos**. Once macOS grants that access and at least one source is enabled, PhotoSync can scan and submit additions to that library. It does not select, migrate, or mount another library, and it does not change iCloud Photos settings.

## Daily behavior

Choose one or more source folders in Settings. PhotoSync scans at launch and then every 30 minutes. A manual scan is available from the menu bar; overlapping scans are ignored, and sleep recovery does not create a backlog. Pausing stops new scan work. A Photos submission already handed to the system is allowed to finish so its result can be recorded conservatively.

Only supported bitmap images and videos are considered. RAW files, Live Photo pairing, transcoding, album mapping, media hashing, and source-file caching are out of scope. Duplicate decisions use exact filenames and conservative public metadata. A possible duplicate is skipped and logged rather than imported. An earlier successful import remains recorded even if the Photos asset is later removed, so it is not automatically re-imported.

PhotoSync never moves, deletes, renames, transcodes, writes, or hashes a source file. It sends additions to Photos only. It also never deletes or overwrites a Photos asset. Import completion means PhotoKit accepted the addition; it does not mean the asset has finished syncing to iCloud.

## Storage, logs, and recovery

The app stores its own configuration and SQLite state under its Application Support directory. It stores rolling diagnostic logs under its Application Support `Logs` directory; use **Open Logs in Finder** from the menu bar to reveal it. Logs and the SQLite database contain operational metadata, never original media copies.

Unavailable folders, metadata errors, Photos permissions, unavailable libraries, and failed state writes remain visible as failures or waiting states. A source read that is slow but returns can recover without blocking all sources. A genuinely non-interruptible filesystem read can occupy a fixed worker slot; when those slots remain stuck, the app reports controlled degradation and may require restart. It does not create unlimited workers to bypass that condition.

If an import result is uncertain after an interruption, PhotoSync keeps it in an importing/waiting state and verifies the stored placeholder on a later run. It does not silently retry based on one missing lookup. To retry safely, the system must provide explicit evidence that the change was not committed.

## Boundaries

Do not use a personal Photos library as a test fixture. Real Photos-write validation requires a separate macOS test account, its System Photo Library, disabled iCloud Photos, and user authorization for that isolated environment. See `Design/Validation.md` for the procedure and current validation status.

PhotoSync v1 does not synchronize deletions, re-import assets removed from Photos, manage Photos libraries, auto-mount network storage, or provide a media browser. A slow or disconnected network mount is treated as a source error or waiting condition, not as a reason to alter the mount or the source contents.
