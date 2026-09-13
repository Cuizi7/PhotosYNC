import XCTest
@testable import PhotoSyncCore

final class RecoveryTests: XCTestCase {
    func testAbsenceWithoutProofDoesNotRetry() {
        XCTAssertEqual(recoveryAction(.unknown), .keepImporting)
    }

    func testDefiniteFailureCanRetry() {
        XCTAssertEqual(recoveryAction(.definitelyNotCommitted), .retry)
    }

    func testFoundCompletes() {
        XCTAssertEqual(recoveryAction(.found(identifier: "asset-1")), .markImported)
    }
}
