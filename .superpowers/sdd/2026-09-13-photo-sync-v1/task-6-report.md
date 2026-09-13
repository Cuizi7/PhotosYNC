# Task 6 Report: scheduling, recovery, and logging events

## Status

Implemented and committed `feat: schedule scans and source recovery`.

`ScanSchedule` is pure, clock-injected scheduling state. It provides fixed 30-minute timer admission, manual/startup/resume/wake admission, pause, no-overlap behavior, missed-timer coalescing, minute-gated recovery checks, and wall-clock rollback reset. The engine owns no scheduler lifecycle; the app can keep one `ScanSchedule` instance and call the engine only after an admitted request. Task 7 should drive its relative timer from `nextRecoveryAt`, call `dueRecoverySources(now:)` to identify due source retries, and report outcomes through `recordSourceFailure(_:now:)` or `recordSourceRecovered(_:)`.

Source retry delays are 5, 15, 30, and then 60 seconds. A successful import resets the persisted retry count. Engine lifecycle and recovery logs carry phase/result plus applicable run, source, file, attempt, and error identifiers. Waiting and recovered events are emitted only on source state transitions.

Fix round 1 makes retry deadlines source-scoped and exposes the earliest deadline as `nextRecoveryAt`. `dueRecoverySources(now:)` identifies each due source; Task 7 records results through `recordSourceFailure(_:now:)` and `recordSourceRecovered(_:)`. The engine now retains aggregate unresolved source issues across scans, so an unknown import, pending file retry, or paused/incomplete scan cannot be reported as recovered by unrelated traversal or file success. Metadata failures include their URL identity, and every Photos submission failure logs its file and attempt independently of source transition notifications.

Task 7 note: keep adapter poison/recreation recovery separate until its semantics are fully resolved. An explicitly surfaced safe restart fallback is acceptable; never recreate a Photos adapter blindly while an import result remains uncertain.

Fix round 2 clears a `file:<id>` source issue only after a durable terminal `recordSourceChange` or duplicate `markSkipped` transition. It preserves other unresolved file and scan issues for that source. The regression covers a failed retry which later becomes a duplicate skip, leaving no pending/importing record and no stale waiting state.

## Verification

Commands run from the task worktree:

```sh
xcodebuild build-for-testing -project PhotoSync.xcodeproj -scheme PhotoSync -destination 'platform=macOS' -derivedDataPath work/DerivedData
xcrun xctest work/DerivedData/Build/Products/Debug/PhotoSyncCoreTests.xctest
git diff --check
```

Output summary:

```text
** TEST BUILD SUCCEEDED **
Executed 80 tests, with 0 failures (0 unexpected)
```
