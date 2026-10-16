# PhotosYNC 0.2.3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox syntax for tracking.

**Goal:** Deliver bounded causal logs, correct retry timing and fair reader backpressure in 0.2.3.
**Architecture:** Shared bounded anonymous diagnostic context; coordinator-owned finite work slices; level-triggered reader/budget admission on existing runtime ticks. Existing persistence and invalidation decisions remain authoritative.
**Tech Stack:** Swift actors, PhotoKit adapters, SQLite, XCTest, existing Python release validation.
**Spec:** docs/superpowers/specs/2026-10-16-index-recovery-023.md

## Global Constraints
- Schema v8; no persistent queue/telemetry database, history/coverage policy change or helper process.
- No production App, DB, Photos, source or settings access; fake/self-made/UUID temp tests only.
- macOS >=13; Universal app/Core; stable 0.2.3 build 11; existing model and 0.98 threshold unchanged.
- Preserve physical ownership until terminal plus real cleanup/consumer lease release; no replacement reader bypass.
- Keep existing artifacts, archives and worktrees. No integration before independent acceptance clearance.

## Review Focus
- Token identity and live/history correspondence are unknown; diagnostics must not invent proof (Task 1).
- Duplicate terminal and active-empty/budget-held cannot open premature admission (Task 2).
- Self-reselecting failed rows and small lexical IDs cannot starve new/due work (Task 2).
- Pause/library change during async admission cannot start stale work (Task 2).
- State/transition logging must remain useful without per-event neutral log floods (Task 1).

### Task 1: Bounded causal diagnostics, behavior unchanged
**Files:** Create Sources/PhotoSyncCore/Logging/IndexDiagnostics.swift if needed; modify PhotoKitGateway.swift, PhotosRepresentationReader.swift, PhotosIndexCoordinator.swift, SyncStore.swift, ImageWorkBudget.swift only for diagnostics; wire shared context in SyncRuntime.swift; Xcode membership; matching focused tests.
**Interfaces:** Optional shared `IndexDiagnostics` context with existing diagnostics closures preserved; anonymous stable run-local handles and at most 8 sticky sample assets; aggregate/nonthrowing bounded logging. Exact initializer spelling may follow local patterns and must be recorded for Task 2.
- [ ] Add failing tests for history/live/invalidation/task lifecycle linkage across two reconciliations, raw field absence and bounded volume.
- [ ] Run those tests and retain RED evidence; add the small shared context and call-site facts without changing decisions.
- [ ] Run focused GREEN and existing history/same-revision regressions, self-review, commit and report interfaces/commands/results.
- [ ] One task reviewer checks spec and quality; resolve findings without expanding scope.

### Task 2: Timing, fair finite slices and reader backpressure
**Files:** PhotosIndexCoordinator.swift, PhotosRepresentationReader.swift, PhotosIndexGateway.swift, PhotoKitGateway.swift, ImageWorkBudget.swift, SyncStore.swift task selection, SyncRuntime.swift only if tick integration needs it; focused core/UI-host tests.
**Interfaces:** Inject wall/monotonic closures; processDueWork(now:) cutoff compatibility; async reader admission snapshot (available/busy/draining/stalled) with default fake implementation; task selection optional rotating cursor, no schema change. Constants: 16 attempts, 1-second slice admission budget, 60-second drain-stall threshold.
- [ ] RED tests use fake clocks/callback gates: failureTime+backoff, sibling busy no-write, timeout then late drain resume, no terminal bounded wait, budget-held after active empty, duplicate terminal, terminal-before-query, pause/context change, slice size/time and fair cursor wrap.
- [ ] Implement smallest coherent scheduler/admission changes preserving owned work and all existing content/unknown/soft-read behavior.
- [ ] Run focused GREEN plus affected regression groups, self-review and commit.
- [ ] One task reviewer checks spec and quality; resolve findings; tester validates integrated affected groups without rerunning identical evidence.

### Task 3: 0.2.3 release preparation and frozen handoff
**Files:** project version config, scripts/package-release.sh exact version checks, docs/release/0.2.3.md, README.md, focused version-tool expectations as needed.
- [ ] Set stable 0.2.3/build11 consistently; document diagnostics, timing and scheduling fixes and unresolved repeated invalidation/no-terminal limits.
- [ ] Run version/package static checks and diff hygiene, commit; freeze clean candidate and report exact SHA/path/evidence.
- [ ] Independent acceptance chat reviews full integrated branch and coordinates canonical validate once; wait for explicit clearance.
- [ ] Create/attach PR, squash to main after clearance, compare source trees; exact-main package-release performs mandatory archive validation and Universal/signature/DMG/provenance checks.
- [ ] Publish v0.2.3 latest stable with four customary assets, three-payload public sums, private full manifest; read back tag/main/release and re-download all assets to verify. No installation or production launch.
