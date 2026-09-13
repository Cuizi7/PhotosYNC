import XCTest

final class TestSupportTests: XCTestCase {
    func testUnixSecondRoundsDownInsteadOfToNearestSecond() {
        XCTAssertEqual(TestSupport.unixSecond(from: Date(timeIntervalSince1970: 100.9)), 100)
    }
}
