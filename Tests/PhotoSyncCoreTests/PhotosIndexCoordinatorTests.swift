import XCTest
import CoreML
import CoreGraphics
import ImageIO
@testable import PhotoSyncCore

final class PhotosIndexCoordinatorTests: XCTestCase {
    func testOwnedReadCompletedAfterPauseCannotStartLazyModelOrBecomeReadFailure() async throws {
        let f = try fixture(), gate = CoordinatorGate(), calls = CoordinatorPhysicalCount()
        let golden = (0..<4).map { _ in ModelSelfTestCase(input: Data(repeating: 0, count: 3 * 320 * 320 * 4),
            reference: [1] + Array(repeating: 0, count: 1023)) }
        let model = try CoreMLFingerprinter(configuration: f.configuration.fingerprint, selfTests: golden, factory: { _ in
            calls.increment(); return CoordinatorPhysicalSession()
        })
        let coordinator = PhotosIndexCoordinator(store: f.store, photos: f.photos, fingerprinter: model, configuration: f.configuration)
        await f.photos.set([descriptor(f.photos.context)]); await f.photos.gateNextRead(gate)
        try await coordinator.reconcile()
        let work = Task { await coordinator.processDueWork(now: now) }
        await gate.waitUntilEntered()
        model.setExecutionEligible(false); await coordinator.setPaused(true)
        let held = await f.photos.budget.snapshot(); XCTAssertEqual(held.images, 1)
        XCTAssertEqual(calls.value, 0)
        await gate.release(); await work.value
        XCTAssertEqual(calls.value, 0, "read admitted before pause must not start a new session")
        let released = await f.photos.budget.snapshot(); XCTAssertEqual(released.images, 0)
        let tasks = try await f.store.nextRepresentationTasks(now: now, limit: 1)
        XCTAssertEqual(tasks.count, 1); XCTAssertEqual(tasks.first?.retryCount, 0); XCTAssertNil(tasks.first?.nextRetryAt)
        let paused = await coordinator.progress(); XCTAssertNil(paused.issue)
        model.setExecutionEligible(true); await coordinator.setPaused(false); await coordinator.processDueWork(now: now)
        let ready = await coordinator.progress(); XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(calls.value, 1)
    }
    func testModelWaitKeepsTaskUnreadyAcrossReconciliation() async throws {
        let f = try fixture()
        await f.photos.set([descriptor(f.photos.context)])
        await f.model.setUnavailable(true)
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        let failed = await f.coordinator.progress()
        XCTAssertEqual(failed.state, .waiting); XCTAssertEqual(failed.issue, ModelExecutionUnavailable.summary)
        try await f.coordinator.reconcile()
        let retained = await f.coordinator.progress(); XCTAssertEqual(retained.issue, ModelExecutionUnavailable.summary)
        let before = try await f.store.nextRepresentationTasks(now: now.addingTimeInterval(59), limit: 2)
        XCTAssertTrue(before.isEmpty)
        await f.model.setUnavailable(false)
        await f.coordinator.processDueWork(now: now.addingTimeInterval(60))
        let recovered = await f.coordinator.progress(); XCTAssertEqual(recovered.state, .ready); XCTAssertNil(recovered.issue)
    }

    private let now = Date(timeIntervalSince1970: 1_000)

    func testNoChangeReconciliationDoesNoImageIO() async throws {
        let f = try fixture()
        await f.photos.set([descriptor(f.photos.context)])
        try await f.coordinator.reconcile()
        await f.coordinator.processDueWork(now: now)
        try await assertNotNil(try await f.coordinator.readyToken())
        await f.photos.resetReads(); await f.model.reset()
        try await f.coordinator.reconcile()
        await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.photos.readCount, 0)
        await assertEqual(await f.model.count, 0)
        try await assertNotNil(try await f.coordinator.readyToken())
    }

    func testUnchangedFullReconciliationWritesNoRepresentationOrTaskRows() async throws {
        for pending in [false, true] {
            let f = try fixture()
            let a = descriptor(f.photos.context), current = descriptor(f.photos.context, kind: .current, equivalent: true)
            let b = descriptor(f.photos.context, asset: "retry")
            await f.photos.setPages([.init(context: f.photos.context, generation: 1,
                descriptors: pending ? [a, current, b] : [a, current], nextOffset: nil,
                exclusions: [.init(descriptor: descriptor(f.photos.context, asset: "raw"), reason: .rawResource)])])
            if pending { await f.photos.fail("retry") }
            try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
            try installWriteAudit(at: f.db)
            try injectEngineSQL("CREATE TABLE previous_tasks AS SELECT * FROM fingerprint_task;", at: f.db)
            await f.photos.resetReads(); await f.model.reset()
            try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
            for table in ["photos_representation", "fingerprint_task", "photos_index_exclusion"] {
                XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM p11_writes WHERE table_name='\(table)'", at: f.db), 0)
            }
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM (SELECT * FROM previous_tasks EXCEPT SELECT * FROM fingerprint_task)", at: f.db), 0)
            await assertEqual(await f.photos.readCount, 0); await assertEqual(await f.model.count, 0)
            let token = try await f.coordinator.readyToken(); XCTAssertEqual(token == nil, pending)
        }
    }

    func testSingleEditInvalidatesOnlyAffectedRepresentations() async throws {
        let f = try fixture()
        let original = descriptor(f.photos.context)
        let current = descriptor(f.photos.context, kind: .current, revision: "edit1")
        await f.photos.set([original, current]); try await f.coordinator.reconcile()
        await f.coordinator.processDueWork(now: now)
        await f.photos.resetReads(); await f.model.reset()
        await f.photos.set([original, descriptor(f.photos.context, kind: .current, revision: "edit2")])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.photos.readKinds, [.current])
        await assertEqual(await f.model.count, 1)
    }

    func testRevertCoalescesEquivalentRepresentations() async throws {
        let f = try fixture()
        await f.photos.set([descriptor(f.photos.context), descriptor(f.photos.context, kind: .current, revision: "edit")])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await f.photos.set([descriptor(f.photos.context), descriptor(f.photos.context, kind: .current, equivalent: true)])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        let publication = try await f.store.indexPublication()
        XCTAssertEqual(publication?.representationCount, 1)
        try await assertNotNil(try await f.coordinator.readyToken())
    }

    func testOneFailedAssetDoesNotStopOtherIndexWorkButBlocksReady() async throws {
        let f = try fixture()
        await f.photos.set([descriptor(f.photos.context, asset: "a"), descriptor(f.photos.context, asset: "b")])
        await f.photos.fail("a")
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.model.count, 1)
        try await assertNil(try await f.coordinator.readyToken())
        let progress = await f.coordinator.progress()
        XCTAssertEqual(progress.readyAssets, 1); XCTAssertEqual(progress.state, .waiting)
        await f.photos.resetReads(); await f.coordinator.processDueWork(now: now.addingTimeInterval(4))
        await assertEqual(await f.photos.readCount, 0)
        await f.photos.fail(nil); await f.coordinator.processDueWork(now: now.addingTimeInterval(5))
        try await assertNotNil(try await f.coordinator.readyToken())
    }

    func testMixedExcludedPagesPreservePartiallyEligibleAsset() async throws {
        let f = try fixture()
        await f.photos.setPages([
            .init(context: f.photos.context, generation: 1, descriptors: [], nextOffset: 1,
                  exclusions: [.init(descriptor: descriptor(f.photos.context, asset: "raw"), reason: .rawResource)]),
            .init(context: f.photos.context, generation: 1,
                  descriptors: [descriptor(f.photos.context, asset: "partial", kind: .current)], nextOffset: nil,
                  exclusions: [.init(descriptor: descriptor(f.photos.context, asset: "partial"), reason: .rawResource)])
        ])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        let p = await f.coordinator.progress()
        XCTAssertEqual(p.totalAssets, 2); XCTAssertEqual(p.excludedAssets, 1)
        XCTAssertEqual(p.totalRepresentations, 1); XCTAssertEqual(p.readyAssets, 1)
        try await assertNotNil(try await f.coordinator.readyToken())
        await assertEqual(await f.photos.requestedLimits, [f.configuration.resources.catalogBatchSize, f.configuration.resources.catalogBatchSize])
    }

    func testSameRevisionExplicitPageInvalidationRecomputes() async throws {
        let f = try fixture(); let d = descriptor(f.photos.context)
        await f.photos.set([d]); try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await f.model.reset(); await f.photos.resetReads()
        await f.photos.setPages([.init(context: f.photos.context, generation: 2, descriptors: [d], nextOffset: nil, invalidatedAssetIDs: [d.key.assetID])])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.model.count, 1)
        try await assertNotNil(try await f.coordinator.readyToken())
    }

    func testAllInvalidationOnLaterPageInvalidatesEarlierCachedPage() async throws {
        let f = try fixture(); let a = descriptor(f.photos.context, asset: "a"), b = descriptor(f.photos.context, asset: "b")
        await f.photos.set([a, b]); try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await f.model.reset()
        await f.photos.setPages([
            .init(context: f.photos.context, generation: 2, descriptors: [a], nextOffset: 1),
            .init(context: f.photos.context, generation: 2, descriptors: [b], nextOffset: nil, invalidateAllCachedRepresentations: true)
        ])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.model.count, 2)
    }

    func testConservativeReadNeverBecomesReadyOrExcluded() async throws {
        let f = try fixture(); await f.photos.set([descriptor(f.photos.context)])
        await f.photos.setConservative(true)
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.model.count, 0)
        try await assertNil(try await f.coordinator.readyToken())
        let p = await f.coordinator.progress(); XCTAssertEqual(p.excludedAssets, 0); XCTAssertEqual(p.state, .waiting)
    }

    func testDeletedAssetAndLateResultNeverReturn() async throws {
        let f = try fixture(); await f.photos.set([descriptor(f.photos.context)])
        let gate = CoordinatorGate(); await f.model.setGate(gate)
        try await f.coordinator.reconcile()
        let work = Task { await f.coordinator.processDueWork(now: now) }
        await gate.waitUntilEntered()
        await f.photos.set([]); try await f.coordinator.reconcile()
        await gate.release(); await work.value
        let publication = try await f.store.indexPublication()
        XCTAssertEqual(publication?.representationCount, 0)
        let tasks = try await f.store.nextRepresentationTasks(now: now, limit: 10); XCTAssertTrue(tasks.isEmpty)
        await assertEqual(await f.photos.readCount, 1)
    }

    func testPauseDuringPreReadSnapshotStartsNoPhysicalWork() async throws {
        let f = try fixture(); await f.photos.set([descriptor(f.photos.context)])
        try await f.coordinator.reconcile()
        let gate = CoordinatorGate(); await f.photos.gateSnapshot(1, using: gate)
        let work = Task { await f.coordinator.processDueWork(now: now) }
        await gate.waitUntilEntered()
        await f.coordinator.setPaused(true)
        await gate.release(); await work.value
        await assertEqual(await f.photos.readCount, 0)
        await assertEqual(await f.model.count, 0)
        let pending = try await f.store.nextRepresentationTasks(now: now, limit: 1)
        XCTAssertEqual(pending.count, 1)
        let progress = await f.coordinator.progress(); XCTAssertEqual(progress.state, .paused)
        await f.coordinator.setPaused(false)
        await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.photos.readCount, 1)
        await assertEqual(await f.model.count, 1)
        try await assertNotNil(try await f.coordinator.readyToken())
    }

    func testPauseAndRepeatedPollingDoNotDuplicateInFlightWork() async throws {
        let f = try fixture(); await f.photos.set([descriptor(f.photos.context, asset: "a"), descriptor(f.photos.context, asset: "b")])
        let gate = CoordinatorGate(); await f.model.setGate(gate)
        try await f.coordinator.reconcile()
        let work = Task { await f.coordinator.processDueWork(now: now) }
        await gate.waitUntilEntered()
        await f.coordinator.processDueWork(now: now)
        await f.coordinator.setPaused(true); work.cancel()
        let occupied = await f.photos.budget.snapshot(); XCTAssertEqual(occupied.images, 1)
        await gate.release(); await work.value
        await assertEqual(await f.photos.readCount, 1)
        let p = await f.coordinator.progress(); XCTAssertEqual(p.state, .paused); XCTAssertEqual(p.readyRepresentations, 1)
        let released = await f.photos.budget.snapshot(); XCTAssertEqual(released.images, 0)
        await f.coordinator.setPaused(false); await f.coordinator.processDueWork(now: now)
        try await assertNotNil(try await f.coordinator.readyToken())
    }

    func testPartialFingerprintsResumeFromInventoryCheckpoint() async throws {
        let f = try fixture(); await f.photos.set([descriptor(f.photos.context, asset: "a"), descriptor(f.photos.context, asset: "b")])
        await f.photos.fail("b")
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        let checkpoint = try await f.store.libraryResumeCheckpoint(); XCTAssertEqual(checkpoint?.context, f.photos.context)
        try await assertNil(try await f.coordinator.readyToken())
        let reopened = try SyncStore(url: f.db)
        let model = CoordinatorModel(version: f.configuration.fingerprint.version)
        let resumed = PhotosIndexCoordinator(store: reopened, photos: f.photos, fingerprinter: model,
            configuration: f.configuration)
        await f.photos.fail(nil); await f.photos.resetReads()
        try await resumed.reconcile(); await resumed.processDueWork(now: now.addingTimeInterval(5))
        await assertEqual(await f.photos.resumeCount, 1); await assertEqual(await f.photos.readCount, 1)
        await assertEqual(await model.count, 1); try await assertNotNil(try await resumed.readyToken())
        await assertEqual(await f.photos.checkpointBeforeSnapshot, true)
    }

    func testFailedResumeDoesNotReuseOldContextFacts() async throws {
        let f = try fixture(); await f.photos.set([descriptor(f.photos.context)])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        let reopened = try SyncStore(url: f.db); await f.photos.setResumeSuccess(false); await f.model.reset()
        let resumed = PhotosIndexCoordinator(store: reopened, photos: f.photos, fingerprinter: f.model,
            configuration: f.configuration)
        try await resumed.reconcile(); await resumed.processDueWork(now: now)
        await assertEqual(await f.model.count, 1)
    }

    func testChangeDuringAcknowledgementBlocksReady() async throws {
        let f = try fixture(); await f.photos.set([descriptor(f.photos.context)])
        await f.photos.changeOnAcknowledgement(true)
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        try await assertNil(try await f.coordinator.readyToken())
        await assertEqual(await f.photos.acknowledgementCount, 1)
    }

    func testObservedChangeImmediatelyBlocksPreviouslyReadyToken() async throws {
        let f = try fixture(); await f.photos.set([descriptor(f.photos.context)])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        try await assertNotNil(try await f.coordinator.readyToken())
        await f.photos.set([descriptor(f.photos.context, revision: "new")])
        try await assertNil(try await f.coordinator.readyToken())
    }

    func testReopenedReadyFactsRepublishReadinessWithoutInference() async throws {
        let f = try fixture(); await f.photos.set([descriptor(f.photos.context)])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        let store = try SyncStore(url: f.db)
        let resumed = PhotosIndexCoordinator(store: store, photos: f.photos, fingerprinter: f.model, configuration: f.configuration)
        await f.photos.resetReads(); await f.model.reset()
        try await assertNil(try await resumed.readyToken())
        try await resumed.reconcile(); await resumed.processDueWork(now: now)
        try await assertNotNil(try await resumed.readyToken()); await assertEqual(await f.model.count, 0)
        await assertEqual(await f.photos.readCount, 0)
    }

    func testPausingCurrentIndexDoesNotInventUnfinishedAnalysis() async throws {
        let f = try fixture(); await f.photos.set([descriptor(f.photos.context)])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await f.coordinator.setPaused(true)
        let progress = await f.coordinator.progress()
        XCTAssertEqual(progress.state, .ready)
        XCTAssertTrue(progress.totalsKnown)
        try await assertNotNil(try await f.coordinator.readyToken())
    }

    func testCompleteEmptyAndOnlyExcludedCatalogsCanBecomeReady() async throws {
        let f = try fixture(); await f.photos.set([])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        try await assertNotNil(try await f.coordinator.readyToken())
        var p = await f.coordinator.progress(); XCTAssertTrue(p.totalsKnown); XCTAssertEqual(p.totalAssets, 0)
        await f.photos.setPages([.init(context: f.photos.context, generation: 2, descriptors: [], nextOffset: nil,
            exclusions: [.init(descriptor: descriptor(f.photos.context), reason: .rawResource)])])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        try await assertNotNil(try await f.coordinator.readyToken())
        p = await f.coordinator.progress(); XCTAssertEqual(p.excludedAssets, 1); XCTAssertEqual(p.totalRepresentations, 0)
        await assertEqual(await f.model.count, 0)
    }

    func testFailedCatalogNeverPublishesPartialEmptyAndPreservesSurvivors() async throws {
        let f = try fixture(); let original = descriptor(f.photos.context)
        await f.photos.set([original]); try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await f.photos.setPages([.init(context: f.photos.context, generation: 2, descriptors: [], nextOffset: 1)])
        do { try await f.coordinator.reconcile(); XCTFail("Expected incomplete catalog failure") } catch {}
        try await assertNil(try await f.coordinator.readyToken())
        let incomplete = await f.coordinator.progress(); XCTAssertFalse(incomplete.totalsKnown)
        await f.photos.set([original]); await f.model.reset()
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.model.count, 0)
        try await assertNotNil(try await f.coordinator.readyToken())
    }

    func testReopensAtPublicationBoundariesWithoutClearingFacts() async throws {
        for stage in 0...1 {
            let f = try fixture(); let d = descriptor(f.photos.context); await f.photos.set([d])
            let checkpoint = try await f.photos.contextCheckpoint()
            let snapshot = try await f.photos.candidateSnapshot()
            let generation = try await f.store.beginIndexReconciliation(context: f.photos.context,
                photosGeneration: snapshot.generation, fingerprintVersion: f.configuration.fingerprint.version)
            try await f.store.upsertRepresentations([d], generation: generation)
            try await f.store.finishIndexReconciliation(generation: generation, seenKeys: Set(([d]).map(\.key)), checkpoint: checkpoint)
            let tasks = try await f.store.nextRepresentationTasks(now: now, limit: 1)
            let fingerprint = try Fingerprint(version: f.configuration.fingerprint.version, values: [1] + Array(repeating: 0, count: 1023))
            _ = try await f.store.completeRepresentation(try XCTUnwrap(tasks.first), fingerprint: fingerprint)
            let value = try await f.store.indexPublication()
            let publication = try XCTUnwrap(value)
            XCTAssertEqual(publication.representationCount, 1)
            if stage == 1 { _ = try await f.store.markIndexPublished(token: publication.token) }
            let reopened = try SyncStore(url: f.db)
            let coordinator = PhotosIndexCoordinator(store: reopened, photos: f.photos, fingerprinter: f.model,
                configuration: f.configuration)
            try await assertNil(try await coordinator.readyToken())
            try await coordinator.reconcile(); await coordinator.processDueWork(now: now)
            try await assertNotNil(try await coordinator.readyToken())
            await assertEqual(await f.model.count, 0)
        }
    }

    func testFingerprintVersionMismatchRecomputesRatherThanReusing() async throws {
        let f = try fixture(); await f.photos.set([descriptor(f.photos.context)])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        let original = f.configuration.fingerprint
        for changed in [try FingerprintConfiguration(modelSHA256: String(repeating: "1", count: 64), inputSide: original.inputSide,
                resizeMode: original.resizeMode, colorSpace: original.colorSpace, mean: original.mean, std: original.std),
            try FingerprintConfiguration(modelSHA256: original.modelSHA256, inputSide: 321,
                resizeMode: original.resizeMode, colorSpace: original.colorSpace, mean: original.mean, std: original.std)] {
            let configuration = try DedupConfiguration(fingerprint: changed, policyVersion: DedupConfiguration.computePolicyVersion(fingerprintVersion: changed.version, threshold: f.configuration.threshold, backend: f.configuration.backend),
                threshold: f.configuration.threshold, backend: f.configuration.backend, resources: f.configuration.resources,
                evidenceCandidateLimit: f.configuration.evidenceCandidateLimit, acceptanceID: f.configuration.acceptanceID)
            let model = CoordinatorModel(version: changed.version)
            let coordinator = PhotosIndexCoordinator(store: f.store, photos: f.photos, fingerprinter: model,
                configuration: configuration)
            try await coordinator.reconcile(); await coordinator.processDueWork(now: now)
            await assertEqual(await model.count, 1)
            let token = try await coordinator.readyToken(); XCTAssertEqual(token?.fingerprintVersion, changed.version)
        }
    }

    func testStoreIssuedGenerationRejectsLateFailureAndCompletion() async throws {
        let f = try fixture(); let d = descriptor(f.photos.context)
        let first = try await f.store.beginIndexReconciliation(context: f.photos.context, photosGeneration: 1, fingerprintVersion: f.configuration.fingerprint.version)
        try await f.store.upsertRepresentations([d], generation: first); try await f.store.finishIndexReconciliation(generation: first, seenKeys: Set(([d]).map(\.key)))
        let oldTasks = try await f.store.nextRepresentationTasks(now: now, limit: 1)
        let old = try XCTUnwrap(oldTasks.first)
        let second = try await f.store.beginIndexReconciliation(context: f.photos.context, photosGeneration: 1, fingerprintVersion: f.configuration.fingerprint.version)
        try await f.store.invalidateRepresentations(assetIDs: [d.key.assetID], generation: second)
        try await f.store.upsertRepresentations([d], generation: second); try await f.store.finishIndexReconciliation(generation: second, seenKeys: Set(([d]).map(\.key)))
        try await f.store.failRepresentation(old, nextRetryAt: now.addingTimeInterval(100), detail: "late failure")
        let accepted = try await f.store.completeRepresentation(old, fingerprint: Fingerprint(version: old.fingerprintVersion, values: [1] + Array(repeating: 0, count: 1023)))
        XCTAssertFalse(accepted)
        let current = try await f.store.nextRepresentationTasks(now: now, limit: 1)
        XCTAssertEqual(current.count, 1); XCTAssertEqual(current.first?.retryCount, 0)
    }

    func testChangeBeforeDerivedPublicationNeverAcknowledgesStaleFacts() async throws {
        let f = try fixture(); await f.photos.set([descriptor(f.photos.context)])
        try await f.coordinator.reconcile()
        let gate = CoordinatorGate(); await f.photos.gateSnapshot(3, using: gate)
        let work = Task { await f.coordinator.processDueWork(now: now) }
        await gate.waitUntilEntered()
        let facts = try await f.store.indexPublication(); XCTAssertNotNil(facts)
        await f.photos.set([descriptor(f.photos.context, revision: "changed")])
        await gate.release(); await work.value
        try await assertNil(try await f.coordinator.readyToken())
        await assertEqual(await f.photos.acknowledgementCount, 0)
    }

    func testUnreliableRevisionAlwaysRebuildsWithinResourceLimits() async throws {
        let f = try fixture()
        let descriptors = (0..<12).map { i in RepresentationDescriptor(key: .init(assetID: "asset-\(i)", kind: .original),
            context: f.photos.context, revision: "same", size: nil, equivalentToOriginal: false, revisionIsReliable: false) }
        await f.photos.set(descriptors)
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await f.model.reset(); await f.photos.resetReads()
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.model.count, 12)
        let maximum = await f.photos.maxImagesObserved
        XCTAssertEqual(maximum, 1)
        XCTAssertLessThanOrEqual(maximum, f.configuration.resources.maxInFlightTasks)
        XCTAssertLessThanOrEqual(maximum, f.configuration.resources.photoRequestConcurrency)
        XCTAssertLessThanOrEqual(maximum, f.configuration.resources.inferenceConcurrency)
    }

    func testEquivalentCurrentWithExcludedOriginalStaysEligible() async throws {
        let f = try fixture()
        await f.photos.setPages([.init(context: f.photos.context, generation: 1,
            descriptors: [descriptor(f.photos.context, kind: .current, equivalent: true)], nextOffset: nil,
            exclusions: [.init(descriptor: descriptor(f.photos.context), reason: .rawResource)])])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        let p = await f.coordinator.progress(); XCTAssertEqual(p.totalAssets, 1); XCTAssertEqual(p.excludedAssets, 0)
        XCTAssertEqual(p.readyRepresentations, 1)
        await assertEqual(await f.photos.readKinds, [.current])
        try await assertNotNil(try await f.coordinator.readyToken())
    }

    func testThresholdOnlyChangeReusesFingerprints() async throws {
        let f = try fixture(); await f.photos.set([descriptor(f.photos.context)])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        let c = f.configuration
        let changed = try DedupConfiguration(fingerprint: c.fingerprint,
            policyVersion: DedupConfiguration.computePolicyVersion(fingerprintVersion: c.fingerprint.version, threshold: 0.97, backend: c.backend),
            threshold: 0.97, backend: c.backend, resources: c.resources, evidenceCandidateLimit: c.evidenceCandidateLimit, acceptanceID: c.acceptanceID)
        let model = CoordinatorModel(version: changed.fingerprint.version)
        let coordinator = PhotosIndexCoordinator(store: f.store, photos: f.photos, fingerprinter: model,
            configuration: changed)
        try await coordinator.reconcile(); await coordinator.processDueWork(now: now)
        await assertEqual(await model.count, 0)
        try await assertNotNil(try await coordinator.readyToken())
    }

    func testOlderV4CheckpointColumnsUpgradePreservesFacts() async throws {
        let f = try fixture(); await f.photos.set([descriptor(f.photos.context)])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        let before = try await f.store.indexPublication()
        try injectEngineSQL("PRAGMA user_version=4; DROP TABLE photos_index_exclusion; ALTER TABLE dedup_index_state DROP COLUMN resume_checkpoint; ALTER TABLE dedup_index_state DROP COLUMN excluded_assets;", at: f.db)
        let reopened = try SyncStore(url: f.db)
        let after = try await reopened.indexPublication()
        XCTAssertNotNil(before); XCTAssertNil(after) // v4 exclusion facts require a fresh inventory.
        let bytes = try Fingerprint(version: f.configuration.fingerprint.version,
            values: [1] + Array(repeating: 0, count: 1023)).littleEndianFloat32
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE asset_id='asset' AND kind='original' AND width=8 AND height=8 AND vector=X'\(hex)' AND fingerprint_version='\(f.configuration.fingerprint.version)'", at: f.db), 1)
        let checkpoint = try await reopened.libraryResumeCheckpoint(); XCTAssertNil(checkpoint)
    }

    func testCheckpointContextMismatchRollsBackInventoryFinish() async throws {
        let f = try fixture(); let generation = try await f.store.beginIndexReconciliation(context: f.photos.context,
            photosGeneration: 1, fingerprintVersion: f.configuration.fingerprint.version)
        let invalid = LibraryResumeCheckpoint(context: .init(id: UUID(), epoch: 1), archivedChangeToken: Data([1]))
        do { try await f.store.finishIndexReconciliation(generation: generation, seenKeys: [], checkpoint: invalid); XCTFail("Expected context rejection") } catch {}
        let p = try await f.store.indexProgress(); XCTAssertFalse(p.totalsKnown)
        let checkpoint = try await f.store.libraryResumeCheckpoint(); XCTAssertNil(checkpoint)
    }

    func testThrownResumeCannotLoseRequiredFullInvalidationOnRetry() async throws {
        let f = try fixture(); await f.photos.set([descriptor(f.photos.context)])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        let reopened = try SyncStore(url: f.db); await f.photos.throwNextResume(); await f.model.reset()
        let resumed = PhotosIndexCoordinator(store: reopened, photos: f.photos, fingerprinter: f.model,
            configuration: f.configuration)
        do { try await resumed.reconcile(); XCTFail("Expected interrupted replay") } catch {}
        try await resumed.reconcile(); await resumed.processDueWork(now: now)
        await assertEqual(await f.model.count, 1)
    }

    func testGenerationMismatchTriggersReconciliationWithoutStreamConsumption() async throws {
        let f = try fixture(); await f.photos.set([descriptor(f.photos.context)])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await f.model.reset(); await f.photos.set([descriptor(f.photos.context, revision: "changed")])
        try await assertNil(try await f.coordinator.readyToken())
        await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.model.count, 1)
        try await assertNotNil(try await f.coordinator.readyToken())
    }

    func testWaitingClassificationSurvivesReconciliationBeforeRetryDeadline() async throws {
        for cloud in [true, false] {
            let f = try fixture()
            let image = descriptor(f.photos.context)
            await f.photos.set([image])
            await f.photos.setReadFailures([image.key.assetID: cloud ? .iCloudUnavailable("offline") : .invalidImage])
            try await f.coordinator.reconcile()
            await f.coordinator.processDueWork(now: now)
            let expected = cloud ? "正在等待 iCloud 图像，连接恢复后自动继续" : "部分图库图像暂时无法读取，正在等待重试。"
            let failed = await f.coordinator.progress()
            XCTAssertEqual(failed.issue, expected)
            let before = try await f.store.nextRepresentationTasks(now: now.addingTimeInterval(5), limit: 10)
            XCTAssertEqual(before.first?.retryCount, 1)
            XCTAssertEqual(before.first?.nextRetryAt, now.addingTimeInterval(5))
            await f.photos.resetReads()
            try await f.coordinator.reconcile()
            await f.coordinator.processDueWork(now: now.addingTimeInterval(1))
            let retained = await f.coordinator.progress()
            XCTAssertEqual(retained.state, .waiting)
            XCTAssertEqual(retained.issue, expected)
            await assertEqual(await f.photos.readCount, 0)
            let after = try await f.store.nextRepresentationTasks(now: now.addingTimeInterval(5), limit: 10)
            XCTAssertEqual(after.first?.retryCount, before.first?.retryCount)
            XCTAssertEqual(after.first?.nextRetryAt, before.first?.nextRetryAt)
            await f.photos.setReadFailures([:])
            await f.coordinator.processDueWork(now: now.addingTimeInterval(5))
            let recovered = await f.coordinator.progress()
            XCTAssertEqual(recovered.state, .ready); XCTAssertNil(recovered.issue)
        }
    }

    func testLastCloudRecoveryPreservesOtherGenericFailureAndDeadline() async throws {
        let f = try fixture()
        await f.photos.set([descriptor(f.photos.context, asset: "a-generic"), descriptor(f.photos.context, asset: "z-cloud")])
        await f.photos.setReadFailures(["a-generic": .invalidImage, "z-cloud": .iCloudUnavailable("offline")])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await f.photos.setReadFailures(["a-generic": .invalidImage])
        await f.coordinator.processDueWork(now: now.addingTimeInterval(5))
        let progress = await f.coordinator.progress()
        XCTAssertEqual(progress.state, .waiting); XCTAssertEqual(progress.readyAssets, 1)
        XCTAssertEqual(progress.issue, "部分图库图像暂时无法读取，正在等待重试。")
        let retry = try await f.store.nextRepresentationTasks(now: now.addingTimeInterval(20), limit: 10)
        XCTAssertEqual(retry.map { $0.descriptor.key.assetID }, ["a-generic"])
        XCTAssertEqual(retry.first?.retryCount, 2); XCTAssertEqual(retry.first?.nextRetryAt, now.addingTimeInterval(20))
        await f.photos.resetReads()
        await f.coordinator.processDueWork(now: now.addingTimeInterval(6))
        let waiting = await f.coordinator.progress()
        XCTAssertEqual(waiting.issue, progress.issue)
        await assertEqual(await f.photos.readCount, 0)
        await f.photos.setReadFailures([:]); await f.coordinator.processDueWork(now: now.addingTimeInterval(20))
        let ready = await f.coordinator.progress(); XCTAssertEqual(ready.state, .ready); XCTAssertNil(ready.issue)
    }

    func testNewGenericFailureReplacesCloudClassificationForSameRepresentation() async throws {
        let f = try fixture(), asset = "cloud"
        await f.photos.set([descriptor(f.photos.context, asset: asset)])
        await f.photos.setReadFailures([asset: .iCloudUnavailable("offline")])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await f.photos.setReadFailures([asset: .invalidImage])
        await f.coordinator.processDueWork(now: now.addingTimeInterval(5))
        let reclassified = await f.coordinator.progress()
        XCTAssertEqual(reclassified.state, .waiting)
        XCTAssertEqual(reclassified.issue, "部分图库图像暂时无法读取，正在等待重试。")
        try await f.coordinator.reconcile()
        let afterReconcile = await f.coordinator.progress()
        XCTAssertEqual(afterReconcile.issue, reclassified.issue)
        let retry = try await f.store.nextRepresentationTasks(now: now.addingTimeInterval(20), limit: 1)
        XCTAssertEqual(retry.first?.retryCount, 2); XCTAssertEqual(retry.first?.nextRetryAt, now.addingTimeInterval(20))
    }

    func testCloudClassificationPrunesOnlyReplacedOrRemovedFailureFacts() async throws {
        for change in ["removal", "revision", "invalidation", "context", "coalescing"] {
            let f = try fixture()
            let cloud = descriptor(f.photos.context, asset: "cloud", kind: change == "coalescing" ? .current : .original,
                equivalent: change == "coalescing")
            let generic = descriptor(f.photos.context, asset: "generic")
            await f.photos.set([cloud, generic])
            await f.photos.setReadFailures(["cloud": .iCloudUnavailable("offline"), "generic": .invalidImage])
            try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
            let failed = await f.coordinator.progress()
            XCTAssertEqual(failed.issue, "正在等待 iCloud 图像，连接恢复后自动继续", change)
            switch change {
            case "removal": await f.photos.set([generic])
            case "revision": await f.photos.set([descriptor(f.photos.context, asset: "cloud", revision: "r2"), generic])
            case "invalidation":
                await f.photos.setPages([.init(context: f.photos.context, generation: 2, descriptors: [cloud, generic],
                    nextOffset: nil, invalidatedAssetIDs: ["cloud"])])
            case "coalescing": await f.photos.set([cloud, descriptor(f.photos.context, asset: "cloud"), generic])
            default:
                let replacement = LibraryContext(id: UUID(), epoch: 2)
                await f.photos.replaceContext(replacement, descriptors: [descriptor(replacement, asset: "generic")])
            }
            try await f.coordinator.reconcile()
            if change == "context" { await f.coordinator.processDueWork(now: now.addingTimeInterval(1)) }
            let pruned = await f.coordinator.progress()
            XCTAssertEqual(pruned.state, .waiting, change)
            XCTAssertEqual(pruned.issue, "部分图库图像暂时无法读取，正在等待重试。", change)
        }
    }

    func testContinuousDeltaAddEditDeleteUsesOnlyChangedIDFetchAndBoundedWrites() async throws {
        var writes: [[Int]] = []
        for size in [2, 40] {
            let f = try fixture()
            let original = (0..<size).map { descriptor(f.photos.context, asset: "a\($0)") }
            await f.photos.set(original); try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
            try installWriteAudit(at: f.db)
            try injectEngineSQL("CREATE TABLE untouched AS SELECT * FROM photos_representation WHERE asset_id <> 'a0';", at: f.db)
            await f.photos.resetReads(); await f.model.reset()
            let edit = descriptor(f.photos.context, asset: "a0", revision: "r2")
            let delta = await f.photos.changeFacts([edit] + Array(original.dropFirst()), changed: ["a0"])
            await f.coordinator.libraryChanged(.incremental(delta))
            try await assertNil(try await f.coordinator.readyToken())
            await f.coordinator.processDueWork(now: now)
            let token = try await f.coordinator.readyToken()
            XCTAssertEqual(token?.photosGeneration, delta.toGeneration)
            await assertEqual(await f.photos.requestedLimits, [])
            await assertEqual(await f.photos.deltaRequests, [["a0"]])
            await assertEqual(await f.model.count, 1)
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM (SELECT * FROM untouched EXCEPT SELECT * FROM photos_representation)", at: f.db), 0)
            writes.append(try ["photos_representation", "fingerprint_task"].map { try engineSQLInteger("SELECT COUNT(*) FROM p11_writes WHERE table_name='\($0)'", at: f.db) })
            let added = descriptor(f.photos.context, asset: "new")
            let add = await f.photos.changeFacts([edit, added] + Array(original.dropFirst()), changed: ["new"])
            await f.coordinator.libraryChanged(.incremental(add)); await f.coordinator.processDueWork(now: now)
            let remove = await f.photos.changeFacts(original, deleted: ["new"], changed: ["a0"])
            await f.coordinator.libraryChanged(.incremental(remove)); await f.coordinator.processDueWork(now: now)
            let publication = try await f.store.indexPublication(); XCTAssertEqual(publication?.representationCount, size)
            await assertEqual(await f.photos.requestedLimits, [])
        }
        XCTAssertEqual(writes, [[2, 2], [2, 2]])
    }

    func testDeltaExclusionsEditRevertAndEmptyGeneration() async throws {
        let f = try fixture(), id = "asset"
        let original = descriptor(f.photos.context)
        await f.photos.set([original]); try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await f.photos.resetReads(); await f.model.reset()
        let edited = descriptor(f.photos.context, kind: .current, revision: "edit")
        let edit = await f.photos.changeFacts([original, edited], changed: [id])
        await f.coordinator.libraryChanged(.incremental(edit)); await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.photos.readKinds, [.current])
        let reverted = descriptor(f.photos.context, kind: .current, equivalent: true)
        let revert = await f.photos.changeFacts([original, reverted], changed: [id])
        await f.coordinator.libraryChanged(.incremental(revert)); await f.coordinator.processDueWork(now: now)
        let one = try await f.store.indexPublication(); XCTAssertEqual(one?.representationCount, 1)
        let exclude = await f.photos.changeFacts([], exclusions: [.init(descriptor: original, reason: .rawResource)], changed: [id])
        await f.coordinator.libraryChanged(.incremental(exclude)); await f.coordinator.processDueWork(now: now)
        let excluded = await f.coordinator.progress(); XCTAssertEqual(excluded.excludedAssets, 1); XCTAssertEqual(excluded.totalRepresentations, 0)
        let include = await f.photos.changeFacts([original], changed: [id])
        await f.coordinator.libraryChanged(.incremental(include)); await f.coordinator.processDueWork(now: now)
        let included = await f.coordinator.progress(); XCTAssertEqual(included.excludedAssets, 0); XCTAssertEqual(included.readyRepresentations, 1)
        let empty = await f.photos.changeFacts([original])
        await f.coordinator.libraryChanged(.incremental(empty)); await f.coordinator.processDueWork(now: now)
        let token = try await f.coordinator.readyToken(); XCTAssertEqual(token?.photosGeneration, empty.toGeneration)
        await assertEqual(await f.photos.requestedLimits, [])
    }

    func testDeltaCoalescingLastChangeWinsAndGapsFallbackToFull() async throws {
        let f = try fixture()
        let original = descriptor(f.photos.context)
        await f.photos.set([original]); try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await f.photos.resetReads()
        let deleted = await f.photos.changeFacts([], deleted: [original.key.assetID])
        await f.coordinator.libraryChanged(.incremental(deleted))
        let restored = await f.photos.changeFacts([original], changed: [original.key.assetID])
        await f.coordinator.libraryChanged(.incremental(restored)); await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.photos.deltaRequests, [[original.key.assetID]])
        let removed = await f.photos.changeFacts([], deleted: [original.key.assetID])
        await f.coordinator.libraryChanged(.incremental(removed)); await f.coordinator.processDueWork(now: now)
        let empty = try await f.store.indexPublication(); XCTAssertEqual(empty?.representationCount, 0)
        await f.photos.set([original]) // a missed event
        let gap = await f.photos.changeFacts([original], changed: [original.key.assetID])
        await f.coordinator.libraryChanged(.incremental(gap)); await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.photos.requestedLimits.isEmpty, false)
    }

    func testMissingIDDeltaFetchDoesNotDeleteAndRecoversThroughCompleteInventory() async throws {
        let f = try fixture()
        let d = descriptor(f.photos.context)
        await f.photos.set([d]); try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await f.photos.setMissingDelta(true); await f.photos.resetReads()
        let delta = await f.photos.changeFacts([d], changed: [d.key.assetID])
        await f.coordinator.libraryChanged(.incremental(delta)); await f.coordinator.processDueWork(now: now)
        let publication = try await f.store.indexPublication(); XCTAssertEqual(publication?.representationCount, 1)
        await assertEqual(await f.photos.requestedLimits.isEmpty, false)
    }

    func testUnaffectedInFlightTaskCompletesOnceAcrossDelta() async throws {
        let f = try fixture(), gate = CoordinatorGate()
        let a = descriptor(f.photos.context, asset: "a"), b = descriptor(f.photos.context, asset: "b")
        await f.photos.set([a, b]); try await f.coordinator.reconcile(); await f.model.setGate(gate)
        let work = Task { await f.coordinator.processDueWork(now: now) }
        await gate.waitUntilEntered()
        let delta = await f.photos.changeFacts([a, descriptor(f.photos.context, asset: "b", revision: "new")], changed: ["b"])
        await f.coordinator.libraryChanged(.incremental(delta))
        await gate.release(); await work.value
        await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.model.count, 2)
        try await assertNotNil(try await f.coordinator.readyToken())
    }

    func testDeletedThenReinsertedSameRevisionRejectsTheReplacedInFlightTask() async throws {
        let f = try fixture(), gate = CoordinatorGate()
        let a = descriptor(f.photos.context)
        await f.photos.set([a]); try await f.coordinator.reconcile(); await f.model.setGate(gate)
        let work = Task { await f.coordinator.processDueWork(now: now) }
        await gate.waitUntilEntered()
        let removed = await f.photos.changeFacts([], deleted: [a.key.assetID])
        await f.coordinator.libraryChanged(.incremental(removed))
        let restored = await f.photos.changeFacts([a], changed: [a.key.assetID])
        await f.coordinator.libraryChanged(.incremental(restored))
        await gate.release(); await work.value
        await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.model.count, 2)
        try await assertNotNil(try await f.coordinator.readyToken())
    }

    private func installWriteAudit(at db: URL) throws {
        try injectEngineSQL("CREATE TABLE p11_writes (table_name TEXT);" + ["photos_representation", "fingerprint_task", "photos_index_exclusion"].flatMap { table in
            ["INSERT", "UPDATE", "DELETE"].map { operation in
                "CREATE TRIGGER p11_\(table)_\(operation) AFTER \(operation) ON \(table) BEGIN INSERT INTO p11_writes VALUES ('\(table)'); END;"
            }
        }.joined(), at: db)
    }

    private struct Fixture {
        let db: URL; let store: SyncStore; let photos: CoordinatorPhotos; let model: CoordinatorModel
        let configuration: DedupConfiguration; let coordinator: PhotosIndexCoordinator
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configuration = try JSONDecoder().decode(DedupConfiguration.self, from: Data(contentsOf: repository.appendingPathComponent("docs/research/advanced-dedup/integration-profile.json")))
        let db = root.appendingPathComponent("test.sqlite"), store = try SyncStore(url: db)
        let photos = CoordinatorPhotos(limits: configuration.resources), model = CoordinatorModel(version: configuration.fingerprint.version)
        return Fixture(db: db, store: store, photos: photos, model: model, configuration: configuration,
            coordinator: PhotosIndexCoordinator(store: store, photos: photos, fingerprinter: model,
                configuration: configuration))
    }
    private func descriptor(_ context: LibraryContext, asset: String = "asset", kind: RepresentationKind = .original,
                            revision: String = "r1", equivalent: Bool = false) -> RepresentationDescriptor {
        .init(key: .init(assetID: asset, kind: kind), context: context, revision: revision,
              size: try! PixelSize(width: 8, height: 8), equivalentToOriginal: equivalent, revisionIsReliable: true)
    }
    private func assertEqual<T: Equatable>(_ value: @autoclosure () async -> T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) async {
        let result = await value(); XCTAssertEqual(result, expected, file: file, line: line)
    }
    private func assertNotNil<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await value(); XCTAssertNotNil(result, file: file, line: line)
    }
    private func assertNil<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await value(); XCTAssertNil(result, file: file, line: line)
    }
}

private actor CoordinatorGate {
    private var entered = false, open = false
    private var waiters: [CheckedContinuation<Void, Never>] = [], blocked: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; waiters.forEach { $0.resume() }; waiters.removeAll(); if !open { await withCheckedContinuation { blocked = $0 } } }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; blocked?.resume(); blocked = nil }
}

private actor CoordinatorModel: ImageFingerprinting {
    private let version: String
    private(set) var count = 0
    private var gate: CoordinatorGate?
    private var unavailable = false
    func setUnavailable(_ value: Bool) { unavailable = value }
    init(version: String) { self.version = version }
    func setGate(_ gate: CoordinatorGate) { self.gate = gate }
    func reset() { count = 0 }
    func fingerprint(image: CGImage, orientation: CGImagePropertyOrientation) async throws -> Fingerprint {
        if unavailable { throw ModelExecutionUnavailable(detail: "test index") }
        count += 1; if let gate { self.gate = nil; await gate.hold() }
        try Task.checkCancellation()
        return try Fingerprint(version: version, values: [1] + Array(repeating: 0, count: 1023))
    }
}

private actor CoordinatorPhotos: PhotosIndexGateway {
    nonisolated let context = LibraryContext(id: UUID(), epoch: 1)
    nonisolated let budget: ImageWorkBudget
    nonisolated let channel = PhotosIndexChangeChannel(capacity: 128)
    private var pages: [RepresentationPage] = []
    private var readFailures: [String: PhotosRepresentationError] = [:]
    private var replacementContext: LibraryContext?
    func setReadFailures(_ failures: [String: PhotosRepresentationError]) { readFailures = failures }
    func replaceContext(_ context: LibraryContext, descriptors: [RepresentationDescriptor]) {
        replacementContext = context; generation += 1
        pages = [.init(context: context, generation: generation, descriptors: descriptors, nextOffset: nil)]
    }
    private var generation = 0, failedAsset: String?, conservative = false, resumeSuccess = true, changeOnAck = false
    private(set) var readCount = 0, resumeCount = 0, acknowledgementCount = 0
    private(set) var readKinds: [RepresentationKind] = [], requestedLimits: [Int] = []
    private var resumeThrows = false
    private var readGate: CoordinatorGate?
    func gateNextRead(_ gate: CoordinatorGate) { readGate = gate }
    private var snapshotCount = 0, snapshotGateAt: Int?, snapshotGate: CoordinatorGate?
    private(set) var maxImagesObserved = 0
    private var checkpointCaptured = false
    private(set) var checkpointBeforeSnapshot = true
    init(limits: ResourceLimits) { budget = ImageWorkBudget(limits: limits) }
    func set(_ descriptors: [RepresentationDescriptor]) {
        generation += 1
        pages = [.init(context: context, generation: generation, descriptors: descriptors, nextOffset: nil)]
    }
    func setPages(_ pages: [RepresentationPage]) { self.pages = pages; generation = pages.first?.generation ?? generation }
    func resetReads() { readCount = 0; readKinds = []; requestedLimits = [] }
    func fail(_ asset: String?) { failedAsset = asset }
    func setConservative(_ value: Bool) { conservative = value }
    func throwNextResume() { resumeThrows = true }
    func setResumeSuccess(_ value: Bool) { resumeSuccess = value }
    func changeOnAcknowledgement(_ value: Bool) { changeOnAck = value }
    nonisolated func changes() -> AsyncStream<PhotosIndexChange> { channel.stream() }
    func gateSnapshot(_ number: Int, using gate: CoordinatorGate) { snapshotCount = 0; snapshotGateAt = number; snapshotGate = gate }
    func candidateSnapshot() async throws -> PhotosCandidateSnapshot {
        snapshotCount += 1
        let captured = generation
        if snapshotCount == snapshotGateAt, let gate = snapshotGate { snapshotGateAt = nil; snapshotGate = nil; await gate.hold() }
        guard captured == generation else { throw PhotoKitGatewayError.libraryChanged }
        checkpointBeforeSnapshot = checkpointBeforeSnapshot && checkpointCaptured
        return .init(generation: generation, candidates: [])
    }
    func contextCheckpoint() async throws -> LibraryResumeCheckpoint? {
        checkpointCaptured = true
        return .init(context: replacementContext ?? context, archivedChangeToken: Data([UInt8(generation)]), photosGeneration: generation)
    }
    func resumeContext(_ checkpoint: LibraryResumeCheckpoint) async throws -> Bool {
        resumeCount += 1
        if resumeThrows { resumeThrows = false; throw PhotoKitGatewayError.libraryUnavailable }
        if !resumeSuccess {
            pages = pages.map { .init(context: $0.context, generation: $0.generation, descriptors: $0.descriptors,
                nextOffset: $0.nextOffset, exclusions: $0.exclusions, invalidateAllCachedRepresentations: true) }
        }
        return resumeSuccess
    }
    func representationCatalog(offset: Int, limit: Int, expectedGeneration: Int) async throws -> RepresentationPage {
        guard expectedGeneration == generation, offset < pages.count else { throw PhotoKitGatewayError.libraryChanged }
        requestedLimits.append(limit); return pages[offset]
    }
    private(set) var deltaRequests: [[String]] = []
    private var missingDelta = false
    func setMissingDelta(_ value: Bool) { missingDelta = value }
    func changeFacts(_ descriptors: [RepresentationDescriptor], exclusions: [RepresentationCatalogExclusion] = [],
                     deleted: [String] = [], changed: [String] = []) -> PhotosIndexDelta {
        let from = generation; generation += 1
        pages = [.init(context: context, generation: generation, descriptors: descriptors, nextOffset: nil, exclusions: exclusions)]
        return .init(context: context, fromGeneration: from, toGeneration: generation, changedAssetIDs: changed, deletedAssetIDs: deleted)
    }
    func representationDelta(_ delta: PhotosIndexDelta) async throws -> RepresentationPage {
        deltaRequests.append(delta.changedAssetIDs)
        guard delta.toGeneration == generation else { throw PhotoKitGatewayError.libraryChanged }
        let ids = Set(delta.changedAssetIDs)
        return .init(context: context, generation: generation,
            descriptors: missingDelta ? [] : pages.flatMap(\.descriptors).filter { ids.contains($0.key.assetID) }, nextOffset: nil,
            exclusions: pages.flatMap(\.exclusions).filter { ids.contains($0.descriptor.key.assetID) })
    }
    func readRepresentation(_ descriptor: RepresentationDescriptor) async throws -> LoadedRepresentation {
        readCount += 1; readKinds.append(descriptor.key.kind)
        if let error = readFailures[descriptor.key.assetID] { throw error }
        if failedAsset == descriptor.key.assetID { throw PhotoKitGatewayError.libraryUnavailable }
        let lease = try await budget.acquire(bytes: 256)
        let occupied = await budget.snapshot(); maxImagesObserved = max(maxImagesObserved, occupied.images)
        let image = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        if let gate = readGate { readGate = nil; await gate.hold() }
        return .init(image: image, orientation: .up, descriptor: descriptor, lease: lease,
            eligibility: conservative ? .conservative(.unverifiedContainer) : .safeSingleFrame)
    }
    func acknowledgeReconciliation(expectedGeneration: Int) async throws {
        acknowledgementCount += 1
        if changeOnAck { generation += 1 }
        guard expectedGeneration == generation else { throw PhotoKitGatewayError.libraryChanged }
        channel.reconciled()
    }
    func create(fileURL: URL, kind: MediaKind, expectedGeneration: Int, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String { throw PhotoKitGatewayError.libraryUnavailable }
    func reconcile(placeholder: String?) async throws -> ImportEvidence { .unknown }
}

private final class CoordinatorPhysicalSession: ModelPredictionSession, @unchecked Sendable {
    func predict(_ input: MLMultiArray) throws -> [Float] { [1] + Array(repeating: 0, count: 1023) }
}
private final class CoordinatorPhysicalCount: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
