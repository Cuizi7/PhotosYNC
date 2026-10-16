# Model input diagnostics implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development within AGENTS risk scaling; independent owners and one integrated deep review, no duplicate review gates.

**Goal:** Explain accepted model-input recomputation with durable baselines and bounded causal/timing evidence.
**Architecture:** Result-local digest after existing prepare; SQLite completion transaction compares independent baseline; existing IndexDiagnostics projects bounded causal chains and complete aggregates.
**Tech Stack:** Swift, CryptoKit, CoreML, system SQLite, hostless XCTest.
**Spec:** docs/superpowers/specs/2026-10-16-input-digest-diagnostics.md

## Global constraints

Use only approved diagnostics, nullable schema v9 and synthetic fixtures; preserve model, acquisition, readiness, retry and physical ownership behavior. No private data or raw digest in logs. No production or release operations.

## Review focus

- Upsert changes current descriptor/version but must retain the independent old baseline contract.
- Late task completion after invalidation/context change cannot replace a successful baseline.
- Logical tensor indexing excludes padding and handles explicit byte order.
- Full summary counts survive sampling cap and disabled sinks.
- Causal scope uses context/epoch/generation and cannot relabel history unknown as content edit.

## Shared internal interfaces

- `ModelInputDigest(bytes: Data, contract: String) throws` is Equatable/Sendable, 32 bytes, nonempty contract.
- `FingerprintTimings` holds preprocessingSeconds, digestSeconds, modelQueueSeconds, predictionSeconds (default 0).
- `FingerprintResult(fingerprint: Fingerprint, inputDigest: ModelInputDigest? = nil, timings: FingerprintTimings = .init())` is Sendable.
- `ImageFingerprinting.fingerprintWithDiagnostics(image:orientation:) async throws -> FingerprintResult`, with default wrapper for legacy fakes. CoreML overrides the one-pass path.
- `InputDigestComparison: String` cases sameInput=same_input, differentInput=different_input, missingBaseline=missing_baseline, incomparable=incomparable, missingInput=missing_input (legacy fake/result with no diagnostic tensor).
- `SyncStore.completeRepresentation(_:result:) async throws -> InputDigestComparison?`: nil rejected; compare only after existing guard; old fingerprint API remains compatible and preserves baseline when input absent.
- `ImageFingerprinting.fingerprintWithDiagnostics(image:orientation:onTiming:)` reports executed `FingerprintTimingStage` elapsed samples, including throws/cancellation, without wrapping original errors.
- Parent owns IndexDiagnostics extensions and coordinator calls. Gateway owner will coordinate exact diagnostic APIs with parent before implementation; no concurrent edits to logging/coordinator.

### Task 1: Prepared tensor evidence

Owner: implementer, CoreMLFingerprinter.swift, AdvancedDedupTypes.swift, FingerprintTests.swift. Add failing actual-preprocess/stride/byte-order/result-local tests, run RED, implement once-only digest and timing result, run GREEN. Record focused evidence and self-review. No project file edits unless coordinated.

### Task 2: Accepted persistent baseline

Owner: implementer, SyncStore.swift, Schema.sql, AdvancedDedupStoreTests.swift, StoreTests.swift. Add failing migration/completion tests; run RED; implement transactional schema 9 and guarded compare/update; verify migration parity/rollback/unknown schema, stale task/retention/reopen and actual prepared tensors; run GREEN. No currentness or index policy changes.

### Task 3: Bounded causal/timing integration

Owner: parent, IndexDiagnostics.swift, PhotosIndexCoordinator.swift, PhotosIndexCoordinatorTests.swift; gateway implementer owns PhotoKitGateway.swift and PhotoKitGatewayTests.swift only. Add failing causal/count/cap tests; instrument existing stages without additional acquisitions/await gates; run focused GREEN. Connect history/live evidence and context-scoped sample causes through invalidation/task/result. Add synthetic overhead/log probe.

### Task 4: Integrated acceptance and delivery

Run tester focused integration, deep_reviewer on complete diff; fix in-scope findings and recheck affected behavior only. Freeze commit/tree. Run one fresh complete scripts/validate.py; preserve failures. Commit/push only this scope; create PR against main and attach. Record migration/overhead/evidence and unverified real Photos/platform boundaries; no merge/release.

## Execution record

- Tasks 1–3 implemented; initial integrated candidate `b93b02c` passed 279 focused tests.
- One complete deep review found two diagnostic P2 defects: latest observation could replace pending invalidation provenance, and failed predictions lost completed phase timings. Both are fixed within the approved logging/model-diagnostic boundaries.
- Causal RED reproduced 7 assertions across 2 tests; corrected gateway/coordinator 138-test run passed. Tensor partial-timing RED reproduced 4 failure/cancel cases; corrected 28-test run passed. Source/product policy unchanged; no new persistent causal index.
- Final scoped review and the single fresh complete validator are recorded with the frozen commit/tree in the PR/local handoff; no release or merge is included.
