import XCTest
@testable import PhotoSyncCore

final class LivePhotoInventoryTests: XCTestCase {
    func testFixedResourceLimitEndsNormallyAcrossManualRetryAndRestart() async throws {
        let f = try await inventoryFixture(count: 1)
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.photos.setReadFailure(.resourceLimit(bytes: 600_000_000))
        let task = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        try await task.resumeInitialInventory()
        _ = try await task.processNextInventoryItem(now: Date())
        let first = try await task.summary()
        XCTAssertEqual(first.phase, .completed)
        XCTAssertEqual(first.identified, 0, "Uninspected bytes must not become identified evidence")
        XCTAssertEqual(first.unresolved, 0)
        XCTAssertEqual(first.requiresAttention, 0)
        XCTAssertEqual(first.skipped, 1); XCTAssertEqual(first.processed, 1)
        let activity = await task.activity(); XCTAssertEqual(activity, .idle)
        try await task.retryAttention(now: Date())
        let retried = try await task.processNextInventoryItem(now: .distantFuture)
        XCTAssertFalse(retried)
        let reopened = try SyncStore(url: f.db)
        let restarted = LivePhotoInventoryCoordinator(store: reopened, photos: f.photos, metadata: InventoryMetadata())
        let catalogBefore = await f.photos.catalogCalls
        try await restarted.resumeInitialInventory()
        try await restarted.retryAttention(now: Date())
        let advanced = try await restarted.processNextInventoryItem(now: .distantFuture)
        XCTAssertFalse(advanced)
        let reads = await f.photos.resourceReads, catalogAfter = await f.photos.catalogCalls
        XCTAssertEqual(reads, 1); XCTAssertEqual(catalogAfter, catalogBefore)
        let replacement = livePhotoAsset(context: f.photos.context, id: "asset-0", revision: "r2")
        try await reopened.enqueueLivePhotoAssets(context: f.photos.context, assets: [replacement])
        let pending = try await reopened.nextLivePhotoInventoryItem(context: f.photos.context, now: Date())
        XCTAssertEqual(pending, replacement)
    }

    func testV11UpgradeOnlyConvertsCurrentCapOnlyInventoryHolds() async throws {
        let f = try await makeLivePhotoStoreFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let context = f.context
        let cap = livePhotoAsset(context: context, id: "cap", isLivePhoto: true)
        let assets = [cap] + ["cap-retry", "generic", "mixed", "stale", "inactive", "missing"].map {
            livePhotoAsset(context: context, id: $0)
        }
        try await f.store.ensureLivePhotoInventory(context: context)
        try await f.store.enqueueLivePhotoAssets(context: context, assets: assets)
        for asset in assets {
            var observations = [LivePhotoObservation(resource: asset.resources[0], inspection: .unresolved("fixture"),
                resourceLimitBytes: asset.assetID == "generic" ? nil : 536_870_912)]
            if asset.assetID == "mixed" {
                observations.append(.init(resource: .photos(contextID: context.id, assetID: asset.assetID, resourceKey: "other", revision: asset.revision), inspection: .unresolved("independent failure")))
            }
            try await f.store.recordLivePhotoInventoryResult(context: context, assetID: asset.assetID, revision: asset.revision,
                observations: observations, retryPolicy: .requiresAttention)
        }
        try await f.store.finishLivePhotoEnumeration(context: context, generation: 1)
        _ = try await f.store.completeLivePhotoInventory(context: context, expectedGeneration: 1)
        let before = try await f.store.livePhotoInventorySummary(context: context)
        let attempt = UUID()
        try await f.store.beginAttempt(fileID: f.first, attemptID: attempt)
        try await f.store.markImported(fileID: f.first, attemptID: attempt, identifier: "existing-success")
        let op = livePhotoOperation(context: context, photoID: f.first, motionID: f.second)
        let reserved = try await f.store.reserveLivePhotoOperation(op); XCTAssertTrue(reserved)
        try await f.store.beginLivePhotoCreation(operationID: op.id)
        try f.store.checkpointLivePhotoPlaceholder(operationID: op.id, identifier: "unconfirmed-target")
        try await f.store.deferLivePhotoCreation(operationID: op.id, detail: "synthetic unknown callback", definite: false)
        let operationsBefore = try await f.store.loadLivePhotoOperationsForRecovery()
        // Seed the old persistent representation independently of the new result writer.
        try injectEngineSQL("""
            UPDATE live_photo_inventory_item SET status='unresolved',next_retry_at=NULL;
            UPDATE live_photo_inventory_item SET next_retry_at=1000 WHERE asset_id='cap-retry';
            UPDATE live_photo_inventory_item SET revision='newer' WHERE asset_id='stale';
            UPDATE live_photo_observation SET current=0 WHERE asset_id='inactive';
            UPDATE live_photo_inventory_item SET descriptor=NULL WHERE asset_id='missing';
            PRAGMA user_version=11;
            """, at: f.db)
        let migrated = try SyncStore(url: f.db)
        let after = try await migrated.livePhotoInventorySummary(context: context)
        XCTAssertEqual(after.requiresAttention, 5); XCTAssertEqual(after.unresolved, 5)
        XCTAssertEqual(after.identified, 0); XCTAssertEqual(after.completedAt, before.completedAt)
        XCTAssertEqual(after.skipped, 2); XCTAssertEqual(after.processed, 2)
        XCTAssertEqual(after.retryWaiting, 0)
        for asset in assets {
            let status = ["cap", "cap-retry"].contains(asset.assetID) ? "resourceLimitSkipped" : "unresolved"
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM live_photo_inventory_item WHERE asset_id='\(asset.assetID)' AND status='\(status)'", at: f.db), 1, asset.assetID)
        }
        let success = try await migrated.successIdentifier(of: f.first)
        XCTAssertEqual(success, "existing-success")
        let operationsAfter = try await migrated.loadLivePhotoOperationsForRecovery()
        XCTAssertEqual(operationsAfter, operationsBefore)
        XCTAssertEqual(operationsAfter.first?.creationEvidence, .unknown)
        XCTAssertTrue(operationsAfter.first?.holdsUnknownMutation == true)
        let uncertainNative = try await migrated.hasUnresolvedLivePhotoCandidates(context: context)
        XCTAssertTrue(uncertainNative, "Skipping cannot prove an existing native candidate is unrelated")
        let retryCount = try await migrated.retryLivePhotoInventoryAttention(context: context, now: Date())
        XCTAssertEqual(retryCount, 5)
        let twice = try SyncStore(url: f.db)
        let again = try await twice.livePhotoInventorySummary(context: context)
        XCTAssertEqual(again.unresolved, 5); XCTAssertEqual(again.identified, 0)
        XCTAssertEqual(again.skipped, 2)
    }

    func testNativeInventoryGetsPriorityWithOrdinaryWorkAfterEightItems() async throws {
        let f = try await inventoryFixture(count: 0); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.photos.appendAsset(livePhotoAsset(context: f.photos.context, id: "a-ordinary"))
        for index in 0..<10 { await f.photos.appendAsset(livePhotoAsset(context: f.photos.context, id: "n-\(index)", isLivePhoto: true)) }
        let c = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        try await c.resumeInitialInventory()
        for _ in 0..<9 { _ = try await c.processNextInventoryItem(now: Date()) }
        let order = await f.photos.readAssetIDs
        XCTAssertEqual(order, ["n-0", "n-1", "n-2", "n-3", "n-4", "n-5", "n-6", "n-7", "a-ordinary"])
        let restart = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        try await restart.resumeInitialInventory()
        _ = try await restart.processNextInventoryItem(now: Date())
        let resumed = await f.photos.readAssetIDs, calls = await f.photos.catalogCalls
        XCTAssertEqual(resumed.last, "n-8"); XCTAssertEqual(calls, 1)
    }

    func testNativeRetryPreferenceNeverPullsFutureRetryForward() async throws {
        for due in [false, true] {
            let f = try await inventoryFixture(count: 0); defer { try? FileManager.default.removeItem(at: f.root) }
            let native = livePhotoAsset(context: f.photos.context, id: "z-native", isLivePhoto: true), now = Date()
            await f.photos.appendAsset(livePhotoAsset(context: f.photos.context, id: "a-ordinary")); await f.photos.appendAsset(native)
            let c = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
            try await c.resumeInitialInventory()
            try await f.store.recordLivePhotoInventoryResult(context: native.context, assetID: native.assetID, revision: native.revision,
                observations: [.init(resource: native.resources[0], inspection: .unresolved("fixture"))],
                retryPolicy: .automatic(nextRetryAt: now.addingTimeInterval(due ? -1 : 60)))
            _ = try await c.processNextInventoryItem(now: now)
            let order = await f.photos.readAssetIDs
            XCTAssertEqual(order, [due ? "z-native" : "a-ordinary"])
        }
    }

    func testBusyInventoryWithHeldFailuresRemainsQueuedButDrainWaits() async throws {
        let f = try await inventoryFixture(count: 2); defer { try? FileManager.default.removeItem(at: f.root) }
        let c = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        try await c.resumeInitialInventory()
        let held = livePhotoAsset(context: f.photos.context, id: "asset-0")
        try await f.store.recordLivePhotoInventoryResult(context: held.context, assetID: held.assetID, revision: held.revision,
            observations: [.init(resource: held.resources[0], inspection: .unresolved("fixture"))], retryPolicy: .requiresAttention)
        await f.photos.setReadAdmission(.busy)
        let busy = await c.activity(); XCTAssertEqual(busy, .queued(.identification))
        for value in [PhotosReaderAdmission.draining, .stalled] {
            await f.photos.setReadAdmission(value)
            let draining = await c.activity(); XCTAssertEqual(draining, .draining)
        }
        let reads = await f.photos.resourceReads; XCTAssertEqual(reads, 0)
    }

    func testParsedInventoryObservationSurvivesClassificationGapWithoutReadingAgain() async throws {
        let f = try await inventoryFixture(count: 1); defer { try? FileManager.default.removeItem(at: f.root) }
        let state = InventoryContinuationState()
        await f.photos.useNativeRead { _, _, _ in
            let url = f.root.appendingPathComponent("bytes"); try Data([1]).write(to: url)
            return .init(url: url, validity: .init(check: { try state.validate() }, release: {}))
        }
        let c = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos,
            metadata: MutatingInventoryMetadata { state.parsedThenWait() })
        try await c.resumeInitialInventory()
        do { _ = try await c.processNextInventoryItem(now: Date()); XCTFail("Unclassified observation accepted") }
        catch { XCTAssertEqual(error as? LivePhotoReadDeferred, .classificationPending) }
        let before = try await c.summary(); XCTAssertEqual(before.identified, 0)
        state.classified()
        let progressed = try await c.processNextInventoryItem(now: Date())
        let after = try await c.summary(), reads = await f.photos.resourceReads
        XCTAssertTrue(progressed); XCTAssertEqual(after.identified, 1)
        XCTAssertEqual(reads, 1); XCTAssertEqual(state.parses, 1)
    }

    func testPendingObservationExpiresWithoutAnotherWorkerCall() async throws {
        let f = try await inventoryFixture(count: 1); defer { try? FileManager.default.removeItem(at: f.root) }
        let state = InventoryContinuationState(), timer = InventoryReadGate()
        let scheduled = expectation(description: "independent expiry scheduled")
        let released = expectation(description: "validity released without another worker call")
        await f.photos.useNativeRead { _, _, _ in
            let url = f.root.appendingPathComponent("bytes"); try Data([1]).write(to: url)
            return .init(url: url, validity: .init(check: { try state.validate() }, release: { released.fulfill() }))
        }
        let c = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos,
            metadata: MutatingInventoryMetadata { state.parsedThenWait() }, uptime: { state.now }, retentionSleep: { seconds in
                XCTAssertEqual(seconds, 30); scheduled.fulfill(); await timer.hold()
            })
        try await c.resumeInitialInventory()
        do { _ = try await c.processNextInventoryItem(now: Date()); XCTFail("Unclassified observation accepted") }
        catch { XCTAssertEqual(error as? LivePhotoReadDeferred, .classificationPending) }
        await fulfillment(of: [scheduled], timeout: 1)
        state.advance(30); await timer.release()
        await fulfillment(of: [released], timeout: 1)
        let summary = try await c.summary(), reads = await f.photos.resourceReads
        XCTAssertEqual(summary.identified, 0); XCTAssertEqual(summary.pending, 1)
        XCTAssertEqual(reads, 1, "Expiry must release ownership without starting more work")
    }

    func testPauseCancelsPendingExpiryAndReleasesValidity() async throws {
        let f = try await inventoryFixture(count: 1); defer { try? FileManager.default.removeItem(at: f.root) }
        let state = InventoryContinuationState(), timer = InventoryReadGate()
        let scheduled = expectation(description: "expiry scheduled")
        let cancelled = expectation(description: "expiry cancelled on pause")
        let released = expectation(description: "validity released on pause")
        await f.photos.useNativeRead { _, _, _ in
            let url = f.root.appendingPathComponent("bytes"); try Data([1]).write(to: url)
            return .init(url: url, validity: .init(check: { try state.validate() }, release: { released.fulfill() }))
        }
        let c = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos,
            metadata: MutatingInventoryMetadata { state.parsedThenWait() }, uptime: { state.now }, retentionSleep: { _ in
                await withTaskCancellationHandler {
                    scheduled.fulfill(); await timer.hold()
                } onCancel: { cancelled.fulfill() }
            })
        try await c.resumeInitialInventory()
        do { _ = try await c.processNextInventoryItem(now: Date()); XCTFail("Unclassified observation accepted") }
        catch { XCTAssertEqual(error as? LivePhotoReadDeferred, .classificationPending) }
        await fulfillment(of: [scheduled], timeout: 1)
        await c.setPaused(true)
        await fulfillment(of: [cancelled, released], timeout: 1)
        state.advance(30); await timer.release()
        let summary = try await c.summary(), reads = await f.photos.resourceReads
        XCTAssertEqual(summary.identified, 0); XCTAssertEqual(summary.pending, 1); XCTAssertEqual(reads, 1)
    }

    func testRetainedObservationCannotSurvivePauseExpiryOrTargetChange() async throws {
        for interruption in ["pause", "expiry", "changed"] {
            let f = try await inventoryFixture(count: 1); defer { try? FileManager.default.removeItem(at: f.root) }
            let state = InventoryContinuationState()
            await f.photos.useNativeRead { _, _, _ in
                let url = f.root.appendingPathComponent("bytes"); try Data([1]).write(to: url)
                return .init(url: url, validity: .init(check: { try state.validate() }, release: {}))
            }
            let c = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos,
                metadata: MutatingInventoryMetadata { state.parsedThenWait() }, uptime: { state.now })
            try await c.resumeInitialInventory()
            do { _ = try await c.processNextInventoryItem(now: Date()); XCTFail("Accepted pending observation") }
            catch { XCTAssertEqual(error as? LivePhotoReadDeferred, .classificationPending) }
            if interruption == "pause" { await c.setPaused(true); await c.setPaused(false) }
            if interruption == "expiry" { state.advance(30) }
            if interruption == "changed" {
                state.changed()
                do { _ = try await c.processNextInventoryItem(now: Date()); XCTFail("Accepted changed observation") }
                catch { XCTAssertEqual(error as? LivePhotoReadDeferred, .resourceChanged) }
                let stale = try await c.summary(); XCTAssertEqual(stale.identified, 0)
            }
            state.classified()
            let progressed = try await c.processNextInventoryItem(now: Date())
            let after = try await c.summary(), reads = await f.photos.resourceReads
            XCTAssertTrue(progressed); XCTAssertEqual(after.identified, 1)
            XCTAssertEqual(reads, 2, interruption); XCTAssertEqual(state.parses, 2, interruption)
        }
    }

    func testTwoResourceInventoryResumesAfterParsedPhotoWithoutReadingItAgain() async throws {
        let f = try await inventoryFixture(count: 0); defer { try? FileManager.default.removeItem(at: f.root) }
        let state = InventoryContinuationState(), context = f.photos.context
        let refs = ["photo", "motion"].map { LivePhotoResourceRef.photos(contextID: context.id, assetID: "paired", resourceKey: $0, revision: "r1") }
        await f.photos.appendAsset(.init(context: context, assetID: "paired", revision: "r1", isLivePhoto: true, mediaKind: .image, resources: refs, resourceKinds: [.image, .video]))
        await f.photos.useNativeRead { _, _, _ in
            let url = f.root.appendingPathComponent("bytes"); try Data([1]).write(to: url)
            return .init(url: url, validity: .init(check: { try state.validate() }, release: {}))
        }
        let c = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: MutatingInventoryMetadata { state.parsedThenWait() })
        try await c.resumeInitialInventory()
        do { _ = try await c.processNextInventoryItem(now: Date()); XCTFail("Unclassified photo accepted") }
        catch { XCTAssertEqual(error as? LivePhotoReadDeferred, .classificationPending) }
        state.classified()
        let progressed = try await c.processNextInventoryItem(now: Date())
        let result = try await c.summary(), reads = await f.photos.resourceReads
        XCTAssertTrue(progressed); XCTAssertEqual(result.identified, 1)
        XCTAssertEqual(reads, 2); XCTAssertEqual(state.parses, 2)
    }

    func testClassificationArrivingAtObservationCommitRollsBackUntilRevalidated() async throws {
        let f = try await inventoryFixture(count: 1); defer { try? FileManager.default.removeItem(at: f.root) }
        let c = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        try await c.resumeInitialInventory()
        let next = try await f.store.nextLivePhotoInventoryItem(context: f.photos.context, now: Date())
        let item = try XCTUnwrap(next)
        do {
            try await f.store.recordLivePhotoInventoryResult(context: item.context, assetID: item.assetID, revision: item.revision,
                observations: [.init(resource: item.resources[0], inspection: .noIdentifier)], retryPolicy: .requiresAttention,
                observationsAreCurrent: { throw LivePhotoReadDeferred.classificationPending })
            XCTFail("Unverified identity committed")
        } catch { XCTAssertEqual(error as? LivePhotoReadDeferred, .classificationPending) }
        let pending = try await c.summary(); XCTAssertEqual(pending.identified, 0); XCTAssertEqual(pending.pending, 1)
        try await f.store.recordLivePhotoInventoryResult(context: item.context, assetID: item.assetID, revision: item.revision,
            observations: [.init(resource: item.resources[0], inspection: .noIdentifier)], retryPolicy: .requiresAttention)
        let accepted = try await c.summary(); XCTAssertEqual(accepted.identified, 1); XCTAssertEqual(accepted.pending, 0)
    }

    func testLegacyVideoRefreshResumesAcrossFailureAndMultipleBatches() async throws {
        let f = try await inventoryFixture(count: 0); defer { try? FileManager.default.removeItem(at: f.root) }
        try await completeEmptyInventory(f.store, f.photos.context)
        for index in 0..<3 {
            let base = livePhotoAsset(context: f.photos.context, id: "video-\(index)", kind: .video)
            try await f.store.enqueueLivePhotoAssets(context: f.photos.context, assets: [try durationDescriptor(base, duration: nil, legacy: true)])
            await f.photos.appendAsset(try durationDescriptor(base, duration: 60))
        }
        let first = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, batchSize: 1)
        try await first.resumeInitialInventory(); await f.photos.failNextDescriptorLookup()
        do { _ = try await first.processNextInventoryItem(now: Date()); XCTFail("Expected injected descriptor failure") }
        catch { XCTAssertTrue(error is PhotosRepresentationError) }
        let restarted = LivePhotoInventoryCoordinator(store: try SyncStore(url: f.db), photos: f.photos, batchSize: 1)
        try await restarted.resumeInitialInventory()
        for _ in 0..<4 { _ = try await restarted.processNextInventoryItem(now: Date()) }
        let summary = try await restarted.summary(), reads = await f.photos.resourceReads, catalogs = await f.photos.catalogCalls
        XCTAssertEqual(summary.identified, 3); XCTAssertEqual(summary.unresolved, 0); XCTAssertEqual(summary.pending, 0)
        XCTAssertEqual(reads, 0); XCTAssertEqual(catalogs, 0)
        let requests = await f.photos.descriptorRequestSizes; XCTAssertEqual(requests.count, 7); XCTAssertTrue(requests.allSatisfy { $0 == 1 })
    }
    func testLegacyPhotoDescriptorVersionDoesNotInvalidateReadResult() async throws {
        for live in [false, true] {
            let f = try await inventoryFixture(count: 0); defer { try? FileManager.default.removeItem(at: f.root) }
            let fresh = livePhotoAsset(context: f.photos.context, id: "photo", isLivePhoto: live)
            let legacy = try durationDescriptor(fresh, duration: nil, legacy: true)
            try await completeEmptyInventory(f.store, f.photos.context)
            try await f.store.enqueueLivePhotoAssets(context: f.photos.context, assets: [legacy])
            await f.photos.appendAsset(fresh)
            let c = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
            do { _ = try await c.processNextInventoryItem(now: Date()) }
            catch { XCTFail("Administrative descriptor version must not invalidate unchanged photo bytes: \(error)") }
            let summary = try await c.summary(), reads = await f.photos.resourceReads
            XCTAssertEqual(summary.identified, 1); XCTAssertEqual(reads, 1)
        }
    }
    func testResourceLimitHasStructuredReasonAndReadableDiagnostic() async throws {
        let f = try await inventoryFixture(count: 1); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.photos.setReadFailure(.resourceLimit(bytes: 600_000_000))
        let c = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        try await c.resumeInitialInventory(); _ = try await c.processNextInventoryItem(now: Date())
        let assets = try await f.photos.livePhotoAssets(assetIDs: ["asset-0"], context: f.photos.context)
        let asset = try XCTUnwrap(assets.first)
        let saved = try await f.store.livePhotoObservation(for: asset.resources[0])
        let observation = try XCTUnwrap(saved)
        guard case .unresolved(let detail) = observation.inspection else { return XCTFail("Expected held limit") }
        XCTAssertTrue(detail.contains("512 MiB")); XCTAssertTrue(detail.contains("已跳过"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(observation)) as? [String: Any])
        XCTAssertEqual(json["resourceLimitBytes"] as? Int, 536_870_912)
        let summary = try await c.summary(); XCTAssertEqual(summary.resourceLimited, 1)
    }
    func testUnknownAndNonfiniteDurationCannotExcludeAndCheckedLegacyVideoIsRetained() async throws {
        for duration: Double? in [nil, .nan, .infinity, -.infinity] {
            XCTAssertFalse(LivePhotoIdentificationPolicy.excludesVideo(kind: .video, duration: duration))
        }
        let f = try await inventoryFixture(count: 0); defer { try? FileManager.default.removeItem(at: f.root) }
        let asset = try durationDescriptor(livePhotoAsset(context: f.photos.context, id: "checked", kind: .video), duration: nil, legacy: true)
        try await completeEmptyInventory(f.store, f.photos.context)
        try await f.store.enqueueLivePhotoAssets(context: f.photos.context, assets: [asset])
        try await f.store.recordLivePhotoInventoryResult(context: f.photos.context, assetID: asset.assetID, revision: asset.revision,
            observations: [.init(resource: asset.resources[0], inspection: .identified(.init(contentIdentifier: "kept", role: .motion)))], retryPolicy: .requiresAttention)
        let c = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos)
        try await c.resumeInitialInventory(); _ = try await c.processNextInventoryItem(now: Date())
        let summary = try await c.summary(), saved = try await f.store.livePhotoObservation(for: asset.resources[0])
        XCTAssertEqual(summary.identified, 1); XCTAssertEqual(summary.pending, 0)
        XCTAssertEqual(saved?.identity?.contentIdentifier, "kept")
        let reads = await f.photos.resourceReads; XCTAssertEqual(reads, 0)
    }
    func testVideoDurationPrefilterAvoidsOriginalReadWithIdentityExceptions() async throws {
        for (duration, live, knownIdentity, expectedReads) in [(10.0, false, false, 1), (10.001, false, false, 0), (0.0, false, false, 1), (-1.0, false, false, 1), (11.0, true, false, 1), (11.0, false, true, 1)] {
            let f = try await inventoryFixture(count: 0); defer { try? FileManager.default.removeItem(at: f.root) }
            let base = LivePhotoAssetDescriptor(context: f.photos.context, assetID: "video", revision: "r1", isLivePhoto: live, mediaKind: .video,
                resources: [.photos(contextID: f.photos.context.id, assetID: "video", resourceKey: "motion", revision: "r1")])
            let asset = try durationDescriptor(base, duration: duration)
            await f.photos.appendAsset(asset)
            if knownIdentity { try await f.store.saveLivePhotoObservation(.init(resource: asset.resources[0], inspection: .identified(.init(contentIdentifier: "known", role: .motion)))) }
            let c = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
            try await c.resumeInitialInventory()
            _ = try await c.processNextInventoryItem(now: Date())
            let reads = await f.photos.resourceReads, summary = try await c.summary()
            XCTAssertEqual(reads, expectedReads, "duration=\(duration), live=\(live), known=\(knownIdentity)")
            XCTAssertEqual(summary.identified, 1); XCTAssertEqual(summary.requiresAttention, 0)
        }
    }

    func testLegacyHeldLongVideoRefreshesMetadataOnceWithoutRepeatingCatalog() async throws {
        let f = try await inventoryFixture(count: 0); defer { try? FileManager.default.removeItem(at: f.root) }
        let base = livePhotoAsset(context: f.photos.context, id: "legacy-video", kind: .video)
        let legacy = try durationDescriptor(base, duration: nil, legacy: true)
        try await completeEmptyInventory(f.store, f.photos.context)
        try await f.store.enqueueLivePhotoAssets(context: f.photos.context, assets: [legacy])
        try await f.store.recordLivePhotoInventoryResult(context: f.photos.context, assetID: legacy.assetID, revision: legacy.revision,
            observations: [.init(resource: legacy.resources[0], inspection: .unresolved("legacy failure"))], retryPolicy: .requiresAttention)
        await f.photos.appendAsset(try durationDescriptor(base, duration: 60))
        let c = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        try await c.resumeInitialInventory()
        _ = try await c.processNextInventoryItem(now: Date())
        let result = try await c.summary()
        XCTAssertEqual(result.identified, 1); XCTAssertEqual(result.requiresAttention, 0)
        let restart = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        try await restart.resumeInitialInventory()
        _ = try await restart.processNextInventoryItem(now: Date())
        let reads = await f.photos.resourceReads, catalogs = await f.photos.catalogCalls
        XCTAssertEqual(reads, 0); XCTAssertEqual(catalogs, 0)
    }

    func testPendingAfterMetadataDefersWithoutEnteringAnotherSnapshotWait() async throws {
        let f = try await inventoryFixture(count: 1); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = InventoryReadGate()
        await f.photos.useNativeRead { _, _, _ in
            let url = f.root.appendingPathComponent("bytes"); try Data([1]).write(to: url)
            return .init(url: url, validity: .init(check: { throw LivePhotoReadDeferred.classificationPending }, release: {}))
        }
        let c = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos,
            metadata: MutatingInventoryMetadata { await f.photos.holdNextSnapshot(gate) })
        try await c.resumeInitialInventory()
        let done = expectation(description: "Metadata pending defers immediately, without a second classifier wait")
        let task = Task {
            do { _ = try await c.processNextInventoryItem(now: Date()); XCTFail("Pending bytes accepted") }
            catch { XCTAssertEqual(error as? LivePhotoReadDeferred, .classificationPending) }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 1)
        let waited = await gate.entered
        await gate.release(); await task.value
        XCTAssertFalse(waited, "A read ticket must reject pending metadata before querying the producer queue")
        let summary = try await c.summary(); XCTAssertEqual(summary.identified, 0)
        let reads = await f.photos.resourceReads; XCTAssertEqual(reads, 1)
    }

    func testInventoryBetweenItemsIsQueuedButFutureRetryAndDrainAreWaiting() async throws {
        let f = try await inventoryFixture(count: 2); defer { try? FileManager.default.removeItem(at: f.root) }
        let now = Date(), c = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        try await c.resumeInitialInventory()
        let first = await c.activity(); XCTAssertEqual(first, .queued(.identification))
        _ = try await c.processNextInventoryItem(now: now)
        let between = await c.activity(); XCTAssertEqual(between, .queued(.identification))
        await f.photos.setReadAdmission(.draining)
        let draining = await c.activity(); XCTAssertEqual(draining, .draining)
    }
    func testClassifiedTargetChangeDuringMetadataRefreshesInsteadOfGlobalFailure() async throws {
        let f = try await inventoryFixture(count: 1); defer { try? FileManager.default.removeItem(at: f.root) }
        let c = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: MutatingInventoryMetadata {
            try await f.store.applyLivePhotoDelta(.init(context: f.photos.context, fromGeneration: 0, toGeneration: 1, changedAssetIDs: ["asset-0"], deletedAssetIDs: []))
        })
        try await c.resumeInitialInventory()
        do { _ = try await c.processNextInventoryItem(now: Date()); XCTFail("Changed issuance accepted") }
        catch { XCTAssertEqual(error as? LivePhotoReadDeferred, .resourceChanged) }
        let before = try await c.summary(); XCTAssertEqual(before.identified, 0); XCTAssertEqual(before.retryWaiting, 0)
        let refreshed = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        _ = try await refreshed.processNextInventoryItem(now: Date())
        let after = try await refreshed.summary(); XCTAssertEqual(after.identified, 1)
    }
    func testPauseDuringMetadataDoesNotReadOrCommitNextPhase() async throws {
        for resourceCount in [1, 2] {
            let f = try await inventoryFixture(count: 0); defer { try? FileManager.default.removeItem(at: f.root) }
            let context = f.photos.context, gate = InventoryReadGate()
            let refs = (0..<resourceCount).map { LivePhotoResourceRef.photos(contextID: context.id, assetID: "paired", resourceKey: "part-\($0)", revision: "r1") }
            await f.photos.appendAsset(.init(context: context, assetID: "paired", revision: "r1", isLivePhoto: resourceCount == 2, mediaKind: .image, resources: refs, resourceKinds: resourceCount == 1 ? [.image] : [.image, .video]))
            await f.photos.useNativeRead { _, _, _ in
                let url = f.root.appendingPathComponent("bytes"); try Data([1]).write(to: url)
                return .init(url: url, validity: .init(validate: { true }, release: {}))
            }
            let c = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: MutatingInventoryMetadata { await gate.hold() })
            try await c.resumeInitialInventory()
            let task = Task { try await c.processNextInventoryItem(now: Date()) }
            let entered = await engineEventually { await gate.entered }; XCTAssertTrue(entered)
            await c.setPaused(true); await gate.release(); _ = try await task.value
            let reads = await f.photos.resourceReads, summary = try await c.summary()
            XCTAssertEqual(reads, 1); XCTAssertEqual(summary.identified, 0)
        }
    }
    func testSlowFailureUsesFailureTimeRatherThanEligibilityCutoff() async throws {
        let f = try await inventoryFixture(count: 1); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.photos.setUnavailable("asset-0")
        let c = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        try await c.resumeInitialInventory()
        _ = try await c.processNextInventoryItem(now: Date().addingTimeInterval(-120))
        _ = try await c.processNextInventoryItem(now: Date())
        let reads = await f.photos.resourceReads; XCTAssertEqual(reads, 1)
    }
    func testInventoryDrainingIsNotReportedAsWorking() async throws {
        let f = try await inventoryFixture(count: 1); defer { try? FileManager.default.removeItem(at: f.root) }
        let c = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata()), gate = InventoryReadGate()
        try await c.resumeInitialInventory(); await f.photos.holdNextRead(gate)
        let task = Task { try await c.processNextInventoryItem(now: Date()) }
        let entered = await engineEventually { await gate.entered }; XCTAssertTrue(entered)
        await f.photos.setReadAdmission(.draining)
        let activity = await c.activity(); XCTAssertEqual(activity, .draining)
        await c.setPaused(true); await gate.release(); _ = try await task.value
    }
    func testDeterministicFailureDoesNotDownloadSameRevisionAgain() async throws {
        for oversized in [false, true] {
            let f = try await inventoryFixture(count: 1); defer { try? FileManager.default.removeItem(at: f.root) }
            if oversized { await f.photos.setReadFailure(.resourceLimit(bytes: 600)) }
            let task = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: UnresolvableInventoryMetadata())
            try await task.resumeInitialInventory()
            _ = try await task.processNextInventoryItem(now: Date())
            _ = try await task.processNextInventoryItem(now: Date().addingTimeInterval(1000))
            let reads = await f.photos.resourceReads
            XCTAssertEqual(reads, 1, "Deterministic failure requires an explicit retry or new revision")
        }
    }
    func testUnrelatedGenerationChangeStillSavesIdentityObservation() async throws {
        let f = try await inventoryFixture(count: 1); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.photos.changeUnrelatedDuringRead()
        let task = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        try await task.resumeInitialInventory()
        _ = try await task.processNextInventoryItem(now: Date())
        let result = try await task.summary(); XCTAssertEqual(result.identified, 1)
    }
    func testOldCompletedUnresolvedResumesAfterReopeningWithoutRepeatingCheckedAssets() async throws {
        let f = try await inventoryFixture(count: 2); defer { try? FileManager.default.removeItem(at: f.root) }
        let now = Date()
        await f.photos.setUnavailable("asset-0")
        let first = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        try await first.resumeInitialInventory()
        for _ in 0..<2 { _ = try await first.processNextInventoryItem(now: now) }
        let before = try await first.summary()
        XCTAssertEqual(before.phase, .completed); XCTAssertEqual(before.identified, 1)
        let reopened = try SyncStore(url: f.db)
        await f.photos.setUnavailable(nil)
        let next = LivePhotoInventoryCoordinator(store: reopened, photos: f.photos, metadata: InventoryMetadata())
        try await next.resumeInitialInventory()
        _ = try await next.processNextInventoryItem(now: now.addingTimeInterval(59))
        let heldReads = await f.photos.resourceReads; XCTAssertEqual(heldReads, 2)
        _ = try await next.processNextInventoryItem(now: now.addingTimeInterval(61))
        let after = try await next.summary(), reads = await f.photos.resourceReads, calls = await f.photos.catalogCalls
        XCTAssertEqual(after.completedAt, before.completedAt); XCTAssertEqual(after.identified, 2)
        XCTAssertEqual(reads, 3); XCTAssertEqual(calls, 1)
    }
    func testInventoryCountsSeparateCheckedQueuedAutomaticAndAttention() async throws {
        let f = try await inventoryFixture(count: 4); defer { try? FileManager.default.removeItem(at: f.root) }
        let context = f.photos.context, now = Date()
        try await f.store.ensureLivePhotoInventory(context: context)
        let assets = await f.photos.assets
        try await f.store.enqueueLivePhotoAssets(context: context, assets: assets)
        for (i, policy) in [LivePhotoInventoryRetryPolicy.automatic(nextRetryAt: now.addingTimeInterval(60)), .requiresAttention].enumerated() {
            let d = assets[i]
            try await f.store.recordLivePhotoInventoryResult(context: context, assetID: d.assetID, revision: d.revision, observations: [.init(resource: d.resources[0], inspection: .unresolved("unavailable"))], retryPolicy: policy)
        }
        let checked = assets[2]
        try await f.store.recordLivePhotoInventoryResult(context: context, assetID: checked.assetID, revision: checked.revision, observations: [.init(resource: checked.resources[0], inspection: .noIdentifier)], retryPolicy: .requiresAttention)
        let s = try await f.store.livePhotoInventorySummary(context: context)
        XCTAssertEqual(s.identified, 1); XCTAssertEqual(s.pending, 1); XCTAssertEqual(s.retryWaiting, 1); XCTAssertEqual(s.requiresAttention, 1)
        XCTAssertEqual(try XCTUnwrap(s.nextRetryAt).timeIntervalSince1970, now.addingTimeInterval(60).timeIntervalSince1970, accuracy: 0.001)
        let retried = try await f.store.retryLivePhotoInventoryAttention(context: context, now: now)
        XCTAssertEqual(retried, 1)
        let after = try await f.store.livePhotoInventorySummary(context: context)
        XCTAssertEqual(after.identified, 1); XCTAssertEqual(after.pending, 1); XCTAssertEqual(after.requiresAttention, 0); XCTAssertEqual(after.retryWaiting, 2)
    }
    func testSharedBudgetDeferralDoesNotBecomeAnUnresolvedFailure() async throws {
        let f = try await inventoryFixture(count: 1); defer { try? FileManager.default.removeItem(at: f.root) }
        let task = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: InventoryMetadata())
        try await task.resumeInitialInventory()
        await f.photos.setReadFailure(.budgetBusy(resourceBytes: 1))
        do { _ = try await task.processNextInventoryItem(now: Date()); XCTFail("Expected resource deferral") } catch { }
        let s = try await task.summary(); XCTAssertEqual(s.pending, 1); XCTAssertEqual(s.unresolved, 0)
        await f.photos.setReadFailure(nil)
        _ = try await task.processNextInventoryItem(now: Date())
        let final = try await task.summary(); XCTAssertEqual(final.identified, 1)
    }
    func testExplicitRetryOnlyReopensAttentionAndKeepsCompletionMarker() async throws {
        let f = try await inventoryFixture(count: 1); defer { try? FileManager.default.removeItem(at: f.root) }
        let task = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: UnresolvableInventoryMetadata())
        try await task.resumeInitialInventory()
        _ = try await task.processNextInventoryItem(now: Date())
        let before = try await task.summary(); XCTAssertEqual(before.requiresAttention, 1)
        try await task.retryAttention(now: Date())
        let after = try await task.summary(); XCTAssertEqual(after.requiresAttention, 0); XCTAssertEqual(after.completedAt, before.completedAt)
        _ = try await task.processNextInventoryItem(now: Date())
        let reads = await f.photos.resourceReads; XCTAssertEqual(reads, 2)
    }
    func testTargetChangeWhileInspectingCannotSaveOldObservation() async throws {
        let f = try await inventoryFixture(count: 1); defer { try? FileManager.default.removeItem(at: f.root) }
        let context = f.photos.context
        let task = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: MutatingInventoryMetadata {
            try await f.store.applyLivePhotoDelta(.init(context: context, fromGeneration: 0, toGeneration: 1, changedAssetIDs: ["asset-0"], deletedAssetIDs: []))
        })
        try await task.resumeInitialInventory()
        do { _ = try await task.processNextInventoryItem(now: Date()); XCTFail("Accepted stale result") } catch { }
        let s = try await task.summary(); XCTAssertEqual(s.identified, 0); XCTAssertEqual(s.pending, 1)
    }
    func testNewRevisionRequeuesHeldItemWithoutResettingHistory() async throws {
        let f = try await inventoryFixture(count: 1); defer { try? FileManager.default.removeItem(at: f.root) }
        let task = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: UnresolvableInventoryMetadata())
        try await task.resumeInitialInventory(); _ = try await task.processNextInventoryItem(now: Date())
        let before = try await task.summary(), context = f.photos.context
        let changed = livePhotoAsset(context: context, id: "asset-0", revision: "r2")
        try await f.store.enqueueLivePhotoAssets(context: context, assets: [changed])
        let after = try await task.summary(); XCTAssertEqual(after.requiresAttention, 0); XCTAssertEqual(after.pending, 1); XCTAssertEqual(after.completedAt, before.completedAt)
    }
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
            try await f.store.recordLivePhotoInventoryResult(context: context, assetID: asset.assetID, revision: asset.revision, observations: [.init(resource: asset.resources[0], inspection: .noIdentifier)], retryPolicy: .automatic(nextRetryAt: Date().addingTimeInterval(60)))
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

final class InventoryContinuationState: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: LivePhotoReadDeferred?
    private var count = 0
    private var time: TimeInterval = 100
    var parses: Int { lock.lock(); defer { lock.unlock() }; return count }
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ duration: TimeInterval) { lock.lock(); time += duration; lock.unlock() }
    func parsedThenWait() { lock.lock(); count += 1; if count == 1 { failure = .classificationPending }; lock.unlock() }
    func classified() { lock.lock(); failure = nil; lock.unlock() }
    func changed() { lock.lock(); failure = .resourceChanged; lock.unlock() }
    func validate() throws {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
    }
}

func durationDescriptor(_ descriptor: LivePhotoAssetDescriptor, duration: Double?, legacy: Bool = false) throws -> LivePhotoAssetDescriptor {
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor)) as? [String: Any])
    json["duration"] = duration
    json["descriptorVersion"] = legacy ? nil : 2
    return try JSONDecoder().decode(LivePhotoAssetDescriptor.self, from: JSONSerialization.data(withJSONObject: json))
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
    var readAssetIDs = [String]()
    var snapshotGate: InventoryReadGate?
    func holdNextSnapshot(_ gate: InventoryReadGate) { snapshotGate = gate }
    var nativeRead: (@Sendable (LivePhotoResourceRef, LivePhotoReadPurpose, LivePhotoResourceBudget) async throws -> LivePhotoResourceLease)?
    func useNativeRead(_ read: @escaping @Sendable (LivePhotoResourceRef, LivePhotoReadPurpose, LivePhotoResourceBudget) async throws -> LivePhotoResourceLease) { nativeRead = read }
    var admission: PhotosReaderAdmission = .available
    var admissionGate: InventoryReadGate?
    func holdReadAdmissionOnce(_ gate: InventoryReadGate) { admissionGate = gate }
    func setReadAdmission(_ value: PhotosReaderAdmission) { admission = value }
    func livePhotoReadAdmission() async -> PhotosReaderAdmission {
        if let gate = admissionGate { admissionGate = nil; await gate.hold() }
        return admission
    }
    var readGate: InventoryReadGate?
    var catalogBeginCount = 0
    var visualGate: InventoryReadGate?, liveCatalogGate: InventoryReadGate?
    func holdCatalog(_ gate: InventoryReadGate, visual: Bool) { if visual { visualGate = gate } else { liveCatalogGate = gate } }
    func beginCatalogSession(expectedGeneration: Int) async throws -> PhotosCatalogSession { catalogBeginCount += 1; return .init(baselineGeneration: expectedGeneration) }
    var visualCatalogCalls = 0
    func holdNextRead(_ gate: InventoryReadGate) { readGate = gate }
    var readFailure: LivePhotoResourceReadError?
    var changeOnRead = false
    func setReadFailure(_ error: LivePhotoResourceReadError?) { readFailure = error }
    func changeUnrelatedDuringRead() { changeOnRead = true }
    var unavailable: String?
    var injected: LivePhotoAssetDescriptor?
    var changesDuringCatalog = [String]()
    var catalogFailureAt: Int?
    var contextAccepted = true
    var failDescriptorLookup = false
    var descriptorRequestSizes = [Int]()
    func failNextDescriptorLookup() { failDescriptorLookup = true }
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
    func candidateSnapshot() async throws -> PhotosCandidateSnapshot { if let gate = snapshotGate { snapshotGate = nil; await gate.hold() }; return .init(generation: generation, candidates: []) }
    func livePhotoLibraryContext() async throws -> LibraryContext { contextReads += 1; return context }
    func livePhotoAssetCatalog(session: PhotosCatalogSession, offset: Int, limit: Int) async throws -> LivePhotoAssetPage {
        catalogCalls += 1
        if let gate = liveCatalogGate { liveCatalogGate = nil; await gate.hold() }
        if catalogCalls == catalogFailureAt { catalogFailureAt = nil; throw PhotoKitGatewayError.libraryChanged }
        let old = assets
        if let injected { assets.append(injected); generation += 1; changesDuringCatalog.append(injected.assetID); self.injected = nil }
        let end = min(old.count, offset + limit)
        return .init(context: context, generation: session.baselineGeneration, assets: Array(old[offset..<end]), nextOffset: end < old.count ? end : nil)
    }
    func livePhotoAssets(assetIDs: [String], context: LibraryContext) async throws -> [LivePhotoAssetDescriptor] {
        descriptorRequestSizes.append(assetIDs.count)
        if failDescriptorLookup { failDescriptorLookup = false; throw PhotosRepresentationError.unavailable }
        return assets.filter { assetIDs.contains($0.assetID) }
    }
    func catalogChanges(baselineGeneration: Int, throughGeneration: Int, afterAssetID: String?, limit: Int) async throws -> PhotosCatalogChangeBatch {
        .init(changedAssetIDs: changesDuringCatalog.filter { $0 > (afterAssetID ?? "") }, deletedAssetIDs: [], nextAssetID: nil)
    }
    func catalogCoverage(baselineGeneration: Int) async throws -> Int { generation }
    func catalogCoverage(session: PhotosCatalogSession) async throws -> Int { generation }
    func readLivePhotoResource(_ ref: LivePhotoResourceRef, purpose: LivePhotoReadPurpose, budget: LivePhotoResourceBudget) async throws -> LivePhotoResourceLease {
        resourceReads += 1
        if let id = ref.assetID { readAssetIDs.append(id) }
        if let gate = readGate { readGate = nil; await gate.hold() }
        if let readFailure { throw readFailure }
        if let nativeRead { return try await nativeRead(ref, purpose, budget) }
        if changeOnRead { generation += 1; changeOnRead = false }
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
    func representationCatalog(offset: Int, limit: Int, expectedGeneration: Int) async throws -> RepresentationPage { visualCatalogCalls += 1; if let gate = visualGate { visualGate = nil; await gate.hold() }; return .init(context: context, generation: generation, descriptors: [], nextOffset: nil) }
    nonisolated func changes() -> AsyncStream<PhotosIndexChange> { AsyncStream { $0.finish() } }
    func readRepresentation(_ descriptor: RepresentationDescriptor) async throws -> LoadedRepresentation { throw PhotosRepresentationError.unavailable }
}

struct UnresolvableInventoryMetadata: LivePhotoMetadataReading {
    func inspect(url: URL, kind: MediaKind) async throws -> LivePhotoInspection { .unresolved("确定无法解析") }
}

struct MutatingInventoryMetadata: LivePhotoMetadataReading {
    let action: @Sendable () async throws -> Void
    func inspect(url: URL, kind: MediaKind) async throws -> LivePhotoInspection { try await action(); return .noIdentifier }
}

actor InventoryReadGate {
    private(set) var entered = false
    private var open = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; if !open { await withCheckedContinuation { continuation = $0 } } }
    func release() { open = true; continuation?.resume(); continuation = nil }
}
