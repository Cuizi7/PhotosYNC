import XCTest
@testable import PhotoSyncCore

final class LivePhotoStoreTests: XCTestCase {
    func testNeutralCatalogProofCannotSuppressContentDeletionOrEarlierInvalidation() async throws {
        for scenario in ["neutral", "content", "unknown", "deleted", "earlier-change"] {
            let f = try await inventoryFixture(count: 1)
            defer { try? FileManager.default.removeItem(at: f.root) }
            let asset = livePhotoAsset(context: f.photos.context, id: "asset-0")
            try await f.store.enqueueLivePhotoAssets(context: f.photos.context, assets: [asset])
            try await f.store.recordLivePhotoInventoryResult(context: f.photos.context, assetID: asset.assetID, revision: asset.revision,
                observations: [.init(resource: asset.resources[0], inspection: .noIdentifier)], retryPolicy: .requiresAttention)
            if scenario == "earlier-change" {
                try f.store.recordLivePhotoChanges(context: f.photos.context, changed: [asset.assetID], deleted: [])
            }
            try f.store.recordPhotosChanges(context: f.photos.context, runID: UUID(), generation: 1,
                changed: scenario == "deleted" ? [] : [asset.assetID], deleted: scenario == "deleted" ? [asset.assetID] : [],
                content: scenario == "content" ? [asset.assetID] : [], batchSize: 1,
                livePhotoUnchanged: scenario == "unknown" ? [] : [asset.assetID])
            let observation = try await f.store.livePhotoObservation(for: asset.resources[0])
            XCTAssertEqual(observation != nil, scenario == "neutral", scenario)
            let refresh = try await f.store.livePhotoAssetsNeedingDescriptor(context: f.photos.context, now: Date(), limit: 1)
            XCTAssertEqual(refresh, ["content", "unknown", "earlier-change"].contains(scenario) ? [asset.assetID] : [], scenario)
        }
    }

    func testLivePhotoNeutralProofRequiresCompleteContentAndResourceFacts() {
        let context = LibraryContext(id: UUID(), epoch: 0), original = livePhotoAsset(context: .init(id: UUID(), epoch: 0), id: "asset")
        XCTAssertTrue(PhotoKitLivePhotoReader.inputsUnchanged(before: original, after: original, assetContentChanged: false))
        for contentChanged: Bool? in [true, nil] {
            XCTAssertFalse(PhotoKitLivePhotoReader.inputsUnchanged(before: original, after: original, assetContentChanged: contentChanged))
        }
        let variants = [
            livePhotoAsset(context: original.context, id: "asset", revision: "r2"),
            livePhotoAsset(context: original.context, id: "asset", isLivePhoto: true),
            livePhotoAsset(context: context, id: "asset"),
            livePhotoAsset(context: original.context, id: "asset", kind: .video),
            LivePhotoAssetDescriptor(context: original.context, assetID: "asset", revision: "r1", isLivePhoto: false,
                mediaKind: .image, resources: original.resources, resourceKinds: [.image], duration: 11)
        ]
        for changed in variants {
            XCTAssertFalse(PhotoKitLivePhotoReader.inputsUnchanged(before: original, after: changed, assetContentChanged: false))
        }
    }

    func testCompleteCandidateWithOnlyOneKnownRoleRemainsUnresolved() async throws {
        let f = try await makeLivePhotoStoreFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let d = LivePhotoAssetDescriptor(context: f.context, assetID: "partial-full", revision: "r1", isLivePhoto: true, mediaKind: .image,
            resources: [.photos(contextID: f.context.id, assetID: "partial-full", resourceKey: "photo", revision: "r1"), .photos(contextID: f.context.id, assetID: "partial-full", resourceKey: "motion", revision: "r1")], resourceKinds: [.image, .video])
        try await f.store.enqueueLivePhotoAssets(context: f.context, assets: [d])
        try await f.store.recordLivePhotoInventoryResult(context: f.context, assetID: d.assetID, revision: d.revision, observations: [
            .init(resource: d.resources[0], inspection: .noIdentifier), .init(resource: d.resources[1], inspection: .identified(.init(contentIdentifier: "pair", role: .motion)))], retryPolicy: .automatic(nextRetryAt: Date().addingTimeInterval(60)))
        let unresolved = try await f.store.hasUnresolvedLivePhotoCandidates(context: f.context)
        XCTAssertTrue(unresolved)
    }
    func testMemberStampGuardSurvivesReplacingInputWithPhotosOriginal() async throws {
        let f = try await makeLivePhotoStoreFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let photo = livePhotoAsset(context: f.context, id: "old-photo"), motion = livePhotoAsset(context: f.context, id: "old-motion", kind: .video)
        try await f.store.enqueueLivePhotoAssets(context: f.context, assets: [photo, motion])
        for asset in [photo, motion] {
            try await f.store.recordLivePhotoInventoryResult(context: f.context, assetID: asset.assetID, revision: asset.revision, observations: [.init(resource: asset.resources[0], inspection: .identified(.init(contentIdentifier: "pair", role: asset.mediaKind == .image ? .photo : .motion)))], retryPolicy: .automatic(nextRetryAt: Date().addingTimeInterval(60)))
        }
        var op = livePhotoOperation(context: f.context, photoID: f.first, motionID: f.second)
        op.photo = photo.resources[0]; op.motion = motion.resources[0]
        _ = try await f.store.reserveLivePhotoOperation(op); try await f.store.beginLivePhotoCreation(operationID: op.id)
        XCTAssertTrue(try f.store.livePhotoMutationAllowed(operationID: op.id, stage: .creating))
        try injectEngineSQL("UPDATE file_record SET size=2,modified_ns=2 WHERE id='\(f.first.uuidString)'", at: f.db)
        XCTAssertFalse(try f.store.livePhotoMutationAllowed(operationID: op.id, stage: .creating))
    }
    func testUnverifiedProducerCannotEstablishHistoricalIdentityAnchor() async throws {
        let f = try await makeLivePhotoStoreFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.store.ensureLivePhotoInventory(context: f.context)
        let op = livePhotoOperation(context: f.context, photoID: f.first, motionID: f.second)
        _ = try await f.store.reserveLivePhotoOperation(op); try await f.store.beginLivePhotoCreation(operationID: op.id)
        try f.store.checkpointLivePhotoPlaceholder(operationID: op.id, identifier: "old-placeholder")
        try f.store.enqueueLivePhotoCatalogAssets(context: f.context, assets: [livePhotoAsset(context: f.context, id: "untrusted-new-asset")])
        let binding = try await f.store.livePhotoIdentityBinding(context: f.context)
        XCTAssertEqual(binding.anchors, ["old-placeholder"])
        XCTAssertTrue(binding.requiresProof)
    }
    func testCompletedInventorySurvivesReopenAndEpochChange() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("state.sqlite"), id = UUID()
        var store: SyncStore? = try SyncStore(url: db)
        let context = LibraryContext(id: id, epoch: 1)
        try await store!.ensureLivePhotoInventory(context: context)
        try await store!.finishLivePhotoEnumeration(context: context, generation: 7)
        let completed = try await store!.completeLivePhotoInventory(context: context, expectedGeneration: 7)
        XCTAssertTrue(completed)
        let before = try await store!.livePhotoInventorySummary(context: context)
        store = nil
        let reopened = try SyncStore(url: db)
        let next = LibraryContext(id: id, epoch: 2)
        try await reopened.ensureLivePhotoInventory(context: next)
        let after = try await reopened.livePhotoInventorySummary(context: next)
        XCTAssertEqual(after.phase, .completed); XCTAssertEqual(after.completedAt, before.completedAt)
    }

    func testCompletionRequiresEnumerationAndEveryItemAttempted() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SyncStore(url: root.appendingPathComponent("s.sqlite")), context = LibraryContext(id: UUID(), epoch: 1)
        try await store.ensureLivePhotoInventory(context: context)
        let early = try await store.completeLivePhotoInventory(context: context, expectedGeneration: 1)
        XCTAssertFalse(early)
        let asset = livePhotoAsset(context: context, id: "untracked")
        try await store.enqueueLivePhotoAssets(context: context, assets: [asset])
        try await store.finishLivePhotoEnumeration(context: context, generation: 1)
        let queued = try await store.completeLivePhotoInventory(context: context, expectedGeneration: 1)
        XCTAssertFalse(queued)
        try await store.recordLivePhotoInventoryResult(context: context, assetID: asset.assetID, revision: asset.revision,
            observations: [.init(resource: asset.resources[0], inspection: .unresolved("cloud"))], retryPolicy: .automatic(nextRetryAt: Date().addingTimeInterval(60)))
        let done = try await store.completeLivePhotoInventory(context: context, expectedGeneration: 1)
        XCTAssertTrue(done)
        let summary = try await store.livePhotoInventorySummary(context: context)
        XCTAssertEqual(summary.unresolved, 1)
        let retry = try await store.nextLivePhotoInventoryItem(context: context, now: Date().addingTimeInterval(1000))
        XCTAssertEqual(retry?.assetID, "untracked")
        try await store.ensureLivePhotoInventory(context: context)
        let still = try await store.livePhotoInventorySummary(context: context)
        XCTAssertEqual(still.completedAt, summary.completedAt)
    }

    func testObservationBindsRevisionAndDoesNotChangeSuccess() async throws {
        let f = try await makeLivePhotoStoreFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let attempt = UUID(); try await f.store.beginAttempt(fileID: f.first, attemptID: attempt)
        try await f.store.markImported(fileID: f.first, attemptID: attempt, identifier: "old-photo")
        let ref = LivePhotoResourceRef.source(fileID: f.first, stamp: .init(size: 1, modifiedNanoseconds: 1))
        try await f.store.saveLivePhotoObservation(.init(resource: ref, inspection: .identified(.init(contentIdentifier: "pair", role: .photo))))
        let observed = try await f.store.livePhotoObservation(for: ref)
        XCTAssertNotNil(observed)
        let changed = try await f.store.livePhotoObservation(for: .source(fileID: f.first, stamp: .init(size: 2, modifiedNanoseconds: 1)))
        XCTAssertNil(changed)
        let success = try await f.store.successIdentifier(of: f.first)
        XCTAssertEqual(success, "old-photo")
    }

    func testMembersReservedExclusivelyAndSharedSuccessIsAtomic() async throws {
        let f = try await makeLivePhotoStoreFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let op = livePhotoOperation(context: f.context, photoID: f.first, motionID: f.second)
        async let a = f.store.reserveLivePhotoOperation(op)
        var competing = op; competing.id = UUID()
        async let b = f.store.reserveLivePhotoOperation(competing)
        let results = try await [a, b]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let pending = try await f.store.nextPendingFile(sourceIDs: [f.sourceID], afterOrder: nil)
        XCTAssertNil(pending)
        let operations = try await f.store.loadLivePhotoOperationsForRecovery()
        let winner = try XCTUnwrap(operations.first)
        try await f.store.beginLivePhotoCreation(operationID: winner.id)
        try f.store.checkpointLivePhotoPlaceholder(operationID: winner.id, identifier: "new")
        try await f.store.confirmLivePhotoCreation(operationID: winner.id, identifier: "new")
        let first = try await f.store.state(of: f.first), second = try await f.store.state(of: f.second)
        XCTAssertEqual(first, .imported); XCTAssertEqual(second, .imported)
        let firstID = try await f.store.successIdentifier(of: f.first), secondID = try await f.store.successIdentifier(of: f.second)
        XCTAssertEqual(firstID, "new"); XCTAssertEqual(secondID, "new")
    }

    func testImportedMemberKeepsSuccessAndAllImportedGroupRecovers() async throws {
        let f = try await makeLivePhotoStoreFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        for id in [f.first, f.second] {
            let attempt = UUID(); try await f.store.beginAttempt(fileID: id, attemptID: attempt)
            try await f.store.markImported(fileID: id, attemptID: attempt, identifier: "old-\(id)")
        }
        let op = livePhotoOperation(context: f.context, photoID: f.first, motionID: f.second)
        let reserved = try await f.store.reserveLivePhotoOperation(op); XCTAssertTrue(reserved)
        try await f.store.beginLivePhotoCreation(operationID: op.id)
        try await f.store.confirmLivePhotoCreation(operationID: op.id, identifier: "complete")
        let success = try await f.store.successIdentifier(of: f.first)
        XCTAssertEqual(success, "old-\(f.first)")
        let recovering = try await f.store.loadLivePhotoOperationsForRecovery()
        XCTAssertEqual(recovering.count, 1); XCTAssertEqual(recovering.first?.targetID, "complete")
    }

    func testOrdinaryImportingMemberCannotBeSeized() async throws {
        let f = try await makeLivePhotoStoreFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.store.beginAttempt(fileID: f.first, attemptID: UUID())
        let reserved = try await f.store.reserveLivePhotoOperation(livePhotoOperation(context: f.context, photoID: f.first, motionID: f.second))
        XCTAssertFalse(reserved)
    }

    func testExistingCompleteTargetRecordsSkipWithoutInventingSuccess() async throws {
        let f = try await makeLivePhotoStoreFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let op = livePhotoOperation(context: f.context, photoID: f.first, motionID: f.second)
        _ = try await f.store.reserveLivePhotoOperation(op)
        try await f.store.reuseLivePhotoTarget(operationID: op.id, identifier: "existing")
        let state = try await f.store.state(of: f.first), success = try await f.store.successIdentifier(of: f.first)
        XCTAssertEqual(state, .skipped); XCTAssertNil(success)
    }

    func testV10MigrationRetainsSuccessAndRollsBackOnCollision() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("old.sqlite")
        do { _ = try SyncStore(url: db) }
        let reset = "DROP TABLE live_photo_observation; DROP TABLE live_photo_operation; DROP TABLE live_photo_group; DROP TABLE live_photo_inventory_item; DROP TABLE live_photo_inventory; DROP INDEX file_live_photo_owner; ALTER TABLE file_record DROP COLUMN live_photo_operation_id; PRAGMA user_version = 10;"
        try injectEngineSQL(reset, at: db)
        try injectEngineSQL("CREATE TABLE live_photo_group(collision TEXT)", at: db)
        XCTAssertThrowsError(try SyncStore(url: db))
        XCTAssertEqual(try engineSQLInteger("PRAGMA user_version", at: db), 10)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM pragma_table_info('file_record') WHERE name='live_photo_operation_id'", at: db), 0)
        try injectEngineSQL("DROP TABLE live_photo_group", at: db)
        let store = try SyncStore(url: db)
        let sourceID = try await store.registerSource(url: root)
        let metadata = MediaMetadata(filename: "old.jpg", kind: .image, captureSecond: nil, rawCaptureTime: nil, make: nil, model: nil, width: nil, height: nil, duration: nil)
        let id = try await store.save(.init(sourceID: sourceID, relativePath: "old.jpg", url: root.appendingPathComponent("old.jpg"), stamp: .init(size: 1, modifiedNanoseconds: 1), metadata: metadata), decision: .importNew)
        let attempt = UUID(); try await store.beginAttempt(fileID: id, attemptID: attempt)
        try await store.markImported(fileID: id, attemptID: attempt, identifier: "retained")
        try injectEngineSQL(reset, at: db)
        let migrated = try SyncStore(url: db)
        let success = try await migrated.successIdentifier(of: id)
        XCTAssertEqual(success, "retained")
        XCTAssertEqual(try engineSQLInteger("PRAGMA user_version", at: db), 11)
    }

    func testMigrationRetainsSuccessAndRejectsFutureVersion() async throws {
        let f = try await makeLivePhotoStoreFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertEqual(try engineSQLInteger("PRAGMA user_version", at: f.db), 11)
        try injectEngineSQL("PRAGMA user_version = 12", at: f.db)
        XCTAssertThrowsError(try SyncStore(url: f.db))
        XCTAssertEqual(try engineSQLInteger("PRAGMA user_version", at: f.db), 12)
    }
}

func livePhotoAsset(context: LibraryContext, id: String, isLivePhoto: Bool = false, revision: String = "r1", kind: MediaKind = .image) -> LivePhotoAssetDescriptor {
    .init(context: context, assetID: id, revision: revision, isLivePhoto: isLivePhoto, mediaKind: kind,
          resources: [.photos(contextID: context.id, assetID: id, resourceKey: "original", revision: revision)])
}

func livePhotoOperation(context: LibraryContext, photoID: UUID, motionID: UUID) -> LivePhotoOperation {
    .init(context: context, contentIdentifier: "pair", photo: .source(fileID: photoID, stamp: .init(size: 1, modifiedNanoseconds: 1)),
          motion: .source(fileID: motionID, stamp: .init(size: 1, modifiedNanoseconds: 1)), sourceFileIDs: [photoID, motionID])
}

func makeLivePhotoStoreFixture() async throws -> (root: URL, db: URL, store: SyncStore, context: LibraryContext, sourceID: UUID, first: UUID, second: UUID) {
    let root = try temporaryDirectory(), db = root.appendingPathComponent("state.sqlite")
    let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let store = try SyncStore(url: db), sourceID = try await store.registerSource(url: source)
    var ids = [UUID]()
    for (filename, kind) in [("a.heic", MediaKind.image), ("a.mov", .video)] {
        let file = SourceFile(sourceID: sourceID, relativePath: filename, url: source.appendingPathComponent(filename), stamp: .init(size: 1, modifiedNanoseconds: 1), metadata: .init(filename: filename, kind: kind, captureSecond: nil, rawCaptureTime: nil, make: nil, model: nil, width: nil, height: nil, duration: nil))
        ids.append(try await store.save(file, decision: .importNew))
    }
    return (root, db, store, LibraryContext(id: UUID(), epoch: 1), sourceID, ids[0], ids[1])
}
