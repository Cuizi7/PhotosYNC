import XCTest
import PhotoSyncCore
import SQLite3

final class StoreTests: XCTestCase {
    func testSuccessfulRetryResetsFailureCount() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("store.sqlite"))
        let sourceID = try await store.registerSource(url: root)
        let file = source(sourceID: sourceID, root: root)
        let id = try await store.save(file, decision: .importNew)
        let failedAttempt = UUID()
        try await store.beginAttempt(fileID: id, attemptID: failedAttempt)
        try await store.recordRetry(fileID: id, attemptID: failedAttempt, nextRetry: Date(), error: "temporary", definitelyNotCommitted: true)
        let successfulAttempt = UUID()
        try await store.beginAttempt(fileID: id, attemptID: successfulAttempt)
        try await store.markImported(fileID: id, attemptID: successfulAttempt, identifier: "asset")

        let stored = try await store.file(sourceID: sourceID, relativePath: "a.jpg")
        XCTAssertEqual(stored?.retryCount, 0)
    }
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots.removeAll()
    }

    func testSourceChangeKeepsImportedHistory() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let sourceID = try await store.registerSource(url: root)
        let file = source(sourceID: sourceID, root: root, relativePath: "a.jpg", size: 12, modified: 10)
        let id = try await store.save(file, decision: .importNew)
        let attempt = UUID()

        try await store.beginAttempt(fileID: id, attemptID: attempt)
        try await store.markImported(fileID: id, attemptID: attempt, identifier: "asset-1")
        try await store.recordSourceChange(fileID: id, stamp: FileStamp(size: 15, modifiedNanoseconds: 20))

        let state = try await store.state(of: id)
        let history = try await store.successIdentifier(of: id)
        XCTAssertEqual(state, .skipped)
        XCTAssertEqual(history, "asset-1")
    }

    func testReopenPreservesSuccessHistory() async throws {
        let root = try makeRoot()
        let database = root.appendingPathComponent("state.sqlite")
        let sourceID: UUID
        let fileID: UUID
        do {
            let store = try SyncStore(url: database)
            sourceID = try await store.registerSource(url: root)
            fileID = try await store.save(source(sourceID: sourceID, root: root), decision: .importNew)
            let attempt = UUID()
            try await store.beginAttempt(fileID: fileID, attemptID: attempt)
            try await store.markImported(fileID: fileID, attemptID: attempt, identifier: "asset-1")
        }

        let reopened = try SyncStore(url: database)
        let history = try await reopened.successIdentifier(of: fileID)
        let state = try await reopened.state(of: fileID)
        XCTAssertEqual(history, "asset-1")
        XCTAssertEqual(state, .imported)
    }

    func testSourcePathConflictsUsePathComponentsAndDisabledSourceRetainsIdentity() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let parent = root.appendingPathComponent("archive")
        let sibling = root.appendingPathComponent("archive-old")
        let child = parent.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let id = try await store.registerSource(url: parent)
        _ = try await store.registerSource(url: sibling)
        await XCTAssertThrowsErrorAsync(try await store.registerSource(url: child))
        try await store.disableSource(id: id)
        let reenabledID = try await store.registerSource(url: parent)
        XCTAssertEqual(reenabledID, id)
    }

    func testAttemptCallbacksRequireCurrentAttempt() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let sourceID = try await store.registerSource(url: root)
        let id = try await store.save(source(sourceID: sourceID, root: root), decision: .importNew)
        let first = UUID()
        let late = UUID()

        try await store.beginAttempt(fileID: id, attemptID: first)
        await XCTAssertThrowsErrorAsync(try await store.markImported(fileID: id, attemptID: late, identifier: "late"))
        let state = try await store.state(of: id)
        let successID = try await store.successIdentifier(of: id)
        XCTAssertEqual(state, .importing)
        XCTAssertNil(successID)
    }

    func testSkippedFileWithSuccessUsesSuccessSnapshotAsCandidate() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let sourceID = try await store.registerSource(url: root)
        let id = try await store.save(source(sourceID: sourceID, root: root), decision: .importNew)
        let attempt = UUID()

        try await store.beginAttempt(fileID: id, attemptID: attempt)
        try await store.markImported(fileID: id, attemptID: attempt, identifier: "asset-1")
        try await store.markSkipped(fileID: id, reason: .sourceChanged, candidates: [])

        let state = try await store.state(of: id)
        let candidates = try await store.candidates(filename: "a.jpg", excludingID: nil)
        XCTAssertEqual(state, .skipped)
        XCTAssertEqual(candidates, [MatchCandidate(key: "file:\(id.uuidString)", metadata: media("a.jpg"))])
    }

    func testListFilesOnlyReturnsRequestedStateWithStablePagination() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let sourceID = try await store.registerSource(url: root)
        let first = try await store.save(source(sourceID: sourceID, root: root, relativePath: "a.jpg"), decision: .importNew)
        let second = try await store.save(source(sourceID: sourceID, root: root, relativePath: "b.jpg"), decision: .importNew)
        let skipped = try await store.save(source(sourceID: sourceID, root: root, relativePath: "c.jpg"), decision: .importNew)
        try await store.markSkipped(fileID: skipped, reason: .unsupportedFormat, candidates: [])

        let firstPage = try await store.listFiles(state: .pending, afterID: nil, limit: 1).map(\.id)
        let secondPage = try await store.listFiles(state: .pending, afterID: first, limit: 10).map(\.id)
        XCTAssertEqual(firstPage, [first])
        XCTAssertEqual(secondPage, [second])
    }

    func testDuplicateSourceRelativePathIsRejected() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let sourceID = try await store.registerSource(url: root)
        _ = try await store.save(source(sourceID: sourceID, root: root), decision: .importNew)

        await XCTAssertThrowsErrorAsync(try await store.save(source(sourceID: sourceID, root: root), decision: .importNew))
    }

    func testEvidenceConstraintFailureRollsBackStateChange() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let sourceID = try await store.registerSource(url: root)
        let id = try await store.save(source(sourceID: sourceID, root: root), decision: .importNew)
        let candidate = MatchCandidate(key: "duplicate", metadata: media("a.jpg"))

        await XCTAssertThrowsErrorAsync(try await store.markSkipped(fileID: id, reason: .suspectedDuplicate, candidates: [candidate, candidate]))

        let state = try await store.state(of: id)
        XCTAssertEqual(state, .pending)
    }

    func testSaveSkipPersistsActualCandidateSnapshots() async throws {
        let root = try makeRoot()
        let database = root.appendingPathComponent("state.sqlite")
        let store = try SyncStore(url: database)
        let sourceID = try await store.registerSource(url: root)
        let candidate = MatchCandidate(key: "photos:1", metadata: media("existing.jpg", second: 20, make: "Canon", model: "R5"))

        let id = try await store.save(source(sourceID: sourceID, root: root), decision: .skip(candidateKeys: [candidate.key]), candidates: [candidate])

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT candidate_json FROM match_evidence WHERE file_id = ?", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_bind_text(statement, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let stored = try JSONDecoder().decode(MatchCandidate.self, from: Data(String(cString: sqlite3_column_text(statement, 0)).utf8))
        XCTAssertEqual(stored, candidate)
    }

    func testUncertainRetryKeepsAttemptAndPlaceholderImporting() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let sourceID = try await store.registerSource(url: root)
        let id = try await store.save(source(sourceID: sourceID, root: root), decision: .importNew)
        let attempt = UUID()
        try await store.beginAttempt(fileID: id, attemptID: attempt)
        try store.checkpointPlaceholder(fileID: id, attemptID: attempt, identifier: "placeholder")

        try await store.recordRetry(fileID: id, attemptID: attempt, nextRetry: Date(), error: "unknown", definitelyNotCommitted: false)

        let maybeStored = try await store.file(sourceID: sourceID, relativePath: "a.jpg")
        let stored = try XCTUnwrap(maybeStored)
        XCTAssertEqual(stored.state, .importing)
        XCTAssertEqual(stored.attemptID, attempt)
        XCTAssertEqual(stored.placeholderID, "placeholder")
    }

    func testRetryRejectsNilOrOldAttemptAgainstImportingAndImportedRecords() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let sourceID = try await store.registerSource(url: root)
        let id = try await store.save(source(sourceID: sourceID, root: root), decision: .importNew)
        let first = UUID()
        try await store.beginAttempt(fileID: id, attemptID: first)
        await XCTAssertThrowsErrorAsync(try await store.recordRetry(fileID: id, attemptID: nil, nextRetry: Date(), error: "late", definitelyNotCommitted: true))
        await XCTAssertThrowsErrorAsync(try await store.recordRetry(fileID: id, attemptID: UUID(), nextRetry: Date(), error: "old", definitelyNotCommitted: true))
        try await store.markImported(fileID: id, attemptID: first, identifier: "asset")
        await XCTAssertThrowsErrorAsync(try await store.recordRetry(fileID: id, attemptID: nil, nextRetry: Date(), error: "late", definitelyNotCommitted: true))
        let finalState = try await store.state(of: id)
        XCTAssertEqual(finalState, .imported)
    }

    func testOldRetryCannotResetNewAttempt() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let sourceID = try await store.registerSource(url: root)
        let id = try await store.save(source(sourceID: sourceID, root: root), decision: .importNew)
        let oldAttempt = UUID()
        let newAttempt = UUID()
        try await store.beginAttempt(fileID: id, attemptID: oldAttempt)
        try await store.recordRetry(fileID: id, attemptID: oldAttempt, nextRetry: Date(), error: "definite", definitelyNotCommitted: true)
        try await store.beginAttempt(fileID: id, attemptID: newAttempt)

        await XCTAssertThrowsErrorAsync(try await store.recordRetry(fileID: id, attemptID: oldAttempt, nextRetry: Date(), error: "late", definitelyNotCommitted: true))
        let maybeStored = try await store.file(sourceID: sourceID, relativePath: "a.jpg")
        let stored = try XCTUnwrap(maybeStored)
        XCTAssertEqual(stored.state, .importing)
        XCTAssertEqual(stored.attemptID, newAttempt)
    }

    func testSourceRegistrationRejectsFilesAndLinks() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let directory = root.appendingPathComponent("photos")
        let file = root.appendingPathComponent("not-a-directory")
        let link = root.appendingPathComponent("photos-link")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data())
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)

        _ = try await store.registerSource(url: directory)
        await XCTAssertThrowsErrorAsync(try await store.registerSource(url: file))
        await XCTAssertThrowsErrorAsync(try await store.registerSource(url: link))
    }

    func testFutureSchemaIsRejectedWithoutReplacingDatabase() throws {
        let root = try makeRoot()
        let database = root.appendingPathComponent("state.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA user_version = 2", nil, nil, nil), SQLITE_OK)

        XCTAssertThrowsError(try SyncStore(url: database))
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 2)
    }

    private func makeRoot() throws -> URL {
        let root = try temporaryDirectory()
        roots.append(root)
        return root
    }

    private func source(
        sourceID: UUID,
        root: URL,
        relativePath: String = "a.jpg",
        size: Int64 = 12,
        modified: Int64 = 10
    ) -> SourceFile {
        SourceFile(
            sourceID: sourceID,
            relativePath: relativePath,
            url: root.appendingPathComponent(relativePath),
            stamp: FileStamp(size: size, modifiedNanoseconds: modified),
            metadata: media(relativePath)
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
