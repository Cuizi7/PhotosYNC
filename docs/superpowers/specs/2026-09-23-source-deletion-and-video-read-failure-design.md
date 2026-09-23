# Source deletion and video read failure

Date: 2026-09-23
Status: implementation scope agreed in conversation

## Goal

A source file that was deleted before a confirmed Photos submission is normal source churn. It must leave the pending queue without repeated retries or a file-failure warning. A video whose media metadata cannot be read remains an explicit file-level failure; it must not be silently imported, skipped, transcoded, or presented as a source outage.

## Invariants

- Source media is strictly read-only. Photos writes remain additive and use the original file URL with `shouldMoveFile = false`.
- Keep the four file states `pending`, `importing`, `imported`, and `skipped`; preserve success history and all uncertain submissions.
- Never infer deletion from an unavailable root, a failed or deferred directory traversal, a paused/disabled source, or a partial enumeration.
- A failure of one supported video must not stop healthy sibling files.
- No runtime dependency on ffmpeg or ffprobe, no staging, remuxing, or transcoding.

## Normal source deletion

At the start of a source traversal, take a snapshot of its pending record IDs and relative paths. Remove a path from this set whenever the directory reader reports that entry, even if the entry later has a metadata failure. After all directories have been enumerated without a directory-level failure, deferred read, or an entry whose attributes failed before its file/directory type was known, the remaining paths are confirmed absent for that traversal. A file-level metadata failure elsewhere does not invalidate directory completeness.

For each absent record, a store transaction removes its comparison evidence and the file record only if the row is still `pending` and either no Photos attempt was submitted or `definitely_not_committed = 1`. Before removal, any `suspectedDuplicate` rows whose `match_evidence.candidate_key` names this pending record are returned to `pending` and their stale comparison evidence is cleared. Their normal submission path rechecks every current Photos and local candidate before any import; this is necessary because an absent pending record must not remain the sole reason another file stays skipped. Both new and existing duplicate-skip commits revalidate referenced local candidates within the same SQLite transaction, closing the race where another source selected a candidate before it was deleted. An `importing` row, a row with uncertain submission evidence, and every imported or unrelated skipped row remain untouched. A concurrent transition makes the removal a no-op; it must not stop the engine. Pending-queue advancement uses the immutable created order rather than looking up a previous row ID, and a drain holding a now-retired row treats its failed pre-submission transition as superseded work. Removing the pending record clears both its scan-stage and submission-stage in-memory issues, emits one ordinary audit event, and does not increment `failed` or `failedFiles`, send a failure or source-recovery notification, or count as `skipped`.

A later file at the same relative path is a new discovery and goes through metadata reading, conservative duplicate matching, and the usual submission path. Existing successful import history remains a candidate, so source deletion never causes automatic re-import of an already imported asset. A changed stamp on a still-present recorded file continues to use the existing `sourceChanged` rule.

The currently missing JPG follows this rule after the new version's first complete traversal. No direct edits to the live database are part of the repair.

## Supported video that cannot be read

`.mpg` remains a video candidate. If `AVURLAsset.load(.duration)` or another required media read fails, the engine records an actual file-level metadata failure, continues healthy files, and makes no Photos submission for that file. The error detail persisted in logs and `scan_run.last_error` includes the relevant `NSError` domain/code chain so a generic localized sentence does not erase the cause. User-facing summary remains plain language and does not assert that the file is corrupt or unsupported without proof.

A read-only probe of the reported MPG returned `AVFoundationErrorDomain -11800` with underlying `NSOSStatusErrorDomain -12979`; a self-made standard MPG loaded successfully on the same machine. This establishes that the current original-file metadata path cannot process this particular file. It does not establish whether PhotoKit would accept it if submitted directly. The product must not bypass the required metadata read on that uncertainty. The file remains a visible file-level failure under the existing scan status model and is retried only by ordinary scans, with no special fast retry deadline.

## Deferred UI work

TODO: design a separate, bounded way to inspect individual file errors. Do not expand the menu into an unbounded per-file list in this repair. Existing source-level issue and scan failure count remain.

## Verification

- Use self-made media, temporary source directories, temporary SQLite, and an injected fake Photos gateway. Do not scan production paths or write to the production library in automated tests.
- RED/GREEN tests cover deleted pending files, source traversal failure/defer, same-path reappearance, dependent duplicate re-evaluation, concurrent transition to `importing`, retained imported history, and a video metadata failure alongside a healthy file.
- Validate that deletion removes a due retry and does not trigger another full scan; the unreadable video remains a file failure rather than a source outage.
- Run the repository's complete `scripts/validate.py` gate on the final code and obtain independent review. GUI, real Photos, compatibility, and local package results must be reported separately.
