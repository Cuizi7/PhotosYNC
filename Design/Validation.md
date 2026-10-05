# PhotoKit Manual Validation

## Current Validation Status (2026-09-13)

| Specification acceptance case | Status | Evidence type and result |
| --- | --- | --- |
| 1. Conservative matching rules | Pass | Mock/unit: `DuplicatePolicyTests` covers filenames, second-level time conflicts, device conflicts, missing fields, time-zone uncertainty, and multiple candidates. |
| 2. Multi-source duplicate submission and retained successful history | Pass | Mock/unit: `EngineTests` and `StoreTests` cover de-duplication and history retention after the target disappears. |
| 3. Metadata failure versus missing metadata | Pass | Mock/unit: `SourceReaderTests` and `EngineTests` distinguish read failure from absent fields and rediscover later. |
| 4. Source stamp changes | Pass | Mock/unit: `EngineTests` and `StoreTests` record a conservative `sourceChanged` skip. |
| 5. Four-state recovery | Pass (mock) | Mock/unit: `RecoveryTests`, `PhotoKitContractTests`, and `EngineTests` cover definite failures, placeholder reconciliation, state-write failure, and unknown outcomes. Real PhotoKit fault injection is not run. |
| 6. Directory recovery, bounded slow I/O, and responsive status | Pass (mock) | Mock/unit: `SourceReaderTests`, `EngineTests`, `GlobalStatusTests`; a non-interruptible saturated worker pool remains a documented controlled-degradation case. |
| 7. Scheduling and login behavior | Pass (mock) | Mock/unit: `ScheduleTests` covers launch, 30-minute cadence, pause/resume, no overlap/backlog, and wake behavior. Login-item approval remains a manual macOS check. |
| 8. Native UI and menu-bar behavior | Qualitative GUI evidence | The inherited `--demo` screenshots cover dark unconfigured and light long-error layout. They do not exercise menu actions, folder selection, authorization, login-item registration, or a live scan. |
| 9. Permission/library/space/database failures | Pass (mock) | Mock/unit: `PhotoKitContractTests`, `RecoveryTests`, and `EngineTests` cover permission, unavailable/changed library, explicit failure, and storage failure states. Real disk-full and library-switch checks are not run. |
| 10. Source immutability, additive Photos behavior, and no media cache | Not run (real PhotoKit) | Requires the isolated account procedure below. Build inspection confirms no source-media cache directory is packaged; no personal library, test library, or source file was mutated during this task. |

The current local package has an ad-hoc signature produced by the local Xcode build. It is not Developer ID signed, notarized, stapled, or Gatekeeper-accepted. The host is macOS 26.6.2 with Xcode 26.6; the deployment target is now macOS 13.0. The real PhotoKit and macOS 13 and 14 host acceptance items remain open.

## Preconditions

1. Use a user-confirmed, separate macOS test account and that account's system Photos library.
2. Disable iCloud Photos for that test account. Do not change the user's default personal library or iCloud configuration.
3. Create a temporary source directory containing one self-made image and one self-made video. Make the directory and both files read-only before the import.
4. Record each source file's path, byte size, modification time, and a checksum for this manual test record only. The application must not calculate or persist this checksum.

## Import Confirmation

1. Start the test build with the test account's system library selected and grant the app read-write Photos access when macOS asks.
2. Run a single import for the image, then a single import for the video. Record the source path, placeholder identifier, PhotoKit completion result, and post-completion fetch result for each attempt.
3. Confirm that each returned identifier fetches exactly one asset, and that the asset's original resource filename matches the source filename.
4. Confirm the source files remain present, byte-for-byte unchanged, and still read-only. Confirm no existing Photos asset, album, or source file was edited, moved, or deleted.
5. Verify that candidate enumeration includes hidden assets and burst assets in this test library. Treat any authorization, availability, or enumeration error as a blocked import; do not accept an empty candidate array as success.

## Recovery Fault Points

For each case, stop the test process only in the separate test account, restart it, and record the recovery result before allowing another import.

1. Stop before `performChanges` begins. Recovery may classify the local failure as definitely not committed and retry.
2. Stop after the placeholder checkpoint returns but before the PhotoKit completion callback is observed. Recovery must fetch the placeholder: a matching asset becomes imported; no match remains unknown and stays importing.
3. Simulate a checkpoint write failure after the placeholder is created. The attempt must remain unknown and block further additions until reconciliation; do not assume PhotoKit rolled back.
4. Stop after the PhotoKit completion callback reports success but before success state is stored. On restart, fetch the recorded placeholder and mark imported only when it is found.
5. Simulate a system completion failure that explicitly reports the atomic change was not committed. Record definite failure and permit retry. Permission denial, unavailable-library errors, crashes, and a single missing placeholder fetch remain unknown or blocked, not automatic retries.

## Acceptance Boundary

Unit tests do not prove real PhotoKit acceptance. The original implementation task did not exercise the write path; the separately authorized backend acceptance on 2026-09-14 is recorded below.

## macOS 13 compatibility follow-up (2026-09-14)

Code commit `7a57730` lowers the deployment target to 13.0 and adds a native settings-window fallback; macOS 14+ retains SettingsLink. Local build-for-testing and Release builds passed; all 94 Core tests passed on the local newer OS host. Both app and framework were explicitly ad-hoc signed and verified for all architectures. This is not Developer ID signing or notarization.

Independent Codex on `user@mbp15.local` (macOS 13.7.8, Intel) verified minimum versions, executable checksum, strict signatures, demo launch, the running process and on-screen window/menu-bar-item records, and graceful exit. No product crash was observed.

Settings-button interaction, window close/reopen/minimize behavior are **Blocked**, not passed: System Events timed out (-1712), and non-prompting probes reported no Accessibility/screen-capture authorization. The initial demo window is not evidence for the settings-button path. Normal-mode Photos import, login/notifications, and test-library ownership remain unverified. No Photos writes or system permission changes were performed.

Retrieved reports: `outputs/remote-macos13/final.md` and `outputs/remote-macos13/compatibility.md`; raw remote evidence retained locally at `work/remote-qa/compat13-evidence/`. Those output/scratch files may not be Git-tracked. Remote originals remain under `/Users/user/Documents/PhotoSync-QA/2026-09-14/compat13/reports/`.


## Real backend acceptance and library-change fix (2026-09-14)

The user confirmed the system library of `user@mbp15.local` as a dedicated test library and authorized additive self-made media tests through a backend harness, without PhotoSync GUI interaction. A Cocoa AuthQA test app obtained normal PhotoKit read-write authorization. Host execution succeeded; earlier sandbox LaunchServices and AVFoundation failures are not evidence of a broken host installation.

The original Core imported JPEG and MOV successfully, then a library generation change interrupted indexing/admission. A pre-submission `libraryChanged` was incorrectly treated as an unknown commit by the engine. The old PNG record remains `importing` without a placeholder; that historical record was preserved, not automatically reset.

The fix retries invalidated candidate snapshots at most three times and classifies only demonstrably unsubmitted admission/mutation-prevention failures as definitely not committed. Unknown/checkpoint blocking remains unchanged. Independent review passed. Local regression tests reproduced the old failure. The integrated build passed; the full rerun passed 101 tests. The first full run had three failed assertions in the existing concurrent scan-finalization test, followed by passing isolated and full reruns; retain this intermittent-test limitation.

The fixed Core was compiled on macOS 13.7.8 Intel with only PhotoKitGateway.swift replaced; all other Core source inputs were unchanged. Fixed gateway SHA-256: `78844de2f2611b0b1440a86a259ec5acf6073a5320e0b24a93652f3990cf5d09`. Fresh isolated fixtures/database were used, preserving the earlier failed run.

- JPEG, MOV and PNG imported successfully in the first round; repeat scans made no additional submissions.
- Five cross-source same-filename cases were skipped with durable suspected-duplicate evidence. The real Photos adapter lacks reliable capture/device fields; source-only differences remain conservative skips, unlike complete-metadata rule tests.
- Actual fixture-container path removal/restoration prevented offline submission and allowed a fourth image after restoration. This is filesystem unavailability simulation, not an SMB/NFS outage test.
- Photos went from 2 to 6 assets: exactly 4 additions and 0 deletions. Added asset IDs, placeholders, successful callbacks and SQLite success relationships matched. Sources and old test records remained unchanged.
- The fixed run passed 23 runtime assertions and independent database/asset verification. No retries or unknown results occurred in this successful run; those paths have injected regression evidence.

Evidence: `outputs/remote-macos13/fixed-real/fixed-real-2BAD785A-9E35-41ED-9821-DD3E60A3A5AD/`, including app-events.jsonl, Photos snapshots and temporary SQLite databases. Source/artifact checks and the old PNG state are retained. Evidence outputs may be untracked. No deletion or cleanup of Photos assets was performed.

Not established by this run: packaged PhotoSync GUI wiring, real network mounts/slow-I/O faults, disk-full behavior, actual process-crash recovery, login/notifications, macOS 14 hardware, Developer ID signing/notarization. Existing distributed app/DMG artifacts predate this fix and are not fixed-build evidence.


## Real fault acceptance follow-up (2026-09-14)

Remote macOS 13.7.8 backend tests used the same fixed Gateway and a dedicated QA wrapper; no product source changes were made for fault injection. Evidence and detailed limitations: `outputs/remote-macos13/faults/final.md` and `evidence-faults/` alongside it. The controller independently checked retrieved asset sets, source manifests, callback IDs and SQLite snapshots.

- Four actual `_exit(86)`/restart cases: after durable intent before submit, inside the placeholder callback after checkpoint, after successful Gateway return before markImported, and after durable imported state. The first two retain unknown/importing with zero resubmissions; callback success is recovered by asset ID; fully imported history is not resubmitted. A missing placeholder fetch is not proof of non-commit. These are wrapper-controlled exits, not coverage of every OS transaction timing.
- Database-volume exhaustion: a dedicated 128 MiB HFS+ image reached ENOSPC. A real successful Photos callback followed by a full database volume caused Core storage to stop (CANTOPEN); the next file was not submitted. Removing only the test filler and restarting recovered the first asset by ID and imported only the remaining file. A separate SQLite experiment produced SQLITE_FULL with rollback/integrity preservation. Core's error must not be mislabeled SQLITE_FULL; final Core state was verified via app snapshots because CLI volume reads later returned EPERM.
- Real read-only loopback WebDAV mount: one asset imported directly from the mounted URL. Stopping the isolated service produced a waiting source; after service restoration and actual remount, the same engine resumed with unchanged source manifest and no duplicate submissions. This is WebDAV/loopback evidence, not SMB/NFS or WAN slow-I/O coverage.
- Total observed additions across this follow-up: five; zero observed deletions; source manifests unchanged. Earlier runs and unknown records retained.

Open finding: WebDAV auto-unmount leaves a readable empty mountpoint. In the first cycle, the engine reported recovery while scanning that empty directory before remount. Evidence is preserved; the later correct remount test does not erase this false-recovery status issue. Reliably distinguishing an empty source from a disappeared mount requires a separately scoped source-identity design; no automatic mounting or identity tracking was added in this test task.

Still not run: Photos target-volume exhaustion (cannot isolate without moving/selecting the system library or filling the system disk), source-full read behavior, dedicated network throttling, independent log-failure callback verification. Raw disk image remains on the test machine; local evidence archive excludes mounted trees, virtualenv, app bundles and disk images.

## SMB mountpoint comparison (2026-09-14)

Dedicated loopback Samba tests on macOS 13.7.8 distinguish mount management from protocol. Public NetFSMountURLSync with mountpath=NULL created a previously nonexistent /Volumes test directory; normal diskutil unmount removed it automatically before any QA cleanup. Manual mkdir + mount_smbfs succeeded, but normal unmount left the manually created empty directory; the original SourceRegistry accepted it and DirectoryReader returned zero entries. Thus the WebDAV finding must not be generalized to every SMB connection.

Stopping the isolated Samba service retained the mount initially; the 0/5/15/30s probes showed blocked reads. Near 60s non-atomic samples caught transition away from smbfs; by the first post-service-restoration check the system-managed directory was absent. Service restoration did not automatically remount; two explicit NetFS reconnects timed out. Online reads had network-volume TCC/EPERM interference, so successful-read/eject and successful-read/disconnect/recovery acceptance remain partial. No actual Finder GUI connection/eject was performed; these are NetFS API and manual CLI results.

Evidence: outputs/remote-macos13/smb/final.md and evidence-smb/. Existing user SMB mounts were untouched, temporary services/mounts were cleaned up, source/artifact and fixture checks passed. No Photos calls or product modifications were made by these probes.


## Local native GUI and single-instance acceptance (2026-09-14)

Local Photos is the production system library. GUI testing uses the separate GUIQA build configuration and identity `local.photosync.guiqa.session3`, a new UUID database/log session per launch, and self-created read-only source fixtures. Fake mode never accesses PhotoKit; readonly mode can enumerate real PhotoKit candidates but its create method always refuses writes. Production PID 96680 and production runtime data were not operated on.

Completed native GUI baseline (before the final visual polish):

- Settings and native NSOpenPanel added two actual fixture directories. The QA Documents-folder permission prompt was approved normally; a timed-out add was retried after approval.
- Ten distinct filenames imported into the fake gateway; the second source's one same-name file was skipped. Actual SQLite: imported=10, skipped=1.
- Menu Pause displayed paused; Resume ran a new scan and returned to completed without more imports. All eleven fixture SHA256 checks remained unchanged.
- Evidence: `work/GUIQA/evidence/stage1-baseline.md`, baseline-menu.png, baseline-settings.png and isolated stage1 SQLite. This is fake Photos integration evidence, not local real Photos writes.

Final GUIQA build: `work/GUIQA/Integrated/Build/Products/GUIQA/PhotoSyncGUIQA.app`; locally re-identified/signed copy in `work/GUIQA/Final/PhotoSyncGUIQA3.app`. Current changes disable Pause/Resume with no enabled source (including action guard), rename the settings entry, move logs into settings, and revise native spacing/layout.

Single-instance guard holds a per-user, per-bundle nonblocking flock before AppModel/SQLite/runtime initialization. Same-identity live legacy processes are checked while holding the lock; no disk bundle version is used to infer the running process's implementation. Actual isolated launch checks:

- Old lock-unaware QA PID57737 running: final QA launched and exited; no final-fake session was created.
- After terminating only old QA, final QA PID65307 started, creating exactly one session `60974D65-9AB0-4EC5-93DF-F08AD7851C59`.
- A second final QA launch with a distinct requested root exited; original PID65307 remained and the requested second runtime directory did not exist.
- Production PID96680 remained unchanged. Activation code is present; visible focus transfer was not separately confirmed. QA identities intentionally do not block the production identity.

Current final focused tests: 18/18 (launch/path safety12, readonly gateway3, process lock3), `work/GUIQA/Integrated-focused-tests.log`. Full suite after startup fix:119/119, `work/single-instance-review-fix-full-tests.log`. Earlier logs contain intermittent concurrency-journal/log assertions; later passes do not prove those timing failures eliminated. Independent review found no remaining concurrency bypass in current startup guard.

Residual startup limitation: during nearly simultaneous fresh launches, conservative legacy-peer detection can make both exit if the losing process does not disappear within200ms; it does not permit parallel synchronization.

Remaining local GUI acceptance: final menu enabled state/visual polish, Finder log action, and real PhotoKit readonly stage. These were interrupted by confirmed system lock (`CGSSessionScreenIsLocked=1`, black capture and inaccessible windows) on September14 at about22:34. Unlock the local desktop before continuing; do not attempt authentication automation. The final QA PID65307 is an empty-source fake session. Production Photos writes remain outside the authorized local test scope.


### Local GUI continuation after unlock (2026-09-15)

Final pre-compact QA native menu confirmed Pause disabled with no sources via AX enabled=false; settings label is 设置…, only four action buttons remain and no dropdown log action. Screenshots: `work/GUIQA/evidence/final-menu-empty.png`, `final-settings-empty.png`. Settings log action opened a Finder window named Logs; exact Finder target path was not obtained (AXDocument missing). An unnecessary Finder Apple Events permission request from the verification command was declined; QA log opening itself succeeded. Final fake session imported10 self-created files after normal Documents permission and retry.

Readonly session `final-readonly/Sessions/D2456A50-A2D2-424C-B641-9D663BD53BA0` ran PID78828 with explicit readonly args, isolated SQLite and approved Photos authorization. Native GUI added album-a. Engine completed real candidate loading (required before submission), then writes were rejected with `GUI QA readonly mode prohibits all Photos writes.` SQLite: pending10, success IDs0, placeholder IDs0; submission refusal logs retained. Candidate count and exact asset contents were not recorded. This validates the read-only QA adapter, not production gateway write lifecycle or all Photos APIs. No Photos write APIs are implemented in that adapter. QA was terminated after evidence capture to stop retries. All11 source fixture hashes still match.

User reported excessive fixed-height source-list whitespace. SourceSettings replaced the168-point nested List with a content-sized native VStack and8-point header gap; outer settings ScrollView handles multiple sources. Compact-layout build and screenshot verification recorded below when complete.

Compact layout verification: GUIQA build succeeded (`work/GUIQA/Compact-build.log`), independent static check confirmed all ForEach rows retained. Same isolated QA identity, fake backend, new `compact-fake` session. Native NSOpenPanel added album-a and GUI returned completed. Actual screenshot `work/GUIQA/evidence/compact-settings-one-source.png` confirms a single source uses its content height and diagnostics are visible without scrolling. No fixed168-point list remains. Runtime PID79862 is the isolated fake test app, not the production app.


## Authorized local production-library write test (2026-09-15)

User authorized2 self-created images and cleanup. Current Core independently built and linked to native test host; exactly2 successIDs matched SQLite, existing-history rescan created0. Live asset IDs1356→1358→1356; after targeted cleanup the live ID set exactly equals baseline and fixture hashes remain unchanged. Permanent cleanup in Recently Deleted is pending Photos album password unlock.

Fresh-store duplicate check exposed a limitation: identical-byte fixtures with unique01/02 names initially retained distinct resource names, but later both IDs reported01. The02 fresh-store attempt was intercepted by the harness2-call limit, so no third asset was created. This does not invalidate history-based protection; filename-only Photos matching without local history cannot reliably recover a name Photos changes. No content hashing was added to product.

Exact evidence and retained failures: `work/ProductionWriteQA/report.md` and adjacent JSON/SQLite/build logs. This tests the real Core engine/gateway against production Photos, not production GUI source configuration. Cleanup exists only in the test harness.


## Final PhotosYNC release, real remote SMB, native GUI (2026-09-15)

User authorized remote Mac SMB service. Isolated readonly Samba at192.168.10.107:1445, source /Volumes/PhotosYNC-QA selected by actual final-app NSOpenPanel. Two distinct selfmade JPEGs imported, README skipped. On test-service stop, final app reported timeout then missing directory/waiting; success count stayed2. Restart service +system remount led automatic recovery at12:10:52 local with no new submission; file hashes unchanged. Restart final app at12:11:53 completed startup scan, identical two successIDs. Evidence:work/SMBFinal/report.md and snapshots. This supersedes final-app GUI/source-picker blocker in closure report; previously no-source acceptance is now completed with realSMB+realPhotos.

Remaining: system login/logout, notifications, sleep/wake and natural30minute enabled-source scan. Desktop locked at12:15. Test service/share/source retained for continued acceptance. System-managed mount disappearance is covered; retained empty manual mountpoint false recovery remains a planned fix.


## Source configuration removal and content-sized Settings (2026-09-15)

Schema3 removed flag retains history; source removal closes newwork, preserves callbacks, hides source; exactpath readd restoresUUID/history. Full127tests passed withreview findings resolved. Actualpreviousv2runtime upgraded intact and user-requested disabled SMB test source removed through nativeconfirmation, preserving2success records. Settings autoheight546→530pt (authorization section present); diagnosis bottom blank area eliminated. No source/Photosdeletion performed. Backup andscreenshots inwork/SourceRemoval; details docs/release/2026-09-15-source-removal.md.


## Beta3 review fixes — 2026-09-19

Work is isolated on `codex/photosync-beta3-fixes`; it is not merged into `main`. The frozen behavior commit is `5420dce992d2fcb58a5d0a8bd57b5c55dc31af3f`. A clean build-for-testing and 209 unfiltered XCTest tests passed (0 failures, 2.909 seconds; both exit 0) with Xcode 26.6 (17F113) / Swift 6.3.3. The integration review and scoped follow-up re-review returned SPEC/QUALITY PASS with all in-scope findings addressed; the follow-up also passed its 84 affected tests. A scratch Core copy with a single-line continuation gate deterministically reproduces source recovery before stale failure publication (RED skipped/waiting=1, GREEN waiting=0). This proves the deliberately scheduled ordering, not a natural-scheduler reproduction. The production change uses an actor-local pending stamp-failure identity under the existing one-drain invariant; no testing API or scratch instrumentation enters the package.

The new regression coverage exercises importing identity protection and late success, superseded pre-submission reads without storage stop, runtime-tick file retry deadlines, pause/disable/unknown admission, independent directory recovery despite bad files, per-file log deduplication and re-logging after directory recovery, classified UI state, source re-enablement/history, strict dates and fractional-second parsing. Existing unknown/checkpoint/history and unsupported-format protections remain in the full suite. Fixtures use temporary paths and injected gateways; these are not live Photos writes. Logs: `work/beta3-frozen-build.log`, `work/beta3-frozen-tests.log`; report: `.superpowers/sdd/2026-09-19-beta3-review-fixes/final-test-report.md`.

UI evidence is independently frozen at `005bfd7ff41ca5df66495cfdd9489bed69e6abcc`, using copied sources/Core and an unshown NSHostingView with synthetic state. Menus for 0/1/16/30 waiting sources measured 320 × 248/299/626/626 logical points; the 440-point scroll viewport keeps action controls visible. Deferred shows “稍后继续”; active file failures show “正在同步”. Long summaries were checked in light/dark appearances, and disabled/in-progress source controls were rendered in Settings. This is static/offscreen evidence, not native MenuBarExtra interaction, scrolling/keyboard/VoiceOver acceptance or end-to-end source enablement through the GUI. No application activation or global key events occurred. Evidence: `work/Beta3UIEvidence/post-outputs/`, `.superpowers/sdd/2026-09-19-beta3-review-fixes/ui-validation-report.md`.

No beta3 native GUI, real Photos, real network outage, login/notification, macOS 13/14 hardware, Developer ID signing, notarization or Gatekeeper acceptance was performed. The current XCTest binaries warn about macOS 14-linked test libraries; this is a test-host constraint, not a product deployment-target increase or proof of macOS 13 runtime compatibility. Real AVFoundation extraction of fractional-offset video timestamps remains unverified. The production app, sources, database and system settings were untouched.

Release configuration is 0.1.0 / beta3 / build 3, with macOS 13 minimum and Universal arm64/x86_64 required. The package script builds only a committed archive into the new `outputs/releases/0.1.0-beta3/` and must pass actual bundle version/channel, architecture, nested ad-hoc signature, DMG and checksum checks. These packaging checks are separate from repository tests and are recorded in the final release evidence; configuration alone is not evidence of a built artifact. No merge, push, tag or installation is part of this run. Existing schema v3 and historical skipped/import-success records are not migrated, reclassified or repaired.


## Repeatable agent release acceptance — 2026-09-19

The required local gate is now documented as `scripts/validate.py`, invoked automatically by `scripts/package-release.sh` inside the exact committed source archive. It runs full hostless XCTest, synthetic Python tool tests and the tracked continuation regression before normal Universal Release packaging. A build exit alone, selected-test success, missing/zero-test output or an old acceptance record cannot pass the gate.

The continuation harness preserves the legal ordering proven during beta3: retry persistence completes, a later scan records sourceChanged and resolves that file, then the original drain resumes. Only its temporary Core copy receives the await gate; the app sources stay uninstrumented. Its assertions and bounded runner are version controlled so the scenario no longer depends on files retained in work/.

Ordinary beta changes do not require repeating all historical real-Photos tests. Their unchanged system boundaries can reuse the dated evidence above, with current automated regression and package verification. Changed PhotoKit, authorization, media-extraction or platform boundaries require targeted acceptance and explicit reporting of any unverified behavior. This policy does not authorize accessing a personal library or changing system settings.

Current execution results must be taken from the final package's provenance and validation evidence. This section defines the gate; it does not predeclare a future build successful. The original beta3 archive at 1f0047d remains historical and is not retroactively relabeled as having run the new gate.

## 0.2 advanced dedup integration gate (2026-10-05)

The current scope, resource/LFS identities, approved 512 MiB conservative-overlimit policy and evidence are in [0.2 validation](../docs/release/0.2.0-advanced-dedup-validation.md). The canonical entry point now requires the local approved fixture validator, actual-model 33-case content/action regression, a nonempty injected actual runtime graph, complete XCTest/Tools, and both continuation scenarios with GREEN and intended RED. It preserves source-manifest identity and records current compilation cache identity separately from the portable source model package. Missing resources, license, model bytes, reports or passing cases block acceptance.

Real Photos/iCloud, 100k real-library load, older macOS/Intel model execution, keyboard/VoiceOver and release/signing remain distinct unperformed gates. The synthetic runtime test must not be called those system tests. Six user images are local-only and excluded from App resources and public CI. No new personal-library, production-database or system-setting authorization is implied.
