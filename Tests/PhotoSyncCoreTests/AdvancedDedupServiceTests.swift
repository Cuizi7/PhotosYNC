import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import PhotoSyncCore

final class AdvancedDedupServiceTests: XCTestCase {
    func testDifferentFilenameStillMatches() async throws {
        let f = try await fixture(); try await ready(f, candidates: [("unrelated-name", .original, 1, 8)])
        let admission = try await admission(f)
        XCTAssertEqual(admission.evidence.evaluation.action, .skip)
        XCTAssertEqual(admission.evidence.decisiveCandidates.first?.key, "photos:14:unrelated-name:original")
    }
    func testSameFilenameCannotForceImageSkip() async throws {
        let f = try await fixture(); try await ready(f, candidates: [(f.file.metadata.filename, .original, 0, 8)])
        let result = try await admission(f); XCTAssertEqual(result.evidence.evaluation.action, .importFile)
    }
    func testReadFailureIsWaitingNotNoMatch() async throws {
        let f = try await fixture()
        guard case .waiting = try await f.service.prepare(fileID: f.id, file: f.file) else { return XCTFail("Unknown index must wait") }
        let count = await f.photos.createCount; XCTAssertEqual(count, 0)
        try await ready(f, candidates: [])
        try Data("bad image".utf8).write(to: f.file.url)
        let bad = SourceFile(sourceID: f.file.sourceID, relativePath: f.file.relativePath, url: f.file.url,
            stamp: try await DirectoryReader().stamp(of: URL(fileURLWithPath: f.file.url.path)), metadata: f.file.metadata)
        _ = try await f.store.recordSourceChange(fileID: f.id, stamp: bad.stamp)
        do { _ = try await f.service.prepare(fileID: f.id, file: bad); XCTFail("Definite read failure must throw") }
        catch MetadataError.unreadable {} // Existing file retry path retains the read failure.
    }
    func testStampChangesDuringFingerprintDiscardsResult() async throws {
        let f = try await fixture(); try await ready(f, candidates: [])
        let gate = AdmissionGate(); await f.model.setGate(gate)
        let work = Task { try await f.service.prepare(fileID: f.id, file: f.file) }
        await gate.waitUntilEntered()
        try Data([1, 2, 3]).write(to: f.file.url)
        await gate.release()
        guard case .waiting = try await work.value else { return XCTFail("Changed source must wait") }
        let cached = try await f.store.fingerprint(fileID: f.id, stamp: f.file.stamp, version: f.configuration.fingerprint.version)
        XCTAssertNil(cached)
    }
    func testCurrentMatchCannotBorrowOriginalDimensions() async throws {
        let f = try await fixture(); try await ready(f, candidates: [("asset", .original, 0, 100), ("asset", .current, 1, 1)])
        let result = try await admission(f)
        XCTAssertEqual(result.evidence.evaluation.action, .importFile)
        XCTAssertEqual(result.evidence.evaluation.reason, .resolutionUpgrade)
        XCTAssertEqual(result.evidence.decisiveCandidates.first?.size, try PixelSize(width: 1, height: 1))
    }
    func testMissingOldHistoryFingerprintDoesNotBlockLibraryReady() async throws {
        let f = try await fixture(); let older = try await f.store.save(copy(f.file, path: "old.png"), decision: .importNew)
        let attempt = UUID(); try await f.store.beginAttempt(fileID: older, attemptID: attempt)
        try await f.store.markImported(fileID: older, attemptID: attempt, identifier: "old-asset")
        try await ready(f, candidates: [])
        let result = try await admission(f); XCTAssertEqual(result.evidence.evaluation.action, .importFile)
        guard case .waiting = try await f.service.prepare(fileID: older, file: copy(f.file, path: "old.png")) else { return XCTFail("Successful identity must stay protected") }
    }
    func testBelowThresholdNearestIsDiagnosticOnly() async throws {
        let f = try await fixture(); try await ready(f, candidates: [("nearest", .original, 0.97, 8)])
        let result = try await admission(f)
        XCTAssertEqual(result.evidence.evaluation.action, .importFile)
        XCTAssertEqual(result.evidence.diagnostics.count, 1)
        XCTAssertEqual(result.evidence.diagnostics[0].score, 0.97, accuracy: 0.000001)
    }
    func testCoveringMatchBeyondDiagnosticLimitStillSkips() async throws {
        let f = try await fixture()
        var candidates: [(String, RepresentationKind, Float, Int)] = (0..<11).map { ("small-\($0)", .original, 1, 1) }
        candidates.append(("large", .current, 0.99, 8))
        try await ready(f, candidates: candidates)
        let result = try await admission(f)
        XCTAssertEqual(result.evidence.evaluation.action, .skip)
        XCTAssertEqual(result.evidence.diagnostics.count, 10)
        XCTAssertFalse(result.evidence.diagnostics.contains { $0.key == "photos:5:large:current" })
        XCTAssertEqual(result.evidence.decisiveCandidates.first?.key, "photos:5:large:current")
        XCTAssertEqual(result.evidence.evaluation.matchedKeys, ["photos:5:large:current"])
        XCTAssertEqual(result.evidence.evaluation.coveringKeys, ["photos:5:large:current"])
    }
    func testThresholdChangeReusesFingerprintButNotOldDecision() async throws {
        let f = try await fixture(); try await ready(f, candidates: [("asset", .original, 0.97, 8)])
        let first = try await admission(f); XCTAssertEqual(first.evidence.evaluation.action, .importFile)
        let c = f.configuration
        let changed = try DedupConfiguration(fingerprint: c.fingerprint,
            policyVersion: DedupConfiguration.computePolicyVersion(fingerprintVersion: c.fingerprint.version, threshold: 0.96, backend: c.backend),
            threshold: 0.96, backend: c.backend, resources: c.resources, evidenceCandidateLimit: c.evidenceCandidateLimit, acceptanceID: c.acceptanceID)
        let service = AdvancedDedupService(store: f.store, photos: f.photos, coordinator: f.coordinator, fingerprinter: f.model,
            index: f.index, configuration: changed, executor: f.executor, budget: f.budget)
        guard case .ready(let second) = try await service.prepare(fileID: f.id, file: f.file) else { return XCTFail("Expected new policy admission") }
        XCTAssertEqual(second.evidence.evaluation.action, .skip)
        XCTAssertNotEqual(first.evidence.policyVersion, second.evidence.policyVersion)
        let count = await f.model.count; XCTAssertEqual(count, 1)
    }
    func testLocalCandidatesUseCreationOrderAndActiveSource() async throws {
        let f = try await fixture()
        let earlierFile = copy(f.file, path: "z-earlier.png"), earlier = try await f.store.save(earlierFile, decision: .importNew)
        let laterFile = copy(f.file, path: "a-later.png"), later = try await f.store.save(laterFile, decision: .importNew)
        let vector = try fingerprint(f.configuration, score: 1)
        let accepted = try await f.store.cacheFingerprint(.init(fileID: earlier, file: earlierFile, fingerprint: vector, size: try PixelSize(width: 8, height: 8)))
        XCTAssertTrue(accepted)
        let stored = try await f.store.file(sourceID: laterFile.sourceID, relativePath: laterFile.relativePath)
        let candidates = try await f.store.localVectorCandidates(beforeOrder: XCTUnwrap(stored).createdOrder, excluding: later, version: vector.version)
        XCTAssertEqual(candidates.entries.map(\.key), ["file:\(earlier.uuidString)"])
        try await f.store.disableSource(id: f.file.sourceID)
        let disabled = try await f.store.localVectorCandidates(beforeOrder: Int64.max, excluding: later, version: vector.version)
        XCTAssertTrue(disabled.entries.isEmpty)
        // P5 owns source/state mutation revision increments; P4 tests its cache writes below.
        _ = candidates.revision
    }
    func testLibraryChangeDuringFingerprintCannotReturnAdmission() async throws {
        let f = try await fixture(); try await ready(f, candidates: [])
        let gate = AdmissionGate(); await f.model.setGate(gate)
        let work = Task { try await f.service.prepare(fileID: f.id, file: f.file) }; await gate.waitUntilEntered()
        await f.photos.change(); await gate.release()
        guard case .waiting = try await work.value else { return XCTFail("Stale library must wait") }
    }
    func testReadableMultiframeImportsConservativelyWithoutVector() async throws {
        let f = try await fixture(); try await ready(f, candidates: [("covering", .original, 1, 100)])
        let url = f.file.url.deletingLastPathComponent().appendingPathComponent("animated.gif")
        try writeImage(url, type: "com.compuserve.gif", frames: 2)
        let file = SourceFile(sourceID: f.file.sourceID, relativePath: url.lastPathComponent, url: url,
            stamp: try await DirectoryReader().stamp(of: url), metadata: f.file.metadata)
        let id = try await f.store.save(file, decision: .importNew)
        guard case .conservative(let admission) = try await f.service.prepare(fileID: id, file: file) else { return XCTFail("Readable multiframe content must import conservatively") }
        XCTAssertEqual(admission.reason, .multiFrameOrCompound)
        XCTAssertEqual(admission.evidence.evaluation.content, .notCompared)
        XCTAssertEqual(admission.evidence.evaluation.action, .importFile)
        XCTAssertEqual(admission.evidence.evaluation.reason, .nonComparableSource)
        XCTAssertTrue(admission.evidence.diagnostics.isEmpty)
        XCTAssertTrue(admission.evidence.decisiveCandidates.isEmpty)
        let count = await f.model.count; XCTAssertEqual(count, 0)
        let fingerprint = try await f.store.fingerprint(fileID: id, stamp: file.stamp, version: f.configuration.fingerprint.version)
        XCTAssertNil(fingerprint)
    }
    func testPauseDuringInferenceKeepsPhysicalLeaseAndBlocksAdmission() async throws {
        let f = try await fixture(); try await ready(f, candidates: [])
        let gate = AdmissionGate(); await f.model.setGate(gate)
        let work = Task { try await f.service.prepare(fileID: f.id, file: f.file) }; await gate.waitUntilEntered()
        await f.service.setPaused(true)
        let occupied = await f.budget.snapshot(); XCTAssertEqual(occupied.images, 1)
        await gate.release()
        guard case .waiting = try await work.value else { return XCTFail("Paused source cannot be admitted") }
        let released = await f.budget.snapshot(); XCTAssertEqual(released.images, 0)
        let cached = try await f.store.fingerprint(fileID: f.id, stamp: f.file.stamp, version: f.configuration.fingerprint.version)
        XCTAssertNil(cached)
    }
    func testLogicalCancellationDoesNotReleaseInFlightImage() async throws {
        let f = try await fixture(); try await ready(f, candidates: [])
        let gate = AdmissionGate(); await f.model.setGate(gate)
        let work = Task { try await f.service.prepare(fileID: f.id, file: f.file) }; await gate.waitUntilEntered()
        work.cancel()
        let occupied = await f.budget.snapshot(); XCTAssertEqual(occupied.images, 1)
        await gate.release()
        guard case .waiting = try await work.value else { return XCTFail("Canceled source cannot be admitted") }
        let released = await f.budget.snapshot(); XCTAssertEqual(released.images, 0)
    }
    func testSharedImageExhaustionWaitsInsteadOfImporting() async throws {
        let f = try await fixture(); try await ready(f, candidates: [])
        let lease = try await f.budget.acquire(bytes: f.configuration.resources.maxDecodedBytes)
        guard case .waiting = try await f.service.prepare(fileID: f.id, file: f.file) else { return XCTFail("Exhausted budget must wait") }
        let count = await f.model.count; XCTAssertEqual(count, 0)
        await lease.finishPhysicalWork()
    }
    func testUnknownSubmissionIsProtectedBeforeSourceRead() async throws {
        let f = try await fixture(); try await ready(f, candidates: [])
        try await f.store.beginAttempt(fileID: f.id, attemptID: UUID())
        try FileManager.default.removeItem(at: f.file.url)
        guard case .waiting = try await f.service.prepare(fileID: f.id, file: f.file) else { return XCTFail("Unknown attempt must stay protected") }
        let count = await f.model.count; XCTAssertEqual(count, 0)
    }
    func testFingerprintCacheChangesInvalidateLocalAdmissionRevision() async throws {
        let f = try await fixture(); try await ready(f, candidates: [])
        let beforeValue = try await f.coordinator.readyToken(); let before = try XCTUnwrap(beforeValue)
        let source = PreparedSource(fileID: f.id, file: f.file, fingerprint: try fingerprint(f.configuration, score: 1), size: try PixelSize(width: 2, height: 2))
        let accepted = try await f.store.cacheFingerprint(source); XCTAssertTrue(accepted)
        let oldValid = try await f.store.indexIsReady(token: before); XCTAssertFalse(oldValid)
        let afterValue = try await f.coordinator.readyToken(); let after = try XCTUnwrap(afterValue)
        XCTAssertEqual(before.indexGeneration, after.indexGeneration)
        XCTAssertEqual(after.localRevision, before.localRevision + 1)
        _ = try await f.store.cacheFingerprint(source)
        let unchangedValue = try await f.coordinator.readyToken(); XCTAssertEqual(unchangedValue?.localRevision, after.localRevision)
        let rejected = PreparedSource(fileID: f.id, file: copy(f.file, path: "wrong-path.png"), fingerprint: source.fingerprint, size: source.size)
        let invalidCache = try await f.store.cacheFingerprint(rejected); XCTAssertFalse(invalidCache)
    }
    func testLocalScoringPreservesAllMatchesAndBelowThresholdDiagnostics() throws {
        let c = try configuration(); let query = try fingerprint(c, score: 1)
        let entries = try (0..<12).map { i in VectorEntry(key: "file:\(i)", origin: .successHistory,
            fingerprint: try fingerprint(c, score: i == 11 ? 0.97 : 1), size: nil) }
        let result = try ExactVectorIndex.scoreWithDiagnostics(query: query, entries: entries, minimumScore: c.threshold, diagnosticLimit: 2)
        XCTAssertEqual(result.matches.count, 11); XCTAssertEqual(result.diagnostics.count, 2)
        let below = try ExactVectorIndex.scoreWithDiagnostics(query: query, entries: Array(entries.suffix(1)), minimumScore: c.threshold, diagnosticLimit: 10)
        XCTAssertTrue(below.matches.isEmpty); XCTAssertEqual(below.diagnostics.first?.score ?? 0, 0.97, accuracy: 0.000001)
    }
    private func configuration() throws -> DedupConfiguration {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(DedupConfiguration.self, from: Data(contentsOf: repository.appendingPathComponent("docs/research/advanced-dedup/integration-profile.json")))
    }
    func testProvidedMetadataCannotReplaceStoredSourceEvidence() async throws {
        let f = try await fixture(); try await ready(f, candidates: [("asset", .original, 1, 8)])
        let altered = SourceFile(sourceID: f.file.sourceID, relativePath: f.file.relativePath, url: f.file.url,
            stamp: f.file.stamp, metadata: MediaMetadata(filename: f.file.metadata.filename, kind: .image,
                captureSecond: nil, rawCaptureTime: nil, make: nil, model: nil, width: 100, height: 100, duration: nil))
        guard case .waiting = try await f.service.prepare(fileID: f.id, file: altered) else { return XCTFail("Admission must use stored source evidence") }
        let count = await f.model.count; XCTAssertEqual(count, 0)
    }
    func testLocalRevisionChangeAfterTokenBlocksOldQuery() async throws {
        let f = try await fixture(); try await ready(f, candidates: [])
        _ = try await admission(f)
        let other = copy(f.file, path: "later.png"), otherID = try await f.store.save(copy(f.file, path: "later.png"), decision: .importNew)
        let gate = AdmissionGate(); await f.photos.gateSecondSnapshot(gate)
        let work = Task { try await f.service.prepare(fileID: f.id, file: f.file) }; await gate.waitUntilEntered()
        _ = try await f.store.cacheFingerprint(.init(fileID: otherID, file: other, fingerprint: try fingerprint(f.configuration, score: 1), size: nil))
        await gate.release()
        guard case .waiting = try await work.value else { return XCTFail("Old local revision must wait") }
    }
    func testSourcePassesOriginalPixelsToCommonPreprocessor() async throws {
        let f = try await fixture(); try await ready(f, candidates: [])
        let url = f.file.url.deletingLastPathComponent().appendingPathComponent("large.png")
        try writeImage(url, type: "public.png", width: 640, height: 320)
        let metadata = MediaMetadata(filename: url.lastPathComponent, kind: .image, captureSecond: nil,
            rawCaptureTime: nil, make: nil, model: nil, width: 640, height: 320, duration: nil)
        let file = SourceFile(sourceID: f.file.sourceID, relativePath: url.lastPathComponent, url: url,
            stamp: try await DirectoryReader().stamp(of: url), metadata: metadata)
        let id = try await f.store.save(file, decision: .importNew)
        guard case .ready = try await f.service.prepare(fileID: id, file: file) else { return XCTFail("Expected static source admission") }
        let dimensions = await f.model.dimensions
        XCTAssertEqual(dimensions, try PixelSize(width: 640, height: 320))
    }
    func testReadableStillBeyondConfiguredDecodeAllowanceWaitsWithoutInference() async throws {
        let f = try await fixture(); try await ready(f, candidates: [])
        let url = f.file.url.deletingLastPathComponent().appendingPathComponent("over-budget.png")
        try writeImage(url, type: "public.png", width: 640, height: 320)
        let metadata = MediaMetadata(filename: url.lastPathComponent, kind: .image, captureSecond: nil,
            rawCaptureTime: nil, make: nil, model: nil, width: 640, height: 320, duration: nil)
        let file = SourceFile(sourceID: f.file.sourceID, relativePath: url.lastPathComponent, url: url,
            stamp: try await DirectoryReader().stamp(of: url), metadata: metadata)
        let id = try await f.store.save(file, decision: .importNew), c = f.configuration, r = c.resources
        let limits = try ResourceLimits(decodeConcurrency: r.decodeConcurrency, photoRequestConcurrency: r.photoRequestConcurrency,
            maxDecodedBytes: 800_000, requestTimeoutSeconds: r.requestTimeoutSeconds, retryDelaysSeconds: r.retryDelaysSeconds,
            catalogBatchSize: r.catalogBatchSize, maxInFlightTasks: r.maxInFlightTasks,
            progressPublishIntervalSeconds: r.progressPublishIntervalSeconds, inferenceConcurrency: r.inferenceConcurrency, batchSize: r.batchSize)
        let configuration = try DedupConfiguration(fingerprint: c.fingerprint, policyVersion: c.policyVersion,
            threshold: c.threshold, backend: c.backend, resources: limits, evidenceCandidateLimit: c.evidenceCandidateLimit, acceptanceID: c.acceptanceID)
        let budget = ImageWorkBudget(limits: limits)
        let reader = MetadataReader(sourceID: file.sourceID, executor: f.executor)
        do { _ = try await reader.readForFingerprint(url: file.url, configuration: configuration, budget: budget); XCTFail("Native backing exceeds configured bytes") }
        catch ImageWorkBudgetError.invalidReservation {}
        let service = AdvancedDedupService(store: f.store, photos: f.photos, coordinator: f.coordinator,
            fingerprinter: f.model, index: f.index, configuration: configuration, executor: f.executor, budget: ImageWorkBudget(limits: limits))
        guard case .waiting = try await service.prepare(fileID: id, file: file) else { return XCTFail("Over-budget still must wait, not claim unique/conservative import") }
        let count = await f.model.count; XCTAssertEqual(count, 0)
        let fingerprint = try await f.store.fingerprint(fileID: id, stamp: file.stamp, version: c.fingerprint.version)
        XCTAssertNil(fingerprint)
    }
    private struct Fixture {
        let store: SyncStore; let photos: AdmissionPhotos; let model: AdmissionModel; let index: ExactVectorIndex
        let coordinator: PhotosIndexCoordinator; let service: AdvancedDedupService; let configuration: DedupConfiguration
        let executor: ReadExecutor; let budget: ImageWorkBudget; let file: SourceFile; let id: UUID
    }
    private func fixture() async throws -> Fixture {
        let root = try temporaryDirectory(); try writeImage(root.appendingPathComponent("no-exif.png"), type: "public.png"); addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let c = try JSONDecoder().decode(DedupConfiguration.self, from: Data(contentsOf: repository.appendingPathComponent("docs/research/advanced-dedup/integration-profile.json")))
        let executor = ReadExecutor(maxConcurrentOperations: c.resources.maxInFlightTasks), budget = ImageWorkBudget(limits: c.resources)
        let store = try SyncStore(url: root.appendingPathComponent("test.sqlite"), readExecutor: executor)
        let source = try await store.registerSource(url: root), url = root.appendingPathComponent("no-exif.png")
        let metadata = MediaMetadata(filename: url.lastPathComponent, kind: .image, captureSecond: nil, rawCaptureTime: nil, make: nil, model: nil, width: 2, height: 2, duration: nil)
        let file = SourceFile(sourceID: source, relativePath: url.lastPathComponent, url: url, stamp: try await DirectoryReader().stamp(of: url), metadata: metadata)
        let id = try await store.save(file, decision: .importNew), photos = AdmissionPhotos(), model = AdmissionModel(vector: try fingerprint(c, score: 1))
        let index = ExactVectorIndex(version: c.fingerprint.version)
        let coordinator = PhotosIndexCoordinator(store: store, photos: photos, fingerprinter: model, index: index, configuration: c)
        return Fixture(store: store, photos: photos, model: model, index: index, coordinator: coordinator,
            service: AdvancedDedupService(store: store, photos: photos, coordinator: coordinator, fingerprinter: model, index: index, configuration: c, executor: executor, budget: budget),
            configuration: c, executor: executor, budget: budget, file: file, id: id)
    }
    private func ready(_ f: Fixture, candidates: [(String, RepresentationKind, Float, Int)]) async throws {
        let context = f.photos.context
        let descriptors = try candidates.map { .init(key: RepresentationKey(assetID: $0.0, kind: $0.1), context: context, revision: "r1", size: try PixelSize(width: $0.3, height: $0.3), equivalentToOriginal: false, revisionIsReliable: true) as RepresentationDescriptor }
        await f.photos.set(descriptors)
        try await f.coordinator.reconcile()
        let tasks = try await f.store.nextRepresentationTasks(now: Date(), limit: 100)
        for task in tasks {
            let score = try XCTUnwrap(candidates.first { $0.0 == task.descriptor.key.assetID && $0.1 == task.descriptor.key.kind }).2
            _ = try await f.store.completeRepresentation(task, fingerprint: fingerprint(f.configuration, score: score))
        }
        await f.coordinator.processDueWork(now: Date())
    }
    private func admission(_ f: Fixture) async throws -> AdvancedAdmission {
        guard case .ready(let result) = try await f.service.prepare(fileID: f.id, file: f.file) else { throw FixtureError.unavailable("Expected admission") }
        return result
    }
    private func writeImage(_ url: URL, type: String, frames: Int = 1, width: Int = 2, height: Int = 2) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, frames, nil))
        for frame in 0..<frames {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: CGFloat(frame % 2), green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    private func fingerprint(_ c: DedupConfiguration, score: Float) throws -> Fingerprint {
        try Fingerprint(version: c.fingerprint.version, values: [score, sqrt(1 - score * score)] + Array(repeating: 0, count: 1022))
    }
    private func copy(_ file: SourceFile, path: String) -> SourceFile {
        .init(sourceID: file.sourceID, relativePath: path, url: file.url.deletingLastPathComponent().appendingPathComponent(path), stamp: file.stamp, metadata: file.metadata)
    }
}
private actor AdmissionGate {
    private var entered = false; private var open = false
    private var listeners: [CheckedContinuation<Void, Never>] = []; private var blocked: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; listeners.forEach { $0.resume() }; listeners = []; if !open { await withCheckedContinuation { blocked = $0 } } }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { listeners.append($0) } } }
    func release() { open = true; blocked?.resume(); blocked = nil }
}
private actor AdmissionModel: ImageFingerprinting {
    let vector: Fingerprint; private var gate: AdmissionGate?; private(set) var count = 0
    private(set) var dimensions: PixelSize?
    init(vector: Fingerprint) { self.vector = vector }
    func setGate(_ gate: AdmissionGate) { self.gate = gate }
    func fingerprint(image: CGImage, orientation: CGImagePropertyOrientation) async throws -> Fingerprint {
        count += 1; dimensions = try PixelSize(width: image.width, height: image.height); if let gate { self.gate = nil; await gate.hold() }; return vector
    }
}
private actor AdmissionPhotos: PhotosIndexGateway {
    nonisolated let context = LibraryContext(id: UUID(), epoch: 1)
    private var generation = 1; private var descriptors: [RepresentationDescriptor] = []
    private(set) var createCount = 0
    private var gate: AdmissionGate?, snapshots = 0
    func gateSecondSnapshot(_ gate: AdmissionGate) { self.gate = gate; snapshots = 0 }
    func set(_ descriptors: [RepresentationDescriptor]) { self.descriptors = descriptors }
    func change() { generation += 1 }
    func candidateSnapshot() async throws -> PhotosCandidateSnapshot {
        snapshots += 1
        if snapshots == 2, let gate { self.gate = nil; await gate.hold() }
        return .init(generation: generation, candidates: [])
    }
    nonisolated func changes() -> AsyncStream<PhotosIndexChange> { AsyncStream { _ in } }
    func representationCatalog(offset: Int, limit: Int, expectedGeneration: Int) async throws -> RepresentationPage { .init(context: context, generation: generation, descriptors: descriptors, nextOffset: nil) }
    func readRepresentation(_ descriptor: RepresentationDescriptor) async throws -> LoadedRepresentation { throw PhotoKitGatewayError.libraryUnavailable }
    func create(fileURL: URL, kind: MediaKind, expectedGeneration: Int, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String { createCount += 1; return "never" }
    func reconcile(placeholder: String?) async throws -> ImportEvidence { .unknown }
}
