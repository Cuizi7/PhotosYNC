# Release Validation Closure Implementation Plan

**Goal:** Make local agent acceptance and packaging fail closed on the same committed source snapshot, retain the continuation-race regression in version control, and squash the completed branch into main.

**Architecture:** The existing packager keeps its clean git archive boundary. A mandatory validator builds Debug for testing from that archive, runs unfiltered hostless XCTest plus a tracked controlled-continuation regression and tool tests, then records machine-readable evidence. Only successful validation permits signing, DMG verification and publication of a new release directory.

**Scope:** User-approved local app/DMG release and squash merge to main. No remote push/tag, installation, real Photos, user preferences, global skill/config changes, new product behavior or version bump. Existing beta3 artifacts stay intact. Repository AGENTS.md is the agent harness contract.

## Interfaces and ownership

- `python3 scripts/validate.py --output-dir ABS --derived-data ABS`: build current snapshot in Debug with build-for-testing; run full XCTest; reject nonzero exit, missing/zero/failing summary, timeout; invoke Python tool regressions and `python3 scripts/test-continuation-race.py --output-dir ABS/continuation-race`; write validation.json only on complete success.
- `python3 scripts/test-continuation-race.py --output-dir ABS`: copies the current Core sources, inserts exactly one await gate after the uniquely identified no-attempt retry write, compiles with the tracked fixture, and runs under a bounded process timeout. Anchor mismatch, compile failure, timeout, or any assertion failure is nonzero. No gate or extra API enters the app.
- `Tests/Regression/ContinuationRace.swift`: real Engine/Store and isolated UUID SQLite, fake source/Photos, deterministic gates. Require successful retry persistence, subsequent sourceChanged skip/resolution, then resumed drain with no waiting/blocking/spurious failure/notification or Photos submission. Preserve explicit controlled-interleaving provenance.
- `scripts/package-release.sh`: call validator inside its git archive before publication; build normal Universal Release from the same archived source after validation; retain version/architecture/signature/DMG checks, add evidence/checksums, prevent concurrent/old-release overwrite. No skip or success-cache bypass.
- `Tests/Tools/test_release_validation.py`: real CLI behavior with isolated fake tool boundaries; verify failure/zero-tests/timeout/preexisting-output behavior and that failed stages cannot reach release publication.
- `AGENTS.md`, `README.md`, `Design/Validation.md`, `docs/release/0.1.0-beta3.md`: normal beta automated gate policy, targeted real-system verification triggers, immutable evidence, merge/release limits, updated current acceptance state.

## Steps

- [ ] Persist the continuation regression; run GREEN and prove RED by removing its guarded publication invalidation only in a temporary source copy. Verify bounded wait/runner failure and instrumented source anchoring.
- [ ] Implement mandatory validator and package gating; verify orchestration failure modes with actual executable fake-tool fixtures, not source-text assertions.
- [ ] Update harness/release documentation to require the closed workflow, allow ordinary beta without repeated real Photos, and distinguish a local ad-hoc release from external distribution.
- [ ] Run one integrated reviewer on new changes relative to 42c1ce8. Prior beta3/App coverage reviews remain valid; re-review only any fixes.
- [ ] Run validator with real Xcode/Swift/XCTest plus tracked race/tool tests on the committed branch; retain full counts and exit codes. Confirm dirty/same-version/failing checks cannot publish.
- [ ] Confirm main clean and unchanged from 4adc1e0; squash merge the whole completed branch locally. Verify resulting tree matches the reviewed branch.
- [ ] Run the real package entry point on final main to exercise archive → all gates → Universal app/DMG. Independently verify provenance source commit, validation evidence, checksums, architectures and signatures. Preserve host-managed worktree/evidence.

## Review focus

1. Tests and the normal optimized Release binary both come from the same archived source; do not enable testability or disable optimization in the distribution build.
2. A zero/failed/hung test run or failed probe never creates a successful validation marker or final release.
3. Copied/instrumented regression never alters product source or real source/library data; a changed anchor fails clearly.
4. Concurrent release attempts and an existing release are never overwritten or nested by mv.
5. Agent harness cannot infer real-Photos authorization from a release request; changes at system boundaries receive targeted acceptance, not unbounded production experiments.
