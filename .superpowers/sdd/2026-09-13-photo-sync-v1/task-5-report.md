# Task 5 — resumable multi-source coordination

Implemented `SyncEngine` with UUID-bound directory/metadata factories, the shared physical ReadExecutor, concurrent source scans, and a single retained Photos drain task. Current source list/add/disable plus startup/manual scan, pause/resume, recovery, and snapshot APIs are public. Checked/imported/skipped/failed describe the latest scan round; pending is a current persisted count (queried even while a Photos callback is held). Waiting source reasons remain visible with active work. SQLite failures stop submissions for the engine lifetime.

Pending history reenters the drain; importing reconciles without treating a missing fetch as failure. Unchanged terminal history avoids metadata rereads, and source changes preserve success identity. Submission checks the fresh stamp and Photos index, then compares older pending reservations plus all unresolved/successful history, excluding self. Actual matching snapshots are persisted. Process-local unknown results retain a submission barrier across rounds; historical unknown imports reserve their matching names while other files can proceed.

Physical Photos calls are never canceled/replaced to bypass the one slot. Later source rounds can scan during a held callback. A committed late result is persisted even after pause or later index-health loss. The gateway instance is never recreated here.

## Scoped integration correction

Controller explicitly authorized the ReadExecutor acceptance blocker correction: it resumed a successful physical operation before clearing its source occupancy, allowing a sequential operation to fail `sourceBusy`. Both synchronous and async physical operations now release occupancy before returning their final result. Timeout/cancellation still retain physical ownership until the actual operation ends. No other reader behavior changed.

## RED / GREEN evidence

Commands used (macOS hostless bundle; no Photos permission API or real library write):

```
xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync -configuration Debug -derivedDataPath /tmp/photo-sync-task5 build-for-testing CODE_SIGNING_ALLOWED=NO
xcrun xctest /tmp/photo-sync-task5/Build/Products/Debug/PhotoSyncCoreTests.xctest
```

RED evidence:
- `/tmp/task5-red.log`: missing `SyncEngine` type before implementation.
- `/tmp/task5-tests.log` / subsequent initial test run: relative-path handling from `/var` versus `/private/var` failed to find persisted source paths; traversal-relative components corrected this.
- `/tmp/task5-red2-tests.log`: held Photos / later scan and metadata recovery regressions exposed integration problems.
- `/tmp/task5-red3-tests.log`: sequential same-source reads failed with 292 assertions (occupancy still 1) and `sourceBusy` before ReadExecutor fix.
- `/tmp/task5-red4-tests.log`: unknown result allowed second creation across rounds (2 versus 1) before the persistent uncertainty barrier.
- `/tmp/task5-pending-red-tests.log`: pending snapshot stayed 0 while a live Photos request held the slot and another source queued a file; fixed using an async current COUNT query.

Final GREEN `/tmp/task5-final-build.log`: BUILD SUCCEEDED. `/tmp/task5-final-tests.log`: September 13, 2026 21:35:15 +0800, 65 tests, 0 failures. Suites: Engine 14, Store 14, Recovery 3, SourceReader 15, PhotoKitContract 9, DuplicatePolicy 10. Engine fixtures generate their own JPEGs and SQLite databases in test temporary directories. SQL trigger injects persistence failure after successful Photos creation; held continuations inject delayed physical responses. Tests never access the user's Photos library.

## Self-review / downstream limits

All changes map to Task5 or the controller-approved executor acceptance blocker. No source file mutation in production paths. No Photos deletion, live authorization or test import was performed.

`PhotoKitGateway` intentionally remains poisoned after a placeholder checkpoint failure. Once reconciliation resolves every outstanding uncertainty, app lifecycle may safely construct a fresh gateway/engine; it must never recreate a gateway to bypass unresolved physical work. This engine keeps the injected adapter and does not implement adapter lifecycle replacement.

When all globally bounded physical reader slots are occupied by unavailable mounts, another source can report resource exhaustion until a subsequent scheduled round; source tasks still run independently, and occupancy is never bypassed. Scan counters reflect the latest round; a callback completing during a later round is counted in the currently visible round. Production signing and live Photos acceptance are outside this task.

## Scoped review fix round 1

Addressed Task5 review P1 and P2 only. P1 now rechecks pause, storage/global block, source disable intent and process uncertainty after suspended preparation and immediately before calling Photos. Source disable closes admission synchronously before its SQLite await. Active-attempt identity is reserved before beginAttempt suspends; if dispatch is prevented after preparation, existing definite-not-committed retry transitions it safely to pending. P2 submission stat failures now increment visible failure count, emit a path/error log, persist pending error/retry with 60-second backoff, and mark the source's scan journal incomplete with a durable error.

RED `/tmp/task5-fix-red-tests.log`: 16 Engine tests with 7 failures. Held pre-submit stat plus another source's SQLite trigger produced an unauthorized create (1 versus 0) and imported versus pending. Submission-stat failure had no next retry, failure count or incomplete/error scan journal, and no retry count. These tests use two independently released barriers and temporary SQLite triggers.

GREEN `/tmp/task5-fix-green-build.log`: build succeeded; `/tmp/task5-fix-green-tests.log`: 67 Core tests, 0 failures (16 Engine; other suites unchanged). Commands are the same build-for-testing plus direct xctest above. No system Photos API call or live media write performed. Self-review confirmed the final admission check has no intervening engine await before Photos dispatch, and prohibited dispatch after a prepared attempt uses explicit no-dispatch evidence rather than a fetch miss.

## Scoped review fix round 2

Fixed remaining P2 journal finalization race only. `finishScan` now atomically adds scan-local failures to already persisted submission failures, preserves the existing error, and cannot mark a run complete when it already has a failure. Thus either operation ordering (submission failure before/after finalization) preserves journal truth.

Deterministic RED `/tmp/task5-fix2-red-tests.log`: a source with an existing pending record blocked while enumerating its subdirectory; another source completed and started the drain; pending-source submission stat failed and journal failed=1 was observed before releasing enumeration. Old finalization overwrote that count to 0 and marked complete, producing 2 failures. GREEN `/tmp/task5-fix2-green-build.log` and `/tmp/task5-fix2-green-tests.log`: build succeeded; 68 Core tests, 0 failures, including 17 Engine tests. No production behavior outside journal accumulation changed.
