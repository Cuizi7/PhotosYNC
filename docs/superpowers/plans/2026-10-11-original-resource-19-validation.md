# Original Resource Common Decoder Validation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development for one cohesive private probe and its independent review/verification. The user explicitly requested planning followed by a real 19-pair test; do not stop for another scope confirmation.

**Goal:** Test whether original Photos encoded resources and the same Source decoder recover the frozen 19 same-frame pairs at the unchanged 0.98 threshold.

**Architecture:** Both sides enter the unchanged frozen Core `MetadataReader.readForFingerprint` and `ImagePreprocessor` from encoded file URLs. A private app streams only the 19 frozen Photos originals to owned temporary files; offline scoring then uses the unchanged FP16 CoreML configuration. Product code and previous QA state remain untouched.

**Tech Stack:** Swift, public PhotoKit / ImageIO, existing frozen PhotoSyncCore / CoreML, small Python custody and report helpers.

**Spec:** `docs/superpowers/specs/2026-10-11-original-resource-common-decoder-design.md`.

## Global Constraints

- Source strictly read-only; no Photos mutation, catalog/index/database access, production App launch, model/threshold/label change, merge or packaging.
- Exactly the 19 `duplicate` rows from `independent-labels-initial-50.jsonl`, with their frozen mapping and reliable `original` revision. No basename substitution or new convenient pairs.
- Shared decoder: current max long edge 4096, decoded allowance 512 MiB, single physical operation; current full-frame 320×320 sRGB and normalization.
- Streamed Photos resource QA cap 64 MiB and request deadline 30 seconds. Actual completion owns cancellation/drain; no overlapping replacement request or unexplained zero occupancy.
- Private artifacts only under `work/real-photos-icloud/20261011-original-resource-19/`, dirs 0700/files 0600. Delete only this run's temporary encoded Photos files after physical completion; preserve tensors/results/error evidence and old QA outputs.
- Unknown/read-failed/over-limit cases remain explicit missing comparisons. Healthy groups continue after a drained item failure; global authorization/library failure stops new work. Targeted retry preserves all attempts and revalidates inputs; there is no one-error retry restriction.
- Ordinary macOS permission handling only; ask about a real new prompt when it occurs, never borrow TCC identity/modify TCC or force mounting.

## Review Focus

- Frozen pair mapping must bind all 19 cases, stamps and selected original descriptors before live reads.
- Source mutations or Photos original changes during capture reject that case; unrelated notifications do not invalidate stable pairs.
- Cap/timeout-before-request-ID, late chunks, duplicate completion, filesystem failure and lease drain must not leak or permit new physical work.
- Temp cleanup must be ownership-bound and occur after native completion; partial errors never look like successful captures.
- Exact tensors, model/version, score denominator and original 33 labels must be verified independently.

---

### Task 1: Frozen 19-pair capture probe

**Files:** Private `capture/` and `inputs/` under the work directory; no product files.

- [x] Build and hash `inputs/pairs.private.json` from frozen labels/maps, proving 19 unique IDs, original resources and unchanged source/meta custody.
- [x] Prepare the smallest app using unchanged frozen Core. Reuse the reviewed resource-stream state where possible, with explicit hash/provenance; add per-case capture, safe cleanup and truthful failure continuation.
- [x] Run synthetic refusal/race/cleanup checks and strict compile/sign/static checks, without live media. Preserve failure attempts.
- [x] Independently review the exact private source/binary/spec snapshot before launch.

### Task 2: Live capture and exact scoring

**Files:** Unique capture attempt directories, native exit/custody report, `scores/` under the work directory.

- [x] Launch the reviewed private app once, normally in the background. Resolve actual system prompts; capture each Source and mapped Photos original sequentially.
- [x] After each case, verify stamps/revision, publish exact tensors/metadata, delete the run-owned encoded resource only after drain, and checkpoint success/failure. Never reuse a changed or unverified result.
- [x] Confirm actual native exit, zero physical work, all 19 terminal outcomes and input custody. Retry only affected failed/missing pairs when the known blocking condition has resolved; retain attempts.
- [x] Offline score all completed tensors with the current CoreML FP16 ANE/GPU policy, fixed 0.98, four model self-tests. Report content comparison separately from dimension/action policy.
- [x] Run the active 33 fixture content comparisons through this same encoded-file decoder; no real Photos writes or fixture label edits.
- [x] Independent tester recomputes hashes, cosine and counts, verifies cleanup/exit and failures, and checks what was and was not actually validated.

### Task 3: Evidence and planning closeout

**Files:** Public aggregate `docs/research/advanced-dedup/2026-10-11-original-resource-19-results.md`, private HTML/report, this plan.

- [x] Show all 19 old/new scores in an HTML table, with frozen expected results and failed cases explicitly visible.
- [x] Summarize encoded-byte equality, successful recovery count, remaining misses, physical/temp cleanup and observed timing/bytes without population claims.
- [x] Reconcile results with the design, name remaining production current-version/capacity/migration/negative tests, and update plan checkboxes with actual evidence. No product implementation or release implied.

## Preflight self-review

Tasks share only immutable input bindings and completed tensor outputs; the capture app has no model/index work, and offline scoring has no Photos/Source API. Public documents contain aggregate facts only. This is the requested original-resource experiment, not a new product rollout or a repeated model-selection run.

## Executed result (2026-10-11)

Tasks 1–3 complete. Original19 compared19/19 and all reached unchanged0.98; scores0.9840663091727172–1.0. Eighteen pairs have identical encoded bytes and exact inputs. Active33 content33/33 (14 duplicate /19 distinct), four model goldens passed. Initial direct-native launch failed before reads because TCC attributed it to Codex; same reviewed app then ran normally through LaunchServices, own normal Photos/network permissions received, native exit0 and physical drain0 verified. All new encoded Photos temps removed. Targeted selection code was not needed: the failed authorization attempt captured no pair, so all19 were affected.

A separately reviewed timing-only scorer reused the captured tensors; its vectors/results exactly matched, native exit0. Prepared model API calls median5.44ms; initial load/self-tests1.742s. Per-call time includes possible recovery inside the awaited API; this run recorded no fallback. This does not measure cloud-only transfer or whole-library throughput.

Independent artifact verification and focused timing/report verification PASS; private evidence in work/real-photos-icloud/20261011-original-resource-19/verification. Cleanup is supported by case receipts, actual directory inventory and reviewed ownership guards; deleted inode identities were not retained in a separate manifest. Public aggregate: [original resource19 results](../../research/advanced-dedup/2026-10-11-original-resource-19-results.md). Product implementation, edited/current, real negative raw-resource path, capacity/crash migration and later write/release remain outside this completed experiment.
