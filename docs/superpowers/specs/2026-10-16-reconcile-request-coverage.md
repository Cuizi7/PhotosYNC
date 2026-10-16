# Covered runtime reconciliation requests

Approved scope: repair unnecessary repeated full reconciliation within the existing runtime/index protocol. Base: `99721e645a1d524fb8bb04232ea50658ac51b1c3`. Production evidence and media remain private; this document contains only protocol facts. No change to content/history invalidation, model inputs, readiness, persistence, scheduling fairness, source handling, permissions or physical ownership.

## Defect and intended behavior

A full/context event received while a due-work batch waits for reader admission invalidates the coordinator and leaves runtime `changePending`. The batch can subsequently reconcile internally; runtime still forces a second complete pass. Controlled fake tests reproduce two passes for one event. Full reconciliation must still run independently of reader busy/draining/stalled; simply relying on `processDueWork` would block catalog work behind physical reader capacity.

## Bounded design

The coordinator returns an opaque run-local monotonic receipt from its existing change handler. Capture that receipt before its first await. At the start of a full reconcile capture the current receipt watermark. Advance the covered watermark only after the complete successful inventory path, final currentness/publication checks, and a final not-paused/not-needing-reconciliation check. Pending fingerprints do not prevent inventory confirmation; ready publication remains separate. Failed/interrupted reconciliation never confirms a request. A later event, even with the same fake Photos generation, is not covered by an earlier start watermark. A small actor query reports whether a receipt is covered and reconciliation is still valid.

Runtime retains explicit force/permission requests separately from full/context event receipts. Keep the newest pending event receipt. Check coverage after registering an event and at the end of an owned work batch; after each await clear only the identical captured pending receipt. Existing `indexEventPending` preserves a cheap continuation for other work. Explicit/manual/permission/periodic full reconciliation remains independent of reader capacity and is never consumed by the event receipt helper. Dual subscriptions may conservatively require another pass for delayed anonymous full delivery; no generation-equality deduplication or event-loss assumption is introduced.

## Acceptance and non-goals

- Busy full/context event covered by an internal successful pass produces one full catalog.
- Idle, later-during-reconcile and later-after-completion requests still reconcile; same-generation late control is synthetic protocol protection, not a production edit claim.
- Failed or paused passes retain work. Full/context events still reconcile when reader capacity is unavailable.
- Same-revision explicit content invalidation still reissues/finishes work; unknown history remains conservative. Existing input diagnostic semantics and physical slots remain untouched.
- No schema, gateway protocol, new persisted infrastructure or unbounded event storage. Only run-local receipt state is added.

Validation: controlled failing/passing regression, integrated runtime/coordinator safety tests, one integrated deep review. The coordinating chat owns final canonical QA and merge/release decisions; this branch supplies focused evidence and a reviewable PR, and does not repeat the separate profile-workstream full four-scale gate.
