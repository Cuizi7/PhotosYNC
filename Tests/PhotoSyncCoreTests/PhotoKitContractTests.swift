import XCTest
import Photos
import ImageIO
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

    func testHistoryCoverageClosesExistingSnapshotFenceWithoutChangingRawGeneration() async throws {
        let f = try continuityFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.coordinator.reconcile()
        let before = try await f.gateway.candidateSnapshot()
        let entered = expectation(description: "history paused"), release = DispatchSemaphore(value: 0)
        f.lifecycle.afterReplay = { entered.fulfill(); release.wait() }
        let work = Task { try await f.coordinator.reconcile() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertFalse(try before.candidateValidity.commitIfCurrent({ XCTFail("old admission entered during history") }))
        release.signal(); try await work.value
        let after = try await f.gateway.candidateSnapshot()
        XCTAssertEqual(after.generation, before.generation)
        XCTAssertFalse(try before.candidateValidity.commitIfCurrent({ XCTFail("old admission revived after history") }))
        XCTAssertTrue(try after.candidateValidity.commitIfCurrent({}))
    }

    func testNoChangeHistoryReplayWritesNoRepresentationOrTaskRows() async throws {
        let f = try continuityFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.coordinator.reconcile()
        try injectEngineSQL("CREATE TABLE history_writes(table_name TEXT);" + ["photos_representation", "fingerprint_task"].flatMap { table in
            ["INSERT", "UPDATE", "DELETE"].map { operation in
                "CREATE TRIGGER history_\(table)_\(operation) AFTER \(operation) ON \(table) BEGIN INSERT INTO history_writes VALUES ('\(table)'); END;"
            }
        }.joined(), at: f.db)
        let replayCount = f.lifecycle.replayedTokens.count
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: Date())
        XCTAssertEqual(f.lifecycle.replayedTokens.count, replayCount + 1)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM history_writes", at: f.db), 0)
        let ready = try await f.coordinator.readyToken(); XCTAssertNotNil(ready)
    }

    func testIncompleteHistoryCoverageKeepsContextButInvalidatesCachedBytes() async throws {
        for failureMode in 0..<3 {
            let f = try continuityFixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            try await f.coordinator.reconcile()
            f.lifecycle.persistentToken = 2
            if failureMode == 1 {
                try injectEngineSQL("CREATE TRIGGER reject_history BEFORE INSERT ON photos_content_change BEGIN SELECT RAISE(ABORT,'history write failure'); END;", at: f.db)
            } else if failureMode == 2 { f.lifecycle.providesToken = false }
            else { f.lifecycle.completeReplay = false }
            let before = try await f.gateway.candidateSnapshot()
            try await f.coordinator.reconcile()
            let checkpoint = try await f.gateway.contextCheckpoint()
            if failureMode == 2 { XCTAssertNil(checkpoint) }
            else { XCTAssertEqual(checkpoint?.context, f.context) }
            XCTAssertFalse(try before.candidateValidity.commitIfCurrent({ XCTFail("unknown history revived old admission") }))
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE state<>'ready' AND vector IS NOT NULL", at: f.db), 4)
            let ready = try await f.coordinator.readyToken(); XCTAssertNil(ready)
        }
    }

    func testFullCheckpointCoversCachedContentEditedBeforeCaptureIncludingStartupReplayGap() async throws {
        for startupGap in [false, true] {
            let f = try continuityFixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            if !startupGap { try await f.coordinator.reconcile() }
            try f.store.recordPhotosChanges(context: f.context, runID: UUID(), generation: 999,
                changed: ["page3"], deleted: [], content: ["page3"], batchSize: 1)
            if startupGap { f.lifecycle.afterReplay = { f.lifecycle.persistentToken = 2 } }
            else { f.lifecycle.persistentToken = 2 }
            // No observer callback for page0: equal metadata must not hide its edit.
            try await f.coordinator.reconcile()
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE asset_id='page0' AND state='pending' AND vector IS NOT NULL", at: f.db), 1)
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_content_change", at: f.db), 0)
            let ready = try await f.coordinator.readyToken(); XCTAssertNil(ready)
            let reopened = try SyncStore(url: f.db), lifecycle = FakePhotoKitLifecycle()
            lifecycle.candidates = (0..<4).map { candidate(key: "page\($0)") }; lifecycle.persistentToken = 2
            let gateway = PhotoKitGateway(lifecycle: lifecycle, catalogBatchSize: 128)
            let coordinator = PhotosIndexCoordinator(store: reopened, photos: gateway, fingerprinter: ContractNoReadModel(), configuration: f.configuration)
            try await coordinator.reconcile()
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE asset_id='page0' AND state='pending' AND vector IS NOT NULL", at: f.db), 1)
            let afterRestart = try await coordinator.readyToken(); XCTAssertNil(afterRestart)
        }
    }

    func testConservativeCheckpointSurvivesObserverLagForFullAndIncrementalInventory() async throws {
        for fullMerge in [true, false] {
            let f = try continuityFixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            if fullMerge {
                try f.store.recordPhotosChanges(context: f.context, runID: UUID(), generation: 999,
                    changed: ["page3"], deleted: [], content: ["page3"], batchSize: 1)
                f.lifecycle.catalogHook = { offset in
                    f.lifecycle.nextChange = .incremental(removedAssetIDs: [], insertedAssets: [], changedAssets: [])
                    f.gateway.recordLibraryChangeForTesting()
                    if offset == 3 { f.lifecycle.persistentToken = 2 }
                }
            }
            try await f.coordinator.reconcile()
            if !fullMerge {
                // A's equal-revision content edit is persistent, but its observer is delayed.
                // The delivered event only names B; B's delta read cannot cover A.
                f.lifecycle.persistentToken = 2
                let before = try await f.gateway.candidateSnapshot()
                f.lifecycle.nextChange = .incremental(removedAssetIDs: [], insertedAssets: [],
                    changedAssets: [.init(identifier: "page1", candidates: [candidate(key: "page1")], inputUnchanged: true)])
                f.gateway.recordLibraryChangeForTesting()
                let after = try await f.gateway.candidateSnapshot()
                await f.coordinator.libraryChanged(.incremental(.init(context: f.context,
                    fromGeneration: before.generation, toGeneration: after.generation, changedAssetIDs: ["page1"], deletedAssetIDs: [])))
                await f.coordinator.processDueWork(now: Date())
            }
            let saved = try await f.store.libraryResumeCheckpoint()
            let checkpoint = try XCTUnwrap(saved)
            XCTAssertEqual(checkpoint.archivedChangeToken, Data([1]), "must not skip an edit absent from the observer journal")
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_content_change", at: f.db), 0)
            let reopened = try SyncStore(url: f.db), lifecycle = FakePhotoKitLifecycle()
            lifecycle.candidates = (0..<4).map { candidate(key: "page\($0)") }; lifecycle.persistentToken = 2
            let gateway = PhotoKitGateway(lifecycle: lifecycle, catalogBatchSize: 128)
            let coordinator = PhotosIndexCoordinator(store: reopened, photos: gateway, fingerprinter: ContractNoReadModel(), configuration: f.configuration)
            try await coordinator.reconcile()
            XCTAssertFalse(lifecycle.replayedTokens.isEmpty)
            XCTAssertTrue(lifecycle.replayedTokens.allSatisfy { $0 == 1 })
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE asset_id='page0' AND state='pending' AND vector IS NOT NULL", at: f.db), 1)
            let ready = try await coordinator.readyToken(); XCTAssertNil(ready)
        }
    }

    func testUnknownRecoveryMergesNonemptyNeutralPagesAndDeletionWithoutLosingBytesOrRetries() async throws {
        let f = try continuityFixture(failedAsset: "page0")
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.coordinator.reconcile()
        try injectEngineSQL("CREATE TABLE retry_before AS SELECT asset_id,retry_count,next_retry_at,last_error FROM fingerprint_task", at: f.db)
        f.lifecycle.nextChange = .reload
        f.gateway.recordLibraryChangeForTesting()
        let unknown = try await f.gateway.candidateSnapshot()
        await f.coordinator.libraryChanged(.fullReconcileRequired)
        let request = PhotosIndexDelta(context: f.context, fromGeneration: unknown.generation - 1,
            toGeneration: unknown.generation, changedAssetIDs: ["page0"], deletedAssetIDs: [])
        do { _ = try await f.gateway.representationDelta(request); XCTFail("normal delta cannot waive unknown coverage") } catch {}
        let untransferred = try await f.gateway.beginCatalogSession(expectedGeneration: unknown.generation)
        do { _ = try await f.gateway.representationCatalogDelta(session: untransferred, delta: request)
            XCTFail("session alone cannot waive untransferred uncertainty") } catch {}
        f.lifecycle.catalogOffsets = []
        f.lifecycle.deltaRevision = "metadata-r2"
        f.lifecycle.catalogHook = { offset in
            f.lifecycle.nextChange = .incremental(removedAssetIDs: offset == 1 ? ["page1"] : [], insertedAssets: [],
                changedAssets: [.init(identifier: "page0", candidates: [candidate(key: "page0")], inputUnchanged: true)])
            f.gateway.recordLibraryChangeForTesting()
        }
        try await f.coordinator.reconcile()
        XCTAssertEqual(f.lifecycle.catalogOffsets, [0,1,2,3])
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE tombstoned=0 AND vector IS NOT NULL AND state<>'ready'", at: f.db), 3)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE asset_id='page1' AND tombstoned=1", at: f.db), 1)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM (SELECT * FROM retry_before EXCEPT SELECT asset_id,retry_count,next_retry_at,last_error FROM fingerprint_task)", at: f.db), 0)
        let unready = try await f.coordinator.readyToken(); XCTAssertNil(unready)
        for task in try await f.store.nextRepresentationTasks(now: Date(timeIntervalSince1970: 9999999999), limit: 128) {
            _ = try await f.store.completeRepresentation(task, fingerprint: f.fingerprint)
        }
        f.lifecycle.catalogHook = nil
        await f.coordinator.processDueWork(now: Date())
        let ready = try await f.coordinator.readyToken(); XCTAssertNotNil(ready)
        // A later unknown event belongs to the session interval and must still abort it.
        f.lifecycle.catalogHook = { offset in
            if offset == 2 { f.lifecycle.nextChange = .reload; f.gateway.recordLibraryChangeForTesting() }
        }
        do { try await f.coordinator.reconcile(); XCTFail("new unknown must invalidate the stable session") } catch {}
        let invalid = try await f.coordinator.readyToken(); XCTAssertNil(invalid)
    }

    func testInventoryAcknowledgementWhileFingerprintsPendingRestoresIncrementalDelivery() async throws {
        let reads = ContractReadProbe()
        let f = try continuityFixture(failedAsset: "page0", readProbe: reads)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.coordinator.reconcile()
        var events = f.gateway.changes().makeAsyncIterator()
        f.lifecycle.nextChange = .reload
        f.gateway.recordLibraryChangeForTesting()
        _ = try await f.gateway.candidateSnapshot()
        let full = await events.next(); XCTAssertEqual(full, .fullReconcileRequired)
        await f.coordinator.libraryChanged(.fullReconcileRequired)
        try await f.coordinator.reconcile()
        let ready = try await f.coordinator.readyToken(); XCTAssertNil(ready)
        XCTAssertGreaterThan(try engineSQLInteger("SELECT COUNT(*) FROM fingerprint_task", at: f.db), 0)
        for task in try await f.store.nextRepresentationTasks(now: Date(), limit: 128) {
            _ = try await f.store.completeRepresentation(task, fingerprint: f.fingerprint)
        }
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE state='ready'", at: f.db), 3)
        try injectEngineSQL("CREATE TABLE retained_vectors AS SELECT asset_id,vector FROM photos_representation", at: f.db)
        let loads = f.lifecycle.loadCount
        // A new subscription exposes sticky delivery state even with no event queued.
        var later = f.gateway.changes().makeAsyncIterator()
        f.lifecycle.nextChange = .incremental(removedAssetIDs: [], insertedAssets: [], changedAssets: [])
        f.gateway.recordLibraryChangeForTesting()
        _ = try await f.gateway.candidateSnapshot()
        guard case .incremental(let delta) = await later.next() else {
            return XCTFail("covered inventory must clear sticky full delivery before fingerprints finish")
        }
        await f.coordinator.libraryChanged(.incremental(delta))
        await f.coordinator.processDueWork(now: Date())
        XCTAssertEqual(f.lifecycle.loadCount, loads)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM (SELECT asset_id,vector FROM retained_vectors EXCEPT SELECT asset_id,vector FROM photos_representation)", at: f.db), 0)
        let stillPending = try await f.coordinator.readyToken(); XCTAssertNil(stillPending)
        XCTAssertEqual(reads.count, 0)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE state='ready'", at: f.db), 3)
    }

    func testSnapshotDuringNotificationDiagnosticDoesNotConsumeUnqueuedGeneration() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        lifecycle.candidates = [candidate(key: "old")]
        let entered = expectation(description: "observer entered")
        let finished = expectation(description: "observer returned")
        let release = DispatchSemaphore(value: 0)
        let gateway = PhotoKitGateway(lifecycle: lifecycle, catalogBatchSize: 128, diagnostics: { fields in
            if fields["phase"] == "photos-notification" {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 10)
            }
        })
        let old = try await gateway.candidateSnapshot()
        var events = gateway.changes().makeAsyncIterator()
        lifecycle.nextChange = .incremental(removedAssetIDs: ["old"],
            insertedAssets: [.init(identifier: "new", candidates: [candidate(key: "new")])], changedAssets: [])
        DispatchQueue.global().async { gateway.recordLibraryChangeForTesting(); finished.fulfill() }
        await fulfillment(of: [entered], timeout: 3)
        defer { release.signal() }
        let current = try await gateway.candidateSnapshot()
        release.signal()
        await fulfillment(of: [finished], timeout: 3)
        _ = try await gateway.candidateSnapshot() // drain producer after the callback resumes
        guard case .incremental(let delta) = await events.next() else {
            return XCTFail("snapshot must preserve the ordered candidate baseline")
        }
        XCTAssertEqual(delta.fromGeneration, old.generation)
        XCTAssertEqual(delta.toGeneration, current.generation)
        XCTAssertEqual(current.allCandidates.map(\.key), ["new"])
        XCTAssertEqual(lifecycle.loadCount, 1)
        let commits = CheckpointLog()
        let accepted = try old.candidateValidity.commitIfCurrent { commits.append("committed") }
        XCTAssertFalse(accepted); XCTAssertTrue(commits.values.isEmpty)
    }

    func testSnapshotContendingWithRecordedObserverPreservesUnconsumedBaseline() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        lifecycle.candidates = [candidate(key: "old")]
        let recorded = expectation(description: "generation recorded before enqueue")
        let callbackReturned = expectation(description: "observer finished")
        let release = DispatchSemaphore(value: 0)
        let gateway = PhotoKitGateway(lifecycle: lifecycle, catalogBatchSize: 128, queueSubmissionProbe: { phase in
            switch phase {
            case .observerRecorded:
                recorded.fulfill()
                _ = release.wait(timeout: .now() + 10)
            case .snapshotContended:
                release.signal()
            }
        })
        let before = try await gateway.candidateSnapshot()
        var events = gateway.changes().makeAsyncIterator()
        lifecycle.nextChange = .incremental(removedAssetIDs: ["old"],
            insertedAssets: [.init(identifier: "new", candidates: [candidate(key: "new")])], changedAssets: [])
        DispatchQueue.global().async { gateway.recordLibraryChangeForTesting(); callbackReturned.fulfill() }
        await fulfillment(of: [recorded], timeout: 3)
        defer { release.signal() }
        let after = try await gateway.candidateSnapshot()
        release.signal() // also bounds the deliberately unserialized mutation
        await fulfillment(of: [callbackReturned], timeout: 3)
        _ = try await gateway.candidateSnapshot()
        guard case .incremental(let delta) = await events.next() else {
            return XCTFail("generation and queue insertion must be serialized, independently of log placement")
        }
        XCTAssertEqual(delta.fromGeneration, before.generation)
        XCTAssertEqual(delta.toGeneration, after.generation)
        XCTAssertEqual(after.allCandidates.map(\.key), ["new"])
        XCTAssertEqual(lifecycle.loadCount, 1)
        let commits = CheckpointLog()
        XCTAssertFalse(try before.candidateValidity.commitIfCurrent { commits.append("stale") })
        XCTAssertTrue(commits.values.isEmpty)
    }

    func testConcurrentNotificationsKeepCandidateAndDeltaOrder() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        lifecycle.candidates = [candidate(key: "unchanged")]
        lifecycle.nextChange = .incremental(removedAssetIDs: [], insertedAssets: [], changedAssets: [])
        let firstEntered = expectation(description: "first callback remains in diagnostics")
        let callbacksReturned = expectation(description: "both callbacks returned")
        callbacksReturned.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        let gateway = PhotoKitGateway(lifecycle: lifecycle, catalogBatchSize: 128, diagnostics: { fields in
            if fields["phase"] == "photos-notification", fields["event"] == "1" {
                firstEntered.fulfill()
                _ = release.wait(timeout: .now() + 10)
            }
        })
        let before = try await gateway.candidateSnapshot()
        var events = gateway.changes().makeAsyncIterator()
        DispatchQueue.global().async { gateway.recordLibraryChangeForTesting(); callbacksReturned.fulfill() }
        await fulfillment(of: [firstEntered], timeout: 3)
        defer { release.signal() }
        // The second callback can enter while the first callback has not returned.
        gateway.recordLibraryChangeForTesting(); callbacksReturned.fulfill()
        let after = try await gateway.candidateSnapshot()
        release.signal()
        await fulfillment(of: [callbacksReturned], timeout: 3)
        for generation in 1...2 {
            guard case .incremental(let delta) = await events.next() else { return XCTFail("ordered complete interval required") }
            XCTAssertEqual(delta.fromGeneration, generation - 1)
            XCTAssertEqual(delta.toGeneration, generation)
            XCTAssertEqual(delta.changedAssetIDs, [])
            XCTAssertEqual(delta.deletedAssetIDs, [])
        }
        XCTAssertEqual(after.generation, 2)
        XCTAssertEqual(after.allCandidates.map(\.key), ["unchanged"])
        XCTAssertEqual(lifecycle.loadCount, 1)
        let commits = CheckpointLog()
        XCTAssertFalse(try before.candidateValidity.commitIfCurrent { commits.append("stale") })
        XCTAssertTrue(commits.values.isEmpty)
    }

    func testInventoryAckRejectsPendingAndNewerDetailsWithoutOpeningHistoryAdmission() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        lifecycle.candidates = [candidate(key: "a")]
        let gateway = PhotoKitGateway(lifecycle: lifecycle, catalogBatchSize: 128)
        let baseline = try await gateway.candidateSnapshot()
        lifecycle.providesToken = false
        let unavailableCheckpoint = try await gateway.contextCheckpoint(); XCTAssertNil(unavailableCheckpoint)
        let entered = expectation(description: "unclassified details block acknowledgement")
        let release = DispatchSemaphore(value: 0)
        lifecycle.changeHook = { entered.fulfill(); _ = release.wait(timeout: .now() + 10) }
        lifecycle.nextChange = .reload
        gateway.recordLibraryChangeForTesting()
        await fulfillment(of: [entered], timeout: 3)
        defer { release.signal() }
        await assertThrows({ try await gateway.acknowledgeInventory(expectedGeneration: baseline.generation) })
        await assertThrows({ try await gateway.acknowledgeInventory(expectedGeneration: baseline.generation + 1) })
        release.signal()
        let current = try await gateway.candidateSnapshot()
        lifecycle.changeHook = nil
        await assertThrows({ try await gateway.acknowledgeInventory(expectedGeneration: baseline.generation) })
        var dirty = gateway.changes().makeAsyncIterator()
        let sticky = await dirty.next(); XCTAssertEqual(sticky, .fullReconcileRequired)
        try await gateway.acknowledgeInventory(expectedGeneration: current.generation)
        let commits = CheckpointLog()
        XCTAssertFalse(try current.candidateValidity.commitIfCurrent { commits.append("premature") })
        XCTAssertTrue(commits.values.isEmpty)
        var events = gateway.changes().makeAsyncIterator()
        lifecycle.nextChange = .incremental(removedAssetIDs: [], insertedAssets: [], changedAssets: [])
        gateway.recordLibraryChangeForTesting()
        _ = try await gateway.candidateSnapshot()
        guard case .incremental = await events.next() else { return XCTFail("covered dirty state must be cleared") }
    }

    func testInventoryAckRejectsAuthorizationLossAndUnavailableLibrary() async throws {
        for authorizationLoss in [true, false] {
            let lifecycle = FakePhotoKitLifecycle()
            let gateway = PhotoKitGateway(lifecycle: lifecycle, catalogBatchSize: 128)
            _ = try await gateway.candidateSnapshot()
            gateway.recordLibraryChangeForTesting()
            let current = try await gateway.candidateSnapshot()
            if authorizationLoss { lifecycle.access = .denied } else { lifecycle.available = false }
            await assertThrows({ try await gateway.acknowledgeInventory(expectedGeneration: current.generation) }, verify: { error in
                XCTAssertEqual(error as? PhotoKitGatewayError, authorizationLoss ? .authorizationRequired : .libraryUnavailable)
            })
            var events = gateway.changes().makeAsyncIterator()
            lifecycle.nextChange = .incremental(removedAssetIDs: [], insertedAssets: [], changedAssets: [])
            gateway.recordLibraryChangeForTesting()
            let dirty = await events.next(); XCTAssertEqual(dirty, .fullReconcileRequired)
        }
    }

    func testFailedInventoryJournalAcknowledgementKeepsDeliveryDirty() async throws {
        let f = try continuityFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.coordinator.reconcile()
        f.lifecycle.nextChange = .reload
        f.gateway.recordLibraryChangeForTesting()
        _ = try await f.gateway.candidateSnapshot()
        f.lifecycle.nextChange = .incremental(removedAssetIDs: [], insertedAssets: [],
            changedAssets: [.init(identifier: "page0", candidates: [candidate(key: "page0")])])
        f.gateway.recordLibraryChangeForTesting()
        let current = try await f.gateway.candidateSnapshot()
        try injectEngineSQL("CREATE TRIGGER reject_ack BEFORE DELETE ON photos_content_change BEGIN SELECT RAISE(ABORT,'controlled ack failure'); END;", at: f.db)
        await assertThrows({ try await f.gateway.acknowledgeInventory(expectedGeneration: current.generation) })
        var dirty = f.gateway.changes().makeAsyncIterator()
        let sticky = await dirty.next(); XCTAssertEqual(sticky, .fullReconcileRequired)
        XCTAssertGreaterThan(try engineSQLInteger("SELECT COUNT(*) FROM photos_content_change", at: f.db), 0)
        try injectEngineSQL("DROP TRIGGER reject_ack", at: f.db)
        try await f.gateway.acknowledgeInventory(expectedGeneration: current.generation)
        var events = f.gateway.changes().makeAsyncIterator()
        f.lifecycle.nextChange = .incremental(removedAssetIDs: [], insertedAssets: [], changedAssets: [])
        f.gateway.recordLibraryChangeForTesting()
        _ = try await f.gateway.candidateSnapshot()
        guard case .incremental = await events.next() else { return XCTFail("successful retry acknowledges delivery") }
    }

    private func continuityFixture(failedAsset: String? = nil, readProbe: ContractReadProbe? = nil) throws -> (root: URL, db: URL, store: SyncStore,
        context: LibraryContext, lifecycle: FakePhotoKitLifecycle, gateway: PhotoKitGateway, configuration: DedupConfiguration,
        fingerprint: Fingerprint, coordinator: PhotosIndexCoordinator) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = root.appendingPathComponent("test.sqlite"), store = try SyncStore(url: db)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configuration = try JSONDecoder().decode(DedupConfiguration.self, from: Data(contentsOf: repository.appendingPathComponent("docs/research/advanced-dedup/integration-profile.json")))
        let context = LibraryContext(id: UUID(), epoch: 1)
        let fingerprint = try Fingerprint(version: configuration.fingerprint.version, values: [1] + Array(repeating: 0, count: 1023))
        let checkpoint = try JSONEncoder().encode(LibraryResumeCheckpoint(context: context, archivedChangeToken: Data([1]), photosGeneration: 0)).map { String(format: "%02x", $0) }.joined()
        let vector = fingerprint.littleEndianFloat32.map { String(format: "%02x", $0) }.joined()
        try injectEngineSQL("INSERT INTO dedup_index_state(id,context_id,context_epoch,generation,fingerprint_version,photos_generation,reconciliation_complete,resume_checkpoint) VALUES(1,'\(context.id.uuidString)',1,1,'\(configuration.fingerprint.version)',0,1,X'\(checkpoint)');", at: db)
        for id in (0..<4).map({ "page\($0)" }) {
            try injectEngineSQL("INSERT INTO photos_representation(context_id,context_epoch,asset_id,kind,revision,equivalent_to_original,revision_is_reliable,seen_generation,state,fingerprint_version,vector) VALUES('\(context.id.uuidString)',1,'\(id)','original','r1',0,1,1,'ready','\(configuration.fingerprint.version)',X'\(vector)');", at: db)
        }
        if let failedAsset {
            try injectEngineSQL("UPDATE photos_representation SET state='failed' WHERE asset_id='\(failedAsset)'; INSERT INTO fingerprint_task(context_id,context_epoch,asset_id,kind,revision,fingerprint_version,generation,retry_count,next_retry_at,last_error) SELECT context_id,context_epoch,asset_id,kind,revision,fingerprint_version,seen_generation,2,9999999999,'cloud' FROM photos_representation WHERE asset_id='\(failedAsset)';", at: db)
        }
        let lifecycle = FakePhotoKitLifecycle(); lifecycle.candidates = (0..<4).map { candidate(key: "page\($0)") }
        let reader = readProbe.map { PhotosRepresentationReader(requester: $0,
            budget: ImageWorkBudget(maxImages: 2, maxBytes: 100_000_000),
            limits: configuration.resources, targetSide: configuration.fingerprint.inputSide) }
        let gateway = PhotoKitGateway(lifecycle: lifecycle, representationReader: reader, catalogBatchSize: 128)
        return (root, db, store, context, lifecycle, gateway, configuration, fingerprint,
            PhotosIndexCoordinator(store: store, photos: gateway, fingerprinter: ContractNoReadModel(), configuration: configuration))
    }

    func testRealGatewayCoordinatorMergesClassifiedEventsDuringEveryCatalogPage() async throws {
        for membership in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try SyncStore(url: root.appendingPathComponent("test.sqlite"))
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let configuration = try JSONDecoder().decode(DedupConfiguration.self, from: Data(contentsOf: repository.appendingPathComponent("docs/research/advanced-dedup/integration-profile.json")))
            let lifecycle = FakePhotoKitLifecycle()
            lifecycle.candidates = (0..<4).map { candidate(key: "page\($0)") }
            let gateway = PhotoKitGateway(lifecycle: lifecycle, catalogBatchSize: 128)
            lifecycle.catalogHook = { offset in
                if membership && offset == 1 {
                    lifecycle.nextChange = .incremental(removedAssetIDs: ["page1"], insertedAssets: [.init(identifier: "new", candidates: [candidate(key: "new")])], changedAssets: [])
                } else { lifecycle.nextChange = .incremental(removedAssetIDs: [], insertedAssets: [], changedAssets: []) }
                gateway.recordLibraryChangeForTesting()
            }
            let coordinator = PhotosIndexCoordinator(store: store, photos: gateway, fingerprinter: ContractNoReadModel(), configuration: configuration)
            try await coordinator.reconcile()
            XCTAssertEqual(lifecycle.catalogOffsets, [0, 1, 2, 3])
            let progress = await coordinator.progress()
            XCTAssertTrue(progress.totalsKnown)
            XCTAssertEqual(progress.totalRepresentations, 4)
            let tasks = try await store.nextRepresentationTasks(now: Date(), limit: 128)
            XCTAssertEqual(Set(tasks.map { $0.descriptor.key.assetID }), membership ? ["page0", "page2", "page3", "new"] : ["page0", "page1", "page2", "page3"])
        }
    }

    func testProducerClassifiesRawObjectContentAndInputsWithoutErasingEarlierContentObligation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SyncStore(url: root.appendingPathComponent("test.sqlite"))
        let lifecycle = FakePhotoKitLifecycle()
        lifecycle.candidates = [candidate(key: "a")]
        let photos = PhotoKitGateway(lifecycle: lifecycle, catalogBatchSize: 128)
        photos.attachIndexStore(store)
        let resource = PhotoKitRepresentationResource(type: .photo, uti: "public.jpeg", filename: "a.jpg", size: nil)
        let before = PhotoKitRepresentationAsset(identifier: "a", modificationDate: Date(timeIntervalSince1970: 1), playbackStyle: .image, resources: [resource])
        let after = PhotoKitRepresentationAsset(identifier: "a", modificationDate: Date(timeIntervalSince1970: 2), playbackStyle: .image, resources: [resource])
        var snapshot = try await photos.candidateSnapshot()
        for content in [false, true, false] {
            lifecycle.rawInputChange = (before, after, content)
            photos.recordLibraryChangeForTesting()
            let latest = try await photos.candidateSnapshot()
            let delta = PhotosIndexDelta(context: try await photos.representationCatalog(offset: 0, limit: 128, expectedGeneration: latest.generation).context,
                fromGeneration: snapshot.generation, toGeneration: latest.generation, changedAssetIDs: ["a"], deletedAssetIDs: [])
            let page = try await photos.representationDelta(delta)
            if snapshot.generation == 0 {
                XCTAssertEqual(page.inputUnchangedAssetIDs, ["a"])
                XCTAssertEqual(page.invalidatedAssetIDs, [])
            } else {
                XCTAssertEqual(page.inputUnchangedAssetIDs, [])
                XCTAssertEqual(page.invalidatedAssetIDs, ["a"])
            }
            snapshot = latest
        }
    }

    func testAttachedGatewayPersists129KnownIDsAndPreservesOtherPageEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("test.sqlite"), store = try SyncStore(url: db)
        let lifecycle = FakePhotoKitLifecycle()
        lifecycle.candidates = (0..<129).map { candidate(key: "a\($0)") }
        let gateway = PhotoKitGateway(lifecycle: lifecycle, catalogBatchSize: 128)
        gateway.attachIndexStore(store)
        _ = try await gateway.candidateSnapshot()
        var events = gateway.changes().makeAsyncIterator()
        lifecycle.nextChange = .incremental(removedAssetIDs: [], insertedAssets: [], changedAssets: (0..<129).map {
            .init(identifier: "a\($0)", candidates: [candidate(key: "a\($0)")])
        })
        gateway.recordLibraryChangeForTesting()
        let latest = try await gateway.candidateSnapshot()
        let event = await events.next(); XCTAssertEqual(event, .fullReconcileRequired)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_content_change WHERE content_changed=1", at: db), 129)
        let page = try await gateway.representationCatalog(offset: 0, limit: 128, expectedGeneration: latest.generation)
        XCTAssertFalse(page.invalidateAllCachedRepresentations)
        XCTAssertEqual(page.invalidatedAssetIDs, []) // unrelated page0
    }

    func testCatalogSessionReplacementRejectsOldPageEvenAtSameRawGeneration() async throws {
        let gateway = PhotoKitGateway(lifecycle: FakePhotoKitLifecycle(), catalogBatchSize: 128)
        let snapshot = try await gateway.candidateSnapshot()
        let first = try await gateway.beginCatalogSession(expectedGeneration: snapshot.generation)
        _ = try await gateway.representationCatalog(session: first, offset: 0, limit: 128)
        let second = try await gateway.beginCatalogSession(expectedGeneration: snapshot.generation)
        XCTAssertNotEqual(first.id, second.id)
        do { _ = try await gateway.representationCatalog(session: first, offset: 1, limit: 128); XCTFail("superseded fetch session") } catch {}
        _ = try await gateway.representationCatalog(session: second, offset: 0, limit: 128)
    }

    func testNeutralProducerNotificationsKeepCatalogBaselineUsableBetweenEveryPage() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        let gateway = PhotoKitGateway(lifecycle: lifecycle, catalogBatchSize: 2)
        let baseline = try await gateway.candidateSnapshot()
        _ = try await gateway.representationCatalog(offset: 0, limit: 2, expectedGeneration: baseline.generation)
        for offset in 1...3 {
            lifecycle.nextChange = .incremental(removedAssetIDs: [], insertedAssets: [], changedAssets: [])
            gateway.recordLibraryChangeForTesting()
            _ = try await gateway.candidateSnapshot()
            let page = try await gateway.representationCatalog(offset: offset, limit: 2, expectedGeneration: baseline.generation)
            XCTAssertEqual(page.generation, baseline.generation)
            XCTAssertFalse(page.invalidateAllCachedRepresentations)
        }
    }

    func testKnown129AssetChangesRemainScopedInProducerEvidence() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        lifecycle.candidates = (0..<130).map { candidate(key: "a\($0)") }
        let gateway = PhotoKitGateway(lifecycle: lifecycle, catalogBatchSize: 128)
        _ = try await gateway.candidateSnapshot()
        var events = gateway.changes().makeAsyncIterator()
        lifecycle.nextChange = .incremental(removedAssetIDs: [], insertedAssets: [],
            changedAssets: (0..<129).map { .init(identifier: "a\($0)", candidates: [candidate(key: "a\($0)")]) })
        gateway.recordLibraryChangeForTesting()
        _ = try await gateway.candidateSnapshot()
        guard case .incremental(let delta) = await events.next() else { return XCTFail("known complete scope must remain incremental") }
        XCTAssertEqual(delta.changedAssetIDs.count, 129)
    }

    func testGenerationBoundProducerSendsOneCompleteDeltaAndFetchesOnlyRequestedIDs() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        lifecycle.candidates = [candidate(key: "old"), candidate(key: "unchanged")]
        let gateway = PhotoKitGateway(lifecycle: lifecycle, catalogBatchSize: 128)
        let before = try await gateway.candidateSnapshot()
        var events = gateway.changes().makeAsyncIterator()
        lifecycle.nextChange = .incremental(removedAssetIDs: ["old"],
            insertedAssets: [.init(identifier: "new", candidates: [candidate(key: "new")])], changedAssets: [])
        gateway.recordLibraryChangeForTesting()
        let after = try await gateway.candidateSnapshot()
        guard case .incremental(let delta) = await events.next() else { return XCTFail("complete incremental event required") }
        XCTAssertEqual(delta.fromGeneration, before.generation); XCTAssertEqual(delta.toGeneration, after.generation)
        XCTAssertEqual(delta.changedAssetIDs, ["new"]); XCTAssertEqual(delta.deletedAssetIDs, ["old"])
        let page = try await gateway.representationDelta(delta)
        XCTAssertEqual(page.descriptors.map { $0.key.assetID }, ["new"])
        XCTAssertEqual(lifecycle.deltaIDs, [["new"]]); XCTAssertEqual(lifecycle.loadCount, 1)
        lifecycle.omitDeltaIDs = true
        do { _ = try await gateway.representationDelta(delta); XCTFail("missing requested IDs must fail closed") } catch {}
    }

    func testEmptyAndLargeIncrementalEventsKeepTheirCompleteInterval() async throws {
        let lifecycle = FakePhotoKitLifecycle()
        let photos = PhotoKitGateway(lifecycle: lifecycle, catalogBatchSize: 1)
        _ = try await photos.candidateSnapshot()
        var events = photos.changes().makeAsyncIterator()
        lifecycle.nextChange = .incremental(removedAssetIDs: [], insertedAssets: [], changedAssets: [])
        photos.recordLibraryChangeForTesting(); _ = try await photos.candidateSnapshot()
        guard case .incremental(let empty) = await events.next() else { return XCTFail("empty event must advance generation") }
        XCTAssertEqual(empty.toGeneration, empty.fromGeneration + 1)
        XCTAssertEqual(empty.changedAssetIDs, []); XCTAssertEqual(empty.deletedAssetIDs, [])
        lifecycle.nextChange = .incremental(removedAssetIDs: [], insertedAssets: [
            .init(identifier: "a", candidates: []), .init(identifier: "b", candidates: [])], changedAssets: [])
        photos.recordLibraryChangeForTesting(); _ = try await photos.candidateSnapshot()
        guard case .incremental(let large) = await events.next() else { return XCTFail("whole interval required") }
        XCTAssertEqual(large.changedAssetIDs, ["a", "b"])
        lifecycle.nextChange = .incremental(removedAssetIDs: [], insertedAssets: [], changedAssets: [])
        photos.recordLibraryChangeForTesting(); _ = try await photos.candidateSnapshot()
        guard case .incremental(let next) = await events.next() else { return XCTFail("known interval must not poison later events") }
        XCTAssertEqual(next.fromGeneration, large.toGeneration)
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
    var rawInputChange: (PhotoKitRepresentationAsset, PhotoKitRepresentationAsset, Bool)?
    var changeHook: (@Sendable () -> Void)?
    func candidateIndexChange(for change: PHChange?) throws -> PhotoKitCandidateIndexChange {
        changeHook?()
        if let (before, after, content) = rawInputChange {
            return .incremental(removedAssetIDs: [], insertedAssets: [], changedAssets: [
                .init(identifier: after.identifier, candidates: [candidate(key: after.identifier)],
                      inputUnchanged: after.inputsUnchanged(from: before, assetContentChanged: content))])
        }
        return nextChange
    }
    var catalogHook: ((Int) -> Void)?
    var catalogOffsets: [Int] = []
    func representationCatalog(offset: Int, limit: Int, context: LibraryContext, generation: Int) throws -> RepresentationPage {
        catalogOffsets.append(offset); catalogHook?(offset)
        return .init(context: context, generation: generation, descriptors: [.init(key: .init(assetID: "page\(offset)", kind: .original),
            context: context, revision: "r1", size: nil, equivalentToOriginal: false, revisionIsReliable: true)],
            nextOffset: offset < 3 ? offset + 1 : nil)
    }
    var persistentToken: UInt8 = 1
    var providesToken = true
    var replayedTokens: [UInt8] = []
    var afterReplay: (() -> Void)?
    var completeReplay = true
    func archivedChangeToken() throws -> Data? { providesToken ? Data([persistentToken]) : nil }
    func replayPersistentChanges(_ token: Data, onChange: (PhotosIndexChange) -> Void, onContentChange: ([String]) -> Void) throws -> Bool {
        let from = token.first ?? 0; replayedTokens.append(from)
        if from < persistentToken { onContentChange(["page0"]) }
        afterReplay?()
        return completeReplay
    }
    var deltaIDs: [[String]] = [], omitDeltaIDs = false
    var deltaRevision = "r1"
    func representationDelta(assetIDs: [String], context: LibraryContext, generation: Int) throws -> RepresentationPage {
        deltaIDs.append(assetIDs)
        return .init(context: context, generation: generation, descriptors: omitDeltaIDs ? [] : assetIDs.map {
            .init(key: .init(assetID: $0, kind: .original), context: context, revision: deltaRevision, size: nil,
                  equivalentToOriginal: false, revisionIsReliable: true)
        }, nextOffset: nil)
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

private struct ContractNoReadModel: ImageFingerprinting {
    func fingerprint(image: CGImage, orientation: CGImagePropertyOrientation) async throws -> Fingerprint {
        XCTFail("catalog reconciliation must not invoke image inference")
        throw PhotosRepresentationError.unavailable
    }
}

private final class ContractReadProbe: PhotosRepresentationRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    func request(_ descriptor: RepresentationDescriptor, targetSide: Int,
                 completion: @escaping @Sendable (PhotosRepresentationCallback) -> Void) throws {
        lock.lock(); requests += 1; lock.unlock()
        XCTFail("retained ready images must not be read again")
        completion(.failure(PhotosRepresentationError.unavailable))
    }
}
