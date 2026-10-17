import XCTest
import SQLite3
@testable import PhotoSyncCore

final class LegacySkipReevaluationTests: XCTestCase {
    func testOnlyEligibleEnabledImageSkipsReopen() async throws {
        let f = try Fixture(); defer { f.clean() }
        let active = try await f.source("active"), disabled = try await f.source("disabled")
        let eligible = try await f.skip(active, "image.jpg")
        let video = try await f.skip(active, "video.mov", kind: .video)
        let changed = try await f.skip(active, "changed.jpg", reason: .sourceChanged)
        let unsupported = try await f.skip(active, "unsupported.jpg", reason: .unsupportedFormat)
        let inactive = try await f.skip(disabled, "inactive.jpg")
        try await f.store.disableSource(id: disabled)
        let success = try await f.skip(active, "success.jpg")
        let unknown = try await f.skip(active, "unknown.jpg")
        let importing = try await f.skip(active, "importing.jpg")
        try injectEngineSQL("UPDATE file_record SET success_id='existing-success', success_metadata_json=metadata_json WHERE id='\(success)'; UPDATE file_record SET submitted_at=42 WHERE id='\(unknown)'; UPDATE file_record SET state='importing',submitted_at=42 WHERE id='\(importing)'", at: f.db)
        let reopened = try await f.worker().processBatch(limit: 20)
        XCTAssertEqual(reopened, 1)
        let pending = try await f.store.state(of: eligible)
        XCTAssertEqual(pending, .pending)
        for id in [video, changed, unsupported, inactive, success, unknown] {
            let state = try await f.store.state(of: id); XCTAssertEqual(state, .skipped)
        }
        let inflight = try await f.store.state(of: importing); XCTAssertEqual(inflight, .importing)
        let savedSuccess = try await f.store.successIdentifier(of: success); XCTAssertEqual(savedSuccess, "existing-success")
    }

    func testCrashAfterReopenResumesIdempotently() async throws {
        let f = try Fixture(); defer { f.clean() }
        let source = try await f.source("active")
        let a = try await f.skip(source, "a.jpg"), b = try await f.skip(source, "b.jpg")
        let first = try await f.worker().processBatch(limit: 1); XCTAssertEqual(first, 1)
        let restartedStore = try SyncStore(url: f.db)
        let restarted = LegacySkipReevaluation(store: restartedStore, stamp: { $0.stamp }, policyVersion: "target", retryDelaysSeconds: [5, 15])
        let second = try await restarted.processBatch(limit: 10); XCTAssertEqual(second, 1)
        let third = try await restarted.processBatch(limit: 10); XCTAssertEqual(third, 0)
        for id in [a, b] { let state = try await restartedStore.state(of: id); XCTAssertEqual(state, .pending) }
    }

    func testSamePolicyDoesNotReopenAgain() async throws {
        let f = try Fixture(); defer { f.clean() }
        let source = try await f.source("active")
        let same = try await f.skip(source, "same.jpg", policy: "target")
        let old = try await f.skip(source, "old.jpg", policy: "old")
        let count = try await f.worker().processBatch(limit: 10); XCTAssertEqual(count, 1)
        let sameState = try await f.store.state(of: same), oldState = try await f.store.state(of: old)
        XCTAssertEqual(sameState, .skipped); XCTAssertEqual(oldState, .pending)
        let again = try await f.worker().processBatch(limit: 10); XCTAssertEqual(again, 0)
    }
    func testResetAtInitialCursorDuringStampCannotLoseEarlierReenabledSource() async throws {
        let f = try Fixture(); defer { f.clean() }
        let disabled = try await f.source("disabled"), active = try await f.source("active")
        let early = try await f.skip(disabled, "early.jpg"), late = try await f.skip(active, "late.jpg")
        try await f.store.disableSource(id: disabled)
        let gate = RecheckGate()
        let worker = f.worker(stamp: { file in await gate.hold(); return file.stamp })
        let batch = Task { try await worker.processBatch(limit: 1) }
        await fulfillment(of: [gate.entered], timeout: 3)
        let restored = try await f.source("disabled"); XCTAssertEqual(restored, disabled)
        await gate.release()
        _ = try await batch.value
        // The stale batch may not advance beyond the reset while it is awaiting stamp.
        let cursor = try engineSQLInteger("SELECT cursor FROM dedup_recheck_progress WHERE target_policy_version='target'", at: f.db)
        XCTAssertEqual(cursor, 0)
        _ = try await worker.processBatch(limit: 10)
        for id in [early, late] { let state = try await f.store.state(of: id); XCTAssertEqual(state, .pending) }
    }

    func testReenabledAndReaddedSourceBeforeCompletedCursorIsReevaluated() async throws {
        for remove in [false, true] {
            let f = try Fixture(); defer { f.clean() }
            let inactive = try await f.source("inactive"), active = try await f.source("active")
            let early = try await f.skip(inactive, "old.jpg")
            let same = try await f.skip(inactive, "same.jpg", policy: "target")
            _ = try await f.skip(active, "later.jpg")
            if remove { try await f.store.removeSource(id: inactive) }
            else { try await f.store.disableSource(id: inactive) }
            _ = try await f.worker().processBatch(limit: 10)
            let restored = try await f.source("inactive"); XCTAssertEqual(restored, inactive)
            // A crash immediately after requeue preserves the reset.
            let restarted = try SyncStore(url: f.db)
            let worker = LegacySkipReevaluation(store: restarted, stamp: { $0.stamp }, policyVersion: "target", retryDelaysSeconds: [5])
            let count = try await worker.processBatch(limit: 10); XCTAssertEqual(count, 1)
            let state = try await restarted.state(of: early), sameState = try await restarted.state(of: same)
            XCTAssertEqual(state, .pending); XCTAssertEqual(sameState, .skipped)
        }
    }

    func testFailedAndMismatchedStampsRemainRetryableAcrossRestartAndReenable() async throws {
        for missing in [false, true] {
            let f = try Fixture(); defer { f.clean() }
            let source = try await f.source("active")
            let early = try await f.skip(source, "early.jpg"), healthy = try await f.skip(source, "healthy.jpg")
            let first = f.worker(stamp: { file in
                if file.relativePath == "early.jpg" {
                    if missing { throw FixtureError.unavailable("offline") }
                    return FileStamp(size: 99, modifiedNanoseconds: 99)
                }
                return file.stamp
            }, now: { Date(timeIntervalSince1970: 100) })
            let count = try await first.processBatch(limit: 10); XCTAssertEqual(count, 1)
            let initial = try await f.store.state(of: early), good = try await f.store.state(of: healthy)
            XCTAssertEqual(initial, .skipped); XCTAssertEqual(good, .pending)
            let tooEarly = f.worker(now: { Date(timeIntervalSince1970: 104) })
            let premature = try await tooEarly.processBatch(limit: 10); XCTAssertEqual(premature, 0)
            try await f.store.disableSource(id: source); _ = try await f.source("active")
            let restarted = try SyncStore(url: f.db)
            let restored = LegacySkipReevaluation(store: restarted, stamp: { $0.stamp }, policyVersion: "target", retryDelaysSeconds: [5], now: { Date(timeIntervalSince1970: 105) })
            let recovered = try await restored.processBatch(limit: 10); XCTAssertEqual(recovered, 1)
            let state = try await restarted.state(of: early); XCTAssertEqual(state, .pending)
        }
    }

    func testLimitOneFairnessBetweenDueRetriesAndFreshFilesPersistsAcrossRestart() async throws {
        let f = try Fixture(); defer { f.clean() }
        let source = try await f.source("active")
        let retry = try await f.skip(source, "retry.jpg")
        _ = try await f.skip(source, "another-retry.jpg")
        let failed = f.worker(stamp: { _ in throw FixtureError.unavailable("offline") }, now: { Date(timeIntervalSince1970: 100) })
        _ = try await failed.processBatch(limit: 2)
        let fresh = try await f.skip(source, "fresh.jpg")
        _ = try await f.skip(source, "more.jpg")
        // Recreate the actor every call: queue alternation must not be only in memory.
        for _ in 0..<2 {
            _ = try await f.worker(now: { Date(timeIntervalSince1970: 105) }).processBatch(limit: 1)
        }
        for id in [retry, fresh] { let state = try await f.store.state(of: id); XCTAssertEqual(state, .pending) }
    }

    func testSourceMutationOrSuccessWinsOverReopen() async throws {
        for success in [false, true] {
            let f = try Fixture(); defer { f.clean() }
            let source = try await f.source("active"), gate = RecheckGate()
            let id = try await f.skip(source, "item.jpg")
            let worker = f.worker(stamp: { file in await gate.hold(); return file.stamp })
            let batch = Task { try await worker.processBatch(limit: 1) }
            await fulfillment(of: [gate.entered], timeout: 3)
            if success {
                try injectEngineSQL("UPDATE file_record SET state='imported',success_id='late-success',success_metadata_json=metadata_json WHERE id='\(id)'", at: f.db)
            } else {
                _ = try await f.store.recordSourceChange(fileID: id, stamp: .init(size: 20, modifiedNanoseconds: 20))
            }
            await gate.release()
            let count = try await batch.value; XCTAssertEqual(count, 0)
            let state = try await f.store.state(of: id); XCTAssertEqual(state, success ? .imported : .skipped)
            let identifier = try await f.store.successIdentifier(of: id); XCTAssertEqual(identifier, success ? "late-success" : nil)
        }
    }

    func testPauseDuringStampAndCancellationDoNotAdvanceCursor() async throws {
        for cancel in [false, true] {
            let f = try Fixture(); defer { f.clean() }
            let source = try await f.source("active"), gate = RecheckGate()
            let id = try await f.skip(source, "item.jpg")
            let worker = f.worker(stamp: { file in await gate.hold(); return file.stamp })
            let batch = Task { try await worker.processBatch(limit: 1) }
            await fulfillment(of: [gate.entered], timeout: 3)
            if cancel { batch.cancel() } else { await worker.setPaused(true) }
            await gate.release()
            do { _ = try await batch.value } catch is CancellationError {} catch { throw error }
            let before = try await f.store.state(of: id); XCTAssertEqual(before, .skipped)
            await worker.setPaused(false)
            let count = try await worker.processBatch(limit: 1); XCTAssertEqual(count, 1)
        }
    }

    func testEnginePauseStopsAwaitingRecheckAndResumeOnlyReopensPending() async throws {
        let f = try Fixture(); defer { f.clean() }
        let source = try await f.source("active"), gate = RecheckGate(), photos = FakePhotosGateway()
        let id = try await f.skip(source, "item.jpg")
        let worker = f.worker(stamp: { file in await gate.hold(); return file.stamp })
        let engine = SyncEngine(store: f.store, photos: photos, legacySkipReevaluation: worker)
        let batch = Task { try await engine.processLegacySkips(limit: 1) }
        await fulfillment(of: [gate.entered], timeout: 3)
        await engine.setPaused(true); await gate.release()
        let pausedCount = try await batch.value; XCTAssertEqual(pausedCount, 0)
        let stillPaused = try await engine.processLegacySkips(limit: 1); XCTAssertEqual(stillPaused, 0)
        await engine.setPaused(false)
        let resumed = try await engine.processLegacySkips(limit: 1); XCTAssertEqual(resumed, 1)
        let state = try await f.store.state(of: id), creates = await photos.createCount
        XCTAssertEqual(state, .pending); XCTAssertEqual(creates, 0)
    }

    func testStartupDiscoversUnqueuedOldSkipBehindCursor() async throws {
        let f = try Fixture(); defer { f.clean() }
        let source = try await f.source("active")
        let earlier = try await f.skip(source, "earlier.jpg", policy: "target")
        _ = try await f.skip(source, "later.jpg")
        _ = try await f.worker().processBatch(limit: 10)
        // Simulate legacy persisted evidence missed by an interrupted pre-P7 producer.
        try injectEngineSQL("DELETE FROM advanced_match_evidence WHERE file_id='\(earlier)'", at: f.db)
        let recovered = try await f.worker().processBatch(limit: 10); XCTAssertEqual(recovered, 1)
        let state = try await f.store.state(of: earlier); XCTAssertEqual(state, .pending)
    }

    func testStandaloneReopenPreservesSubmissionAndImportRetryFields() async throws {
        let f = try Fixture(); defer { f.clean() }
        let source = try await f.source("active")
        let id = try await f.skip(source, "retry.jpg"), attempt = UUID()
        try injectEngineSQL("UPDATE file_record SET attempt_id='\(attempt)',placeholder_id='placeholder',submitted_at=42,definitely_not_committed=1,retry_count=3,next_retry_at=99,last_error='confirmed failure' WHERE id='\(id)'", at: f.db)
        let page = try await f.store.legacySkipPage(afterOrder: 0, limit: 1, policyVersion: "target")
        XCTAssertEqual(page.count, 1); XCTAssertEqual(page.first?.submittedAt, Date(timeIntervalSince1970: 42))
        XCTAssertEqual(page.first?.definitelyNotCommitted, true); XCTAssertNil(page.first?.decisionPolicyVersion)
        let refused = try await f.store.reopenLegacySkip(fileID: id, expectedStamp: .init(size: 0, modifiedNanoseconds: 0), policyVersion: "target")
        XCTAssertFalse(refused)
        let reopened = try await f.store.reopenLegacySkip(fileID: id, expectedStamp: .init(size: 12, modifiedNanoseconds: 10), policyVersion: "target")
        XCTAssertTrue(reopened)
        let row = try await f.store.file(sourceID: source, relativePath: "retry.jpg")
        XCTAssertEqual(row?.attemptID, attempt); XCTAssertEqual(row?.placeholderID, "placeholder")
        XCTAssertEqual(row?.retryCount, 3); XCTAssertEqual(row?.nextRetryAt, Date(timeIntervalSince1970: 99))
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM file_record WHERE id='\(id)' AND submitted_at=42 AND definitely_not_committed=1 AND last_error='confirmed failure'", at: f.db), 1)
    }

    func testExistingV4MigrationPreservesRowsAndRecheckProgress() async throws {
        let f = try Fixture(); defer { f.clean() }
        let source = try await f.source("active"), id = try await f.skip(source, "old.jpg")
        // Reconstruct the supported older v4 shape, not a damaged current v5 store.
        try injectEngineSQL("""
            PRAGMA user_version = 4;
            DROP TABLE photos_index_exclusion;
            DROP INDEX file_recheck_retry;
            ALTER TABLE file_record DROP COLUMN recheck_policy_version;
            ALTER TABLE file_record DROP COLUMN recheck_retry_count;
            ALTER TABLE file_record DROP COLUMN recheck_next_retry_at;
            ALTER TABLE dedup_recheck_progress DROP COLUMN revision;
            INSERT INTO dedup_recheck_progress VALUES ('target',1,1);
            """, at: f.db)
        let migrated = try SyncStore(url: f.db)
        XCTAssertEqual(try engineSQLInteger("PRAGMA user_version", at: f.db), 10)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_index_exclusion", at: f.db), 0)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM pragma_table_info('file_record') WHERE name IN ('recheck_policy_version','recheck_retry_count','recheck_next_retry_at')", at: f.db), 3)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='file_recheck_retry'", at: f.db), 1)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM dedup_recheck_progress WHERE target_policy_version='target' AND cursor=1 AND complete=1 AND revision=0", at: f.db), 1)
        let preserved = try await migrated.state(of: id); XCTAssertEqual(preserved, .skipped)
        let worker = LegacySkipReevaluation(store: migrated, stamp: { $0.stamp }, policyVersion: "target", retryDelaysSeconds: [5])
        let count = try await worker.processBatch(limit: 1); XCTAssertEqual(count, 1)
        let state = try await migrated.state(of: id); XCTAssertEqual(state, .pending)
        XCTAssertEqual(try engineSQLInteger("PRAGMA user_version", at: f.db), 10)
    }

    func testRevisionOverflowRollsBackItemAndSourceRequeue() async throws {
        let f = try Fixture(); defer { f.clean() }
        let source = try await f.source("active"), id = try await f.skip(source, "old.jpg")
        try injectEngineSQL("INSERT INTO dedup_recheck_progress VALUES ('target',0,0,9223372036854775807)", at: f.db)
        do { _ = try await f.worker().processBatch(limit: 1); XCTFail("Overflow must fail closed") }
        catch SyncStoreError.constraint {} catch { throw error }
        let state = try await f.store.state(of: id); XCTAssertEqual(state, .skipped)
        try await f.store.disableSource(id: source)
        do { _ = try await f.source("active"); XCTFail("Reset overflow must roll back source enabling") }
        catch SyncStoreError.constraint {} catch { throw error }
        let registered = try await f.store.source(id: source); XCTAssertFalse(registered.enabled)
    }

    func testExhaustedFreshQueueCheckpointsIneligibleTailAndLaterSourceStillRuns() async throws {
        let f = try Fixture(); defer { f.clean() }
        let source = try await f.source("active")
        _ = try await f.skip(source, "seed.jpg")
        try injectEngineSQL("""
            WITH RECURSIVE n(i) AS (VALUES(2) UNION ALL SELECT i+1 FROM n WHERE i<1000)
            INSERT INTO file_record(id,created_order,source_id,relative_path,filename,size,modified_ns,metadata_json,state,skip_reason,rule_version)
            SELECT printf('00000000-0000-0000-0000-%012d',i),i,'\(source)',printf('video-%d.mov',i),'video.mov',12,10,
                (SELECT json_set(metadata_json,'$.kind','video') FROM file_record LIMIT 1),'skipped','suspectedDuplicate',1 FROM n;
            """, at: f.db)
        let worker = f.worker(stamp: { file in
            if file.relativePath == "seed.jpg" { throw FixtureError.unavailable("offline") }
            return file.stamp
        }, now: { Date(timeIntervalSince1970: 100) })
        let initial = try await worker.processBatch(limit: 10); XCTAssertEqual(initial, 0)
        XCTAssertEqual(try engineSQLInteger("SELECT cursor FROM dedup_recheck_progress WHERE target_policy_version='target'", at: f.db), 1000)
        let due = try await f.worker(now: { Date(timeIntervalSince1970: 105) }).processBatch(limit: 10)
        XCTAssertEqual(due, 1, "The exhausted frontier must not discard a retry behind it")
        _ = try await f.skip(source, "late.jpg")
        let highOrder = try await worker.processBatch(limit: 10); XCTAssertEqual(highOrder, 1)
        let added = try await f.source("later")
        let id = try await f.skip(added, "new.jpg")
        let after = try await worker.processBatch(limit: 10); XCTAssertEqual(after, 1)
        let state = try await f.store.state(of: id); XCTAssertEqual(state, .pending)
    }

    func testQueueQueriesDecodeBoundedRowsAndUseMatchingIndexes() async throws {
        let counter = RecheckDecodeCounter(), f = try Fixture(decodeObserver: { counter.increment() })
        defer { f.clean() }
        let source = try await f.source("active")
        _ = try await f.skip(source, "seed.jpg")
        try injectEngineSQL("""
            WITH RECURSIVE n(i) AS (VALUES(2) UNION ALL SELECT i+1 FROM n WHERE i<1000)
            INSERT INTO file_record(id,created_order,source_id,relative_path,filename,size,modified_ns,metadata_json,state,skip_reason,rule_version)
            SELECT printf('00000000-0000-0000-0000-%012d',i),i,'\(source)',printf('item-%d.jpg',i),'item.jpg',12,10,
                (SELECT metadata_json FROM file_record LIMIT 1),'skipped','suspectedDuplicate',1 FROM n;
            """, at: f.db)
        let first = try await f.worker(stamp: { _ in throw FixtureError.unavailable("offline") }, now: { Date(timeIntervalSince1970: 100) }).processBatch(limit: 1)
        XCTAssertEqual(first, 0); XCTAssertLessThanOrEqual(counter.count, 2)
        let second = try await f.worker(now: { Date(timeIntervalSince1970: 105) }).processBatch(limit: 1)
        XCTAssertEqual(second, 1); XCTAssertLessThanOrEqual(counter.count, 4)
        let freshPlan = try queryPlan("SELECT id FROM file_record WHERE state='skipped' AND created_order>5 ORDER BY created_order LIMIT 1", at: f.db)
        let retryPlan = try queryPlan("SELECT id FROM file_record INDEXED BY file_recheck_retry WHERE recheck_policy_version='target' AND recheck_retry_count>0 AND recheck_next_retry_at<=105 ORDER BY recheck_next_retry_at,created_order LIMIT 1", at: f.db)
        XCTAssertTrue(freshPlan.contains("file_state_created_order")); XCTAssertTrue(retryPlan.contains("file_recheck_retry"))
        XCTAssertFalse(retryPlan.contains("TEMP B-TREE"))
    }

}

private struct Fixture {
    let root: URL
    let db: URL
    let store: SyncStore
    init(decodeObserver: @escaping @Sendable () -> Void = {}) throws {
        root = try temporaryDirectory(); db = root.appendingPathComponent("state.sqlite")
        store = try SyncStore(url: db, decodeObserver: decodeObserver)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func source(_ name: String) async throws -> UUID {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try await store.registerSource(url: url)
    }
    func skip(_ source: UUID, _ name: String, kind: MediaKind = .image,
              reason: SkipReason = .suspectedDuplicate, policy: String? = nil) async throws -> UUID {
        let url = try await store.source(id: source).url.appendingPathComponent(name)
        let metadata = MediaMetadata(filename: name, kind: kind, captureSecond: nil, rawCaptureTime: nil, make: nil, model: nil, width: 1, height: 1, duration: nil)
        let file = SourceFile(sourceID: source, relativePath: name, url: url, stamp: .init(size: 12, modifiedNanoseconds: 10), metadata: metadata)
        let id = try await store.save(file, decision: .importNew)
        try await store.markSkipped(fileID: id, reason: reason, candidates: [])
        if let policy {
            try injectEngineSQL("INSERT INTO advanced_match_evidence VALUES ('\(UUID())','\(id)',12,10,'{}','\(policy)','skip','{}',1)", at: db)
        }
        return id
    }
    func worker(stamp: @escaping @Sendable (SourceFile) async throws -> FileStamp = { $0.stamp },
                now: @escaping @Sendable () -> Date = { Date() }, policy: String = "target") -> LegacySkipReevaluation {
        LegacySkipReevaluation(store: store, stamp: stamp, policyVersion: policy, retryDelaysSeconds: [5, 15], now: now)
    }
}

private actor RecheckGate {
    nonisolated let entered = XCTestExpectation(description: "stamp entered")
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func hold() async {
        guard !released else { return }
        entered.fulfill()
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private final class RecheckDecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
private func queryPlan(_ query: String, at url: URL) throws -> String {
    var db: OpaquePointer?, statement: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw FixtureError.unavailable("sqlite open") }
    defer { sqlite3_finalize(statement); sqlite3_close(db) }
    guard sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN " + query, -1, &statement, nil) == SQLITE_OK else { throw FixtureError.unavailable("explain query") }
    var lines: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW { lines.append(String(cString: sqlite3_column_text(statement, 3))) }
    return lines.joined(separator: "\n")
}
