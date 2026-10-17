# Photos ID/date Incremental Analysis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. All writes serial; parent owns final independent review.

**Goal:** Same ID/valid date reuses analysis directly; only changed/missing dates enter per-item digest/inference, with durable success facts and no whole-library rebuild.
**Architecture:** Reuse the existing representation table, task queue, reader, fingerprinter and inventory barriers. Persist observed versus accepted dates/version independently; discard notification-driven cache invalidation as an analysis decision. Keep the existing successful input cache binding.
**Tech Stack:** Swift, public PhotoKit, CoreML, SQLite; macOS 13 minimum unchanged.
**Spec:** docs/specs/2026-10-17-photos-incremental-recovery.md

## Global Constraints

- Only this isolated worktree and UUID temporary data/fixtures; no real Photos/production DB/process/target/permissions/monitoring.
- Never clear/rebuild all analysis, batch ready→pending on uncertainty, or rotate a persistent domain because of failure. Do not lose old successful results.
- Same ID + same valid date + same representation/analysis contract directly reuses; no resource/content event override. Missing dates are not equal proof.
- Observed date and accepted successful date are different facts. Success date/vector/digest/contracts commit atomically after current-task checks.
- schema v10 may be extended before any release; dual schema definitions agree, v9 migration preserves unchanged ready rows and does not invent digest pairing.
- No main merge, push, publishing, production launch or new dependencies. No concurrent implementation writers; independent reviewers read only.

## Review Focus

1. Startup event order: same date notification reuses; changed date before/during adoption cannot publish old result (Task 2 tests).
2. Date B read fails and later date C arrives: accepted date A/vector remain until a valid current success, retry bounded (Tasks 1/2 tests).
3. Metadata/resource/revision changes with unchanged date do not trigger image work (Task 1 store + Task 2 integration).
4. v9 ready cache with hashed revision but no date/binding bootstraps only proved per-item facts (Task 1 migration tests).
5. Permission loss, incomplete inventory, cancellation, change after last catalog page do not imply deletion/readiness (Task 2 controlled-gate tests).

---

### Task 1: Persist observed and successful date facts

**Files:** Modify AdvancedDedupTypes.swift, PhotosRepresentationReader.swift, Storage/SyncStore.swift, Storage/Schema.sql; Tests/PhotoSyncCoreTests/AdvancedDedupStoreTests.swift and necessary descriptor fixture helpers.
**Interfaces:** RepresentationDescriptor gains optional modificationDate default nil. Store task reconstruction retains that date. Existing completeRepresentation/reusableFingerprint signatures remain; internal columns separately identify current observed date, successful date and successful vector contract. Task 2 consumes these same APIs.
- [ ] Add permanent failing store tests for same date/different revision or dimensions zero tasks, changed date pending with old successful facts retained, missing dates per-item, stale completion and digest hit failure fencing; v9 bootstrap without false digest pair.
- [ ] Run focused RED with current source; preserve expected failure output.
- [ ] Implement minimal schema/descriptor/upsert/accept/failure changes; retain old vector on read failure and keep it out of current queries. No generalized cache layer.
- [ ] Run focused Store/reader/migration tests; document any integration expectations intentionally deferred to Task 2, do not repeatedly run full suites.
- [ ] Self-review and commit owned files, record report. Fresh task reviewer issues separate spec and quality verdicts; fix scoped findings before Task 2.

### Task 2: Make discovery/recovery follow date-only incremental policy

**Files:** Modify Sync/PhotosIndexCoordinator.swift, Photos/PhotoKitGateway.swift, Photos/PhotosIndexGateway.swift, affected tests; only amend Store from Task 1 if integration needs a documented interface correction.
**Interfaces:** Consume Descriptor.modificationDate and Store observed/successful facts. Keep catalog/session/generation and current-task barriers; reuse existing CoreML pre-inference digest callback.
- [ ] Turn old P1 probe into permanent same-date zero-work positive and changed-date stale-ready negative; gate event classification during adoption and test permission failure/pause then resume.
- [ ] Run RED before changing discovery policy.
- [ ] Remove notification/history/unknown-scope paths that force same-date input work; metadata enumeration and per-item upsert own analysis freshness. Preserve insertion/deletion discovery and real inventory fences. No random namespace on failures and no global analysis clear shortcut.
- [ ] Update old tests to use actual dates for content changes rather than hash-only revision/notification as a substitute; retain meaningful same-date, new date, actual input changes, retries, restart and checkpoint race assertions.
- [ ] Run focused coordinator/gateway/reader/runtime tests, self-review and commit. Fresh task reviewer supplies separate spec/quality verdicts; resolve scoped findings.

### Task 3: Freeze and validate the integrated snapshot

**Files:** README.md and the spec may be reconciled with final implementation; ignored work evidence/ledger only during frozen verification.
- [ ] Confirm supplemental old-snapshot results: 102 tools pass, stamp and advanced-preparation green/red probes pass; preserve original canonical failure.
- [ ] Complete branch-wide spec/quality review coordination with parent; never label self-review as independent.
- [ ] Freeze source manifest; run python3 scripts/validate.py --scale-profile full with fresh absolute work output/derived paths. It runs full unfiltered XCTest, 4 scale samples, 102 Tools and two continuation probes using standard thresholds.
- [ ] If failure occurs diagnose, no arbitrary timeout relaxation/deletion. Source changes invalidate frozen evidence and require final canonical on last behavior/test snapshot.
- [ ] Export exact patch/base/manifest/review reports and results; state untested real Photos/platform/distribution. No merge/push/release.
