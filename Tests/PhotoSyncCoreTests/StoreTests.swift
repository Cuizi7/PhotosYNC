import XCTest
@testable import PhotoSyncCore
import SQLite3

final class StoreTests: XCTestCase {
    func testDeletedLocalCandidateCannotBecomeNewSkipEvidence() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let firstRoot = root.appendingPathComponent("first")
        let secondRoot = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let firstSource = try await store.registerSource(url: firstRoot)
        let secondSource = try await store.registerSource(url: secondRoot)
        let first = source(sourceID: firstSource, root: firstRoot, relativePath: "same.jpg")
        let firstID = try await store.save(first, decision: .importNew)
        let candidate = MatchCandidate(key: "file:\(firstID.uuidString)", metadata: first.metadata)
        let second = source(sourceID: secondSource, root: secondRoot, relativePath: "same.jpg")
        let validity = PhotosCandidateSnapshot(generation: 0, candidates: []).candidateValidity
        let removed = try await store.removeConfirmedAbsentPending(fileID: firstID)
        XCTAssertTrue(removed)

        let result = try await store.saveWithSnapshotValidity(second,
            decision: .skip(candidateKeys: [candidate.key]), candidates: [candidate], validity: validity)

        guard case .staleSnapshot = result else { return XCTFail("Deleted local candidate must invalidate the skip") }
        let secondRecord = try await store.file(sourceID: secondSource, relativePath: "same.jpg")
        XCTAssertNil(secondRecord)
    }

    func testDeletedLocalCandidateCannotSkipExistingPendingFile() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let sourceID = try await store.registerSource(url: root)
        let first = source(sourceID: sourceID, root: root, relativePath: "first.jpg")
        let firstID = try await store.save(first, decision: .importNew)
        let secondID = try await store.save(source(sourceID: sourceID, root: root, relativePath: "second.jpg"), decision: .importNew)
        let candidate = MatchCandidate(key: "file:\(firstID.uuidString)", metadata: first.metadata)
        let removed = try await store.removeConfirmedAbsentPending(fileID: firstID)
        XCTAssertTrue(removed)

        let result = try await store.markSkippedWithSnapshotValidity(fileID: secondID,
            reason: .suspectedDuplicate, candidates: [candidate],
            validity: PhotosCandidateSnapshot(generation: 0, candidates: []).candidateValidity)

        guard case .staleSnapshot = result else { return XCTFail("Deleted local candidate must invalidate the skip") }
        let state = try await store.state(of: secondID)
        XCTAssertEqual(state, .pending)
    }

    func testPendingQueueCanAdvanceAfterCursorRecordWasDeleted() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let sourceID = try await store.registerSource(url: root)
        let firstID = try await store.save(source(sourceID: sourceID, root: root, relativePath: "first.jpg"), decision: .importNew)
        let secondID = try await store.save(source(sourceID: sourceID, root: root, relativePath: "second.jpg"), decision: .importNew)
        let firstOptional = try await store.nextPendingFile(sourceIDs: [sourceID], afterOrder: nil)
        let first = try XCTUnwrap(firstOptional)
        XCTAssertEqual(first.id, firstID)
        let removed = try await store.removeConfirmedAbsentPending(fileID: firstID)
        XCTAssertTrue(removed)

        let next = try await store.nextPendingFile(sourceIDs: [sourceID], afterOrder: first.createdOrder)
        XCTAssertEqual(next?.id, secondID)
    }

    func testConfirmedAbsentPendingRemovesRetryAndReopensDependentDuplicate() async throws {
        let root = try makeRoot()
        let database = root.appendingPathComponent("state.sqlite")
        let store = try SyncStore(url: database)
        let sourceID = try await store.registerSource(url: root)
        let missing = source(sourceID: sourceID, root: root, relativePath: "missing.jpg")
        let missingID = try await store.save(missing, decision: .importNew)
        try await store.recordRetry(fileID: missingID, attemptID: nil, nextRetry: Date(timeIntervalSince1970: 0),
                                    error: "missing before submission", definitelyNotCommitted: true)
        let candidate = MatchCandidate(key: "file:\(missingID.uuidString)", metadata: missing.metadata)
        let duplicate = source(sourceID: sourceID, root: root, relativePath: "elsewhere/missing.jpg")
        let duplicateID = try await store.save(duplicate, decision: .skip(candidateKeys: [candidate.key]), candidates: [candidate])

        let before = try await store.pendingPaths(sourceID: sourceID)
        XCTAssertEqual(before["missing.jpg"], missingID)
        let removed = try await store.removeConfirmedAbsentPending(fileID: missingID)

        XCTAssertTrue(removed)
        let deletedRecord = try await store.file(sourceID: sourceID, relativePath: "missing.jpg")
        let reopenedState = try await store.state(of: duplicateID)
        let dueSources = try await store.dueRetrySourceIDs(at: Date())
        let removedAgain = try await store.removeConfirmedAbsentPending(fileID: missingID)
        XCTAssertNil(deletedRecord)
        XCTAssertEqual(reopenedState, .pending)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM match_evidence WHERE file_id = '\(duplicateID.uuidString)'", at: database), 0)
        XCTAssertEqual(dueSources, [])
        XCTAssertFalse(removedAgain)
    }

    func testConfirmedAbsentPendingPreservesSubmittedAndImportedRecords() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let sourceID = try await store.registerSource(url: root)
        let importingID = try await store.save(source(sourceID: sourceID, root: root, relativePath: "in-flight.jpg"), decision: .importNew)
        let attempt = UUID()
        try await store.beginAttempt(fileID: importingID, attemptID: attempt)
        let removedImporting = try await store.removeConfirmedAbsentPending(fileID: importingID)
        try await store.markImported(fileID: importingID, attemptID: attempt, identifier: "photos-success")
        let removedImported = try await store.removeConfirmedAbsentPending(fileID: importingID)
        let successID = try await store.successIdentifier(of: importingID)
        XCTAssertFalse(removedImporting)
        XCTAssertFalse(removedImported)
        XCTAssertEqual(successID, "photos-success")
    }
    func testNextPendingFileUsesStableCursorAndActiveSourceScope() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let activeRoot = root.appendingPathComponent("active")
        let disabledRoot = root.appendingPathComponent("disabled")
        try FileManager.default.createDirectory(at: activeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: disabledRoot, withIntermediateDirectories: true)
        let activeID = try await store.registerSource(url: activeRoot)
        let disabledID = try await store.registerSource(url: disabledRoot)

        let first = try await store.save(source(sourceID: activeID, root: activeRoot, relativePath: "first.jpg"), decision: .importNew)
        let second = try await store.save(source(sourceID: activeID, root: activeRoot, relativePath: "second.jpg"), decision: .importNew)
        _ = try await store.save(source(sourceID: disabledID, root: disabledRoot, relativePath: "disabled.jpg"), decision: .importNew)
        try await store.disableSource(id: disabledID)

        let selectedFirst = try await store.nextPendingFile(sourceIDs: [activeID, disabledID], afterOrder: nil)
        XCTAssertEqual(selectedFirst?.id, first)

        try await store.markSkipped(fileID: first, reason: .sourceChanged, candidates: [])
        let selectedSecond = try await store.nextPendingFile(sourceIDs: [activeID, disabledID], afterOrder: selectedFirst?.createdOrder)
        XCTAssertEqual(selectedSecond?.id, second)

        let empty = try await store.nextPendingFile(sourceIDs: [], afterOrder: nil)
        XCTAssertNil(empty)
        let pastEnd = try await store.nextPendingFile(sourceIDs: [activeID], afterOrder: Int64.max)
        XCTAssertNil(pastEnd)
    }

    func testNextPendingFileDecodesOnlyTheProcessedPrefixAcrossLargeQueue() async throws {
        let root = try makeRoot()
        let counter = DecodeCounter()
        let database = root.appendingPathComponent("state.sqlite")
        let store = try SyncStore(url: database, decodeObserver: { counter.increment() })
        let sourceID = try await store.registerSource(url: root)
        let metadata = "{\"filename\":\"synthetic.jpg\",\"kind\":\"image\",\"captureSecond\":null,\"rawCaptureTime\":null,\"rawCaptureOffset\":null,\"make\":null,\"model\":null,\"width\":1,\"height\":1,\"duration\":null}"
        try injectEngineSQL("""
            WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i + 1 FROM n WHERE i < 10000)
            INSERT INTO file_record (id, created_order, source_id, relative_path, filename, size, modified_ns, metadata_json, state, rule_version)
            SELECT printf('00000000-0000-0000-0000-%012d', i), i, '\(sourceID.uuidString)', printf('synthetic-%05d.jpg', i), 'synthetic.jpg', 1, 1, '\(metadata)', 'pending', 1 FROM n
            """, at: database)

        var cursor: Int64?
        for _ in 0..<16 {
            let selected = try await store.nextPendingFile(sourceIDs: [sourceID], afterOrder: cursor)
            cursor = try XCTUnwrap(selected?.createdOrder)
        }
        XCTAssertEqual(counter.value, 16)
    }

    func testNextPendingFileKeepsLateAppendsAndFutureRetriesVisibleAfterCursor() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let sourceID = try await store.registerSource(url: root)
        let firstID = try await store.save(source(sourceID: sourceID, root: root, relativePath: "first.jpg"), decision: .importNew)
        let secondID = try await store.save(source(sourceID: sourceID, root: root, relativePath: "second.jpg"), decision: .importNew)

        let firstOptional = try await store.nextPendingFile(sourceIDs: [sourceID], afterOrder: nil)
        let first = try XCTUnwrap(firstOptional)
        XCTAssertEqual(first.id, firstID)
        try await store.markSkipped(fileID: firstID, reason: .sourceChanged, candidates: [])

        let secondOptional = try await store.nextPendingFile(sourceIDs: [sourceID], afterOrder: first.createdOrder)
        let second = try XCTUnwrap(secondOptional)
        XCTAssertEqual(second.id, secondID)

        let lateID = try await store.save(source(sourceID: sourceID, root: root, relativePath: "late.jpg"), decision: .importNew)
        let lateOptional = try await store.nextPendingFile(sourceIDs: [sourceID], afterOrder: second.createdOrder)
        let late = try XCTUnwrap(lateOptional)
        XCTAssertEqual(late.id, lateID)

        let future = Date(timeIntervalSince1970: 10_000)
        try await store.recordRetry(fileID: lateID, attemptID: nil, nextRetry: future,
                                    error: "wait for retry", definitelyNotCommitted: true)
        let futureRetryOptional = try await store.nextPendingFile(sourceIDs: [sourceID], afterOrder: second.createdOrder)
        let futureRetry = try XCTUnwrap(futureRetryOptional)
        XCTAssertEqual(futureRetry.id, lateID)
        XCTAssertEqual(futureRetry.nextRetryAt, future)
    }

    func testFreshReopenedAndMigratedV3DatabasesKeepKeysetIndexAndHistory() async throws {
        let fixture = try await makeEngineFixture(sourceCount: 1)
        let file = try await engineSourceFile(sourceID: fixture.sourceIDs[0], directory: fixture.directories[0])
        let fileID = try await fixture.store.save(file, decision: .importNew)
        let database = fixture.databaseURL
        let indexCount = "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'file_state_created_order'"
        XCTAssertEqual(try engineSQLInteger(indexCount, at: database), 1)

        try injectEngineSQL("DROP TABLE dedup_recheck_progress; DROP TABLE dedup_dependency; DROP TABLE advanced_match_evidence; DROP TABLE file_fingerprint; DROP TABLE fingerprint_task; DROP TABLE photos_representation; DROP TABLE photos_index_exclusion; DROP TABLE dedup_index_state; DROP INDEX file_state_created_order; PRAGMA user_version = 2", at: database)
        let reopened = try SyncStore(url: database)
        XCTAssertEqual(try engineSQLInteger(indexCount, at: database), 1)
        let reopenedState = try await reopened.state(of: fileID)
        XCTAssertEqual(reopenedState, .pending)

        let reopenedAgain = try SyncStore(url: database)
        XCTAssertEqual(try engineSQLInteger(indexCount, at: database), 1)
        let reopenedAgainState = try await reopenedAgain.state(of: fileID)
        XCTAssertEqual(reopenedAgainState, .pending)
    }

    func testFailedKeysetIndexCreationDoesNotReplaceExistingDatabase() async throws {
        let root = try makeRoot()
        let database = root.appendingPathComponent("state.sqlite")
        let fileID: UUID
        do {
            let store = try SyncStore(url: database)
            let sourceID = try await store.registerSource(url: root)
            fileID = try await store.save(source(sourceID: sourceID, root: root), decision: .importNew)
        }

        try injectEngineSQL("DROP INDEX file_state_created_order; CREATE TABLE file_state_created_order (marker INTEGER)", at: database)
        XCTAssertThrowsError(try SyncStore(url: database))
        XCTAssertEqual(try engineSQLInteger("PRAGMA user_version", at: database), 12)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM file_record WHERE id = '\(fileID.uuidString)'", at: database), 1)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'file_state_created_order'", at: database), 1)
    }

    func testDueRetrySourceIDsIncludesOnlyActiveDefinitePendingFailuresAtDeadline() async throws {
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
        let deadline = Date(timeIntervalSince1970: 5)

        for relativePath in ["due-one.jpg", "due-two.jpg"] {
            let id = try await store.save(source(sourceID: activeID, root: active, relativePath: relativePath), decision: .importNew)
            try await store.recordRetry(fileID: id, attemptID: nil, nextRetry: deadline,
                                        error: "temporary", definitelyNotCommitted: true)
        }
        let future = try await store.save(source(sourceID: activeID, root: active, relativePath: "future.jpg"), decision: .importNew)
        try await store.recordRetry(fileID: future, attemptID: nil, nextRetry: deadline.addingTimeInterval(1),
                                    error: "temporary", definitelyNotCommitted: true)
        _ = try await store.save(source(sourceID: activeID, root: active, relativePath: "clean-pending.jpg"), decision: .importNew)
        let importing = try await store.save(source(sourceID: activeID, root: active, relativePath: "importing.jpg"), decision: .importNew)
        let importingAttempt = UUID()
        try await store.beginAttempt(fileID: importing, attemptID: importingAttempt)
        try await store.recordRetry(fileID: importing, attemptID: importingAttempt, nextRetry: deadline,
                                    error: "unknown", definitelyNotCommitted: false)

        let disabledFile = try await store.save(source(sourceID: disabledID, root: disabled, relativePath: "disabled.jpg"), decision: .importNew)
        try await store.recordRetry(fileID: disabledFile, attemptID: nil, nextRetry: deadline,
                                    error: "temporary", definitelyNotCommitted: true)
        try await store.disableSource(id: disabledID)

        let removedFile = try await store.save(source(sourceID: removedID, root: removed, relativePath: "removed.jpg"), decision: .importNew)
        try await store.recordRetry(fileID: removedFile, attemptID: nil, nextRetry: deadline,
                                    error: "temporary", definitelyNotCommitted: true)
        try await store.removeSource(id: removedID)

        let beforeDeadline = try await store.dueRetrySourceIDs(at: deadline.addingTimeInterval(-1))
        let atDeadline = try await store.dueRetrySourceIDs(at: deadline)
        let reopened = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let afterReopen = try await reopened.dueRetrySourceIDs(at: deadline)

        XCTAssertEqual(beforeDeadline, [])
        XCTAssertEqual(atDeadline, [activeID])
        XCTAssertEqual(afterReopen, [activeID])
    }

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
        let changed = try await store.recordSourceChange(fileID: id, stamp: FileStamp(size: 15, modifiedNanoseconds: 20))

        let state = try await store.state(of: id)
        let history = try await store.successIdentifier(of: id)
        XCTAssertTrue(changed)
        XCTAssertEqual(state, .skipped)
        XCTAssertEqual(history, "asset-1")
    }

    func testSourceChangeSkipsPendingRecord() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let sourceID = try await store.registerSource(url: root)
        let file = source(sourceID: sourceID, root: root)
        let fileID = try await store.save(file, decision: .importNew)
        let replacement = FileStamp(size: 99, modifiedNanoseconds: 99)

        let changed = try await store.recordSourceChange(fileID: fileID, stamp: replacement)
        let stored = try await store.file(sourceID: sourceID, relativePath: "a.jpg")

        XCTAssertTrue(changed)
        XCTAssertEqual(stored?.state, .skipped)
        XCTAssertEqual(stored?.file.stamp, replacement)
    }

    func testSourceChangePreservesUnconfirmedAttempt() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let sourceID = try await store.registerSource(url: root)
        let file = source(sourceID: sourceID, root: root)
        let fileID = try await store.save(file, decision: .importNew)
        let before = try await store.file(sourceID: sourceID, relativePath: "a.jpg")
        let stale = try XCTUnwrap(before)
        let attempt = UUID()
        try await store.beginAttempt(fileID: fileID, attemptID: attempt)
        try store.checkpointPlaceholder(fileID: fileID, attemptID: attempt, identifier: "asset")

        let changed = try await store.recordSourceChange(fileID: fileID, stamp: .init(size: 99, modifiedNanoseconds: 99))
        let during = try await store.file(sourceID: sourceID, relativePath: "a.jpg")

        XCTAssertFalse(changed)
        XCTAssertEqual(during?.state, .importing)
        XCTAssertEqual(during?.attemptID, attempt)
        XCTAssertEqual(during?.placeholderID, "asset")
        XCTAssertEqual(during?.file.stamp, stale.file.stamp)
        try await store.markImported(fileID: fileID, attemptID: attempt, identifier: "asset")
        let success = try await store.successIdentifier(of: fileID)
        XCTAssertEqual(success, "asset")
    }

    func testSourceChangeMissingRecordThrowsNotFound() async throws {
        let root = try makeRoot()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let missing = UUID()

        do {
            _ = try await store.recordSourceChange(fileID: missing, stamp: .init(size: 99, modifiedNanoseconds: 99))
            XCTFail("Expected a missing record to throw")
        } catch let error as SyncStoreError {
            guard case .notFound(let id) = error else {
                return XCTFail("Expected notFound, got \(error)")
            }
            XCTAssertEqual(id, missing)
        }
    }

    func testReopenPreservesProtectedUnconfirmedAttempt() async throws {
        let root = try makeRoot()
        let database = root.appendingPathComponent("state.sqlite")
        let sourceID: UUID
        let fileID: UUID
        let attempt: UUID
        do {
            let store = try SyncStore(url: database)
            sourceID = try await store.registerSource(url: root)
            fileID = try await store.save(source(sourceID: sourceID, root: root), decision: .importNew)
            attempt = UUID()
            try await store.beginAttempt(fileID: fileID, attemptID: attempt)
            try store.checkpointPlaceholder(fileID: fileID, attemptID: attempt, identifier: "asset")
            let changed = try await store.recordSourceChange(fileID: fileID, stamp: .init(size: 99, modifiedNanoseconds: 99))
            XCTAssertFalse(changed)
        }

        let reopened = try SyncStore(url: database)
        let stored = try await reopened.file(sourceID: sourceID, relativePath: "a.jpg")
        XCTAssertEqual(stored?.id, fileID)
        XCTAssertEqual(stored?.state, .importing)
        XCTAssertEqual(stored?.attemptID, attempt)
        XCTAssertEqual(stored?.placeholderID, "asset")
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

    func testSnapshotValidityRollbackLeavesNoSkipOrEvidence() async throws {
        let root = try makeRoot()
        let database = root.appendingPathComponent("state.sqlite")
        let store = try SyncStore(url: database)
        let sourceID = try await store.registerSource(url: root)
        let file = source(sourceID: sourceID, root: root)
        let candidate = MatchCandidate(key: "photos:1", metadata: media("a.jpg"))

        let result = try await store.saveWithSnapshotValidity(
            file,
            decision: .skip(candidateKeys: [candidate.key]),
            candidates: [candidate],
            validity: RejectingSnapshotValidity()
        )

        guard case .staleSnapshot = result else {
            return XCTFail("Expected a stale snapshot result")
        }
        let pendingCount = try await store.countFiles(state: .pending)
        let skippedCount = try await store.countFiles(state: .skipped)
        XCTAssertEqual(pendingCount, 0)
        XCTAssertEqual(skippedCount, 0)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM file_record", at: database), 0)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM match_evidence", at: database), 0)
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
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA user_version = 13", nil, nil, nil), SQLITE_OK)

        XCTAssertThrowsError(try SyncStore(url: database))
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 13)
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

private final class DecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var countStorage = 0

    func increment() {
        lock.lock()
        countStorage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return countStorage
    }
}

private final class RejectingSnapshotValidity: PhotosCandidateValidity, @unchecked Sendable {
    func commitIfCurrent(_ commit: @escaping @Sendable () throws -> Void) throws -> Bool {
        false
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
        try injectEngineSQL("DROP TABLE dedup_recheck_progress; DROP TABLE dedup_dependency; DROP TABLE advanced_match_evidence; DROP TABLE file_fingerprint; DROP TABLE fingerprint_task; DROP TABLE photos_representation; DROP TABLE photos_index_exclusion; DROP TABLE dedup_index_state; DROP TABLE non_media_skip; ALTER TABLE source DROP COLUMN removed; PRAGMA user_version = 1", at: fixture.databaseURL)
        let migrated = try SyncStore(url: fixture.databaseURL)
        XCTAssertEqual(try engineSQLInteger("PRAGMA user_version", at: fixture.databaseURL), 12)
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
        // A v2 database already has file_record; source-only fixtures conceal migration dependencies.
        try injectEngineSQL("""
            CREATE TABLE source (id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, enabled INTEGER NOT NULL, last_scan_at REAL, last_error TEXT);
            CREATE TABLE file_record (id TEXT PRIMARY KEY, created_order INTEGER NOT NULL UNIQUE, source_id TEXT NOT NULL REFERENCES source(id), relative_path TEXT NOT NULL, filename TEXT NOT NULL, size INTEGER NOT NULL, modified_ns INTEGER NOT NULL, metadata_json TEXT NOT NULL, state TEXT NOT NULL, skip_reason TEXT, rule_version INTEGER NOT NULL, attempt_id TEXT, placeholder_id TEXT, submitted_at REAL, definitely_not_committed INTEGER NOT NULL DEFAULT 0, success_id TEXT, success_metadata_json TEXT, succeeded_at REAL, retry_count INTEGER NOT NULL DEFAULT 0, next_retry_at REAL, last_error TEXT);
            INSERT INTO source (id, path, enabled) VALUES ('\(sourceID.uuidString)', '\(sourcePath)', 1);
            INSERT INTO file_record(id,created_order,source_id,relative_path,filename,size,modified_ns,metadata_json,state,rule_version,success_id,success_metadata_json)
                VALUES ('old-success',1,'\(sourceID.uuidString)','old.jpg','old.jpg',12,10,'{}','imported',1,'asset-success','{"history":"retained"}');
            PRAGMA user_version = 2;
            """, at: database)

        let migrated = try SyncStore(url: database)
        let sources = try await migrated.sources()
        XCTAssertEqual(try engineSQLInteger("PRAGMA user_version", at: database), 12)
        XCTAssertEqual(try engineSQLInteger("SELECT removed FROM source WHERE id = '\(sourceID.uuidString)'", at: database), 0)
        XCTAssertEqual(sources.map(\.id), [sourceID])
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM file_record WHERE success_id='asset-success' AND success_metadata_json='{\"history\":\"retained\"}' AND recheck_retry_count=0", at: database), 1)
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
