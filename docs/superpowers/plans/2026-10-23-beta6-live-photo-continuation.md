# beta6 Live Photo continuation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan serially. Steps use checkbox syntax for tracking. The user already authorized writing this plan and proceeding to verification, local squash merge and release.

**Goal:** Avoid discarded Live Photo work and misleading transient states, prioritize pairing blockers, and release a verified local beta6.

**Architecture:** One serial worker retains one bounded asset continuation across classification deferrals. The gateway retains one completed raw lease while classification is pending; every reused result retains its existing validity checks. Store selection adds native preference with coordinator-owned fairness. Progress telemetry remains independent of correctness.

**Tech Stack:** Swift actors/locks, public PhotoKit, SQLite, XCTest, existing native UI and canonical packaging.

**Spec:** `docs/superpowers/specs/2026-10-23-beta6-live-photo-continuation.md`; current native Live Photo and runtime contracts remain authoritative outside this repair.

## Global Constraints

- macOS 13 minimum; no new dependency, schema migration or Photos mutation path.
- Sources strictly read-only; exact pairing, single Photos mutation and unknown-result barriers unchanged.
- Retention: one raw lease and one partial asset; 30 monotonic seconds; aggregate 512 MiB plus existing free-space reserve. Pause/cancel and real invalidation release retained work.
- Fairness: at most eight successfully attempted native items before one ordinary preference; no early retry. One worker and physical ownership remain intact.
- Six UI states; one caption per task; equal-width solid tracks; no download subtask or settings.
- Unknown history is not proof of unchanged content. Production parallelism requires representative evidence, not a synthetic-only win.
- Preserve the running beta and production files. New version 0.3.0 beta6/build 23; local squash/tag/package only.

## Review Focus

- Notification arrives between final validity validation and SQLite commit: no stale pairing identity accepted.
- An expired or cancelled retained read outlives its logical caller: actual lease and physical budget have exactly one owner.
- Continuous native arrivals or repeatedly deferred partial work: ordinary due assets make bounded progress without early retry or busy looping.
- A partial failure coexists with admission busy: task remains visible/running, but real drain/retry and pause still override.
- Persistent-history ambiguity and same-revision edits: no false reuse or checkpoint jump can bypass revalidation.

### Task 1: Retain completed reads and partial inventory work safely

**Files:** `Sources/PhotoSyncCore/Photos/PhotoKitGateway.swift`, `Sources/PhotoSyncCore/Photos/LivePhotoPhotosGateway.swift`, `Sources/PhotoSyncCore/Sync/LivePhotoInventoryCoordinator.swift`, corresponding `LivePhotoKitContractTests.swift`, `LivePhotoInventoryTests.swift`, `LivePhotoResourceTests.swift`; add a small retained-resource helper and Xcode membership if needed.

**Interfaces:** Preserve `readLivePhotoResource(_:purpose:budget:)` and `processNextInventoryItem(now:)`. Add `discardPendingLivePhotoReads() async` to the gateway contract with a no-op default for gateways without retention. Add injected monotonic time for deterministic expiry tests. Only inventory reads are retained; completion writes/verification keep their existing contract.

- [x] Add RED tests: timeout then neutral classification reuses bytes with one physical request; changed resource/context or unknown coverage cannot reuse; expiry/pause/cancel releases bytes; notification after parsing and at commit resumes with one metadata inspection; two-resource assets retain the first observation when the second defers.
- [x] Build `work/Beta6-Validation` and run affected Core classes using `xcrun xctest -XCTest PhotoSyncCoreTests.LivePhotoKitContractTests,PhotoSyncCoreTests.LivePhotoInventoryTests,PhotoSyncCoreTests.LivePhotoResourceTests <bundle>`; expected: new behavioral assertions fail, not compile/setup errors. Keep RED logs under `work/beta6/`.
- [x] Implement the single-slot raw lease and partial observation continuation, absolute expiry and invalidation/discard rules. Preserve atomic observation validity checks and physical cancellation ownership. Add anonymous bounded retention diagnostics.
- [x] Run the same checks; expected: all affected tests pass, including stale/unknown rejection and budget cleanup. Commit this outcome and ledger evidence.

### Task 2: Prioritize native candidates and represent normal waits accurately

**Files:** `SyncStore.swift`, `LivePhotoInventoryCoordinator.swift`, `LivePhotoCoordinator.swift`, `SyncRuntime.swift` only if needed for accurate deferral classification; existing store, inventory, coordinator, runtime and presentation tests.

**Interfaces:** Extend `nextLivePhotoInventoryItem(context:now:preferNative:)` with explicit preference, preserving eligible statuses/deadlines. Coordinator tracks at most eight native completions before ordinary preference. `.busy` remains a physical scheduling barrier but means queued activity when eligible work exists.

- [x] Add RED tests for native preference over ordinary queued work, overdue native retries versus future deadlines, ordinary fairness after eight native items, retained-item resume, and restart preserving completed records.
- [x] Add RED tests for pending/busy plus held attention showing queued/running, and real drain/stall/future retry/unknown submission retaining waiting or blocked behavior. Cover completion-only work and menu/settings/details with one/two tasks.
- [x] Run affected classes; expected: new ordering and busy-presentation assertions fail.
- [x] Implement selection and activity changes without altering matching or global native-target admission. Keep the approved compact UI structure; fix state causes rather than add display delays.
- [x] Run affected classes and native `AppViewTests`; expected: all pass. Save and inspect rendered normal-busy, real-wait, pause, one/two-task and hover/details fixtures. Commit and ledger.

### Task 3: Instrument system progress and validate conditional optimizations

**Files:** `LivePhotoPhotosGateway.swift`, `PhotoKitLivePhotoReader.swift`, `IndexDiagnostics.swift`, requester fakes and `LivePhotoResourceTests.swift`; validation report under `docs/validation/` and isolated experiment under ignored `work/beta6/`.

**Interfaces:** Add a `progress: @escaping @Sendable (Double) -> Void` callback to internal `LivePhotoResourceRequesting.request`. It feeds diagnostics only; terminal completion remains the only success signal. Preserve request/byte limits and aggregate logging caps.

- [x] Add RED tests for queue versus first-data timing, bounded progress aggregation, malformed/nonfinite progress ignored, progress without completion not succeeding, private IDs absent, and retained reuse not counted as another physical transfer.
- [x] Implement public PhotoKit progress hookup and aggregate timing fields. Run affected resource/diagnostic tests; expected: pass with no changes to terminal, cancellation or budget behavior.
- [x] Record SDK/API proof for history/live mismatch and run existing same-revision edit/history tests. Expected: ambiguous history still requeues; no unsafe suppression. Copy a concise conclusion to tracked validation docs (no private data).
- [x] Run controlled identical-workload one/two-lane read experiment, recording elapsed time, actual physical occupancy, retained bytes and cancellation/drain. Explicitly distinguish synthetic/local/cached input from real cloud waiting. Expected: bounded ownership and honest result; production stays serial unless representative evidence supports a safe improvement.
- [x] Commit diagnostics and evidence; do not include private fixtures, runtime logs, synthetic experiment output or speculative parallel product code.

### Task 4: Integrated validation, review and beta6 release

**Files:** version plist/Xcode configurations, `scripts/package-release.sh`, matching tool fixtures, README, CHANGELOG, release notes and validation report.

**Interfaces:** Existing validation/package entry points, `--scale-profile full`, exact main source/archive/provenance identity.

- [x] Update current identities to beta6/build 23 and document shipped scope and conditional exclusions; retain beta5 history.
- [x] Independent tester verifies the integrated focused checks and native visuals; final deep reviewer checks the complete branch and the five review-focus boundaries. Resolve material findings with focused RED/GREEN evidence.
- [x] Run integrated verification before merge; use the repository's full-profile canonical development validation when required, and do not call a build or filtered tests full acceptance. Expected: all required functional/tool/resource/scale/continuation checks pass or stop before delivery.
- [ ] Commit clean source, squash into local main, verify source-tree equivalence. Run `env -u RQDATAC2_CONF scripts/package-release.sh --scale-profile full` on exact main; expected: canonical archive validation, Universal app/Core, signatures, DMG and checksums all succeed.
- [ ] Independently verify provenance/source binding and packaged version, create local `v0.3.0-beta6` tag, and report artifact path, test evidence and real-system limitations. No install, restart, remote push or publication.
