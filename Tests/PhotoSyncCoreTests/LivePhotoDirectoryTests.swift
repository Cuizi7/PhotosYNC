import XCTest
@testable import PhotoSyncCore

final class LivePhotoDirectoryTests: XCTestCase {
    func testLongVideoStillImportsWithoutLivePhotoReadAndKeepsKnownIdentity() async throws {
        for knownIdentity in [false, true] {
            let f = try await directoryFixture(makeSingle: false); defer { try? FileManager.default.removeItem(at: f.root) }
            let url = f.source.appendingPathComponent("long.mov"); try Data([1, 2, 3]).write(to: url)
            let metadata = LongVideoMetadata(), reader = DirectoryIdentificationCounter()
            let file = SourceFile(sourceID: f.sourceID, relativePath: "long.mov", url: url,
                stamp: try await DirectoryReader(sourceID: f.sourceID).stamp(of: url), metadata: try await metadata.read(url: url, filename: "long.mov"))
            if knownIdentity {
                let id = try await f.store.save(file, decision: .importNew)
                try await f.store.saveLivePhotoObservation(.init(resource: .source(fileID: id, stamp: file.stamp), inspection: .identified(.init(contentIdentifier: "known", role: .motion))))
            }
            let engine = SyncEngine(store: f.store, photos: f.photos, metadata: { _ in metadata },
                livePhotoDirectoryObserver: DirectoryObserverProbe(store: f.store), livePhotoMetadata: { _ in reader })
            await engine.scanEnabledSources()
            let reads = await reader.reads, imported = await f.photos.created
            XCTAssertEqual(reads, 0); XCTAssertEqual(imported, ["long.mov"])
            let stored = try await f.store.file(sourceID: f.sourceID, relativePath: "long.mov")
            let id = try XCTUnwrap(stored).id
            let observation = try await f.store.livePhotoObservation(for: .source(fileID: id, stamp: file.stamp))
            if knownIdentity { XCTAssertEqual(observation?.identity?.contentIdentifier, "known") }
            else { XCTAssertEqual(observation?.inspection, .excludedByDuration) }
        }
    }

    func testNoSubmissionBeforeDirectoryIdentificationCompletes() async throws {
        let f = try await directoryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let entered = expectation(description: "directory identified"), gate = DirectoryTestGate()
        let observer = DirectoryObserverProbe(store: f.store, holdDirectory: "", entered: entered, gate: gate)
        let engine = SyncEngine(store: f.store, photos: f.photos, livePhotoDirectoryObserver: observer)
        let scan = Task { await engine.scanEnabledSources() }
        await fulfillment(of: [entered], timeout: 5)
        let before = await f.photos.created; XCTAssertTrue(before.isEmpty)
        await gate.release(); await scan.value
        let after = await f.photos.created; XCTAssertEqual(after, ["single.jpg"])
    }

    func testHEICAndMOVOrderingDoesNotSplitPair() async throws {
        for imageFirst in [true, false] {
            let f = try await directoryFixture(makeSingle: false); defer { try? FileManager.default.removeItem(at: f.root) }
            let photo = f.source.appendingPathComponent(imageFirst ? "a.jpg" : "z.jpg")
            let video = f.source.appendingPathComponent(imageFirst ? "z.mov" : "a.mov")
            try makeLivePhotoImage(at: photo, identifier: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
            try await makeLivePhotoMotion(at: video, identifier: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
            let observer = DirectoryObserverProbe(store: f.store, reservePairs: true)
            let engine = SyncEngine(store: f.store, photos: f.photos, livePhotoDirectoryObserver: observer)
            await engine.scanEnabledSources()
            let created = await f.photos.created; XCTAssertTrue(created.isEmpty)
            let operations = try await f.store.loadLivePhotoOperationsForRecovery()
            XCTAssertEqual(operations.count, 1); XCTAssertEqual(operations.first?.sourceFileIDs.count, 2)
        }
    }

    func testOldPendingAndRetryCannotBypassDirectoryGate() async throws {
        let f = try await directoryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let file = try await directoryStoredFile(sourceID: f.sourceID, url: f.source.appendingPathComponent("single.jpg"), root: f.source)
        let id = try await f.store.save(file, decision: .importNew), attempt = UUID()
        try await f.store.beginAttempt(fileID: id, attemptID: attempt)
        try await f.store.recordRetry(fileID: id, attemptID: attempt, nextRetry: Date(timeIntervalSince1970: 1), error: "definite", definitelyNotCommitted: true)
        let entered = expectation(description: "retry folder waiting"), gate = DirectoryTestGate()
        let observer = DirectoryObserverProbe(store: f.store, holdDirectory: "", entered: entered, gate: gate)
        let engine = SyncEngine(store: f.store, photos: f.photos, livePhotoDirectoryObserver: observer)
        let scan = Task { await engine.scanEnabledSources() }
        await fulfillment(of: [entered], timeout: 5)
        let created = await f.photos.created; XCTAssertTrue(created.isEmpty)
        await gate.release(); await scan.value
        let state = try await f.store.state(of: id); XCTAssertEqual(state, .imported)
    }

    func testHealthySiblingCanSubmitWithoutWaitingForSubtree() async throws {
        let f = try await directoryFixture(makeSingle: false); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = f.source.appendingPathComponent("a-ready"), later = f.source.appendingPathComponent("z-held")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        try makeLivePhotoImage(at: first.appendingPathComponent("ready.jpg"), identifier: nil)
        try makeLivePhotoImage(at: later.appendingPathComponent("later.jpg"), identifier: nil)
        let entered = expectation(description: "later folder held"), imported = expectation(description: "ready folder imported")
        let gate = DirectoryTestGate()
        await f.photos.notifyImported(imported)
        let observer = DirectoryObserverProbe(store: f.store)
        let engine = SyncEngine(store: f.store, photos: f.photos,
            directory: { GatedLivePhotoDirectory(sourceID: $0, folder: "z-held", entered: entered, gate: gate) },
            livePhotoDirectoryObserver: observer)
        let scan = Task { await engine.scanEnabledSources() }
        await fulfillment(of: [entered, imported], timeout: 5)
        let during = await f.photos.created; XCTAssertEqual(during, ["ready.jpg"])
        await gate.release(); await scan.value
        let after = await f.photos.created; XCTAssertEqual(after.count, 2)
    }

    func testDirectoryFailureHoldsOnlyThatDirectory() async throws {
        let f = try await directoryFixture(makeSingle: false); defer { try? FileManager.default.removeItem(at: f.root) }
        for name in ["a-good", "z-bad"] {
            let folder = f.source.appendingPathComponent(name); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try makeLivePhotoImage(at: folder.appendingPathComponent(name + ".jpg"), identifier: nil)
        }
        let bad = try await directoryStoredFile(sourceID: f.sourceID, url: f.source.appendingPathComponent("z-bad/z-bad.jpg"), root: f.source)
        let badID = try await f.store.save(bad, decision: .importNew)
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { FailingLivePhotoDirectory(sourceID: $0, failing: "z-bad") }, livePhotoDirectoryObserver: DirectoryObserverProbe(store: f.store))
        await engine.scanEnabledSources()
        let created = await f.photos.created; XCTAssertEqual(created, ["a-good.jpg"])
        let state = try await f.store.state(of: badID); XCTAssertEqual(state, .pending)
    }

    func testSingleUnreadableEntryDoesNotDiscardSiblings() async throws {
        let f = try await directoryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try Data("invalid".utf8).write(to: f.source.appendingPathComponent("corrupt.jpg"))
        let engine = SyncEngine(store: f.store, photos: f.photos, livePhotoDirectoryObserver: DirectoryObserverProbe(store: f.store))
        await engine.scanEnabledSources()
        let created = await f.photos.created; XCTAssertEqual(created, ["single.jpg"])
    }

    func testDeferredDirectoryAdmissionIsNotFileFailure() async throws {
        let f = try await directoryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let file = try await directoryStoredFile(sourceID: f.sourceID, url: f.source.appendingPathComponent("single.jpg"), root: f.source)
        let id = try await f.store.save(file, decision: .importNew), attempt = UUID()
        try await f.store.beginAttempt(fileID: id, attemptID: attempt)
        try await f.store.deferUnsubmittedAttempt(fileID: id, attemptID: attempt, nextRetry: Date())
        let summary = try await f.store.activeSourceSummary()
        XCTAssertEqual(summary.pending, 1); XCTAssertEqual(summary.retryPending, 0)
    }

    func testUnchangedImportedAndSkippedFilesGetIdentityWithoutReimport() async throws {
        let f = try await directoryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try makeLivePhotoImage(at: f.source.appendingPathComponent("skipped.jpg"), identifier: nil)
        let file = try await directoryStoredFile(sourceID: f.sourceID, url: f.source.appendingPathComponent("single.jpg"), root: f.source)
        let first = try await f.store.save(file, decision: .importNew), attempt = UUID()
        try await f.store.beginAttempt(fileID: first, attemptID: attempt); try await f.store.markImported(fileID: first, attemptID: attempt, identifier: "retained")
        let secondFile = try await directoryStoredFile(sourceID: f.sourceID, url: f.source.appendingPathComponent("skipped.jpg"), root: f.source)
        let second = try await f.store.save(secondFile, decision: .skip(candidateKeys: []))
        let engine = SyncEngine(store: f.store, photos: f.photos, livePhotoDirectoryObserver: DirectoryObserverProbe(store: f.store))
        await engine.scanEnabledSources()
        let a = try await f.store.livePhotoObservation(for: .source(fileID: first, stamp: file.stamp))
        let b = try await f.store.livePhotoObservation(for: .source(fileID: second, stamp: secondFile.stamp))
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        let created = await f.photos.created; XCTAssertTrue(created.isEmpty)
        let success = try await f.store.successIdentifier(of: first); XCTAssertEqual(success, "retained")
    }
}

private struct LongVideoMetadata: MetadataReading {
    func read(url: URL, filename: String) async throws -> MediaMetadata {
        .init(filename: filename, kind: .video, captureSecond: nil, rawCaptureTime: nil, rawCaptureOffset: nil,
              make: nil, model: nil, width: 16, height: 16, duration: 60)
    }
}
private actor DirectoryIdentificationCounter: LivePhotoMetadataReading {
    var reads = 0
    func inspect(url: URL, kind: MediaKind) async throws -> LivePhotoInspection { reads += 1; return .noIdentifier }
}

actor DirectoryTestGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { if released { return }; await withCheckedContinuation { continuation = $0 } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

actor DirectoryObserverProbe: LivePhotoDirectoryObserving {
    let store: SyncStore
    let reservePairs: Bool
    let holdDirectory: String?
    let entered: XCTestExpectation?
    let gate: DirectoryTestGate?
    init(store: SyncStore, reservePairs: Bool = false, holdDirectory: String? = nil, entered: XCTestExpectation? = nil, gate: DirectoryTestGate? = nil) {
        self.store = store; self.reservePairs = reservePairs; self.holdDirectory = holdDirectory; self.entered = entered; self.gate = gate
    }
    func observeDirectory(sourceID: UUID, relativeDirectory: String, fileIDs: [UUID]) async throws {
        if relativeDirectory == holdDirectory { entered?.fulfill(); await gate?.wait() }
        guard reservePairs else { return }
        var values = [(StoredFile, LivePhotoIdentity)]()
        for id in fileIDs {
            if let file = try await store.sourceFile(id: id), let observation = try await store.livePhotoObservation(for: .source(fileID: id, stamp: file.file.stamp)), let identity = observation.identity { values.append((file, identity)) }
        }
        guard let p = values.first(where: { $0.1.role == .photo }), let m = values.first(where: { $0.1.role == .motion }), p.1.contentIdentifier == m.1.contentIdentifier else { return }
        _ = try await store.reserveLivePhotoOperation(.init(context: .init(id: UUID(), epoch: 0), contentIdentifier: p.1.contentIdentifier,
            photo: .source(fileID: p.0.id, stamp: p.0.file.stamp), motion: .source(fileID: m.0.id, stamp: m.0.file.stamp), sourceFileIDs: [p.0.id, m.0.id]))
    }
}

actor DirectoryPhotos: PhotosGateway {
    var created = [String]()
    var imported: XCTestExpectation?
    func notifyImported(_ value: XCTestExpectation) { imported = value }
    func candidateSnapshot() async throws -> PhotosCandidateSnapshot { .init(generation: 0, candidates: []) }
    func create(fileURL: URL, kind: MediaKind, expectedGeneration: Int, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        try await create(fileURL: fileURL, kind: kind, expectedGeneration: expectedGeneration, beforeMutation: { true }, onPlaceholder: onPlaceholder)
    }
    func create(fileURL: URL, kind: MediaKind, expectedGeneration: Int, beforeMutation: @escaping @Sendable () throws -> Bool, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        guard try beforeMutation() else { throw PhotosAdmissionDeferred() }
        let id = UUID().uuidString; try onPlaceholder(id); created.append(fileURL.lastPathComponent)
        imported?.fulfill(); imported = nil
        return id
    }
    func reconcile(placeholder: String?) async throws -> ImportEvidence { .unknown }
}
struct FailingLivePhotoDirectory: DirectoryReading {
    let sourceID: UUID, failing: String
    func entries(in directory: URL) async throws -> [DirectoryEntry] {
        if directory.lastPathComponent == failing { throw CocoaError(.fileReadNoPermission) }
        return try await DirectoryReader(sourceID: sourceID).entries(in: directory)
    }
    func stamp(of file: URL) async throws -> FileStamp { try await DirectoryReader(sourceID: sourceID).stamp(of: file) }
}
func directoryStoredFile(sourceID: UUID, url: URL, root: URL) async throws -> SourceFile {
    .init(sourceID: sourceID, relativePath: String(url.path.dropFirst(root.path.count + 1)), url: url,
          stamp: try await DirectoryReader(sourceID: sourceID).stamp(of: url), metadata: try await MetadataReader(sourceID: sourceID).read(url: url, filename: url.lastPathComponent))
}
func directoryFixture(makeSingle: Bool = true) async throws -> (root: URL, source: URL, sourceID: UUID, store: SyncStore, photos: DirectoryPhotos) {
    let root = try temporaryDirectory(), source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    if makeSingle { try makeLivePhotoImage(at: source.appendingPathComponent("single.jpg"), identifier: nil) }
    let store = try SyncStore(url: root.appendingPathComponent("state.sqlite")), sourceID = try await store.registerSource(url: source)
    return (root, source, sourceID, store, DirectoryPhotos())
}

struct GatedLivePhotoDirectory: DirectoryReading {
    let sourceID: UUID
    let folder: String
    let entered: XCTestExpectation
    let gate: DirectoryTestGate
    func entries(in directory: URL) async throws -> [DirectoryEntry] {
        if directory.lastPathComponent == folder { entered.fulfill(); await gate.wait() }
        return try await DirectoryReader(sourceID: sourceID).entries(in: directory)
    }
    func stamp(of file: URL) async throws -> FileStamp { try await DirectoryReader(sourceID: sourceID).stamp(of: file) }
}
