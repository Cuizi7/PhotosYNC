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
