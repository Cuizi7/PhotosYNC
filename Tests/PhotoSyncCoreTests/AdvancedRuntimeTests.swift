import XCTest
import CoreGraphics
import ImageIO
@testable import PhotoSyncCore

final class AdvancedRuntimeTests: XCTestCase {
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
    }
    private func fixture(authorized: Bool = true, gate: P8Gate? = nil, resourceDirectory: URL? = nil) async throws -> Fixture {
        let root = try temporaryDirectory(), source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let executor = ReadExecutor()
        let store = try SyncStore(url: root.appendingPathComponent("test.sqlite"), readExecutor: executor)
        let sourceID = try await store.registerSource(url: source)
        let c = try p8Configuration(), photos = P8Photos(), loads = P8Counter(), notifications = P8Counter()
        let auth = P8Authorization(authorized)
        let runtime = SyncRuntime(store: store, executor: executor,
            advancedFactory: { store, executor, directory, now, _ in
                loads.increment()
                if let gate { await gate.hold() }
                if let resourceDirectory {
                    return try await AdvancedRuntimeGraph.load(store: store, executor: executor,
                        directory: directory, now: now, resourceDirectory: resourceDirectory)
                }
                return AdvancedRuntimeGraph(store: store, photos: photos,
                    model: P8Model(), configuration: c, executor: executor,
                    budget: ImageWorkBudget(limits: c.resources), directory: directory, now: now)
            }, now: { Date(timeIntervalSince1970: 1000) }, authorized: { auth.value },
            notificationsEnabled: { true }, notification: { _, _ in notifications.increment() })
        try await runtime.prepareInjectedRuntime()
        addTeardownBlock { await runtime.stop(); await runtime.waitForRound(); try? FileManager.default.removeItem(at: root) }
        return Fixture(runtime: runtime, photos: photos, sourceID: sourceID, loads: loads,
                       notifications: notifications, authorization: auth)
    }
}

private actor P8Model: ImageFingerprinting {
    func fingerprint(image: CGImage, orientation: CGImagePropertyOrientation) async throws -> Fingerprint {
        XCTFail("Empty catalog must not infer"); throw AdvancedDedupError.invalidImage
    }
}
private actor P8Photos: PhotosIndexGateway {
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
        return .init(context: context, generation: capturedGeneration, descriptors: [], nextOffset: multiplePages && offset == 0 ? 1 : nil)
    }
    func readRepresentation(_ descriptor: RepresentationDescriptor) async throws -> LoadedRepresentation { throw PhotosRepresentationError.unavailable }
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
