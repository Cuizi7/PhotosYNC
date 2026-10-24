# Beta8 Task State and Hover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking. Root implements serially; one final deep review and an independent validation audit cover the integrated result.

**Goal:** Treat fixed-limit Live Photo identification as normal skips, avoid unchanged periodic catalog passes, and deliver the approved concise task hover in beta8.

**Architecture:** Keep resource-limit evidence in existing observations and add a terminal inventory disposition with separate skipped/processed counts. Gate only periodic reconciliation through a read-only active-observer proof before withdrawing readiness. Derive a single title/body task explanation from the existing snapshot; preserve native hover lifecycle.

**Tech Stack:** Swift/SwiftUI/AppKit, PhotoKit adapters, SQLite, XCTest, existing release scripts; macOS 13+.

**Spec:** `docs/superpowers/specs/2026-10-24-beta8-task-state-hover-design.md`

## Global Constraints

- User authorized planning, serial implementation, local squash integration and a new beta; do not pause for duplicate approval.
- Source files stay read-only. No production library/database/settings access is needed for validation.
- Unknown PhotoKit submission and verified-content retirement gates remain intact; no resource-limit observation is proof of absent pairing identity.
- Skip fixed-limit **inventory identification**; preserve known-pair creation/verification and source reservation contracts. Visual decode memory limits remain actionable through Settings.
- Every task tooltip has a title and exactly one body paragraph; no third informational line, no scrolling, no gradient or mismatched progress widths.
- Use full scale profile because index/SQLite behavior changes. Final canonical validation runs once in the final committed release archive; focused checks precede it.

## Review Focus

- Legacy mixed observations: convert only exact-current fixed-cap holds; retain generic unreadable results, successful history, missing descriptors and unknown mutations (Task 1 tests).
- Terminal skips across restart/manual scan: no retry or full enumeration; a new revision can requeue (Task 1 tests).
- Native unreadable candidates must not become evidence that a complete pair is absent (Task 1 conservative gate regression).
- A change, pause, authorization gap or overlapping reconcile during continuity proof must prevent stale fast-path decisions (Task 2 controlled-gate tests).
- Hover priority in mixed tasks and normal skipped+offline states must not hide real issues or retain fake pending work (Task 3 presentation/render tests).

## Task 1 — Persist normal Live Photo identification skips

**Files:** `Sources/PhotoSyncCore/Domain/LivePhotoTypes.swift`, `Sources/PhotoSyncCore/Storage/SyncStore.swift`, `Sources/PhotoSyncCore/Sync/LivePhotoInventoryCoordinator.swift`, `Sources/PhotoSyncApp/SyncRuntime.swift`; tests `LivePhotoInventoryTests.swift`, `LivePhotoStoreTests.swift`, schema migration fixtures as affected.

**Interfaces:** `LivePhotoInventorySummary.skipped` (default 0), `processed = identified + skipped`; persisted inventory status `resourceLimitSkipped`. Keep `LivePhotoObservation.inspection` and `resourceLimitBytes` as unverified cap evidence, and existing queue/revision APIs.

- [x] Write RED tests: fixed-cap result has identified=0/skipped=1/unresolved=0/attention=0; generic failure is still unresolved; manual retry returns no work; reopened store retains skip; changed revision queues again.
- [x] Write RED migration cases from v11: exact-current cap-only holds become terminal; mixed non-cap failures and missing/stale evidence do not; completion marker and success/unknown operation evidence survive. Retain native candidate safety gate.
- [x] Implement schema v12 migration once, transactionally. Fresh v12 and all supported older upgrades use the same classification; reject unknown newer schemas. Update schema expectations/docs rather than pretending older binaries can understand a new disposition.
- [x] Classify cap-only unresolved observation sets as terminal on new writes. Count checked and skipped separately and log aggregate skip/processed counts without filenames or library IDs. Queue/manual retry continue to select only queued/unresolved.
- [x] Build and run affected inventory/store/identity/resource/coordinator tests; retain RED/GREEN evidence under `work/beta8-task-state-hover/`, then commit.

## Task 2 — Avoid unchanged periodic full catalog work

**Files:** `Sources/PhotoSyncCore/Photos/PhotosIndexGateway.swift`, `PhotoKitGateway.swift`, `Sources/PhotoSyncCore/Sync/PhotosIndexCoordinator.swift`, `Sources/PhotoSyncApp/SyncRuntime.swift`; tests `PhotosIndexCoordinatorTests.swift`, `PhotoKitGatewayTests.swift` or existing continuity test file, `AdvancedRuntimeTests.swift`.

**Interfaces:** add `PhotosIndexGateway.hasContinuousObservation(context:expectedGeneration:checkpoint:) async throws -> Bool` with conservative default false; implement in PhotoKit using current active observer state, not persistent recovery coverage or mere observerFence presence. Add `PhotosIndexCoordinator.reconcileIfNeeded()` for periodic work; keep `reconcile()` as explicit full path.

- [x] RED: after a healthy published index, an unchanged periodic call performs zero catalog pages, writes no new inventory generation, retains ready token/known total, and does not expose working activity.
- [x] RED: false continuity, changed generation/context, pending changes, initial startup or absent publication takes full path. Gate proof with a controlled continuation and inject pause/change to reject stale admission.
- [x] Implement proof before setting reconciling/clearing acknowledgements; recheck actor flags after awaits. Default/fallback behavior stays conservative; do not use dates as content proof.
- [x] Runtime passes periodic versus forced/change reasons explicitly; log trigger reason and unchanged/full fallback result. Source cadence remains 1800 seconds; no new timer or busy loop.
- [x] Run affected coordinator/gateway/runtime/schedule tests, commit, and record exact evidence.

## Task 3 — Implement approved task explanations

**Files:** `Sources/PhotoSyncApp/SyncStatusPresentation.swift`, `SyncProgressView.swift`, related existing authorization/source single-summary entry only where needed; tests `SyncStatusPresentationTests.swift`, `AppViewTests.swift`, `DemoFixtures.swift` if render scenarios need extension.

**Interfaces:** retain stable task IDs and hover anchor lifecycle. Replace task detail sections with explicit single explanation title/body. Use inventory processed count for progress; skip-only completion creates no task row or attention note.

- [x] RED presentation cases: all task variants map to the spec's exact title/body; normal skipped inventory exits; skipped+offline still waits for source; unknown writes never show a retry instruction; memory holds remain actionable.
- [x] Implement single native title/body layout without a ScrollView. Keep global sync details and actual diagnostic data separate from short task help; do not add new settings.
- [x] Run affected presentation/view tests; render actual SwiftUI views with fake state for known/unknown single/dual tasks, waiting, paused/in-flight, memory, completed skip, and skip+offline in both appearances. Verify one paragraph/no clipping/equal solid tracks; do not claim browser prototype equals native verification.
- [x] Commit after focused GREEN and save visual evidence, then mark all implementation tasks complete.

## Task 4 — Integrated review, local squash and beta8

**Files:** release configuration, `README.md`, `CHANGELOG.md`, `docs/release/0.3.0-beta8.md`, validation report and this plan's completion records.

- [x] Bump 0.3.0 beta8/build25; document schema12, skip semantics, periodic fast path, hover and remaining system-validation boundaries.
- [x] Run one final `deep_reviewer` on the integrated diff and plan focus. Address material findings with focused RED/GREEN; re-review changed safety boundaries if necessary per AGENTS.
- [x] Use `tester` for integrated focused verification/native evidence audit. Verify the primary checkout and preserve pre-existing untracked workspace metadata before authorized local squash to main.
- [ ] On the exact committed main tree, run `scripts/package-release.sh --scale-profile full`, which runs full canonical XCTest/Tools/four scales/two continuation regressions and Universal release/artifact gates. Never reuse beta7 provenance or overwrite a release directory.
- [ ] Independently verify actual main/tag, provenance, tests, architecture, signatures, DMG and checksums; deliver artifact link and limitations. Do not install/restart production, push or publish remotely.

## Evidence ledger

Implementation evidence and rulings: `work/beta8-task-state-hover/ledger.md`. Preserve all logs and failure evidence per repository validation policy.

Final review closed R1/R2 after focused repair verification; tester audited the refreshed 234-image matrix and source hashes. The frozen archive necessarily records release steps before execution; actual completion is recorded by the package provenance/validation and the final work ledger rather than rewriting an already-built source snapshot.
