# Source Deletion and Video Read Failure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Normal source deletion removes safe pending work and its false retry, while an unparseable MPG remains an actionable file-level failure with diagnostic cause.

**Architecture:** Reconcile a snapshot of pending paths only after complete directory traversal. Use one guarded SQLite transaction to remove a confirmed absent pending row and reopen duplicate skips that depended on it. Preserve the existing AVFoundation-first media path, adding bounded diagnostic error context without attempting a Photos write or conversion.

**Tech Stack:** Swift 6.3, macOS 13+, AVFoundation, PhotoKit gateway, SQLite, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-23-source-deletion-and-video-read-failure-design.md`

## Global Constraints

- Keep source media strictly read-only and Photos writes additive with original URL and `shouldMoveFile = false`.
- Keep the four file states and schema v3; never remove imported history or an uncertain `importing` record.
- Do not use production source paths, database snapshots, or Photos in automated tests.
- Do not add a runtime ffmpeg/ffprobe dependency, transcode, stage originals, or add per-file UI listing.
- Record the requested per-file UI inspection work as a TODO only.

## Review Focus

- Root unavailable or directory traversal deferred: pending records remain and source recovery continues.
- A pending row changed to `importing` during reconciliation: it survives, including any late successful callback.
- An entry whose attributes fail before its directory type is known: its descendants are not treated as deleted.
- Drain holding a row that another scan retires: immutable order cursor continues and stale transitions do not stop storage.
- A duplicate skip depending on a deleted pending candidate: it is reconsidered with current Photos/local candidates before import; concurrent new skip commits also revalidate local evidence.
- A deleted file reappearing at the same path: it is discovered as new work; imported history still prevents re-import.
- A video media read error beside a healthy file: only that file fails, with no PhotoKit submission for it.

---

### Task 1: Transactional pending-deletion reconciliation

**Files:** `Sources/PhotoSyncCore/Storage/SyncStore.swift`, `Tests/PhotoSyncCoreTests/StoreTests.swift`.

**Interfaces:** Add `pendingPaths(sourceID:) -> [String: UUID]` and `removeConfirmedAbsentPending(fileID:) -> Bool`. Make `nextPendingFile` use `afterOrder: Int64?` and return each row's `createdOrder`, so deletion cannot invalidate a live cursor. The latter runs one transaction, guards `state = 'pending'` plus `submitted_at IS NULL OR definitely_not_committed = 1`, reopens `suspectedDuplicate` rows whose `match_evidence.candidate_key` is `file:<id>`, clears their stale evidence, removes the deleted row's evidence, and deletes that row. A stale/concurrent state returns `false`.

- [ ] Write StoreTests for never-submitted pending deletion, definite failure deletion, importing/uncertain preservation, imported preservation, dependent duplicate reopening, and transaction rollback on injected SQL failure. Assert actual DB states and evidence, not SQL text.
- [ ] Run the focused StoreTests and record the expected RED assertions before editing the store.
- [ ] Implement the two store methods using the existing serial queue and `transaction` helper. Do not change schema or a source file.
- [ ] Re-run focused StoreTests to GREEN; check foreign keys and that reopened rows are pending with cleared retry/skip fields.

### Task 2: Complete-traversal source deletion and safe recovery

**Files:** `Sources/PhotoSyncCore/Sync/SyncEngine.swift`, `Tests/PhotoSyncCoreTests/EngineTests.swift`, `Tests/PhotoSyncCoreTests/GlobalStatusTests.swift` if runtime admission needs coverage.

**Interfaces:** At the start of each source scan, obtain `pendingPaths`. Remove each reported relative path from this set before classification. Only after `directories` is empty and directory traversal was complete, call `removeConfirmedAbsentPending` for the remaining IDs. On a true removal, resolve that file's submission and scan issues without a recovery notification, and log a normal `source-file/deleted` event. Treat an entry with unknown type after attribute failure as incomplete traversal; drain treats retired pending rows as superseded before Photos admission. Do not add a scan failure or a notification. The existing drain then sees no due row.

- [ ] Write EngineTests using temporary UUID sources and fake Photos for: missing pending JPG becomes absent from store and retry query; incomplete/deferred traversal preserves it; a separate bad media file does not block deletion reconciliation; same-path reappearance is rediscovered; a gated pending-to-importing transition preserves late success; duplicate dependents are reconsidered. Verify no Photos request for the missing path.
- [ ] Run focused EngineTests and record expected RED failures.
- [ ] Implement the traversal set and guarded reconciliation. Preserve existing per-file failure and source-availability handling. Keep cancellation checks after each await.
- [ ] Re-run focused EngineTests to GREEN. Confirm `scan_run` records zero failures for deletion alone and only the media failure for the mixed case.

### Task 3: Explicit video read diagnostics and deferred UI TODO

**Files:** `Sources/PhotoSyncCore/Sources/MetadataReader.swift`, `Sources/PhotoSyncApp/StatusMenu.swift`, `Tests/PhotoSyncCoreTests/SourceReaderTests.swift`, `Tests/PhotoSyncCoreTests/EngineTests.swift`.

**Interfaces:** Retain the `AVURLAsset` metadata path. Wrap a failed required video property load with a concise error description containing the outer and nested `NSError` domain/code chain, preserving the original error as underlying evidence. Keep `SourceIssue` kind `.file`; no Photos submission or skip record follows an unreadable video. Add a TODO beside the existing bounded menu count for a future per-file inspection surface, without changing rendered UI.

- [ ] Write tests for a malformed self-made video fixture and a synthetic nested AVFoundation `NSError`; assert file-level failure, a useful diagnostic code chain in the journal, and continued import of a healthy sibling. Do not rely on the production MPG or require ffmpeg at test runtime.
- [ ] Run focused tests and record expected RED results.
- [ ] Implement the narrow diagnostic wrapper and TODO comment. Do not change classification or duplicate policy.
- [ ] Re-run focused tests to GREEN. Verify that UI headline still uses plain-language summary and raw diagnostics stay in logs/tooltip.

### Task 4: Integrated verification and review

**Files:** No additional production scope unless a test or review finding directly blocks the agreed behavior.

- [ ] Run `python3 scripts/validate.py --output-dir "$PWD/work/validation-source-deletion-mpg-final" --derived-data "$PWD/work/validation-source-deletion-mpg-final-derived"` on the final snapshot. Inspect exit code, `validation.json`, XCTest count/failures, tool tests, continuation race, and source manifest.
- [ ] Obtain independent deep review of the final diff for transaction safety, duplicate consequences, actor interleavings, and media error handling. Resolve findings within scope and rerun the complete gate after any behavior/test change.
- [ ] Check `git diff --check`, review all changed paths against the spec, and commit the validated branch. Report commit, build, automatic tests, GUI, real Photos, platform compatibility, and signing/package status separately.

