# Reconciliation request coverage implementation plan

Goal: preserve completed fingerprints during continuously classified neutral Photos changes, and consume only full/context requests already covered by successful inventory reconciliation.
Spec: `docs/superpowers/specs/2026-10-16-reconcile-request-coverage.md`.
Execution: one cohesive runtime/coordinator unit owned by the main agent; independent evidence, test validation and final deep review are delegated. No editing validation/package scripts or Tools tests.

- [ ] RED: promote the busy-event fake sequence to a regression asserting one full pass. Add later-event, failure, reader-capacity and same-revision controls using UUID stores/fakes and explicit gates. Run before the repair and record the intended duplicate-pass failure.
- [ ] GREEN: return coordinator change receipts, confirm only successful full-pass start watermarks, and separately track/consume covered runtime full/context receipts. Retain explicit force and physical safety behavior.
- [ ] Verify: rerun changed regressions, then an independent tester runs the integrated runtime/coordinator and related contract suites. Record exact source/test snapshot, failures, counts and residual system/production limits.
- [ ] Review/deliver: one final integrated deep review; resolve in-scope findings with targeted regression evidence. Freeze exact SHA/tree, private evidence and public-safe change description; open PR. No merge/tag/release/install.

All changes must map to observer continuity, request coverage or a named acceptance blocker. Conservative recovery after genuine gaps, completeness/publication, backpressure and permission/source policies remain binding. No real Photos or source-media tests; only the explicitly permitted log/version/read-only SQLite capture was performed.


## Direct follow-up execution — 2026-10-17

1. Record RED for the observed neutral-live / unknown-history / ready-to-pending chain through the real gateway and coordinator.
2. Add one inventory-continuity preparation result and fence-aware acknowledgement. Keep active durable checkpoints pinned; recover only on startup or explicit content-continuity loss.
3. Cover partial-build convergence, true edits, restart, gaps, permission loss and late acknowledgements. Retain PR9 request-consumption and physical-reader regressions.
4. Run focused checks, then independent integrated testing and one deep review of the final expanded PR. Run canonical acceptance once after fixes, with the existing full scale requirement for product-index behavior. Update PR9 to describe the final scope and limitations; do not merge, release, install or mutate the production library in this task.

5. Final review found a runtime permission gap that could bypass gateway reads. Explicitly revoke continuity on runtime-observed permission transitions, with a partial-build deny/edit/grant integration regression.
6. Validation exposed a pre-existing delivery/cancellation lock inversion. Defer termination removal without changing ordered delivery; retain the stack evidence privately and test concurrent termination/delivery.
