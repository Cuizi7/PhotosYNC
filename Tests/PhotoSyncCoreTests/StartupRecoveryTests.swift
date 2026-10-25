import XCTest
import CoreGraphics
import ImageIO
@testable import PhotoSyncCore

/// Runs the actual bootstrap/graph/store, replacing only the operating-system
/// boundaries. Child invocations use the same test bundle, not a second runtime.
final class StartupRecoveryTests: XCTestCase {
    func testLockAfterConfigurationValidationUsesDatabaseRecoveryNotConfigurationFailure() async throws {
        let root = try PortableRuntimeSession.create(), clock = P12Clock(), gate = PortableRuntimeGate()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await PortableRuntimeSession(root: root, count: 0, configurationGate: gate, now: { clock.value })
        try await session.addSourceVideo()
        let start = Task { await session.runtime.bootstrap() }
        await gate.waitForArrival()
        let lock = try FixtureDatabaseLock(url: root.appendingPathComponent("sync.sqlite"))
        await gate.release(); await start.value
        let waiting = await session.runtime.current()
        XCTAssertNil(waiting.message, "A validated model is not invalid because the following DB transaction is busy")
        lock.release(); clock.advance(6)
        await session.runtime.tick(); await session.runtime.waitForRound()
        let recovered = await session.runtime.current(), creates = await session.photos.creates
        XCTAssertEqual(creates, 1); XCTAssertNil(recovered.message)
        XCTAssertFalse(recovered.snapshot.storageRetryPending)
        await session.runtime.stop(); await session.runtime.waitForRound(); session.events.flushLog()
    }

    func testBootstrapLockRecoversOnPeriodicTickInSameRuntime() async throws {
        let root = try PortableRuntimeSession.create(), clock = P12Clock()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await PortableRuntimeSession(root: root, count: 0, now: { clock.value })
        try await session.addSourceVideo()
        let lock = try FixtureDatabaseLock(url: root.appendingPathComponent("sync.sqlite"))
        await session.runtime.bootstrap()
        let waiting = await session.runtime.current()
        XCTAssertTrue(waiting.snapshot.storageRetryPending)
        XCTAssertNil(waiting.message, "Typed busy is an automatic startup wait")
        lock.release(); clock.advance(6)
        await session.runtime.tick(); await session.runtime.waitForRound()
        let recovered = await session.runtime.current(), creates = await session.photos.creates
        XCTAssertEqual(creates, 1)
        XCTAssertNil(recovered.message); XCTAssertFalse(recovered.snapshot.storageRetryPending)
        await session.runtime.stop(); await session.runtime.waitForRound(); session.events.flushLog()
    }

    func testColdRestartAcrossProcesses() async throws {
        let environment = ProcessInfo.processInfo.environment
        if let phase = environment["PHOTOSYNC_SYNTHETIC_PHASE"], let path = environment["PHOTOSYNC_SYNTHETIC_SESSION"] {
            let root = URL(fileURLWithPath: path)
            try PortableRuntimeSession.validate(root)
            try await runPhase(root: root, phase: phase)
            return
        }
        let root = try PortableRuntimeSession.create()
        defer { try? FileManager.default.removeItem(at: root) }
        for phase in ["seed", "resume", "settled"] { try await runChild(root: root, phase: phase) }
        let reports = try ["seed", "resume", "settled"].map { phase in
            try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(phase + ".json"))) as! [String: Any]
        }
        XCTAssertEqual(reports[0]["modelCalls"] as? Int, 1000)
        XCTAssertEqual(reports[1]["modelCalls"] as? Int, 0)
        XCTAssertEqual(reports[2]["modelCalls"] as? Int, 0)
        XCTAssertEqual(reports[1]["liveReads"] as? Int, 40)
        XCTAssertEqual(reports[2]["liveReads"] as? Int, 0)
        XCTAssertEqual(reports[1]["creates"] as? Int, 1)
        XCTAssertEqual(reports[2]["creates"] as? Int, 0)
        XCTAssertEqual(reports[2]["imported"] as? Int, 201)
        XCTAssertEqual(Set(reports.compactMap { $0["pid"] as? Int }).count, 3)
        if let output = environment["PHOTOSYNC_ACCEPTANCE_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output).appendingPathComponent("runtime-restart.json"))
        }
    }

    func testBootstrapInventoriesSourceWhileColdCandidateLoadIsHeld() async throws {
        let root = try PortableRuntimeSession.create()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await PortableRuntimeSession(root: root, count: 16)
        try await session.addSourceVideo()
        let gate = PortableRuntimeGate()
        await session.photos.setGate(gate)
        await session.runtime.bootstrap()
        await gate.waitForArrival()
        let delivered = await XCTWaiter.fulfillment(of: [session.events.sourceDelivered], timeout: 2)
        let before = await session.photos.creates
        XCTAssertEqual(delivered, .completed, "A candidate wait must not prevent directory delivery")
        XCTAssertEqual(before, 0, "Enumeration does not authorize submission")
        session.events.record("candidate_dependency_released")
        await gate.release()
        await session.runtime.waitForRound()
        let after = await session.photos.creates, state = await session.runtime.current()
        XCTAssertEqual(after, 1); XCTAssertNil(state.message); XCTAssertNil(state.snapshot.blockingError)
        XCTAssertLessThan(session.events.elapsed("candidate_dependency_released", "first_submit_completed") ?? .infinity, 2)
        await session.runtime.stop(); await session.runtime.waitForRound()
        session.events.flushLog()
    }

    private func runPhase(root: URL, phase: String) async throws {
        guard ["seed", "resume", "settled"].contains(phase) else { throw FixtureError.unavailable("Unknown synthetic phase") }
        let session = try await PortableRuntimeSession(root: root, count: 1000)
        if phase == "seed" {
            for i in 0..<200 {
                let name = "history-\(i).jpg"
                let file = SourceFile(sourceID: session.sourceID, relativePath: name, url: session.source.appendingPathComponent(name),
                    stamp: .init(size: 10, modifiedNanoseconds: 1), metadata: media(name))
                let id = try await session.store.save(file, decision: .importNew), attempt = UUID()
                try await session.store.beginAttempt(fileID: id, attemptID: attempt)
                try await session.store.markImported(fileID: id, attemptID: attempt, identifier: "fixture-history-\(i)")
            }
        } else if phase == "resume" { try await session.addSourceVideo() }
        session.events.record("runtime_started")
        await session.runtime.bootstrap(); await session.runtime.waitForRound()
        if phase == "seed" {
            // A production timer feeds bounded image slices. Advance those timer
            // events explicitly; waiting for one slice is not a finished inventory.
            for _ in 0..<64 {
                if await session.runtime.current().snapshot.indexProgress?.readyRepresentations == 1000 { break }
                await session.runtime.tick(); await session.runtime.waitForRound()
            }
        }
        let state = await session.runtime.current()
        XCTAssertNil(state.message); XCTAssertNil(state.snapshot.blockingError)
        XCTAssertEqual(state.snapshot.indexProgress?.readyRepresentations, 1000)
        if phase == "seed" {
            try await session.store.enqueueLivePhotoAssets(context: session.photos.context,
                assets: (0..<40).map { session.photos.liveDescriptor($0) })
        } else {
            XCTAssertLessThan(session.events.elapsed("runtime_started", "first_source_entry") ?? .infinity, 2)
            if phase == "resume" {
                XCTAssertLessThan(session.events.elapsed("runtime_started", "first_submit_completed") ?? .infinity, 2)
                let live = try await session.store.livePhotoInventorySummary(context: session.photos.context)
                XCTAssertEqual(live.pending, 0); XCTAssertEqual(live.unresolved, 0)
            }
        }
        await session.runtime.stop(); await session.runtime.waitForRound()
        session.events.flushLog()
        let report: [String: Any] = ["phase": phase, "pid": ProcessInfo.processInfo.processIdentifier,
            "modelCalls": await session.model.calls, "liveReads": await session.photos.liveReads,
            "creates": await session.photos.creates, "imported": try await session.store.countFiles(state: .imported),
            "events": session.events.json]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent(phase + ".json"))
    }

    private func runChild(root: URL, phase: String) async throws {
        let bundle = Bundle(for: Self.self).bundleURL
        let result = try await Task.detached { try Self.runChildSynchronously(root: root, phase: phase, bundle: bundle) }.value
        XCTAssertEqual(result.0, 0, "Child \(phase):\n\(result.1)")
        guard result.0 == 0 else { throw FixtureError.unavailable("Child phase failed") }
    }

    static func runChildSynchronously(root: URL, phase: String, bundle: URL,
        test: String = "StartupRecoveryTests/testColdRestartAcrossProcesses", checkpoint: String? = nil) throws -> (Int32, String) {
            let process = Process(), done = DispatchSemaphore(value: 0)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctest", "-XCTest", "PhotoSyncCoreTests." + test, bundle.path]
            var environment = ProcessInfo.processInfo.environment
            environment["PHOTOSYNC_SYNTHETIC_PHASE"] = phase; environment["PHOTOSYNC_SYNTHETIC_SESSION"] = root.path
            environment["PHOTOSYNC_SYNTHETIC_CHECKPOINT"] = checkpoint
            environment.removeValue(forKey: "PHOTOSYNC_ACCEPTANCE_OUTPUT")
            process.environment = environment
            let log = root.appendingPathComponent(phase + ".log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
            process.standardOutput = handle; process.standardError = handle
            process.terminationHandler = { _ in done.signal() }
            try process.run()
            if done.wait(timeout: .now() + 25) == .timedOut {
                process.terminate()
                if done.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 2) }
                throw FixtureError.unavailable("Synthetic runtime child timed out: \(phase)")
            }
            return (process.terminationStatus, try String(contentsOf: log, encoding: .utf8))
    }
}

struct PortableRuntimeSession {
    let root: URL, source: URL, sourceID: UUID, store: SyncStore, runtime: SyncRuntime
    let photos: PortableRuntimePhotos, model: PortableRuntimeModel, events: PortableRuntimeEvents
    static func create() throws -> URL {
        let root = try temporaryDirectory()
        try Data(root.lastPathComponent.utf8).write(to: root.appendingPathComponent("synthetic-session"))
        return root
    }
    static func validate(_ root: URL) throws {
        let real = root.standardizedFileURL.resolvingSymlinksInPath()
        guard real.deletingLastPathComponent() == FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath(),
              real.lastPathComponent.hasPrefix("PhotoSyncTests-"),
              UUID(uuidString: String(real.lastPathComponent.dropFirst("PhotoSyncTests-".count))) != nil,
              try String(contentsOf: real.appendingPathComponent("synthetic-session"), encoding: .utf8) == real.lastPathComponent else {
            throw FixtureError.unavailable("Not an owned synthetic session")
        }
    }
    init(root: URL, count: Int, configurationGate: PortableRuntimeGate? = nil,
         now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1000) }) async throws {
        try Self.validate(root)
        self.root = root; source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let configuration = try DedupConfiguration.loadValidated(resourceDirectory: DedupConfiguration.bundledResourceDirectory())
        store = try SyncStore(url: root.appendingPathComponent("sync.sqlite"))
        sourceID = try await store.registerSource(url: source)
        events = PortableRuntimeEvents()
        let context = LibraryContext(id: UUID(uuidString: String(root.lastPathComponent.dropFirst("PhotoSyncTests-".count)))!, epoch: 1)
        let budget = ImageWorkBudget(limits: configuration.resources)
        photos = PortableRuntimePhotos(context: context, root: root, count: count, budget: budget, events: events)
        model = PortableRuntimeModel(version: configuration.fingerprint.version)
        let photos = self.photos, model = self.model, events = self.events
        runtime = SyncRuntime(store: nil, advancedFactory: { store, executor, directory, now, logger in
            events.attachLog(logger)
            return AdvancedRuntimeGraph(store: store, photos: photos, model: model, configuration: configuration,
                executor: executor, budget: budget, directory: directory, now: now, logger: logger)
        }, livePhotoMetadata: PortableNoIdentity(), logsURL: root.appendingPathComponent("Logs"), databaseURL: root.appendingPathComponent("sync.sqlite"),
            directory: { PortableRuntimeDirectory(base: DirectoryReader(sourceID: $0), events: events) },
            configurationLoader: { root in
                let validated = try DedupConfiguration.loadValidated(resourceDirectory: root)
                if let configurationGate { await configurationGate.hold() }
                return validated
            },
            now: now, authorized: { true })
    }
    func addSourceVideo() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/LivePhotoPortable/media/above.mov")
        try FileManager.default.copyItem(at: fixture, to: source.appendingPathComponent("new.mov"))
    }
}

final class PortableRuntimeEvents: @unchecked Sendable {
    let sourceDelivered = XCTestExpectation(description: "real directory delivered a source entry")
    private let lock = NSLock(), start = ProcessInfo.processInfo.systemUptime
    private var entries = [(String, Double)]()
    private var logger: RunLogger?
    func attachLog(_ value: RunLogger?) { lock.lock(); logger = value; lock.unlock() }
    func flushLog() { lock.lock(); let value = logger; lock.unlock(); value?.flushForTesting() }
    func record(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        if name == "first_source_entry" && !entries.contains(where: { $0.0 == name }) { sourceDelivered.fulfill() }
        entries.append((name, ProcessInfo.processInfo.systemUptime - start))
    }
    func elapsed(_ from: String, _ to: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let a = entries.first(where: { $0.0 == from }), let b = entries.first(where: { $0.0 == to }) else { return nil }
        return b.1 - a.1
    }
    var json: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return entries.enumerated().map { ["sequence": $0.offset, "kind": $0.element.0, "monotonicOffset": $0.element.1] }
    }
}

private struct PortableRuntimeDirectory: DirectoryReading {
    let base: DirectoryReader, events: PortableRuntimeEvents
    func entries(in directory: URL) async throws -> [DirectoryEntry] {
        let entries = try await base.entries(in: directory)
        if entries.contains(where: { !$0.isDirectory }) { events.record("first_source_entry") }
        return entries
    }
    func stamp(of file: URL) async throws -> FileStamp { try await base.stamp(of: file) }
}

actor PortableRuntimeGate {
    private var open = false, arrived = false, waiters = [CheckedContinuation<Void, Never>]()
    private let arrival = XCTestExpectation(description: "candidate dependency entered")
    func hold() async {
        if !arrived { arrived = true; arrival.fulfill() }
        if !open { await withCheckedContinuation { waiters.append($0) } }
    }
    func waitForArrival() async {
        let result = await XCTWaiter.fulfillment(of: [arrival], timeout: 5)
        XCTAssertEqual(result, .completed)
        if result != .completed { release() }
    }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}

actor PortableRuntimeModel: ImageFingerprinting {
    let version: String
    private(set) var calls = 0
    init(version: String) { self.version = version }
    func fingerprint(image: CGImage, orientation: CGImagePropertyOrientation) throws -> Fingerprint {
        calls += 1; return try Fingerprint(version: version, values: [1] + Array(repeating: 0, count: 1023))
    }
}

private struct PortableNoIdentity: LivePhotoMetadataReading {
    func inspect(url: URL, kind: MediaKind) async throws -> LivePhotoInspection { .noIdentifier }
}

actor PortableRuntimePhotos: LivePhotoPhotosGateway {
    nonisolated let context: LibraryContext
    let root: URL, count: Int, budget: ImageWorkBudget, events: PortableRuntimeEvents
    private var gate: PortableRuntimeGate?
    private(set) var creates = 0, liveReads = 0
    init(context: LibraryContext, root: URL, count: Int, budget: ImageWorkBudget, events: PortableRuntimeEvents) {
        self.context = context; self.root = root; self.count = count; self.budget = budget; self.events = events
    }
    func setGate(_ gate: PortableRuntimeGate) { self.gate = gate }
    func candidateSnapshot() async throws -> PhotosCandidateSnapshot {
        events.record("candidate_load_begin"); if let gate { await gate.hold() }
        events.record("candidate_load_end")
        return .init(generation: 0, candidates: (0..<count).map { .init(key: "fixture-\($0)", metadata: media("fixture-\($0).jpg")) })
    }
    func representationCatalog(offset: Int, limit: Int, expectedGeneration: Int) async throws -> RepresentationPage {
        let end = min(count, offset + limit)
        let descriptors = (offset..<end).map { RepresentationDescriptor(key: .init(assetID: "fixture-\($0)", kind: .original), context: context,
            revision: "r1", size: try! PixelSize(width: 8, height: 8), equivalentToOriginal: false,
            revisionIsReliable: true, modificationDate: Date(timeIntervalSince1970: 100)) }
        return .init(context: context, generation: 0, descriptors: descriptors, nextOffset: end < count ? end : nil)
    }
    func readRepresentation(_ descriptor: RepresentationDescriptor) async throws -> LoadedRepresentation {
        let lease = try await budget.acquire(bytes: 256)
        let image = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        return .init(image: image, orientation: .up, descriptor: descriptor, lease: lease, eligibility: .safeSingleFrame)
    }
    nonisolated func changes() -> AsyncStream<PhotosIndexChange> { AsyncStream { $0.finish() } }
    func create(fileURL: URL, kind: MediaKind, expectedGeneration: Int, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        guard expectedGeneration == 0 else { throw PhotoKitGatewayError.libraryChanged }
        events.record("first_submit_admitted"); creates += 1
        let id = "synthetic-new-video"
        try Data(id.utf8).write(to: root.appendingPathComponent("system-mutation-journal"), options: .atomic)
        try onPlaceholder(id); events.record("first_submit_completed"); return id
    }
    func create(fileURL: URL, kind: MediaKind, expectedGeneration: Int, beforeMutation: @escaping @Sendable () throws -> Bool, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        guard try beforeMutation() else { throw PhotosAdmissionDeferred() }
        return try await create(fileURL: fileURL, kind: kind, expectedGeneration: expectedGeneration, onPlaceholder: onPlaceholder)
    }
    func reconcile(placeholder: String?) async throws -> ImportEvidence {
        guard let placeholder, let journal = try? String(contentsOf: root.appendingPathComponent("system-mutation-journal"), encoding: .utf8), placeholder == journal else { return .unknown }
        return .found(identifier: placeholder)
    }
    func contextCheckpoint() async throws -> LibraryResumeCheckpoint? { .init(context: context, archivedChangeToken: Data([1]), photosGeneration: 0) }
    func resumeContext(_ checkpoint: LibraryResumeCheckpoint) async throws -> Bool { events.record("history_checked"); return checkpoint.context == context }
    func coverPersistentHistory(from: LibraryResumeCheckpoint, through: LibraryResumeCheckpoint) async throws -> Bool { from == through }
    func restoreInventoryContext(_ context: LibraryContext) async throws { guard context == self.context else { throw PhotoKitGatewayError.libraryChanged } }
    func livePhotoLibraryContext() async throws -> LibraryContext { context }
    func verifyLivePhotoContext(context: LibraryContext, anchorAssetIDs: [String], allowUnanchored: Bool) async throws -> Bool { context == self.context }
    func livePhotoAssetCatalog(session: PhotosCatalogSession, offset: Int, limit: Int) async throws -> LivePhotoAssetPage { .init(context: context, generation: 0, assets: [], nextOffset: nil) }
    nonisolated func liveDescriptor(_ i: Int) -> LivePhotoAssetDescriptor {
        .init(context: context, assetID: "lp-\(i)", revision: "r1", isLivePhoto: false, mediaKind: .image,
            resources: [.photos(contextID: context.id, assetID: "lp-\(i)", resourceKey: "original", revision: "r1")], resourceKinds: [.image])
    }
    func livePhotoAssets(assetIDs: [String], context: LibraryContext) async throws -> [LivePhotoAssetDescriptor] {
        assetIDs.compactMap { id in id.hasPrefix("lp-") ? Int(id.dropFirst(3)).map(liveDescriptor) : nil }
    }
    func readLivePhotoResource(_ ref: LivePhotoResourceRef, purpose: LivePhotoReadPurpose, budget: LivePhotoResourceBudget) async throws -> LivePhotoResourceLease {
        liveReads += 1; events.record("live_photo_read")
        return .init(url: root.appendingPathComponent("synthetic-no-identity"))
    }
    func setLivePhotoRecoveryBlocks(_ ids: Set<UUID>) async {}
    func createLivePhoto(photoURL: URL, motionURL: URL, photoFilename: String?, motionFilename: String?, preservation: LivePhotoPreservationSnapshot, expectedGeneration: Int, beforeMutation: @escaping @Sendable () throws -> Bool, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String { throw FixtureError.unavailable("No fixture pair should be submitted") }
    func retireLivePhotoComponents(assetIDs: [String], expectedGeneration: Int, beforeMutation: @escaping @Sendable () throws -> Bool) async throws { throw FixtureError.unavailable("No fixture asset should be deleted") }
    func verifyLivePhoto(assetID: String, operation: LivePhotoOperation) async throws -> LivePhotoVerification { throw FixtureError.unavailable("No fixture pair should need verification") }
    func livePhotoPreservationSnapshot(assetID: String, context: LibraryContext) async throws -> LivePhotoPreservationSnapshot { knownLivePhotoSnapshot() }
    func resourcesEqual(_ lhs: LivePhotoResourceRef, _ rhs: LivePhotoResourceRef, budget: LivePhotoResourceBudget) async throws -> Bool { lhs == rhs }
}
