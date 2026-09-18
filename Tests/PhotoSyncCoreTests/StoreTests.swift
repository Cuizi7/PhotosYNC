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

    func testActiveSourceSummaryCountsCurrentStatesOnceAndExcludesInactiveSources() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let active = root.appendingPathComponent("active")
        let disabled = root.appendingPathComponent("disabled")
        let removed = root.appendingPathComponent("removed")
        for directory in [active, disabled, removed] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let activeID = try await store.registerSource(url: active)
        let disabledID = try await store.registerSource(url: disabled)
        let removedID = try await store.registerSource(url: removed)

        let imported = try await store.save(source(sourceID: activeID, root: active, relativePath: "imported.jpg"), decision: .importNew)
        let importedAttempt = UUID()
        try await store.beginAttempt(fileID: imported, attemptID: importedAttempt)
        try await store.markImported(fileID: imported, attemptID: importedAttempt, identifier: "asset-imported")

        let changed = try await store.save(source(sourceID: activeID, root: active, relativePath: "changed.jpg"), decision: .importNew)
        let changedAttempt = UUID()
        try await store.beginAttempt(fileID: changed, attemptID: changedAttempt)
        try await store.markImported(fileID: changed, attemptID: changedAttempt, identifier: "asset-changed")
        try await store.recordSourceChange(fileID: changed, stamp: FileStamp(size: 13, modifiedNanoseconds: 11))

        let duplicate = try await store.save(source(sourceID: activeID, root: active, relativePath: "duplicate.jpg"), decision: .importNew)
        try await store.markSkipped(fileID: duplicate, reason: .suspectedDuplicate, candidates: [])
        _ = try await store.save(source(sourceID: activeID, root: active, relativePath: "pending.jpg"), decision: .importNew)
        // One pending record with a definite not-committed failure: it stays pending as a state,
        // but the summary separates it so counters never double count the same record.
        let retrying = try await store.save(source(sourceID: activeID, root: active, relativePath: "retrying.jpg"), decision: .importNew)
        try await store.recordRetry(fileID: retrying, attemptID: nil, nextRetry: Date(), error: "definitely not committed", definitelyNotCommitted: true)
        let importing = try await store.save(source(sourceID: activeID, root: active, relativePath: "importing.jpg"), decision: .importNew)
        try await store.beginAttempt(fileID: importing, attemptID: UUID())

        _ = try await store.save(source(sourceID: disabledID, root: disabled, relativePath: "ignored-pending.jpg"), decision: .importNew)
        // History of a retired source stays in the database but leaves the counters, so the
        // summary reports it separately instead of silently dropping it.
        let retired = try await store.save(source(sourceID: disabledID, root: disabled, relativePath: "retired.jpg"), decision: .importNew)
        let retiredAttempt = UUID()
        try await store.beginAttempt(fileID: retired, attemptID: retiredAttempt)
        try await store.markImported(fileID: retired, attemptID: retiredAttempt, identifier: "asset-retired")
        try await store.disableSource(id: disabledID)
        _ = try await store.save(source(sourceID: removedID, root: removed, relativePath: "ignored-pending.jpg"), decision: .importNew)
        let removedFile = try await store.save(source(sourceID: removedID, root: removed, relativePath: "removed.jpg"), decision: .importNew)
        let removedAttempt = UUID()
        try await store.beginAttempt(fileID: removedFile, attemptID: removedAttempt)
        try await store.markImported(fileID: removedFile, attemptID: removedAttempt, identifier: "asset-removed")
        try await store.removeSource(id: removedID)

        let summary = try await store.activeSourceSummary()

        XCTAssertEqual(summary, SyncStatusSummary(imported: 1, skipped: 2, pending: 1, importing: 1,
                                                  retryPending: 1, retainedImported: 2))
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

    func testReaddingRemovedSourceRejectsActiveOverlapAndKeepsTombstone() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let parent = root.appendingPathComponent("archive")
        let child = parent.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let parentID = try await store.registerSource(url: parent)
        try await store.removeSource(id: parentID)
        let childID = try await store.registerSource(url: child)

        await XCTAssertThrowsErrorAsync(try await store.registerSource(url: parent))
        let visibleSources = try await store.sources()
        let retainedParent = try await store.source(id: parentID)
        XCTAssertEqual(visibleSources.map(\.id), [childID])
        XCTAssertFalse(retainedParent.enabled)
    }

    func testRemovedSourceIsHiddenButRetainsHistoryAndReaddingRestoresIdentity() async throws {
        let root = try makeRoot()
        let database = root.appendingPathComponent("state.sqlite")
        let sourceDirectory = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceID: UUID
        let fileID: UUID
        let pendingID: UUID
        do {
            let store = try SyncStore(url: database)
            sourceID = try await store.registerSource(url: sourceDirectory)
            fileID = try await store.save(source(sourceID: sourceID, root: sourceDirectory), decision: .importNew)
            let attempt = UUID()
            try await store.beginAttempt(fileID: fileID, attemptID: attempt)
            try await store.markImported(fileID: fileID, attemptID: attempt, identifier: "asset-1")
            pendingID = try await store.save(source(sourceID: sourceID, root: sourceDirectory, relativePath: "pending.jpg"), decision: .importNew)

            try await store.removeSource(id: sourceID)
            let visibleSources = try await store.sources()
            let retainedSource = try await store.source(id: sourceID)
            let successIdentifier = try await store.successIdentifier(of: fileID)
            let actionablePending = try await store.countEnabledFiles(state: .pending)
            XCTAssertTrue(visibleSources.isEmpty)
            XCTAssertFalse(retainedSource.enabled)
            XCTAssertEqual(successIdentifier, "asset-1")
            XCTAssertEqual(actionablePending, 0)
        }

        let reopened = try SyncStore(url: database)
        let hiddenSources = try await reopened.sources()
        XCTAssertTrue(hiddenSources.isEmpty)
        let restoredID = try await reopened.registerSource(url: sourceDirectory)
        let restoredSources = try await reopened.sources()
        let retainedSuccessIdentifier = try await reopened.successIdentifier(of: fileID)
        let retainedPending = try await reopened.state(of: pendingID)
        XCTAssertEqual(restoredID, sourceID)
        XCTAssertEqual(restoredSources.map(\.id), [sourceID])
        XCTAssertEqual(retainedSuccessIdentifier, "asset-1")
        XCTAssertEqual(retainedPending, .pending)
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
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA user_version = 4", nil, nil, nil), SQLITE_OK)

        XCTAssertThrowsError(try SyncStore(url: database))
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 4)
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

extension StoreTests {
    func testHeldSourceValidationCannotBlockStoreOrPlaceholderCheckpoint() async throws {
        let fixture = try await makeEngineFixture(sourceCount: 1)
        let gate = DispatchSemaphore(value: 0)
        let entered = expectation(description: "physical validation entered")
        let reader = ReadExecutor(maxConcurrentOperations: 1, defaultTimeout: .seconds(30))
        let store = try SyncStore(url: fixture.databaseURL, readExecutor: reader, validateSource: { url in
            entered.fulfill()
            gate.wait()
            return try SourceRegistry.normalizedURL(url)
        })
        let file = try await engineSourceFile(sourceID: fixture.sourceIDs[0], directory: fixture.directories[0])
        let fileID = try await store.save(file, decision: .importNew)
        let attempt = UUID()
        try await store.beginAttempt(fileID: fileID, attemptID: attempt)
        let second = try temporaryDirectory()
        let registration = Task { try await store.registerSource(url: second) }
        defer { gate.signal() }
        await fulfillment(of: [entered], timeout: 2)
        let checked = expectation(description: "checkpoint and DB reads remain live")
        let checkpoint = Task.detached {
            try store.checkpointPlaceholder(fileID: fileID, attemptID: attempt, identifier: "held-validation-proof")
            _ = try await store.sources()
            checked.fulfill()
        }
        await fulfillment(of: [checked], timeout: 2)
        gate.signal()
        _ = try await registration.value
        try await checkpoint.value
        let result = try await store.file(sourceID: fixture.sourceIDs[0], relativePath: "same.jpg")
        XCTAssertEqual(result?.placeholderID, "held-validation-proof")
    }
}

extension StoreTests {
    func testSchemaOneMigrationRetainsMediaAndOpensLegacyAttributeTable() async throws {
        let fixture = try await makeEngineFixture(sourceCount: 1)
        let file = try await engineSourceFile(sourceID: fixture.sourceIDs[0], directory: fixture.directories[0])
        _ = try await fixture.store.save(file, decision: .importNew)
        try injectEngineSQL("DROP TABLE non_media_skip; ALTER TABLE source DROP COLUMN removed; PRAGMA user_version = 1", at: fixture.databaseURL)
        let migrated = try SyncStore(url: fixture.databaseURL)
        XCTAssertEqual(try engineSQLInteger("PRAGMA user_version", at: fixture.databaseURL), 3)
        let pending = try await migrated.countFiles(state: .pending)
        XCTAssertEqual(pending, 1)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM non_media_skip", at: fixture.databaseURL), 0)
    }

    func testSchemaTwoMigrationAddsRemovedFlagAndRetainsSource() async throws {
        let root = try makeRoot()
        let database = root.appendingPathComponent("state.sqlite")
        let sourceID = UUID()
        let sourcePath = root.appendingPathComponent("photos").path
        try FileManager.default.createDirectory(atPath: sourcePath, withIntermediateDirectories: true)
        try injectEngineSQL("CREATE TABLE source (id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, enabled INTEGER NOT NULL, last_scan_at REAL, last_error TEXT); INSERT INTO source (id, path, enabled) VALUES ('\(sourceID.uuidString)', '\(sourcePath)', 1); PRAGMA user_version = 2", at: database)

        let migrated = try SyncStore(url: database)
        let sources = try await migrated.sources()
        XCTAssertEqual(try engineSQLInteger("PRAGMA user_version", at: database), 3)
        XCTAssertEqual(try engineSQLInteger("SELECT removed FROM source WHERE id = '\(sourceID.uuidString)'", at: database), 0)
        XCTAssertEqual(sources.map(\.id), [sourceID])
    }

    func testFreshSchemaLeavesLegacyAttributeTableEmpty() async throws {
        let root = try makeRoot()
        let sourceDirectory = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        _ = try await store.registerSource(url: sourceDirectory)

        let pending = try await store.countFiles(state: .pending)
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM non_media_skip", at: root.appendingPathComponent("state.sqlite")), 0)
    }
}
