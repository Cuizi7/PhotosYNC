# Reconciliation request coverage implementation plan

Goal: consume only full/context requests already covered by successful inventory reconciliation.
Spec: `docs/superpowers/specs/2026-10-16-reconcile-request-coverage.md`.
Execution: one cohesive runtime/coordinator unit owned by the main agent; independent evidence, test validation and final deep review are delegated. No editing validation/package scripts or Tools tests.

- [ ] RED: promote the busy-event fake sequence to a regression asserting one full pass. Add later-event, failure, reader-capacity and same-revision controls using UUID stores/fakes and explicit gates. Run before the repair and record the intended duplicate-pass failure.
- [ ] GREEN: return coordinator change receipts, confirm only successful full-pass start watermarks, and separately track/consume covered runtime full/context receipts. Retain explicit force and physical safety behavior.
- [ ] Verify: rerun changed regressions, then an independent tester runs the integrated runtime/coordinator and related contract suites. Record exact source/test snapshot, failures, counts and residual system/production limits.
- [ ] Review/deliver: one final integrated deep review; resolve in-scope findings with targeted regression evidence. Freeze exact SHA/tree, private evidence and public-safe change description; open PR. No merge/tag/release/install.

All changes must map to request coverage or a named acceptance control. Conservative history/content invalidation, completeness/publication, backpressure and permission/source policies remain binding. No real Photos or source-media tests; only the explicitly permitted log/version/read-only SQLite capture was performed.
