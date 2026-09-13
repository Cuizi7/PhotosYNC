# Task 3 Report: Read-only Directory and Metadata Readers

## Scope

- Added `DirectoryReader` and its protocol/value boundary. It enumerates one directory at a time, skips hidden entries, aliases, symbolic links, and directory packages, and obtains only size and modification-date stamps for files.
- Added `MetadataReader` using uncached ImageIO image properties and asynchronous `AVURLAsset` video metadata. It excludes RAW, does not decode thumbnails or media content, preserves EXIF original time text, records TIFF make/model and dimensions, and returns an absolute Unix second only with a valid `OffsetTimeOriginal`.
- Added a fixed two-slot `ReadExecutor`. A timed-out logical caller receives `timedOut`, while the physical worker slot and source ownership remain occupied until the synchronous work actually returns. Continuation completion is guarded, so timer and worker races resume once only.
- Added synthetic, ephemeral test fixtures and source-reader coverage. The reader test snapshots source bytes and modification time before/after metadata extraction.
- Removed task 1's test-only Unix-second floor helper. Production `MetadataReader.captureSecond` now has direct positive and pre-epoch fractional floor assertions.

## RED

The initial focused test target did not compile because the public reader interfaces and `ReadExecutor` had not been added. Subsequent RED compiler checks also caught Swift async assertion and continuation-syntax defects before the implementation was green.

## GREEN

```sh
xcodebuild build-for-testing -project PhotoSync.xcodeproj -scheme PhotoSync \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath work/DerivedData CODE_SIGNING_ALLOWED=NO
xcrun xctest work/DerivedData/Build/Products/Debug/PhotoSyncCoreTests.xctest
```

Final output:

```text
** TEST BUILD SUCCEEDED **
Executed 31 tests, with 0 failures
```

`SourceReaderTests` executed 7 tests with 0 failures, covering corrupt/missing-EXIF/RAW handling, directory exclusion rules, source immutability, explicit and unknown timezones, timeout/source retry ownership, two-slot exhaustion, and timer/worker completion races.

## Self-review

- `git diff --check` passed.
- Production readers contain no PhotoKit imports, hash calculation, original-media caching, writes, thumbnails, or transcode operations.
- The only fixture writes occur while creating synthetic temporary test directories. Tests do not access personal photos or the Photos library.
- The fixed `OperationQueue` rejects excess work rather than creating replacement worker threads; timed-out work retains its slot until the underlying closure returns.

## Concern

The current bounded executor exposes resource exhaustion immediately, rather than maintaining a coordinator-level deferred queue. This preserves the strict two-slot/no-unbounded-buffer boundary; the later sync coordinator owns directory queueing and retry scheduling.

## Fix 1 (2026-09-13)

### Addressed review findings

- Reader instances now bind to a configured `UUID` source identity and a shared executor. Directory and metadata calls within one source therefore retain the same physical ownership after timeout or cancellation.
- `OffsetTimeOriginal` is retained as `MediaMetadata.rawCaptureOffset`; EXIF offset parsing accepts only ASCII `+/-HH:MM` with a literal colon and bounded hours/minutes, without force unwraps.
- `ReadExecutor` rejects cancellation before admission and logically completes a cancelled caller during physical work while retaining the source and slot until the closure returns. Timeout tasks are owned by the operation state and cancelled on every terminal completion. Snapshot pending work no longer counts running operations.
- Video reads run through the same source-bound executor and derive an absolute timestamp only when AVFoundation supplies a creation date with an explicit offset. AVFoundation did not expose the explicit-offset field from the locally generated ffmpeg MOV/MP4 fixture in this runtime, so no synthetic-video assertion was retained; the conservative implementation remains covered by the explicit parser behavior.
- Test fixtures now create a real JPEG containing EXIF/TIFF metadata. RAW exclusion covers a wider extension set plus `UTType.rawImage`.

### Verification

```sh
xcodebuild build-for-testing -project PhotoSync.xcodeproj -scheme PhotoSync \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath work/DerivedData CODE_SIGNING_ALLOWED=NO
xcrun xctest work/DerivedData/Build/Products/Debug/PhotoSyncCoreTests.xctest
git diff --check
```

Output: `** TEST BUILD SUCCEEDED **`; `Executed 37 tests, with 0 failures`; `git diff --check` produced no output.

### Self-review

The changes remain limited to reader/executor/metadata-domain code and synthetic tests. They do not access PhotoKit, write personal media, or change source data after fixture creation. The only unresolved acceptance gap is an actual AVFoundation synthetic video fixture with an explicit offset: ffmpeg writes the requested field (confirmed with ffprobe), but this runtime's AVFoundation metadata APIs returned no creation-date item for that generated asset.

## Fix 2 (2026-09-13)

- Guarded `ReadExecutor.executeAsync` with `beginPhysicalWork()` before invoking its child operation. A caller cancelled after admission now completes logically while the spawned task performs only unconditional source/slot cleanup.
- Added a direct cancellation-before-child-work regression test and a parser-only explicit-offset video timestamp test. The AVFoundation synthetic-fixture limitation remains documented above.

Verification repeated:

```text
** TEST BUILD SUCCEEDED **
Executed 39 tests, with 0 failures
```

## Fix 3 (2026-09-13)

- Added an internal executor start gate used only by the test target. The regression now deterministically admits the async read, blocks the spawned child task before `beginPhysicalWork()`, cancels the caller, releases the gate, and verifies that the supplied async operation was never invoked while physical cleanup completed.
- The parser-only video test covers explicit-offset conversion; this report does not claim full `readVideo` fixture coverage because the AVFoundation fixture limitation remains unresolved.

Verification repeated:

```text
** TEST BUILD SUCCEEDED **
Executed 39 tests, with 0 failures
```
