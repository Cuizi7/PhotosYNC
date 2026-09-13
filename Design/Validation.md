# PhotoKit Manual Validation

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

Real PhotoKit import acceptance is **not executed** by unit tests or this task. It requires the explicit test-account procedure above. Until it is executed and recorded, automatic import into a user's existing personal Photos library remains disabled. Fake gateway tests may continue for later tasks.
