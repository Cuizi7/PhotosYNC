# Task 4 Report: PhotoKit Import and Conservative Recovery

## Scope

- Added the `PhotosGateway` contract, recovery evidence/action mapping, and explicit PhotoKit error classes.
- Added `PhotoKitGateway`, which requests read-write access, verifies library availability and authorization before every query or write, and requires a complete candidate load for the current library generation before creating an asset.
- Candidate enumeration includes hidden and burst assets and emits candidates from public `PHAssetResource.originalFilename` values. It does not read Photos.sqlite, use private APIs, read device metadata through KVC, or download iCloud originals. Existing Photos metadata leaves unknown capture time/offset and device fields as nil.
- The only write path uses `PHPhotoLibrary.performChanges`, `PHAssetCreationRequest.forAsset()`, a photo/video resource, and `shouldMoveFile = false`. It creates no albums and contains no delete or edit request.
- Placeholder persistence is synchronous inside the change block through the gateway callback. A checkpoint error, missing placeholder, absent confirmation fetch, or lost/unknown result returns `resultUnknown` and blocks additional writes in that gateway process. A single missing reconciliation fetch remains `unknown`; it never proves non-commit.
- Added the app Photos usage description, contract/recovery unit tests, and `Design/Validation.md` with a test-account-only manual procedure. Real import acceptance is not executed.

## RED

Before the implementation, `xcodebuild build-for-testing` failed because `recoveryAction`, `ImportEvidence`, and `PhotoKitGatewayError` were not defined. The first compiler errors were:

```text
RecoveryTests.swift:6:24: error: cannot find 'recoveryAction' in scope
PhotoKitContractTests.swift:7:13: error: cannot find 'PhotoKitGatewayError' in scope
```

## GREEN

```sh
xcodebuild build-for-testing -project PhotoSync.xcodeproj -scheme PhotoSync \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath work/DerivedData-task4 CODE_SIGNING_ALLOWED=NO
xcrun xctest work/DerivedData-task4/Build/Products/Debug/PhotoSyncCoreTests.xctest
```

The build reported `** TEST BUILD SUCCEEDED **`. The direct XCTest bundle ran 44 tests with 0 failures, including the 3 recovery tests and 2 PhotoKit contract tests.

## Self-review

- `git diff --check` passed.
- `PhotoKitGateway.swift` uses only public Photos APIs and never calls a Photos resource manager, so it cannot trigger full original downloads.
- The gateway returns a target identifier only after the PhotoKit change callback succeeds and a fetch finds exactly that identifier. It does not treat a missing fetch as a negative proof.
- Tests do not instantiate the gateway or access a Photos library. There was no personal-library authorization, source-media mutation, or PhotoKit write during this task.

## Remaining Acceptance Gap

Actual Photos import validation is deliberately unexecuted. It requires a user-confirmed separate macOS account, a system test library with iCloud Photos disabled, and the procedure in `Design/Validation.md`. This gap blocks automatic import into a user's existing personal library, while later fake-gateway tasks may proceed.
