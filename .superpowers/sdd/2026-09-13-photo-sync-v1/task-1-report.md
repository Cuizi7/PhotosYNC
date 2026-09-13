# Task 1 Report: Testable Domain Model and Conservative Matching

## Scope completed

- Added the three-target macOS Xcode project: `PhotoSync` app, `PhotoSyncCore` framework linked with system SQLite3, and hostless `PhotoSyncCoreTests`.
- Set every target's deployment target to macOS 14.0.
- Added the empty SwiftUI app shell. It imports no Photos framework and performs no Photos access or writes.
- Added public, `Sendable`, concrete-initializable domain record types for framework boundaries.
- Added conservative duplicate matching: exact filename equality, known whole-second time conflict exclusion, fully-known normalized make/model conflict exclusion, and skip on every unresolved candidate with sorted keys.
- Added test support for Unix-second floor conversion and focused matching coverage.

## RED

Command:

```sh
xcodebuild test -project PhotoSync.xcodeproj -scheme PhotoSync -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath work/DerivedData -only-testing:PhotoSyncCoreTests/DuplicatePolicyTests
```

Observed expected pre-implementation compile failure:

```text
DuplicatePolicyTests.swift:9:6: error: cannot find type 'MediaMetadata' in scope
```

The first sandboxed test attempt also showed macOS test-runner access restriction `testmanagerd.control ... error 159 - Sandbox restriction`. I rebuilt outside the sandbox and used the hostless bundle directly for the executable test evidence.

## GREEN

Build command:

```sh
xcodebuild build-for-testing -project PhotoSync.xcodeproj -scheme PhotoSync -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath work/DerivedData
```

Output:

```text
** TEST BUILD SUCCEEDED **
```

Focused test command:

```sh
xcrun xctest work/DerivedData/Build/Products/Debug/PhotoSyncCoreTests.xctest
```

Output:

```text
DuplicatePolicyTests: Executed 10 tests, with 0 failures
```

Full available Core suite command:

```sh
xcrun xctest work/DerivedData/Build/Products/Debug/PhotoSyncCoreTests.xctest
```

Output:

```text
PhotoSyncCoreTests.xctest: Executed 11 tests, with 0 failures
```

Final application build command:

```sh
xcodebuild build -project PhotoSync.xcodeproj -scheme PhotoSync -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath work/DerivedData
```

Output:

```text
** BUILD SUCCEEDED **
```

## Files

- `PhotoSync.xcodeproj/project.pbxproj`
- `PhotoSync.xcodeproj/project.xcworkspace/contents.xcworkspacedata`
- `PhotoSync.xcodeproj/xcshareddata/xcschemes/PhotoSync.xcscheme`
- `Sources/PhotoSyncApp/PhotoSyncApp.swift`
- `Sources/PhotoSyncCore/Domain/MediaRecord.swift`
- `Sources/PhotoSyncCore/Matching/DuplicatePolicy.swift`
- `Tests/PhotoSyncCoreTests/DuplicatePolicyTests.swift`
- `Tests/PhotoSyncCoreTests/TestSupport.swift`
- `Tests/PhotoSyncCoreTests/TestSupportTests.swift`

## Self-review

- `git diff --check` passed.
- Matching intentionally ignores size, duration, dimensions, and any raw capture-time text for exclusion.
- Filename matching is case-sensitive and time matching only compares known Unix seconds.
- Make/model normalization only folds whitespace and case; missing either part retains the candidate.
- No source reads, PhotoKit import, Photos write, deletion, or iCloud configuration code exists in this task.

## Concerns

`xcodebuild test` completed the build but its test-runner handoff was unreliable in this environment: sandboxed attempts hit `testmanagerd` error 159, and an outside-sandbox attempt stalled after build. The same hostless XCTest bundle was built successfully and executed directly with `xcrun xctest`, passing all 11 tests. This is an environment runner limitation, not a Core test failure.

## Review repair: framework boundary and runtime linkage

The review correctly identified that a static Core library would leak SQLite linkage to final consumers and change the planned integration boundary. The Core product is now restored to `PhotoSyncCore.framework`.

- `SQLite3.tbd` remains linked by the framework itself.
- The app and hostless test bundle both link and embed `PhotoSyncCore.framework`.
- The framework install name is `@rpath/PhotoSyncCore.framework/...`; the app uses `@executable_path/../Frameworks` and the hostless test bundle uses `@loader_path/../Frameworks`.

Repair verification on September 13, 2026:

```sh
xcodebuild build-for-testing -project PhotoSync.xcodeproj -scheme PhotoSync -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath work/DerivedData
xcrun xctest work/DerivedData/Build/Products/Debug/PhotoSyncCoreTests.xctest
```

Output:

```text
** TEST BUILD SUCCEEDED **
PhotoSyncCoreTests.xctest: Executed 11 tests, with 0 failures
```

`otool -L` confirmed the test bundle resolves `@rpath/PhotoSyncCore.framework/Versions/A/PhotoSyncCore`, and `Contents/Frameworks/PhotoSyncCore.framework` is present. The final `xcodebuild build` also succeeded with the app framework embedded at `PhotoSync.app/Contents/Frameworks/PhotoSyncCore.framework`.

The test-only Unix-second floor helper remains intentionally narrow until source metadata extraction is introduced. At that point, its coverage must move to the production conversion path, including a negative pre-epoch fractional timestamp if supported by the source representation.
