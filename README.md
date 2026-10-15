# PhotosYNC

PhotosYNC scans selected filesystem folders and adds eligible images and videos to the current macOS System Photo Library. It is intentionally one-way: source files stay in place, and PhotosYNC never modifies or removes an existing Photos asset.

## 0.2.1 stable

0.2.1 adds PR #1 native UI improvements: segmented import progress, a details popover, clearer source paths, and a height-limited scrolling source list in Settings. The [2026-10-13 visual acceptance](docs/release/2026-10-13-native-ui-acceptance.md) is historical user acceptance; the [2026-10-15 follow-up](docs/release/2026-10-15-native-interaction-followup.md) added zero product interaction assertions (zero passed, zero failed). Physical hover, keyboard and system menu interactions retain the disclosed gaps. Core, schema v8, the model, the 0.98 threshold, permissions and Photos resource reads retain 0.2.0 behavior; this version adds no database migration.

The 0.2 series uses SSCD Large FP16 with Float32 input/output and a native gallery-analysis panel. On Apple Silicon, Core ML requests CPU + Neural Engine first, then CPU + GPU as the sole fallback. Intel requests CPU + GPU. Every newly loaded instance must pass four fixed numerical checks before producing photo fingerprints. Both configurations can use CPU internally; the application does not select a CPU-only fallback. Unavailable execution waits for recovery, with automatic retries at least 60 seconds apart and an explicit manual scan/resume exception.

Photos catalog reconciliation retains existing fingerprint bytes and pending work. Known changes affect their own assets; unverified entries remain excluded from decisions until content continuity is established. Stable catalog sessions and a bounded same-database change journal separate inventory progress from publication. Schema v8 preserves prior vectors and import history while withdrawing old publication for the new encoded-resource input contract. Individual Photos read failures remain isolated from healthy siblings; see the [continuity implementation and validation](docs/release/2026-10-07-photos-index-continuity-validation.md) and [read-error isolation validation](docs/release/2026-10-08-photos-read-error-isolation-validation.md). Candidate scores use system SQLite + Accelerate exact Float32 queries.

Photos now streams its precisely selected original or edited-current encoded resource into an owned temporary file. Source and Photos use the same bounded ImageIO decoder and final 320 × 320 preprocessing. Each encoded file is limited to 512 MiB with a 128 MiB free-space reserve; file ownership lasts through actual pixel consumption. The input-version upgrade rebuilds old Photos preview fingerprints and transactionally rebinds only proven-equivalent Source fingerprints, preserving successful and unknown imports. See [implementation and validation](docs/release/2026-10-11-original-resource-integration-validation.md) for the real paired-sample results and remaining current/iCloud/platform boundaries.

Fixed model weights use Git LFS; install Git LFS with repository-local filters (`git lfs install --local --skip-repo`) and hydrate the exact checkout before building. The package entry point verifies and hydrates archived pointers from local objects only, and fails on absent/corrupt resources. It does not download a model at App runtime.

The user-selected threshold remains 0.98 with a 512 MiB decoded allowance and conservative original import for readable still images exceeding that allowance. This is not an independently calibrated statistical acceptance. See [current validation and limitations](docs/release/0.2.0-advanced-dedup-validation.md), including the reproduced and corrected R2 decode integration defect. The six cleaned user attachments are authorized as PhotosYNC test material in this public repository; their exact hashes and scope are recorded in [publication authorization](Tests/Fixtures/AdvancedDedup/PUBLICATION_AUTHORIZATION.md). They are not App resources. Public CI is not configured, and the existing `CI=true` refusal remains unchanged.

## Install a local build

The delivered `PhotosYNC.app` and `PhotosYNC.dmg` are local build artifacts with an ad-hoc signature. They are not Developer ID signed or notarized. Gatekeeper may prevent them opening until a signed and notarized distribution is produced.

For a local build on macOS 13 or later with Xcode installed:

```sh
# Xcode 26+ is required to compile the Icon Composer source.
# Run from a clean committed checkout. Existing release directories are preserved.
scripts/package-release.sh
```

Prepared release configuration: **0.2.1 stable (build 9)**, targeting
`outputs/releases/0.2.1/`; see [release notes](docs/release/0.2.1.md)
and the [changelog](CHANGELOG.md). The stable package archives the exact main
commit and runs full acceptance; its provenance and validation records identify
the actual source, completion status and results. Prior success cannot replace them.
This release integrates PR #1 UI improvements on the 0.2.0 baseline. Previous
[0.2.0 stable build 8](docs/release/0.2.0.md) and completed
[0.2.0 beta build 7](docs/release/0.2.0-beta.md) notes and evidence are retained. The package entry point requires Apple Silicon and Intel code,
the compiled layered icon and an ICNS fallback for older macOS. The previous
0.1.0 stable build 6 notes remain [historical release evidence](docs/release/0.1.0.md).

Before first launch after upgrading, quit PhotosYNC normally and back up the complete
`~/Library/Application Support/PhotoSync/` directory, including any SQLite WAL/SHM
files. The app transactionally migrates supported schemas v3–v7 to v8; older apps reject the upgraded database on reopening.
Direct downgrade is not supported. Restoring an old database after new imports can
lose success evidence and cause duplicate additions; see the release notes for the
backup and downgrade boundary. Packaging does not back up or migrate production data.

Open the DMG, drag `PhotosYNC.app` to `Applications`, then launch it. The menu-bar app asks for read-write access to the **System Photo Library** only after you choose **Authorize Photos**. Once macOS grants that access and at least one source is enabled, PhotosYNC can scan and submit additions to that library. It does not select, migrate, or mount another library, and it does not change iCloud Photos settings.

## Daily behavior

Choose one or more source folders in Settings. PhotosYNC scans at launch and then every 30 minutes. A manual scan is available from the menu bar; overlapping scans are ignored, and sleep recovery does not create a backlog. Pausing stops new scan work. A Photos submission already handed to the system is allowed to finish so its result can be recorded conservatively.

Only supported bitmap images and videos are considered. RAW files, Live Photo pairing, transcoding, album mapping, media hashing, and source-file caching are out of scope. Photos use visual fingerprints across filenames with the selected 0.98 threshold and resolution rules; videos retain exact-filename and conservative metadata matching. Eligible old suspected-duplicate photo skips are reconsidered under the new policy; successful imports and unknown submissions remain protected. A possible duplicate is skipped and logged rather than imported. An earlier successful import remains recorded even if the Photos asset is later removed, so it is not automatically re-imported. Removing a source in Settings hides and disables that configuration while retaining its import history; it does not delete any source files or Photos assets. Re-adding the same path restores that history.

PhotosYNC never moves, deletes, renames, transcodes, writes, or hashes a source file. It sends additions to Photos only. It also never deletes or overwrites a Photos asset. Import completion means PhotoKit accepted the addition; it does not mean the asset has finished syncing to iCloud.

## Storage, logs, and recovery

The canonical runtime-state and recovery contract is [the runtime state specification](docs/specs/2026-09-18-runtime-state-and-recovery.md). It defines the distinction between source outages, file issues, read deferrals, global blockers, counters, and retry schedules.

The app stores its own configuration and SQLite state at `~/Library/Application Support/PhotoSync/sync.sqlite`; this existing path and bundle identity are retained across the PhotosYNC rename. It stores rolling diagnostic logs under its Application Support `Logs` directory; use **Open Logs in Finder** in Settings to reveal it. Logs and the SQLite database contain operational metadata, never original media copies.

Unavailable folders enter source recovery backoff; file or metadata errors stay attached to the affected file and do not quarantine a healthy source. Bounded read contention and logical timeouts are normal deferred work: they do not create failure records or retry errors, and return through a separate short schedule. A genuinely non-interruptible filesystem read can occupy a fixed worker slot; when those slots remain stuck, the app reports controlled degradation and may require restart. It does not create unlimited workers to bypass that condition.

If an import result is uncertain after an interruption, PhotosYNC keeps it in an importing/waiting state and verifies the stored placeholder on a later run. It does not silently retry based on one missing lookup. To retry safely, the system must provide explicit evidence that the change was not committed.

## Boundaries

The user has authorized 0.2 validation on this Mac's actively used production System Photo Library. The [real Photos/iCloud plan](docs/release/2026-10-06-real-photos-icloud-validation-plan.md) requires isolated QA state, read-only source dry runs first, then one self-made canary with exact-ID rollback. Existing assets and production application data are not edited or restored from an old snapshot. The [current closeout record](docs/release/2026-10-13-final-real-qa-closeout.md) covers 256 scoped assets, 262 effective representations and 3,017 Source photos: 51 content-duplicate decisions, 2,965 below-threshold decisions and one typed waiting error. Blind review of 87 groups concluded 36 duplicates, 50 distinct and one uncertain; established labels agree with the algorithm within the supplied candidate scope. Six natural original/current pairs passed; a required-network/iCloud-only scene was not established. One self-made canary passed import, same-path and renamed-copy checks, exact-ID deletion and retained-success rescan. The user confirmed targeted permanent deletion in Recently Deleted; the QA host exited, released the production lock and preserved the prior stopped App state. This does not establish other-device cloud propagation or restore system caches. A read gap can miss duplicates proven only by that representation. macOS 13 and Intel runtime behavior remain unverified, with both device tests excluded from this release's closeout requirements; the macOS 13 minimum and Universal build checks remain in scope. The older isolated-account/iCloud-off procedure in `Design/Validation.md` is historical evidence.

PhotosYNC does not synchronize deletions, re-import assets removed from Photos, manage Photos libraries, auto-mount network storage, or provide a media browser. A slow or disconnected network mount is treated as a source error or waiting condition, not as a reason to alter the mount or the source contents.


## Automated acceptance and local release

Run `python3 scripts/validate.py --output-dir "$PWD/work/validation-check" --derived-data "$PWD/work/validation-check-derived"` with a fresh evidence path for development acceptance. It runs the complete hostless XCTest bundle, synthetic tool tests and the version-controlled continuation-race regression. Failed, empty or timed-out runs do not produce a successful acceptance record.

`scripts/package-release.sh` performs this validation inside a clean committed `git archive`, then builds the normal Universal Release app from the same source. Only validated and verified bundles are published into a new release directory; old releases and concurrent publication locks are not overwritten. Validation evidence accompanies the package and is tied to its source provenance. There is no test-skip or cached-success release path.

Routine beta iterations reuse established real-Photos integration evidence and require the automated gates. Changes to actual PhotoKit/authorization/media/platform boundaries need targeted system acceptance. The automation does not use personal Photos, production database snapshots or system-permission changes. See [agent acceptance rules](AGENTS.md) and [validation history](Design/Validation.md) for the distinction between automated, historical and current system evidence.
