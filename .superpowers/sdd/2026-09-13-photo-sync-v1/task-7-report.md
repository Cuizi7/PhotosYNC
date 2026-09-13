# Task 7 report

Implemented native MenuBarExtra window and Settings with AppModel, actor-owned SyncRuntime, directory selection, disable-with-history, explicit Photos authorization, login service actual-status refresh, Finder logs, counters, pause-in-flight text, and required six status symbols. Info.plist declares LSUIElement and Photos purpose; sandbox explicitly disabled. No automatic permission request or login registration on launch.

Runtime owns exactly one gateway and engine, one shared ReadExecutor keyed by configured source UUIDs, one ScanSchedule, and one scan task. Startup/configuration/wake/manual and fixed-30-minute cadence use schedule admission. Source retry backoff advances once after an attempted scan, not on UI polls; waiting state aggregates across enabled sources. Logger failure callback reports to UI. Minimal engine integrations: public snapshot initializer and setPaused without starting a scan (existing resume contract retained).

Verification: expected red compile for missing GlobalStatus; final PhotoSync build-for-testing successful for arm64/x86_64 with macOS 14 deployment target. Direct xctest: 85 passed, 0 failures. Includes status ordering, host symbol lookup, and logging append failure callback. git diff --check clean. Logs: work/task7-red.log, task7-green.log, task7-xctest.log.

Manual: launched only --demo (no runtime/store/gateway); dark unconfigured and light synthetic-error/long-path settings screenshots inspected. Fixed clipping by making settings scroll. Screenshot final /tmp/codex-shot-2026-09-13_22-37-56-w1997.png. CUA kernel failed twice, so screenshot fallback used. Quit request succeeded. No Photos permission dialog, import, source addition, login registration, or real library changes were performed.

Not verified: actual macOS 14 host (host 26.6.2; only deployment-target compile and host SF Symbol lookup), VoiceOver/keyboard flows, menu interactions, actual login item registration, real permission flow, mount recovery timing end-to-end, real Photos imports. No runtime injection tests added; schedule and engine behavior covered separately by existing tests. These remain manual/integration acceptance work, not claimed passing.

Self-review: all additions map to Task7 UI/orchestration; no source copying/export, destructive Photos operation, or gateway recreation. Registered disabled paths already retain overlap exclusion, so no registry edit needed. GlobalStatus kept under existing Sync group for minimal project wiring.
