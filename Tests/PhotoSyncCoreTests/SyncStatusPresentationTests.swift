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
