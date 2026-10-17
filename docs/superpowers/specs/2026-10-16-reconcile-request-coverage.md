# Continuous Photos indexing and covered reconciliation requests

Approved scope: stop repeated invalidation of completed fingerprints within a continuously observed Photos session, and avoid full catalog passes for runtime requests already covered by a successful pass. Base: `99721e645a1d524fb8bb04232ea50658ac51b1c3`. The user authorized the continuity extension on 2026-10-17. Production evidence and media remain private. Model inputs, full-ready import admission, persistence schema, scheduling fairness, source handling and physical ownership retain their existing contracts.

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
- No schema, new persisted infrastructure or unbounded event storage. Gateway preparation/acknowledgement carries an opaque run-local continuity fence; runtime receipts remain run-local.

Validation: controlled failing/passing regression, real gateway/coordinator/store tests with a fake Photos lifecycle, runtime permission recovery, existing reader/admission controls, one integrated deep review and one canonical acceptance on the frozen result. Product indexing behavior changes require the existing full scale gate. This task updates PR9 without merging, releasing, installing or mutating production.


## 2026-10-17: continuous observer sessions and recovery

The user authorized a direct extension of PR9 after overnight evidence showed that completed fingerprints were repeatedly invalidated by persistent history reinterpreting already classified live notifications. This repair is implemented by the coordinating agent in this branch.

A gateway-owned, run-local continuity fence distinguishes a complete active observer session from startup or a genuine notification gap. Within a continuous session, full inventory consumes the classified journal and retains the last safely recovered durable checkpoint; it neither replays generic history IDs nor advances the token from callback timing. Unknown classifications, lost baselines, journal failures, authorization/library loss and context replacement revoke the fence. Large classified batches, downstream wakeup coalescing and periodic full inventory alone do not revoke content continuity.

Recovery keeps the existing conservative history/full-invalidation route. Its complete inventory acknowledgement establishes a new continuous session only for the same fence. All fingerprints need not be ready to acknowledge inventory, but the existing full-ready import/publication barrier remains. True same-revision edits, deletes and eligibility changes still invalidate affected representations; active work and final publication retain their await checks.

No new schema or per-asset history identity is introduced: PhotoKit provides no documented join between PHChange and persistent-history tokens. Active-session correctness relies on the public observer contract; it does not claim a periodic history audit for callbacks that are forever missing without any continuity-gap signal. Restart may conservatively revalidate changes since the retained checkpoint. This cost is accepted for this scoped repair; no token is advanced from silence, queue drainage or clean exit.

Acceptance uses the real gateway/coordinator/store graph with a fake PhotoKit lifecycle: nonempty neutral notifications plus repeated full inventory preserve completed fingerprints and converge; true edits remain invalidating; gaps/permission loss require recovery; late pre-gap confirmations fail; restart catches an edit included in a later token but not yet delivered live. Old tests that specifically exercise recovery explicitly introduce a gap instead of relying on every full pass performing history replay.

Runtime permission transitions synchronously revoke gateway continuity even when a paused partial build makes no PhotoKit request. A stale inventory decision cannot restore admission after this gap, including when the raw observer generation did not change. Library-unavailable callbacks also revoke continuity and active read leases' validity.

A validation-discovered subscription teardown deadlock is fixed locally: the AsyncStream termination callback schedules subscriber removal instead of taking the delivery lock while Swift holds its task cancellation lock. Delivery, overflow and acknowledgement remain serialized as before. A bounded concurrent cancellation/delivery regression complements the captured lock-inversion evidence; the channel is not otherwise redesigned.
