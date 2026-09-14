# PhotoKit Manual Validation

## Current Validation Status (2026-09-13)

| Specification acceptance case | Status | Evidence type and result |
| --- | --- | --- |
| 1. Conservative matching rules | Pass | Mock/unit: `DuplicatePolicyTests` covers filenames, second-level time conflicts, device conflicts, missing fields, time-zone uncertainty, and multiple candidates. |
| 2. Multi-source duplicate submission and retained successful history | Pass | Mock/unit: `EngineTests` and `StoreTests` cover de-duplication and history retention after the target disappears. |
| 3. Metadata failure versus missing metadata | Pass | Mock/unit: `SourceReaderTests` and `EngineTests` distinguish read failure from absent fields and rediscover later. |
| 4. Source stamp changes | Pass | Mock/unit: `EngineTests` and `StoreTests` record a conservative `sourceChanged` skip. |
| 5. Four-state recovery | Pass (mock) | Mock/unit: `RecoveryTests`, `PhotoKitContractTests`, and `EngineTests` cover definite failures, placeholder reconciliation, state-write failure, and unknown outcomes. Real PhotoKit fault injection is not run. |
| 6. Directory recovery, bounded slow I/O, and responsive status | Pass (mock) | Mock/unit: `SourceReaderTests`, `EngineTests`, `GlobalStatusTests`; a non-interruptible saturated worker pool remains a documented controlled-degradation case. |
| 7. Scheduling and login behavior | Pass (mock) | Mock/unit: `ScheduleTests` covers launch, 30-minute cadence, pause/resume, no overlap/backlog, and wake behavior. Login-item approval remains a manual macOS check. |
| 8. Native UI and menu-bar behavior | Qualitative GUI evidence | The inherited `--demo` screenshots cover dark unconfigured and light long-error layout. They do not exercise menu actions, folder selection, authorization, login-item registration, or a live scan. |
| 9. Permission/library/space/database failures | Pass (mock) | Mock/unit: `PhotoKitContractTests`, `RecoveryTests`, and `EngineTests` cover permission, unavailable/changed library, explicit failure, and storage failure states. Real disk-full and library-switch checks are not run. |
| 10. Source immutability, additive Photos behavior, and no media cache | Not run (real PhotoKit) | Requires the isolated account procedure below. Build inspection confirms no source-media cache directory is packaged; no personal library, test library, or source file was mutated during this task. |

The current local package has an ad-hoc signature produced by the local Xcode build. It is not Developer ID signed, notarized, stapled, or Gatekeeper-accepted. The host is macOS 26.6.2 with Xcode 26.6; the deployment target is now macOS 13.0. The real PhotoKit and macOS 13 and 14 host acceptance items remain open.

## Preconditions

1. Use a user-confirmed, separate macOS test account and that account's system Photos library.
2. Disable iCloud Photos for that test account. Do not change the user's default personal library or iCloud configuration.
3. Create a temporary source directory containing one self-made image and one self-made video. Make the directory and both files read-only before the import.
4. Record each source file's path, byte size, modification time, and a checksum for this manual test record only. The application must not calculate or persist this checksum.

## Import Confirmation

1. Start the test build with the test account's system library selected and grant the app read-write Photos access when macOS asks.
2. Run a single import for the image, then a single import for the video. Record the source path, placeholder identifier, PhotoKit completion result, and post-completion fetch result for each attempt.
3. Confirm that each returned identifier fetches exactly one asset, and that the asset's original resource filename matches the source filename.
4. Confirm the source files remain present, byte-for-byte unchanged, and still read-only. Confirm no existing Photos asset, album, or source file was edited, moved, or deleted.
5. Verify that candidate enumeration includes hidden assets and burst assets in this test library. Treat any authorization, availability, or enumeration error as a blocked import; do not accept an empty candidate array as success.

## Recovery Fault Points

For each case, stop the test process only in the separate test account, restart it, and record the recovery result before allowing another import.

1. Stop before `performChanges` begins. Recovery may classify the local failure as definitely not committed and retry.
2. Stop after the placeholder checkpoint returns but before the PhotoKit completion callback is observed. Recovery must fetch the placeholder: a matching asset becomes imported; no match remains unknown and stays importing.
3. Simulate a checkpoint write failure after the placeholder is created. The attempt must remain unknown and block further additions until reconciliation; do not assume PhotoKit rolled back.
4. Stop after the PhotoKit completion callback reports success but before success state is stored. On restart, fetch the recorded placeholder and mark imported only when it is found.
5. Simulate a system completion failure that explicitly reports the atomic change was not committed. Record definite failure and permit retry. Permission denial, unavailable-library errors, crashes, and a single missing placeholder fetch remain unknown or blocked, not automatic retries.

## Acceptance Boundary

Real PhotoKit import acceptance is **not executed** by unit tests or this task. It requires the explicit test-account procedure above. The application is capable of submitting additions after the user explicitly authorizes the System Photo Library; this task did not exercise that write path. Fake gateway tests do not prove real PhotoKit acceptance.
