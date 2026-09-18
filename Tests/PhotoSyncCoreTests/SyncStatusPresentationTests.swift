import XCTest
@testable import PhotoSyncCore

final class SyncStatusPresentationTests: XCTestCase {
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

}
