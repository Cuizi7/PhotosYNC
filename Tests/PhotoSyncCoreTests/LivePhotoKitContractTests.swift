import XCTest
import Photos
@testable import PhotoSyncCore

final class LivePhotoKitContractTests: XCTestCase {
    func testGuardedOrdinaryCallDefersBehindRecoveredPairedBlock() async throws {
        let f = try await contractFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.gateway.setLivePhotoRecoveryBlocks([UUID()])
        do {
            _ = try await f.gateway.create(fileURL: f.photo, kind: .image, expectedGeneration: f.generation, beforeMutation: { true }, onPlaceholder: { _ in XCTFail("Existing unknown block") })
            XCTFail("Expected no-submission deferral")
        } catch is PhotosAdmissionDeferred { }
        catch { XCTFail("An earlier mutation's uncertainty cannot belong to this call: \(error)") }
        XCTAssertTrue(f.lifecycle.commands.isEmpty)
        await f.gateway.setLivePhotoRecoveryBlocks([])
        let saved = try await f.gateway.create(fileURL: f.photo, kind: .image, expectedGeneration: f.generation, beforeMutation: { true }, onPlaceholder: { _ in })
        XCTAssertEqual(saved, "created")
    }
    func testOrdinaryEngineDefersBehindUnknownPairedResultWithoutPhantomAttempt() async throws {
        let f = try await contractFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let source = f.root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try makeLivePhotoImage(at: source.appendingPathComponent("ordinary.jpg"), identifier: nil)
        let store = try SyncStore(url: f.root.appendingPathComponent("engine.sqlite"))
        let sourceID = try await store.registerSource(url: source)
        f.gateway.attachIndexStore(store)
        f.lifecycle.failure = PhotoKitGatewayError.resultUnknown("paired result lost")
        do { _ = try await f.gateway.createLivePhoto(photoURL: f.photo, motionURL: f.motion, preservation: knownLivePhotoSnapshot(), expectedGeneration: f.generation, beforeMutation: { true }, onPlaceholder: { _ in }); XCTFail("Expected unknown") } catch { }
        f.lifecycle.failure = nil
        let engine = SyncEngine(store: store, photos: f.gateway, livePhotoDirectoryObserver: DirectoryObserverProbe(store: store))
        await engine.scanEnabledSources()
        let first = try await store.activeSourceSummary()
        XCTAssertEqual(first.pending, 1); XCTAssertEqual(first.importing, 0)
        await f.gateway.setLivePhotoRecoveryBlocks([])
        await engine.scan(sourceIDs: [sourceID])
        let final = try await store.activeSourceSummary()
        XCTAssertEqual(final.imported, 1); XCTAssertEqual(final.importing, 0)
        XCTAssertEqual(f.lifecycle.commands.count, 2, "Only original unknown pair and later confirmed ordinary request")
    }
    func testFinalGuardFilesystemFailureHasDefiniteNoSubmissionEvidence() async throws {
        for retirement in [false, true] {
            let f = try await contractFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let absent = f.root.appendingPathComponent("removed-before-final-guard")
            let guardRead: @Sendable () throws -> Bool = {
                _ = try FileManager.default.attributesOfItem(atPath: absent.path)
                return true
            }
            do {
                if retirement {
                    try await f.gateway.retireLivePhotoComponents(assetIDs: ["old"], expectedGeneration: f.generation, beforeMutation: guardRead)
                } else {
                    _ = try await f.gateway.createLivePhoto(photoURL: f.photo, motionURL: f.motion, preservation: knownLivePhotoSnapshot(), expectedGeneration: f.generation,
                        beforeMutation: guardRead, onPlaceholder: { _ in XCTFail("No asset request before admission") })
                }
                XCTFail("Missing guard read accepted")
            } catch let error as PhotoKitGatewayError {
                XCTAssertEqual(error.recoveryEvidence, .definitelyNotCommitted)
            } catch { XCTFail("Affirmative prevention lost: \(error)") }
            XCTAssertTrue(f.lifecycle.commands.isEmpty)
            let saved = try await f.gateway.create(fileURL: f.photo, kind: .image, expectedGeneration: f.generation, onPlaceholder: { _ in })
            XCTAssertEqual(saved, "created", "A prevented request cannot poison unrelated Photos writes")
        }
    }
    func testRestoredCatalogProducerUsesSavedContextBeforeFirstFetch() async throws {
        let f = try await makeLivePhotoStoreFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let lifecycle = LivePhotoKitLifecycle(); lifecycle.emitInventoryOnLoad = true
        let gateway = PhotoKitGateway(lifecycle: lifecycle); gateway.attachIndexStore(f.store)
        try await gateway.restoreInventoryContext(f.context)
        _ = try await gateway.candidateSnapshot()
        let descriptor = try await f.store.livePhotoAssetDescriptor(context: f.context, assetID: "new-on-start")
        XCTAssertNotNil(descriptor, "First metadata fetch must not enqueue under a provisional context")
    }
    func testUnverifiedLibraryIdentityPreventsPairedMutation() async throws {
        let f = try await contractFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let context = try await f.gateway.livePhotoLibraryContext()
        f.lifecycle.missingIDs = ["old-anchor"]
        let verified = try await f.gateway.verifyLivePhotoContext(context: context, anchorAssetIDs: ["old-anchor"], allowUnanchored: false)
        XCTAssertFalse(verified)
        do {
            _ = try await f.gateway.createLivePhoto(photoURL: f.photo, motionURL: f.motion, preservation: knownLivePhotoSnapshot(), expectedGeneration: f.generation, beforeMutation: { true }, onPlaceholder: { _ in XCTFail("Unknown library") })
            XCTFail("Unknown library accepted mutation")
        } catch is PhotosAdmissionDeferred { }
        XCTAssertEqual(f.lifecycle.commands.count, 0)
    }
    func testOrdinaryUnknownBlocksPairedCreationWithoutInventingSecondUnknown() async throws {
        let f = try await contractFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.lifecycle.failure = PhotoKitGatewayError.resultUnknown("ordinary callback lost")
        do { _ = try await f.gateway.create(fileURL: f.photo, kind: .image, expectedGeneration: f.generation, onPlaceholder: { _ in }); XCTFail("Expected unknown") } catch { }
        f.lifecycle.failure = nil
        do {
            _ = try await f.gateway.createLivePhoto(photoURL: f.photo, motionURL: f.motion, preservation: knownLivePhotoSnapshot(), expectedGeneration: f.generation, beforeMutation: { true }, onPlaceholder: { _ in XCTFail("No second request") })
            XCTFail("Ordinary unknown bypassed")
        } catch is PhotosAdmissionDeferred { }
        XCTAssertEqual(f.lifecycle.commands.count, 1)
    }
    func testDurableOrdinaryAttemptBlocksPairedMutationAtLastGuard() async throws {
        let f = try await contractFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let db = try await makeLivePhotoStoreFixture(); defer { try? FileManager.default.removeItem(at: db.root) }
        try await db.store.beginAttempt(fileID: db.first, attemptID: UUID())
        f.gateway.attachIndexStore(db.store)
        do {
            _ = try await f.gateway.createLivePhoto(photoURL: f.photo, motionURL: f.motion, preservation: knownLivePhotoSnapshot(), expectedGeneration: f.generation, beforeMutation: { true }, onPlaceholder: { _ in XCTFail("Durable ordinary attempt bypassed") })
            XCTFail("Expected admission deferral")
        } catch is PhotosAdmissionDeferred { }
        XCTAssertEqual(f.lifecycle.commands.count, 0)
    }
    func testDurableUnknownGroupBlocksOrdinaryWithoutRecoveryCallback() async throws {
        let f = try await contractFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let stored = try await makeLivePhotoStoreFixture(); defer { try? FileManager.default.removeItem(at: stored.root) }
        let op = livePhotoOperation(context: stored.context, photoID: stored.first, motionID: stored.second)
        _ = try await stored.store.reserveLivePhotoOperation(op)
        try await stored.store.beginLivePhotoCreation(operationID: op.id)
        f.gateway.attachIndexStore(stored.store)
        do {
            _ = try await f.gateway.create(fileURL: f.photo, kind: .image, expectedGeneration: f.generation, beforeMutation: { true }, onPlaceholder: { _ in })
            XCTFail("Durable submitted group bypassed after missing success callback")
        } catch { }
        XCTAssertEqual(f.lifecycle.commands.count, 0)
    }

    func testOneRequestContainsOriginalPhotoAndPairedVideo() async throws {
        let f = try await contractFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let result = try await f.gateway.createLivePhoto(photoURL: f.photo, motionURL: f.motion, photoFilename: "original.heic", motionFilename: "original.mov",
            preservation: knownLivePhotoSnapshot(), expectedGeneration: f.generation, beforeMutation: { true }, onPlaceholder: { _ in })
        XCTAssertEqual(result, "created")
        let command = try XCTUnwrap(f.lifecycle.commands.first)
        XCTAssertEqual(command.resources.map(\.type), [.photo, .pairedVideo])
        XCTAssertEqual(command.resources.map(\.shouldMoveFile), [false, false])
        XCTAssertEqual(command.resources.map(\.originalFilename), ["original.heic", "original.mov"])
    }

    func testCleanupOnlySubmitsFrozenAssetIDs() async throws {
        let f = try await contractFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.gateway.retireLivePhotoComponents(assetIDs: ["old-photo", "old-motion"], expectedGeneration: f.generation, beforeMutation: { true })
        guard case .retireComponents(let ids) = f.lifecycle.commands.first else { return XCTFail("Expected retirement command") }
        XCTAssertEqual(ids, ["old-photo", "old-motion"])
    }

    func testOrdinaryAndLivePhotoSharePhysicalMutationSlot() async throws {
        let f = try await contractFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let entered = expectation(description: "first physical request"), gate = DirectoryTestGate()
        f.lifecycle.entered = entered; f.lifecycle.gate = gate
        let first = Task { try await f.gateway.create(fileURL: f.photo, kind: .image, expectedGeneration: f.generation, onPlaceholder: { _ in }) }
        await fulfillment(of: [entered], timeout: 5)
        do {
            _ = try await f.gateway.createLivePhoto(photoURL: f.photo, motionURL: f.motion, preservation: knownLivePhotoSnapshot(), expectedGeneration: f.generation, beforeMutation: { true }, onPlaceholder: { _ in })
            XCTFail("Concurrent mutation admitted")
        } catch is PhotosAdmissionDeferred { }
        await gate.release(); _ = try await first.value
        XCTAssertEqual(f.lifecycle.maximumActive, 1); XCTAssertEqual(f.lifecycle.commands.count, 1)
    }

    func testUnknownRetirementBlocksOrdinaryCreation() async throws {
        let f = try await contractFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.lifecycle.failure = PhotoKitGatewayError.resultUnknown("unknown deletion")
        do { try await f.gateway.retireLivePhotoComponents(assetIDs: ["old"], expectedGeneration: f.generation, beforeMutation: { true }); XCTFail("Expected unknown") }
        catch let error as PhotoKitGatewayError { XCTAssertEqual(error.recoveryEvidence, .unknown) }
        f.lifecycle.failure = nil
        do { _ = try await f.gateway.create(fileURL: f.photo, kind: .image, expectedGeneration: f.generation, onPlaceholder: { _ in }); XCTFail("Unknown deletion bypassed") }
        catch is PhotosAdmissionDeferred { }
        XCTAssertEqual(f.lifecycle.commands.count, 1)
    }

    func testFinalGuardRejectsWithoutCreatingAssetRequest() async throws {
        let f = try await contractFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        do {
            _ = try await f.gateway.createLivePhoto(photoURL: f.photo, motionURL: f.motion, preservation: knownLivePhotoSnapshot(), expectedGeneration: f.generation, beforeMutation: { false }, onPlaceholder: { _ in XCTFail("Checkpoint before admission") })
            XCTFail("Expected no-mutation deferral")
        } catch is PhotosAdmissionDeferred { }
        XCTAssertTrue(f.lifecycle.commands.isEmpty)
    }

    func testCheckpointFailureRemainsUnknownAndBlocksOtherMutations() async throws {
        let f = try await contractFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        do {
            _ = try await f.gateway.createLivePhoto(photoURL: f.photo, motionURL: f.motion, preservation: knownLivePhotoSnapshot(), expectedGeneration: f.generation, beforeMutation: { true }, onPlaceholder: { _ in throw CocoaError(.fileWriteOutOfSpace) })
            XCTFail("Checkpoint failure lost")
        } catch let error as PhotoKitGatewayError { XCTAssertEqual(error.recoveryEvidence, .unknown) }
        do { try await f.gateway.retireLivePhotoComponents(assetIDs: ["old"], expectedGeneration: f.generation, beforeMutation: { true }); XCTFail("Checkpoint block bypassed") } catch { }
        XCTAssertEqual(f.lifecycle.commands.count, 1)
    }

    func testLateConfirmedCallbackWinsOverCallerCancellation() async throws {
        let f = try await contractFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let entered = expectation(description: "submitted"), gate = DirectoryTestGate()
        f.lifecycle.entered = entered; f.lifecycle.gate = gate
        let work = Task { try await f.gateway.createLivePhoto(photoURL: f.photo, motionURL: f.motion, preservation: knownLivePhotoSnapshot(), expectedGeneration: f.generation, beforeMutation: { true }, onPlaceholder: { _ in }) }
        await fulfillment(of: [entered], timeout: 5)
        work.cancel(); await gate.release()
        let identifier = try await work.value; XCTAssertEqual(identifier, "created")
    }

    private func contractFixture() async throws -> (root: URL, photo: URL, motion: URL, gateway: PhotoKitGateway, lifecycle: LivePhotoKitLifecycle, generation: Int) {
        let root = try temporaryDirectory(), photo = root.appendingPathComponent("photo.jpg"), motion = root.appendingPathComponent("motion.mov")
        try Data([1]).write(to: photo); try Data([2]).write(to: motion)
        let lifecycle = LivePhotoKitLifecycle(), gateway = PhotoKitGateway(lifecycle: lifecycle)
        let snapshot = try await gateway.candidateSnapshot()
        return (root, photo, motion, gateway, lifecycle, snapshot.generation)
    }
}

final class LivePhotoKitLifecycle: PhotoKitLifecycle, @unchecked Sendable {
    let lock = NSLock()
    private(set) var commands = [PhotoKitCreateCommand]()
    private var active = 0
    private(set) var maximumActive = 0
    var entered: XCTestExpectation?
    var gate: DirectoryTestGate?
    var failure: Error?
    func currentAccess() -> PhotoKitAccess { .authorized }
    func requestReadWriteAuthorization() async -> PhotoKitAccess { .authorized }
    func isAvailable() -> Bool { true }
    var emitInventoryOnLoad = false
    var inventoryAttachment: (SyncStore, @Sendable () -> LibraryContext)?
    var missingIDs = Set<String>()
    func attachLivePhotoInventory(store: SyncStore, context: @escaping @Sendable () -> LibraryContext) { inventoryAttachment = (store, context) }
    func loadCandidateAssets() throws -> [PhotoKitCandidateAsset] {
        if emitInventoryOnLoad, let attachment = inventoryAttachment {
            let context = attachment.1()
            try attachment.0.enqueueLivePhotoCatalogAssets(context: context, assets: [livePhotoAsset(context: context, id: "new-on-start")])
        }
        return []
    }
    func candidateIndexChange(for change: PHChange?) throws -> PhotoKitCandidateIndexChange { .reload }
    func fetch(identifier: String) throws -> Bool { !missingIDs.contains(identifier) }
    func submit(_ command: PhotoKitCreateCommand, beforeMutation: @escaping @Sendable () -> Bool, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> PhotoKitSubmissionResult {
        guard beforeMutation() else { return .preventedBeforeMutation }
        lock.lock(); commands.append(command); active += 1; maximumActive = max(maximumActive, active); lock.unlock()
        defer { lock.lock(); active -= 1; lock.unlock() }
        entered?.fulfill(); entered = nil
        if let gate { await gate.wait() }
        if let failure { throw failure }
        if case .retireComponents = command { return .retired }
        do { try onPlaceholder("created") } catch { return .checkpointFailed }
        return .committed(identifier: "created")
    }
}
