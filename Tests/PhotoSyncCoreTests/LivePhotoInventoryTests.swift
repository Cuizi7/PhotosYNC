import XCTest
@testable import PhotoSyncCore

final class LivePhotoInventoryTests: XCTestCase {
    func testHistoricalContextMustBePositivelyVerifiedBeforeResuming() async throws {
        let f = try await inventoryFixture(count: 1); defer { try? FileManager.default.removeItem(at: f.root) }
        try await completeEmptyInventory(f.store, f.photos.context)
        await f.photos.setContextAccepted(false)
        let task = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        do { try await task.resumeInitialInventory(); XCTFail("Unverified historical context accepted") } catch { }
        let calls = await f.photos.catalogCalls, reads = await f.photos.resourceReads
        XCTAssertEqual(calls, 0); XCTAssertEqual(reads, 0)
        let saved = try await f.store.livePhotoInventorySummary(context: f.photos.context); XCTAssertEqual(saved.phase, .completed)
    }
    func testInitialInventoryIncludesUntrackedImagesAndVideos() async throws {
        let f = try await inventoryFixture(count: 35); defer { try? FileManager.default.removeItem(at: f.root) }
        let task = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        try await task.resumeInitialInventory()
        for _ in 0..<35 { _ = try await task.processNextInventoryItem(now: Date()) }
        let summary = try await task.summary()
        XCTAssertEqual(summary.inventoried, 35); XCTAssertEqual(summary.identified, 35); XCTAssertEqual(summary.phase, .completed)
        let kinds = await f.photos.readKinds
        XCTAssertTrue(kinds.contains(.image)); XCTAssertTrue(kinds.contains(.video))
        let sourceCount = try await f.store.countFiles(state: .imported); XCTAssertEqual(sourceCount, 0)
    }

    func testCompletedInventoryDoesNotEnumerateOnRestartOrUpgrade() async throws {
        let f = try await inventoryFixture(count: 3); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        try await first.resumeInitialInventory()
        for _ in 0..<3 { _ = try await first.processNextInventoryItem(now: Date()) }
        let before = await f.photos.catalogCalls
        let reopened = try SyncStore(url: f.db)
        for _ in 0..<3 {
            let next = LivePhotoInventoryCoordinator(store: reopened, photos: f.photos, metadata: InventoryMetadata())
            try await next.resumeInitialInventory()
            _ = try await next.processNextInventoryItem(now: Date())
        }
        let after = await f.photos.catalogCalls
        XCTAssertEqual(after, before)
        let reads = await f.photos.resourceReads; XCTAssertEqual(reads, 3)
    }

    func testInterruptedInventoryResumesPendingItems() async throws {
        let f = try await inventoryFixture(count: 4); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        try await first.resumeInitialInventory(); _ = try await first.processNextInventoryItem(now: Date())
        let next = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        try await next.resumeInitialInventory()
        for _ in 0..<3 { _ = try await next.processNextInventoryItem(now: Date()) }
        let summary = try await next.summary(); XCTAssertEqual(summary.phase, .completed)
        let reads = await f.photos.resourceReads; XCTAssertEqual(reads, 4)
    }

    func testUnresolvedItemsDoNotResetCompletion() async throws {
        let f = try await inventoryFixture(count: 2); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.photos.setUnavailable("asset-0")
        let task = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        try await task.resumeInitialInventory()
        for _ in 0..<2 { _ = try await task.processNextInventoryItem(now: Date()) }
        let before = try await task.summary(); XCTAssertEqual(before.phase, .completed); XCTAssertEqual(before.unresolved, 1)
        _ = try await task.processNextInventoryItem(now: Date().addingTimeInterval(1000))
        let after = try await task.summary(); XCTAssertEqual(after.completedAt, before.completedAt)
        let calls = await f.photos.catalogCalls; XCTAssertEqual(calls, 1)
    }

    func testLibraryChangeDuringPagingDoesNotLoseAssets() async throws {
        let f = try await inventoryFixture(count: 3); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.photos.addDuringCatalog(livePhotoAsset(context: f.photos.context, id: "before-cursor", kind: .video))
        let task = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        try await task.resumeInitialInventory()
        for _ in 0..<4 { _ = try await task.processNextInventoryItem(now: Date()) }
        let summary = try await task.summary(); XCTAssertEqual(summary.inventoried, 4); XCTAssertEqual(summary.phase, .completed)
    }

    func testDeletionPersistsBeforeAcknowledgement() async throws {
        let f = try await makeLivePhotoStoreFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var operation = livePhotoOperation(context: f.context, photoID: f.first, motionID: f.second)
        operation.oldAssetIDs = ["old-photo"]
        _ = try await f.store.reserveLivePhotoOperation(operation)
        let delta = PhotosIndexDelta(context: f.context, fromGeneration: 0, toGeneration: 1, changedAssetIDs: [], deletedAssetIDs: ["old-photo"])
        try await f.store.applyLivePhotoDelta(delta)
        try await f.store.applyLivePhotoDelta(delta) // duplicate delivery cannot clear the deletion fact
        let group = try await f.store.livePhotoGroup(context: f.context, contentIdentifier: "pair")
        XCTAssertEqual(group?.deleted, true)
        let again = try await f.store.reserveLivePhotoOperation(livePhotoOperation(context: f.context, photoID: f.first, motionID: f.second))
        XCTAssertFalse(again)
    }

    func testInterruptedCatalogRealignsWithoutRereadingCompletedItems() async throws {
        let f = try await inventoryFixture(count: 5); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.photos.failCatalogOnce(at: 2)
        let task = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata(), batchSize: 2)
        do { try await task.resumeInitialInventory(); XCTFail("Expected invalidated page") } catch { }
        try await task.resumeInitialInventory()
        for _ in 0..<5 { _ = try await task.processNextInventoryItem(now: Date()) }
        let summary = try await task.summary(); XCTAssertEqual(summary.phase, .completed)
        let reads = await f.photos.resourceReads; XCTAssertEqual(reads, 5)
    }

    func testStaleObservationCannotConsumeNewChange() async throws {
        let f = try await inventoryFixture(count: 1); defer { try? FileManager.default.removeItem(at: f.root) }
        let context = f.photos.context, asset = livePhotoAsset(context: f.photos.context, id: "asset-0")
        try await f.store.ensureLivePhotoInventory(context: context)
        try await f.store.enqueueLivePhotoAssets(context: context, assets: [asset])
        try await f.store.applyLivePhotoDelta(.init(context: context, fromGeneration: 0, toGeneration: 1, changedAssetIDs: [asset.assetID], deletedAssetIDs: []))
        do {
            try await f.store.recordLivePhotoInventoryResult(context: context, assetID: asset.assetID, revision: asset.revision, observations: [.init(resource: asset.resources[0], inspection: .noIdentifier)])
            XCTFail("Stale read consumed newer change")
        } catch { }
        let pending = try await f.store.livePhotoAssetsNeedingDescriptor(context: context, now: Date(), limit: 2)
        XCTAssertEqual(pending, ["asset-0"])
    }

    func testCompletedTaskConsumesNewCatalogAssetsWithoutFullRescan() async throws {
        let f = try await inventoryFixture(count: 1); defer { try? FileManager.default.removeItem(at: f.root) }
        let task = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        try await task.resumeInitialInventory(); _ = try await task.processNextInventoryItem(now: Date())
        let before = try await task.summary()
        let added = livePhotoAsset(context: f.photos.context, id: "new-untracked", kind: .video)
        await f.photos.appendAsset(added)
        try f.store.enqueueLivePhotoCatalogAssets(context: f.photos.context, assets: [added])
        _ = try await task.processNextInventoryItem(now: Date())
        let after = try await task.summary(), catalogCalls = await f.photos.catalogCalls
        XCTAssertEqual(after.completedAt, before.completedAt); XCTAssertEqual(after.identified, 2)
        XCTAssertEqual(catalogCalls, 1)
    }

    func testPauseDoesNotEnumerateOrRead() async throws {
        let f = try await inventoryFixture(count: 2); defer { try? FileManager.default.removeItem(at: f.root) }
        let task = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        await task.setPaused(true)
        try await task.resumeInitialInventory()
        let progressed = try await task.processNextInventoryItem(now: Date()); XCTAssertFalse(progressed)
        let calls = await f.photos.catalogCalls, reads = await f.photos.resourceReads
        XCTAssertEqual(calls, 0); XCTAssertEqual(reads, 0)
    }
}

struct InventoryMetadata: LivePhotoMetadataReading {
    func inspect(url: URL, kind: MediaKind) async throws -> LivePhotoInspection { .noIdentifier }
}

func inventoryFixture(count: Int) async throws -> (root: URL, db: URL, store: SyncStore, photos: FixtureLivePhotoGateway) {
    let root = try temporaryDirectory(), db = root.appendingPathComponent("state.sqlite")
    let context = LibraryContext(id: UUID(), epoch: 0)
    let assets = (0..<count).map { livePhotoAsset(context: context, id: "asset-\($0)", kind: $0.isMultiple(of: 2) ? .image : .video) }
    let photos = FixtureLivePhotoGateway(context: context, assets: assets, root: root)
    return (root, db, try SyncStore(url: db), photos)
}

actor FixtureLivePhotoGateway: LivePhotoPhotosGateway {
    nonisolated let context: LibraryContext
    var assets: [LivePhotoAssetDescriptor]
    let root: URL
    var catalogCalls = 0, resourceReads = 0, generation = 0, contextReads = 0
    var readKinds = [MediaKind]()
    var unavailable: String?
    var injected: LivePhotoAssetDescriptor?
    var changesDuringCatalog = [String]()
    var catalogFailureAt: Int?
    var contextAccepted = true
    func setContextAccepted(_ value: Bool) { contextAccepted = value }
    func verifyLivePhotoContext(context: LibraryContext, anchorAssetIDs: [String], allowUnanchored: Bool) async throws -> Bool { contextAccepted && context == self.context }
    func failCatalogOnce(at call: Int) { catalogFailureAt = call }
    init(context: LibraryContext, assets: [LivePhotoAssetDescriptor], root: URL) { self.context = context; self.assets = assets; self.root = root }
    func verifyLivePhoto(assetID: String, operation: LivePhotoOperation) async throws -> LivePhotoVerification { throw PhotosRepresentationError.unavailable }
    func setLivePhotoRecoveryBlocks(_ operationIDs: Set<UUID>) async {}
    func createLivePhoto(photoURL: URL, motionURL: URL, photoFilename: String?, motionFilename: String?, preservation: LivePhotoPreservationSnapshot, expectedGeneration: Int, beforeMutation: @escaping @Sendable () throws -> Bool, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String { throw PhotosRepresentationError.unavailable }
    func retireLivePhotoComponents(assetIDs: [String], expectedGeneration: Int, beforeMutation: @escaping @Sendable () throws -> Bool) async throws { throw PhotosRepresentationError.unavailable }
    func setUnavailable(_ id: String?) { unavailable = id }
    func appendAsset(_ descriptor: LivePhotoAssetDescriptor) { assets.append(descriptor) }
    func addDuringCatalog(_ descriptor: LivePhotoAssetDescriptor) { injected = descriptor }
    func candidateSnapshot() async throws -> PhotosCandidateSnapshot { .init(generation: generation, candidates: []) }
    func livePhotoLibraryContext() async throws -> LibraryContext { contextReads += 1; return context }
    func livePhotoAssetCatalog(session: PhotosCatalogSession, offset: Int, limit: Int) async throws -> LivePhotoAssetPage {
        catalogCalls += 1
        if catalogCalls == catalogFailureAt { catalogFailureAt = nil; throw PhotoKitGatewayError.libraryChanged }
        let old = assets
        if let injected { assets.append(injected); generation += 1; changesDuringCatalog.append(injected.assetID); self.injected = nil }
        let end = min(old.count, offset + limit)
        return .init(context: context, generation: session.baselineGeneration, assets: Array(old[offset..<end]), nextOffset: end < old.count ? end : nil)
    }
    func livePhotoAssets(assetIDs: [String], context: LibraryContext) async throws -> [LivePhotoAssetDescriptor] { assets.filter { assetIDs.contains($0.assetID) } }
    func catalogChanges(baselineGeneration: Int, throughGeneration: Int, afterAssetID: String?, limit: Int) async throws -> PhotosCatalogChangeBatch {
        .init(changedAssetIDs: changesDuringCatalog.filter { $0 > (afterAssetID ?? "") }, deletedAssetIDs: [], nextAssetID: nil)
    }
    func catalogCoverage(baselineGeneration: Int) async throws -> Int { generation }
    func catalogCoverage(session: PhotosCatalogSession) async throws -> Int { generation }
    func readLivePhotoResource(_ ref: LivePhotoResourceRef, purpose: LivePhotoReadPurpose, budget: LivePhotoResourceBudget) async throws -> LivePhotoResourceLease {
        resourceReads += 1
        guard ref.assetID != unavailable else { throw PhotosRepresentationError.unavailable }
        let asset = assets.first { $0.assetID == ref.assetID }!
        readKinds.append(asset.mediaKind)
        let url = root.appendingPathComponent(asset.assetID)
        try Data([1]).write(to: url)
        return .init(url: url)
    }
    func livePhotoPreservationSnapshot(assetID: String, context: LibraryContext) async throws -> LivePhotoPreservationSnapshot { knownLivePhotoSnapshot() }
    func resourcesEqual(_ lhs: LivePhotoResourceRef, _ rhs: LivePhotoResourceRef, budget: LivePhotoResourceBudget) async throws -> Bool { lhs == rhs }
    func create(fileURL: URL, kind: MediaKind, expectedGeneration: Int, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String { throw PhotosRepresentationError.unavailable }
    func reconcile(placeholder: String?) async throws -> ImportEvidence { .unknown }
    func representationCatalog(offset: Int, limit: Int, expectedGeneration: Int) async throws -> RepresentationPage { .init(context: context, generation: generation, descriptors: [], nextOffset: nil) }
    nonisolated func changes() -> AsyncStream<PhotosIndexChange> { AsyncStream { $0.finish() } }
    func readRepresentation(_ descriptor: RepresentationDescriptor) async throws -> LoadedRepresentation { throw PhotosRepresentationError.unavailable }
}
