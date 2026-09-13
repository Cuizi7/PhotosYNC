import Foundation
@testable import PhotoSyncCore
import AppKit
import ImageIO
import UniformTypeIdentifiers
import SQLite3

func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PhotoSyncTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func sourceFixtureDirectory() throws -> URL {
    let directory = try temporaryDirectory()
    let image = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 1,
        pixelsHigh: 1,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    image.setColor(NSColor.red, atX: 0, y: 0)
    guard let png = image.representation(using: .png, properties: [:]) else {
        throw FixtureError.unavailable("unable to create PNG")
    }

    try png.write(to: directory.appendingPathComponent("no-exif.png"))
    try makeJPEGFixture(
        at: directory.appendingPathComponent("normal.jpg"),
        captureTime: "2026:09:13 10:15:30",
        offset: "+08:00",
        make: "Fixture Make",
        model: "Fixture Model"
    )
    try png.write(to: directory.appendingPathComponent("photo.CR3"))
    try Data("not an image".utf8).write(to: directory.appendingPathComponent("corrupt.jpg"))
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("subdirectory"), withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent(".hidden"), withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("bundle.photoslibrary"), withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(
        at: directory.appendingPathComponent("linked.png"),
        withDestinationURL: directory.appendingPathComponent("no-exif.png")
    )
    return directory
}

private func makeJPEGFixture(
    at url: URL,
    captureTime: String,
    offset: String,
    make: String,
    model: String
) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw FixtureError.unavailable("unable to create JPEG destination")
    }
    let image = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 1,
        pixelsHigh: 1,
        bitsPerSample: 8,
        samplesPerPixel: 3,
        hasAlpha: false,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    guard let cgImage = image.cgImage else { throw FixtureError.unavailable("unable to create JPEG image") }
    let properties: [CFString: Any] = [
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: captureTime,
            kCGImagePropertyExifOffsetTimeOriginal: offset
        ],
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFMake: make,
            kCGImagePropertyTIFFModel: model
        ]
    ]
    CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw FixtureError.unavailable("unable to finalize JPEG") }
}

enum FixtureError: Error {
    case unavailable(String)
}

// Test-only Photos implementation. Never asks for system authorization.
actor FakePhotosGateway: PhotosGateway {
    private(set) var createCount = 0
    private var candidates: [MatchCandidate] = []
    private var loadFailure = false
    var evidence: ImportEvidence = .unknown
    private var creationGate: EngineTestGate?
    private var creationError: PhotoKitGatewayError?
    private var failIndexAfterCreate = false
    func setCreationGate(_ gate: EngineTestGate) { creationGate = gate }
    func setCreationError(_ error: PhotoKitGatewayError?) { creationError = error }
    func setFailIndexAfterCreate() { failIndexAfterCreate = true }
    func setCandidates(_ values: [MatchCandidate]) { candidates = values }
    func setLoadFailure(_ value: Bool) { loadFailure = value }
    func setEvidence(_ value: ImportEvidence) { evidence = value }
    func loadCandidates() async throws -> [MatchCandidate] {
        if loadFailure { throw PhotoKitGatewayError.libraryUnavailable }
        return candidates
    }
    func reconcile(placeholder: String?) async throws -> ImportEvidence { evidence }
    func create(fileURL: URL, kind: MediaKind, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        createCount += 1
        let id = "fake-\(createCount)"
        try onPlaceholder(id)
        if let creationGate { await creationGate.wait() }
        if let creationError { throw creationError }
        if failIndexAfterCreate { loadFailure = true }
        let metadata = try await MetadataReader().read(url: fileURL, filename: fileURL.lastPathComponent)
        candidates.append(MatchCandidate(key: id, metadata: metadata))
        return id
    }
}

func engineSourceFile(sourceID: UUID, directory: URL) async throws -> SourceFile {
    let url = directory.appendingPathComponent("same.jpg")
    return SourceFile(sourceID: sourceID, relativePath: "same.jpg", url: url,
        stamp: try await DirectoryReader(sourceID: sourceID).stamp(of: url),
        metadata: try await MetadataReader(sourceID: sourceID).read(url: url, filename: "same.jpg"))
}

func makeEngineFixture(sourceCount: Int = 2) async throws -> (engine: SyncEngine, sourceIDs: [UUID], photos: FakePhotosGateway, store: SyncStore, directories: [URL], databaseURL: URL) {
    let root = try temporaryDirectory()
    let databaseURL = root.appendingPathComponent("store.sqlite")
    let store = try SyncStore(url: databaseURL)
    var ids: [UUID] = []
    var directories: [URL] = []
    for index in 0..<sourceCount {
        let directory = root.appendingPathComponent("source-\(index)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try makeJPEGFixture(at: directory.appendingPathComponent("same.jpg"), captureTime: "2026:09:13 10:15:30", offset: "+08:00", make: "Fixture", model: "Camera")
        ids.append(try await store.registerSource(url: directory))
        directories.append(directory)
    }
    let photos = FakePhotosGateway()
    return (SyncEngine(store: store, photos: photos), ids, photos, store, directories, databaseURL)
}

actor EngineTestGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = false
    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { released = true; waiters.forEach { $0.resume() }; waiters = [] }
}

struct GatedDirectoryReader: DirectoryReading {
    let reader: DirectoryReader
    let gate: EngineTestGate
    func entries(in directory: URL) async throws -> [DirectoryEntry] {
        await gate.wait()
        return try await reader.entries(in: directory)
    }
    func stamp(of file: URL) async throws -> FileStamp { try await reader.stamp(of: file) }
}

func injectEngineSQL(_ sql: String, at url: URL) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw FixtureError.unavailable("sqlite open") }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.unavailable(String(cString: sqlite3_errmsg(db))) }
}

func engineEventually(_ condition: () async throws -> Bool) async rethrows -> Bool {
    for _ in 0..<500 {
        if try await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return false
}

actor SubmissionStampReader: DirectoryReading {
    let reader: DirectoryReader
    let gate: EngineTestGate?
    let failSubmissionStamp: Bool
    let failSubmissionStampOnce: Bool
    private var stamps = 0
    private var emittedFailure = false
    init(sourceID: UUID, gate: EngineTestGate? = nil, failSubmissionStamp: Bool = false, failSubmissionStampOnce: Bool = false) {
        reader = DirectoryReader(sourceID: sourceID)
        self.gate = gate; self.failSubmissionStamp = failSubmissionStamp; self.failSubmissionStampOnce = failSubmissionStampOnce
    }
    func entries(in directory: URL) async throws -> [DirectoryEntry] { try await reader.entries(in: directory) }
    func stamp(of file: URL) async throws -> FileStamp {
        stamps += 1
        if stamps > 1 {
            if let gate { await gate.wait() }
            if failSubmissionStamp && (!failSubmissionStampOnce || !emittedFailure) {
                emittedFailure = true
                throw FixtureError.unavailable("submission stat unavailable")
            }
        }
        return try await reader.stamp(of: file)
    }
}

func engineSQLInteger(_ sql: String, at url: URL) throws -> Int {
    var db: OpaquePointer?, statement: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw FixtureError.unavailable("sqlite open") }
    defer { sqlite3_finalize(statement); sqlite3_close(db) }
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else {
        throw FixtureError.unavailable("sqlite query")
    }
    return Int(sqlite3_column_int64(statement, 0))
}

actor JournalRaceReader: DirectoryReading {
    let real: DirectoryReader
    let directoryGate: EngineTestGate
    private var stamps = 0
    init(sourceID: UUID, gate: EngineTestGate) { real = DirectoryReader(sourceID: sourceID); directoryGate = gate }
    func entries(in directory: URL) async throws -> [DirectoryEntry] {
        if directory.lastPathComponent == "held" { await directoryGate.wait() }
        return try await real.entries(in: directory)
    }
    func stamp(of file: URL) async throws -> FileStamp {
        stamps += 1
        if stamps > 1 { throw FixtureError.unavailable("pending submission stat failed") }
        return try await real.stamp(of: file)
    }
}
