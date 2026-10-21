import XCTest
@testable import PhotoSyncCore

final class SyncStatusPresentationTests: XCTestCase {
    func testLivePhotoProgressIsSeparateAndWorksWithoutSources() {
        var snapshot = EngineSnapshot()
        snapshot.summary = SyncStatusSummary(imported: 9)
        snapshot.livePhotoInventory = .init(phase: .identifying, inventoried: 100, identified: 35, unresolved: 4)
        let p = SyncStatusPresentation(snapshot: snapshot)
        XCTAssertEqual(p.analysis?.title, "正在识别历史 Live Photo")
        XCTAssertTrue(p.analysis?.progressText.contains("100") == true)
        XCTAssertEqual(p.baseSummary, "已导入 9 · 已跳过 0 · 待处理 0")
        XCTAssertEqual(p.globalStatus(enabledSourceIDs: [], authorized: true, hasBlockingError: false), .running)
        snapshot.livePhotoInventory = .init(phase: .completed, inventoried: 100, identified: 96, unresolved: 4)
        let waiting = SyncStatusPresentation(snapshot: snapshot)
        XCTAssertTrue(waiting.summaryNotes.contains("历史识别已完成，部分项目待核实"))
        XCTAssertEqual(waiting.globalStatus(enabledSourceIDs: [], authorized: true, hasBlockingError: false), .waiting)
        snapshot.livePhotoWork.awaitingRetirement = 1
        XCTAssertTrue(SyncStatusPresentation(snapshot: snapshot).summaryNotes.contains("Live Photo 已补齐，旧项目待清理"))
        snapshot.livePhotoWork.unknownMutation = true
        XCTAssertEqual(SyncStatusPresentation(snapshot: snapshot).globalStatus(enabledSourceIDs: [], authorized: true, hasBlockingError: false), .error)
    }

    func testOnlyEnabledUnmountedRootDimsWaitingIcon() {
        let source = RegisteredSource(id: UUID(), url: URL(fileURLWithPath: "/Volumes/Example/Photos"), enabled: true)
        var snapshot = EngineSnapshot()
        let summary = "所在磁盘或网络共享 /Volumes/Example 未挂载；挂载后会自动继续同步。"
        snapshot.waitingSources[source.id] = SourceIssue(summary: summary, detail: "synthetic")
        snapshot.sourceIssueDetails[source.id] = [SourceIssueDetail(id: "root", kind: .sourceAvailability,
            path: source.url.path, summary: summary, stage: nil, detail: "synthetic")]
        func dims(_ status: GlobalStatus = .waiting, sources: [RegisteredSource]? = nil) -> Bool {
            SyncStatusPresentation(snapshot: snapshot).dimsStatusIcon(status: status, sources: sources ?? [source])
        }
        XCTAssertTrue(dims())
        for status in GlobalStatus.allCases where status != .waiting {
            XCTAssertFalse(dims(status), "A mount issue must not hide \(status)")
        }
        let disabled = RegisteredSource(id: source.id, url: source.url, enabled: false)
        XCTAssertFalse(dims(sources: [disabled]))
        XCTAssertFalse(dims(sources: []))
        snapshot.sourceIssueDetails[source.id]?[0].path += "/nested"
        XCTAssertFalse(dims(), "A nested directory diagnosis is not an unmounted source root")
        snapshot.sourceIssueDetails[source.id]?[0].path = source.url.path
        snapshot.sourceIssueDetails[source.id]?[0].kind = .file
        XCTAssertFalse(dims())
        snapshot.sourceIssueDetails[source.id] = []
        XCTAssertFalse(dims(), "Recovery awaiting a traversal is not a current unmounted diagnosis")
    }

    func testOrdinaryWaitingAndOtherDirectoryFailuresStayOpaque() {
        let source = RegisteredSource(id: UUID(), url: URL(fileURLWithPath: "/Volumes/Example/Photos"), enabled: true)
        for summary in ["来源目录无法访问，请检查访问权限。", "来源目录所在的网络共享连接已中断。", "来源目录不可用。"] {
            var snapshot = EngineSnapshot()
            snapshot.waitingSources[source.id] = SourceIssue(summary: summary, detail: "synthetic")
            snapshot.sourceIssueDetails[source.id] = [SourceIssueDetail(id: "root", kind: .sourceAvailability,
                path: source.url.path, summary: summary, stage: nil, detail: "synthetic")]
            XCTAssertFalse(SyncStatusPresentation(snapshot: snapshot).dimsStatusIcon(status: .waiting, sources: [source]))
        }
        var snapshot = EngineSnapshot()
        snapshot.deferredSources = [source.id]
        snapshot.summary = SyncStatusSummary(pending: 1, importing: 1, retryPending: 1)
        snapshot.indexProgress = IndexProgress(state: .waiting, totalsKnown: false, totalAssets: 0,
            readyAssets: 0, totalRepresentations: 0, readyRepresentations: 0, excludedAssets: 0, issue: nil)
        XCTAssertFalse(SyncStatusPresentation(snapshot: snapshot).dimsStatusIcon(status: .waiting, sources: [source]))
    }

    func testAnalysisAssetProgressIgnoresRepresentationAndSourceCounts() {
        var snapshot = EngineSnapshot()
        snapshot.summary = SyncStatusSummary(imported: 800, skipped: 100, pending: 9)
        snapshot.latestScan = ScanProgress(state: .completed, checkedCandidates: 456, newlyImported: 123)
        snapshot.indexProgress = IndexProgress(state: .updating, totalsKnown: true,
            totalAssets: 15702, readyAssets: 2192, totalRepresentations: 45000,
            readyRepresentations: 6789, excludedAssets: 99, issue: "原始分析原因")
        let analysis = SyncStatusPresentation(snapshot: snapshot).analysis
        XCTAssertEqual(analysis?.progressText, "已分析 2192 / 15702 张")
        XCTAssertEqual(analysis?.title, "正在分析图库")
        XCTAssertEqual(analysis?.detail, "原始分析原因")
        XCTAssertEqual(analysis?.fraction ?? -1, 2192.0 / 15702.0, accuracy: 0.000001)
        XCTAssertEqual(SyncDetailsButton(snapshot: snapshot).accessibilityLabel, "查看图库分析与同步详情")
    }

    func testScanDetailRowsKeepExactValuesDatesAndOptionalRows() {
        let start = Date(timeIntervalSince1970: 1_791_878_400)
        var snapshot = EngineSnapshot()
        snapshot.summary = SyncStatusSummary(imported: 900, skipped: 800, pending: 700)
        snapshot.latestScan = ScanProgress(state: .interrupted, checkedCandidates: 86,
            newlyImported: 24, failed: 99, failedFiles: 3, deferred: true,
            startedAt: start, endedAt: start.addingTimeInterval(60))
        snapshot.waitingSources[UUID()] = SourceIssue(summary: "目录等待", detail: "synthetic", kind: .sourceAvailability)
        snapshot.waitingSources[UUID()] = SourceIssue(summary: "文件问题", detail: "synthetic", kind: .file)
        let rows = SyncStatusPresentation(snapshot: snapshot).scanDetailRows
        XCTAssertEqual(rows.map(\.title), ["检查候选", "新增导入", "状态", "本次读取失败", "来源等待恢复", "时间", "开始"])
        XCTAssertEqual(rows.map(\.value), ["86", "24", "稍后继续", "3 个文件", "1 个来源",
            start.addingTimeInterval(60).formatted(date: .abbreviated, time: .shortened),
            start.formatted(date: .abbreviated, time: .shortened)])
        snapshot.latestScan.state = .notStarted
        XCTAssertTrue(SyncStatusPresentation(snapshot: snapshot).scanDetailRows.isEmpty)
    }

    func testUnavailableCountsAreNotPresentedAsZeroAndNoScanIsNotCompleted() {
        var snapshot = EngineSnapshot()
        XCTAssertEqual(SyncStatusPresentation(snapshot: snapshot).summary, "正在读取同步统计…")
        XCTAssertEqual(SyncStatusPresentation(snapshot: snapshot).scan, "尚未扫描")
        snapshot.summaryError = "database unreadable"
        XCTAssertEqual(SyncStatusPresentation(snapshot: snapshot).summary, "同步统计暂不可用")
        XCTAssertNil(SyncStatusPresentation(snapshot: snapshot).recoveryAdvice)
    }
    func testPersistentSummaryAndCurrentScanRemainSeparateAfterRescan() {
        var snapshot = EngineSnapshot()
        snapshot.summary = SyncStatusSummary(imported: 115, skipped: 1)
        snapshot.latestScan = ScanProgress(state: .completed, checkedCandidates: 116, newlyImported: 0)
        let text = SyncStatusPresentation(snapshot: snapshot)
        XCTAssertEqual(text.summary, "已导入 115 · 已跳过 1 · 待处理 0")
        XCTAssertEqual(text.scan, "本次扫描：检查 116 个候选 · 新增导入 0 · 已完成")
        snapshot.latestScan.state = .running
        XCTAssertTrue(SyncStatusPresentation(snapshot: snapshot).scan.contains("进行中"))
        snapshot.latestScan.state = .interrupted
        XCTAssertTrue(SyncStatusPresentation(snapshot: snapshot).scan.contains("已中断"))
        // A round that only waited for a busy reader is not an interruption to report as one.
        snapshot.summary = SyncStatusSummary(imported: 115, skipped: 1)
        snapshot.latestScan = ScanProgress(state: .interrupted, checkedCandidates: 315, newlyImported: 4, deferred: true)
        let deferred = SyncStatusPresentation(snapshot: snapshot).scan
        XCTAssertTrue(deferred.contains("稍后继续"))
        XCTAssertFalse(deferred.contains("已中断"))
        XCTAssertFalse(deferred.contains("本次读取失败"))
    }

    func testCountersAreStandingStateWhileScanFailuresStayThisRoundOnly() {
        var snapshot = EngineSnapshot()
        snapshot.summary = SyncStatusSummary(imported: 10, skipped: 2, pending: 1, importing: 2, retryPending: 3)
        snapshot.latestScan = ScanProgress(state: .interrupted, checkedCandidates: 6, newlyImported: 0, failed: 4, failedFiles: 2)
        snapshot.waitingSources[UUID()] = SourceIssue(summary: "所在磁盘或网络共享 /Volumes/home 未挂载；挂载后会自动继续同步。",
                                                      detail: "The file “home” couldn’t be opened because there is no such file.")
        let text = SyncStatusPresentation(snapshot: snapshot)
        XCTAssertEqual(text.summary, "已导入 10 · 已跳过 2 · 待处理 1 · 待重试 3 · 提交中/待确认 2")
        // No per-round occurrence counter is presented next to standing counters.
        XCTAssertFalse(text.scan.contains("错误"))
        XCTAssertTrue(text.scan.contains("本次读取失败 2 个文件"))
        XCTAssertTrue(text.scan.contains("1 个来源等待恢复"))
    }

    func testUnavailableSourceIsNotPresentedAsFailedFiles() {
        var snapshot = EngineSnapshot()
        snapshot.summary = SyncStatusSummary(imported: 206, skipped: 3)
        snapshot.latestScan = ScanProgress(state: .interrupted, checkedCandidates: 0, newlyImported: 0, failed: 2, failedFiles: 0)
        let missingVolume = SourceIssue(summary: "所在磁盘或网络共享 /Volumes/home 未挂载；挂载后会自动继续同步。",
                                        detail: "The file “home” couldn’t be opened because there is no such file.")
        snapshot.waitingSources[UUID()] = missingVolume
        snapshot.waitingSources[UUID()] = missingVolume
        let text = SyncStatusPresentation(snapshot: snapshot)
        XCTAssertEqual(text.summary, "已导入 206 · 已跳过 3 · 待处理 0")
        XCTAssertFalse(text.scan.contains("本次读取失败"))
        XCTAssertTrue(text.scan.contains("2 个来源等待恢复"))
    }

    func testFileIssueDoesNotInflateUnavailableSourceCount() {
        var snapshot = EngineSnapshot()
        snapshot.summary = SyncStatusSummary(imported: 1)
        snapshot.latestScan = ScanProgress(state: .interrupted, failed: 1, failedFiles: 1)
        snapshot.waitingSources[UUID()] = SourceIssue(
            summary: "文件无法读取，可能已损坏或没有权限。",
            detail: "raw file error",
            kind: .file
        )
        let scan = SyncStatusPresentation(snapshot: snapshot).scan
        XCTAssertTrue(scan.contains("本次读取失败 1 个文件"))
        XCTAssertFalse(scan.contains("来源等待恢复"))
    }

    func testRetiredSourceHistoryIsMentionedInsteadOfLookingLost() {
        var snapshot = EngineSnapshot()
        snapshot.summary = SyncStatusSummary(imported: 0, skipped: 315, retainedImported: 214)
        let text = SyncStatusPresentation(snapshot: snapshot).summary
        XCTAssertTrue(text.contains("已导入 0"))
        XCTAssertTrue(text.contains("另有 214 条历史属已停用或移除的来源"))

        // Nothing retired: no extra wording on the common path.
        snapshot.summary = SyncStatusSummary(imported: 206, skipped: 3)
        XCTAssertEqual(SyncStatusPresentation(snapshot: snapshot).summary, "已导入 206 · 已跳过 3 · 待处理 0")
    }

    func testUnknownAndStaleStatesHaveSpecificPresentation() {
        var snapshot = EngineSnapshot()
        snapshot.summary = SyncStatusSummary(imported: 5, importing: 1)
        snapshot.summaryError = "database failure"
        let text = SyncStatusPresentation(snapshot: snapshot).summary
        XCTAssertTrue(text.contains("已导入 5"))
        XCTAssertTrue(text.contains("提交中/待确认 1"))
        XCTAssertTrue(text.contains("统计暂未更新"))
        snapshot.blockingError = "unrelated failure"
        XCTAssertNil(SyncStatusPresentation(snapshot: snapshot).recoveryAdvice)
        snapshot.recoveryHint = .uncertainSubmission(message: "unknown commit")
        XCTAssertNotNil(SyncStatusPresentation(snapshot: snapshot).recoveryAdvice)
        XCTAssertFalse(SyncStatusPresentation(snapshot: snapshot).recoveryAdvice!.contains("重新启动"))
        snapshot.recoveryHint = .checkpointFailure(message: "checkpoint failed")
        XCTAssertTrue(SyncStatusPresentation(snapshot: snapshot).recoveryAdvice!.contains("重新启动"))
    }

    func testDeferredRoundIsNotCompleted() {
        let id = UUID()
        var snapshot = EngineSnapshot()
        snapshot.summary = SyncStatusSummary()
        snapshot.latestScan = ScanProgress(state: .interrupted, deferred: true)
        snapshot.deferredSources = [id]
        let view = SyncStatusPresentation(snapshot: snapshot)

        let status = view.globalStatus(enabledSourceIDs: [id], authorized: true, hasBlockingError: false)

        XCTAssertEqual(status, .waiting)
        XCTAssertEqual(view.statusDescription(for: status, enabledSourceIDs: [id]), "稍后继续")
    }

    func testFileIssueDoesNotHideHealthyWork() {
        let id = UUID()
        var snapshot = EngineSnapshot()
        snapshot.activeWork = true
        snapshot.waitingSources[id] = SourceIssue(summary: "文件无法读取。", detail: "fixture", kind: .file)
        let view = SyncStatusPresentation(snapshot: snapshot)

        XCTAssertEqual(view.globalStatus(enabledSourceIDs: [id], authorized: true, hasBlockingError: false), .running)
    }

    func testNoEnabledSourcesIsUnconfigured() {
        let view = SyncStatusPresentation(snapshot: EngineSnapshot())
        let status = view.globalStatus(enabledSourceIDs: [], authorized: true, hasBlockingError: false)

        XCTAssertEqual(status, .unconfigured)
        XCTAssertEqual(view.statusDescription(for: status, enabledSourceIDs: []), "未配置来源")
    }

    func testBlockingErrorsOutrankPauseAndDoNotUsePauseDescription() {
        let id = UUID()
        var snapshot = EngineSnapshot()
        snapshot.isPaused = true
        snapshot.activeWork = true
        let view = SyncStatusPresentation(snapshot: snapshot)

        let blocked = view.globalStatus(enabledSourceIDs: [id], authorized: true, hasBlockingError: true)
        let unauthorized = view.globalStatus(enabledSourceIDs: [id], authorized: false, hasBlockingError: false)

        XCTAssertEqual(blocked, .error)
        XCTAssertEqual(unauthorized, .error)
        XCTAssertEqual(view.statusDescription(for: blocked, enabledSourceIDs: [id]), "同步异常")
    }

    func testPausedWorkDescribesPendingStop() {
        let id = UUID()
        var snapshot = EngineSnapshot()
        snapshot.isPaused = true
        snapshot.activeWork = true
        let view = SyncStatusPresentation(snapshot: snapshot)

        let status = view.globalStatus(enabledSourceIDs: [id], authorized: true, hasBlockingError: false)

        XCTAssertEqual(status, .paused)
        XCTAssertEqual(view.statusDescription(for: status, enabledSourceIDs: [id]), "正在暂停，等待当前操作返回")
    }

    func testEnabledSourceAvailabilityPrecedesRunningWork() {
        let id = UUID()
        var snapshot = EngineSnapshot()
        snapshot.activeWork = true
        snapshot.waitingSources[id] = SourceIssue(summary: "来源目录不可用。", detail: "fixture")
        let view = SyncStatusPresentation(snapshot: snapshot)

        let status = view.globalStatus(enabledSourceIDs: [id], authorized: true, hasBlockingError: false)

        XCTAssertEqual(status, .waiting)
        XCTAssertEqual(view.statusDescription(for: status, enabledSourceIDs: [id]), "等待恢复")
    }

    func testDisabledSourceIssueDoesNotAffectCompletedStatus() {
        let enabledID = UUID()
        let disabledID = UUID()
        var snapshot = EngineSnapshot()
        snapshot.summary = SyncStatusSummary()
        snapshot.latestScan = ScanProgress(state: .completed)
        snapshot.waitingSources[disabledID] = SourceIssue(summary: "来源目录不可用。", detail: "fixture")
        snapshot.sourceFileIssueCounts[disabledID] = 1
        let view = SyncStatusPresentation(snapshot: snapshot)

        let status = view.globalStatus(enabledSourceIDs: [enabledID], authorized: true, hasBlockingError: false)

        XCTAssertEqual(status, .completed)
        XCTAssertEqual(view.statusDescription(for: status, enabledSourceIDs: [enabledID]), "已完成")
    }

    func testDisabledDeferredSourceDoesNotHideHealthyWork() {
        let enabledID = UUID()
        let disabledID = UUID()
        var snapshot = EngineSnapshot()
        snapshot.activeWork = true
        snapshot.latestScan = ScanProgress(state: .interrupted, deferred: true)
        snapshot.deferredSources = [disabledID]
        let view = SyncStatusPresentation(snapshot: snapshot)

        let status = view.globalStatus(enabledSourceIDs: [enabledID], authorized: true, hasBlockingError: false)

        XCTAssertEqual(status, .running)
        XCTAssertEqual(view.statusDescription(for: status, enabledSourceIDs: [enabledID]), "正在同步")
    }

    func testUnknownAndInterruptedRoundsWaitForScan() {
        let id = UUID()
        var snapshot = EngineSnapshot()
        let view = SyncStatusPresentation(snapshot: snapshot)

        let unknown = view.globalStatus(enabledSourceIDs: [id], authorized: true, hasBlockingError: false)

        XCTAssertEqual(unknown, .waiting)
        XCTAssertEqual(view.statusDescription(for: unknown, enabledSourceIDs: [id]), "等待扫描")

        snapshot.latestScan = ScanProgress(state: .interrupted)
        let interrupted = SyncStatusPresentation(snapshot: snapshot)
        let status = interrupted.globalStatus(enabledSourceIDs: [id], authorized: true, hasBlockingError: false)

        XCTAssertEqual(status, .waiting)
        XCTAssertEqual(interrupted.statusDescription(for: status, enabledSourceIDs: [id]), "等待扫描")
    }

    func testQueuedWorkUsesSpecificWaitingDescription() {
        let id = UUID()
        let cases: [(name: String, summary: SyncStatusSummary, description: String)] = [
            ("importing", SyncStatusSummary(importing: 1), "等待核对"),
            ("retry only", SyncStatusSummary(retryPending: 1), "等待重试"),
            ("new pending", SyncStatusSummary(pending: 1), "等待中"),
            ("mixed pending", SyncStatusSummary(pending: 1, retryPending: 1), "等待中")
        ]

        for item in cases {
            var snapshot = EngineSnapshot()
            snapshot.summary = item.summary
            let view = SyncStatusPresentation(snapshot: snapshot)
            let status = view.globalStatus(enabledSourceIDs: [id], authorized: true, hasBlockingError: false)

            XCTAssertEqual(status, .waiting, item.name)
            XCTAssertEqual(view.statusDescription(for: status, enabledSourceIDs: [id]), item.description, item.name)
        }
    }

    func testIdleFileAndSubmissionIssuesNeedAttention() {
        let id = UUID()
        let cases: [(name: String, kind: SourceIssueKind)] = [
            ("file", .file),
            ("submission", .submission)
        ]

        for item in cases {
            var snapshot = EngineSnapshot()
            snapshot.summary = SyncStatusSummary()
            snapshot.waitingSources[id] = SourceIssue(summary: "需要处理。", detail: "fixture", kind: item.kind)
            let view = SyncStatusPresentation(snapshot: snapshot)
            let status = view.globalStatus(enabledSourceIDs: [id], authorized: true, hasBlockingError: false)

            XCTAssertEqual(status, .error, item.name)
            XCTAssertEqual(view.statusDescription(for: status, enabledSourceIDs: [id]), "同步异常", item.name)
        }
    }

    func testEnabledFileIssueCountNeedsAttention() {
        let id = UUID()
        var snapshot = EngineSnapshot()
        snapshot.summary = SyncStatusSummary()
        snapshot.sourceFileIssueCounts[id] = 1
        let view = SyncStatusPresentation(snapshot: snapshot)

        let status = view.globalStatus(enabledSourceIDs: [id], authorized: true, hasBlockingError: false)

        XCTAssertEqual(status, .error)
        XCTAssertEqual(view.statusDescription(for: status, enabledSourceIDs: [id]), "同步异常")
    }

    func testCompletedRoundWithoutOutstandingWorkIsCompleted() {
        let id = UUID()
        var snapshot = EngineSnapshot()
        snapshot.summary = SyncStatusSummary(imported: 1)
        snapshot.latestScan = ScanProgress(state: .completed)
        let view = SyncStatusPresentation(snapshot: snapshot)

        let status = view.globalStatus(enabledSourceIDs: [id], authorized: true, hasBlockingError: false)

        XCTAssertEqual(status, .completed)
        XCTAssertEqual(view.statusDescription(for: status, enabledSourceIDs: [id]), "已完成")
    }

}

extension SyncStatusPresentationTests {
    // Analysis remains visible, but must not replace the headline explaining an unavailable source.
    func testUnavailableSourceHeadlineWinsWhileAnalysisVisible() {
        let id = UUID()
        for state in [IndexState.preparing, .updating, .waiting] {
            var snapshot = EngineSnapshot()
            snapshot.indexProgress = IndexProgress(state: state, totalsKnown: true,
                totalAssets: 2, readyAssets: 1, totalRepresentations: 3,
                readyRepresentations: 1, excludedAssets: 0, issue: nil)
            snapshot.waitingSources[id] = SourceIssue(summary: "来源目录暂时不可用。",
                detail: "synthetic unavailable source", kind: .sourceAvailability)
            let p = SyncStatusPresentation(snapshot: snapshot)
            let status = p.globalStatus(enabledSourceIDs: [id], authorized: true, hasBlockingError: false)
            XCTAssertEqual(status, .waiting, state.rawValue)
            XCTAssertEqual(p.statusDescription(for: status, enabledSourceIDs: [id]), "等待恢复", state.rawValue)
            XCTAssertNotNil(p.analysis, state.rawValue)

            snapshot.isPaused = true
            let paused = SyncStatusPresentation(snapshot: snapshot)
            let pausedStatus = paused.globalStatus(enabledSourceIDs: [id], authorized: true, hasBlockingError: false)
            XCTAssertEqual(pausedStatus, .paused)
            XCTAssertEqual(paused.statusDescription(for: pausedStatus, enabledSourceIDs: [id]), "已暂停")
            for (authorized, blocked) in [(false, false), (true, true)] {
                let error = p.globalStatus(enabledSourceIDs: [id], authorized: authorized, hasBlockingError: blocked)
                XCTAssertEqual(error, .error)
                XCTAssertEqual(p.statusDescription(for: error, enabledSourceIDs: [id]), "同步异常")
            }
            let unconfigured = p.globalStatus(enabledSourceIDs: [], authorized: true, hasBlockingError: false)
            XCTAssertEqual(unconfigured, .unconfigured)
            XCTAssertEqual(p.statusDescription(for: unconfigured, enabledSourceIDs: []), "未配置来源")

            snapshot.indexProgress = IndexProgress(state: .ready, totalsKnown: true,
                totalAssets: 2, readyAssets: 2, totalRepresentations: 3,
                readyRepresentations: 3, excludedAssets: 0, issue: nil)
            XCTAssertNil(SyncStatusPresentation(snapshot: snapshot).analysis)
        }
    }

    func testLibraryAnalysisVisibility() {
        for state in [IndexState.preparing, .updating, .waiting, .paused, .ready] {
            var snapshot = EngineSnapshot()
            snapshot.indexProgress = IndexProgress(state: state, totalsKnown: true,
                totalAssets: 100000, readyAssets: 50000, totalRepresentations: 200000,
                readyRepresentations: 90000, excludedAssets: 0, issue: nil)
            let p = SyncStatusPresentation(snapshot: snapshot)
            XCTAssertEqual(p.analysis != nil, state != .ready)
            snapshot.isPaused = true
            XCTAssertEqual(SyncStatusPresentation(snapshot: snapshot).analysis != nil, state != .ready)
        }
    }

    func testIndexProgressCountsAssetsAndRepresentationsSeparately() {
        var snapshot = EngineSnapshot()
        snapshot.indexProgress = IndexProgress(state: .updating, totalsKnown: true,
            totalAssets: 100000, readyAssets: 50000, totalRepresentations: 200000,
            readyRepresentations: 90000, excludedAssets: 0, issue: nil)
        XCTAssertEqual(SyncStatusPresentation(snapshot: snapshot).analysis?.progressText, "已分析 50000 / 100000 张")
        XCTAssertEqual(SyncStatusPresentation(snapshot: snapshot).analysis?.fraction, 0.5)
        snapshot.indexProgress = IndexProgress(state: .preparing, totalsKnown: false,
            totalAssets: 0, readyAssets: 0, totalRepresentations: 0,
            readyRepresentations: 0, excludedAssets: 0, issue: nil)
        XCTAssertNil(SyncStatusPresentation(snapshot: snapshot).analysis?.fraction)
        XCTAssertEqual(SyncStatusPresentation(snapshot: snapshot).analysis?.progressText, "正在读取图库…")
    }

    func testWaitingIndexIsNotFinishedOrFileError() {
        var snapshot = EngineSnapshot()
        snapshot.latestScan = ScanProgress(state: .completed)
        snapshot.indexProgress = IndexProgress(state: .waiting, totalsKnown: true,
            totalAssets: 2, readyAssets: 1, totalRepresentations: 3,
            readyRepresentations: 1, excludedAssets: 0, issue: "正在等待 iCloud 图像，连接恢复后自动继续")
        let p = SyncStatusPresentation(snapshot: snapshot)
        XCTAssertEqual(p.globalStatus(enabledSourceIDs: [UUID()], authorized: true, hasBlockingError: false), .waiting)
        XCTAssertEqual(p.analysis?.detail, "正在等待 iCloud 图像，连接恢复后自动继续")
        XCTAssertEqual(snapshot.latestScan.failedFiles, 0)
    }
}
