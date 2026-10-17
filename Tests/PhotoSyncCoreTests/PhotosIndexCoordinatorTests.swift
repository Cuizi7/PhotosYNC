import XCTest
import CoreML
import CoreGraphics
import ImageIO
import Photos
@testable import PhotoSyncCore

final class PhotosIndexCoordinatorTests: XCTestCase {
    func testCompletedEmptyInventoryThenSameSuccessfulDateReturnDoesNoImageWork() async throws {
        let f = try fixture(), d = descriptor(f.photos.context)
        await f.photos.set([d]); try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await f.photos.set([]); try await f.coordinator.reconcile()
        let removed = await f.coordinator.progress(); XCTAssertEqual(removed.totalRepresentations, 0)
        try await assertNotNil(try await f.coordinator.readyToken())
        await f.photos.resetReads(); await f.model.reset()
        await f.photos.set([d]); try await f.coordinator.reconcile()
        let returned = await f.coordinator.progress(); XCTAssertEqual(returned.readyRepresentations, 1)
        let tasks = try await f.store.nextRepresentationTasks(now: now, limit: 1); XCTAssertTrue(tasks.isEmpty)
        await f.coordinator.processDueWork(now: now)
        try await assertNotNil(try await f.coordinator.readyToken())
        await assertEqual(await f.photos.readCount, 0); await assertEqual(await f.model.count, 0)
    }

    func testCancellationDuringPreReadSnapshotStartsNoOwnedWorkAndFreshCallerCanResume() async throws {
        let f = try fixture(); await f.photos.set([descriptor(f.photos.context)])
        try await f.coordinator.reconcile()
        try injectEngineSQL("CREATE TABLE before_cancel AS SELECT * FROM fingerprint_task", at: f.db)
        let gate = CoordinatorGate(); await f.photos.gateSnapshot(1, using: gate)
        let work = Task { await f.coordinator.processDueWork(now: now) }
        await gate.waitUntilEntered(); work.cancel(); await gate.release(); await work.value
        await assertEqual(await f.photos.readCount, 0); await assertEqual(await f.model.count, 0)
        let progress = await f.coordinator.progress(); XCTAssertEqual(progress.readyRepresentations, 0)
        let pending = try await f.store.nextRepresentationTasks(now: now, limit: 1); XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM (SELECT * FROM before_cancel EXCEPT SELECT * FROM fingerprint_task)", at: f.db), 0)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM (SELECT * FROM fingerprint_task EXCEPT SELECT * FROM before_cancel)", at: f.db), 0)
        let resources = await f.photos.budget.snapshot(); XCTAssertEqual(resources.images, 0); XCTAssertEqual(resources.bytes, 0)
        await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.photos.readCount, 1); await assertEqual(await f.model.count, 1)
        try await assertNotNil(try await f.coordinator.readyToken())
    }

    func testSameDateContentEventsNeverDemoteSuccessOrRestartFailedRetry() async throws {
        for succeeded in [true, false] {
            let f = try fixture()
            let d = descriptor(f.photos.context, date: Date(timeIntervalSinceReferenceDate: 100.25))
            await f.photos.set([d])
            if !succeeded { await f.photos.fail("asset") }
            try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
            try injectEngineSQL("CREATE TABLE before_retry AS SELECT retry_count,next_retry_at,last_error FROM fingerprint_task; CREATE TRIGGER forbid_event_demotion BEFORE UPDATE OF state ON photos_representation WHEN OLD.state='ready' AND NEW.state='pending' BEGIN SELECT RAISE(FAIL, 'same-date event demoted success'); END;", at: f.db)
            await f.model.reset(); await f.photos.resetReads()
            await f.photos.setPages([.init(context: f.photos.context, generation: 2, descriptors: [d], nextOffset: nil, invalidatedAssetIDs: ["asset"])])
            try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM (SELECT * FROM before_retry EXCEPT SELECT retry_count,next_retry_at,last_error FROM fingerprint_task)", at: f.db), 0)
            await assertEqual(await f.photos.readCount, 0)
            await assertEqual(await f.model.count, 0)
            let token = try await f.coordinator.readyToken()
            XCTAssertEqual(token != nil, succeeded)
        }
    }

    func testCancellationOrPauseAtPublicationAwaitsCannotPublishOrConfirmAndResumeReusesDates() async throws {
        for pause in [false, true] {
            // 4: final inventory snapshot; 5: before publication persistence;
            // 6: after gateway acknowledgment; nil: acknowledgment itself awaits.
            for snapshotNumber in [4, 5, 6, nil] as [Int?] {
                let f = try fixture(), gate = CoordinatorGate()
                await f.photos.set([descriptor(f.photos.context)])
                try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
                await f.photos.resetReads(); await f.model.reset()
                let acknowledgments = await f.photos.acknowledgementCount
                let receipt = await f.coordinator.libraryChanged(.fullReconcileRequired)
                if let snapshotNumber { await f.photos.gateSnapshot(snapshotNumber, using: gate) }
                else { await f.photos.gateNextAcknowledgment(gate) }
                let pass = Task { try await f.coordinator.reconcile() }
                await gate.waitUntilEntered()
                if pause { await f.coordinator.setPaused(true) } else { pass.cancel() }
                await gate.release()
                do { try await pass.value; XCTFail("interrupted publication cannot finish") }
                catch { XCTAssertTrue(error is CancellationError) }
                let covered = await f.coordinator.reconciliationCovers(change: receipt)
                XCTAssertFalse(covered)
                try await assertNil(try await f.coordinator.readyToken())
                // A call already issued before interruption may finish, but an
                // interrupted pre-publication snapshot must not issue an ack.
                let expectedAcknowledgments = acknowledgments + (snapshotNumber == 6 || snapshotNumber == nil ? 1 : 0)
                await assertEqual(await f.photos.acknowledgementCount, expectedAcknowledgments)
                XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM dedup_index_state WHERE published_generation IS NULL", at: f.db), 1)
                XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE state='ready' AND vector IS NOT NULL AND successful_modification_date=100", at: f.db), 1)
                await f.coordinator.setPaused(false)
                try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
                try await assertNotNil(try await f.coordinator.readyToken())
                let resumed = await f.coordinator.reconciliationCovers(change: receipt)
                XCTAssertTrue(resumed)
                await assertEqual(await f.photos.readCount, 0); await assertEqual(await f.model.count, 0)
            }
        }
    }

    func testMergedDeleteReinsertKeepsSameDateSuccessWithoutImageWork() async throws {
        let f = try fixture(), d = descriptor(f.photos.context)
        await f.photos.set([d]); try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await f.photos.resetReads(); await f.model.reset()
        let removed = await f.photos.changeFacts([], deleted: [d.key.assetID])
        await f.coordinator.libraryChanged(.incremental(removed))
        let restored = await f.photos.changeFacts([d], changed: [d.key.assetID])
        await f.coordinator.libraryChanged(.incremental(restored)); await f.coordinator.processDueWork(now: now)
        try await assertNotNil(try await f.coordinator.readyToken())
        await assertEqual(await f.photos.readCount, 0); await assertEqual(await f.model.count, 0)
    }

    func testMetadataRevisionChangeReusesSuccessfulModelInputBeforePrediction() async throws {
        let f = try fixture(), calls = CoordinatorPhysicalCount()
        let model = CoreMLFingerprinter(configuration: f.configuration.fingerprint, predict: { _ in
            calls.increment(); return [1] + Array(repeating: 0, count: 1023)
        })
        let coordinator = PhotosIndexCoordinator(store: f.store, photos: f.photos, fingerprinter: model,
            configuration: f.configuration)
        await f.photos.set([descriptor(f.photos.context, revision: "first")])
        try await coordinator.reconcile(); await coordinator.processDueWork(now: now)
        XCTAssertEqual(calls.value, 1)
        await f.photos.set([descriptor(f.photos.context, revision: "new-metadata-same-pixels", date: Date(timeIntervalSinceReferenceDate: 200))])
        try await coordinator.reconcile(); await coordinator.processDueWork(now: now)
        XCTAssertEqual(calls.value, 1, "A matching accepted model input must bypass physical prediction")
        await assertEqual(await f.photos.readCount, 2)
        try await assertNotNil(try await coordinator.readyToken())
        await f.photos.setImageRed(1)
        await f.photos.set([descriptor(f.photos.context, revision: "new-pixels", date: Date(timeIntervalSinceReferenceDate: 300))])
        try await coordinator.reconcile(); await coordinator.processDueWork(now: now)
        XCTAssertEqual(calls.value, 2, "A changed model input must still be predicted")
        await f.photos.setImageRed(0.5)
        await f.photos.setPages([.init(context: f.photos.context, generation: 4,
            descriptors: [descriptor(f.photos.context, revision: "new-pixels", date: Date(timeIntervalSinceReferenceDate: 400))], nextOffset: nil, invalidatedAssetIDs: ["asset"])])
        try await coordinator.reconcile(); await coordinator.processDueWork(now: now)
        XCTAssertEqual(calls.value, 3, "A changed date verifies actual input even when the read revision is equal")
    }

    func testSuccessfulInventoryConfirmsRequestWhileVectorsRemainPending() async throws {
        let f = try fixture()
        await f.photos.set([descriptor(f.photos.context)])
        let receipt = await f.coordinator.libraryChanged(.fullReconcileRequired)
        try await f.coordinator.reconcile()
        let covered = await f.coordinator.reconciliationCovers(change: receipt)
        XCTAssertTrue(covered)
        let progress = await f.coordinator.progress()
        XCTAssertEqual(progress.readyRepresentations, 0)
        XCTAssertEqual(progress.totalRepresentations, 1)
        try await assertNil(try await f.coordinator.readyToken())
    }

    func testPauseDuringFinalSnapshotDoesNotConfirmFullRequest() async throws {
        let f = try fixture(), gate = CoordinatorGate()
        await f.photos.set([])
        let receipt = await f.coordinator.libraryChanged(.fullReconcileRequired)
        await f.photos.gateSnapshot(4, using: gate)
        let pass = Task { try await f.coordinator.reconcile() }
        await gate.waitUntilEntered(); await f.coordinator.setPaused(true)
        await gate.release(); _ = await pass.result
        let covered = await f.coordinator.reconciliationCovers(change: receipt)
        XCTAssertFalse(covered, "A pause in the successful path's final await must not confirm inventory")
        await f.coordinator.setPaused(false); try await f.coordinator.reconcile()
        let resumed = await f.coordinator.reconciliationCovers(change: receipt)
        XCTAssertTrue(resumed)
    }

    func testPendingContentCauseSurvivesLaterNeutralObservationBeforeMergedDelta() async throws {
        let rows = CoordinatorDiagnostics(), diagnostics = IndexDiagnostics(sink: { rows.record($0) })
        let f = try fixture(indexDiagnostics: diagnostics), d = descriptor(f.photos.context)
        await f.photos.set([d]); try await f.coordinator.reconcile()
        await f.coordinator.processDueWork(now: now)
        let content = await f.photos.changeFacts([descriptor(f.photos.context, date: Date(timeIntervalSinceReferenceDate: 200))], changed: ["asset"])
        diagnostics.recordCause(context: f.photos.context, assetID: "asset", source: "live", generation: content.toGeneration,
            facts: ["assetContentChanged": "true", "visibleInputFields": "none", "metadataFields": "none"])
        await f.coordinator.libraryChanged(.incremental(content))
        let neutral = await f.photos.changeFacts([descriptor(f.photos.context, date: Date(timeIntervalSinceReferenceDate: 200))], changed: ["asset"])
        diagnostics.recordCause(context: f.photos.context, assetID: "asset", source: "live", generation: neutral.toGeneration,
            facts: ["assetContentChanged": "false", "visibleInputFields": "none", "metadataFields": "isFavorite"], inputObligation: false)
        await f.photos.invalidateDelta(["asset"])
        await f.coordinator.libraryChanged(.incremental(neutral))
        await f.coordinator.processDueWork(now: now)
        let accepted = try XCTUnwrap(rows.rows.last { $0["event"] == "accepted" })
        XCTAssertEqual(accepted["causeGeneration"], String(content.toGeneration))
        XCTAssertEqual(accepted["cause.assetContentChanged"], "true")
        XCTAssertNotNil(accepted["invalidationOperation"])
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE state='ready'", at: f.db), 1)
    }

    func testUnknownFullInvalidationDoesNotReuseOldSpecificCause() async throws {
        let rows = CoordinatorDiagnostics(), diagnostics = IndexDiagnostics(sink: { rows.record($0) })
        let f = try fixture(indexDiagnostics: diagnostics), d = descriptor(f.photos.context)
        await f.photos.set([d]); try await f.coordinator.reconcile()
        await f.coordinator.processDueWork(now: now)
        diagnostics.recordCause(context: f.photos.context, assetID: "asset", source: "live", generation: 1,
            facts: ["assetContentChanged": "true", "visibleInputFields": "none", "metadataFields": "none"])
        await f.photos.setPages([.init(context: f.photos.context, generation: 2, descriptors: [descriptor(f.photos.context, date: Date(timeIntervalSinceReferenceDate: 200))], nextOffset: nil,
            invalidateAllCachedRepresentations: true)])
        await f.coordinator.libraryChanged(.fullReconcileRequired)
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        let accepted = try XCTUnwrap(rows.rows.last { $0["event"] == "accepted" })
        XCTAssertEqual(accepted["causeSource"], "unknown")
        XCTAssertEqual(accepted["cause.content"], "unknown")
        XCTAssertEqual(accepted["invalidationScope"], "all")
        XCTAssertNotEqual(accepted["cause.assetContentChanged"], "true")
    }

    func testFailedAndCancelledPredictionKeepActualPartialTimingsWithoutCompletingBaseline() async throws {
        for cancelled in [false, true] {
            let rows = CoordinatorDiagnostics(), diagnostics = IndexDiagnostics(sink: { rows.record($0) })
            let f = try fixture(), count = CoordinatorPhysicalCount()
            let model = CoreMLFingerprinter(configuration: f.configuration.fingerprint, predict: { _ in
                count.increment()
                if cancelled { throw CancellationError() }
                throw AdvancedDedupError.invalidModelOutput
            })
            let coordinator = PhotosIndexCoordinator(store: f.store, photos: f.photos, fingerprinter: model,
                configuration: f.configuration, indexDiagnostics: diagnostics)
            await f.photos.set([descriptor(f.photos.context)])
            try await coordinator.reconcile(); await coordinator.processDueWork(now: now)
            let summary = try XCTUnwrap(rows.rows.last { $0["phase"] == "index-diagnostic-summary" && $0["timing.fingerprint-total-wall.count"] != nil })
            for stage in ["preprocessing-wall", "input-digest-wall", "model-queue-wall", "prediction-wall"] {
                XCTAssertEqual(summary["timing." + stage + ".count"], "1", stage)
                XCTAssertGreaterThanOrEqual(Double(summary["timing." + stage + ".sumMS"] ?? "-1")!, 0, stage)
            }
            XCTAssertNil(summary["comparison.same_input"])
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE input_digest IS NOT NULL", at: f.db), 0)
            XCTAssertEqual(try engineSQLInteger("SELECT retry_count FROM fingerprint_task", at: f.db), cancelled ? 0 : 1)
            XCTAssertEqual(count.value, 1)
            await assertEqual(await f.photos.readCount, 1)
        }
    }

    func testActualPreparedInputsReachAcceptedComparisonsWithoutExtraReads() async throws {
        let rows = CoordinatorDiagnostics(), diagnostic = IndexDiagnostics(sink: { rows.record($0) })
        let f = try fixture(), count = CoordinatorPhysicalCount()
        let model = CoreMLFingerprinter(configuration: f.configuration.fingerprint, predict: { _ in
            count.increment(); return [1] + Array(repeating: 0, count: 1023)
        })
        let coordinator = PhotosIndexCoordinator(store: f.store, photos: f.photos, fingerprinter: model,
            configuration: f.configuration, indexDiagnostics: diagnostic)
        await f.photos.set([descriptor(f.photos.context, revision: "first")])
        try await coordinator.reconcile(); await coordinator.processDueWork(now: now)
        XCTAssertEqual(rows.rows.last { $0["event"] == "accepted" }?["comparison"], "missing_baseline")
        diagnostic.recordCause(context: f.photos.context, assetID: "asset", source: "history", generation: 2,
            facts: ["category": "updated", "content": "unknown"])
        await f.photos.setPages([.init(context: f.photos.context, generation: 2,
            descriptors: [descriptor(f.photos.context, revision: "metadata-only", date: Date(timeIntervalSinceReferenceDate: 200))], nextOffset: nil, invalidatedAssetIDs: ["asset"])])
        await coordinator.libraryChanged(.fullReconcileRequired)
        try await coordinator.reconcile(); await coordinator.processDueWork(now: now)
        let same = try XCTUnwrap(rows.rows.last { $0["event"] == "accepted" })
        XCTAssertEqual(same["comparison"], "same_input")
        XCTAssertEqual(same["causeSource"], "history"); XCTAssertEqual(same["cause.content"], "unknown")
        let catalog = rows.rows.last { $0["phase"] == "index-catalog-sample" && $0["causeHandle"] == same["causeHandle"] }
        XCTAssertNotNil(catalog)
        await f.photos.setImageRed(1)
        await f.photos.set([descriptor(f.photos.context, revision: "edited-input", date: Date(timeIntervalSinceReferenceDate: 300))])
        await coordinator.libraryChanged(.fullReconcileRequired)
        try await coordinator.reconcile(); await coordinator.processDueWork(now: now)
        XCTAssertEqual(rows.rows.last { $0["event"] == "accepted" }?["comparison"], "different_input")
        // A changed preprocessing contract is incomparable even with an actual new tensor.
        let old = f.configuration.fingerprint
        let changed = try FingerprintConfiguration(modelSHA256: old.modelSHA256, inputSide: old.inputSide,
            resizeMode: old.resizeMode, colorSpace: old.colorSpace, mean: [0.4, 0.4, 0.4], std: old.std)
        let configuration = try DedupConfiguration(fingerprint: changed, policyVersion: DedupConfiguration.computePolicyVersion(
            fingerprintVersion: changed.version, threshold: f.configuration.threshold, backend: f.configuration.backend),
            threshold: f.configuration.threshold, backend: f.configuration.backend, resources: f.configuration.resources,
            evidenceCandidateLimit: f.configuration.evidenceCandidateLimit, acceptanceID: f.configuration.acceptanceID)
        let nextModel = CoreMLFingerprinter(configuration: changed, predict: { _ in
            count.increment(); return [1] + Array(repeating: 0, count: 1023)
        })
        let next = PhotosIndexCoordinator(store: f.store, photos: f.photos, fingerprinter: nextModel,
            configuration: configuration, indexDiagnostics: diagnostic)
        try await next.reconcile(); await next.processDueWork(now: now)
        XCTAssertEqual(rows.rows.last { $0["event"] == "accepted" }?["comparison"], "incomparable")
        await assertEqual(await f.photos.readCount, 4)
        XCTAssertEqual(count.value, 3, "Identical prepared input reuses its accepted vector")
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE state='ready' AND length(input_digest)=32 AND length(input_digest_contract)>0", at: f.db), 1)
        let summaries = rows.rows.filter { $0["phase"] == "index-diagnostic-summary" }
        for outcome in ["missing_baseline", "same_input", "different_input", "incomparable"] {
            XCTAssertEqual(summaries.reduce(0) { $0 + (Int($1["comparison." + outcome] ?? "0") ?? 0) }, 1)
        }
        XCTAssertTrue(summaries.contains { Int($0["timing.input-digest-wall.count"] ?? "0") == 1 })
    }

    func testComparisonSummaryCountsAllRowsBeyondSampleAndDetailCapsWithoutSink() throws {
        let diagnostics = IndexDiagnostics(sink: { _ in })
        let operation = diagnostics.operation("work")
        let context = LibraryContext(id: UUID(), epoch: 1)
        operation.bindScope(context: context, photosGeneration: 3)
        for n in 0..<1000 {
            let d = descriptor(context, asset: "private-asset-\(n)")
            let task = RepresentationTask(descriptor: d, retryCount: 0, nextRetryAt: nil,
                fingerprintVersion: "v", indexGeneration: 1)
            operation.recordComparison(.sameInput, task: task)
        }
        let summary = operation.finish()
        XCTAssertEqual(summary["comparison.same_input"], "1000")
        XCTAssertEqual(summary["contextEpoch"], "1")
        XCTAssertEqual(summary["photosGeneration"], "3")
        XCTAssertEqual(summary["comparison.different_input"], "0")
        XCTAssertEqual(summary["comparison.missing_baseline"], "0")
        XCTAssertEqual(summary["comparison.incomparable"], "0")
        XCTAssertLessThanOrEqual(Int(summary["detailed"] ?? "1000")!, 64)
    }

    func testCauseChainUsesContextAndCapturesAttemptBeforeLateEvent() throws {
        let log = CoordinatorDiagnostics(), diagnostics = IndexDiagnostics(sink: { log.record($0) })
        let context = LibraryContext(id: UUID(), epoch: 3)
        let d = descriptor(context, asset: "PRIVATE-ASSET-SENTINEL")
        diagnostics.recordCause(context: context, assetID: d.key.assetID, source: "history", generation: 2,
            facts: ["content": "unknown", "category": "updated"], operation: "history-1")
        let operation = diagnostics.operation("work")
        diagnostics.operation("reconcile").bindInvalidation(d, indexGeneration: 4, photosGeneration: 2)
        let task = RepresentationTask(descriptor: d, retryCount: 0, nextRetryAt: nil,
            fingerprintVersion: "v", indexGeneration: 4)
        operation.record(["phase": "index-task", "event": "attempt"], task: task)
        let attempt = try XCTUnwrap(log.rows.last)
        diagnostics.recordCause(context: context, assetID: d.key.assetID, source: "live", generation: 3,
            facts: ["assetContentChanged": "true", "visibleInputFields": "pixelSize", "metadataFields": "none"])
        operation.recordComparison(.sameInput, task: task)
        let accepted = try XCTUnwrap(log.rows.last)
        XCTAssertEqual(accepted["causeHandle"], attempt["causeHandle"])
        XCTAssertEqual(accepted["causeSource"], "history")
        XCTAssertEqual(accepted["cause.content"], "unknown")
        XCTAssertEqual(accepted["issuanceHandle"], attempt["issuanceHandle"])
        XCTAssertEqual(accepted["contextEpoch"], "3")
        XCTAssertEqual(accepted["comparison"], "same_input")
        let next = diagnostics.operation("work")
        diagnostics.operation("reconcile").bindInvalidation(d, indexGeneration: 5, photosGeneration: 3)
        let nextTask = RepresentationTask(descriptor: d, retryCount: 0, nextRetryAt: nil,
            fingerprintVersion: "v", indexGeneration: 5)
        next.record(["phase": "index-task", "event": "attempt"], task: nextTask)
        XCTAssertEqual(log.rows.last?["causeSource"], "live")
        let other = descriptor(LibraryContext(id: context.id, epoch: 4), asset: d.key.assetID)
        next.record(["phase": "index-catalog-sample"], descriptor: other)
        XCTAssertNil(log.rows.last?["causeHandle"], "Another epoch cannot inherit an earlier cause")
        let data = try JSONSerialization.data(withJSONObject: log.rows)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE-ASSET-SENTINEL"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(context.id.uuidString))
    }

    func testBoundCauseIsMixedWhenHistoryExceedsCapAndCannotReuseAcceptedOrFutureEvents() throws {
        let rows = CoordinatorDiagnostics(), diagnostics = IndexDiagnostics(sink: { rows.record($0) })
        let d = descriptor(LibraryContext(id: UUID(), epoch: 1))
        for generation in 1...5 {
            diagnostics.recordCause(context: d.context, assetID: d.key.assetID, source: "live", generation: generation,
                facts: ["assetContentChanged": "true", "visibleInputFields": "none", "metadataFields": "none"])
        }
        let invalidation = diagnostics.operation("reconcile"), work = diagnostics.operation("work")
        invalidation.bindInvalidation(d, indexGeneration: 1, photosGeneration: 5)
        let task = RepresentationTask(descriptor: d, retryCount: 0, nextRetryAt: nil, fingerprintVersion: "v", indexGeneration: 1)
        work.record(["phase": "index-task", "event": "attempt"], task: task)
        XCTAssertEqual(rows.rows.last?["causeSource"], "mixed")
        XCTAssertEqual(rows.rows.last?["causeOmitted"], "true")
        XCTAssertEqual(rows.rows.last?["causeHandles"]?.split(separator: ",").count, 4)
        work.recordComparison(.sameInput, task: task)
        diagnostics.recordCause(context: d.context, assetID: d.key.assetID, source: "live", generation: 9,
            facts: ["assetContentChanged": "true"])
        invalidation.bindInvalidation(d, indexGeneration: 2, photosGeneration: 8)
        let next = RepresentationTask(descriptor: d, retryCount: 0, nextRetryAt: nil, fingerprintVersion: "v", indexGeneration: 2)
        work.record(["phase": "index-task", "event": "attempt"], task: next)
        XCTAssertEqual(rows.rows.last?["causeSource"], "unknown")
        XCTAssertNil(rows.rows.last?["cause.assetContentChanged"])
    }

    func testTimingsAggregateMonotonicElapsedWithoutPerPageLogs() throws {
        let log = CoordinatorDiagnostics(), clock = DiagnosticClock()
        let diagnostics = IndexDiagnostics(sink: { log.record($0) }, monotonic: { clock.now })
        let operation = diagnostics.operation("reconcile")
        for _ in 0..<1000 {
            operation.measure(stage: "catalog", seconds: 0.002)
            diagnostics.recordTiming(stage: "notification-queue", seconds: 0.003)
        }
        XCTAssertTrue(log.rows.isEmpty)
        let summary = operation.finish()
        XCTAssertEqual(summary["timing.catalog.count"], "1000")
        XCTAssertEqual(Double(summary["timing.catalog.sumMS"] ?? "" )!, 2000, accuracy: 0.001)
        XCTAssertEqual(Double(summary["timing.catalog.maxMS"] ?? "" )!, 2, accuracy: 0.001)
        diagnostics.flushObservations(force: true)
        XCTAssertEqual(log.rows.count, 2)
        XCTAssertEqual(log.rows.last?["timing.notification-queue.count"], "1000")
        XCTAssertEqual(log.rows.last?["measurement"], "monotonic-elapsed-wall")
    }

    func testSliceStopsAtSixteenAttemptsAndContinuesOnNextCall() async throws {
        let f = try fixture()
        await f.photos.set((0..<40).map { descriptor(f.photos.context, asset: String(format: "%03d", $0)) })
        try await f.coordinator.reconcile()
        await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.photos.readCount, 16)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE state='ready'", at: f.db), 16)
        await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.photos.readCount, 32)
        await f.coordinator.processDueWork(now: now)
        try await assertNotNil(try await f.coordinator.readyToken())
    }

    func testFailureDeadlineUsesCapturedFailureWallTimeAfterReadAndModelDelay() async throws {
        for (retryCount, delay) in [5.0, 15.0, 30.0, 60.0].enumerated() {
            for readFailure in [false, true] {
                let clock = DiagnosticClock(), rows = CoordinatorDiagnostics(), gate = CoordinatorGate(), postFailure = CoordinatorGate()
                clock.now = 1000
                let f = try fixture(wallNow: { Date(timeIntervalSince1970: clock.now) }, diagnostics: { rows.record($0) })
                await f.photos.set([descriptor(f.photos.context)])
                try await f.coordinator.reconcile()
                try injectEngineSQL("UPDATE fingerprint_task SET retry_count=\(retryCount)", at: f.db)
                if readFailure { await f.photos.gateNextRead(gate); await f.photos.setAfterRead(.invalidImage) }
                else { await f.model.setGate(gate); await f.model.setAfterGate(.failure(.invalidImage)) }
                await f.photos.gateSnapshot(2, using: postFailure)
                let work = Task { await f.coordinator.processDueWork(now: Date(timeIntervalSince1970: 1000)) }
                await gate.waitUntilEntered(); clock.now = 1040; await gate.release()
                await postFailure.waitUntilEntered(); clock.now = 2000; await postFailure.release(); await work.value
                let tasks = try await f.store.nextRepresentationTasks(now: Date(timeIntervalSince1970: 1040 + delay), limit: 10)
                XCTAssertEqual(tasks.count, 1); XCTAssertEqual(tasks.first?.retryCount, retryCount + 1)
                XCTAssertEqual(tasks.first?.nextRetryAt, Date(timeIntervalSince1970: 1040 + delay))
                XCTAssertTrue(rows.rows.contains { $0["failureAt"] == "1040.0" && $0["deadline"] == String(1040 + delay) })
                let tooEarly = try await f.store.nextRepresentationTasks(now: Date(timeIntervalSince1970: 1039 + delay), limit: 10)
                XCTAssertTrue(tooEarly.isEmpty)
            }
        }
    }

    func testMonotonicAdmissionBudgetLetsOwnedWorkFinishThenRotatesPastFailures() async throws {
        let clock = DiagnosticClock(), gate = CoordinatorGate()
        let f = try fixture(monotonic: { clock.now })
        await f.photos.set((0..<20).map { descriptor(f.photos.context, asset: String(format: "%03d", $0)) })
        try await f.coordinator.reconcile(); await f.model.setGate(gate)
        let work = Task { await f.coordinator.processDueWork(now: now) }
        await gate.waitUntilEntered(); clock.now = 1; await gate.release(); await work.value
        await assertEqual(await f.photos.readCount, 1)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE state='ready'", at: f.db), 1)
        await f.photos.setReadFailures(["001": .iCloudUnavailable("fake")])
        await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.photos.readCount, 17)
        await f.coordinator.processDueWork(now: now.addingTimeInterval(100))
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE state='ready'", at: f.db), 19)
        let failures = try await f.store.nextRepresentationTasks(now: now.addingTimeInterval(100), limit: 10)
        XCTAssertEqual(failures.first?.retryCount, 2, "One issuance must be attempted once per slice, even when failure deadline is before cutoff")
    }

    func testBusyLargeQueueAndTimeoutDrainLeaveSiblingIssuancesUntouched() async throws {
        let log = CoordinatorDiagnostics(), f = try fixture(diagnostics: { log.record($0) })
        await f.photos.setPaged((0..<2000).map { descriptor(f.photos.context, asset: String(format: "%04d", $0)) }, pageSize: 100)
        try await f.coordinator.reconcile(); try installWriteAudit(at: f.db)
        await f.photos.setAdmission(.busy)
        for _ in 0..<100 { await f.coordinator.processDueWork(now: now) }
        await assertEqual(await f.photos.readCount, 0)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM p11_writes", at: f.db), 0)
        XCTAssertEqual(log.rows.filter { $0["phase"] == "index-task" && $0["event"] == "attempt" }.count, 0)
        await f.photos.setAdmission(.available); await f.photos.setReadError(.timedOut)
        await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.photos.readCount, 1)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM fingerprint_task WHERE retry_count=1", at: f.db), 1)
        await f.photos.setAdmission(.draining)
        for _ in 0..<20 { await f.coordinator.processDueWork(now: now.addingTimeInterval(100)) }
        await assertEqual(await f.photos.readCount, 1)
        await f.photos.setAdmission(.stalled); await f.coordinator.processDueWork(now: now)
        let progress = await f.coordinator.progress(); XCTAssertEqual(progress.state, .waiting)
        XCTAssertTrue(progress.issue?.contains("系统") == true)
        await f.coordinator.setPaused(true); await f.photos.setAdmission(.available); await f.photos.setReadError(nil)
        await f.coordinator.processDueWork(now: now); await assertEqual(await f.photos.readCount, 1)
        await f.coordinator.setPaused(false); await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.photos.readCount, 17)
    }

    func testCoordinatorStoreNeutralTransferStreamIsBoundedAndPreservesRetryFacts() async throws {
        let rows = CoordinatorDiagnostics(), clock = DiagnosticClock()
        let diagnostics = IndexDiagnostics(sink: { rows.record($0) }, monotonic: { clock.now })
        let f = try fixture(indexDiagnostics: diagnostics)
        let ids = ["healthy", "retry"]
        var all = ids.map { descriptor(f.photos.context, asset: $0) }
        await f.photos.set(all); await f.photos.setReadFailures(["retry": .unavailable])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        let initialTasks = try await f.store.nextRepresentationTasks(now: now.addingTimeInterval(100), limit: 2)
        let original = try XCTUnwrap(initialTasks.first)
        let start = rows.rows.count
        for window in 0..<4 {
            clock.now = Double(window * 30)
            for index in 0..<32 {
                let changed = index.isMultiple(of: 2) ? ids : []
                if !changed.isEmpty { all = ids.map { descriptor(f.photos.context, asset: $0, revision: "metadata-\(window)-\(index)") } }
                await f.photos.preserveDeltaInputs(changed)
                let delta = await f.photos.changeFacts(all, changed: changed)
                await f.coordinator.libraryChanged(.incremental(delta)); await f.coordinator.processDueWork(now: now)
            }
        }
        diagnostics.flushObservations(force: true)
        let stream = Array(rows.rows.dropFirst(start))
        XCTAssertLessThanOrEqual(stream.count, 29, "bound original observations plus fixed timing windows")
        let timingWindows = stream.filter { $0["phase"] == "index-window-summary" }
        XCTAssertLessThanOrEqual(timingWindows.count, 5)
        XCTAssertEqual(timingWindows.reduce(0) { $0 + (Int($1["timing.catalog-delta.count"] ?? "0") ?? 0) }, 128)
        XCTAssertEqual(timingWindows.reduce(0) { $0 + (Int($1["timing.db-delta.count"] ?? "0") ?? 0) }, 128)
        let data = try JSONSerialization.data(withJSONObject: stream, options: [.sortedKeys])
        XCTAssertLessThan(data.count, 15_000)
        XCTAssertEqual(stream.filter { $0["phase"] == "index-live-transfer-neutral" }.count, 8)
        let summaries = stream.filter { $0["phase"] == "index-observation-summary" && $0["category"] == "index-live-transfer-neutral" }
        XCTAssertEqual(summaries.reduce(0) { $0 + (Int($1["suppressed"] ?? "0") ?? 0) }, 120)
        XCTAssertEqual(summaries.reduce(0) { $0 + (Int($1["assetObservations"] ?? "0") ?? 0) }, 128)
        XCTAssertEqual(summaries.reduce(0) { $0 + (Int($1["batchObservations"] ?? "0") ?? 0) }, 128)
        XCTAssertFalse(stream.contains { $0["phase"] == "index-invalidation" || $0["phase"] == "index-diagnostic-summary" })
        let finalTasks = try await f.store.nextRepresentationTasks(now: now.addingTimeInterval(100), limit: 2)
        let retained = try XCTUnwrap(finalTasks.first)
        XCTAssertEqual(retained.issuanceRevision, all[0].revision)
        XCTAssertEqual(retained.indexGeneration, original.indexGeneration + 127)
        XCTAssertEqual(retained.retryCount, original.retryCount); XCTAssertEqual(retained.nextRetryAt, original.nextRetryAt)
        await assertEqual(await f.photos.readCount, 2); await assertEqual(await f.model.count, 1)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE state='ready' AND vector IS NOT NULL", at: f.db), 1)
        if let destination = ProcessInfo.processInfo.environment["PHOTOSYNC_TRANSFER_DIAGNOSTIC_EVIDENCE"] {
            let lines = try stream.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) + Data([10]) }
            try lines.reduce(into: Data(), { $0.append($1) }).write(to: URL(fileURLWithPath: destination))
        }
    }

    func testCoordinatorStoreMeaningfulZeroInvalidationControlsAreNotCoalesced() async throws {
        let rows = CoordinatorDiagnostics(), diagnostics = IndexDiagnostics(sink: { rows.record($0) })
        let f = try fixture(indexDiagnostics: diagnostics)
        var healthy = descriptor(f.photos.context, asset: "healthy")
        await f.photos.set([healthy]); try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        var controls: [[String: String]] = []
        for kind in ["content", "unproven", "inserted-with-proof", "changed-shape-with-proof", "deleted"] {
            let start = rows.rows.count
            let added = descriptor(f.photos.context, asset: "new")
            await f.photos.invalidateDelta(kind == "content" ? ["healthy"] : [])
            await f.photos.preserveDeltaInputs(kind == "inserted-with-proof" ? ["new"] : kind == "changed-shape-with-proof" ? ["healthy"] : [])
            if kind == "changed-shape-with-proof" {
                healthy = .init(key: healthy.key, context: healthy.context, revision: healthy.revision,
                    size: try PixelSize(width: 16, height: 8), equivalentToOriginal: false, revisionIsReliable: true, modificationDate: Date(timeIntervalSinceReferenceDate: 200))
            }
            let all = kind == "inserted-with-proof" ? [healthy, added] : [healthy]
            let changed = kind == "deleted" ? [] : [kind == "inserted-with-proof" ? "new" : "healthy"]
            let delta = await f.photos.changeFacts(all, deleted: kind == "deleted" ? ["new"] : [], changed: changed)
            await f.coordinator.libraryChanged(.incremental(delta)); await f.coordinator.processDueWork(now: now)
            let events = Array(rows.rows.dropFirst(start)).filter { $0["phase"] == "index-invalidation" && $0["source"] == "live" }
            XCTAssertEqual(events.count, 1, kind)
            XCTAssertEqual(events.first?["readyToPending"], "0", kind)
            XCTAssertNotNil(events.first?["operation"], kind)
            controls.append(contentsOf: events)
        }
        XCTAssertEqual(controls.count, 5)
        let failed = descriptor(f.photos.context, asset: "failed")
        await f.photos.setReadFailures(["failed": .unavailable])
        await f.photos.invalidateDelta([]); await f.photos.preserveDeltaInputs([])
        let insertion = await f.photos.changeFacts([healthy, failed], changed: ["failed"])
        await f.coordinator.libraryChanged(.incremental(insertion)); await f.coordinator.processDueWork(now: now)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE asset_id='failed' AND state='failed'", at: f.db), 1)
        await f.photos.invalidateDelta(["failed"]); await f.photos.preserveDeltaInputs(["failed"])
        let invalidationStart = rows.rows.count
        let failureEdit = await f.photos.changeFacts([healthy, failed], changed: ["failed"])
        await f.coordinator.libraryChanged(.incremental(failureEdit)); await f.coordinator.processDueWork(now: now)
        let failedEvents = Array(rows.rows.dropFirst(invalidationStart)).filter { $0["phase"] == "index-invalidation" && $0["source"] == "live" }
        XCTAssertEqual(failedEvents.count, 1, "an explicit obligation remains meaningful when no row was ready")
        XCTAssertEqual(failedEvents.first?["readyToPending"], "0")
        XCTAssertEqual(failedEvents.first?["added"], "0"); XCTAssertEqual(failedEvents.first?["changed"], "0"); XCTAssertEqual(failedEvents.first?["deleted"], "0")
        await f.photos.setPages([.init(context: f.photos.context, generation: 8, descriptors: [healthy, failed], nextOffset: nil, invalidateAllCachedRepresentations: true)])
        await f.coordinator.libraryChanged(.fullReconcileRequired)
        let start = rows.rows.count
        await f.coordinator.processDueWork(now: now)
        XCTAssertTrue(rows.rows.dropFirst(start).contains { $0["phase"] == "index-metadata-verification" }, "unknown continuity requests metadata verification without mutating tombstoned facts")
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE tombstoned=0 AND state='ready'", at: f.db), 1)
    }

    func testNeutralGenerationAdvancesDoNotRestartRotationOrStarveHealthyHighKeys() async throws {
        let f = try fixture()
        let all = (0..<40).map { descriptor(f.photos.context, asset: String(format: "%03d", $0)) }
        await f.photos.set(all)
        await f.photos.setReadFailures(Dictionary(uniqueKeysWithValues: all.prefix(32).map { ($0.key.assetID, PhotosRepresentationError.unavailable) }))
        try await f.coordinator.reconcile()
        let cutoff = now.addingTimeInterval(100)
        for slice in 0..<3 {
            if slice > 0 {
                // Context, descriptors, model and input are unchanged; only the live endpoint advances.
                let neutral = await f.photos.changeFacts(all, changed: [])
                await f.coordinator.libraryChanged(.incremental(neutral))
            }
            await f.coordinator.processDueWork(now: cutoff)
            let prefix = (0..<min(40, (slice + 1) * 16)).map { String(format: "%03d", $0) }
            let wrapped = slice == 2 ? (0..<8).map { String(format: "%03d", $0) } : []
            await assertEqual(await f.photos.readAssetIDs, prefix + wrapped)
        }
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE asset_id>='032' AND state='ready'", at: f.db), 8)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM fingerprint_task WHERE asset_id<'032' AND retry_count>0", at: f.db), 32)
    }

    func testSameDateLocatorDeltasRetargetIssuancePreservingRotationAndFailureBackoff() async throws {
        let f = try fixture()
        var all = (0..<40).map { descriptor(f.photos.context, asset: String(format: "%03d", $0)) }
        let ids = all.map { $0.key.assetID }
        await f.photos.set(all)
        await f.photos.setReadFailures(Dictionary(uniqueKeysWithValues: all.prefix(32).map { ($0.key.assetID, PhotosRepresentationError.unavailable) }))
        try await f.coordinator.reconcile()
        let cutoff = now.addingTimeInterval(100)
        let initial = Dictionary(uniqueKeysWithValues: try await f.store.nextRepresentationTasks(now: cutoff, limit: 40).map { ($0.descriptor.key.assetID, $0) })
        XCTAssertEqual(initial.count, 40)
        for slice in 0..<3 {
            let revision = slice == 0 ? "r1" : "metadata-\(slice)"
            if slice > 0 {
                // Nonempty producer evidence changes metadata-derived revision only;
                // every asset's actual representation input remains unchanged.
                all = ids.map { descriptor(f.photos.context, asset: $0, revision: revision) }
                await f.photos.preserveDeltaInputs(ids)
                let neutral = await f.photos.changeFacts(all, changed: ids)
                await f.coordinator.libraryChanged(.incremental(neutral))
            }
            await f.coordinator.processDueWork(now: cutoff)
            let prefix = (0..<min(40, (slice + 1) * 16)).map { String(format: "%03d", $0) }
            let wrapped = slice == 2 ? (0..<8).map { String(format: "%03d", $0) } : []
            await assertEqual(await f.photos.readAssetIDs, prefix + wrapped)
            let remaining = try await f.store.nextRepresentationTasks(now: cutoff, limit: 40)
            XCTAssertEqual(remaining.count, slice == 2 ? 32 : 40)
            for task in remaining {
                let asset = task.descriptor.key.assetID
                let original = try XCTUnwrap(initial[asset])
                XCTAssertEqual(task.descriptor.revision, revision)
                XCTAssertEqual(task.descriptor.context, original.descriptor.context)
                XCTAssertEqual(task.issuanceRevision, revision, "The current locator owns the retargeted issuance")
                XCTAssertEqual(task.indexGeneration, original.indexGeneration + Int64(slice))
                let ordinal = try XCTUnwrap(Int(asset))
                let retries = slice == 2 && ordinal < 8 ? 2 : (ordinal < min(32, (slice + 1) * 16) ? 1 : 0)
                XCTAssertEqual(task.retryCount, retries, "Neutral metadata must preserve prior failures")
                XCTAssertEqual(task.nextRetryAt, retries == 0 ? nil : now.addingTimeInterval(retries == 2 ? 15 : 5))
            }
        }
        await assertEqual(await f.photos.deltaRequests, [ids, ids])
        await assertEqual(await f.model.count, 8)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE asset_id>='032' AND state='ready' AND vector IS NOT NULL AND revision='metadata-2'", at: f.db), 8)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM fingerprint_task WHERE asset_id<'032' AND retry_count>0", at: f.db), 32)
    }

    func testRotatingKeysetServesNewLowKeyAndDueRetriesAcrossWrap() async throws {
        let clock = DiagnosticClock(); clock.now = 1000
        let f = try fixture(wallNow: { Date(timeIntervalSince1970: clock.now) })
        let initial = (100..<140).map { descriptor(f.photos.context, asset: String($0)) }
        await f.photos.set(initial)
        await f.photos.setReadFailures(Dictionary(uniqueKeysWithValues: initial.map { ($0.key.assetID, PhotosRepresentationError.unavailable) }))
        try await f.coordinator.reconcile()
        // Every failed deadline remains eligible against this frozen future cutoff.
        let cutoff = now.addingTimeInterval(100)
        await f.coordinator.processDueWork(now: cutoff)
        await assertEqual(await f.photos.readAssetIDs, (100..<116).map(String.init))
        clock.now = 500 // A wall-clock rollback does not reset the rotating slice or admit repeats.
        let added = descriptor(f.photos.context, asset: "000-new")
        let delta = await f.photos.changeFacts(initial + [added], changed: [added.key.assetID])
        await f.coordinator.libraryChanged(.incremental(delta))
        await f.coordinator.processDueWork(now: cutoff)
        await assertEqual(await f.photos.readAssetIDs, (100..<132).map(String.init))
        await f.coordinator.processDueWork(now: cutoff)
        await assertEqual(await f.photos.readAssetIDs, (100..<140).map(String.init) + ["000-new"] + (100..<107).map(String.init))
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM fingerprint_task WHERE retry_count>0", at: f.db), 40)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE asset_id='000-new' AND state='ready'", at: f.db), 1)
    }

    func testCapacityErrorFromModelRemainsFailureWithModelBackoff() async throws {
        for unavailable in [false, true] {
            let f = try fixture()
            await f.photos.set([descriptor(f.photos.context)])
            if unavailable { await f.model.setUnavailable(true) }
            else { await f.model.setCapacityFailure(true) }
            try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
            let tasks = try await f.store.nextRepresentationTasks(now: now.addingTimeInterval(100), limit: 1)
            XCTAssertEqual(tasks.first?.retryCount, 1)
            XCTAssertEqual(tasks.first?.nextRetryAt, now.addingTimeInterval(unavailable ? 60 : 5))
            let progress = await f.coordinator.progress()
            XCTAssertEqual(progress.state, .waiting); XCTAssertEqual(progress.readErrorRepresentations, 0)
            if unavailable { XCTAssertEqual(progress.issue, ModelExecutionUnavailable.summary) }
        }
    }

    func testFrozenCutoffDoesNotAdmitTasksBecomingDueDuringOwnedWork() async throws {
        let clock = DiagnosticClock(), gate = CoordinatorGate(), f = try fixture(wallNow: { Date(timeIntervalSince1970: clock.now) })
        await f.photos.set([descriptor(f.photos.context, asset: "a"), descriptor(f.photos.context, asset: "b")])
        try await f.coordinator.reconcile()
        try injectEngineSQL("UPDATE fingerprint_task SET next_retry_at=1001 WHERE asset_id='b'", at: f.db)
        await f.model.setGate(gate)
        let work = Task { await f.coordinator.processDueWork(now: now) }
        await gate.waitUntilEntered(); clock.now = 2000; await gate.release(); await work.value
        await assertEqual(await f.photos.readCount, 1)
        await f.coordinator.processDueWork(now: now.addingTimeInterval(1))
        try await assertNotNil(try await f.coordinator.readyToken())
    }

    func testPauseAndContextChangeDuringAdmissionCannotStartStaleWork() async throws {
        for contextChange in [false, true] {
            let f = try fixture(), gate = CoordinatorGate()
            await f.photos.set([descriptor(f.photos.context)]); try await f.coordinator.reconcile()
            await f.photos.gateAdmission(2, using: gate)
            let work = Task { await f.coordinator.processDueWork(now: now) }
            await gate.waitUntilEntered()
            if contextChange { await f.coordinator.libraryChanged(.contextInvalidated) }
            else { await f.coordinator.setPaused(true) }
            await gate.release(); await work.value
            await assertEqual(await f.photos.readCount, 0)
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM fingerprint_task WHERE retry_count=0 AND next_retry_at IS NULL", at: f.db), 1)
        }
    }

    func testRacingReadCapacityErrorsDoNotChangeDurableTaskOrVector() async throws {
        for error in [ReadExecutorError.sourceBusy, .resourceExhausted, nil] {
            let f = try fixture()
            await f.photos.set([descriptor(f.photos.context, asset: "a"), descriptor(f.photos.context, asset: "b")])
            try await f.coordinator.reconcile(); try installWriteAudit(at: f.db)
            await f.photos.setReadError(error); await f.photos.setBudgetExhausted(error == nil)
            await f.coordinator.processDueWork(now: now)
            await assertEqual(await f.photos.readCount, 1)
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM p11_writes", at: f.db), 0)
            await f.photos.setReadError(nil); await f.photos.setBudgetExhausted(false)
            await f.coordinator.processDueWork(now: now)
            try await assertNotNil(try await f.coordinator.readyToken())
        }
    }

    func testSampledStaleSuccessFailureAndCancellationHaveTerminalOutcomes() async throws {
        for outcome in ["success", "failure", "cancelled"] {
            let rows = CoordinatorDiagnostics(), f = try fixture(diagnostics: { rows.record($0) }), gate = CoordinatorGate()
            let d = descriptor(f.photos.context)
            await f.photos.set([d]); try await f.coordinator.reconcile(); await f.model.setGate(gate)
            let work = Task { await f.coordinator.processDueWork(now: now) }
            await gate.waitUntilEntered()
            let attempt = try XCTUnwrap(rows.rows.first { $0["phase"] == "index-task" && $0["event"] == "attempt" })
            if outcome == "failure" { await f.model.setAfterGate(.failure(.invalidImage)) }
            if outcome == "cancelled" { await f.model.setAfterGate(.cancelled) }
            else {
                await f.photos.set([descriptor(f.photos.context, revision: "new", date: Date(timeIntervalSinceReferenceDate: 200))])
                await f.coordinator.libraryChanged(.fullReconcileRequired)
            }
            await f.coordinator.setPaused(true)
            await gate.release(); await work.value
            let terminal = rows.rows.filter { $0["phase"] == "index-task" && $0["event"] != "attempt" && $0["issuanceHandle"] == attempt["issuanceHandle"] }
            XCTAssertEqual(terminal.count, 1)
            XCTAssertEqual(terminal.first?["event"], outcome == "cancelled" ? "deferred" : "rejected")
            XCTAssertEqual(terminal.first?["reason"], outcome == "success" ? "inventory-not-current" : outcome == "failure" ? "stale-failure" : "cancelled")
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM fingerprint_task WHERE retry_count=0 AND next_retry_at IS NULL", at: f.db), 1)
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE state='ready'", at: f.db), 0)
        }
    }

    func testDiagnosticHandlesAreRunLocalAndNeutralOvernightVolumeIsBounded() throws {
        let log = CoordinatorDiagnostics(), clock = DiagnosticClock()
        let diagnostic = IndexDiagnostics(sink: { log.record($0) }, monotonic: { clock.now })
        let token = Data("PRIVATE-TOKEN-SENTINEL".utf8)
        XCTAssertEqual(diagnostic.tokenHandle(token), diagnostic.tokenHandle(token))
        let other = IndexDiagnostics(sink: { _ in })
        XCTAssertNotEqual(diagnostic.tokenHandle(token), other.tokenHandle(token))
        // 8 hours, 100 notifications/second, three neutral production phases.
        for window in 0..<960 {
            clock.now = Double(window * 30)
            for _ in 0..<3000 {
                diagnostic.observation(["phase": "photos-notification", "publication": "closed", "classification": "pending"])
                diagnostic.observation(["phase": "photos-fetch-details", "incremental": "true"])
                diagnostic.observation(["phase": "photos-change-classification", "contentScope": "known", "contentChanged": "0", "inserted": "0", "deleted": "0"])
            }
        }
        diagnostic.flushObservations(force: true)
        XCTAssertEqual(log.rows.count, 8640)
        let suppressed = log.rows.reduce(0) { $0 + (Int($1["suppressed"] ?? "0") ?? 0) }
        XCTAssertEqual(suppressed, 8_634_240)
        let data = try JSONSerialization.data(withJSONObject: log.rows, options: [.sortedKeys])
        XCTAssertLessThan(data.count, 2_000_000)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE-TOKEN-SENTINEL"))
        diagnostic.observation(["phase": "photos-change-classification", "contentScope": "unknown", "fallback": "gap"])
        diagnostic.observation(["phase": "photos-change-classification", "contentScope": "known", "contentChanged": "1"])
        XCTAssertEqual(log.rows.count, 8642, "Unknown and content transitions cannot be throttled as neutral")
        diagnostic.state("reader", value: "busy")
        for _ in 0..<1000 { diagnostic.state("reader", value: "busy"); diagnostic.flushObservations() }
        XCTAssertEqual(log.rows.count, 8643, "Polling must not emit one summary per tick")
        diagnostic.state("reader", value: "available")
        XCTAssertEqual(log.rows.last?["suppressed"], "1000")
    }

    func testAnonymousDiagnosticsLinkTwoReconciliationsAndBoundDetail() async throws {
        let log = CoordinatorDiagnostics(), f = try fixture(diagnostics: { log.record($0) })
        let descriptors = (0..<20).map { descriptor(f.photos.context, asset: "private-asset-\($0)") }
        await f.photos.setPaged(descriptors, pageSize: 10)
        try await f.coordinator.reconcile(); await drain(f.coordinator, cutoff: now)
        await f.photos.setPages([.init(context: f.photos.context, generation: 2, descriptors: descriptors.map { descriptor(f.photos.context, asset: $0.key.assetID, date: Date(timeIntervalSinceReferenceDate: 200)) }, nextOffset: nil,
            invalidatedAssetIDs: descriptors.map { $0.key.assetID })])
        try await f.coordinator.reconcile(); await drain(f.coordinator, cutoff: now)
        let rows = log.rows
        XCTAssertFalse(rows.contains { $0.values.contains { $0.contains("private-asset-") } })
        let invalidations = rows.filter { $0["phase"] == "index-invalidation" }
        XCTAssertTrue(invalidations.isEmpty, "Content events cannot force analysis invalidation; changed dates schedule per item")
        let details = rows.filter { $0["assetHandle"] != nil }
        XCTAssertFalse(details.isEmpty)
        XCTAssertLessThanOrEqual(Set(details.compactMap { $0["assetHandle"] }).count, 8)
        let attempts = rows.filter { $0["phase"] == "index-task" && $0["event"] == "attempt" }
        for handle in Set(attempts.compactMap { $0["assetHandle"] }) {
            XCTAssertEqual(Set(attempts.filter { $0["assetHandle"] == handle }.compactMap { $0["issuanceHandle"] }).count, 2)
        }
        let reconciles = Set(details.compactMap { $0["operation"] })
        XCTAssertGreaterThanOrEqual(reconciles.count, 2)
        XCTAssertTrue(rows.contains { $0["phase"] == "index-diagnostic-summary" && Int($0["suppressed"] ?? "0") ?? 0 > 0 })
        XCTAssertEqual(rows.filter { $0["phase"] == "index-reconcile" }.count, 2)
        let samples = rows.filter { $0["phase"] == "index-catalog-sample" }
        for handle in Set(samples.compactMap { $0["assetHandle"] }) {
            XCTAssertEqual(Set(samples.filter { $0["assetHandle"] == handle }.compactMap { $0["descriptorHandle"] }).count, 2, "An actual date change has a new descriptor identity")
        }
        if let destination = ProcessInfo.processInfo.environment["PHOTOSYNC_DIAGNOSTIC_EVIDENCE"] {
            let lines = try rows.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) + Data([10]) }
            try lines.reduce(into: Data(), { $0.append($1) }).write(to: URL(fileURLWithPath: destination))
        }
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE state='ready'", at: f.db), 20)
    }

    func testDecoderConservativeReadGapLetsHealthySiblingPublishWithoutVector() async throws {
        for reason in [RepresentationConservativeReason.decodedResourceLimit, .multiFrameOrCompound] {
            let log = CoordinatorDiagnostics(), f = try fixture(diagnostics: { log.record($0) })
            let failed = descriptor(f.photos.context, asset: "unsupported"), healthy = descriptor(f.photos.context, asset: "good")
            await f.photos.set([failed, healthy])
            await f.photos.setReadFailures([failed.key.assetID: .unsupportedRepresentation(reason)])
            try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
            let progress = await f.coordinator.progress()
            XCTAssertEqual(progress.state, .ready); XCTAssertEqual(progress.readyRepresentations, 1)
            XCTAssertEqual(progress.readErrorRepresentations, 1)
            try await assertNotNil(try await f.coordinator.readyToken())
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE asset_id='unsupported' AND state='failed' AND vector IS NULL", at: f.db), 1)
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM fingerprint_task WHERE asset_id='unsupported' AND failure_kind='photos_read' AND last_error LIKE '%\(reason.rawValue)%'", at: f.db), 1)
            XCTAssertTrue(log.rows.contains { $0["stage"] == "photos-read" && $0["result"] == "read-error" && $0["error"]?.contains(reason.rawValue) == true })
        }
    }

    func testTerminalCocoaReadFailureAllowsHealthySiblingPublication() async throws {
        let log = CoordinatorDiagnostics()
        let f = try fixture(diagnostics: { log.record($0) })
        let failed = descriptor(f.photos.context, asset: "bad"), healthy = descriptor(f.photos.context, asset: "good")
        await f.photos.set([failed, healthy])
        await f.photos.setCallbackFailure(NSError(domain: NSCocoaErrorDomain, code: -1,
            userInfo: [NSLocalizedDescriptionKey: "synthetic terminal image failure"]), key: failed.key)
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        let progress = await f.coordinator.progress()
        XCTAssertEqual(progress.state, .ready)
        XCTAssertEqual(progress.readyRepresentations, 1)
        XCTAssertEqual(progress.readErrorRepresentations, 1)
        XCTAssertEqual(progress.excludedAssets, 0)
        XCTAssertTrue(log.rows.contains { $0["stage"] == "photos-read" && $0["result"] == "read-error" && $0["error"]?.contains("NSCocoaErrorDomain") == true })
        try await assertNotNil(try await f.coordinator.readyToken())
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE asset_id='bad' AND state='failed' AND vector IS NULL", at: f.db), 1)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM fingerprint_task WHERE asset_id='bad' AND retry_count=1", at: f.db), 1)
        let physical = await f.photos.budget.snapshot(); XCTAssertEqual(physical.images, 0)
    }
    func testNestedKnownReadFailuresCannotPublishSoftGap() async throws {
        for cause in [NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
                      NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.accessUserDenied.rawValue)] {
            let log = CoordinatorDiagnostics(), f = try fixture(diagnostics: { log.record($0) })
            let failed = descriptor(f.photos.context, asset: "bad"), healthy = descriptor(f.photos.context, asset: "good")
            await f.photos.set([failed, healthy])
            let wrapper = NSError(domain: NSCocoaErrorDomain, code: -1,
                userInfo: [NSUnderlyingErrorKey: cause, NSLocalizedDescriptionKey: "synthetic wrapper detail"])
            await f.photos.setCallbackFailure(wrapper, key: failed.key)
            try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
            let p = await f.coordinator.progress()
            XCTAssertEqual(p.state, .waiting); XCTAssertEqual(p.readyRepresentations, 1)
            XCTAssertEqual(p.readErrorRepresentations, 0)
            try await assertNil(try await f.coordinator.readyToken())
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM fingerprint_task WHERE asset_id='bad' AND failure_kind IS NULL", at: f.db), 1)
            XCTAssertTrue(log.rows.contains { $0["stage"] == "photos-read" && $0["result"] == "waiting" && $0["error"]?.contains("synthetic wrapper detail") == true })
        }
    }

    func testOriginalAndCurrentReadErrorsAreIndependent() async throws {
        for failedKind in [RepresentationKind.original, .current] {
            let f = try fixture()
            let original = descriptor(f.photos.context), current = descriptor(f.photos.context, kind: .current)
            await f.photos.set([original, current])
            await f.photos.setCallbackFailure(NSError(domain: NSCocoaErrorDomain, code: -1),
                key: failedKind == .original ? original.key : current.key)
            try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
            let p = await f.coordinator.progress()
            XCTAssertEqual(p.state, .ready); XCTAssertEqual(p.readyRepresentations, 1)
            XCTAssertEqual(p.readErrorRepresentations, 1); XCTAssertEqual(p.readyAssets, 0)
            let publication = try await f.store.indexPublication(); XCTAssertEqual(publication?.representationCount, 1)
            let readiness = try await f.store.indexReadiness(); XCTAssertEqual(readiness?.entryCount, 1)
        }
    }

    func testSameReadErrorTypesFromModelRemainBlocking() async throws {
        for error in [PhotosRepresentationError.invalidImage, .unsupportedRepresentation(.decodedResourceLimit),
                      .imageReadFailed(domain: NSCocoaErrorDomain, code: -1, detail: "same model error")] {
            let f = try fixture(), log = CoordinatorDiagnostics()
            let coordinator = PhotosIndexCoordinator(store: f.store, photos: f.photos, fingerprinter: f.model,
                configuration: f.configuration, diagnostics: { log.record($0) })
            await f.photos.set([descriptor(f.photos.context)]); await f.model.setFailure(error)
            try await coordinator.reconcile(); await coordinator.processDueWork(now: now)
            let p = await coordinator.progress()
            XCTAssertEqual(p.state, .waiting); XCTAssertEqual(p.readErrorRepresentations, 0)
            try await assertNil(try await coordinator.readyToken())
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM fingerprint_task WHERE failure_kind IS NULL", at: f.db), 1)
            XCTAssertTrue(log.rows.contains { $0["stage"] == "fingerprint" && $0["result"] == "waiting" })
        }
    }

    func testSQLiteCompletionFailureCannotBecomeReadExclusion() async throws {
        let f = try fixture(), log = CoordinatorDiagnostics()
        let coordinator = PhotosIndexCoordinator(store: f.store, photos: f.photos, fingerprinter: f.model,
            configuration: f.configuration, diagnostics: { log.record($0) })
        await f.photos.set([descriptor(f.photos.context)]); try await coordinator.reconcile()
        try injectEngineSQL("CREATE TRIGGER fail_completion BEFORE UPDATE ON photos_representation WHEN NEW.state='ready' BEGIN SELECT RAISE(FAIL, 'synthetic completion failure'); END", at: f.db)
        await coordinator.processDueWork(now: now)
        let p = await coordinator.progress()
        XCTAssertEqual(p.state, .waiting); XCTAssertEqual(p.readErrorRepresentations, 0)
        try await assertNil(try await coordinator.readyToken())
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM fingerprint_task WHERE failure_kind IS NULL", at: f.db), 1)
        XCTAssertTrue(log.rows.contains { $0["stage"] == "sqlite-completion" && $0["result"] == "waiting" })
    }

    func testStableReadFailureKeepsTokenAndRecoveredReadRevokesIt() async throws {
        let f = try fixture(), d = descriptor(f.photos.context)
        await f.photos.set([d]); await f.photos.setCallbackFailure(NSError(domain: NSCocoaErrorDomain, code: -1), key: d.key)
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        let oldValue = try await f.coordinator.readyToken(); let old = try XCTUnwrap(oldValue)
        await f.coordinator.processDueWork(now: now.addingTimeInterval(5))
        let repeated = try await f.coordinator.readyToken(); XCTAssertEqual(repeated, old)
        XCTAssertEqual(try engineSQLInteger("SELECT retry_count FROM fingerprint_task", at: f.db), 2)
        await f.photos.setCallbackFailure(nil, key: d.key)
        await f.coordinator.processDueWork(now: now.addingTimeInterval(20))
        let recoveredValue = try await f.coordinator.readyToken(); let recovered = try XCTUnwrap(recoveredValue)
        XCTAssertGreaterThan(recovered.indexGeneration, old.indexGeneration)
        let oldValid = try await f.store.indexIsReady(token: old); XCTAssertFalse(oldValid)
        let p = await f.coordinator.progress(); XCTAssertEqual(p.readErrorRepresentations, 0); XCTAssertEqual(p.readyRepresentations, 1)
    }

    func testSoftReadRetryBecomingModelFailureRevokesPublishedToken() async throws {
        let f = try fixture(), d = descriptor(f.photos.context)
        await f.photos.set([d]); await f.photos.setCallbackFailure(NSError(domain: NSCocoaErrorDomain, code: -1), key: d.key)
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        let oldValue = try await f.coordinator.readyToken(), old = try XCTUnwrap(oldValue)
        await f.photos.setCallbackFailure(nil, key: d.key)
        await f.model.setFailure(.imageReadFailed(domain: NSCocoaErrorDomain, code: -1, detail: "model stage"))
        await f.coordinator.processDueWork(now: now.addingTimeInterval(5))
        let p = await f.coordinator.progress()
        XCTAssertEqual(p.state, .waiting); XCTAssertEqual(p.readErrorRepresentations, 0)
        try await assertNil(try await f.coordinator.readyToken())
        let stillValid = try await f.store.indexIsReady(token: old); XCTAssertFalse(stillValid)
    }

    func testInvalidAndOversizedReadBitmapsAreIsolated() async throws {
        for error in [PhotosRepresentationError.invalidImage, .oversized(width: 8192, height: 8192)] {
            let f = try fixture(), d = descriptor(f.photos.context)
            await f.photos.set([d]); await f.photos.setReadFailures([d.key.assetID: error])
            try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
            let p = await f.coordinator.progress()
            XCTAssertEqual(p.state, .ready); XCTAssertEqual(p.readErrorRepresentations, 1)
            XCTAssertEqual(p.readyRepresentations, 0)
            let publication = try await f.store.indexPublication(); XCTAssertEqual(publication?.representationCount, 0)
        }
    }

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

    func testSameDateLocatorRetargetRejectsOldInFlightIssuanceWithoutLosingWork() async throws {
        let f = try fixture(), gate = CoordinatorGate()
        let a = descriptor(f.photos.context)
        await f.photos.set([a]); try await f.coordinator.reconcile(); await f.model.setGate(gate)
        let work = Task { await f.coordinator.processDueWork(now: now) }
        await gate.waitUntilEntered()
        let delta = await f.photos.changeFacts([descriptor(f.photos.context, revision: "metadata-only")], changed: [a.key.assetID])
        await f.photos.preserveDeltaInputs([a.key.assetID])
        await f.coordinator.libraryChanged(.incremental(delta))
        await gate.release(); await work.value
        try await assertNil(try await f.coordinator.readyToken())
        await f.coordinator.processDueWork(now: now)
        try await assertNotNil(try await f.coordinator.readyToken())
        await assertEqual(await f.model.count, 2)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE revision='metadata-only' AND state='ready'", at: f.db), 1)
    }

    func testSingleEditIn100000ReadyRowsWritesOnlyAffectedAsset() async throws {
        let f = try fixture()
        let a = descriptor(f.photos.context, asset: "a0"), other = descriptor(f.photos.context, asset: "unrelated")
        await f.photos.set([a, other]); try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        try injectEngineSQL("""
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<99998)
            INSERT INTO photos_representation(context_id,context_epoch,asset_id,kind,revision,width,height,equivalent_to_original,revision_is_reliable,seen_generation,state,fingerprint_version,vector,tombstoned)
            SELECT context_id,context_epoch,'bulk'||n.x,kind,revision,width,height,equivalent_to_original,revision_is_reliable,seen_generation,state,fingerprint_version,vector,tombstoned
            FROM photos_representation,n WHERE asset_id='unrelated';
            """, at: f.db)
        try installWriteAudit(at: f.db)
        await f.model.reset(); await f.photos.resetReads()
        let delta = await f.photos.changeFacts([descriptor(f.photos.context, asset: "a0", revision: "edit", date: Date(timeIntervalSinceReferenceDate: 200)), other], changed: ["a0"])
        await f.coordinator.libraryChanged(.incremental(delta)); await f.coordinator.processDueWork(now: now)
        try await assertNotNil(try await f.coordinator.readyToken())
        await assertEqual(await f.model.count, 1)
        await assertEqual(await f.photos.requestedLimits, [])
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE state='ready' AND vector IS NOT NULL", at: f.db), 100000)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM p11_writes WHERE table_name='photos_representation'", at: f.db), 2)
    }

    func testUnknownContinuityRetainsExistingFailedRetryDeadline() async throws {
        let f = try fixture()
        let d = descriptor(f.photos.context)
        await f.photos.set([d]); await f.photos.fail(d.key.assetID)
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        try injectEngineSQL("CREATE TABLE retry_before AS SELECT asset_id,retry_count,next_retry_at,last_error FROM fingerprint_task", at: f.db)
        await f.photos.setPages([.init(context: f.photos.context, generation: 2, descriptors: [d], nextOffset: nil, invalidateAllCachedRepresentations: true)])
        try await f.coordinator.reconcile()
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM (SELECT * FROM retry_before EXCEPT SELECT asset_id,retry_count,next_retry_at,last_error FROM fingerprint_task)", at: f.db), 0)
        await f.photos.resetReads(); await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.photos.readCount, 0)
    }

    func testUnknownContinuityRetainsBytesAndRepublishesVerifiedMetadata() async throws {
        let f = try fixture()
        let original = descriptor(f.photos.context)
        await f.photos.set([original]); try await f.coordinator.reconcile()
        await f.coordinator.processDueWork(now: now)
        try injectEngineSQL("CREATE TABLE retained_vectors AS SELECT asset_id, kind, vector FROM photos_representation", at: f.db)
        await f.photos.setPages([.init(context: f.photos.context, generation: 2, descriptors: [original],
            nextOffset: nil, invalidateAllCachedRepresentations: true)])
        try await f.coordinator.reconcile()
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE vector IS NOT NULL AND state = 'ready'", at: f.db), 1)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM retained_vectors v JOIN photos_representation r USING(asset_id,kind) WHERE r.vector=v.vector", at: f.db), 1)
        try await assertNotNil(try await f.coordinator.readyToken())
    }

    func test129ChangedAssetsUseBoundedDeltaBatchesWithoutTouchingUnrelatedRows() async throws {
        let f = try fixture()
        let all = (0..<140).flatMap { id in
            [descriptor(f.photos.context, asset: "a\(id)"), descriptor(f.photos.context, asset: "a\(id)", kind: .current)]
        }
        let initial = try await f.store.beginIndexReconciliation(context: f.photos.context, photosGeneration: 1,
            fingerprintVersion: f.configuration.fingerprint.version)
        try await f.store.upsertRepresentations(all, generation: initial)
        try await f.store.finishIndexReconciliation(generation: initial, seenKeys: Set(all.map(\.key)))
        let fingerprint = try Fingerprint(version: f.configuration.fingerprint.version, values: [1] + Array(repeating: 0, count: 1023))
        for task in try await f.store.nextRepresentationTasks(now: now, limit: 1000) {
            _ = try await f.store.completeRepresentation(task, fingerprint: fingerprint)
        }
        await f.photos.setPaged(all, pageSize: 128)
        try await f.coordinator.reconcile(); await drain(f.coordinator, cutoff: now)
        try installWriteAudit(at: f.db)
        try injectEngineSQL("CREATE TABLE untouched AS SELECT * FROM photos_representation WHERE asset_id='a139'", at: f.db)
        await f.photos.resetReads(); await f.model.reset()
        let ids = (0..<129).map { "a\($0)" }
        let edited = all.map { d in ids.contains(d.key.assetID) ? descriptor(f.photos.context, asset: d.key.assetID, kind: d.key.kind, date: Date(timeIntervalSinceReferenceDate: 200)) : d }
        let delta = await f.photos.changeFacts(edited, changed: ids)
        await f.photos.invalidateDelta(ids)
        await f.coordinator.libraryChanged(.incremental(delta))
        await drain(f.coordinator, cutoff: now)
        try await assertNotNil(try await f.coordinator.readyToken())
        await assertEqual(await f.model.count, 258)
        await assertEqual(await f.photos.requestedLimits, [])
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM (SELECT * FROM untouched EXCEPT SELECT * FROM photos_representation)", at: f.db), 0)
    }

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
        await f.photos.set([original, descriptor(f.photos.context, kind: .current, revision: "edit2", date: Date(timeIntervalSinceReferenceDate: 200))])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.photos.readKinds, [.current])
        await assertEqual(await f.model.count, 1)
    }

    func testRevertCoalescesEquivalentRepresentations() async throws {
        let f = try fixture()
        await f.photos.set([descriptor(f.photos.context), descriptor(f.photos.context, kind: .current, revision: "edit", date: Date(timeIntervalSinceReferenceDate: 200))])
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

    func testSameDateExplicitPageContentNotificationDoesNoImageWork() async throws {
        let f = try fixture(); let d = descriptor(f.photos.context)
        await f.photos.set([d]); try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await f.model.reset(); await f.photos.resetReads()
        await f.photos.setPages([.init(context: f.photos.context, generation: 2, descriptors: [d], nextOffset: nil, invalidatedAssetIDs: [d.key.assetID])])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.model.count, 0)
        await assertEqual(await f.photos.readCount, 0)
        try await assertNotNil(try await f.coordinator.readyToken())
    }

    func testUnknownContinuityOnLaterPageRetainsMetadataVerifiedCachedPages() async throws {
        let f = try fixture(); let a = descriptor(f.photos.context, asset: "a"), b = descriptor(f.photos.context, asset: "b")
        await f.photos.set([a, b]); try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await f.model.reset()
        await f.photos.setPages([
            .init(context: f.photos.context, generation: 2, descriptors: [a], nextOffset: 1),
            .init(context: f.photos.context, generation: 2, descriptors: [b], nextOffset: nil, invalidateAllCachedRepresentations: true)
        ])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.model.count, 0)
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

    func testFailedResumeReusesMetadataVerifiedSameDeviceFacts() async throws {
        let f = try fixture(); await f.photos.set([descriptor(f.photos.context)])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        let reopened = try SyncStore(url: f.db); await f.photos.setResumeSuccess(false); await f.model.reset()
        let resumed = PhotosIndexCoordinator(store: reopened, photos: f.photos, fingerprinter: f.model,
            configuration: f.configuration)
        try await resumed.reconcile(); await resumed.processDueWork(now: now)
        await assertEqual(await f.model.count, 0)
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
        await f.photos.set([descriptor(f.photos.context, revision: "new", date: Date(timeIntervalSinceReferenceDate: 200))])
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
        try await f.store.upsertRepresentations([descriptor(f.photos.context, date: Date(timeIntervalSinceReferenceDate: 200))], generation: second)
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
        await f.photos.set([descriptor(f.photos.context, revision: "changed", date: Date(timeIntervalSinceReferenceDate: 200))])
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

    func testThrownResumePreservesMetadataVerifiedCacheOnRetry() async throws {
        let f = try fixture(); await f.photos.set([descriptor(f.photos.context)])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        let reopened = try SyncStore(url: f.db); await f.photos.throwNextResume(); await f.model.reset()
        let resumed = PhotosIndexCoordinator(store: reopened, photos: f.photos, fingerprinter: f.model,
            configuration: f.configuration)
        do { try await resumed.reconcile(); XCTFail("Expected interrupted replay") } catch {}
        try await resumed.reconcile(); await resumed.processDueWork(now: now)
        await assertEqual(await f.model.count, 0)
    }

    func testGenerationMismatchTriggersReconciliationWithoutStreamConsumption() async throws {
        let f = try fixture(); await f.photos.set([descriptor(f.photos.context)])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await f.model.reset(); await f.photos.set([descriptor(f.photos.context, revision: "changed", date: Date(timeIntervalSinceReferenceDate: 200))])
        try await assertNil(try await f.coordinator.readyToken())
        await f.coordinator.processDueWork(now: now)
        await assertEqual(await f.model.count, 1)
        try await assertNotNil(try await f.coordinator.readyToken())
    }

    // A generic blocking lookup error is distinct from the now-isolated invalid bitmap.
    func testWaitingClassificationSurvivesReconciliationBeforeRetryDeadline() async throws {
        for cloud in [true, false] {
            let f = try fixture()
            let image = descriptor(f.photos.context)
            await f.photos.set([image])
            await f.photos.setReadFailures([image.key.assetID: cloud ? .iCloudUnavailable("offline") : .unavailable])
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
        let clock = DiagnosticClock(); clock.now = 1000
        let f = try fixture(wallNow: { Date(timeIntervalSince1970: clock.now) })
        await f.photos.set([descriptor(f.photos.context, asset: "a-generic"), descriptor(f.photos.context, asset: "z-cloud")])
        await f.photos.setReadFailures(["a-generic": .unavailable, "z-cloud": .iCloudUnavailable("offline")])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await f.photos.setReadFailures(["a-generic": .unavailable])
        clock.now = 1005
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
        let clock = DiagnosticClock(); clock.now = 1000
        let f = try fixture(wallNow: { Date(timeIntervalSince1970: clock.now) }), asset = "cloud"
        await f.photos.set([descriptor(f.photos.context, asset: asset)])
        await f.photos.setReadFailures([asset: .iCloudUnavailable("offline")])
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
        await f.photos.setReadFailures([asset: .unavailable])
        clock.now = 1005
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
            await f.photos.setReadFailures(["cloud": .iCloudUnavailable("offline"), "generic": .unavailable])
            try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: now)
            let failed = await f.coordinator.progress()
            XCTAssertEqual(failed.issue, "正在等待 iCloud 图像，连接恢复后自动继续", change)
            switch change {
            case "removal": await f.photos.set([generic])
            case "revision": await f.photos.set([descriptor(f.photos.context, asset: "cloud", revision: "r2", date: Date(timeIntervalSinceReferenceDate: 200)), generic])
            case "invalidation":
                await f.photos.setPages([.init(context: f.photos.context, generation: 2, descriptors: [descriptor(f.photos.context, asset: "cloud", date: Date(timeIntervalSinceReferenceDate: 200)), generic],
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
            await f.photos.set(original); try await f.coordinator.reconcile(); await drain(f.coordinator, cutoff: now)
            try installWriteAudit(at: f.db)
            try injectEngineSQL("CREATE TABLE untouched AS SELECT * FROM photos_representation WHERE asset_id <> 'a0';", at: f.db)
            await f.photos.resetReads(); await f.model.reset()
            let edit = descriptor(f.photos.context, asset: "a0", revision: "r2", date: Date(timeIntervalSinceReferenceDate: 200))
            let delta = await f.photos.changeFacts([edit] + Array(original.dropFirst()), changed: ["a0"])
            await f.coordinator.libraryChanged(.incremental(delta))
            try await assertNil(try await f.coordinator.readyToken())
            await drain(f.coordinator, cutoff: now)
            let token = try await f.coordinator.readyToken()
            XCTAssertEqual(token?.photosGeneration, delta.toGeneration)
            await assertEqual(await f.photos.requestedLimits, [])
            await assertEqual(await f.photos.deltaRequests, [["a0"]])
            await assertEqual(await f.model.count, 1)
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM (SELECT * FROM untouched EXCEPT SELECT * FROM photos_representation)", at: f.db), 0)
            writes.append(try ["photos_representation", "fingerprint_task"].map { try engineSQLInteger("SELECT COUNT(*) FROM p11_writes WHERE table_name='\($0)'", at: f.db) })
            let added = descriptor(f.photos.context, asset: "new")
            let add = await f.photos.changeFacts([edit, added] + Array(original.dropFirst()), changed: ["new"])
            await f.coordinator.libraryChanged(.incremental(add)); await drain(f.coordinator, cutoff: now)
            let remove = await f.photos.changeFacts(original, deleted: ["new"], changed: ["a0"])
            await f.coordinator.libraryChanged(.incremental(remove)); await drain(f.coordinator, cutoff: now)
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
        let edited = descriptor(f.photos.context, kind: .current, revision: "edit", date: Date(timeIntervalSinceReferenceDate: 200))
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
        let delta = await f.photos.changeFacts([a, descriptor(f.photos.context, asset: "b", revision: "new", date: Date(timeIntervalSinceReferenceDate: 200))], changed: ["b"])
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

    private func drain(_ coordinator: PhotosIndexCoordinator, cutoff: Date) async {
        for _ in 0..<32 {
            await coordinator.processDueWork(now: cutoff)
            if (try? await coordinator.readyToken()) != nil { return }
        }
        XCTFail("bounded test drain did not reach original ready oracle")
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
    private func fixture(indexDiagnostics: IndexDiagnostics? = nil, wallNow: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1000) }, monotonic: @escaping @Sendable () -> TimeInterval = { 0 }, diagnostics: @escaping @Sendable ([String: String]) -> Void = { _ in }) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configuration = try JSONDecoder().decode(DedupConfiguration.self, from: Data(contentsOf: repository.appendingPathComponent("docs/research/advanced-dedup/integration-profile.json")))
        let db = root.appendingPathComponent("test.sqlite"), store = try SyncStore(url: db)
        let photos = CoordinatorPhotos(limits: configuration.resources), model = CoordinatorModel(version: configuration.fingerprint.version)
        return Fixture(db: db, store: store, photos: photos, model: model, configuration: configuration,
            coordinator: PhotosIndexCoordinator(store: store, photos: photos, fingerprinter: model,
                configuration: configuration, wallNow: wallNow, monotonic: monotonic, indexDiagnostics: indexDiagnostics, diagnostics: diagnostics))
    }
    private func descriptor(_ context: LibraryContext, asset: String = "asset", kind: RepresentationKind = .original,
                            revision: String = "r1", equivalent: Bool = false, date: Date? = Date(timeIntervalSinceReferenceDate: 100)) -> RepresentationDescriptor {
        .init(key: .init(assetID: asset, kind: kind), context: context, revision: revision,
              size: try! PixelSize(width: 8, height: 8), equivalentToOriginal: equivalent, revisionIsReliable: true, modificationDate: date)
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

private enum CoordinatorAfterGate: Sendable { case cancelled, failure(PhotosRepresentationError) }

private actor CoordinatorModel: ImageFingerprinting {
    private var afterGate: CoordinatorAfterGate?
    func setAfterGate(_ outcome: CoordinatorAfterGate) { afterGate = outcome }
    private let version: String
    private(set) var count = 0
    private var gate: CoordinatorGate?
    private var unavailable = false, capacityFailure = false
    func setCapacityFailure(_ value: Bool) { capacityFailure = value }
    private var failure: PhotosRepresentationError?
    func setFailure(_ error: PhotosRepresentationError?) { failure = error }
    func setUnavailable(_ value: Bool) { unavailable = value }
    init(version: String) { self.version = version }
    func setGate(_ gate: CoordinatorGate) { self.gate = gate }
    func reset() { count = 0 }
    func fingerprint(image: CGImage, orientation: CGImagePropertyOrientation) async throws -> Fingerprint {
        if let failure { throw failure }
        if unavailable { throw ModelExecutionUnavailable(detail: "test index") }
        if capacityFailure { throw ImageWorkBudgetError.exhausted }
        count += 1; if let gate { self.gate = nil; await gate.hold() }
        if let afterGate {
            switch afterGate { case .cancelled: throw CancellationError(); case .failure(let error): throw error }
        }
        try Task.checkCancellation()
        return try Fingerprint(version: version, values: [1] + Array(repeating: 0, count: 1023))
    }
}

private actor CoordinatorPhotos: PhotosIndexGateway {
    private let limits: ResourceLimits
    nonisolated let context = LibraryContext(id: UUID(), epoch: 1)
    nonisolated let budget: ImageWorkBudget
    nonisolated let channel = PhotosIndexChangeChannel(capacity: 128)
    private var pages: [RepresentationPage] = []
    private var admission: PhotosReaderAdmission = .available
    private var budgetExhausted = false
    func setBudgetExhausted(_ value: Bool) { budgetExhausted = value }
    private var imageRed: CGFloat = 0
    func setImageRed(_ value: CGFloat) { imageRed = value }
    private var readError: ReadExecutorError?
    private var afterRead: PhotosRepresentationError?
    func setAfterRead(_ error: PhotosRepresentationError?) { afterRead = error }
    func setAdmission(_ value: PhotosReaderAdmission) { admission = value }
    private var admissionCount = 0, admissionGateAt: Int?
    private var admissionGate: CoordinatorGate?
    func gateAdmission(_ number: Int, using gate: CoordinatorGate) { admissionCount = 0; admissionGateAt = number; admissionGate = gate }
    func representationReadAdmission() async -> PhotosReaderAdmission {
        admissionCount += 1
        if admissionCount == admissionGateAt, let gate = admissionGate { admissionGate = nil; await gate.hold() }
        return admission
    }
    func setReadError(_ error: ReadExecutorError?) { readError = error }
    private var readFailures: [String: PhotosRepresentationError] = [:]
    private var callbackFailure: NSError?
    private var callbackFailureKey: RepresentationKey?
    func setCallbackFailure(_ error: NSError?, key: RepresentationKey) { callbackFailure = error; callbackFailureKey = key }
    private var replacementContext: LibraryContext?
    func setReadFailures(_ failures: [String: PhotosRepresentationError]) { readFailures = failures }
    func replaceContext(_ context: LibraryContext, descriptors: [RepresentationDescriptor]) {
        replacementContext = context; generation += 1
        pages = [.init(context: context, generation: generation, descriptors: descriptors, nextOffset: nil)]
    }
    private var generation = 0, failedAsset: String?, conservative = false, resumeSuccess = true, changeOnAck = false
    private(set) var readCount = 0, resumeCount = 0, acknowledgementCount = 0
    private(set) var readAssetIDs: [String] = []
    private(set) var readKinds: [RepresentationKind] = [], requestedLimits: [Int] = []
    private var resumeThrows = false
    private var readGate: CoordinatorGate?
    func gateNextRead(_ gate: CoordinatorGate) { readGate = gate }
    private var snapshotCount = 0, snapshotGateAt: Int?, snapshotGate: CoordinatorGate?
    private(set) var maxImagesObserved = 0
    private var checkpointCaptured = false
    private(set) var checkpointBeforeSnapshot = true
    init(limits: ResourceLimits) { self.limits = limits; budget = ImageWorkBudget(limits: limits) }
    func set(_ descriptors: [RepresentationDescriptor]) {
        generation += 1
        pages = [.init(context: context, generation: generation, descriptors: descriptors, nextOffset: nil)]
    }
    func setPaged(_ descriptors: [RepresentationDescriptor], pageSize: Int) {
        generation += 1
        pages = stride(from: 0, to: descriptors.count, by: pageSize).enumerated().map { index, offset in
            .init(context: context, generation: generation, descriptors: Array(descriptors[offset..<min(descriptors.count, offset + pageSize)]),
                  nextOffset: offset + pageSize < descriptors.count ? index + 1 : nil)
        }
    }
    private var deltaInputUnchanged: [String] = []
    func preserveDeltaInputs(_ ids: [String]) { deltaInputUnchanged = ids }
    private var deltaInvalidations: [String] = []
    func invalidateDelta(_ ids: [String]) { deltaInvalidations = ids }
    func setPages(_ pages: [RepresentationPage]) { self.pages = pages; generation = pages.first?.generation ?? generation }
    func resetReads() { readCount = 0; readKinds = []; requestedLimits = [] }
    func fail(_ asset: String?) { failedAsset = asset }
    func setConservative(_ value: Bool) { conservative = value }
    func throwNextResume() { resumeThrows = true }
    func setResumeSuccess(_ value: Bool) { resumeSuccess = value }
    func changeOnAcknowledgement(_ value: Bool) { changeOnAck = value }
    private var acknowledgementGate: CoordinatorGate?
    func gateNextAcknowledgment(_ gate: CoordinatorGate) { acknowledgementGate = gate }
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
    // This synthetic producer completely controls each descriptor/event interval.
    func coverPersistentHistory(from previous: LibraryResumeCheckpoint, through proposed: LibraryResumeCheckpoint) async throws -> Bool { true }
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
            exclusions: pages.flatMap(\.exclusions).filter { ids.contains($0.descriptor.key.assetID) },
            invalidatedAssetIDs: deltaInvalidations.filter { ids.contains($0) }, inputUnchangedAssetIDs: deltaInputUnchanged.filter { ids.contains($0) })
    }
    func readRepresentation(_ descriptor: RepresentationDescriptor) async throws -> LoadedRepresentation {
        readCount += 1; readKinds.append(descriptor.key.kind); readAssetIDs.append(descriptor.key.assetID)
        if budgetExhausted { throw ImageWorkBudgetError.exhausted }
        if let readError { throw readError }
        if descriptor.key == callbackFailureKey, let callbackFailure {
            let c = try p8Configuration()
            let configuration = try DedupConfiguration(fingerprint: c.fingerprint, policyVersion: c.policyVersion,
                threshold: c.threshold, backend: c.backend, resources: limits,
                evidenceCandidateLimit: c.evidenceCandidateLimit, acceptanceID: c.acceptanceID)
            let reader = PhotosRepresentationReader(requester: CoordinatorFailedRequester(error: callbackFailure),
                budget: budget, configuration: configuration)
            return try await reader.read(descriptor, isCurrent: { true })
        }
        if let error = readFailures[descriptor.key.assetID] { throw error }
        if failedAsset == descriptor.key.assetID { throw PhotoKitGatewayError.libraryUnavailable }
        let lease = try await budget.acquire(bytes: 256)
        let occupied = await budget.snapshot(); maxImagesObserved = max(maxImagesObserved, occupied.images)
        let imageContext = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        imageContext.setFillColor(CGColor(red: imageRed, green: 0, blue: 0, alpha: 1))
        imageContext.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = imageContext.makeImage()!
        if let gate = readGate { readGate = nil; await gate.hold() }
        if let afterRead { await lease.finishPhysicalWork(); throw afterRead }
        return .init(image: image, orientation: .up, descriptor: descriptor, lease: lease,
            eligibility: conservative ? .conservative(.unverifiedContainer) : .safeSingleFrame)
    }
    func acknowledgeReconciliation(expectedGeneration: Int) async throws {
        acknowledgementCount += 1
        if let gate = acknowledgementGate { acknowledgementGate = nil; await gate.hold() }
        if changeOnAck { generation += 1 }
        guard expectedGeneration == generation else { throw PhotoKitGatewayError.libraryChanged }
        channel.reconciled()
    }
    func create(fileURL: URL, kind: MediaKind, expectedGeneration: Int, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String { throw PhotoKitGatewayError.libraryUnavailable }
    func reconcile(placeholder: String?) async throws -> ImportEvidence { .unknown }
}

private struct CoordinatorFailedRequester: PhotosRepresentationRequesting {
    let error: NSError
    func request(_ descriptor: RepresentationDescriptor,
                 completion: @escaping @Sendable (PhotosRepresentationCallback) -> Void) throws -> @Sendable () -> Void {
        completion(.failure(error))
        return {}
    }
}

private final class CoordinatorPhysicalSession: ModelPredictionSession, @unchecked Sendable {
    func predict(_ input: MLMultiArray) throws -> [Float] { [1] + Array(repeating: 0, count: 1023) }
}
private final class CoordinatorPhysicalCount: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class CoordinatorDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[String: String]] = []
    func record(_ row: [String: String]) { lock.lock(); values.append(row); lock.unlock() }
    var rows: [[String: String]] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class DiagnosticClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
