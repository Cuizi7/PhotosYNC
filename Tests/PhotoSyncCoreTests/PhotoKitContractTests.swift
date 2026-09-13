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

    func testCreateUsesCopyCheckpointBeforeReturningCommittedIdentifier() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        let gateway = PhotoKitGateway(lifecycle: lifecycle)
        _ = try await gateway.loadCandidates()
        let source = try temporaryFile()
        let checkpoints = CheckpointLog()

        let identifier = try await gateway.create(fileURL: source, kind: .image) { identifier in
            checkpoints.append(identifier)
        }

        XCTAssertEqual(identifier, "asset-1")
        XCTAssertEqual(checkpoints.values, ["asset-1"])
        XCTAssertEqual(lifecycle.commands, [PhotoKitCreateCommand(fileURL: source, kind: .image, shouldMoveFile: false)])
        XCTAssertEqual(lifecycle.events, ["beforeMutation", "placeholder", "completion", "fetch"])
    }

    func testCheckpointFailureRemainsUnknownAndBlocksAnotherCreate() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        let gateway = PhotoKitGateway(lifecycle: lifecycle)
        _ = try await gateway.loadCandidates()
        let source = try temporaryFile()

        await assertThrows({ try await gateway.create(fileURL: source, kind: .image) { _ in
            throw CheckpointError.failed
        } }, verify: { error in
            XCTAssertEqual(error as? PhotoKitGatewayError, .resultUnknown("The placeholder checkpoint failed."))
        })
        await assertThrows { try await gateway.create(fileURL: source, kind: .image) { _ in } }
    }

    func testSystemFailedCompletionIsDefinitelyNotCommitted() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        lifecycle.submitError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed completion"])
        let gateway = PhotoKitGateway(lifecycle: lifecycle)
        _ = try await gateway.loadCandidates()

        await assertThrows({ try await gateway.create(fileURL: try temporaryFile(), kind: .video) { _ in } }, verify: { error in
            XCTAssertEqual(error as? PhotoKitGatewayError, .definitelyNotCommitted("failed completion"))
        })
    }

    func testCheckpointFailureWinsWhenCompletionAlsoFails() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        lifecycle.submitError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed completion"])
        let gateway = PhotoKitGateway(lifecycle: lifecycle)
        _ = try await gateway.loadCandidates()

        await assertThrows({ try await gateway.create(fileURL: try temporaryFile(), kind: .image) { _ in
            throw CheckpointError.failed
        } }, verify: { error in
            XCTAssertEqual(error as? PhotoKitGatewayError, .resultUnknown("The placeholder checkpoint failed."))
        })
        await assertThrows { try await gateway.create(fileURL: try temporaryFile(), kind: .image) { _ in } }
    }

    func testCommittedCreateReturnsIdentifierWhenFetchOrPermissionHealthFails() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        lifecycle.fetchResult = false
        let gateway = PhotoKitGateway(lifecycle: lifecycle)
        _ = try await gateway.loadCandidates()

        let identifier = try await gateway.create(fileURL: try temporaryFile(), kind: .image) { _ in }
        XCTAssertEqual(identifier, "asset-1")
        await assertThrows { try await gateway.create(fileURL: try temporaryFile(), kind: .image) { _ in } }
    }

    func testCommittedCreateReturnsIdentifierWhenPermissionIsLostAfterCompletion() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        lifecycle.loseAccessAfterCompletion = true
        let gateway = PhotoKitGateway(lifecycle: lifecycle)
        _ = try await gateway.loadCandidates()

        let identifier = try await gateway.create(fileURL: try temporaryFile(), kind: .image) { _ in }
        XCTAssertEqual(identifier, "asset-1")
        await assertThrows { try await gateway.create(fileURL: try temporaryFile(), kind: .image) { _ in } }
    }

    func testEventBeforeChangeBlockPreventsSubmissionAndEventDuringReconcileDoesNotReturnFound() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        let gateway = PhotoKitGateway(lifecycle: lifecycle)
        _ = try await gateway.loadCandidates()
        lifecycle.beforeMutation = { gateway.recordLibraryChangeForTesting() }

        await assertThrows({ try await gateway.create(fileURL: try temporaryFile(), kind: .image) { _ in } }, verify: { error in
            XCTAssertEqual(error as? PhotoKitGatewayError, .libraryChanged)
        })
        XCTAssertTrue(lifecycle.commands.isEmpty)

        let secondLifecycle = FakePhotoKitLifecycle()
        let secondGateway = PhotoKitGateway(lifecycle: secondLifecycle)
        secondLifecycle.fetchHook = { secondGateway.recordLibraryChangeForTesting() }
        await assertThrows({ try await secondGateway.reconcile(placeholder: "asset-1") }, verify: { error in
            XCTAssertEqual(error as? PhotoKitGatewayError, .libraryChanged)
        })
    }
}

private enum CheckpointError: Error { case failed }

private func assertThrows<T>(
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

private final class CheckpointLog: @unchecked Sendable {
    private var storage: [String] = []
    func append(_ value: String) { storage.append(value) }
    var values: [String] { storage }
}

private final class FakePhotoKitLifecycle: PhotoKitLifecycle, @unchecked Sendable {
    var access: PhotoKitAccess = .authorized
    var available = true
    var candidates: [MatchCandidate] = []
    var submitError: Error?
    var fetchResult = true
    var beforeMutation: (() -> Void)?
    var fetchHook: (() -> Void)?
    var loseAccessAfterCompletion = false
    var commands: [PhotoKitCreateCommand] = []
    var events: [String] = []

    func currentAccess() -> PhotoKitAccess { access }
    func requestReadWriteAuthorization() async -> PhotoKitAccess { access }
    func isAvailable() -> Bool { available }
    func loadCandidates() throws -> [MatchCandidate] { candidates }
    func submit(_ command: PhotoKitCreateCommand, beforeMutation: @escaping @Sendable () -> Bool, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> PhotoKitSubmissionResult {
        self.beforeMutation?()
        events.append("beforeMutation")
        guard beforeMutation() else { return .preventedBeforeMutation }
        commands.append(command)
        do {
            try onPlaceholder("asset-1")
            events.append("placeholder")
        } catch {
            events.append("placeholder")
            events.append("completion")
            if let submitError { throw PhotoKitSubmissionError.checkpointFailed(submitError) }
            return .checkpointFailed
        }
        if let submitError { throw submitError }
        events.append("completion")
        if loseAccessAfterCompletion { access = .denied }
        return .committed(identifier: "asset-1")
    }
    func fetch(identifier: String) throws -> Bool {
        events.append("fetch")
        fetchHook?()
        return fetchResult
    }
}

private func temporaryFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoKitContract-\(UUID().uuidString).jpg")
    try Data([0]).write(to: url)
    return url
}
