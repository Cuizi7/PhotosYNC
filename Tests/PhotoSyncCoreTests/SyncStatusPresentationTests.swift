import XCTest
@testable import PhotoSyncCore

final class SyncStatusPresentationTests: XCTestCase {
    func testActiveLivePhotoTaskExplainsConcurrentAttentionInsteadOfGenericPurpose() throws {
        for inventoryHold in [true, false] {
            var s = EngineSnapshot()
            s.summary = .init(); s.latestScan = .init(state: .completed)
            let issue = SourceIssue(summary: "部分项目需要重新核实配对信息。", detail: "synthetic", kind: .file)
            if inventoryHold {
                s.livePhotoInventory = .init(phase: .identifying, inventoried: 3, identified: 1, unresolved: 1, pending: 1, requiresAttention: 1)
                s.livePhotoIssue = issue
            } else {
                s.livePhotoWork.activeGroups = 1
                s.livePhotoWork.requiresAttentionGroups = 1
                s.livePhotoWork.issue = issue
            }
            for activity in [LivePhotoActivity.queued(.identification), .working(.completion)] {
                s.livePhotoActivities = [activity]
                let p = SyncStatusPresentation(snapshot: s)
                let row = try XCTUnwrap(p.progressRows.first)
                XCTAssertTrue(row.active, "Healthy work continues beside a held item")
                XCTAssertEqual(row.title, "Live Photo 需处理")
                XCTAssertEqual(row.explanation, issue.summary)
                XCTAssertEqual(p.statusReason(for: .error, enabledSourceIDs: []), "部分项目的 Live Photo 配对需要处理，请查看任务说明。")
            }
        }
    }
    func testPersistentLivePhotoAttentionSurvivesHealthyActivityAndPause() {
        var s = EngineSnapshot()
        s.summary = .init(); s.latestScan = .init(state: .completed)
        s.livePhotoInventory = .init(phase: .completed, inventoried: 100, identified: 10, unresolved: 90, retryWaiting: 89, requiresAttention: 1)
        s.livePhotoWork.requiresAttentionGroups = 1
        for paused in [false, true] {
            s.isPaused = paused
            for activity in [LivePhotoActivity.queued(.identification), .working(.completion), .waiting(nextRetryAt: nil), .draining] {
                s.livePhotoActivities = [activity]
                let p = SyncStatusPresentation(snapshot: s)
                let status = p.globalStatus(enabledSourceIDs: [], authorized: true, hasBlockingError: false)
                XCTAssertEqual(p.statusReason(for: status, enabledSourceIDs: []), "部分项目的 Live Photo 配对需要处理，请查看任务说明。")
            }
        }
        s.isPaused = false; s.livePhotoWork.requiresAttentionGroups = 0
        s.livePhotoInventory = .init(phase: .completed, inventoried: 100, identified: 10, unresolved: 90, retryWaiting: 90)
        s.livePhotoActivities = [.working(.identification)]
        let resolved = SyncStatusPresentation(snapshot: s)
        XCTAssertNil(resolved.statusReason(for: .preparing, enabledSourceIDs: []))
    }
    func testTaskHoverUsesApprovedSingleBodyWithoutSupplementalLines() throws {
        var s = EngineSnapshot()
        s.indexActivity = .working
        s.indexProgress = .init(state: .updating, totalsKnown: false, totalAssets: 0, readyAssets: 15716,
            totalRepresentations: 0, readyRepresentations: 15716, excludedAssets: 0, issue: nil)
        s.livePhotoInventory = .init(phase: .identifying, inventoried: 16222, identified: 45, pending: 16177)
        s.livePhotoActivities = [.working(.identification)]
        var rows = SyncStatusPresentation(snapshot: s).progressRows
        XCTAssertEqual(rows.map(\.countText), ["已分析 15716 张", "45 / 16222 项"])
        XCTAssertEqual(rows.first?.explanation, "分析照片内容，帮助避免重复导入。")
        XCTAssertEqual(rows.last?.explanation, "识别照片与视频的配对关系，找到另一半后自动补齐。")
        s.livePhotoInventory = .init(phase: .completed, inventoried: 16222, identified: 16222)
        s.livePhotoActivities = [.working(.completion)]
        rows = SyncStatusPresentation(snapshot: s).progressRows
        XCTAssertNil(rows.last?.fraction); XCTAssertNil(rows.last?.countText)
        XCTAssertEqual(rows.last?.explanation, "正在补齐包含动态画面和声音的 Live Photo。")
        s.isPaused = true; s.indexActivity = .waiting; s.livePhotoActivities = [.waiting(nextRetryAt: nil)]
        rows = SyncStatusPresentation(snapshot: s).progressRows
        XCTAssertEqual(rows.first?.title, "已暂停"); XCTAssertEqual(rows.first?.explanation, "已完成的结果会保留。")
        XCTAssertEqual(rows.map(\.taskTitle), ["视觉索引", "Live Photo 配对"], "Paused hover titles must not erase the task identity")
        s.isPaused = false; s.livePhotoWork.unknownMutation = true
        rows = SyncStatusPresentation(snapshot: s).progressRows
        XCTAssertEqual(rows.last?.title, "等待“照片”确认")
        XCTAssertEqual(rows.last?.explanation, "保存结果尚未确认，新的保存已暂停。")
        s.livePhotoWork.unknownMutation = false
        s.livePhotoInventory = .init(phase: .completed, inventoried: 100, identified: 90, unresolved: 10, retryWaiting: 10)
        rows = SyncStatusPresentation(snapshot: s).progressRows
        XCTAssertEqual(rows.last?.title, "Live Photo 等待恢复")
        XCTAssertEqual(rows.last?.explanation, "部分原文件暂时无法读取，稍后自动重试。")
        s.indexProgress = .init(state: .waiting, totalsKnown: true, totalAssets: 100, readyAssets: 97,
            totalRepresentations: 100, readyRepresentations: 97, readErrorRepresentations: 3, excludedAssets: 0, issue: nil, requiresAttentionAssets: 3)
        rows = SyncStatusPresentation(snapshot: s).progressRows
        XCTAssertEqual(rows.first?.title, "需要提高内存上限")
        XCTAssertEqual(rows.first?.explanation, "3 张照片超出图像处理内存上限。")
    }

    func testNormalLivePhotoSkipsFinishWithoutTaskButPreserveIndependentSourceIssue() throws {
        var s = EngineSnapshot(); let sourceID = UUID()
        s.summary = .init(); s.latestScan = .init(state: .completed)
        s.livePhotoInventory = .init(phase: .completed, inventoried: 100, identified: 95, resourceLimited: 5, skipped: 5)
        s.livePhotoActivities = [.idle]
        var presentation = SyncStatusPresentation(snapshot: s)
        XCTAssertTrue(presentation.progressRows.isEmpty)
        XCTAssertNil(presentation.statusReason(for: .completed, enabledSourceIDs: [sourceID]))
        XCTAssertEqual(presentation.globalStatus(enabledSourceIDs: [sourceID], authorized: true, hasBlockingError: false), .completed)
        s.waitingSources[sourceID] = SourceIssue(summary: "来源目录不可用", detail: "fixture", kind: .sourceAvailability)
        presentation = SyncStatusPresentation(snapshot: s)
        XCTAssertTrue(presentation.progressRows.isEmpty)
        XCTAssertEqual(presentation.globalStatus(enabledSourceIDs: [sourceID], authorized: true, hasBlockingError: false), .waiting)
        s.livePhotoInventory = .init(phase: .identifying, inventoried: 100, identified: 80, pending: 15, resourceLimited: 5, skipped: 5)
        s.livePhotoActivities = [.working(.identification)]
        let row = try XCTUnwrap(SyncStatusPresentation(snapshot: s).progressRows.first)
        XCTAssertEqual(row.countText, "85 / 100 项"); XCTAssertEqual(row.fraction, 0.85)
    }

    func testLivePhotoOnlyQueuedDiscoveryDoesNotDemandSourceConfiguration() {
        var s = EngineSnapshot()
        s.summary = .init(); s.latestScan = .init(state: .completed)
        s.livePhotoInventory = .init(phase: .completed, inventoried: 10, identified: 10)
        for (activity, expected) in [(LivePhotoActivity.working(.identification), GlobalStatus.preparing),
                                    (.queued(.identification), .preparing), (.queued(.completion), .running)] {
            s.livePhotoActivities = [activity]
            let p = SyncStatusPresentation(snapshot: s)
            XCTAssertEqual(p.globalStatus(enabledSourceIDs: [], authorized: true, hasBlockingError: false), expected)
            XCTAssertNil(p.statusReason(for: expected, enabledSourceIDs: []))
            XCTAssertTrue(p.progressRows.allSatisfy(\.active))
        }
    }

    func testNormalBatchGapsKeepBothTaskRowsAndPreparingHeadline() {
        let id = UUID(); var s = EngineSnapshot()
        s.summary = .init(pending: 1)
        s.indexProgress = .init(state: .updating, totalsKnown: true, totalAssets: 16000, readyAssets: 15716, totalRepresentations: 16000, readyRepresentations: 15716, excludedAssets: 0, issue: nil)
        s.livePhotoInventory = .init(phase: .identifying, inventoried: 16222, identified: 45, pending: 16177)
        for (index, live) in [(IndexActivity.working, LivePhotoActivity.working(.identification)), (.working, .queued(.identification)), (.queued, .working(.identification)), (.queued, .queued(.identification))] {
            s.indexActivity = index; s.livePhotoActivities = [live]
            let p = SyncStatusPresentation(snapshot: s)
            XCTAssertEqual(p.progressRows.map(\.id), ["visualIndex", "livePhoto"])
            XCTAssertTrue(p.progressRows.allSatisfy(\.active))
            XCTAssertEqual(p.globalStatus(enabledSourceIDs: [id], authorized: true, hasBlockingError: false), .preparing)
        }
        s.indexActivity = .waiting; s.livePhotoActivities = [.waiting(nextRetryAt: Date())]
        let waiting = SyncStatusPresentation(snapshot: s)
        XCTAssertEqual(waiting.globalStatus(enabledSourceIDs: [id], authorized: true, hasBlockingError: false), .waiting)
        XCTAssertFalse(waiting.progressRows.contains(where: \.active))
    }
    func testUnfinishedTaskRowsPersistAcrossWaitingAndPause() {
        var s = EngineSnapshot()
        s.indexProgress = .init(state: .waiting, totalsKnown: true, totalAssets: 100, readyAssets: 90, totalRepresentations: 100, readyRepresentations: 90, excludedAssets: 0, issue: "稍后重试")
        s.indexActivity = .waiting
        s.livePhotoInventory = .init(phase: .completed, inventoried: 200, identified: 100, unresolved: 100, retryWaiting: 100)
        s.livePhotoActivities = [.waiting(nextRetryAt: Date())]
        for paused in [false, true] {
            s.isPaused = paused
            let p = SyncStatusPresentation(snapshot: s)
            XCTAssertEqual(p.progressRows.map(\.id), ["visualIndex", "livePhoto"])
            XCTAssertEqual(p.progressRows.first?.fraction, 0.9)
        }
    }
    func testReadyPublicationWithHeldAssetsStillNeedsAttention() {
        let id = UUID(); var s = EngineSnapshot()
        s.summary = .init(imported: 1); s.latestScan = .init(state: .completed)
        s.indexProgress = .init(state: .ready, totalsKnown: true, totalAssets: 10, readyAssets: 7, totalRepresentations: 10, readyRepresentations: 7, readErrorRepresentations: 3, excludedAssets: 0, issue: nil, requiresAttentionAssets: 3)
        let p = SyncStatusPresentation(snapshot: s)
        XCTAssertEqual(p.globalStatus(enabledSourceIDs: [id], authorized: true, hasBlockingError: false), .error)
        XCTAssertEqual(p.progressRows.map(\.id), ["visualIndex"])
    }
    func testOwnedLivePhotoImportsDoNotHideOtherUnknownImports() {
        var snapshot = EngineSnapshot()
        snapshot.summary = SyncStatusSummary(importing: 2)
        snapshot.livePhotoWork.ownedImportingFiles = 2
        snapshot.livePhotoActivities = [.working(.completion)]
        XCTAssertFalse(SyncStatusPresentation(snapshot: snapshot).unknownMutation)
        snapshot.summary = SyncStatusSummary(importing: 3)
        XCTAssertTrue(SyncStatusPresentation(snapshot: snapshot).unknownMutation)
        snapshot.summary = SyncStatusSummary(importing: 2)
        snapshot.unknownSubmissionBlock = true
        XCTAssertTrue(SyncStatusPresentation(snapshot: snapshot).unknownMutation)
    }
    func testApprovedSixHeadlinesAndUnknownMutationPriority() {
        XCTAssertEqual(Set(GlobalStatus.allCases.map(\.description)), Set(["正在准备", "正在同步", "等待恢复", "已暂停", "需要处理", "同步完成"]))
        let id = UUID()
        var snapshot = EngineSnapshot()
        snapshot.summary = SyncStatusSummary(imported: 1)
        snapshot.livePhotoWork.unknownMutation = true
        snapshot.sourceActivities[id] = .submitting
        let p = SyncStatusPresentation(snapshot: snapshot)
        XCTAssertEqual(p.globalStatus(enabledSourceIDs: [id], authorized: true, hasBlockingError: false), .waiting)
    }
    func testLivePhotoFailureCannotIncreaseProcessedFraction() {
        var snapshot = EngineSnapshot()
        snapshot.livePhotoInventory = .init(phase: .identifying, inventoried: 16222, identified: 2, unresolved: 626, retryWaiting: 626)
        snapshot.livePhotoActivities = [.working(.identification)]
        let p = SyncStatusPresentation(snapshot: snapshot)
        XCTAssertEqual(p.progressRows.first?.fraction ?? -1, 2.0 / 16222, accuracy: 0.000001)
    }
    func testLivePhotoProgressIsSeparateAndWorksWithoutSources() {
        var snapshot = EngineSnapshot()
        snapshot.summary = SyncStatusSummary(imported: 9)
        snapshot.livePhotoInventory = .init(phase: .identifying, inventoried: 100, identified: 35, unresolved: 4, pending: 61, retryWaiting: 4)
        snapshot.livePhotoActivities = [.working(.identification)]
        let p = SyncStatusPresentation(snapshot: snapshot)
        XCTAssertEqual(p.progressRows.first?.subtitle, "正在配对 Live Photo")
        XCTAssertEqual(p.baseSummary, "已导入 9 · 已跳过 0 · 待处理 0")
        XCTAssertEqual(p.globalStatus(enabledSourceIDs: [], authorized: true, hasBlockingError: false), .preparing)
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
        snapshot.indexActivity = .working
        let analysis = SyncStatusPresentation(snapshot: snapshot).progressRows.first
        XCTAssertEqual(analysis?.progressText, "已分析 2192 / 15702 张")
        XCTAssertEqual(analysis?.subtitle, "正在建立视觉索引")
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

    func testSixStateProjectionAcrossConcurrentAndIdleWork() {
        let id = UUID(), disabled = UUID()
        func check(_ name: String, _ expected: GlobalStatus, sources: Set<UUID>? = nil, authorized: Bool = true, blocked: Bool = false, edit: (inout EngineSnapshot) -> Void) {
            var snapshot = EngineSnapshot()
            snapshot.summary = SyncStatusSummary(imported: 1)
            snapshot.latestScan.state = .completed
            edit(&snapshot)
            let p = SyncStatusPresentation(snapshot: snapshot)
            let result = p.globalStatus(enabledSourceIDs: sources ?? [id], authorized: authorized, hasBlockingError: blocked)
            XCTAssertEqual(result, expected, name)
            XCTAssertEqual(p.statusDescription(for: result, enabledSourceIDs: sources ?? [id]), expected.description, name)
        }
        check("idle between scans", .completed) { _ in }
        check("pause", .paused) { $0.isPaused = true; $0.sourceActivities[id] = .submitting }
        check("permission outranks pause", .error, authorized: false) { $0.isPaused = true }
        check("global failure outranks pause", .error, blocked: true) { $0.isPaused = true }
        check("healthy source progresses beside offline source", .running) { $0.sourceActivities[id] = .scanning; $0.waitingSources[id] = SourceIssue(summary: "离线", detail: "fixture") }
        check("index works beside offline source", .preparing) { $0.indexActivity = .working; $0.waitingSources[id] = SourceIssue(summary: "离线", detail: "fixture") }
        check("sync beside preparation", .running) { $0.indexActivity = .working; $0.sourceActivities[id] = .submitting }
        check("unknown mutation outranks work", .waiting) { $0.livePhotoWork.unknownMutation = true; $0.sourceActivities[id] = .submitting; $0.indexActivity = .working }
        check("unknown without specialized hint", .waiting) { $0.unknownSubmissionBlock = true; $0.indexActivity = .working }
        check("ordinary unknown", .waiting) { $0.recoveryHint = .uncertainSubmission(message: "fixture"); $0.indexActivity = .working }
        check("pause before unknown", .paused) { $0.isPaused = true; $0.livePhotoWork.unknownMutation = true }
        check("queued even after one-time completion", .waiting, sources: []) { $0.livePhotoInventory = .init(phase: .completed, inventoried: 3, identified: 2, pending: 1) }
        check("automatic unresolved", .waiting, sources: []) { $0.livePhotoInventory = .init(phase: .completed, inventoried: 3, identified: 2, unresolved: 1, retryWaiting: 1) }
        check("held unresolved", .error, sources: []) { $0.livePhotoInventory = .init(phase: .completed, inventoried: 3, identified: 2, unresolved: 1, requiresAttention: 1) }
        check("unconfirmed verification", .waiting, sources: []) { $0.livePhotoWork.awaitingVerification = 1 }
        check("held group", .error, sources: []) { $0.livePhotoWork.requiresAttentionGroups = 1 }
        check("index awaiting resources", .waiting) { $0.indexActivity = .waiting; $0.indexProgress = .init(state: .waiting, totalsKnown: false, totalAssets: 0, readyAssets: 0, totalRepresentations: 0, readyRepresentations: 0, excludedAssets: 0, issue: nil) }
        check("activeWork alone does not prove sync", .waiting) { $0.activeWork = true; $0.summary = .init(pending: 1) }
        check("photos-only preparation", .preparing, sources: []) { $0.livePhotoInventory = .init(phase: .identifying, inventoried: 1, pending: 1); $0.livePhotoActivities = [.working(.identification)] }
        check("photos-only completion", .running, sources: []) { $0.livePhotoWork.activeGroups = 1; $0.livePhotoActivities = [.working(.completion)] }
        check("missing configuration after photos-only work ends", .error, sources: []) { $0.livePhotoInventory = .init(phase: .completed) }
        check("disabled source issue ignored", .completed) { $0.waitingSources[disabled] = SourceIssue(summary: "离线", detail: "fixture"); $0.sourceFileIssueCounts[disabled] = 1 }
        check("pending new source file", .waiting) { $0.summary = .init(pending: 1) }
        check("source retry", .waiting) { $0.summary = .init(retryPending: 1) }
        check("deferred physical work", .waiting) { $0.deferredSources = [id] }
        check("local issue while healthy work continues", .running) { $0.sourceFileIssueCounts[id] = 1; $0.sourceActivities[id] = .scanning }
        check("only local manual issue", .error) { $0.sourceFileIssueCounts[id] = 1 }
        let initial = SyncStatusPresentation(snapshot: EngineSnapshot())
        XCTAssertEqual(initial.globalStatus(enabledSourceIDs: [], authorized: true, hasBlockingError: false), .preparing)
    }
    func testReasonsAreActionableAndSeparateFromHeadlines() {
        var snapshot = EngineSnapshot()
        snapshot.summary = .init()
        var p = SyncStatusPresentation(snapshot: snapshot)
        XCTAssertEqual(p.statusReason(for: .error, enabledSourceIDs: []), "请添加或启用来源目录")
        snapshot.livePhotoWork.unknownMutation = true
        p = SyncStatusPresentation(snapshot: snapshot)
        XCTAssertEqual(p.statusReason(for: .waiting, enabledSourceIDs: []), "等待‘照片’确认结果，新的保存已暂停")
    }
    func testIndependentProgressAndUnknownTotals() {
        var snapshot = EngineSnapshot()
        snapshot.indexActivity = .working
        snapshot.indexProgress = .init(state: .updating, totalsKnown: true, totalAssets: 100, readyAssets: 50, totalRepresentations: 300, readyRepresentations: 250, excludedAssets: 0, issue: nil)
        snapshot.livePhotoActivities = [.working(.identification)]
        snapshot.livePhotoInventory = .init(phase: .identifying, inventoried: 16222, identified: 2, unresolved: 626, retryWaiting: 626)
        var rows = SyncStatusPresentation(snapshot: snapshot).progressRows
        XCTAssertEqual(rows.map(\.id), ["visualIndex", "livePhoto"])
        XCTAssertEqual(rows.map(\.subtitle), ["正在建立视觉索引", "正在配对 Live Photo"])
        XCTAssertEqual(rows[0].progressText, "已分析 50 / 100 张"); XCTAssertEqual(rows[0].fraction, 0.5)
        XCTAssertEqual(rows[1].progressText, "已处理 2 / 16222 项")
        snapshot.livePhotoInventory?.phase = .enumerating
        rows = SyncStatusPresentation(snapshot: snapshot).progressRows
        XCTAssertEqual(rows[1].progressText, "已处理 2 项"); XCTAssertNil(rows[1].fraction)
        snapshot.livePhotoActivities = [.working(.completion)]
        rows = SyncStatusPresentation(snapshot: snapshot).progressRows
        XCTAssertNil(rows[1].fraction); XCTAssertNil(rows[1].progressText)
        snapshot.indexProgress = .init(state: .preparing, totalsKnown: false, totalAssets: 0, readyAssets: 7, totalRepresentations: 0, readyRepresentations: 0, excludedAssets: 0, issue: nil)
        XCTAssertEqual(SyncStatusPresentation(snapshot: snapshot).progressRows[0].progressText, "已分析 7 张")
        snapshot.isPaused = true; XCTAssertEqual(SyncStatusPresentation(snapshot: snapshot).progressRows.count, 2)
        XCTAssertFalse(SyncStatusPresentation(snapshot: snapshot).progressRows.contains(where: \.active))
        snapshot.isPaused = false; snapshot.indexActivity = .waiting; snapshot.livePhotoActivities = [.waiting(nextRetryAt: nil)]
        XCTAssertEqual(SyncStatusPresentation(snapshot: snapshot).progressRows.count, 2)
        XCTAssertFalse(SyncStatusPresentation(snapshot: snapshot).progressRows.contains(where: \.active))
    }
}
