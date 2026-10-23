# beta5 runtime progress validation

Scope: coherent task publication and continuous bounded Live Photo work, based on beta4 commit `d250ea9`. No production database, Photos, source or running-app changes.

## Reproductions and focused checks

- `testOlderCurrentDoesNotHideLivePhotoRowWhileNewerPublicationIsHeld`: two controlled admission gates reproduce the missing task row while a newer publisher remains suspended. Exact-base isolated RED: one test, one failure (`work/beta4-task-visibility-probe/red-test.log`). Both publication orders pass after the fix (`work/beta5-publication-tests.log`, 2 tests).
- `testOneWakeDrainsLivePhotoBacklogAndStopsAtIdleOrHeldItems`: fixed clock, one wake and 35-item healthy/attention queues. RED processed only one item per queue (`work/beta5-worker-red.log`); GREEN traverses multiple 16-item slices without another UI tick and does not reread idle/held work.
- Runtime coverage includes repeated ticks during an in-flight read, source/reconciliation work during a held resource, pause with remaining items, stop, authorization loss, physical drain, classification deferral, and retry-held results. Diagnostic assertions check bounded slices, aggregate item counts and task visibility.
- Focused runtime, inventory, completion and presentation results: 143 tests, zero failures in `work/beta5-review-fix-tests.log`. Independent Tools: 102 tests, zero failures; AppModel: 11 tests, zero failures. Final integrated deep review found no remaining material concerns after pause ownership was fixed. Final package validation remains authoritative for the released source.

- Pause/resume ownership also has a controlled value-level RED (one test, two assertions in `work/beta5-pause-red.log`): a stale engine snapshot must not undo the latest runtime command. It passes after runtime owns this field. Completion-only work is tested through a future retry deadline and then creation, verification and retirement after a single wake.

## Native UI environment

Native rendering requires WindowServer access, so run the XCTest host outside the filesystem sandbox using the normal tool approval. The optional `P8_NATIVE_OUTPUT` directory must already exist before tests that call `renderMenu`; that helper writes PNG files directly. Initial sandbox runs could not create native rendering state; an exported-image run also failed when its output directory did not yet exist. No product or test assertions were changed to resolve either setup issue.

The 35-test AppView run under proper permissions passed 34 tests; the remaining optional-export case passed with its directory prepared (10 PNG files, `work/beta5-compact-existing-output.log`). It also passes under the canonical environment without optional export. The final unfiltered canonical XCTest run must still pass all tests. Menu/settings/details light and dark exports are under `work/beta5-ui-final`; the parent visually checked both menu appearances. These are offscreen images, not physical menu/hover evidence.

## Canonical release gate

Use full scale profile because runtime throughput/resource behavior changed. Package from the exact merged commit, requiring all XCTest/Tools, four configured scale samples, both continuation-race checks, source manifest and artifact checks. Final totals, commit, hashes and machine/toolchain are in the immutable package provenance and validation report.

Native view tests exercise menu/settings/details in light and dark appearances using fake state. They do not prove physical menu/hover/keyboard, macOS 13/14, Intel or real iCloud behavior. Existing exact-resource preservation, unknown-write protection and real-system boundaries are unchanged; no new real Photos write was performed.
