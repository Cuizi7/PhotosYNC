# Source removal and compact settings

User requests removal of configured source directories and no excess blank area below Diagnostics.

Removal deletes the visible configuration, not filesystem media or Photos assets. Persist a removed flag, disable scheduling/new submissions immediately, retain all file/import/unknown history and callbacks. Re-adding the exact path restores its source identity/history, but validates against other visible overlapping sources first. Removed sources do not block configuring a different parent/child source; histories still participate in conservative duplicate checks.

Upgrade existing schema v2 to v3 transactionally. Missing file/directory must not prevent removing its configuration. Back up the production DB before running the new app. Do not reset it. The future network identity plan must target a later version rather than conflicting with v3.

Settings: native Remove action with a brief confirmation of non-destructive semantics. Content-size height with maximum scrollable height; empty, disabled, one-source, errors and multiple sources must remain usable on macOS13+. No fixed590-point empty window.

Validate: migration/reopen/readd history, overlap rules, removal while import in-flight; full tests and independent review; actual window screenshot, then rebuild ad-hocRelease/DMG/provenance. No production Photos writes needed for this change.

## Validation

Full127 tests passed (work/SourceRemoval-all-final.log). Migration tests coverfresh/v1/v2; independent tester migrated copy of actualproductionv2 and verified sourceUUID/fileIDs/successIDs/states unchanged. Reviewer findings freshnonmedia table, removedunknownafterrestart notification, and removalstoragefail blocking fixed. No product media deletionAPI added.

Native Release GUI verified2026-09-15: actualv2database upgradedv3 retaining2imported records. Existing disabled /Volumes/PhotosYNC-QA removed via native confirmation; source.enabled=0,removed=1,visiblelist empty, imported history2 unchanged. No newPhotoscalls requested. Actual window546pt with disabledrow→530pt empty (authorization section visible), diagnosticbottom standard24pt margin. Screenshot work/SourceRemoval/settings-after-remove.png. Backupwork/SourceRemoval/production-v2-before.sqlite retained.
