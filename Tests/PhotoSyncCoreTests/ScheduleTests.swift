import XCTest
@testable import PhotoSyncCore

final class ScheduleTests: XCTestCase {
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

    func testSourceRetryDelayCapsAtOneMinute() {
        XCTAssertEqual(retryDelay(failureCount: 1), 5)
        XCTAssertEqual(retryDelay(failureCount: 2), 15)
        XCTAssertEqual(retryDelay(failureCount: 3), 30)
        XCTAssertEqual(retryDelay(failureCount: 4), 60)
        XCTAssertEqual(retryDelay(failureCount: 99), 60)
    }
}
