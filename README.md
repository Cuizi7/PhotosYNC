# PhotosYNC

PhotosYNC v1 scans selected filesystem folders and adds eligible images and videos to the current macOS System Photo Library. It is intentionally one-way: source files stay in place, and PhotosYNC never modifies or removes an existing Photos asset.

## Install a local build

The delivered `PhotosYNC.app` and `PhotosYNC.dmg` are local build artifacts with an ad-hoc signature. They are not Developer ID signed or notarized. Gatekeeper may prevent them opening until a signed and notarized distribution is produced.

For a local build on macOS 13 or later with Xcode installed:

```sh
# Xcode 26+ is required to compile the Icon Composer source.
# Run from a clean committed checkout. Existing release directories are preserved.
scripts/package-release.sh
```

Current frozen release: **0.1.0 beta3 (build 3)**. Artifacts are under
`outputs/releases/0.1.0-beta3/`; see [release notes](docs/release/0.1.0-beta3.md).
The package includes Apple Silicon and Intel code, the compiled layered icon and
an ICNS fallback for older macOS.

Open the DMG, drag `PhotosYNC.app` to `Applications`, then launch it. The menu-bar app asks for read-write access to the **System Photo Library** only after you choose **Authorize Photos**. Once macOS grants that access and at least one source is enabled, PhotosYNC can scan and submit additions to that library. It does not select, migrate, or mount another library, and it does not change iCloud Photos settings.

## Daily behavior

Choose one or more source folders in Settings. PhotosYNC scans at launch and then every 30 minutes. A manual scan is available from the menu bar; overlapping scans are ignored, and sleep recovery does not create a backlog. Pausing stops new scan work. A Photos submission already handed to the system is allowed to finish so its result can be recorded conservatively.

Only supported bitmap images and videos are considered. RAW files, Live Photo pairing, transcoding, album mapping, media hashing, and source-file caching are out of scope. Duplicate decisions use exact filenames and conservative public metadata. A possible duplicate is skipped and logged rather than imported. An earlier successful import remains recorded even if the Photos asset is later removed, so it is not automatically re-imported. Removing a source in Settings hides and disables that configuration while retaining its import history; it does not delete any source files or Photos assets. Re-adding the same path restores that history.

PhotosYNC never moves, deletes, renames, transcodes, writes, or hashes a source file. It sends additions to Photos only. It also never deletes or overwrites a Photos asset. Import completion means PhotoKit accepted the addition; it does not mean the asset has finished syncing to iCloud.

## Storage, logs, and recovery

The canonical runtime-state and recovery contract is [the runtime state specification](docs/specs/2026-09-18-runtime-state-and-recovery.md). It defines the distinction between source outages, file issues, read deferrals, global blockers, counters, and retry schedules.

The app stores its own configuration and SQLite state at `~/Library/Application Support/PhotoSync/sync.sqlite`; this existing path and bundle identity are retained across the PhotosYNC rename. It stores rolling diagnostic logs under its Application Support `Logs` directory; use **Open Logs in Finder** in Settings to reveal it. Logs and the SQLite database contain operational metadata, never original media copies.

Unavailable folders enter source recovery backoff; file or metadata errors stay attached to the affected file and do not quarantine a healthy source. Bounded read contention and logical timeouts are normal deferred work: they do not create failure records or retry errors, and return through a separate short schedule. A genuinely non-interruptible filesystem read can occupy a fixed worker slot; when those slots remain stuck, the app reports controlled degradation and may require restart. It does not create unlimited workers to bypass that condition.

If an import result is uncertain after an interruption, PhotosYNC keeps it in an importing/waiting state and verifies the stored placeholder on a later run. It does not silently retry based on one missing lookup. To retry safely, the system must provide explicit evidence that the change was not committed.

## Boundaries

Do not use a personal Photos library as a test fixture. Real Photos-write validation requires a separate macOS test account, its System Photo Library, disabled iCloud Photos, and user authorization for that isolated environment. See `Design/Validation.md` for the procedure and current validation status.

PhotosYNC v1 does not synchronize deletions, re-import assets removed from Photos, manage Photos libraries, auto-mount network storage, or provide a media browser. A slow or disconnected network mount is treated as a source error or waiting condition, not as a reason to alter the mount or the source contents.


## Automated acceptance and local release

Run `python3 scripts/validate.py --output-dir "$PWD/work/validation-check" --derived-data "$PWD/work/validation-check-derived"` with a fresh evidence path for development acceptance. It runs the complete hostless XCTest bundle, synthetic tool tests and the version-controlled continuation-race regression. Failed, empty or timed-out runs do not produce a successful acceptance record.

`scripts/package-release.sh` performs this validation inside a clean committed `git archive`, then builds the normal Universal Release app from the same source. Only validated and verified bundles are published into a new release directory; old releases and concurrent publication locks are not overwritten. Validation evidence accompanies the package and is tied to its source provenance. There is no test-skip or cached-success release path.

Routine beta iterations reuse established real-Photos integration evidence and require the automated gates. Changes to actual PhotoKit/authorization/media/platform boundaries need targeted system acceptance. The automation does not use personal Photos, production database snapshots or system-permission changes. See [agent acceptance rules](AGENTS.md) and [validation history](Design/Validation.md) for the distinction between automated, historical and current system evidence.
