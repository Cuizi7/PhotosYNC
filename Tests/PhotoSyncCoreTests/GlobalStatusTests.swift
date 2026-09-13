import XCTest
import AppKit
@testable import PhotoSyncCore

final class GlobalStatusTests: XCTestCase {
    func testWaitingIsVisibleWhileAnotherSourceRuns() {
        XCTAssertEqual(GlobalStatus.resolve(configured: true, error: false, paused: false, waiting: true, running: true), .waiting)
    }
    func testErrorIsNotReportedAsCompleted() {
        XCTAssertEqual(GlobalStatus.resolve(configured: true, error: true, paused: false, waiting: false, running: false), .error)
    }
    func testSymbolsExistOnHostOS() {
        for status in GlobalStatus.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: status.symbol, accessibilityDescription: status.description))
        }
    }
    func testLoggerReportsAppendFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let failure = expectation(description: "visible failure")
        let logger = try RunLogger(directory: directory) { _ in failure.fulfill() }
        try FileManager.default.removeItem(at: directory)
        logger.log(["result": "test"])
        await fulfillment(of: [failure], timeout: 2)
    }
    func testPriorityAndSymbols() {
        XCTAssertEqual(GlobalStatus.resolve(configured: false, error: true, paused: true, waiting: true, running: true), .unconfigured)
        XCTAssertEqual(GlobalStatus.resolve(configured: true, error: false, paused: true, waiting: true, running: true), .paused)
        XCTAssertEqual(GlobalStatus.resolve(configured: true, error: false, paused: false, waiting: false, running: true), .running)
        XCTAssertEqual(GlobalStatus.resolve(configured: true, error: false, paused: false, waiting: false, running: false), .completed)
        XCTAssertEqual(Set(GlobalStatus.allCases.map(\.symbol)).count, 6)
    }
}
