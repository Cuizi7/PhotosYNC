import XCTest
@testable import PhotoSyncCore

final class ScheduleTests: XCTestCase {
    func testThirtyMinuteReconcileDoesNotOverlapOrCatchUp() {
        var s = ScanSchedule()
        let t = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(ScanSchedule.interval, 1800)
        XCTAssertTrue(s.requestPhotosReconciliation(now: t))
        XCTAssertFalse(s.requestPhotosReconciliation(now: t.addingTimeInterval(1800)))
        s.finishedPhotosReconciliation()
        XCTAssertFalse(s.requestPhotosReconciliation(now: t.addingTimeInterval(1801)))
        XCTAssertTrue(s.requestPhotosReconciliation(now: t.addingTimeInterval(9000)))
        s.finishedPhotosReconciliation()
        XCTAssertFalse(s.requestPhotosReconciliation(now: t.addingTimeInterval(9001)))
        s.pause()
        XCTAssertFalse(s.requestPhotosReconciliation(now: t.addingTimeInterval(10800), force: true))
    }

    func testNoOverlapOrCatchupBurst() {
        var schedule = ScanSchedule()
        let start = Date(timeIntervalSince1970: 0)

        XCTAssertTrue(schedule.request(now: start))
        XCTAssertFalse(schedule.request(now: start.addingTimeInterval(1_800)))
        schedule.finished(now: start.addingTimeInterval(1_900))
        XCTAssertFalse(schedule.request(now: start.addingTimeInterval(1_901)))
        XCTAssertTrue(schedule.request(now: start.addingTimeInterval(3_600)))
    }

    func testStartupManualResumeAndWakeBypassTimeGateButNotRunning() {
        var schedule = ScanSchedule()
        let start = Date(timeIntervalSince1970: 0)

        XCTAssertTrue(schedule.startup(now: start))
        XCTAssertFalse(schedule.requestNow(now: start.addingTimeInterval(1)))
        XCTAssertFalse(schedule.wake(now: start.addingTimeInterval(2)))
        schedule.finished(now: start.addingTimeInterval(3))

        XCTAssertTrue(schedule.requestNow(now: start.addingTimeInterval(4)))
        schedule.finished(now: start.addingTimeInterval(5))
        schedule.pause()
        XCTAssertFalse(schedule.requestNow(now: start.addingTimeInterval(6)))
        XCTAssertTrue(schedule.resume(now: start.addingTimeInterval(7)))
    }

    func testTimerMissesManyIntervalsWithoutCatchup() {
        var schedule = ScanSchedule()
        let start = Date(timeIntervalSince1970: 0)

        XCTAssertTrue(schedule.request(now: start))
        XCTAssertFalse(schedule.request(now: start.addingTimeInterval(7_200)))
        XCTAssertEqual(schedule.nextScanAt, start.addingTimeInterval(9_000))
        schedule.finished(now: start.addingTimeInterval(7_201))
        XCTAssertFalse(schedule.request(now: start.addingTimeInterval(7_202)))
    }

    func testClockRollbackRebuildsOneFutureDeadline() {
        var schedule = ScanSchedule()
        let start = Date(timeIntervalSince1970: 10_000)

        XCTAssertTrue(schedule.request(now: start))
        schedule.finished(now: start.addingTimeInterval(10))
        XCTAssertFalse(schedule.request(now: start.addingTimeInterval(-100)))
        XCTAssertEqual(schedule.nextScanAt, start.addingTimeInterval(1_700))
        XCTAssertFalse(schedule.request(now: start.addingTimeInterval(-99)))
    }

    func testRecoveryCheckIsMinuteGatedAndCannotOverlapScan() {
        var schedule = ScanSchedule()
        let start = Date(timeIntervalSince1970: 0)

        XCTAssertTrue(schedule.requestRecovery(now: start))
        XCTAssertFalse(schedule.requestRecovery(now: start.addingTimeInterval(60)))
        schedule.finished(now: start.addingTimeInterval(61))
        XCTAssertFalse(schedule.requestRecovery(now: start.addingTimeInterval(62)))
        XCTAssertTrue(schedule.requestRecovery(now: start.addingTimeInterval(120)))
    }

    func testFileRetryDelayCapsAtOneMinute() {
        XCTAssertEqual(retryDelay(failureCount: 1), 5)
        XCTAssertEqual(retryDelay(failureCount: 2), 15)
        XCTAssertEqual(retryDelay(failureCount: 3), 30)
        XCTAssertEqual(retryDelay(failureCount: 4), 60)
        XCTAssertEqual(retryDelay(failureCount: 99), 60)
    }

    func testSourceRecoveryDelaySettlesAtFiveMinutes() {
        XCTAssertEqual(sourceRecoveryDelay(failureCount: 1), 5)
        XCTAssertEqual(sourceRecoveryDelay(failureCount: 2), 15)
        XCTAssertEqual(sourceRecoveryDelay(failureCount: 3), 30)
        XCTAssertEqual(sourceRecoveryDelay(failureCount: 4), 60)
        // A volume that has been missing for several rounds is probed every five minutes, not
        // every minute; the file retry curve above is deliberately untouched.
        XCTAssertEqual(sourceRecoveryDelay(failureCount: 5), 300)
        XCTAssertEqual(sourceRecoveryDelay(failureCount: 500), 300)

        var schedule = ScanSchedule()
        var now = Date(timeIntervalSince1970: 0)
        let source = UUID()
        for expected in [5.0, 15, 30, 60, 300, 300] {
            let deadline = schedule.recordSourceFailure(source, now: now)
            XCTAssertEqual(deadline.timeIntervalSince(now), expected)
            now = deadline
        }
    }

    func testDeferredReadsComeBackWithinSecondsAndDoNotUseTheFailureCurve() {
        XCTAssertEqual(sourceDeferralDelay(count: 1), 5)
        XCTAssertEqual(sourceDeferralDelay(count: 2), 5)
        XCTAssertEqual(sourceDeferralDelay(count: 3), 15)
        XCTAssertEqual(sourceDeferralDelay(count: 4), 15)
        XCTAssertEqual(sourceDeferralDelay(count: 9), 60)

        var schedule = ScanSchedule()
        let start = Date(timeIntervalSince1970: 0)
        let source = UUID()
        XCTAssertEqual(schedule.recordSourceDeferral(source, now: start), start.addingTimeInterval(5))
        XCTAssertEqual(Set(schedule.dueRecoverySources(now: start.addingTimeInterval(4))), [])
        XCTAssertEqual(Set(schedule.dueRecoverySources(now: start.addingTimeInterval(5))), [source])
        // A deferral never escalates into the unavailable-source curve.
        XCTAssertEqual(schedule.recordSourceDeferral(source, now: start.addingTimeInterval(5)), start.addingTimeInterval(10))
        schedule.recordSourceRecovered(source)
        XCTAssertEqual(schedule.recordSourceDeferral(source, now: start.addingTimeInterval(10)), start.addingTimeInterval(15))
    }

    func testSourceRecoveryTracksIndependentBackoffDeadlines() {
        var schedule = ScanSchedule()
        let start = Date(timeIntervalSince1970: 0)
        let first = UUID(), second = UUID()

        XCTAssertEqual(schedule.recordSourceFailure(first, now: start), start.addingTimeInterval(5))
        XCTAssertEqual(schedule.recordSourceFailure(second, now: start), start.addingTimeInterval(5))
        XCTAssertEqual(Set(schedule.dueRecoverySources(now: start.addingTimeInterval(5))), Set([first, second]))
        XCTAssertFalse(schedule.requestRecovery(now: start.addingTimeInterval(4)))
        XCTAssertTrue(schedule.requestRecovery(now: start.addingTimeInterval(5)))
        schedule.finished(now: start.addingTimeInterval(6))

        schedule.recordSourceRecovered(second)
        XCTAssertEqual(schedule.recordSourceFailure(first, now: start.addingTimeInterval(6)), start.addingTimeInterval(21))
        XCTAssertEqual(schedule.nextRecoveryAt, start.addingTimeInterval(21))
        XCTAssertEqual(schedule.recordSourceFailure(first, now: start.addingTimeInterval(21)), start.addingTimeInterval(51))
        XCTAssertEqual(schedule.recordSourceFailure(first, now: start.addingTimeInterval(51)), start.addingTimeInterval(111))
        XCTAssertEqual(schedule.nextRecoveryAt, start.addingTimeInterval(65))
    }

    func testSourceFailureAndDeferralDeadlinesDoNotOverwriteEachOther() {
        var schedule = ScanSchedule()
        let start = Date(timeIntervalSince1970: 0)
        let source = UUID()

        XCTAssertEqual(schedule.recordSourceFailure(source, now: start), start.addingTimeInterval(5))
        XCTAssertEqual(schedule.recordSourceDeferral(source, now: start), start.addingTimeInterval(5))

        // Advance both counters independently. The deferral deadline remains due even after a
        // later source-failure update chooses the longer failure curve.
        XCTAssertEqual(schedule.recordSourceFailure(source, now: start.addingTimeInterval(5)), start.addingTimeInterval(20))
        XCTAssertEqual(schedule.recordSourceDeferral(source, now: start.addingTimeInterval(5)), start.addingTimeInterval(10))
        XCTAssertEqual(schedule.recordSourceFailure(source, now: start.addingTimeInterval(10)), start.addingTimeInterval(40))
        XCTAssertEqual(schedule.nextRecoveryAt, start.addingTimeInterval(10))
        XCTAssertEqual(Set(schedule.dueRecoverySources(now: start.addingTimeInterval(10))), [source])
    }
}
