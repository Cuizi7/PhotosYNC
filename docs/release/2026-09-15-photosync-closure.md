# PhotosYNC release closure

Approved scope: rename user-facing application to PhotosYNC; finish packaging, final artifact end-to-end acceptance, resident behavior acceptance, flaky-test diagnosis; propose network recovery improvement without implementation.

Compatibility: preserve com.example.PhotoSync identity, PhotoSyncCore module and ~/Library/Application Support/PhotoSync/sync.sqlite. Do not reset histories. Internal Xcode target/scheme names may remain stable; shipped app/DMG and UI use PhotosYNC.

1. Diagnose intermittent EngineTests journal assertions; reproduce cause with deterministic synchronization and fix minimal necessary code/tests. Review integrated patch.
2. Build normal Release and unit tests from final code; commit source and docs, record exact commit, binary/core/DMG hashes, ad-hoc signature (not notarized).
3. Test exact final app on dedicated remote macOS13 account/system Photos library: native directory selection of unique self-made fixture, import, second scan, process restart; verify no duplicate and source unchanged. Do not substitute fake/readonly/instrumented wrapper evidence for this step.
4. Resident acceptance: real login toggle and state restore, notifications on source failure/recovery, natural30-minute cycles, sleep/wake; actual logout/login requires a recoverable authenticated desktop session. Do not log out local production desktop or type/retrieve passwords. Report any host/session constraint separately rather than claiming completed.
5. Network recovery: plan source identity validation and false-recovery avoidance for empty mountpoints, preserve unified directory adapter and no automatic mounting; spell out migrations and cases, leave implementation pending approval.

Existing successful production-library test and retained Recently Deleted test assets are documented in Design/Validation.md. User instructed to leave Recently Deleted alone. No further cleanup there.

## Results as of 2026-09-15

- Rename complete: PhotosYNC.app/executable/display name/DMG volume, menu/settings/notifications/docs. Stable existing bundleID and data directory. Case-insensitive name collision discovered while packaging; mixed staging moved aside, final app copied from clean Release output and strict ad-hoc verification passed. No DeveloperID/notarization claim.
- Flaky tests reproduced before fix (log iteration2; journal iteration13). Log test now waits specific parsed event. Journal test's concurrent rawSQLite polling itself could cause SQLITE_BUSY; now internal Store queue query waits actual failed journal before releasing scan finalization. Regression RED with old overwrite behavior fails; fixed targeted100loops and22EngineTests pass; full suite is separately recorded in validation log.
- Release successfully launches on local macOS and remote macOS13.7.8, same bundle bytes/signature checked. Remote PID85173 ran normal app and created first empty runtime DB. Local formal DB backed up to work/ReleaseClosure/local-before.sqlite (0sources). Local formal app authorization flow succeeded; native settings layout and labels inspected.
- FINAL APP END-TO-END INCOMPLETE: no new source was added through the formal app. Local Open panel path navigation did not reliably commit under UI automation despite returning successful AX calls; remote System Events GUI queries timed out(-1712). No direct DB/source injection used to pretend GUI passed. Prepared selfmade source fixture has not been imported by this final app.
- RESIDENT ACCEPTANCE INCOMPLETE: login toggle/system notification delivery/logout-login/sleep-wake/natural periodic scan with enabled source remain unverified on final artifact. Existing unit tests do not replace them. Do not force logout of user's working desktop or authenticate on their behalf.
- Network recovery proposal completed separately, not implemented; requires approval of manual verification fallback for old/unidentifiable sources and realNAS identity sampling.

Thus four requested closure categories are tracked honestly: packaging and flaky resolution complete after final provenance/commit; final-package fullGUI and resident acceptance remain blocked by control-session access. Existing prior nativefake/readonly and productionCore write evidence still valid only for their original scopes.

## Superseding SMB acceptance (2026-09-15 12:12 local)

Final-app end-to-end is now PASS: real remote readonlySMB selected via native volume picker,2realPhotos imports, service loss→waiting, same-share explicit remount→automatic recovery, process restart→startup scan with no duplicate. See Design/Validation.md and work/SMBFinal/report.md. The previous source-picker blocker is resolved by native sidebar volume selection. Resident login/logout/notifications/sleepwake/natural30min remains unverified; desktop locked again. Network identity implementation still pending.
