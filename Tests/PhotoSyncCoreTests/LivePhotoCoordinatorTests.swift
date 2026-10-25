import XCTest
@testable import PhotoSyncCore

final class LivePhotoCoordinatorTests: XCTestCase {
    func testVerifiedReplacementClosesHistoricalBlockedAttemptWithoutAnotherMutation() async throws {
        for historical in [false, true] {
            let f = try await completionFixture(photosOnly: true)
            defer { try? FileManager.default.removeItem(at: f.root) }
            let assets = try await f.photos.livePhotoAssets(assetIDs: ["old-photo", "old-motion"], context: f.photos.context)
            let photo = try XCTUnwrap(assets.first { $0.assetID == "old-photo" }).resources[0]
            let motion = try XCTUnwrap(assets.first { $0.assetID == "old-motion" }).resources[0]
            var old = LivePhotoOperation(context: f.photos.context, contentIdentifier: "pair", photo: photo, motion: motion)
            old.stage = .blocked; old.error = "historical resource wait"
            old.nextRetryAt = Date(timeIntervalSince1970: 1)
            old.discoveryResources = [photo, motion]
            if !historical { _ = try await f.store.reserveLivePhotoOperation(old) }
            // Represents a later discovery, which older builds could leave alongside
            // a blocked attempt. The actual coordinator still creates and verifies it.
            let replacement = LivePhotoOperation(context: f.photos.context, contentIdentifier: "pair", photo: photo, motion: motion)
            _ = try await f.store.reserveLivePhotoOperation(replacement)
            let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata())
            for _ in 0..<3 { _ = try await c.advanceNext(now: Date(), refreshDiscovery: false) }
            if historical { _ = try await f.store.reserveLivePhotoOperation(old) }
            let restarted = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata())
            try await restarted.recover()
            for _ in 0..<3 { _ = try await restarted.advanceNext(now: Date(), refreshDiscovery: false) }
            let summary = try await restarted.summary(), saved = try await f.store.livePhotoOperation(id: old.id)
            let creates = await f.photos.creates, retires = await f.photos.retires
            XCTAssertEqual(saved?.stage, .complete, "historical=\(historical)")
            XCTAssertEqual(saved?.creationEvidence, .notSubmitted, "Do not invent successful submission evidence")
            XCTAssertEqual(saved?.supersededByOperationID, replacement.id)
            XCTAssertNil(saved?.nextRetryAt)
            XCTAssertEqual(summary.retryWaitingGroups, 0); XCTAssertEqual(summary.requiresAttentionGroups, 0)
            XCTAssertEqual(creates, 1); XCTAssertEqual(retires, 1)
        }
    }

    func testVerifiedTargetDoesNotClearUnknownOrUncoveredBlockedAttempt() async throws {
        for unknown in [false, true] {
            let f = try await completionFixture(photosOnly: true)
            defer { try? FileManager.default.removeItem(at: f.root) }
            let assets = try await f.photos.livePhotoAssets(assetIDs: ["old-photo", "old-motion"], context: f.photos.context)
            let photo = try XCTUnwrap(assets.first { $0.assetID == "old-photo" }).resources[0]
            let motion = try XCTUnwrap(assets.first { $0.assetID == "old-motion" }).resources[0]
            let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata())
            for _ in 0..<4 { _ = try await c.advanceNext(now: Date(), refreshDiscovery: false) }
            let changed = LivePhotoResourceRef.photos(contextID: f.photos.context.id, assetID: "old-photo", resourceKey: "original", revision: "edited")
            var old = LivePhotoOperation(context: f.photos.context, contentIdentifier: "pair", photo: unknown ? photo : changed, motion: motion)
            old.stage = .blocked; old.nextRetryAt = Date(timeIntervalSince1970: 1)
            old.creationEvidence = unknown ? .unknown : .notSubmitted
            _ = try await f.store.reserveLivePhotoOperation(old)
            let restarted = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata())
            try await restarted.recover()
            for _ in 0..<2 { _ = try await restarted.advanceNext(now: Date(), refreshDiscovery: false) }
            let saved = try await f.store.livePhotoOperation(id: old.id), summary = try await restarted.summary()
            XCTAssertEqual(saved?.stage, .blocked)
            XCTAssertEqual(summary.unknownMutation, unknown)
            XCTAssertEqual(summary.retryWaitingGroups, 0, "Blocked attempts cannot be scheduled as automatic retries")
            let creates = await f.photos.creates; XCTAssertEqual(creates, 1)
        }
    }

    func testDeletedHeldGroupReleasesUnsubmittedSourceDespiteRetryOrProtectionHold() async throws {
        for reason in [LivePhotoDeferralReason.workingSetLimit, .protectedInformation, .otherFailure] {
            let f = try await completionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            try await completeEmptyInventory(f.store, f.photos.context)
            let file = try await f.store.sourceFile(id: f.first)
            var op = LivePhotoOperation(context: f.photos.context, contentIdentifier: "pair",
                photo: .source(fileID: f.first, stamp: try XCTUnwrap(file).file.stamp),
                motion: .photos(contextID: f.photos.context.id, assetID: "gone", resourceKey: "motion", revision: "r1"),
                sourceFileIDs: [f.first], oldAssetIDs: ["gone"])
            _ = try await f.store.reserveLivePhotoOperation(op)
            op.deferralReason = reason; op.nextRetryAt = reason == .otherFailure ? Date().addingTimeInterval(60) : .distantFuture
            _ = try await f.store.saveLivePhotoOperation(op, expectedStage: .planned)
            try f.store.recordLivePhotoChanges(context: f.photos.context, changed: [], deleted: ["gone"])
            let c = LivePhotoCoordinator(store: f.store, photos: f.photos, sourceAdmission: { _ in true })
            _ = try await c.advanceNext(now: Date(), refreshDiscovery: false)
            let reserved = try await f.store.livePhotoMemberIsReserved(id: f.first), state = try await f.store.state(of: f.first)
            XCTAssertFalse(reserved, "Deletion must release the still-unsubmitted file even when held: \(reason)")
            XCTAssertEqual(state, .pending)
            let creates = await f.photos.creates, retires = await f.photos.retires
            XCTAssertEqual(creates, 0); XCTAssertEqual(retires, 0)
        }
    }
    func testDeletedGroupCannotHideUnknownSubmission() async throws {
        let f = try await completionFixture(photosOnly: true); defer { try? FileManager.default.removeItem(at: f.root) }
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata())
        try await c.recover()
        // Discover a durable operation without starting its external mutation.
        await c.setPaused(true)
        let assets = try await f.photos.livePhotoAssets(assetIDs: ["old-photo", "old-motion"], context: f.photos.context)
        let photo = try XCTUnwrap(assets.first { $0.assetID == "old-photo" }), motion = try XCTUnwrap(assets.first { $0.assetID == "old-motion" })
        let op = LivePhotoOperation(context: f.photos.context, contentIdentifier: "pair", photo: photo.resources[0], motion: motion.resources[0], oldAssetIDs: ["old-photo", "old-motion"])
        _ = try await f.store.reserveLivePhotoOperation(op)
        try await f.store.beginLivePhotoCreation(operationID: op.id)
        try f.store.recordLivePhotoChanges(context: f.photos.context, changed: [], deleted: ["old-photo"])
        let summary = try await c.summary()
        XCTAssertTrue(summary.unknownMutation); XCTAssertEqual(summary.stoppedGroups, 0)
    }
    func testDiscoveryRefreshDoesNotExecuteUnadmittedGroupsAndResumesWhenDependencyClears() async throws {
        let f = try await completionFixture(photosOnly: true); defer { try? FileManager.default.removeItem(at: f.root) }
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata())
        try await f.store.enqueueLivePhotoAssets(context: f.photos.context, assets: [.init(context: f.photos.context,
            assetID: "unknown-complete", revision: "r1", isLivePhoto: true, mediaKind: .image, resources: [])])
        try await c.recover()
        let before = await f.photos.snapshotCount
        for _ in 0..<4 { _ = try await c.advanceNext(now: Date(), refreshDiscovery: true) }
        let after = await f.photos.snapshotCount, reads = await f.photos.rawReadCount
        XCTAssertEqual(after, before, "Discovery must not enter blocked planned operations or their Photos snapshot wait")
        XCTAssertEqual(reads, 0)
        try f.store.recordLivePhotoChanges(context: f.photos.context, changed: [], deleted: ["unknown-complete"])
        _ = try await c.advanceNext(now: Date(), refreshDiscovery: false)
        let created = await f.photos.creates; XCTAssertEqual(created, 1)
    }
    func testDisabledReservedSourceWakesResolutionAfterDiscoveryHasDrained() async throws {
        let f = try await completionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await completeEmptyInventory(f.store, f.photos.context)
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in false })
        do { _ = try await c.advanceNext(now: Date(), refreshDiscovery: false) }
        catch { XCTAssertTrue(error is PhotosAdmissionDeferred) }
        let before = try await c.hasDueWork(now: Date()); XCTAssertFalse(before)
        let reserved = try await f.store.livePhotoMemberIsReserved(id: f.first); XCTAssertTrue(reserved)
        try await f.store.disableSource(id: f.sourceID)
        let due = try await c.hasDueWork(now: Date()); XCTAssertTrue(due, "Stale members need resolution even though their disabled source cannot admit reads")
        if due { _ = try await c.advanceNext(now: Date(), refreshDiscovery: false) }
        for id in [f.first, f.second] {
            let held = try await f.store.livePhotoMemberIsReserved(id: id); XCTAssertFalse(held)
        }
        let creates = await f.photos.creates; XCTAssertEqual(creates, 0)
        let idle = try await c.hasDueWork(now: Date()); XCTAssertFalse(idle)
    }

    func testPlannedGroupWaitingForUnknownCompleteTargetIsNotRunnable() async throws {
        let f = try await completionFixture(photosOnly: true); defer { try? FileManager.default.removeItem(at: f.root) }
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata())
        let unknown = LivePhotoAssetDescriptor(context: f.photos.context, assetID: "unknown-complete", revision: "r1", isLivePhoto: true, mediaKind: .image, resources: [])
        try await f.store.enqueueLivePhotoAssets(context: f.photos.context, assets: [unknown])
        _ = try await c.advanceNext(now: Date(), refreshDiscovery: false)
        let activity = await c.activity(); XCTAssertEqual(activity, .waiting(nextRetryAt: nil))
        let due = try await c.hasDueWork(now: Date()); XCTAssertFalse(due)
        let creates = await f.photos.creates; XCTAssertEqual(creates, 0)
    }
    func testDiscoveryFinishesAndRevisitsLowKeyFactsAddedDuringPagedPass() async throws {
        let f = try await completionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await completeEmptyInventory(f.store, f.photos.context)
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
        for _ in 0..<5 { _ = try await c.advanceNext(now: Date(), refreshDiscovery: false) }
        let idle = try await c.hasDueWork(now: Date()); XCTAssertFalse(idle)
        for i in 0..<130 {
            let id = String(format: "z-%03d", i)
            try await f.store.saveLivePhotoObservation(.init(resource: .photos(contextID: f.photos.context.id, assetID: id, resourceKey: "motion", revision: "r1"), inspection: .identified(.init(contentIdentifier: id, role: .motion))))
        }
        _ = try await c.advanceNext(now: Date(), refreshDiscovery: true)
        for role in [LivePhotoRole.photo, .motion] {
            try await f.store.saveLivePhotoObservation(.init(resource: .photos(contextID: f.photos.context.id, assetID: "new-" + role.rawValue, resourceKey: role.rawValue, revision: "r1"), inspection: .identified(.init(contentIdentifier: "a-new", role: role))))
        }
        _ = try await c.advanceNext(now: Date(), refreshDiscovery: true)
        for _ in 0..<8 { _ = try await c.advanceNext(now: Date(), refreshDiscovery: false) }
        let group = try await f.store.livePhotoGroup(context: f.photos.context, contentIdentifier: "a-new"); XCTAssertNotNil(group)
        let finished = try await c.hasDueWork(now: Date()); XCTAssertFalse(finished)
    }
    func testAdmittedCompletionBetweenOperationsIsQueued() async throws {
        let f = try await completionFixture(photosOnly: true); defer { try? FileManager.default.removeItem(at: f.root) }
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata())
        _ = try await c.advanceNext(now: Date())
        let queued = await c.activity(); XCTAssertEqual(queued, .queued(.completion))
        await f.photos.setRawAdmission(.busy)
        let classified = await c.activity(); XCTAssertEqual(classified, .queued(.completion))
        await f.photos.setRawAdmission(.draining)
        let draining = await c.activity(); XCTAssertEqual(draining, .draining)
    }
    func testReusingExistingTargetRequiresFreshResourceTicketsBeforeSavingObservations() async throws {
        let f = try await completionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await completeEmptyInventory(f.store, f.photos.context)
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
        for _ in 0..<5 { _ = try await c.advanceNext(now: Date()) }
        let motion = try await appendCompletionSource(store: f.store, sourceID: f.sourceID, filename: "late.mov", kind: .video)
        try await c.observeDirectory(sourceID: f.sourceID, relativeDirectory: "", fileIDs: [motion])
        await f.photos.useRawValidity(.init(check: { throw LivePhotoReadDeferred.classificationPending }, release: {}))
        await f.photos.rejectSnapshotsAfterRawRead()
        do { _ = try await c.advanceNext(now: Date()); XCTFail("Unclassified target bytes accepted for reuse") }
        catch { XCTAssertEqual(error as? LivePhotoReadDeferred, .classificationPending) }
        let targets = try await f.photos.livePhotoAssets(assetIDs: ["complete"], context: f.photos.context)
        let target = try XCTUnwrap(targets.first)
        let observation = try await f.store.livePhotoObservation(for: target.resources[0])
        XCTAssertNil(observation)
        let state = try await f.store.state(of: motion); XCTAssertEqual(state, .pending)
        await f.photos.useRawValidity(nil)
        await f.photos.allowSnapshots()
        for _ in 0..<3 { _ = try await c.advanceNext(now: Date()) }
        let final = try await f.store.state(of: motion), creates = await f.photos.creates
        XCTAssertEqual(final, .skipped); XCTAssertEqual(creates, 1)
    }
    func testCompletionReadFailureOwnsOnlyItsOperationRetry() async throws {
        let f = try await completionFixture(photosOnly: true); defer { try? FileManager.default.removeItem(at: f.root) }
        let now = Date()
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), wallNow: { now })
        await f.photos.failRawRead(PhotosRepresentationError.unavailable)
        _ = try await c.advanceNext(now: now)
        let operations = try await f.store.loadLivePhotoOperationsForRecovery()
        let op = try XCTUnwrap(operations.first)
        XCTAssertEqual(op.nextRetryAt, now.addingTimeInterval(60)); XCTAssertEqual(op.deferralReason, .otherFailure)
        let before = await f.photos.rawReadCount
        _ = try await c.advanceNext(now: now.addingTimeInterval(1))
        let after = await f.photos.rawReadCount; XCTAssertEqual(after, before)
        await f.photos.failRawRead(nil)
        _ = try await c.advanceNext(now: now.addingTimeInterval(61))
        let creates = await f.photos.creates; XCTAssertEqual(creates, 1)
    }
    func testCompletionClassificationDeferralDoesNotPersistFailureDeadline() async throws {
        let f = try await completionFixture(photosOnly: true); defer { try? FileManager.default.removeItem(at: f.root) }
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata())
        await f.photos.failRawRead(LivePhotoReadDeferred.classificationPending)
        do { _ = try await c.advanceNext(now: Date()); XCTFail("Expected normal deferral") }
        catch { XCTAssertEqual(error as? LivePhotoReadDeferred, .classificationPending) }
        let operations = try await f.store.loadLivePhotoOperationsForRecovery()
        let op = try XCTUnwrap(operations.first)
        XCTAssertNil(op.nextRetryAt); XCTAssertNil(op.error); XCTAssertNil(op.deferralReason)
        await f.photos.failRawRead(nil)
        _ = try await c.advanceNext(now: Date())
        let creates = await f.photos.creates; XCTAssertEqual(creates, 1)
    }
    func testPauseAfterFirstCloudResourceDoesNotStartSecondRead() async throws {
        let f = try await completionFixture(photosOnly: true); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = InventoryReadGate(); await f.photos.holdRawRead(gate)
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata())
        let task = Task { try await c.advanceNext(now: Date()) }
        let entered = await engineEventually { await gate.entered }; XCTAssertTrue(entered)
        let reading = try await c.summary(); XCTAssertFalse(reading.hasOwnedSubmission)
        await c.setPaused(true); await gate.release(); _ = try await task.value
        let reads = await f.photos.rawReadCount; XCTAssertEqual(reads, 1)
        let creates = await f.photos.creates; XCTAssertEqual(creates, 0)
    }
    func testNormalInFlightCreateAndRetirementAreWorkRatherThanUnknown() async throws {
        for retirement in [false, true] {
            let f = try await completionFixture(photosOnly: true); defer { try? FileManager.default.removeItem(at: f.root) }
            let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata()), gate = InventoryReadGate()
            if retirement { for _ in 0..<2 { _ = try await c.advanceNext(now: Date()) } }
            await f.photos.holdMutation(gate, retirement: retirement)
            let task = Task { try await c.advanceNext(now: Date()) }
            let entered = await engineEventually { await gate.entered }; XCTAssertTrue(entered)
            let summary = try await c.summary(); XCTAssertFalse(summary.unknownMutation)
            XCTAssertTrue(summary.hasOwnedSubmission)
            XCTAssertEqual(summary.ownedImportingFiles, 0)
            let activity = await c.activity(); XCTAssertEqual(activity, .working(.completion))
            await c.setPaused(true)
            var snapshot = EngineSnapshot()
            snapshot.isPaused = true; snapshot.livePhotoWork = summary; snapshot.livePhotoActivities = [activity]
            let row = try XCTUnwrap(SyncStatusPresentation(snapshot: snapshot).progressRows.first)
            XCTAssertEqual(row.title, "正在结束当前操作", "Photos-only creates and retirement both own a submitted request")
            XCTAssertEqual(row.explanation, "已提交给“照片”的操作会继续收尾，之后暂停。")
            await gate.release(); _ = try await task.value
            let finished = try await c.summary(); XCTAssertFalse(finished.hasOwnedSubmission)
        }
    }
    func testChangedRevisionReopensWorkingSetLimitWithoutExplicitRetry() async throws {
        let f = try await completionFixture(photosOnly: true); defer { try? FileManager.default.removeItem(at: f.root) }
        let budget = LivePhotoResourceBudget(maxBytes: 5)
        await f.photos.useEncodedFixtures(bytes: 3)
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), budget: budget)
        do { _ = try await c.advanceNext(now: Date()); XCTFail("Expected working-set limit") } catch { }
        let changed = livePhotoAsset(context: f.photos.context, id: "old-photo", revision: "r2")
        await f.photos.replace(changed, bytes: 2)
        try await f.store.enqueueLivePhotoAssets(context: f.photos.context, assets: [changed])
        try await f.store.recordLivePhotoInventoryResult(context: f.photos.context, assetID: changed.assetID, revision: changed.revision, observations: [.init(resource: changed.resources[0], inspection: .identified(.init(contentIdentifier: "pair", role: .photo)))], retryPolicy: .requiresAttention)
        for _ in 0..<3 { _ = try await c.advanceNext(now: Date()) }
        let creates = await f.photos.creates; XCTAssertEqual(creates, 1)
    }
    func testReplacementResourceKeyReopensOnlyUnambiguousMatchingRole() async throws {
        for ambiguous in [false, true] {
            let f = try await completionFixture(photosOnly: true); defer { try? FileManager.default.removeItem(at: f.root) }
            let budget = LivePhotoResourceBudget(maxBytes: 5)
            await f.photos.useEncodedFixtures(bytes: 3)
            let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), budget: budget)
            do { _ = try await c.advanceNext(now: Date()); XCTFail("Expected limit") } catch { }
            let context = f.photos.context
            let refs = (0..<(ambiguous ? 2 : 1)).map { LivePhotoResourceRef.photos(contextID: context.id, assetID: "old-photo", resourceKey: "replacement-\($0)", revision: "r2") }
            let changed = LivePhotoAssetDescriptor(context: context, assetID: "old-photo", revision: "r2", isLivePhoto: false, mediaKind: .image, resources: refs)
            await f.photos.replace(changed, bytes: 2)
            try await f.store.applyLivePhotoDelta(.init(context: context, fromGeneration: 0, toGeneration: 1, changedAssetIDs: [changed.assetID], deletedAssetIDs: []))
            try await f.store.enqueueLivePhotoAssets(context: context, assets: [changed])
            try await f.store.recordLivePhotoInventoryResult(context: context, assetID: changed.assetID, revision: changed.revision, observations: refs.map { .init(resource: $0, inspection: .identified(.init(contentIdentifier: "pair", role: .photo))) }, retryPolicy: .requiresAttention)
            for _ in 0..<3 { _ = try await c.advanceNext(now: Date()) }
            let creates = await f.photos.creates; XCTAssertEqual(creates, ambiguous ? 0 : 1)
        }
    }
    func testCompletionDrainingIsNotReportedAsWorking() async throws {
        let f = try await completionFixture(photosOnly: true); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = InventoryReadGate(); await f.photos.holdRawRead(gate)
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata())
        let task = Task { try await c.advanceNext(now: Date()) }
        let entered = await engineEventually { await gate.entered }; XCTAssertTrue(entered)
        await f.photos.setRawAdmission(.draining)
        let activity = await c.activity(); XCTAssertEqual(activity, .draining)
        await c.setPaused(true); await gate.release(); _ = try await task.value
    }
    func testPairWorkingSetLimitIsHeldButOtherOwnersBudgetIsRetryable() async throws {
        for oversized in [true, false] {
            let f = try await completionFixture(photosOnly: true); defer { try? FileManager.default.removeItem(at: f.root) }
            let budget = LivePhotoResourceBudget(maxBytes: 5)
            await f.photos.useEncodedFixtures(bytes: oversized ? 3 : 2)
            if !oversized { try budget.reserve(2) }
            let coordinator = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), budget: budget)
            do { _ = try await coordinator.advanceNext(now: Date()); XCTFail("Expected capacity rejection") } catch { }
            let operations = try await f.store.loadLivePhotoOperationsForRecovery()
            let op = try XCTUnwrap(operations.first)
            let reads = await f.photos.rawReadCount
            if oversized {
                XCTAssertEqual(op.deferralReason, .workingSetLimit); XCTAssertEqual(op.nextRetryAt, .distantFuture)
                _ = try await coordinator.advanceNext(now: Date().addingTimeInterval(1000))
                let after = await f.photos.rawReadCount; XCTAssertEqual(after, reads)
                let summary = try await coordinator.summary(); XCTAssertEqual(summary.requiresAttentionGroups, 1)
                try await coordinator.retryAttention(now: Date())
                let rearmed = try await f.store.livePhotoOperation(id: op.id); XCTAssertNotEqual(rearmed?.nextRetryAt, .distantFuture)
            } else {
                XCTAssertNil(op.deferralReason); XCTAssertNil(op.error)
                budget.release(2)
                _ = try await coordinator.advanceNext(now: Date())
                let creates = await f.photos.creates; XCTAssertEqual(creates, 1)
            }
            XCTAssertEqual(budget.reservedBytes, 0)
        }
    }
    func testLegacyOperationWithoutDeferralReasonStillDecodes() throws {
        let context = LibraryContext(id: UUID(), epoch: 0)
        let op = LivePhotoOperation(context: context, contentIdentifier: "pair", photo: .source(fileID: UUID(), stamp: .init(size: 1, modifiedNanoseconds: 1)), motion: .source(fileID: UUID(), stamp: .init(size: 1, modifiedNanoseconds: 1)))
        let data = try JSONEncoder().encode(op)
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); value.removeValue(forKey: "deferralReason")
        let legacy = try JSONDecoder().decode(LivePhotoOperation.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertNil(legacy.deferralReason); XCTAssertEqual(legacy.id, op.id)
    }
    func testSourceGroupsWaitWithoutAdmissionDependency() async throws {
        let f = try await completionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await completeEmptyInventory(f.store, f.photos.context)
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata())
        for _ in 0..<5 { _ = try await c.advanceNext(now: Date()) }
        let creates = await f.photos.creates, first = try await f.store.state(of: f.first)
        XCTAssertEqual(creates, 0); XCTAssertEqual(first, .pending)
    }
    func testEquivalentCompleteAssetsDoNotGenerateEndlessOperations() async throws {
        let f = try await makeLivePhotoStoreFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let photos = CompletionPhotos(context: f.context, root: f.root)
        await photos.addComplete()
        let second = LivePhotoAssetDescriptor(context: f.context, assetID: "second-complete", revision: "r1", isLivePhoto: true, mediaKind: .image,
            resources: [.photos(contextID: f.context.id, assetID: "second-complete", resourceKey: "photo", revision: "r1"),
                        .photos(contextID: f.context.id, assetID: "second-complete", resourceKey: "motion", revision: "r1")], resourceKinds: [.image, .video])
        await photos.add(second)
        let all = try await photos.livePhotoAssets(assetIDs: ["complete", "second-complete"], context: f.context)
        try await f.store.enqueueLivePhotoAssets(context: f.context, assets: all)
        for d in all {
            try await f.store.recordLivePhotoInventoryResult(context: f.context, assetID: d.assetID, revision: d.revision,
                observations: d.resources.enumerated().map { i, ref in .init(resource: ref, inspection: .identified(.init(contentIdentifier: "pair", role: i == 0 ? .photo : .motion))) }, retryPolicy: .automatic(nextRetryAt: Date().addingTimeInterval(60)))
        }
        try await completeEmptyInventory(f.store, f.context)
        let c = LivePhotoCoordinator(store: f.store, photos: photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
        for _ in 0..<16 { _ = try await c.advanceNext(now: Date()) }
        let summary = try await c.summary(), creates = await photos.creates, retires = await photos.retires
        XCTAssertEqual(creates, 0); XCTAssertEqual(retires, 0); XCTAssertEqual(summary.activeGroups, 0)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM live_photo_operation", at: f.db), 1)
    }
    func testUnreadySourceGroupDoesNotStarvePhotosOnlyGroup() async throws {
        let f = try await completionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await completeEmptyInventory(f.store, f.photos.context)
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: IndependentGroupMetadata(), sourceAdmission: { _ in false })
        try await c.observeDirectory(sourceID: f.sourceID, relativeDirectory: "", fileIDs: [f.first, f.second])
        for (id, kind) in [("ready-photo", MediaKind.image), ("ready-motion", MediaKind.video)] {
            let asset = livePhotoAsset(context: f.photos.context, id: id, kind: kind)
            await f.photos.add(asset)
            try await f.store.enqueueLivePhotoAssets(context: f.photos.context, assets: [asset])
            try await f.store.recordLivePhotoInventoryResult(context: f.photos.context, assetID: id, revision: asset.revision,
                observations: [.init(resource: asset.resources[0], inspection: .identified(.init(contentIdentifier: "ready", role: kind == .image ? .photo : .motion)))], retryPolicy: .automatic(nextRetryAt: Date().addingTimeInterval(60)))
        }
        for _ in 0..<6 { _ = try await c.advanceNext(now: Date()) }
        let creates = await f.photos.creates, retires = await f.photos.retires, state = try await f.store.state(of: f.first)
        XCTAssertEqual(creates, 1); XCTAssertEqual(retires, 1)
        XCTAssertEqual(state, .pending, "Unready source pair remains held")
    }
    func testRepeatedLateCopiesReuseAnAlreadyInventoriedTarget() async throws {
        let f = try await completionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await completeEmptyInventory(f.store, f.photos.context)
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
        for _ in 0..<5 { _ = try await c.advanceNext(now: Date()) }
        let targets = try await f.photos.livePhotoAssets(assetIDs: ["complete"], context: f.photos.context)
        let target = try XCTUnwrap(targets.first)
        try await f.store.enqueueLivePhotoAssets(context: f.photos.context, assets: [target])
        let observations = target.resources.enumerated().map { i, ref in
            LivePhotoObservation(resource: ref, inspection: .identified(.init(contentIdentifier: "pair", role: i == 0 ? .photo : .motion)))
        }
        try await f.store.recordLivePhotoInventoryResult(context: f.photos.context, assetID: target.assetID, revision: target.revision, observations: observations, retryPolicy: .automatic(nextRetryAt: Date().addingTimeInterval(60)))
        for batch in 1...2 {
            let motion = try await appendCompletionSource(store: f.store, sourceID: f.sourceID, filename: "late-\(batch).mov", kind: .video)
            try await c.observeDirectory(sourceID: f.sourceID, relativeDirectory: "", fileIDs: [motion])
            for _ in 0..<6 { _ = try await c.advanceNext(now: Date()) }
            let state = try await f.store.state(of: motion), reserved = try await f.store.livePhotoMemberIsReserved(id: motion)
            XCTAssertEqual(state, .skipped, "Batch \(batch)"); XCTAssertFalse(reserved)
        }
        let creates = await f.photos.creates; XCTAssertEqual(creates, 1)
    }
    func testLaterCopiesCanReuseCompleteTargetWithAdditionalEditResources() async throws {
        let f = try await completionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await completeEmptyInventory(f.store, f.photos.context)
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
        for _ in 0..<5 { _ = try await c.advanceNext(now: Date()) }
        await f.photos.addExtraToComplete()
        let motion = try await appendCompletionSource(store: f.store, sourceID: f.sourceID, filename: "later.mov", kind: .video)
        try await c.observeDirectory(sourceID: f.sourceID, relativeDirectory: "", fileIDs: [motion])
        for _ in 0..<6 { _ = try await c.advanceNext(now: Date()) }
        let state = try await f.store.state(of: motion), creates = await f.photos.creates
        XCTAssertEqual(state, .skipped); XCTAssertEqual(creates, 1)
    }
    func testChangedUnsubmittedMemberReleasesPairAndKeepsSourceChangeSkip() async throws {
        let f = try await completionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await completeEmptyInventory(f.store, f.photos.context)
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
        try await c.observeDirectory(sourceID: f.sourceID, relativeDirectory: "", fileIDs: [f.first, f.second])
        let stored = try await f.store.sourceFile(id: f.first), url = try XCTUnwrap(stored).file.url
        try Data([3,4]).write(to: url)
        let stamp = try await DirectoryReader(sourceID: f.sourceID).stamp(of: url)
        _ = try await f.store.recordSourceChange(fileID: f.first, stamp: stamp)
        try await f.store.saveLivePhotoObservation(.init(resource: .source(fileID: f.first, stamp: stamp), inspection: .identified(.init(contentIdentifier: "pair", role: .photo))))
        for _ in 0..<5 { _ = try await c.advanceNext(now: Date()) }
        let reserved = try await f.store.livePhotoMemberIsReserved(id: f.second), state = try await f.store.state(of: f.first), creates = await f.photos.creates
        XCTAssertFalse(reserved); XCTAssertEqual(state, .skipped); XCTAssertEqual(creates, 0)
    }
    func testLaterSourceCopiesReuseCompletedGroupWithoutStandaloneMOV() async throws {
        let f = try await completionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await completeEmptyInventory(f.store, f.photos.context)
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
        for _ in 0..<5 { _ = try await c.advanceNext(now: Date()) }
        let photo = try await appendCompletionSource(store: f.store, sourceID: f.sourceID, filename: "later.jpg", kind: .image)
        let motion = try await appendCompletionSource(store: f.store, sourceID: f.sourceID, filename: "later.mov", kind: .video)
        try await c.observeDirectory(sourceID: f.sourceID, relativeDirectory: "", fileIDs: [photo, motion])
        let queued = try await f.store.nextPendingFile(sourceIDs: [f.sourceID], afterOrder: nil); XCTAssertNil(queued)
        for _ in 0..<6 { _ = try await c.advanceNext(now: Date()) }
        let creates = await f.photos.creates, state = try await f.store.state(of: motion), success = try await f.store.successIdentifier(of: motion)
        XCTAssertEqual(creates, 1); XCTAssertEqual(state, .skipped); XCTAssertNil(success)
    }
    func testLaterHalfReusesTargetWhileOldCleanupIsRetained() async throws {
        let f = try await completionFixture(photosOnly: true); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.photos.setUnknownCaption()
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
        for _ in 0..<5 { _ = try await c.advanceNext(now: Date()) }
        let motion = try await appendCompletionSource(store: f.store, sourceID: f.sourceID, filename: "later.mov", kind: .video)
        try await c.observeDirectory(sourceID: f.sourceID, relativeDirectory: "", fileIDs: [motion])
        let queued = try await f.store.nextPendingFile(sourceIDs: [f.sourceID], afterOrder: nil); XCTAssertNil(queued)
        for _ in 0..<6 { _ = try await c.advanceNext(now: Date()) }
        let creates = await f.photos.creates, retires = await f.photos.retires, state = try await f.store.state(of: motion)
        XCTAssertEqual(creates, 1); XCTAssertEqual(retires, 0); XCTAssertEqual(state, .skipped)
        let summary = try await c.summary(); XCTAssertEqual(summary.awaitingRetirement, 0)
        XCTAssertEqual(summary.limitedGroups, 0)
        let activity = await c.activity(); XCTAssertEqual(activity, .idle)
    }
    func testContextChangeDuringInputInspectionCannotRedirectNewPair() async throws {
        let f = try await completionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await completeEmptyInventory(f.store, f.photos.context)
        let gate = DirectoryTestGate(), entered = expectation(description: "input inspection")
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: GatedCompletionMetadata(gate: gate, entered: entered), sourceAdmission: { _ in true })
        let task = Task { try await c.advanceNext(now: Date()) }
        await fulfillment(of: [entered], timeout: 3)
        await f.photos.switchContext(); await gate.release(); _ = try await task.value
        let creates = await f.photos.creates; XCTAssertEqual(creates, 0)
    }
    func testForeignContextCannotConfirmOldPlaceholder() async throws {
        let f = try await completionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let op = livePhotoOperation(context: f.photos.context, photoID: f.first, motionID: f.second)
        // Use the current source stamps while reserving this fixture.
        var operation = op
        let p = try await f.store.sourceFile(id: f.first), m = try await f.store.sourceFile(id: f.second)
        operation.photo = .source(fileID: f.first, stamp: p!.file.stamp); operation.motion = .source(fileID: f.second, stamp: m!.file.stamp)
        _ = try await f.store.reserveLivePhotoOperation(operation)
        try await f.store.beginLivePhotoCreation(operationID: operation.id); try f.store.checkpointLivePhotoPlaceholder(operationID: operation.id, identifier: "complete")
        let other = CompletionPhotos(context: .init(id: UUID(), epoch: 0), root: f.root); await other.addComplete()
        let restarted = LivePhotoCoordinator(store: f.store, photos: other, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
        try await restarted.recover()
        let success = try await f.store.successIdentifier(of: f.first); XCTAssertNil(success)
        XCTAssertTrue(try f.store.hasUnconfirmedLivePhotoMutation())
    }
    func testRetirementAdmissionDeferralAutomaticallyResumes() async throws {
        let f = try await completionFixture(photosOnly: true); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.photos.deferNextRetirement()
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
        let now = Date()
        for _ in 0..<5 { _ = try await c.advanceNext(now: now) }
        for _ in 0..<3 { _ = try await c.advanceNext(now: now.addingTimeInterval(10)) }
        let creates = await f.photos.creates, retires = await f.photos.retires
        XCTAssertEqual(creates, 1); XCTAssertEqual(retires, 1)
    }
    func testSuccessCallbackDatabaseFailureRecoversPlaceholderWithoutRecreate() async throws {
        let f = try await completionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await completeEmptyInventory(f.store, f.photos.context)
        let db = f.root.appendingPathComponent("state.sqlite")
        try injectEngineSQL("CREATE TRIGGER fail_lp_confirm BEFORE UPDATE OF stage ON live_photo_operation WHEN NEW.stage='created' BEGIN SELECT RAISE(ABORT,'injected confirmation failure'); END", at: db)
        let first = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
        do { _ = try await first.advanceNext(now: Date()); XCTFail("Expected injected persistence failure") } catch { }
        XCTAssertTrue(try f.store.hasUnconfirmedLivePhotoMutation())
        let blocked = await f.photos.blocks; XCTAssertFalse(blocked.isEmpty)
        try injectEngineSQL("DROP TRIGGER fail_lp_confirm", at: db)
        let restarted = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true }); try await restarted.recover()
        for _ in 0..<4 { _ = try await restarted.advanceNext(now: Date()) }
        let calls = await f.photos.creates; XCTAssertEqual(calls, 1)
        let success = try await f.store.successIdentifier(of: f.first); XCTAssertEqual(success, "complete")
        XCTAssertFalse(try f.store.hasUnconfirmedLivePhotoMutation())
    }
    func testMissingHalfHasNoActiveGroup() async throws {
        let f = try await completionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try injectEngineSQL("UPDATE live_photo_observation SET current=0 WHERE role='motion'", at: f.root.appendingPathComponent("state.sqlite"))
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
        for _ in 0..<2 { _ = try await c.advanceNext(now: Date()) }
        let summary = try await c.summary(); XCTAssertEqual(summary.activeGroups, 0)
    }
    func testExistingCompleteTargetReusedWithoutForgedSuccess() async throws {
        let f = try await completionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.photos.addComplete()
        let descriptors = try await f.photos.livePhotoAssets(assetIDs: ["complete"], context: f.photos.context)
        let d = try XCTUnwrap(descriptors.first)
        try await f.store.enqueueLivePhotoAssets(context: f.photos.context, assets: [d])
        try await f.store.recordLivePhotoInventoryResult(context: f.photos.context, assetID: d.assetID, revision: d.revision, observations: d.resources.enumerated().map { i, ref in .init(resource: ref, inspection: .identified(.init(contentIdentifier: "pair", role: i == 0 ? .photo : .motion))) }, retryPolicy: .automatic(nextRetryAt: Date().addingTimeInterval(60)))
        try await completeEmptyInventory(f.store, f.photos.context)
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
        for _ in 0..<6 { _ = try await c.advanceNext(now: Date()) }
        let calls = await f.photos.creates, state = try await f.store.state(of: f.first), success = try await f.store.successIdentifier(of: f.first)
        XCTAssertEqual(calls, 0); XCTAssertEqual(state, .skipped); XCTAssertNil(success)
    }
    func testSourceAndPhotosPairBothArrivalOrdersUsePhotosOriginal() async throws {
        for photoInPhotos in [true, false] {
            let f = try await completionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let role: LivePhotoRole = photoInPhotos ? .photo : .motion
            let id = photoInPhotos ? "old-photo" : "old-motion"
            let d = livePhotoAsset(context: f.photos.context, id: id, kind: photoInPhotos ? .image : .video)
            await f.photos.add(d)
            try await f.store.enqueueLivePhotoAssets(context: f.photos.context, assets: [d])
            try await f.store.recordLivePhotoInventoryResult(context: f.photos.context, assetID: id, revision: d.revision, observations: [.init(resource: d.resources[0], inspection: .identified(.init(contentIdentifier: "pair", role: role)))], retryPolicy: .automatic(nextRetryAt: Date().addingTimeInterval(60)))
            try await completeEmptyInventory(f.store, f.photos.context)
            let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
            for _ in 0..<6 { _ = try await c.advanceNext(now: Date()) }
            let calls = await f.photos.creates, inputs = await f.photos.inputs
            XCTAssertEqual(calls, 1); XCTAssertTrue(inputs.contains(id))
        }
    }
    func testRecoveryFromCreatedVerifiedAndCompletedDoesNotRecreate() async throws {
        for phase in ["created", "verified", "complete"] {
            let f = try await completionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            try await completeEmptyInventory(f.store, f.photos.context)
            let first = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
            _ = try await first.advanceNext(now: Date())
            if phase != "created" { _ = try await first.advanceNext(now: Date()) }
            if phase == "complete" { _ = try await first.advanceNext(now: Date()) }
            let restarted = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true }); try await restarted.recover()
            for _ in 0..<5 { _ = try await restarted.advanceNext(now: Date()) }
            let calls = await f.photos.creates; XCTAssertEqual(calls, 1, phase)
        }
    }
    func testSameIDMultipleVersionsReleaseOrdinaryFilesWithoutCleanup() async throws {
        let f = try await completionFixture(photosOnly: true); defer { try? FileManager.default.removeItem(at: f.root) }
        let d = livePhotoAsset(context: f.photos.context, id: "different-photo")
        await f.photos.add(d)
        try await f.store.enqueueLivePhotoAssets(context: f.photos.context, assets: [d])
        try await f.store.recordLivePhotoInventoryResult(context: f.photos.context, assetID: d.assetID, revision: d.revision, observations: [.init(resource: d.resources[0], inspection: .identified(.init(contentIdentifier: "pair", role: .photo)))], retryPolicy: .automatic(nextRetryAt: Date().addingTimeInterval(60)))
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
        for _ in 0..<4 { _ = try await c.advanceNext(now: Date()) }
        let calls = await f.photos.creates, retires = await f.photos.retires; XCTAssertEqual(calls, 0); XCTAssertEqual(retires, 0)
        let operations = try await f.store.loadLivePhotoOperationsForRecovery()
        XCTAssertEqual(operations.count, 1, "Unchanged ambiguity must not create an operation each tick")
    }
    func testSourcePairReservedBeforeInventoryAndNotSplit() async throws {
        let f = try await completionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
        try await c.observeDirectory(sourceID: f.sourceID, relativeDirectory: "", fileIDs: [f.first, f.second])
        let pending = try await f.store.nextPendingFile(sourceIDs: [f.sourceID], afterOrder: nil); XCTAssertNil(pending)
        _ = try await c.advanceNext(now: Date())
        let calls = await f.photos.creates; XCTAssertEqual(calls, 0)
    }
    func testSourcePairCreatesOneAndSharedSuccessSurvivesRestart() async throws {
        let f = try await completionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await completeEmptyInventory(f.store, f.photos.context)
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
        for _ in 0..<6 { _ = try await c.advanceNext(now: Date()) }
        let first = try await f.store.successIdentifier(of: f.first), second = try await f.store.successIdentifier(of: f.second)
        XCTAssertEqual(first, "complete"); XCTAssertEqual(first, second)
        let again = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true }); try await again.recover()
        for _ in 0..<4 { _ = try await again.advanceNext(now: Date()) }
        let calls = await f.photos.creates; XCTAssertEqual(calls, 1)
    }
    func testPhotosOnlyUsesExactOldResourcesThenVerifiesBeforeRetiring() async throws {
        let f = try await completionFixture(photosOnly: true); defer { try? FileManager.default.removeItem(at: f.root) }
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
        for _ in 0..<8 { _ = try await c.advanceNext(now: Date()) }
        let events = await f.photos.events; XCTAssertEqual(events, ["create", "verify", "retire"])
        let inputs = await f.photos.inputs; XCTAssertEqual(inputs, ["old-photo", "old-motion"])
        let count = try await f.store.countFiles(state: .imported); XCTAssertEqual(count, 0)
    }
    func testUnknownCompleteCandidateBlocksNewPair() async throws {
        let f = try await completionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let unknown = livePhotoAsset(context: f.photos.context, id: "cloud-full", isLivePhoto: true)
        try await f.store.enqueueLivePhotoAssets(context: f.photos.context, assets: [unknown])
        try await f.store.recordLivePhotoInventoryResult(context: f.photos.context, assetID: unknown.assetID, revision: unknown.revision, observations: [.init(resource: unknown.resources[0], inspection: .unresolved("cloud"))], retryPolicy: .automatic(nextRetryAt: Date().addingTimeInterval(60)))
        try await completeEmptyInventory(f.store, f.photos.context)
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
        for _ in 0..<4 { _ = try await c.advanceNext(now: Date()) }
        let calls = await f.photos.creates; XCTAssertEqual(calls, 0)
    }
    func testUnknownCreationCheckpointRecoveredWithoutRecreate() async throws {
        let f = try await completionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await completeEmptyInventory(f.store, f.photos.context)
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
        try await c.observeDirectory(sourceID: f.sourceID, relativeDirectory: "", fileIDs: [f.first, f.second])
        let loaded = try await f.store.loadLivePhotoOperationsForRecovery()
        let op = try XCTUnwrap(loaded.first)
        try await f.store.beginLivePhotoCreation(operationID: op.id)
        try f.store.checkpointLivePhotoPlaceholder(operationID: op.id, identifier: "complete")
        await f.photos.addComplete()
        let again = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true }); try await again.recover()
        for _ in 0..<4 { _ = try await again.advanceNext(now: Date()) }
        let calls = await f.photos.creates; XCTAssertEqual(calls, 0)
        let success = try await f.store.successIdentifier(of: f.first); XCTAssertEqual(success, "complete")
    }
    func testUserDeletionNeverRecreatesGroup() async throws {
        let f = try await completionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await completeEmptyInventory(f.store, f.photos.context)
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
        try await c.observeDirectory(sourceID: f.sourceID, relativeDirectory: "", fileIDs: [f.first, f.second])
        let loaded = try await f.store.loadLivePhotoOperationsForRecovery()
        let op = try XCTUnwrap(loaded.first)
        try await f.store.beginLivePhotoCreation(operationID: op.id); try await f.store.confirmLivePhotoCreation(operationID: op.id, identifier: "gone")
        try f.store.recordLivePhotoChanges(context: f.photos.context, changed: [], deleted: ["gone"])
        let next = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true }); try await next.recover()
        for _ in 0..<4 { _ = try await next.advanceNext(now: Date()) }
        let creates = await f.photos.creates, retires = await f.photos.retires; XCTAssertEqual(creates, 0); XCTAssertEqual(retires, 0)
        let summary = try await next.summary()
        XCTAssertEqual(summary.requiresAttentionGroups, 0); XCTAssertEqual(summary.activeGroups, 0)
        XCTAssertEqual(summary.limitedGroups, 0); XCTAssertNil(summary.issue)
    }
    func testUnknownRetirementBlocksAndNeverRetriesMissingFetch() async throws {
        let f = try await completionFixture(photosOnly: true); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.photos.setRetirementUnknown()
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true })
        for _ in 0..<8 { _ = try await c.advanceNext(now: Date()) }
        let next = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true }); try await next.recover()
        for _ in 0..<4 { _ = try await next.advanceNext(now: Date()) }
        let count = await f.photos.retires, blocks = await f.photos.blocks
        XCTAssertEqual(count, 1); XCTAssertFalse(blocks.isEmpty)
    }
    func testUnknownInformationRetainsOldItemsAndPausePreventsCreate() async throws {
        let f = try await completionFixture(photosOnly: true); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.photos.setUnknownCaption()
        let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata(), sourceAdmission: { _ in true }); await c.setPaused(true)
        _ = try await c.advanceNext(now: Date()); let before = await f.photos.creates; XCTAssertEqual(before, 0)
        await c.setPaused(false)
        for _ in 0..<8 { _ = try await c.advanceNext(now: Date()) }
        let creates = await f.photos.creates, retires = await f.photos.retires; XCTAssertEqual(creates, 1); XCTAssertEqual(retires, 0)
        let summary = try await c.summary(); XCTAssertEqual(summary.awaitingRetirement, 0)
        XCTAssertEqual(summary.limitedGroups, 0)
        let activity = await c.activity(); XCTAssertEqual(activity, .idle)
    }
    func testUnknownOrChangedTitlesDoNotPreventVerifiedRetirement() async throws {
        for unknownTitle in [true, false] {
            let f = try await completionFixture(photosOnly: true); defer { try? FileManager.default.removeItem(at: f.root) }
            if unknownTitle { await f.photos.setUnknownTitle() }
            else { await f.photos.setTitle(.value("original title"), assetID: "old-photo") }
            let c = LivePhotoCoordinator(store: f.store, photos: f.photos, metadata: CompletionMetadata())
            _ = try await c.advanceNext(now: Date())
            _ = try await c.advanceNext(now: Date())
            let operations = try await f.store.loadLivePhotoOperationsForRecovery()
            XCTAssertEqual(operations.first?.stage, .readyToRetire)
            if !unknownTitle { await f.photos.setTitle(.value("changed title"), assetID: "old-photo") }
            _ = try await c.advanceNext(now: Date())
            let old = try await f.photos.livePhotoAssets(assetIDs: ["old-photo", "old-motion"], context: f.photos.context)
            let targets = try await f.photos.livePhotoAssets(assetIDs: ["complete"], context: f.photos.context)
            let events = await f.photos.events, summary = try await c.summary()
            XCTAssertTrue(old.isEmpty)
            XCTAssertEqual(targets.count, 1); XCTAssertEqual(targets.first?.isLivePhoto, true)
            XCTAssertEqual(events, ["create", "verify", "retire"])
            XCTAssertEqual(summary.awaitingRetirement, 0)
        }
    }
}

func completeEmptyInventory(_ store: SyncStore, _ context: LibraryContext) async throws {
    try await store.ensureLivePhotoInventory(context: context); try await store.finishLivePhotoEnumeration(context: context, generation: 0)
    _ = try await store.completeLivePhotoInventory(context: context, expectedGeneration: 0)
}

func completionFixture(photosOnly: Bool = false) async throws -> (root: URL, store: SyncStore, photos: CompletionPhotos, sourceID: UUID, first: UUID, second: UUID) {
    let f = try await makeLivePhotoStoreFixture(), photos = CompletionPhotos(context: f.context, root: f.root)
    if photosOnly {
        try injectEngineSQL("DELETE FROM file_record", at: f.db)
        for (id, role) in [("old-photo", LivePhotoRole.photo), ("old-motion", .motion)] {
            let asset = livePhotoAsset(context: f.context, id: id, kind: role == .photo ? .image : .video)
            await photos.add(asset)
            try await f.store.enqueueLivePhotoAssets(context: f.context, assets: [asset])
            try await f.store.recordLivePhotoInventoryResult(context: f.context, assetID: id, revision: asset.revision, observations: [.init(resource: asset.resources[0], inspection: .identified(.init(contentIdentifier: "pair", role: role)))], retryPolicy: .automatic(nextRetryAt: Date().addingTimeInterval(60)))
        }
        try await completeEmptyInventory(f.store, f.context)
    } else {
        for (id, role) in [(f.first, LivePhotoRole.photo), (f.second, .motion)] {
            let stored = try await f.store.sourceFile(id: id)
            let file = try XCTUnwrap(stored)
            try Data([role == .photo ? 1 : 2]).write(to: file.file.url)
            let stamp = try await DirectoryReader(sourceID: f.sourceID).stamp(of: file.file.url)
            try injectEngineSQL("UPDATE file_record SET size=\(stamp.size),modified_ns=\(stamp.modifiedNanoseconds) WHERE id='\(id.uuidString)'", at: f.db)
            try await f.store.saveLivePhotoObservation(.init(resource: .source(fileID: id, stamp: stamp), inspection: .identified(.init(contentIdentifier: "pair", role: role))))
        }
    }
    return (f.root, f.store, photos, f.sourceID, f.first, f.second)
}

actor CompletionPhotos: LivePhotoPhotosGateway {
    nonisolated let context: LibraryContext
    let root: URL
    var activeContext: LibraryContext?
    var generation = 0
    func switchContext() { activeContext = .init(id: UUID(), epoch: 0); generation += 1 }
    var rawGate: InventoryReadGate?, createGate: InventoryReadGate?, retirementGate: InventoryReadGate?
    var rawAdmission: PhotosReaderAdmission = .available
    var encodedSizes: [String: Int] = [:]
    func replace(_ asset: LivePhotoAssetDescriptor, bytes: Int) { assets.removeAll { $0.assetID == asset.assetID }; assets.append(asset); encodedSizes[asset.assetID] = bytes }
    func holdRawRead(_ gate: InventoryReadGate) { rawGate = gate }
    func holdMutation(_ gate: InventoryReadGate, retirement: Bool) { if retirement { retirementGate = gate } else { createGate = gate } }
    func setRawAdmission(_ value: PhotosReaderAdmission) { rawAdmission = value }
    func livePhotoReadAdmission() async -> PhotosReaderAdmission { rawAdmission }
    var encodedFixtureBytes: Int?
    var rawReadCount = 0, snapshotCount = 0
    var rawFailure: Error?
    var rejectSnapshotAfterRead = false, rawReadSinceTrap = false
    func rejectSnapshotsAfterRawRead() { rejectSnapshotAfterRead = true; rawReadSinceTrap = false }
    func allowSnapshots() { rejectSnapshotAfterRead = false }
    var rawValidity: LivePhotoResourceValidity?
    func useRawValidity(_ value: LivePhotoResourceValidity?) { rawValidity = value }
    func failRawRead(_ error: Error?) { rawFailure = error }
    func useEncodedFixtures(bytes: Int) { encodedFixtureBytes = bytes }
    var createdResourceURLs = [MediaKind: URL]()
    var liveCatalogCalls = 0
    var assets = [LivePhotoAssetDescriptor](), creates = 0, retires = 0, events = [String](), inputs = [String]()
    var blocks = Set<UUID>(), unknownRetirement = false, unknownTitle = false
    private var nativeJournal: URL?, crashCheckpoint: String?
    struct NativeJournal: Codable {
        let assets: [LivePhotoAssetDescriptor], creates: Int, retires: Int
    }
    func attachNativeJournal(root: URL, restore: Bool, checkpoint: String?) throws {
        try PortableRuntimeSession.validate(root)
        let url = root.appendingPathComponent("native-journal.json")
        if restore {
            let saved = try JSONDecoder().decode(NativeJournal.self, from: Data(contentsOf: url))
            assets = saved.assets; creates = saved.creates; retires = saved.retires
        }
        nativeJournal = url; crashCheckpoint = checkpoint
        try saveNativeJournal()
    }
    private func saveNativeJournal() throws {
        if let nativeJournal {
            try JSONEncoder().encode(NativeJournal(assets: assets, creates: creates, retires: retires)).write(to: nativeJournal, options: .atomic)
        }
    }
    var unknownCaption = false, titles = [String: PreservedField<String>]()
    var retirementDeferrals = 0
    func deferNextRetirement() { retirementDeferrals += 1 }
    func verifyLivePhotoContext(context: LibraryContext, anchorAssetIDs: [String], allowUnanchored: Bool) async throws -> Bool { context == self.context }
    init(context: LibraryContext, root: URL) { self.context = context; self.root = root }
    func add(_ a: LivePhotoAssetDescriptor) { assets.append(a) }
    func setRetirementUnknown() { unknownRetirement = true }
    func setUnknownTitle() { unknownTitle = true }
    func setUnknownCaption() { unknownCaption = true }
    func setTitle(_ title: PreservedField<String>, assetID: String) { titles[assetID] = title }
    func addExtraToComplete() {
        guard let d = assets.first(where: { $0.assetID == "complete" }) else { return }
        assets.removeAll { $0.assetID == "complete" }
        assets.append(.init(context: context, assetID: d.assetID, revision: d.revision, isLivePhoto: true, mediaKind: .image,
            resources: d.resources + [.photos(contextID: context.id, assetID: d.assetID, resourceKey: "adjustment", revision: d.revision)], resourceKinds: [.image, .video, nil]))
    }
    func addComplete() { assets.append(.init(context: context, assetID: "complete", revision: "r1", isLivePhoto: true, mediaKind: .image, resources: [.photos(contextID: context.id, assetID: "complete", resourceKey: "photo", revision: "r1"), .photos(contextID: context.id, assetID: "complete", resourceKey: "motion", revision: "r1")], resourceKinds: [.image, .video])) }
    func candidateSnapshot() async throws -> PhotosCandidateSnapshot {
        snapshotCount += 1
        if rejectSnapshotAfterRead && rawReadSinceTrap { throw PhotosRepresentationError.unavailable }
        return .init(generation: generation, candidates: [])
    }
    func livePhotoLibraryContext() async throws -> LibraryContext { activeContext ?? context }
    func setLivePhotoRecoveryBlocks(_ ids: Set<UUID>) async { blocks = ids }
    func createLivePhoto(photoURL: URL, motionURL: URL, photoFilename: String?, motionFilename: String?, preservation: LivePhotoPreservationSnapshot, expectedGeneration: Int, beforeMutation: @escaping @Sendable () throws -> Bool, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        guard expectedGeneration == generation, try beforeMutation() else { throw PhotosAdmissionDeferred() }
        if nativeJournal != nil, crashCheckpoint == "intent" { _exit(86) }
        creates += 1; events.append("create"); inputs = [photoURL.lastPathComponent, motionURL.lastPathComponent]
        createdResourceURLs = [.image: photoURL, .video: motionURL]
        if nativeJournal != nil {
            if crashCheckpoint == "placeholder" {
                try onPlaceholder("complete"); try saveNativeJournal(); _exit(86)
            }
            // This journal represents the independent system, not local success.
            addComplete(); try saveNativeJournal(); try onPlaceholder("complete")
            if crashCheckpoint == "system-committed" { _exit(86) }
        } else { try onPlaceholder("complete"); addComplete() }
        if let gate = createGate { createGate = nil; await gate.hold() }; return "complete"
    }
    func verifyLivePhoto(assetID: String, operation: LivePhotoOperation) async throws -> LivePhotoVerification { events.append("verify"); return .init(assetID: assetID, revision: "r1", passed: true, details: ["fake verified native content"]) }
    func retireLivePhotoComponents(assetIDs: [String], expectedGeneration: Int, beforeMutation: @escaping @Sendable () throws -> Bool) async throws {
        guard try beforeMutation() else { throw PhotosAdmissionDeferred() }
        if retirementDeferrals > 0 { retirementDeferrals -= 1; throw PhotosAdmissionDeferred() }
        retires += 1; events.append("retire")
        if let gate = retirementGate { retirementGate = nil; await gate.hold() }
        if unknownRetirement { throw PhotoKitGatewayError.resultUnknown("test") }
        assets.removeAll { assetIDs.contains($0.assetID) }
        try saveNativeJournal()
        if nativeJournal != nil, crashCheckpoint == "retirement-unconfirmed" { _exit(86) }
    }
    func livePhotoAssets(assetIDs: [String], context: LibraryContext) async throws -> [LivePhotoAssetDescriptor] { assets.filter { assetIDs.contains($0.assetID) } }
    func livePhotoPreservationSnapshot(assetID: String, context: LibraryContext) async throws -> LivePhotoPreservationSnapshot {
        var value = knownLivePhotoSnapshot()
        if unknownTitle { value.title = .unknown }
        if let title = titles[assetID] { value.title = title }
        if unknownCaption { value.caption = .unknown }
        return value
    }
    func readLivePhotoResource(_ ref: LivePhotoResourceRef, purpose: LivePhotoReadPurpose, budget: LivePhotoResourceBudget) async throws -> LivePhotoResourceLease {
        rawReadSinceTrap = true
        rawReadCount += 1
        if let rawFailure { throw rawFailure }
        if let gate = rawGate { rawGate = nil; await gate.hold() }
        let kind: MediaKind = ref.key.contains("motion") ? .video : .image
        if let count = encodedSizes[ref.assetID ?? ""] ?? encodedFixtureBytes {
            let bytes = Int64(count)
            guard bytes <= budget.limits.maxEncodedBytes else { throw LivePhotoResourceReadError.resourceLimit(bytes: bytes) }
            do { try budget.reserve(bytes) } catch { throw LivePhotoResourceReadError.budgetBusy(resourceBytes: bytes) }
            let owner = try PhotosResourceStorage(root: root.appendingPathComponent("encoded")).create(limits: budget.limits)
            try owner.append(Data(repeating: kind == .image ? 1 : 2, count: count)); try owner.closeStream()
            return .init(url: owner.url, owner: owner, budget: budget, bytes: bytes)
        }
        let url = root.appendingPathComponent(ref.assetID! + (ref.assetID == "complete" ? (kind == .image ? "-photo" : "-motion") : ""))
        let bytes = ref.assetID == "complete" && createdResourceURLs[kind] != nil ? try Data(contentsOf: createdResourceURLs[kind]!) : Data([ref.key.contains("different-photo") ? 3 : (kind == .video ? 2 : 1)])
        try bytes.write(to: url); return .init(url: url, validity: rawValidity)
    }
    func resourcesEqual(_ lhs: LivePhotoResourceRef, _ rhs: LivePhotoResourceRef, budget: LivePhotoResourceBudget) async throws -> Bool { true }
    func reconcile(placeholder: String?) async throws -> ImportEvidence { assets.contains { $0.assetID == placeholder } ? .found(identifier: placeholder!) : .unknown }
    func create(fileURL: URL, kind: MediaKind, expectedGeneration: Int, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String { throw PhotosAdmissionDeferred() }
    func livePhotoAssetCatalog(session: PhotosCatalogSession, offset: Int, limit: Int) async throws -> LivePhotoAssetPage { liveCatalogCalls += 1; return .init(context: context, generation: 0, assets: assets, nextOffset: nil) }
    func representationCatalog(offset: Int, limit: Int, expectedGeneration: Int) async throws -> RepresentationPage { .init(context: context, generation: 0, descriptors: [], nextOffset: nil) }
    nonisolated func changes() -> AsyncStream<PhotosIndexChange> { AsyncStream { $0.finish() } }
    func readRepresentation(_ descriptor: RepresentationDescriptor) async throws -> LoadedRepresentation { throw PhotosRepresentationError.unavailable }
}

struct CompletionMetadata: LivePhotoMetadataReading {
    func inspect(url: URL, kind: MediaKind) async throws -> LivePhotoInspection {
        .identified(.init(contentIdentifier: "pair", role: kind == .image ? .photo : .motion, stillImageTime: kind == .video ? 0.5 : nil, hasAudio: kind == .video ? false : nil))
    }
}

private struct IndependentGroupMetadata: LivePhotoMetadataReading {
    func inspect(url: URL, kind: MediaKind) async throws -> LivePhotoInspection {
        .identified(.init(contentIdentifier: url.lastPathComponent.contains("ready") ? "ready" : "pair",
            role: kind == .image ? .photo : .motion, stillImageTime: kind == .video ? 0.5 : nil, hasAudio: false))
    }
}

struct GatedCompletionMetadata: LivePhotoMetadataReading {
    let gate: DirectoryTestGate
    let entered: XCTestExpectation
    func inspect(url: URL, kind: MediaKind) async throws -> LivePhotoInspection {
        if kind == .image { entered.fulfill(); await gate.wait() }
        return try await CompletionMetadata().inspect(url: url, kind: kind)
    }
}

func appendCompletionSource(store: SyncStore, sourceID: UUID, filename: String, kind: MediaKind) async throws -> UUID {
    let source = try await store.source(id: sourceID), url = source.url.appendingPathComponent(filename)
    try Data([kind == .image ? 1 : 2]).write(to: url)
    let stamp = try await DirectoryReader(sourceID: sourceID).stamp(of: url)
    let file = SourceFile(sourceID: sourceID, relativePath: filename, url: url, stamp: stamp,
        metadata: .init(filename: filename, kind: kind, captureSecond: nil, rawCaptureTime: nil, make: nil, model: nil, width: nil, height: nil, duration: nil))
    let id = try await store.save(file, decision: .importNew)
    try await store.saveLivePhotoObservation(.init(resource: .source(fileID: id, stamp: stamp), inspection: .identified(.init(contentIdentifier: "pair", role: kind == .image ? .photo : .motion))))
    return id
}
