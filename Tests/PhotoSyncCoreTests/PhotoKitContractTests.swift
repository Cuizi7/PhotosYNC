import XCTest
@testable import PhotoSyncCore

final class PhotoKitContractTests: XCTestCase {
    func testGatewayErrorsKeepCommittedOutcomeUnknownSeparateFromDefiniteFailure() {
        XCTAssertEqual(
            PhotoKitGatewayError.definitelyNotCommitted("validation failed").recoveryEvidence,
            .definitelyNotCommitted
        )
        XCTAssertEqual(
            PhotoKitGatewayError.resultUnknown("checkpoint persistence failed").recoveryEvidence,
            .unknown
        )
    }

    func testPermissionAndLibraryErrorsDoNotAuthorizeAutomaticRetry() {
        XCTAssertEqual(PhotoKitGatewayError.authorizationRequired.recoveryEvidence, .unknown)
        XCTAssertEqual(PhotoKitGatewayError.libraryUnavailable.recoveryEvidence, .unknown)
    }
}
