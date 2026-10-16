# Source root availability correction

Approved task: when a configured root is inaccessible, show its directory error and
stop new work for that source. Keep other sources and Photos indexing running.
This corrects the existing runtime contract; no schema, media/model, matching,
Photos acquisition, version or release changes are included.

## Diagnosis and design

The 0.2.3 baseline reports root enumeration failure but `canSubmit` ignores it.
The shared pending drain then reads every child stamp and persists a separate
file retry. Scan-time child errors also continue without verifying the root.

Keep actor-local root admission separate from the existing directory-issue slot:
child-directory failures already share that slot and must not close a whole root.
A root must have actual successful enumeration before its first submission.
Root enumeration failure closes admission until a later root enumeration succeeds.
An actor-local closure revision rejects older root-success continuations after a
newer outage, deferral or source disable/removal; no persistent state is added.
A child read failure triggers one bounded root enumeration: root failure becomes
one directory issue and ends that source's current work; a successful root probe
keeps the original independent file/child error; contention only defers work.
Recheck admission after suspension, including the existing synchronous advanced
submission mirror. Never cancel or discard a dispatched Photos result.

While a root is unavailable, project only its root diagnosis into the existing
compact row/hover. Retain independent file/submission evidence internally and in
SQLite, then reveal/reconcile it through normal recovery. Do not erase history,
pending work, unknown submissions or retry evidence. Existing source backoff
remains the recovery scheduler; expiry itself does not reopen admission. Automatic
index-ready/legacy-work kicks withhold only unavailable roots until their recovery
deadlines, preserving child-only automatic kicks; explicit manual force retains
its existing immediate probe.

## Implementation and acceptance sequence

1. Add deterministic regression tests using synthetic files, UUID stores and fake
   Photos. Record baseline RED for large pending queues, cold unknown root,
   mid-scan/mid-drain loss and root-only projection; preserve late-callback checks.
2. Apply the minimal engine-local admission/probe/projection correction.
3. Run focused engine checks, independent tester validation, integrated deep review,
   and canonical `scripts/validate.py` against the final behavior/test snapshot.
4. Record exact evidence, commit and open a reviewable PR to main. No merge,
   packaging, install, production media/database access or system changes.

Existing independent file/child-directory, deferred, unknown/checkpoint and
continuation regressions remain acceptance requirements. Hardware/network/real
Photos testing is separate and is not claimed by synthetic validation.
