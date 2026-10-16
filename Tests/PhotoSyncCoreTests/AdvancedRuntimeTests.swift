import XCTest
import CoreGraphics
import ImageIO
import CoreML
@testable import PhotoSyncCore

final class AdvancedRuntimeTests: XCTestCase {
    func testIndexReadinessDoesNotBypassUnavailableSourceRecoveryDeadline() async throws {
        let clock = P12Clock()
        let f = try await fixture(taskCount: 40, now: { clock.value })
        let initial = await f.runtime.current()
        let sourceURL = try XCTUnwrap(initial.sources.first?.url)
        let databaseURL = sourceURL.deletingLastPathComponent().appendingPathComponent("test.sqlite")
        try FileManager.default.removeItem(at: sourceURL)
        await f.runtime.tick(force: true); await f.runtime.waitForRound()
        let first = await f.runtime.current()
        XCTAssertEqual(first.snapshot.waitingSources[f.sourceID]?.kind, .sourceAvailability)
        let scanCount = try engineSQLInteger("SELECT COUNT(*) FROM scan_run", at: databaseURL)
        XCTAssertEqual(scanCount, 1)
        for _ in 0..<3 { await f.runtime.tick(); await f.runtime.waitForRound() }
        let ready = await f.runtime.current()
        XCTAssertEqual(ready.snapshot.indexProgress?.state, .ready, "Photos indexing continues while the source is held")
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM scan_run", at: databaseURL), 1,
            "Automatic index readiness must not trigger an early source-root probe")
        clock.advance(5)
        await f.runtime.tick(); await f.runtime.waitForRound()
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM scan_run", at: databaseURL), 2)
    }

    func testIndexReadinessStillProcessesHealthyRootWithOnlyChildDirectoryIssue() async throws {
        let f = try await fixture(taskCount: 40)
        let initial = await f.runtime.current()
        let sourceURL = try XCTUnwrap(initial.sources.first?.url)
        let child = sourceURL.appendingPathComponent("unreadable-child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: child.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: child.path) }
        let media = try sourceFixtureDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: media) }
        try FileManager.default.copyItem(at: media.appendingPathComponent("normal.jpg"), to: sourceURL.appendingPathComponent("healthy.jpg"))
        let databaseURL = sourceURL.deletingLastPathComponent().appendingPathComponent("test.sqlite")
        await f.runtime.tick(force: true); await f.runtime.waitForRound()
        let first = await f.runtime.current()
        XCTAssertEqual(first.snapshot.sourceIssueDetails[f.sourceID]?.first?.path, child.path)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM scan_run", at: databaseURL), 1)
        for _ in 0..<3 { await f.runtime.tick(); await f.runtime.waitForRound() }
        let ready = await f.runtime.current()
        XCTAssertEqual(ready.snapshot.indexProgress?.state, .ready)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM scan_run", at: databaseURL), 2,
            "Child-only errors must retain the healthy root's automatic index-ready kick")
        XCTAssertEqual(ready.snapshot.summary?.pending, 0)
    }

    func testPeriodicTickContinuesFiniteSlicesAndResumesAfterCapacityRelease() async throws {
        let f = try await fixture(taskCount: 40)
        await f.runtime.tick(force: true); await f.runtime.waitForRound()
        let first = await f.runtime.current()
        XCTAssertEqual(first.snapshot.indexProgress?.readyRepresentations, 16)
        let held = try await f.photos.holdBudget()
        for _ in 0..<3 { await f.runtime.tick(); await f.runtime.waitForRound() }
        let waiting = await f.runtime.current()
        XCTAssertEqual(waiting.snapshot.indexProgress?.readyRepresentations, 16)
        XCTAssertEqual(waiting.snapshot.indexProgress?.state, .waiting)
        await f.runtime.pause(); await held.finishPhysicalWork()
        await f.runtime.tick(); await f.runtime.waitForRound()
        let paused = await f.runtime.current(); XCTAssertEqual(paused.snapshot.indexProgress?.readyRepresentations, 16)
        await f.runtime.resume(); await f.runtime.waitForRound()
        await f.runtime.tick(); await f.runtime.waitForRound()
        let ready = await f.runtime.current()
        XCTAssertEqual(ready.snapshot.indexProgress?.state, .ready)
        XCTAssertEqual(ready.snapshot.indexProgress?.readyRepresentations, 40)
        // Source-side ownership of the shared budget cannot turn a completed index into waiting.
        await f.photos.setAdmission(.busy); await f.runtime.tick(); await f.runtime.waitForRound()
        let stillReady = await f.runtime.current(); XCTAssertEqual(stillReady.snapshot.indexProgress?.state, .ready)
    }

    func testPauseCancelsQueuedModelRecoveryWithoutConfigurationError() async throws {
        let f = try await fixture()
        await f.runtime.tick(force: true); await f.runtime.waitForRound()
        let gate = P8Gate(); await f.model.setRecoveryGate(gate)
        let tick = Task { await f.runtime.tick(force: true) }
        await gate.waitUntilEntered(); await f.runtime.pause()
        await gate.release(); await tick.value
        let state = await f.runtime.current()
        XCTAssertTrue(state.snapshot.isPaused); XCTAssertNil(state.message)
        await f.runtime.resume(); await f.runtime.waitForRound()
        let after = await f.runtime.current(); XCTAssertNil(after.message)
    }

    func testModelRetryRespectsDeadlinePauseAndAuthorization() async throws {
        let clock = P12Clock()
        let f = try await fixture(modelUnavailable: true, now: { clock.value })
        await f.runtime.tick(force: true); await f.runtime.waitForRound()
        let waiting = await f.runtime.current()
        XCTAssertNil(waiting.message)
        XCTAssertEqual(waiting.snapshot.indexProgress?.issue, ModelExecutionUnavailable.summary)
        XCTAssertEqual(f.loads.value, 1)
        clock.advance(59); await f.runtime.tick(); await f.runtime.waitForRound(); XCTAssertEqual(f.loads.value, 1)
        clock.advance(1); await f.runtime.tick(); await f.runtime.waitForRound(); XCTAssertEqual(f.loads.value, 2)
        await f.runtime.tick(force: true, retryModel: true); await f.runtime.waitForRound(); XCTAssertEqual(f.loads.value, 3)
        await f.runtime.pause(); clock.advance(60); await f.runtime.tick(force: true); XCTAssertEqual(f.loads.value, 3)
        f.authorization.value = false; await f.runtime.resume(); XCTAssertEqual(f.loads.value, 3)
        f.authorization.value = true; await f.runtime.tick(); await f.runtime.waitForRound(); XCTAssertEqual(f.loads.value, 4)
        try await f.runtime.disable(f.sourceID); clock.advance(60); await f.runtime.tick(force: true); XCTAssertEqual(f.loads.value, 4)
    }

    func testAnalysisStartsAutomaticallyOnlyWhenEligible() async throws {
        let f = try await fixture(authorized: false)
        await f.runtime.tick(force: true)
        XCTAssertEqual(f.loads.value, 0)
        f.authorization.value = true
        await f.runtime.pause()
        await f.runtime.tick(force: true)
        XCTAssertEqual(f.loads.value, 0)
        await f.runtime.resume()
        await f.runtime.waitForRound()
        XCTAssertEqual(f.loads.value, 1)
        let state = await f.runtime.current()
        XCTAssertEqual(state.snapshot.indexProgress?.state, .ready)
        await f.runtime.tick()
        await f.runtime.waitForRound()
        XCTAssertEqual(f.loads.value, 1)
    }

    func testAuthorizationRoundTripRequestsFreshCatalogWithoutPeriodicDeadline() async throws {
        let f = try await fixture()
        await f.runtime.tick(force: true)
        await f.runtime.waitForRound()
        let before = await f.photos.catalogCount
        f.authorization.value = false
        await f.runtime.tick()
        f.authorization.value = true
        await f.runtime.tick()
        await f.runtime.waitForRound()
        let after = await f.photos.catalogCount
        XCTAssertGreaterThan(after, before)
        XCTAssertEqual(f.loads.value, 1)
    }

    func testNoEnabledSourceDoesNotLoadModel() async throws {
        let f = try await fixture()
        try await f.runtime.disable(f.sourceID)
        await f.runtime.tick(force: true)
        XCTAssertEqual(f.loads.value, 0)
    }

    func testContinuousEmptyEventUsesDeltaWithoutForcingFullCatalog() async throws {
        let f = try await fixture()
        await f.runtime.tick(force: true); await f.runtime.waitForRound()
        let before = await f.photos.catalogCount
        let fetched = expectation(description: "runtime requested the bounded delta")
        await f.photos.setDeltaHook { fetched.fulfill() }
        await f.photos.advanceEmptyDelta()
        await fulfillment(of: [fetched], timeout: 3)
        await f.runtime.waitForRound()
        let after = await f.photos.catalogCount
        XCTAssertEqual(after, before)
        let deltas = await f.photos.deltaCount; XCTAssertEqual(deltas, 1)
    }

    func testRealMulticastEventDeliveryWakesReconciliationWithoutTimer() async throws {
        let f = try await fixture()
        await f.runtime.tick(force: true)
        await f.runtime.waitForRound()
        let before = await f.photos.catalogCount
        XCTAssertEqual(f.photos.subscribers.value, 2)
        // A third real-channel observer proves this is multicast rather than a consumed shared stream.
        let events = f.photos.changes()
        let receipt = Task<PhotosIndexChange?, Never> { for await event in events { return event }; return nil }
        await f.photos.change()
        let received = await receipt.value
        XCTAssertEqual(received, fixtureIndexChange(changed: ["edited"]))
        await f.photos.waitForCatalog(after: before)
        await f.runtime.waitForRound()
        let after = await f.photos.catalogCount
        XCTAssertGreaterThan(after, before)
        XCTAssertEqual(f.loads.value, 1)
    }

    func testPauseDuringBackgroundFactoryPreventsAnalysisAndRemainsResponsive() async throws {
        let gate = P8Gate()
        let f = try await fixture(gate: gate)
        await f.runtime.tick(force: true)
        await gate.waitUntilEntered()
        await f.runtime.pause()
        let paused = await f.runtime.current()
        XCTAssertTrue(paused.snapshot.isPaused)
        await gate.release()
        await f.runtime.waitForRound()
        let catalogs = await f.photos.catalogCount
        XCTAssertEqual(catalogs, 0)
        await f.runtime.resume()
        await f.runtime.waitForRound()
        XCTAssertEqual(f.loads.value, 1)
        let ready = await f.runtime.current()
        XCTAssertEqual(ready.snapshot.indexProgress?.state, .ready)
    }

    func testChangeDuringBusyCatalogCoalescesWithoutOverlap() async throws {
        let f = try await fixture(), gate = P8Gate()
        await f.photos.setCatalogGate(gate)
        await f.runtime.tick(force: true)
        await gate.waitUntilEntered()
        await f.photos.change()
        await f.runtime.tick(force: true)
        let maximum = await f.photos.maximumCatalogs
        XCTAssertEqual(maximum, 1)
        await gate.release()
        await f.runtime.waitForRound()
        // A regular tick may consume a late coordinator observer invalidation, but
        // no 30-minute timer or overlapping catalog is required to refresh.
        await f.runtime.tick()
        await f.runtime.waitForRound()
        let state = await f.runtime.current(), maximumAfter = await f.photos.maximumCatalogs
        XCTAssertEqual(state.snapshot.indexProgress?.state, .ready)
        XCTAssertEqual(maximumAfter, 1)
    }

    func testPauseDuringCatalogAllowsCurrentPageButStartsNoNextPage() async throws {
        let f = try await fixture(), gate = P8Gate()
        await f.photos.setCatalogGate(gate, multiplePages: true)
        await f.runtime.tick(force: true)
        await gate.waitUntilEntered()
        await f.runtime.pause()
        await gate.release()
        await f.runtime.waitForRound()
        let count = await f.photos.catalogCount
        XCTAssertEqual(count, 1)
        let state = await f.runtime.current()
        XCTAssertEqual(state.snapshot.indexProgress?.state, .paused)
    }

    func testMissingAndCorruptResourcesStayUnavailableWithoutLegacyFallback() async throws {
        for corrupt in [false, true] {
            let root = try temporaryDirectory()
            if corrupt { try Data("{}".utf8).write(to: root.appendingPathComponent("decision.json")) }
            let f = try await fixture(resourceDirectory: root)
            await f.runtime.tick(force: true)
            await f.runtime.waitForRound()
            let state = await f.runtime.current()
            XCTAssertEqual(state.message, "照片判重配置不可用，同步尚未启动。")
            XCTAssertNotNil(state.messageDetail)
            let creates = await f.photos.createCount
            XCTAssertEqual(creates, 0)
            XCTAssertEqual(state.snapshot.indexProgress?.state, .waiting)
            try FileManager.default.removeItem(at: root)
        }
    }

    func testAnalysisReadyDoesNotEmitExtraNotification() async throws {
        let f = try await fixture()
        await f.runtime.tick(force: true)
        await f.runtime.waitForRound()
        let state = await f.runtime.current()
        XCTAssertEqual(state.snapshot.indexProgress?.state, .ready)
        XCTAssertEqual(f.notifications.value, 0)
    }

    private struct Fixture {
        let runtime: SyncRuntime, photos: P8Photos, sourceID: UUID
        let loads: P8Counter, notifications: P8Counter, authorization: P8Authorization
        let model: P8Model
    }
    private func fixture(taskCount: Int = 0, authorized: Bool = true, gate: P8Gate? = nil, resourceDirectory: URL? = nil, modelUnavailable: Bool = false, now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1000) }) async throws -> Fixture {
        let root = try temporaryDirectory(), source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let executor = ReadExecutor()
        let store = try SyncStore(url: root.appendingPathComponent("test.sqlite"), readExecutor: executor)
        let sourceID = try await store.registerSource(url: source)
        let c = try p8Configuration(), photos = P8Photos(), loads = P8Counter(), notifications = P8Counter(), model = P8Model()
        let auth = P8Authorization(authorized)
        let runtime = SyncRuntime(store: store, executor: executor,
            advancedFactory: { store, executor, directory, now, _ in
                loads.increment()
                if modelUnavailable { throw ModelExecutionUnavailable(detail: "test runtime") }
                if let gate { await gate.hold() }
                if let resourceDirectory {
                    return try await AdvancedRuntimeGraph.load(store: store, executor: executor,
                        directory: directory, now: now, resourceDirectory: resourceDirectory)
                }
                let budget = ImageWorkBudget(limits: c.resources)
                await photos.setWork(taskCount, budget: budget); await model.enableFingerprinting(taskCount > 0, version: c.fingerprint.version)
                return AdvancedRuntimeGraph(store: store, photos: photos,
                    model: model, configuration: c, executor: executor,
                    budget: budget, directory: directory, now: now)
            }, now: now, authorized: { auth.value },
            notificationsEnabled: { true }, notification: { _, _ in notifications.increment() })
        try await runtime.prepareInjectedRuntime()
        addTeardownBlock { await runtime.stop(); await runtime.waitForRound(); try? FileManager.default.removeItem(at: root) }
        return Fixture(runtime: runtime, photos: photos, sourceID: sourceID, loads: loads,
                       notifications: notifications, authorization: auth, model: model)
    }
}

private actor P8Model: ImageFingerprinting, ModelExecutionRecovering {
    private var version: String?
    func enableFingerprinting(_ value: Bool, version: String) { self.version = value ? version : nil }
    private var recoveryGate: P8Gate?
    func setRecoveryGate(_ gate: P8Gate) { recoveryGate = gate }
    func prepareExecution(forceRetry: Bool) async throws {
        if let gate = recoveryGate { recoveryGate = nil; await gate.hold(); try Task.checkCancellation() }
    }
    func fingerprint(image: CGImage, orientation: CGImagePropertyOrientation) async throws -> Fingerprint {
        if let version { return try Fingerprint(version: version, values: [1] + Array(repeating: 0, count: 1023)) }
        XCTFail("Empty catalog must not infer"); throw AdvancedDedupError.invalidImage
    }
}
private actor P8Photos: PhotosIndexGateway {
    private var taskCount = 0, budget: ImageWorkBudget?
    private var admission: PhotosReaderAdmission = .available
    func setAdmission(_ value: PhotosReaderAdmission) { admission = value }
    func representationReadAdmission() async -> PhotosReaderAdmission {
        guard admission == .available, let budget else { return admission }
        return await budget.canAcquire(bytes: reservationBytes) ? .available : .busy
    }
    private var reservationBytes: Int64 = 0
    func holdBudget() async throws -> ImageLease {
        guard let budget else { throw PhotosRepresentationError.unavailable }
        return try await budget.acquire(bytes: reservationBytes)
    }
    func setWork(_ count: Int, budget: ImageWorkBudget) async {
        taskCount = count; self.budget = budget
        reservationBytes = (try? p8Configuration().resources.maxDecodedBytes) ?? 1
    }
    nonisolated let subscribers = P8Counter()
    nonisolated let channel = PhotosIndexChangeChannel(capacity: 8)
    let context = LibraryContext(id: UUID(), epoch: 1)
    private var generation = 1
    private var catalogGate: P8Gate?
    private var multiplePages = false
    private var activeCatalogs = 0
    private(set) var maximumCatalogs = 0
    func setCatalogGate(_ gate: P8Gate, multiplePages: Bool = false) { catalogGate = gate; self.multiplePages = multiplePages }
    private(set) var catalogCount = 0, createCount = 0
    private var catalogWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    nonisolated func changes() -> AsyncStream<PhotosIndexChange> { subscribers.increment(); return channel.stream() }
    func change() { generation += 1; channel.send(fixtureIndexChange(changed: ["edited"])) }
    private var deltaHook: (@Sendable () -> Void)?
    private(set) var deltaCount = 0
    func setDeltaHook(_ hook: @escaping @Sendable () -> Void) { deltaHook = hook }
    func advanceEmptyDelta() {
        let from = generation; generation += 1
        channel.send(.incremental(.init(context: context, fromGeneration: from, toGeneration: generation, changedAssetIDs: [], deletedAssetIDs: [])))
    }
    func representationDelta(_ delta: PhotosIndexDelta) async throws -> RepresentationPage {
        guard delta.context == context, delta.toGeneration == generation else { throw PhotoKitGatewayError.libraryChanged }
        deltaCount += 1; deltaHook?()
        return .init(context: context, generation: generation, descriptors: [], nextOffset: nil)
    }
    func waitForCatalog(after count: Int) async {
        if catalogCount > count { return }
        await withCheckedContinuation { catalogWaiters.append((count, $0)) }
    }
    func candidateSnapshot() async throws -> PhotosCandidateSnapshot { .init(generation: generation, candidates: []) }
    func representationCatalog(offset: Int, limit: Int, expectedGeneration: Int) async throws -> RepresentationPage {
        activeCatalogs += 1; maximumCatalogs = max(maximumCatalogs, activeCatalogs)
        defer { activeCatalogs -= 1 }
        let capturedGeneration = generation
        if let gate = catalogGate { catalogGate = nil; await gate.hold() }
        catalogCount += 1
        let ready = catalogWaiters.filter { catalogCount > $0.0 }
        catalogWaiters.removeAll { catalogCount > $0.0 }; ready.forEach { $0.1.resume() }
        return .init(context: context, generation: capturedGeneration, descriptors: (0..<taskCount).map {
            .init(key: .init(assetID: String(format: "%03d", $0), kind: .original), context: context,
                  revision: "r1", size: try! PixelSize(width: 8, height: 8), equivalentToOriginal: false, revisionIsReliable: true)
        }, nextOffset: multiplePages && offset == 0 ? 1 : nil)
    }
    func readRepresentation(_ descriptor: RepresentationDescriptor) async throws -> LoadedRepresentation {
        guard let budget else { throw PhotosRepresentationError.unavailable }
        let lease = try await budget.acquire(bytes: 256)
        let image = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        return .init(image: image, orientation: .up, descriptor: descriptor, lease: lease, eligibility: .safeSingleFrame)
    }
    func create(fileURL: URL, kind: MediaKind, expectedGeneration: Int, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        createCount += 1; throw PhotosAdmissionDeferred()
    }
    func reconcile(placeholder: String?) async throws -> ImportEvidence { .unknown }
}
private final class P8Counter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
private final class P8Authorization: @unchecked Sendable {
    private let lock = NSLock(); private var granted: Bool
    init(_ granted: Bool) { self.granted = granted }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return granted }
        set { lock.lock(); granted = newValue; lock.unlock() }
    }
}
private actor P8Gate {
    private var entered = false, open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; waiters.forEach { $0.resume() }; waiters = []; if !open { await withCheckedContinuation { blocked = $0 } } }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; blocked?.resume(); blocked = nil }
}

private final class P12Clock: @unchecked Sendable {
    private let lock = NSLock(); private var date = Date(timeIntervalSince1970: 1000)
    var value: Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: Double) { lock.lock(); date.addTimeInterval(seconds); lock.unlock() }
}


// Inject only the physical Core ML boundary; the real actor/serial queue owns every operation.
private final class R2PhysicalProbe: @unchecked Sendable {
    enum Stage { case load, selfTest, prediction }
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stage: Stage?, shouldFail = true, held = false, unavailable = false
    private var loaded: [ModelComputeConfiguration] = [], predicted = 0, active = 0, peak = 0
    func arm(_ stage: Stage, fail: Bool = true) { lock.lock(); self.stage = stage; shouldFail = fail; held = false; lock.unlock() }
    func failAll(_ value: Bool) { lock.lock(); unavailable = value; lock.unlock() }
    var loads: [ModelComputeConfiguration] { lock.lock(); defer { lock.unlock() }; return loaded }
    var predictions: Int { lock.lock(); defer { lock.unlock() }; return predicted }
    var maximumInstances: Int { lock.lock(); defer { lock.unlock() }; return peak }
    private func hold(_ at: Stage) throws {
        lock.lock(); let shouldHold = stage == at && !held; if shouldHold { held = true }; let fail = shouldFail; lock.unlock()
        if shouldHold { entered.signal(); release.wait(); if fail { throw ModelExecutionUnavailable(detail: "controlled physical failure") } }
    }
    func make(_ configuration: FingerprintConfiguration, now: @escaping @Sendable () -> Date = { Date() }) throws -> CoreMLFingerprinter {
        let golden = (0..<4).map { _ in ModelSelfTestCase(input: Data(repeating: 0, count: 3 * configuration.inputSide * configuration.inputSide * 4),
            reference: [1] + Array(repeating: 0, count: 1023)) }
        return try CoreMLFingerprinter(configuration: configuration, selfTests: golden, now: now, factory: { backend in
            self.lock.lock(); self.loaded.append(backend); self.lock.unlock()
            try self.hold(.load)
            self.lock.lock(); self.active += 1; self.peak = max(self.peak, self.active); self.lock.unlock()
            let calls = P8Counter()
            return R2PhysicalSession(predict: { _ in
                calls.increment(); self.lock.lock(); self.predicted += 1; let unavailable = self.unavailable; self.lock.unlock()
                try self.hold(calls.value <= 4 ? .selfTest : .prediction)
                if unavailable { throw ModelExecutionUnavailable(detail: "controlled both unavailable") }
                return [1] + Array(repeating: 0, count: 1023)
            }, released: { self.lock.lock(); self.active -= 1; self.lock.unlock() })
        })
    }
}
private final class R2PhysicalSession: ModelPredictionSession, @unchecked Sendable {
    let prediction: (MLMultiArray) throws -> [Float], released: () -> Void
    init(predict: @escaping (MLMultiArray) throws -> [Float], released: @escaping () -> Void) { prediction = predict; self.released = released }
    func predict(_ tensor: MLMultiArray) throws -> [Float] { try prediction(tensor) }
    deinit { released() }
}
private struct R2RuntimeFixture {
    let runtime: SyncRuntime, model: CoreMLFingerprinter, graph: AdvancedRuntimeGraph
    let store: SyncStore, root: URL, source: UUID, auth: P8Authorization, probe: R2PhysicalProbe
}
extension AdvancedRuntimeTests {
    private func physicalFixture(_ probe: R2PhysicalProbe, clock: P12Clock = P12Clock(), bootstrap: Bool = false) async throws -> R2RuntimeFixture {
        let root = try temporaryDirectory(), sourceRoot = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let store = try SyncStore(url: root.appendingPathComponent("sync.sqlite")), executor = ReadExecutor()
        let source = try await store.registerSource(url: sourceRoot), c = try p8Configuration(), photos = P8Photos()
        let model = try probe.make(c.fingerprint, now: { clock.value }), auth = P8Authorization(true)
        let graph = AdvancedRuntimeGraph(store: store, photos: photos, model: model, configuration: c, executor: executor,
            budget: ImageWorkBudget(limits: c.resources), directory: { DirectoryReader(sourceID: $0, executor: executor) }, now: { clock.value })
        let runtime = SyncRuntime(store: store, executor: executor, advancedFactory: { store, executor, directory, now, _ in
            if bootstrap {
                return try await AdvancedRuntimeGraph.loadInBackground {
                    let candidate = try probe.make(c.fingerprint, now: now)
                    candidate.setExecutionAuthorization { auth.value }
                    try await candidate.prepareExecution()
                    return AdvancedRuntimeGraph(store: store, photos: photos, model: candidate, configuration: c,
                        executor: executor, budget: ImageWorkBudget(limits: c.resources), directory: directory, now: now)
                }
            }
            return graph
        }, now: { clock.value }, authorized: { auth.value })
        try await runtime.prepareInjectedRuntime()
        addTeardownBlock { probe.release.signal(); await runtime.stop(); await runtime.waitForRound(); try? FileManager.default.removeItem(at: root) }
        return .init(runtime: runtime, model: model, graph: graph, store: store, root: sourceRoot, source: source, auth: auth, probe: probe)
    }
    private func physicalImage() -> CGImage {
        CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
    private func makeUnavailable(_ f: R2RuntimeFixture) async throws {
        f.probe.failAll(true)
        do { _ = try await f.model.fingerprint(image: physicalImage(), orientation: .up); XCTFail("both unavailable") }
        catch is ModelExecutionUnavailable { }
        f.probe.failAll(false)
    }
    func testAutomaticForcedScansRespectPhysicalModelDeadlineAndManualRetryIsImmediate() async throws {
        let clock = P12Clock(), probe = R2PhysicalProbe(), f = try await physicalFixture(probe, clock: clock)
        await f.runtime.tick(force: true); await f.runtime.waitForRound()
        try await makeUnavailable(f); XCTAssertEqual(probe.loads.count, 2)
        clock.advance(59)
        // Same entry point as automatic wake and pending-scan follow-up; force is scan urgency.
        await f.runtime.tick(force: true); await f.runtime.waitForRound(); XCTAssertEqual(probe.loads.count, 2)
        clock.advance(1); await f.runtime.tick(); await f.runtime.waitForRound(); XCTAssertEqual(probe.loads.count, 3)
        try await makeUnavailable(f)
        let exhausted = probe.loads.count
        await f.runtime.tick(force: true, retryModel: true); await f.runtime.waitForRound()
        XCTAssertEqual(probe.loads.count, exhausted + 1)
        try await makeUnavailable(f)
        let beforeResume = probe.loads.count
        await f.runtime.pause(); await f.runtime.resume(); await f.runtime.waitForRound()
        XCTAssertEqual(probe.loads.count, beforeResume + 1)
    }
    func testIneligibleManualRequestCannotAuthorizeLaterAutomaticModelReload() async throws {
        let clock = P12Clock(), probe = R2PhysicalProbe(), f = try await physicalFixture(probe, clock: clock)
        await f.runtime.tick(force: true); await f.runtime.waitForRound()
        try await makeUnavailable(f)
        f.auth.value = false
        await f.runtime.tick(force: true, retryModel: true)
        XCTAssertEqual(probe.loads.count, 2)
        f.auth.value = true; clock.advance(59)
        await f.runtime.tick(force: true); await f.runtime.waitForRound()
        XCTAssertEqual(probe.loads.count, 2, "a rejected request is not a future backoff exception")
        clock.advance(1); await f.runtime.tick(); await f.runtime.waitForRound(); XCTAssertEqual(probe.loads.count, 3)
    }
    func testAutomaticForcedStartupCannotBypassPhysicalBackoff() async throws {
        let clock = P12Clock(), probe = R2PhysicalProbe(); probe.failAll(true)
        let f = try await physicalFixture(probe, clock: clock, bootstrap: true)
        await f.runtime.tick(force: true); await f.runtime.waitForRound(); XCTAssertEqual(probe.loads.count, 2)
        clock.advance(59); await f.runtime.tick(force: true); await f.runtime.waitForRound(); XCTAssertEqual(probe.loads.count, 2)
        clock.advance(1); await f.runtime.tick(); await f.runtime.waitForRound(); XCTAssertEqual(probe.loads.count, 4)
        await f.runtime.tick(force: true, retryModel: true); await f.runtime.waitForRound(); XCTAssertEqual(probe.loads.count, 6)
    }
    func testOwnedSourcePredictionCannotFallbackAfterRuntimeEligibilityLoss() async throws {
        for action in ["pause", "disable", "revoke", "stop"] {
            let probe = R2PhysicalProbe(), f = try await physicalFixture(probe)
            await f.runtime.tick(force: true); await f.runtime.waitForRound()
            let url = f.root.appendingPathComponent("new.png")
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, physicalImage(), nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
            let file = SourceFile(sourceID: f.source, relativePath: "new.png", url: url, stamp: try await DirectoryReader().stamp(of: url),
                metadata: try await MetadataReader().read(url: url, filename: "new.png"))
            let id = try await f.store.save(file, decision: .importNew)
            probe.arm(.prediction)
            let prepare = Task { try await f.graph.service.prepare(fileID: id, file: file) }
            XCTAssertEqual(probe.entered.wait(timeout: .now() + 5), .success, action)
            switch action {
            case "pause": await f.runtime.pause()
            case "disable": try await f.runtime.disable(f.source)
            case "revoke": f.auth.value = false // no runtime/UI polling before physical return
            default: await f.runtime.stop()
            }
            let held = await f.graph.budget.snapshot(); XCTAssertEqual(held.images, 1, "retain physical bitmap through return")
            XCTAssertEqual(probe.loads.count, 1)
            probe.release.signal(); _ = try await prepare.value
            XCTAssertEqual(probe.loads.count, 1, action)
            let released = await f.graph.budget.snapshot(); XCTAssertEqual(released.images, 0)
            let record = try await f.store.file(sourceID: f.source, relativePath: "new.png")
            XCTAssertEqual(record?.state, .pending); XCTAssertEqual(record?.retryCount, 0)
            if action != "stop" {
                if action == "disable" { try await f.runtime.enable(f.source) }
                if action == "revoke" { f.auth.value = true }
                await f.runtime.resume(); await f.runtime.waitForRound()
                XCTAssertEqual(probe.loads.count, 2, "eligible recovery retains serial fallback")
            }
            XCTAssertEqual(probe.maximumInstances, 1)
        }
    }
    func testCancelledDetachedStartupRecoversAcrossPauseResumeBeforeOrAfterPhysicalReturn() async throws {
        for earlyResume in [false, true] {
            let probe = R2PhysicalProbe(); probe.arm(.load)
            let f = try await physicalFixture(probe, bootstrap: true)
            await f.runtime.tick(force: true)
            XCTAssertEqual(probe.entered.wait(timeout: .now() + 5), .success)
            await f.runtime.pause()
            if earlyResume { await f.runtime.resume() }
            XCTAssertEqual(probe.loads.count, 1)
            probe.release.signal(); await f.runtime.waitForRound()
            let stopped = await f.runtime.current(); XCTAssertNil(stopped.message)
            if !earlyResume { XCTAssertEqual(probe.loads.count, 1); await f.runtime.resume(); await f.runtime.waitForRound() }
            XCTAssertEqual(probe.loads, [.cpuAndNeuralEngine, .cpuAndNeuralEngine])
            let ready = await f.runtime.current(); XCTAssertEqual(ready.snapshot.indexProgress?.state, .ready); XCTAssertNil(ready.message)
            XCTAssertEqual(probe.maximumInstances, 1)
        }
    }
    func testDetachedBootstrapEligibilityLossStopsFallbackAndAutomaticReload() async throws {
        for action in ["disable", "revoke", "stop"] {
            let probe = R2PhysicalProbe(); probe.arm(.load)
            let f = try await physicalFixture(probe, bootstrap: true)
            await f.runtime.tick(force: true)
            XCTAssertEqual(probe.entered.wait(timeout: .now() + 5), .success)
            switch action {
            case "disable": try await f.runtime.disable(f.source)
            case "revoke": f.auth.value = false // no runtime/UI polling before physical return
            default: await f.runtime.stop()
            }
            probe.release.signal(); await f.runtime.waitForRound()
            XCTAssertEqual(probe.loads.count, 1, action)
            let blocked = await f.runtime.current(); XCTAssertNil(blocked.message)
            await f.runtime.tick(force: true); await f.runtime.waitForRound(); XCTAssertEqual(probe.loads.count, 1)
            if action != "stop" {
                if action == "disable" { try await f.runtime.enable(f.source) }
                if action == "revoke" { f.auth.value = true }
                // Restored eligibility alone does not abandon the startup retry deadline.
                await f.runtime.tick(force: true); await f.runtime.waitForRound(); XCTAssertEqual(probe.loads.count, 1)
                await f.runtime.resume(); await f.runtime.waitForRound()
                XCTAssertEqual(probe.loads, [.cpuAndNeuralEngine, .cpuAndNeuralEngine])
                let recovered = await f.runtime.current(); XCTAssertEqual(recovered.snapshot.indexProgress?.state, .ready)
            }
        }
    }
    func testDetachedBootstrapAlreadyCancelledNeverRunsFactory() async throws {
        let calls = P8Counter(), f = try await fixture()
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AdvancedRuntimeGraph.loadInBackground { calls.increment(); throw CancellationError() }
        }
        do { _ = try await operation.value; XCTFail("cancelled factory") } catch is CancellationError { }
        XCTAssertEqual(calls.value, 0)
        await f.runtime.stop()
    }
}
