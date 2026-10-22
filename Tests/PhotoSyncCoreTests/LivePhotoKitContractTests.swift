import XCTest
import Photos
@testable import PhotoSyncCore

final class LivePhotoKitContractTests: XCTestCase {
    func testNewNotificationAfterClassificationMarkerDefersWithoutWaitingAgain() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let raw = expectation(description: "raw"), pending = expectation(description: "read waiting"), finished = expectation(description: "read deferred")
        let gates = LivePhotoNotificationGates(first: expectation(description: "first event"), second: expectation(description: "second event"))
        defer { gates.releaseFirst.signal(); gates.releaseSecond.signal() }
        let requester = ControlledCloudRequester(started: raw), lifecycle = LivePhotoKitLifecycle()
        let gateway = PhotoKitGateway(lifecycle: lifecycle,
            livePhotoRawReader: .init(requester: requester, storage: .init(root: root.appendingPathComponent("raw"))),
            livePhotoResourceIsCurrent: { _ in true }, diagnostics: { fields in
                if fields["phase"] == "live-photo-read", fields["event"] == "classification-pending" { pending.fulfill() }
                if fields["phase"] == "live-photo-stage", fields["stage"] == "classification", fields["result"] == "completed" { gates.injectSecond() }
            })
        gates.gateway = gateway
        let context = try await gateway.livePhotoLibraryContext()
        let task = Task { () -> Error? in
            defer { finished.fulfill() }
            do { _ = try await gateway.readLivePhotoResource(.photos(contextID: context.id, assetID: "target", resourceKey: "original", revision: "r1"), purpose: .inventory, budget: .init()); return nil }
            catch { return error }
        }
        await fulfillment(of: [raw], timeout: 2)
        lifecycle.nextChange = .incremental(removedAssetIDs: [], insertedAssets: [], changedAssets: [])
        lifecycle.changeHook = { gates.classify() }
        gateway.recordLibraryChangeForTesting(); await fulfillment(of: [gates.first], timeout: 2)
        requester.finish(); await fulfillment(of: [pending], timeout: 2)
        gates.releaseFirst.signal()
        await fulfillment(of: [gates.second, finished], timeout: 2)
        gates.releaseSecond.signal()
        let error = await task.value; XCTAssertEqual(error as? LivePhotoReadDeferred, .classificationPending)
        _ = try await gateway.candidateSnapshot()
    }
    func testClassificationWaitTimeoutAndCancellationReleaseCompletedRawLease() async throws {
        for cancelled in [false, true] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let raw = expectation(description: "raw"), entered = expectation(description: "classification"), deadline = expectation(description: "deadline installed"), finished = expectation(description: "logical read finished")
            let release = DispatchSemaphore(value: 0); defer { release.signal() }
            let expiry = InventoryReadGate(), requester = ControlledCloudRequester(started: raw), lifecycle = LivePhotoKitLifecycle()
            lifecycle.initialAssets = [.init(identifier: "target", candidates: [cloudCandidate("target")])]
            let gateway = PhotoKitGateway(lifecycle: lifecycle,
                livePhotoRawReader: .init(requester: requester, storage: .init(root: root.appendingPathComponent("raw"))),
                livePhotoResourceIsCurrent: { _ in true }, classificationSleep: { duration in
                    XCTAssertEqual(duration, .seconds(5)); deadline.fulfill(); await expiry.hold()
                })
            let context = try await gateway.livePhotoLibraryContext(), budget = LivePhotoResourceBudget()
            let task = Task { () -> Result<Data, Error> in
                defer { finished.fulfill() }
                do {
                    let lease = try await gateway.readLivePhotoResource(.photos(contextID: context.id, assetID: "target", resourceKey: "original", revision: "r1"), purpose: .inventory, budget: budget)
                    return .success(try Data(contentsOf: lease.url))
                } catch { return .failure(error) }
            }
            await fulfillment(of: [raw], timeout: 2)
            lifecycle.nextChange = .incremental(removedAssetIDs: [], insertedAssets: [], changedAssets: [])
            lifecycle.changeHook = { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
            gateway.recordLibraryChangeForTesting(); await fulfillment(of: [entered], timeout: 2)
            requester.finish(); await fulfillment(of: [deadline], timeout: 2)
            if cancelled { task.cancel() } else { await expiry.release() }
            await fulfillment(of: [finished], timeout: 2)
            release.signal(); await expiry.release()
            switch await task.value {
            case .success: XCTFail("Timed out/cancelled classification accepted bytes")
            case .failure(let error):
                if cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? LivePhotoReadDeferred, .classificationPending) }
            }
            _ = try await gateway.candidateSnapshot() // late marker cannot resume the completed waiter again
            let freed = await engineEventually { budget.reservedBytes == 0 }; XCTAssertTrue(freed)
        }
    }
    func testPendingClassificationPreventsNewPhysicalRead() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let lifecycle = LivePhotoKitLifecycle(), entered = expectation(description: "classification"), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let requester = BufferedLivePhotoRequester(chunks: [Data([1])], fileExtension: nil)
        let gateway = PhotoKitGateway(lifecycle: lifecycle, livePhotoRawReader: .init(requester: requester, storage: .init(root: root.appendingPathComponent("raw"))), livePhotoResourceIsCurrent: { _ in true })
        let context = try await gateway.livePhotoLibraryContext()
        lifecycle.nextChange = .incremental(removedAssetIDs: [], insertedAssets: [], changedAssets: [])
        lifecycle.changeHook = { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
        gateway.recordLibraryChangeForTesting(); await fulfillment(of: [entered], timeout: 2)
        do {
            _ = try await gateway.readLivePhotoResource(.photos(contextID: context.id, assetID: "target", resourceKey: "original", revision: "r1"), purpose: .inventory, budget: .init())
            XCTFail("Read started with unclassified changes")
        } catch { XCTAssertEqual(error as? LivePhotoReadDeferred, .classificationPending) }
        XCTAssertTrue(requester.networkFlags.isEmpty)
        release.signal(); _ = try await gateway.candidateSnapshot()
    }
    func testCloudReadDiagnosticsBoundDetailAndAggregateBytesWithoutPrivateIDs() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let rows = LivePhotoDiagnosticRows(), diagnostics = IndexDiagnostics(sink: { rows.append($0) })
        let lifecycle = LivePhotoKitLifecycle(), gateway = PhotoKitGateway(lifecycle: lifecycle,
            livePhotoRawReader: .init(requester: BufferedLivePhotoRequester(chunks: [Data([1, 2, 3])], fileExtension: nil), storage: .init(root: root.appendingPathComponent("raw"))),
            livePhotoResourceIsCurrent: { _ in true }, indexDiagnostics: diagnostics)
        let context = try await gateway.livePhotoLibraryContext()
        for _ in 0..<10 {
            let lease = try await gateway.readLivePhotoResource(.photos(contextID: context.id, assetID: "private-asset", resourceKey: "private-name.HEIC", revision: "private-revision"), purpose: .inventory, budget: LivePhotoResourceBudget())
            XCTAssertEqual(try Data(contentsOf: lease.url), Data([1, 2, 3]))
        }
        diagnostics.flushObservations(force: true)
        let values = rows.values
        let summary = try XCTUnwrap(values.last { $0["phase"] == "live-photo-summary" })
        XCTAssertEqual(summary["raw-read.completed"], "10"); XCTAssertEqual(summary["raw-read.bytes"], "30")
        let details = values.filter { $0["phase"] == "live-photo-stage" && $0["stage"] == "raw-read" }
        XCTAssertFalse(details.isEmpty); XCTAssertLessThanOrEqual(details.count, 2)
        XCTAssertTrue(details.allSatisfy { $0["assetHandle"]?.hasPrefix("asset-") == true && $0["elapsedMS"] != nil })
        XCTAssertFalse(String(describing: values).contains("private-"))
    }
    func testCompletionDiagnosticsDistinguishProgressFromNormalNoProgressReturn() async throws {
        let rows = LivePhotoDiagnosticRows(), diagnostics = IndexDiagnostics(sink: { rows.append($0) })
        _ = try await diagnostics.measureLivePhoto(.completion) { false }
        _ = try await diagnostics.measureLivePhoto(.completion) { true }
        diagnostics.flushObservations(force: true)
        let summary = try XCTUnwrap(rows.values.last { $0["phase"] == "live-photo-summary" })
        XCTAssertEqual(summary["completion.no-progress"], "1")
        XCTAssertEqual(summary["completion.advanced"], "1")
        XCTAssertNil(summary["completion.completed"])
    }
    func testRawCompletionDuringClassificationWaitsWithoutDiscardingUnrelatedBytes() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "raw request"), classifying = expectation(description: "classification entered")
        let readReachedFence = expectation(description: "read reached pending fence")
        readReachedFence.assertForOverFulfill = false
        let release = DispatchSemaphore(value: 0); defer { release.signal() }
        let requester = ControlledCloudRequester(started: started), lifecycle = LivePhotoKitLifecycle()
        lifecycle.initialAssets = [.init(identifier: "target", candidates: [cloudCandidate("target")])]
        let gateway = PhotoKitGateway(lifecycle: lifecycle,
            livePhotoRawReader: .init(requester: requester, storage: .init(root: root.appendingPathComponent("raw"))),
            livePhotoResourceIsCurrent: { _ in true }, diagnostics: { fields in
                if fields["phase"] == "live-photo-read", fields["event"] == "classification-pending" { readReachedFence.fulfill() }
            })
        _ = try await gateway.candidateSnapshot()
        let context = try await gateway.livePhotoLibraryContext(), budget = LivePhotoResourceBudget()
        let task = Task {
            do {
                let lease = try await gateway.readLivePhotoResource(.photos(contextID: context.id, assetID: "target", resourceKey: "original", revision: "r1"), purpose: .inventory, budget: budget)
                return try Data(contentsOf: lease.url)
            } catch { readReachedFence.fulfill(); throw error }
        }
        await fulfillment(of: [started], timeout: 2)
        lifecycle.nextChange = .incremental(removedAssetIDs: [], insertedAssets: [.init(identifier: "other", candidates: [cloudCandidate("other")])], changedAssets: [])
        lifecycle.changeHook = { classifying.fulfill(); _ = release.wait(timeout: .now() + 5) }
        gateway.recordLibraryChangeForTesting()
        await fulfillment(of: [classifying], timeout: 2)
        requester.finish()
        await fulfillment(of: [readReachedFence], timeout: 2)
        release.signal()
        let data = try await task.value
        XCTAssertEqual(data, Data([1, 2, 3]))
        let freed = await engineEventually { budget.reservedBytes == 0 }; XCTAssertTrue(freed)
    }
    func testUnknownCoverageWhileInspectingCannotSaveIdentityObservation() async throws {
        let f = try await inventoryFixture(count: 1); defer { try? FileManager.default.removeItem(at: f.root) }
        let started = expectation(description: "raw read"), requester = ControlledCloudRequester(started: started)
        let lifecycle = LivePhotoKitLifecycle()
        lifecycle.initialAssets = [.init(identifier: "asset-0", candidates: [cloudCandidate("asset-0")])]
        let gateway = PhotoKitGateway(lifecycle: lifecycle, livePhotoRawReader: .init(requester: requester, storage: .init(root: f.root.appendingPathComponent("raw"))), livePhotoResourceIsCurrent: { _ in true })
        try await gateway.restoreInventoryContext(f.photos.context); _ = try await gateway.candidateSnapshot()
        await f.photos.useNativeRead { ref, purpose, budget in try await gateway.readLivePhotoResource(ref, purpose: purpose, budget: budget) }
        let c = LivePhotoInventoryCoordinator(store: f.store, photos: f.photos, metadata: MutatingInventoryMetadata {
            gateway.invalidateObservationContinuity(); _ = try await gateway.candidateSnapshot()
        })
        try await c.resumeInitialInventory()
        let task = Task { try await c.processNextInventoryItem(now: Date()) }
        await fulfillment(of: [started], timeout: 2); requester.finish()
        do { _ = try await task.value; XCTFail("Unknown coverage accepted during metadata inspection") } catch { }
        let summary = try await c.summary(); XCTAssertEqual(summary.identified, 0); XCTAssertEqual(summary.pending, 1)
    }
    func testCloudResourceReadAcceptsUnrelatedChangesAndRejectsInvalidation() async throws {
        for mode in ["unrelated", "neutral-target", "revision-neutral", "target", "deleted", "unknown", "revision", "permission"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let started = expectation(description: "read " + mode)
            let requester = ControlledCloudRequester(started: started)
            let lifecycle = LivePhotoKitLifecycle(), validity = CloudResourceValidity()
            lifecycle.initialAssets = [.init(identifier: "target", candidates: [cloudCandidate("target")])]
            let reader = LivePhotoRawResourceReader(requester: requester, storage: .init(root: root.appendingPathComponent("raw")))
            let gateway = PhotoKitGateway(lifecycle: lifecycle, livePhotoRawReader: reader, livePhotoResourceIsCurrent: { _ in validity.current })
            _ = try await gateway.candidateSnapshot()
            let context = try await gateway.livePhotoLibraryContext()
            let ref = LivePhotoResourceRef.photos(contextID: context.id, assetID: "target", resourceKey: "original", revision: "r1")
            let budget = LivePhotoResourceBudget()
            let task = Task {
                let lease = try await gateway.readLivePhotoResource(ref, purpose: .inventory, budget: budget)
                return try Data(contentsOf: lease.url)
            }
            await fulfillment(of: [started], timeout: 2)
            if mode == "permission" { lifecycle.access = .denied }
            else if mode == "revision" { validity.invalidate() }
            else {
                if mode == "unrelated" { lifecycle.nextChange = .incremental(removedAssetIDs: [], insertedAssets: [.init(identifier: "other", candidates: [cloudCandidate("other")])], changedAssets: []) }
                if mode == "target" { lifecycle.nextChange = .incremental(removedAssetIDs: [], insertedAssets: [], changedAssets: [.init(identifier: "target", candidates: [cloudCandidate("target")])]) }
                if mode == "neutral-target" || mode == "revision-neutral" {
                    lifecycle.nextChange = .incremental(removedAssetIDs: [], insertedAssets: [], changedAssets: [.init(identifier: "target", candidates: [cloudCandidate("target")], inputUnchanged: true)])
                    if mode == "revision-neutral" { validity.invalidate() }
                }
                if mode == "deleted" { lifecycle.nextChange = .incremental(removedAssetIDs: ["target"], insertedAssets: [], changedAssets: []) }
                gateway.recordLibraryChangeForTesting()
                _ = try await gateway.candidateSnapshot()
            }
            requester.finish()
            if mode == "unrelated" || mode == "neutral-target" {
                let bytes = try await task.value
                XCTAssertEqual(bytes, Data([1,2,3]))
            } else {
                do { _ = try await task.value; XCTFail("Accepted " + mode) } catch { }
            }
            let released = await engineEventually { budget.reservedBytes == 0 }; XCTAssertTrue(released, mode)
        }
    }
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

private final class LivePhotoDiagnosticRows: @unchecked Sendable {
    private let lock = NSLock()
    private var rows = [[String: String]]()
    var values: [[String: String]] { lock.lock(); defer { lock.unlock() }; return rows }
    func append(_ fields: [String: String]) { lock.lock(); rows.append(fields); lock.unlock() }
}
private final class LivePhotoNotificationGates: @unchecked Sendable {
    let first: XCTestExpectation, second: XCTestExpectation
    let releaseFirst = DispatchSemaphore(value: 0), releaseSecond = DispatchSemaphore(value: 0)
    weak var gateway: PhotoKitGateway?
    private let lock = NSLock()
    private var count = 0, injected = false
    init(first: XCTestExpectation, second: XCTestExpectation) { self.first = first; self.second = second }
    func classify() {
        lock.lock(); count += 1; let initial = count == 1; lock.unlock()
        (initial ? first : second).fulfill()
        _ = (initial ? releaseFirst : releaseSecond).wait(timeout: .now() + 5)
    }
    func injectSecond() {
        lock.lock(); let shouldInject = !injected; injected = true; lock.unlock()
        if shouldInject { gateway?.recordLibraryChangeForTesting() }
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
    var access: PhotoKitAccess = .authorized
    var initialAssets: [PhotoKitCandidateAsset] = []
    var nextChange: PhotoKitCandidateIndexChange = .reload
    var changeHook: (@Sendable () -> Void)?
    func currentAccess() -> PhotoKitAccess { access }
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
        return initialAssets
    }
    func candidateIndexChange(for change: PHChange?) throws -> PhotoKitCandidateIndexChange { changeHook?(); return nextChange }
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

private final class CloudResourceValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var current: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func invalidate() { lock.lock(); valid = false; lock.unlock() }
}

private func cloudCandidate(_ key: String) -> MatchCandidate {
    MatchCandidate(key: key, metadata: MediaMetadata(filename: "fixture.jpg", kind: .image, captureSecond: nil, rawCaptureTime: nil, make: nil, model: nil, width: nil, height: nil, duration: nil))
}
