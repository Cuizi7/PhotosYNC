# beta5 runtime progress implementation plan

> **For agentic workers:** Use superpowers:executing-plans; the primary agent implements serially, followed by one integrated deep review and focused tester verification.

**Goal:** Keep unfinished task rows visible during concurrent refreshes and advance Live Photo work without waiting for UI polling; release 0.3.0 beta5 locally.

**Architecture:** Runtime-owned analysis state survives source-engine refreshes. Only a fully assembled Live Photo publication replaces the last committed publication. One owned worker continues after real progress, yielding between items; UI publication remains throttled and waiting/no-progress exits the worker.

**Tech Stack:** Swift actors, XCTest, SQLite, existing PhotoKit gateway and release tooling.

**Spec:** User-approved two-fix scope in this conversation; existing status contract `docs/specs/2026-09-18-runtime-state-and-recovery.md` and task presentation design `docs/superpowers/specs/2026-10-21-task-progress-and-scheduling-repair-design.md` where applicable. Evidence: ignored `work/beta4-monitor-2026-10-23/findings.md` and isolated double-gate RED in `work/beta4-task-visibility-probe/red-test.log`.

## Constraints

- Retain source read-only, physical resource limits, exact pairing, unknown-write protection, schema v11, macOS 13, and one actual Photos submission.
- No changes to the 512 MiB limit, 10-second filter, or unresolved-target admission. No production app installation/restart or production-data mutation.
- Preserve six statuses, task copy, one row per task, equal-width non-gradient bars; this is state correctness rather than a visual redesign.
- Release beta5/build 22, local squash main and tag; no remote publication. Canonical package uses full scale profile because worker throughput/resource behavior changes.

## Review focus

- An older publisher returns while a newer publisher is suspended: last complete state remains visible.
- Source scan completion during publication cannot clear runtime-owned task fields.
- Pause/authorization loss/draining during a read prevents new work; completed PhotoKit writes retain existing recovery semantics.
- Deferral, unknown outcomes, future retries and no-progress discovery cannot form a tight loop.
- Repeated ticks/source wakes cannot create multiple workers; healthy backlog continues without additional ticks.

### Task 1: Preserve coherent task snapshots

**Files:** `Sources/PhotoSyncApp/SyncRuntime.swift`, `Tests/PhotoSyncCoreTests/AdvancedRuntimeTests.swift`.
**Interfaces:** `current() -> RuntimeState`, `publishLivePhotoProgress()`, `finishedRound(ids:snapshot:)` retain signatures.

- [ ] Promote the already observed failing double-gate test; retain the existing newer-completes-first test.
- [ ] Preserve runtime-owned fields when accepting engine snapshots. Distinguish last started and last committed publication generations, so an older complete publication can serve the UI while a newer one is still awaiting data.
- [ ] Verify both publication orders and task visibility after source rounds. Log task state transitions with aggregate counts only.

### Task 2: Continue bounded serial work independently of UI polling

**Files:** same runtime/test files; existing coordinator contracts remain unchanged unless necessary to distinguish progress.
**Interfaces:** `processNextInventoryItem(now:) -> Bool`, `advanceNext(now:refreshDiscovery:) -> Bool` report durable progress; deferred/no-progress returns to normal wake scheduling.

- [ ] Write and observe RED for multiple queued items completing after one wake with a fixed clock; cover held resource, pause, admission deferral and repeated concurrent ticks.
- [ ] Continue the single worker only after inventory or completion progress. Recheck authorization/admission/eligibility between items and yield fairly; retain retry deadlines and source-ready wake signals.
- [ ] Publish progress on the existing profile cadence and at exit. Add aggregate worker item/elapsed/exit-reason diagnostics without per-file identifiers or per-item info spam.
- [ ] Run affected runtime/coordinator/presentation/view checks; adjust tests that asserted old one-item scheduling only when their business expectations are unchanged.

### Task 3: Integrate and release

**Files:** version plist, release script identity, release tool fixtures, README, CHANGELOG, release/validation notes.

- [ ] Update all current version identities to 0.3.0 beta5/build 22; leave historical release notes intact.
- [ ] Independent tester checks integrated behavior and UI regression; final deep reviewer covers complete diff and concurrency boundaries. Resolve material findings and rerun affected checks.
- [ ] Commit clean source, squash main, verify identical source tree, run `env -u RQDATAC2_CONF scripts/package-release.sh --scale-profile full` from the exact main commit.
- [ ] Verify canonical validation, source/provenance hashes, architecture/signature/DMG checks and local tag. Report real-system verification limits separately.
