# Task 2 Report

## Scope

Implemented SQLite-backed sync state, source registration, JSONL run logging, test support, and Xcode project membership in the assigned worktree. No Photos framework APIs or Photos library writes were used.

## Red

`xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync -configuration Debug -derivedDataPath work/DerivedData build-for-testing`

Initial result: exit 65. The target reported missing `SyncStore.swift`, `SourceRegistry.swift`, and `RunLogger.swift` build inputs before implementation.

## Green

`xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync -configuration Debug -derivedDataPath work/DerivedData build-for-testing && xcrun xctest work/DerivedData/Build/Products/Debug/PhotoSyncCoreTests.xctest`

Result: exit 0; 20 tests, 0 failures. The direct XCTest executable was used because the provided instruction states the `xcodebuild test` runner stalls.

## Evidence

- `testFutureSchemaIsRejectedWithoutReplacingDatabase` creates a database with `PRAGMA user_version = 2`, asserts `SyncStore(url:)` throws, then queries the same handle and asserts version remains `2`.
- `testEvidenceConstraintFailureRollsBackStateChange` submits duplicate evidence keys, asserts `markSkipped` throws on the unique constraint, then asserts the file remains `pending`.
- `testReopenPreservesSuccessHistory` and `testSourceChangeKeepsImportedHistory` verify retained success history across source changes and reopening.
- Tests create UUID-named directories under the system temporary directory and clean only those directories in teardown.

## Concerns

- `Schema.sql` is retained as the schema reference and tracked in the Xcode group; the executable migration uses the same v1 statements inline because the framework has no resource-bundle loading path yet. Future migration work should keep the two representations synchronized or move schema loading behind a tested resource path.

## Review Round 1

Addressed the three required blockers from `task-2-review.md`.

- `recordRetry` now keeps uncertain matching attempts in `importing` and retains the attempt and checkpoint identifier. It permits the transition to `pending` only when `definitelyNotCommitted` is true and the attempt matches; nil-attempt retry is restricted to `pending`.
- `save(_:decision:candidates:)` accepts real `MatchCandidate` snapshots. A skip decision requires the exact complete candidate-key set and no longer synthesizes candidate metadata from the incoming source file.
- Source registration verifies an existing directory and rejects configured aliases and symbolic links. This configuration validation does not alter the runtime non-recursive traversal rule.

Validation command:

`xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync -configuration Debug -derivedDataPath work/DerivedData build-for-testing && xcrun xctest work/DerivedData/Build/Products/Debug/PhotoSyncCoreTests.xctest`

Result: exit 0; `StoreTests` executed 14 tests with 0 failures, and the full suite executed 25 tests with 0 failures.

New evidence:

- `testUncertainRetryKeepsAttemptAndPlaceholderImporting` proves an uncertain retry leaves the file importing with its exact attempt and placeholder.
- `testRetryRejectsNilOrOldAttemptAgainstImportingAndImportedRecords` and `testOldRetryCannotResetNewAttempt` prove stale and nil callbacks cannot reopen importing or imported records.
- `testSaveSkipPersistsActualCandidateSnapshots` reads `match_evidence.candidate_json` and verifies the exact distinct candidate snapshot is stored.
- `testSourceRegistrationRejectsFilesAndLinks` verifies regular files and symbolic-link sources are rejected.

No Photos framework calls or Photos library writes are present in this change or its tests.
