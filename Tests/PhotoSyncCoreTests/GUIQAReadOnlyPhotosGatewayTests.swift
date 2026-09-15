import XCTest
@testable import PhotoSyncCore

final class GUIQAReadOnlyPhotosGatewayTests: XCTestCase {
    func testCreateAlwaysRejectsBeforeTouchingReadOnlyAdapter() async throws {
        let access = FakeGUIQAReadOnlyPhotosAccess(access: .authorized)
        let gateway = GUIQAReadOnlyPhotosGateway(access: access)
        let file = try guiQATemporaryFile()

        await assertGUIQAThrows({
            try await gateway.create(fileURL: file, kind: .image) { _ in }
        }, verify: { error in
            XCTAssertEqual(
                error as? PhotoKitGatewayError,
                .definitelyNotCommitted("GUI QA readonly mode prohibits all Photos writes.")
            )
        })

        XCTAssertEqual(access.loadCount, 0)
        XCTAssertEqual(access.authorizationRequests, 0)
    }

    func testReadonlyGatewayRequiresExplicitAuthorizationBeforeEnumeration() async {
        let access = FakeGUIQAReadOnlyPhotosAccess(access: .notDetermined)
        let gateway = GUIQAReadOnlyPhotosGateway(access: access)

        await assertGUIQAThrows({ try await gateway.loadCandidates() }, verify: { error in
            XCTAssertEqual(error as? PhotoKitGatewayError, .authorizationRequired)
        })

        XCTAssertEqual(access.loadCount, 0)
        XCTAssertEqual(access.authorizationRequests, 0)
    }

    func testExplicitAuthorizationAllowsCandidateEnumeration() async throws {
        let candidate = MatchCandidate(
            key: "readonly:fixture",
            metadata: MediaMetadata(
                filename: "fixture.jpg", kind: .image, captureSecond: nil,
                rawCaptureTime: nil, rawCaptureOffset: nil, make: nil, model: nil,
                width: nil, height: nil, duration: nil
            )
        )
        let access = FakeGUIQAReadOnlyPhotosAccess(access: .notDetermined, candidates: [candidate])
        access.authorizationResult = .authorized
        let gateway = GUIQAReadOnlyPhotosGateway(access: access)

        let granted = await gateway.requestAuthorization()
        let candidates = try await gateway.loadCandidates()
        XCTAssertTrue(granted)
        XCTAssertEqual(candidates, [candidate])
        XCTAssertEqual(access.authorizationRequests, 1)
        XCTAssertEqual(access.loadCount, 1)
    }
}

private final class FakeGUIQAReadOnlyPhotosAccess: GUIQAReadOnlyPhotosAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var access: GUIQAReadOnlyAccess
    private let candidates: [MatchCandidate]
    var authorizationResult: GUIQAReadOnlyAccess = .denied
    private(set) var authorizationRequests = 0
    private(set) var loadCount = 0

    init(access: GUIQAReadOnlyAccess, candidates: [MatchCandidate] = []) {
        self.access = access
        self.candidates = candidates
    }

    func currentAccess() -> GUIQAReadOnlyAccess {
        lock.lock(); defer { lock.unlock() }
        return access
    }

    func requestAuthorization() -> GUIQAReadOnlyAccess {
        lock.lock(); defer { lock.unlock() }
        authorizationRequests += 1
        access = authorizationResult
        return access
    }

    func loadCandidates() throws -> [MatchCandidate] {
        lock.lock(); defer { lock.unlock() }
        loadCount += 1
        return candidates
    }
}

private func guiQATemporaryFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("GUIQAReadOnly-\(UUID().uuidString).jpg")
    try Data([0]).write(to: url)
    return url
}

private func assertGUIQAThrows<T>(
    _ operation: () async throws -> T,
    verify: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        verify(error)
    }
}
