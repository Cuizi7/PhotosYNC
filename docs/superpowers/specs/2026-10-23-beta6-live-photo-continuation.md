# beta6 Live Photo continuation

The user approved the five-part repair proposal and serial implementation, verification, squash merge and a new local beta on 2026-10-23. This records that approval; it does not widen production access.

## Outcome

Completed resource reads and parsed pairing observations survive a brief notification-classification gap. Normal admission/queue/classification waits retain the task's running presentation. Due native Live Photo candidates are served preferentially, with ordinary work still making progress. Diagnostics distinguish queue, system download progress, first data and result reuse. Existing successful imports, exact pairing and protected deletion rules are preserved.

## Approach and boundaries

- Retain at most one completed raw resource awaiting classification, for at most 30 monotonic seconds, inside the existing 512 MiB aggregate budget. Retain at most one asset's partial parsed inventory result for the same bound. Revalidate its ticket, context, current descriptor and resource identity before use. A known change, unknown coverage, expiry, pause or cancellation releases retained work; no unverified result is committed.
- Keep serial inventory processing. Serve up to eight due native candidates before giving one due ordinary candidate preference; retries are never pulled forward. Resume a retained partial item first. This changes order, not matching or the unresolved-native-candidate safety gate.
- Treat `.busy` admission as ordinary queued work for presentation when work is due; `.draining`, `.stalled`, real failure retry deadlines, authorization loss and unknown mutations keep their existing protections. A few held failures cannot replace a healthy queued task's running caption. Keep six public states and the approved one-caption/equal-width solid-track layout.
- Historical notifications remain conservative unless public APIs can establish reliable coverage of the same changes. SDK/official API inspection found no shared event identity between `PHChange` and persistent changes; do not infer unchanged bytes from asset ID, descriptor, revision, or a token sampled later. Consequently this beta must not suppress unknown history invalidation. Record this verified limitation, and retain regression tests proving the safety boundary.
- Add bounded anonymous diagnostics for retained/reused/discarded work and system progress. A progress callback is telemetry, never success or content evidence. Compare one/two read lanes in an isolated controlled experiment; synthetic or warm-cache improvement alone does not justify enabling parallel production reads. Ship serial reads unless representative system evidence and lifecycle/budget verification pass.

## Acceptance and delivery

Exercise notification arrival after raw completion, after parsing and at commit; affected versus unrelated edits; unknown coverage; bounded expiry; pause/cancel; retry fairness; restart persistence; normal versus real waits; one/two-task menu/settings/details rendering. Use synthetic fixtures and isolated SQLite/fake PhotoKit for automatic checks. Private local media never enters Git.

Use full scale profile because resource lifetime, scheduling and SQLite selection change. An integrated deep review and tester evidence precede local squash merge; the canonical package archives the exact main commit. Deliver 0.3.0 beta6/build 23 with local ad-hoc signatures and Universal binaries. Do not install/restart the running application, modify production data, push remote, or publish GitHub assets.
