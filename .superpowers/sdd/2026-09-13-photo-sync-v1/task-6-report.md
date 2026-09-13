# Task 6 Report: scheduling, recovery, and logging events

## Status

Implemented and committed `feat: schedule scans and source recovery`.

`ScanSchedule` is pure, clock-injected scheduling state. It provides fixed 30-minute timer admission, manual/startup/resume/wake admission, pause, no-overlap behavior, missed-timer coalescing, minute-gated recovery checks, and wall-clock rollback reset. The engine owns no scheduler lifecycle; the app can keep one `ScanSchedule` instance and call the engine only after an admitted request.

Source retry delays are 5, 15, 30, and then 60 seconds. A successful import resets the persisted retry count. Engine lifecycle and recovery logs carry phase/result plus applicable run, source, file, attempt, and error identifiers. Waiting and recovered events are emitted only on source state transitions.

Task 7 note: keep adapter poison/recreation recovery separate until its semantics are fully resolved. An explicitly surfaced safe restart fallback is acceptable; never recreate a Photos adapter blindly while an import result remains uncertain.

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
Executed 75 tests, with 0 failures (0 unexpected)
```
