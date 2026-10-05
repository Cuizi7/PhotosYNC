import XCTest
import Photos
@testable import PhotoSyncCore

final class PhotoKitContractTests: XCTestCase {
    func testIncrementalChangePayloadContainsOnlyTheChangedAssets() {
        let change = PhotoKitCandidateIndexChange.incremental(
            removedAssetIDs: ["removed"],
            insertedAssets: [PhotoKitCandidateAsset(identifier: "inserted", candidates: [candidate(key: "inserted")])],
            changedAssets: [PhotoKitCandidateAsset(identifier: "changed", candidates: [candidate(key: "changed")])]
        )
        guard case let .incremental(removed, inserted, changed) = change else {
            return XCTFail("expected an incremental change")
        }
        XCTAssertEqual(removed, ["removed"])
        XCTAssertEqual(inserted.map(\.identifier), ["inserted"])
        XCTAssertEqual(changed.map(\.identifier), ["changed"])
    }

    func testCandidateSnapshotGroupsByFilenameAndReusesUnchangedIndex() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        lifecycle.candidates = [candidate(key: "fixture-1"), candidate(key: "fixture-2")]
        let gateway = PhotoKitGateway(lifecycle: lifecycle)

        let first = try await gateway.candidateSnapshot()
        let second = try await gateway.candidateSnapshot()

        XCTAssertEqual(first.candidates(named: "fixture.jpg").count, 2)
        XCTAssertEqual(second.candidates(named: "missing.jpg"), [])
        XCTAssertEqual(first.generation, second.generation)
        XCTAssertEqual(lifecycle.loadCount, 1)
    }

    func testIncrementalCandidateChangeUpdatesFilenameBucketsWithoutFullReload() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        let old = candidate(key: "asset-old")
        let replacement = candidate(key: "asset-new")
        lifecycle.candidates = [old]
        let gateway = PhotoKitGateway(lifecycle: lifecycle)
        _ = try await gateway.candidateSnapshot()
        lifecycle.nextChange = .incremental(
            removedAssetIDs: ["asset-old"],
            insertedAssets: [PhotoKitCandidateAsset(identifier: "asset-new", candidates: [replacement])],
            changedAssets: [],
        )
        gateway.recordLibraryChangeForTesting()

        let snapshot = try await gateway.candidateSnapshot()
        XCTAssertTrue(snapshot.candidates(named: "fixture.jpg").contains(replacement))
        XCTAssertFalse(snapshot.candidates(named: "fixture.jpg").contains(old))
        XCTAssertEqual(lifecycle.loadCount, 1)
    }

    func testNonincrementalCandidateChangeRebuildsBeforeReturningSnapshot() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        lifecycle.candidates = [candidate(key: "before")]
        let gateway = PhotoKitGateway(lifecycle: lifecycle)
        _ = try await gateway.candidateSnapshot()
        lifecycle.candidates = [candidate(key: "after")]
        lifecycle.nextChange = .reload
        gateway.recordLibraryChangeForTesting()

        let snapshot = try await gateway.candidateSnapshot()
        XCTAssertEqual(snapshot.candidates(named: "fixture.jpg").map(\.key), ["after"])
        XCTAssertEqual(lifecycle.loadCount, 2)
    }

    func testOneHundredIncrementalOwnAssetChangesDoNotReloadTheLibrary() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        var currentID = "asset-0"
        lifecycle.candidates = [candidate(key: currentID)]
        let gateway = PhotoKitGateway(lifecycle: lifecycle)
        _ = try await gateway.candidateSnapshot()

        for index in 1...100 {
            let nextID = "asset-\(index)"
            lifecycle.nextChange = .incremental(
                removedAssetIDs: [currentID],
                insertedAssets: [PhotoKitCandidateAsset(identifier: nextID, candidates: [candidate(key: nextID)])],
                changedAssets: [],
            )
            gateway.recordLibraryChangeForTesting()
            let snapshot = try await gateway.candidateSnapshot()
            XCTAssertEqual(snapshot.candidates(named: "fixture.jpg").map(\.key), [nextID])
            currentID = nextID
        }
        XCTAssertEqual(lifecycle.loadCount, 1)
    }

    func testOverlappingIncrementalIDsForceACompleteRebuild() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        lifecycle.candidates = [candidate(key: "asset-1")]
        let gateway = PhotoKitGateway(lifecycle: lifecycle)
        _ = try await gateway.candidateSnapshot()

        lifecycle.candidates = [candidate(key: "reloaded")]
        lifecycle.nextChange = .incremental(
            removedAssetIDs: ["asset-1"],
            insertedAssets: [],
            changedAssets: [PhotoKitCandidateAsset(identifier: "asset-1", candidates: [candidate(key: "changed")])]
        )
        gateway.recordLibraryChangeForTesting()

        let snapshot = try await gateway.candidateSnapshot()
        XCTAssertEqual(snapshot.candidates(named: "fixture.jpg").map(\.key), ["reloaded"])
        XCTAssertEqual(lifecycle.loadCount, 2)
    }

    func testGatewayErrorsKeepCheckpointFailureAndUnknownOutcomeSeparateFromDefiniteFailure() {
        XCTAssertEqual(
            PhotoKitGatewayError.definitelyNotCommitted("validation failed").recoveryEvidence,
            .definitelyNotCommitted
        )
        XCTAssertEqual(
            PhotoKitGatewayError.resultUnknown("checkpoint persistence failed").recoveryEvidence,
            .unknown
        )
        XCTAssertEqual(
            PhotoKitGatewayError.checkpointFailed("checkpoint persistence failed").recoveryEvidence,
            .unknown
        )
    }

    func testPermissionAndLibraryErrorsDoNotAuthorizeAutomaticRetry() {
        XCTAssertEqual(PhotoKitGatewayError.authorizationRequired.recoveryEvidence, .unknown)
        XCTAssertEqual(PhotoKitGatewayError.libraryUnavailable.recoveryEvidence, .unknown)
    }

    func testLoadCandidatesDiscardsStaleSnapshotAfterOneLibraryChange() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        let stale = candidate(key: "stale")
        let refreshed = candidate(key: "refreshed")
        lifecycle.candidates = [stale]
        let gateway = PhotoKitGateway(lifecycle: lifecycle)
        lifecycle.loadHook = {
            lifecycle.candidates = [refreshed]
            lifecycle.loadHook = nil
            gateway.recordLibraryChangeForTesting()
        }

        let candidates = try await gateway.loadCandidates()

        XCTAssertEqual(candidates, [refreshed])
        XCTAssertEqual(lifecycle.loadCount, 2)
    }

    func testLoadCandidatesFailsAfterBoundedPersistentLibraryChanges() async {
        let lifecycle = FakePhotoKitLifecycle()
        let gateway = PhotoKitGateway(lifecycle: lifecycle)
        lifecycle.loadHook = { gateway.recordLibraryChangeForTesting() }

        await assertThrows({ try await gateway.loadCandidates() }, verify: { error in
            XCTAssertEqual(error as? PhotoKitGatewayError, .libraryChanged)
        })
        XCTAssertEqual(lifecycle.loadCount, 3)
    }

    func testLoadCandidatesDoesNotRetryWhenAccessIsLostDuringRead() async {
        let lifecycle = FakePhotoKitLifecycle()
        let gateway = PhotoKitGateway(lifecycle: lifecycle)
        lifecycle.loadHook = { lifecycle.access = .denied }

        await assertThrows({ try await gateway.loadCandidates() }, verify: { error in
            XCTAssertEqual(error as? PhotoKitGatewayError, .authorizationRequired)
        })
        XCTAssertEqual(lifecycle.loadCount, 1)
    }

    func testLoadCandidatesDoesNotRetryWhenLibraryBecomesUnavailableDuringRead() async {
        let lifecycle = FakePhotoKitLifecycle()
        let gateway = PhotoKitGateway(lifecycle: lifecycle)
        lifecycle.loadHook = { lifecycle.available = false }

        await assertThrows({ try await gateway.loadCandidates() }, verify: { error in
            XCTAssertEqual(error as? PhotoKitGatewayError, .libraryUnavailable)
        })
        XCTAssertEqual(lifecycle.loadCount, 1)
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

    func testCheckpointFailureRemainsTypedAfterReindexingAndBlocksAnotherCreate() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        let gateway = PhotoKitGateway(lifecycle: lifecycle)
        _ = try await gateway.loadCandidates()
        let source = try temporaryFile()

        await assertThrows({ try await gateway.create(fileURL: source, kind: .image) { _ in
            throw CheckpointError.failed
        } }, verify: { error in
            XCTAssertEqual(error as? PhotoKitGatewayError, .checkpointFailed("The placeholder checkpoint failed."))
        })
        _ = try await gateway.loadCandidates()
        await assertThrows({ try await gateway.create(fileURL: source, kind: .image) { _ in } }, verify: { error in
            XCTAssertEqual(
                error as? PhotoKitGatewayError,
                .checkpointFailed("New imports are blocked until the gateway is recreated after reconciliation.")
            )
        })
        XCTAssertEqual(lifecycle.commands.count, 1)
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
            XCTAssertEqual(error as? PhotoKitGatewayError, .checkpointFailed("The placeholder checkpoint failed."))
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

    func testReindexingDoesNotUnblockAdditionsAfterAnUnknownCommittedOutcome() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        lifecycle.fetchResult = false
        let gateway = PhotoKitGateway(lifecycle: lifecycle)
        _ = try await gateway.loadCandidates()

        let identifier = try await gateway.create(fileURL: temporaryFile(), kind: .image) { _ in }
        XCTAssertEqual(identifier, "asset-1")
        _ = try await gateway.loadCandidates()

        await assertThrows({ try await gateway.create(fileURL: try temporaryFile(), kind: .image) { _ in } }, verify: { error in
            XCTAssertEqual(
                error as? PhotoKitGatewayError,
                .resultUnknown("New imports are blocked until the gateway is recreated after reconciliation.")
            )
        })
        XCTAssertEqual(lifecycle.commands.count, 1)
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

    func testCreateRejectsAStaleCandidateIndexBeforePhotoKitSubmission() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        let gateway = PhotoKitGateway(lifecycle: lifecycle)
        let snapshot = try await gateway.candidateSnapshot()
        gateway.recordLibraryChangeForTesting()

        await assertThrows({ try await gateway.create(fileURL: try temporaryFile(), kind: .image, expectedGeneration: snapshot.generation) { _ in } }, verify: { error in
            XCTAssertEqual(
                error as? PhotoKitGatewayError,
                .definitelyNotCommitted("The Photos candidate index was stale before PhotoKit submission.")
            )
        })
        XCTAssertTrue(lifecycle.commands.isEmpty)
        XCTAssertTrue(lifecycle.events.isEmpty)
    }

    func testGuardedProtocolDefaultCannotInvokeLegacyCreate() async throws {
        let fake = FakePhotosGateway()
        let gateway: any PhotosGateway = fake
        await assertThrows({ try await gateway.create(fileURL: URL(fileURLWithPath: "/never-read"), kind: .image,
            expectedGeneration: 0, beforeMutation: { true }, onPlaceholder: { _ in XCTFail("No legacy checkpoint") }) }, verify: { error in
            XCTAssertTrue(error is PhotosAdmissionDeferred)
        })
        let count = await fake.createCount
        XCTAssertEqual(count, 0)
    }

    func testNativeGuardStorageErrorRemainsStorageError() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        let gateway = PhotoKitGateway(lifecycle: lifecycle)
        let root = try sourceFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await gateway.candidateSnapshot()
        await assertThrows({ try await gateway.create(fileURL: root.appendingPathComponent("normal.jpg"), kind: .image,
            expectedGeneration: snapshot.generation, beforeMutation: { throw SyncStoreError.sqlite("controlled receipt failure") },
            onPlaceholder: { _ in XCTFail("No checkpoint") }) }, verify: { error in
            guard case .sqlite(let message) = error as? SyncStoreError else { return XCTFail("Storage failure must stay typed") }
            XCTAssertEqual(message, "controlled receipt failure")
        })
        XCTAssertTrue(lifecycle.commands.isEmpty)
    }

    func testGuardedProtocolCreateChecksInsideNativeMutationBoundary() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        let gateway: any PhotosGateway = PhotoKitGateway(lifecycle: lifecycle)
        let root = try sourceFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let predicate = NativeAdmissionSwitch()
        lifecycle.beforeMutation = { predicate.reject() }
        let snapshot = try await gateway.candidateSnapshot()
        await assertThrows({ try await gateway.create(fileURL: root.appendingPathComponent("normal.jpg"), kind: .image,
            expectedGeneration: snapshot.generation, beforeMutation: { predicate.allowed }, onPlaceholder: { _ in XCTFail("No checkpoint before mutation") }) }, verify: { error in
            XCTAssertTrue(error is PhotosAdmissionDeferred)
        })
        XCTAssertTrue(lifecycle.commands.isEmpty)
        XCTAssertEqual(lifecycle.events, ["beforeMutation"])
    }

    func testGuardedProtocolCreatePreservesSourceFailureDiagnostics() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        let gateway: any PhotosGateway = PhotoKitGateway(lifecycle: lifecycle)
        let root = try sourceFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await gateway.candidateSnapshot()
        await assertThrows({ try await gateway.create(fileURL: root.appendingPathComponent("normal.jpg"), kind: .image,
            expectedGeneration: snapshot.generation, beforeMutation: {
                throw NSError(domain: "PhysicalStamp", code: 7, userInfo: [NSLocalizedDescriptionKey: "controlled source failure"])
            }, onPlaceholder: { _ in XCTFail("No checkpoint") }) }, verify: { error in
            XCTAssertEqual((error as? PhotoKitGatewayError)?.recoveryEvidence, .definitelyNotCommitted)
            XCTAssertTrue(error.localizedDescription.contains("controlled source failure"))
        })
        XCTAssertTrue(lifecycle.commands.isEmpty)
    }

    func testPhotosGatewayProtocolDispatchesGenerationBoundCreate() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        let concrete = PhotoKitGateway(lifecycle: lifecycle)
        let gateway: any PhotosGateway = concrete
        let snapshot = try await gateway.candidateSnapshot()
        concrete.recordLibraryChangeForTesting()

        await assertThrows({ try await gateway.create(fileURL: try temporaryFile(), kind: .image, expectedGeneration: snapshot.generation) { _ in } }, verify: { error in
            XCTAssertEqual(error as? PhotoKitGatewayError, .definitelyNotCommitted("The Photos candidate index was stale before PhotoKit submission."))
        })
        XCTAssertTrue(lifecycle.commands.isEmpty)
    }

    func testEventBeforeChangeBlockPreventsSubmissionAndEventDuringReconcileDoesNotReturnFound() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        let gateway = PhotoKitGateway(lifecycle: lifecycle)
        _ = try await gateway.loadCandidates()
        lifecycle.beforeMutation = { gateway.recordLibraryChangeForTesting() }

        await assertThrows({ try await gateway.create(fileURL: try temporaryFile(), kind: .image) { _ in } }, verify: { error in
            XCTAssertEqual(
                error as? PhotoKitGatewayError,
                .definitelyNotCommitted("The Photos submission was prevented before mutation.")
            )
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
    var loadHook: (() -> Void)?
    var fetchHook: (() -> Void)?
    var nextChange: PhotoKitCandidateIndexChange = .reload
    var loseAccessAfterCompletion = false
    var commands: [PhotoKitCreateCommand] = []
    var events: [String] = []
    private(set) var loadCount = 0

    func currentAccess() -> PhotoKitAccess { access }
    func requestReadWriteAuthorization() async -> PhotoKitAccess { access }
    func isAvailable() -> Bool { available }
    func loadCandidateAssets() throws -> [PhotoKitCandidateAsset] {
        loadCount += 1
        let snapshot = candidates
        loadHook?()
        let grouped = Dictionary(grouping: snapshot, by: { $0.key })
        return grouped.map { PhotoKitCandidateAsset(identifier: $0.key, candidates: $0.value) }
    }
    func candidateIndexChange(for change: PHChange?) throws -> PhotoKitCandidateIndexChange {
        nextChange
    }
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

private func candidate(key: String) -> MatchCandidate {
    MatchCandidate(
        key: key,
        metadata: MediaMetadata(
            filename: "fixture.jpg",
            kind: .image,
            captureSecond: nil,
            rawCaptureTime: nil,
            make: nil,
            model: nil,
            width: nil,
            height: nil,
            duration: nil
        )
    )
}

private final class NativeAdmissionSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    func reject() { lock.lock(); value = false; lock.unlock() }
    var allowed: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
