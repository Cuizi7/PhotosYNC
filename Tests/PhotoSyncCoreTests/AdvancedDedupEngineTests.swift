import XCTest
import ImageIO
@testable import PhotoSyncCore

final class AdvancedDedupEngineTests: XCTestCase {
    func testReopenedLegacySkipReturnsToNormalAdvancedDrain() async throws {
        let f = try await fixture()
        await f.engine.scanEnabledSources()
        let optional = try await f.store.file(sourceID: f.source, relativePath: "a.png")
        let record = try XCTUnwrap(optional)
        try await f.store.markSkipped(fileID: record.id, reason: .suspectedDuplicate, candidates: [])
        let worker = LegacySkipReevaluation(store: f.store,
            stamp: { try await DirectoryReader(sourceID: $0.sourceID).stamp(of: $0.url) },
            policyVersion: f.configuration.policyVersion, retryDelaysSeconds: f.configuration.resources.retryDelaysSeconds)
        let reopened = try await worker.processBatch(limit: f.configuration.resources.catalogBatchSize)
        XCTAssertEqual(reopened, 1)
        let before = await f.photos.createCount; XCTAssertEqual(before, 0)
        try await ready(f)
        await f.engine.scanEnabledSources()
        let imported = try await f.store.file(sourceID: f.source, relativePath: "a.png")
        let after = await f.photos.createCount
        XCTAssertEqual(imported?.state, .imported); XCTAssertEqual(after, 1)
    }

    func testInitialIndexBlocksCreateButAllowsScanPreparation() async throws {
        let f = try await fixture()
        await f.engine.scanEnabledSources()
        let row = try await f.store.file(sourceID: f.source, relativePath: "a.png")
        let count = await f.photos.createCount
        XCTAssertEqual(row?.state, .pending)
        XCTAssertNil(row?.successID)
        XCTAssertEqual(count, 0)
        let snapshot = await f.engine.snapshot()
        XCTAssertTrue(snapshot.deferredSources.contains(f.source))
    }

    func testSameFilenameDoesNotSkipBeforeAdvancedPreparation() async throws {
        let f = try await fixture()
        let metadata = try await MetadataReader().read(url: f.root.appendingPathComponent("a.png"), filename: "a.png")
        await f.photos.setCandidates([MatchCandidate(key: "same-name", metadata: metadata)])
        await f.engine.scanEnabledSources()
        let row = try await f.store.file(sourceID: f.source, relativePath: "a.png")
        let count = await f.photos.createCount
        XCTAssertEqual(row?.state, .pending); XCTAssertNil(row?.successID); XCTAssertEqual(count, 0)
    }

    func testOwnSuccessParticipatesBeforePhotosNotification() async throws {
        let f = try await fixture(second: true)
        try await f.coordinator.reconcile()
        await f.coordinator.processDueWork(now: Date())
        await f.engine.scanEnabledSources()
        let a = try await f.store.file(sourceID: f.source, relativePath: "a.png")
        let b = try await f.store.file(sourceID: f.source, relativePath: "b.png")
        let count = await f.photos.createCount
        XCTAssertEqual(a?.state, .imported)
        XCTAssertEqual(a?.successID, "created-1")
        XCTAssertEqual(b?.state, .skipped)
        XCTAssertNil(b?.successID)
        XCTAssertEqual(count, 1)
    }

    func testPauseOrSourceDisableAfterInferenceStopsNewSubmit() async throws {
        for disable in [false, true] {
            let f = try await fixture(); try await ready(f)
            let gate = EngineBoundaryGate(); await f.model.setGate(gate)
            let scan = Task { await f.engine.scanEnabledSources() }
            await gate.waitUntilEntered()
            if disable { try await f.engine.disableSource(id: f.source) }
            else { await f.engine.pause() }
            await gate.release(); await scan.value
            let row = try await f.store.file(sourceID: f.source, relativePath: "a.png")
            let count = await f.photos.createCount
            XCTAssertEqual(count, 0); XCTAssertEqual(row?.state, .pending); XCTAssertNil(row?.successID)
        }
    }

    func testChangesAfterBeginAttemptBeforeMutationPreventCreate() async throws {
        for change in ["pause", "disable", "stamp", "photos", "receipt"] {
            let f = try await fixture(); try await ready(f)
            let gate = EngineBoundaryGate(); await f.photos.setBeforeGate(gate)
            let scan = Task { await f.engine.scanEnabledSources() }
            await gate.waitUntilEntered()
            let intent = try await f.store.file(sourceID: f.source, relativePath: "a.png")
            XCTAssertEqual(intent?.state, .importing, change)
            switch change {
            case "pause": await f.engine.pause()
            case "disable": try await f.engine.disableSource(id: f.source)
            case "stamp": try Data([1, 2, 3]).write(to: f.root.appendingPathComponent("a.png"))
            case "photos": await f.photos.change()
            default:
                let other = f.root.deletingLastPathComponent().appendingPathComponent("other-source")
                try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
                _ = try await f.store.registerSource(url: other)
            }
            await gate.release(); await scan.value
            let row = try await f.store.file(sourceID: f.source, relativePath: "a.png")
            let count = await f.photos.createCount
            XCTAssertEqual(count, 0, change); XCTAssertEqual(row?.state, .pending, change); XCTAssertNil(row?.successID, change)
            XCTAssertEqual(row?.retryCount, 0, change)
            let snapshot = await f.engine.snapshot()
            XCTAssertNil(snapshot.blockingError, "A prevented mutation is known not sent: \(change)")
            XCTAssertEqual(snapshot.summary?.retryPending, 0, change)
            XCTAssertTrue(snapshot.waitingSources.isEmpty, change)
            if change == "photos" || change == "receipt" {
                XCTAssertEqual(snapshot.latestScan.failed, 0, "Invalidated admission is waiting, not a file failure")
                XCTAssertTrue(snapshot.deferredSources.contains(f.source))
                XCTAssertNotNil(snapshot.advancedWaitingReasons[f.source])
                f.photos.validity.restore()
                f.clock.advance(6)
                await f.engine.scanEnabledSources()
                let recovered = try await f.store.file(sourceID: f.source, relativePath: "a.png")
                let recoveredCount = await f.photos.createCount
                XCTAssertEqual(recovered?.state, .imported, change)
                XCTAssertEqual(recoveredCount, 1, change)
            }
        }
    }

    func testThirdPartyChangeAtBeginAdvancedAttemptPreventsCreate() async throws {
        let f = try await fixture(); try await ready(f)
        // prepare's final validity is check 1; the atomic begin gate is check 2.
        f.photos.validity.invalidate(onCheck: 2)
        await f.engine.scanEnabledSources()
        let count = await f.photos.createCount
        let row = try await f.store.file(sourceID: f.source, relativePath: "a.png")
        XCTAssertEqual(count, 0); XCTAssertEqual(row?.state, .pending); XCTAssertNil(row?.attemptID)
    }

    func testLateSuccessAfterIndexInvalidationStillPersists() async throws {
        let f = try await fixture(); try await ready(f)
        let gate = EngineBoundaryGate(); await f.photos.setAfterGate(gate)
        let scan = Task { await f.engine.scanEnabledSources() }
        await gate.waitUntilEntered()
        await f.photos.change(); await f.engine.pause()
        await gate.release(); await scan.value
        let row = try await f.store.file(sourceID: f.source, relativePath: "a.png")
        let count = await f.photos.createCount
        XCTAssertEqual(count, 1); XCTAssertEqual(row?.state, .imported); XCTAssertEqual(row?.successID, "created-1")
    }

    func testUnknownSubmitStaysImportingAndBlocksNextFile() async throws {
        let f = try await fixture(second: true); try await ready(f)
        await f.photos.setUnknown()
        await f.engine.scanEnabledSources(); await f.engine.scanEnabledSources()
        let count = await f.photos.createCount
        let row = try await f.store.file(sourceID: f.source, relativePath: "a.png")
        XCTAssertEqual(count, 1); XCTAssertEqual(row?.state, .importing); XCTAssertNil(row?.successID)
        let snapshot = await f.engine.snapshot(); XCTAssertNotNil(snapshot.blockingError)
        let unknown = try XCTUnwrap(row)
        do {
            try await f.store.deferAdvancedAttempt(fileID: unknown.id, attemptID: XCTUnwrap(unknown.attemptID), nextRetry: f.clock.now)
            XCTFail("Unknown attempt must not be restored as unsubmitted")
        } catch SyncStoreError.invalidTransition {}
        let retained = try await f.store.file(sourceID: f.source, relativePath: "a.png")
        XCTAssertEqual(retained?.state, .importing); XCTAssertEqual(retained?.attemptID, unknown.attemptID)
    }

    func testDeferralCleanupRejectsMismatchedAndSuccessfulAttempt() async throws {
        let f = try await fixture(); try await ready(f)
        let gate = EngineBoundaryGate(); await f.photos.setBeforeGate(gate)
        let scan = Task { await f.engine.scanEnabledSources() }
        await gate.waitUntilEntered()
        let storedIntent = try await f.store.file(sourceID: f.source, relativePath: "a.png")
        let intent = try XCTUnwrap(storedIntent)
        let attempt = try XCTUnwrap(intent.attemptID)
        do {
            try await f.store.deferAdvancedAttempt(fileID: intent.id, attemptID: UUID(), nextRetry: f.clock.now)
            XCTFail("Unrelated attempt cannot be restored")
        } catch SyncStoreError.invalidTransition {}
        await gate.release(); await scan.value
        do {
            try await f.store.deferAdvancedAttempt(fileID: intent.id, attemptID: attempt, nextRetry: f.clock.now)
            XCTFail("Successful attempt cannot be restored")
        } catch SyncStoreError.invalidTransition {}
        let row = try await f.store.file(sourceID: f.source, relativePath: "a.png")
        XCTAssertEqual(row?.state, .imported); XCTAssertEqual(row?.successID, "created-1")
    }

    func testMissingRequiredGraphCannotFallBackToFilenameImport() async throws {
        let f = try await fixture()
        let engine = SyncEngine(store: f.store, photos: f.photos, requiresAdvancedDedup: true)
        await engine.scanEnabledSources()
        let count = await f.photos.createCount
        let row = try await f.store.file(sourceID: f.source, relativePath: "a.png")
        XCTAssertEqual(count, 0); XCTAssertEqual(row?.state, .pending)
    }

    func testConservativeMultiframePersistsSuccessWithoutFingerprint() async throws {
        let f = try await fixture(); try await ready(f)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("a.png"))
        try writeImage(f.root.appendingPathComponent("animated.gif"), type: "com.compuserve.gif", frames: 2)
        await f.engine.scanEnabledSources()
        let row = try await f.store.file(sourceID: f.source, relativePath: "animated.gif")
        let count = await f.photos.createCount
        XCTAssertEqual(count, 1); XCTAssertEqual(row?.state, .imported); XCTAssertEqual(row?.successID, "created-1")
        let local = try await f.store.localVectorCandidates(beforeOrder: Int64.max, excluding: UUID(), version: f.model.vector.version)
        XCTAssertTrue(local.entries.isEmpty)
    }

    func testVideoKeepsLegacyMatchingWhileIndexUnready() async throws {
        let f = try await fixture()
        let url = f.root.appendingPathComponent("movie.mov")
        try Data([1]).write(to: url)
        let file = SourceFile(sourceID: f.source, relativePath: "movie.mov", url: url,
            stamp: try await DirectoryReader().stamp(of: url), metadata: MediaMetadata(filename: "movie.mov", kind: .video,
                captureSecond: nil, rawCaptureTime: nil, make: nil, model: nil, width: nil, height: nil, duration: nil))
        _ = try await f.store.save(file, decision: .importNew)
        await f.photos.setCandidates([MatchCandidate(key: "video", metadata: file.metadata)])
        await f.engine.scanEnabledSources()
        let row = try await f.store.file(sourceID: f.source, relativePath: "movie.mov")
        let count = await f.photos.createCount
        XCTAssertEqual(row?.state, .skipped); XCTAssertEqual(count, 0)
    }

    func testTemporaryBudgetOccupancyDoesNotStarveCachedPendingFile() async throws {
        let f = try await fixture(second: true)
        let url = f.root.appendingPathComponent("b.png")
        let file = SourceFile(sourceID: f.source, relativePath: "b.png", url: url,
            stamp: try await DirectoryReader().stamp(of: url), metadata: try await MetadataReader().read(url: url, filename: "b.png"))
        let id = try await f.store.save(file, decision: .importNew)
        let cached = try await f.store.cacheFingerprint(.init(fileID: id, file: file,
            fingerprint: f.model.vector, size: try PixelSize(width: 2, height: 2)))
        XCTAssertTrue(cached)
        try await ready(f)
        let lease = try await f.budget.acquire(bytes: f.configuration.resources.maxDecodedBytes)
        await f.engine.scanEnabledSources()
        await lease.finishPhysicalWork()
        let a = try await f.store.file(sourceID: f.source, relativePath: "a.png")
        let b = try await f.store.file(sourceID: f.source, relativePath: "b.png")
        let count = await f.photos.createCount
        XCTAssertEqual(a?.state, .pending); XCTAssertNil(a?.successID)
        XCTAssertEqual(b?.state, .imported); XCTAssertEqual(count, 1)
        let snapshot = await f.engine.snapshot()
        XCTAssertEqual(snapshot.latestScan.failed, 0)
        XCTAssertNotNil(snapshot.advancedWaitingReasons[f.source])
    }
    func testOversizeReadableSourceImportsOriginalWithoutSuccessVector() async throws {
        let f = try await fixture(maximumDecodedBytes: 800_000)
        try writeImage(f.root.appendingPathComponent("a.png"), width: 640, height: 320)
        try await ready(f)
        await f.engine.scanEnabledSources()
        let a = try await f.store.file(sourceID: f.source, relativePath: "a.png")
        let count = await f.photos.createCount
        XCTAssertEqual(a?.state, .imported); XCTAssertNotNil(a?.successID); XCTAssertEqual(count, 1)
        let vectors = try await f.store.localVectorCandidates(beforeOrder: Int64.max, excluding: UUID(), version: f.model.vector.version)
        XCTAssertTrue(vectors.entries.isEmpty)
        let inferenceCount = await f.model.count; XCTAssertEqual(inferenceCount, 0)
        let snapshot = await f.engine.snapshot()
        XCTAssertEqual(snapshot.latestScan.failed, 0)
        XCTAssertNil(snapshot.advancedWaitingReasons[f.source])
    }

    private func ready(_ f: Fixture) async throws {
        try await f.coordinator.reconcile(); await f.coordinator.processDueWork(now: Date())
    }

    private struct Fixture {
        let engine: SyncEngine; let store: SyncStore; let photos: EngineIndexPhotos
        let coordinator: PhotosIndexCoordinator; let model: EngineIndexModel; let budget: ImageWorkBudget; let configuration: DedupConfiguration; let source: UUID; let root: URL; let clock: EngineIndexClock
    }
    private func fixture(second: Bool = false, maximumDecodedBytes: Int64? = nil) async throws -> Fixture {
        let root = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try writeImage(sourceURL.appendingPathComponent("a.png"))
        if second { try writeImage(sourceURL.appendingPathComponent("b.png")) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var c = try JSONDecoder().decode(DedupConfiguration.self, from: Data(contentsOf: repository.appendingPathComponent("docs/research/advanced-dedup/integration-profile.json")))
        if let maximumDecodedBytes {
            let r = c.resources
            let limits = try ResourceLimits(decodeConcurrency: r.decodeConcurrency, photoRequestConcurrency: r.photoRequestConcurrency,
                maxDecodedBytes: maximumDecodedBytes, requestTimeoutSeconds: r.requestTimeoutSeconds,
                retryDelaysSeconds: r.retryDelaysSeconds, catalogBatchSize: r.catalogBatchSize,
                maxInFlightTasks: r.maxInFlightTasks, progressPublishIntervalSeconds: r.progressPublishIntervalSeconds,
                inferenceConcurrency: r.inferenceConcurrency, batchSize: r.batchSize)
            c = try DedupConfiguration(fingerprint: c.fingerprint, policyVersion: c.policyVersion, threshold: c.threshold,
                backend: c.backend, resources: limits, evidenceCandidateLimit: c.evidenceCandidateLimit, acceptanceID: c.acceptanceID)
        }
        let store = try SyncStore(url: root.appendingPathComponent("test.sqlite"))
        let source = try await store.registerSource(url: sourceURL)
        let photos = EngineIndexPhotos()
        var values = [Float](repeating: 0, count: 1024); values[0] = 1
        let model = EngineIndexModel(vector: try Fingerprint(version: c.fingerprint.version, values: values))
        let index = ExactVectorIndex(version: c.fingerprint.version)
        let coordinator = PhotosIndexCoordinator(store: store, photos: photos, fingerprinter: model, index: index, configuration: c)
        let budget = ImageWorkBudget(limits: c.resources)
        let service = AdvancedDedupService(store: store, photos: photos, coordinator: coordinator, fingerprinter: model,
            index: index, configuration: c, executor: ReadExecutor(maxConcurrentOperations: c.resources.maxInFlightTasks), budget: budget)
        let clock = EngineIndexClock()
        let engine = SyncEngine(store: store, photos: photos, advancedDedup: service, indexCoordinator: coordinator, requiresAdvancedDedup: true, now: { clock.now })
        return Fixture(engine: engine, store: store, photos: photos, coordinator: coordinator, model: model, budget: budget, configuration: c, source: source, root: sourceURL, clock: clock)
    }
    private func writeImage(_ url: URL, type: String = "public.png", frames: Int = 1, width: Int = 2, height: Int = 2) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, frames, nil))
        for _ in 0..<frames { CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

private actor EngineIndexModel: ImageFingerprinting {
    let vector: Fingerprint
    private var gate: EngineBoundaryGate?
    private(set) var count = 0
    init(vector: Fingerprint) { self.vector = vector }
    func setGate(_ gate: EngineBoundaryGate) { self.gate = gate }
    func fingerprint(image: CGImage, orientation: CGImagePropertyOrientation) async throws -> Fingerprint {
        count += 1; if let gate { await gate.hold() }; return vector
    }
}
private actor EngineIndexPhotos: PhotosIndexGateway {
    nonisolated let context = LibraryContext(id: UUID(), epoch: 1)
    nonisolated let validity = EngineIndexValidity()
    private(set) var createCount = 0
    private var beforeGate: EngineBoundaryGate?, afterGate: EngineBoundaryGate?
    private var unknown = false
    private var candidates: [MatchCandidate] = []
    func setBeforeGate(_ gate: EngineBoundaryGate) { beforeGate = gate }
    func setAfterGate(_ gate: EngineBoundaryGate) { afterGate = gate }
    func setUnknown() { unknown = true }
    func setCandidates(_ values: [MatchCandidate]) { candidates = values }
    func change() { validity.invalidate() }
    func candidateSnapshot() async throws -> PhotosCandidateSnapshot { .init(generation: 1, candidates: candidates, validity: validity) }
    nonisolated func changes() -> AsyncStream<PhotosIndexChange> { AsyncStream { _ in } }
    func representationCatalog(offset: Int, limit: Int, expectedGeneration: Int) async throws -> RepresentationPage {
        .init(context: context, generation: 1, descriptors: [], nextOffset: nil)
    }
    func readRepresentation(_ descriptor: RepresentationDescriptor) async throws -> LoadedRepresentation { throw PhotoKitGatewayError.libraryUnavailable }
    func create(fileURL: URL, kind: MediaKind, expectedGeneration: Int, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        createCount += 1; let id = "created-\(createCount)"; try onPlaceholder(id)
        if let afterGate { await afterGate.hold() }
        if unknown { throw PhotoKitGatewayError.resultUnknown("Controlled unknown outcome") }
        return id
    }
    func create(fileURL: URL, kind: MediaKind, expectedGeneration: Int,
                beforeMutation: @escaping @Sendable () throws -> Bool,
                onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        if let beforeGate { await beforeGate.hold() }
        guard try beforeMutation() else { throw PhotosAdmissionDeferred() }
        return try await create(fileURL: fileURL, kind: kind, expectedGeneration: expectedGeneration, onPlaceholder: onPlaceholder)
    }
    func reconcile(placeholder: String?) async throws -> ImportEvidence { .unknown }
}

private actor EngineBoundaryGate {
    private var entered = false, open = false
    private var listeners: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true; listeners.forEach { $0.resume() }; listeners = []
        if !open { await withCheckedContinuation { blocked = $0 } }
    }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { listeners.append($0) } } }
    func release() { open = true; blocked?.resume(); blocked = nil }
}
private final class EngineIndexValidity: PhotosCandidateValidity, @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true, checks = 0
    private var invalidCheck: Int?
    func invalidate() { lock.lock(); valid = false; lock.unlock() }
    func restore() { lock.lock(); valid = true; invalidCheck = nil; lock.unlock() }
    func invalidate(onCheck count: Int) { lock.lock(); invalidCheck = count; checks = 0; lock.unlock() }
    func commitIfCurrent(_ commit: @escaping @Sendable () throws -> Void) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        checks += 1
        if checks == invalidCheck { valid = false }
        guard valid else { return false }
        try commit(); return true
    }
}

private final class EngineIndexClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
}
