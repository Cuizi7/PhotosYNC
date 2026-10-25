import Foundation
import CryptoKit
import SQLite3
import SQLiteVectorQuery

/// Query-local scores and metadata only. The cancellation bit is the sole field
/// shared with the calling task; collection happens synchronously on the store queue.
private final class SQLiteVectorCollector: @unchecked Sendable {
    let version: String, threshold: Double, diagnosticLimit: Int
    private var matches = [ScoredCandidate](), diagnostics = [ScoredCandidate]()
    private let cancellationLock = NSLock()
    private var cancelled = false
    private(set) var error: Error?
    init(version: String, threshold: Double, diagnosticLimit: Int) {
        self.version = version; self.threshold = threshold; self.diagnosticLimit = diagnosticLimit
    }
    func cancel() { cancellationLock.lock(); cancelled = true; cancellationLock.unlock() }
    var isCancelled: Bool {
        cancellationLock.lock(); defer { cancellationLock.unlock() }; return cancelled
    }
    var diagnosticFloor: Float {
        diagnosticLimit == 0 ? .infinity : diagnostics.count < diagnosticLimit ? -.infinity : Float(diagnostics.last!.score)
    }
    var result: VectorSearchResult { .init(matches: matches.sorted(by: Self.ranked), diagnostics: diagnostics) }
    func collect(row: OpaquePointer, score: Float) -> Float {
        guard let keyBytes = sqlite3_column_text(row, 0), let originBytes = sqlite3_column_text(row, 1),
              let key = String(bytes: UnsafeBufferPointer(start: keyBytes, count: Int(sqlite3_column_bytes(row, 0))), encoding: .utf8),
              let originText = String(bytes: UnsafeBufferPointer(start: originBytes, count: Int(sqlite3_column_bytes(row, 1))), encoding: .utf8),
              let origin = CandidateOrigin(rawValue: originText) else {
            error = AdvancedDedupError.invalidConfiguration; return .nan
        }
        do {
            let size = sqlite3_column_type(row, 2) == SQLITE_NULL ? nil :
                try PixelSize(width: Int(sqlite3_column_int64(row, 2)), height: Int(sqlite3_column_int64(row, 3)))
            let candidate = ScoredCandidate(key: key, origin: origin, score: Double(score), size: size, fingerprintVersion: version)
            if Double(score) >= threshold { matches.append(candidate) }
            if diagnosticLimit > 0 {
                diagnostics.append(candidate); diagnostics.sort(by: Self.ranked)
                if diagnostics.count > diagnosticLimit { diagnostics.removeLast() }
            }
            return diagnosticFloor
        } catch { self.error = error; return .nan }
    }
    private static func ranked(_ lhs: ScoredCandidate, _ rhs: ScoredCandidate) -> Bool {
        lhs.score == rhs.score ? lhs.key < rhs.key : lhs.score > rhs.score
    }
}

public struct StoredFile: Sendable {
    public let id: UUID
    public let createdOrder: Int64
    public let file: SourceFile
    public let state: FileState
    public let attemptID: UUID?
    public let placeholderID: String?
    public let successID: String?
    public let retryCount: Int
    public let nextRetryAt: Date?
}

enum SnapshotCommitResult: Sendable {
    case committed(UUID)
    case staleSnapshot
}

/// Current terminal and queue states for enabled, configured sources.
/// A record has exactly one state, so a source-changed successful import is counted as skipped once.
/// `pending` and `retryPending` partition the `pending` state without adding a fifth state:
/// `pending` has never recorded an error, `retryPending` holds a definite not-committed failure
/// in `last_error` and waits for its next attempt. Their sum is every pending record.
public struct SyncStatusSummary: Equatable, Sendable {
    public var imported: Int
    public var skipped: Int
    public var pending: Int
    public var importing: Int
    public var retryPending: Int
    /// Successful imports kept in the database whose source is disabled or removed. They are not
    /// part of the counters above; the menu mentions them so retiring a source is not mistaken
    /// for losing its history.
    public var retainedImported: Int

    public init(imported: Int = 0, skipped: Int = 0, pending: Int = 0, importing: Int = 0,
                retryPending: Int = 0, retainedImported: Int = 0) {
        self.imported = imported
        self.skipped = skipped
        self.pending = pending
        self.importing = importing
        self.retryPending = retryPending
        self.retainedImported = retainedImported
    }
}

public struct RegisteredSource: Sendable {
    public let id: UUID
    public let url: URL
    public let enabled: Bool
}

public enum SyncStoreError: Error, LocalizedError {
    case sqlite(String)
    case busy(String)
    case constraint(String)
    case notFound(UUID)
    case invalidTransition(String)
    case unsupportedSchema(Int32)

    public var errorDescription: String? {
        switch self {
        case .sqlite(let message), .busy(let message), .constraint(let message), .invalidTransition(let message): return message
        case .notFound(let id): return "No file record exists for \(id.uuidString)."
        case .unsupportedSchema(let version): return "Database schema version \(version) is newer than this app supports."
        }
    }
}

public final class SyncStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PhotoSync.SyncStore.sqlite")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let database: OpaquePointer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let ruleVersion = 1
    private let readExecutor: ReadExecutor
    private let validateSource: @Sendable (URL) throws -> URL
    private let decodeObserver: @Sendable () -> Void
    /// A durable marker does not prove this process completed its publication barrier.
    /// Accessed only on the database queue; local revisions do not invalidate Photos publication.
    private var publishedIndexToken: IndexToken?
    /// Effective optional mapping allowance. Zero/truncation never changes query correctness.
    public private(set) var vectorQueryMmapBytes: Int64 = 0

    public init(url: URL, readExecutor: ReadExecutor = .shared,
                validateSource: @escaping @Sendable (URL) throws -> URL = { try SourceRegistry.normalizedURL($0) },
                decodeObserver: @escaping @Sendable () -> Void = {}) throws {
        queue.setSpecific(key: queueKey, value: true)
        self.readExecutor = readExecutor
        self.validateSource = validateSource
        self.decodeObserver = decodeObserver
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database."
            if let handle { sqlite3_close(handle) }
            throw SyncStoreError.sqlite(message)
        }
        database = handle
        do {
            // A short external reader/writer must not poison an otherwise healthy store.
            // Longer contention remains a typed, bounded result; never wait indefinitely.
            guard sqlite3_busy_timeout(handle, 1000) == SQLITE_OK else { throw databaseError() }
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA mmap_size = 2147483648")
            vectorQueryMmapBytes = try int64(one("PRAGMA mmap_size", [])![0])
            try execute("PRAGMA cache_size = -16384")
            try migrate()
            try ensureIndexes()
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public func legacySkipPage(afterOrder: Int64, limit: Int, policyVersion: String) async throws -> [LegacySkipCandidate] {
        guard limit > 0 else { return [] }
        return try await perform {
            try self.rows(Self.legacySelect + " WHERE " + Self.legacyEligibility +
                " AND file_record.created_order > ? ORDER BY file_record.created_order LIMIT ?",
                [.text(policyVersion), .int64(afterOrder), .int64(Int64(limit))]).map { try self.decodeLegacyCandidate($0) }
        }
    }

    /// Reopening preserves submission recovery and successful-history fields. It never imports.
    public func reopenLegacySkip(fileID: UUID, expectedStamp: FileStamp, policyVersion: String) async throws -> Bool {
        try await perform { try self.transaction {
            try self.reopenLegacySkipSync(fileID: fileID, expectedStamp: expectedStamp, policyVersion: policyVersion)
        } }
    }

    /// Run once per actor lifetime. Rediscover only unqueued eligible rows behind the saved cursor;
    /// retries already have their own durable queue, so they must not reset the fresh cursor.
    func beginLegacyRecheck(policyVersion: String) async throws {
        try await perform { try self.transaction {
            try self.execute("INSERT OR IGNORE INTO dedup_recheck_progress(target_policy_version,cursor,complete,revision) VALUES (?,0,0,0)", [.text(policyVersion)])
            let progress = try self.legacyProgress(policyVersion)
            if try self.one(Self.legacySelect + " WHERE " + Self.legacyEligibility + """
                 AND file_record.created_order <= ?
                 AND NOT (COALESCE(recheck_policy_version = ?, 0) AND recheck_retry_count > 0) LIMIT 1
                """, [.text(policyVersion), .int64(progress.cursor), .text(policyVersion)]) != nil {
                try self.updateLegacyProgress(policyVersion, cursor: 0, complete: false, revision: progress.revision)
            }
        } }
    }

    /// Each queue has its own indexed order. A persisted CAS version alternates their turns,
    /// including limit=1 and process restarts. No unbounded candidate decoding is required.
    func nextLegacyRecheck(policyVersion: String, now: Date) async throws -> LegacyRecheckWork? {
        try await perform { try self.transaction {
            var progress = try self.legacyProgress(policyVersion)
            let fresh = try self.one(Self.legacySelect + " WHERE " + Self.legacyEligibility + """
                 AND file_record.created_order > ?
                 AND NOT (COALESCE(recheck_policy_version = ?, 0) AND recheck_retry_count > 0)
                 ORDER BY file_record.created_order LIMIT 1
                """, [.text(policyVersion), .int64(progress.cursor), .text(policyVersion)])
            if fresh == nil {
                // The complete eligible query (not a filtered finite page) is exhausted.
                // Checkpoint this transaction's full keyset frontier so ineligible tail rows
                // are not scanned again on every due retry. Reactivation resets this cursor.
                let highWater = try self.int64(self.one("SELECT COALESCE(MAX(created_order),0) FROM file_record", [])![0])
                if highWater > progress.cursor {
                    try self.updateLegacyProgress(policyVersion, cursor: highWater,
                        complete: progress.complete, revision: progress.revision)
                    progress = try self.legacyProgress(policyVersion)
                }
            }
            let retry = try self.one(Self.legacyRetrySelect + " WHERE " + Self.legacyEligibility + """
                 AND recheck_policy_version = ? AND recheck_retry_count > 0 AND recheck_next_retry_at <= ?
                 ORDER BY recheck_next_retry_at, file_record.created_order LIMIT 1
                """, [.text(policyVersion), .text(policyVersion), .double(now.timeIntervalSince1970)])
            let useRetry = retry != nil && (fresh == nil || progress.revision % 2 != 0)
            if let row = useRetry ? retry : fresh {
                return LegacyRecheckWork(candidate: try self.decodeLegacyCandidate(row), revision: progress.revision,
                    isRetry: useRetry, retryCount: useRetry ? Int(try self.int64(row[18])) : 0)
            }
            let waiting = try self.one(Self.legacyRetrySelect + " WHERE " + Self.legacyEligibility +
                " AND recheck_policy_version = ? AND recheck_retry_count > 0 LIMIT 1", [.text(policyVersion), .text(policyVersion)]) != nil
            if progress.complete != !waiting {
                try self.updateLegacyProgress(policyVersion, cursor: progress.cursor, complete: !waiting, revision: progress.revision)
            }
            return nil
        } }
    }

    /// One transaction owns the outcome AND cursor. A source requeue while stamp is awaited
    /// invalidates the version even for reset 0 -> 0; stale outcomes never mutate file rows.
    func finishLegacyRecheck(_ work: LegacyRecheckWork, stamp: FileStamp?, policyVersion: String,
                             nextRetryAt: Date) async throws -> Bool? {
        try await perform { try self.transaction {
            let progress = try self.legacyProgress(policyVersion)
            guard progress.revision == work.revision else { return nil }
            var reopened = false
            if stamp == work.candidate.file.file.stamp {
                reopened = try self.reopenLegacySkipSync(fileID: work.candidate.file.id,
                    expectedStamp: work.candidate.file.file.stamp, policyVersion: policyVersion)
            } else {
                // Missing, unknown and mismatched physical stamps are retryable. Normal scanning
                // alone owns source-change recording; a temporarily restored stamp must not be lost.
                guard work.retryCount < Int.max else { throw SyncStoreError.constraint("Legacy retry count overflow.") }
                try self.execute("""
                    UPDATE file_record SET recheck_policy_version=?, recheck_retry_count=?, recheck_next_retry_at=?
                    WHERE id IN (SELECT file_record.id FROM file_record JOIN source ON source.id=file_record.source_id
                    WHERE \(Self.legacyEligibility) AND file_record.id=? AND size=? AND modified_ns=?)
                    """, [.text(policyVersion), .int64(Int64(work.retryCount + 1)), .double(nextRetryAt.timeIntervalSince1970),
                          .text(policyVersion), .text(work.candidate.file.id.uuidString),
                          .int64(work.candidate.file.file.stamp.size), .int64(work.candidate.file.file.stamp.modifiedNanoseconds)])
            }
            try self.updateLegacyProgress(policyVersion,
                cursor: work.isRetry ? progress.cursor : max(progress.cursor, work.candidate.file.createdOrder),
                complete: false, revision: progress.revision)
            return reopened
        } }
    }

    private static let legacyDecisionPolicy = "(SELECT policy_version FROM advanced_match_evidence WHERE file_id=file_record.id ORDER BY created_at DESC LIMIT 1)"
    private static let legacyEligibility = """
        file_record.state='skipped' AND skip_reason='suspectedDuplicate'
        AND source.enabled=1 AND source.removed=0 AND success_id IS NULL
        AND (submitted_at IS NULL OR definitely_not_committed=1)
        AND json_extract(metadata_json,'$.kind')='image'
        AND COALESCE(\(legacyDecisionPolicy),'') <> ?
        """
    private static let legacyColumns = fileColumns + ", skip_reason, submitted_at, definitely_not_committed, " + legacyDecisionPolicy + ", recheck_retry_count"
    private static let legacySelect = "SELECT " + legacyColumns + " FROM file_record JOIN source ON source.id=file_record.source_id"
    private static let legacyRetrySelect = "SELECT " + legacyColumns + " FROM file_record INDEXED BY file_recheck_retry JOIN source ON source.id=file_record.source_id"

    private func decodeLegacyCandidate(_ row: [Value]) throws -> LegacySkipCandidate {
        LegacySkipCandidate(file: try decodeStoredFile(row), skipReason: .suspectedDuplicate,
            submittedAt: optionalDouble(row[15]).map(Date.init(timeIntervalSince1970:)),
            definitelyNotCommitted: try int64(row[16]) != 0, decisionPolicyVersion: optionalText(row[17]))
    }
    private func legacyProgress(_ policy: String) throws -> (cursor: Int64, complete: Bool, revision: Int64) {
        guard let row = try one("SELECT COALESCE(cursor,0),complete,revision FROM dedup_recheck_progress WHERE target_policy_version=?", [.text(policy)]) else {
            throw SyncStoreError.constraint("Legacy recheck progress is not initialized.")
        }
        return (try int64(row[0]), try int64(row[1]) != 0, try int64(row[2]))
    }
    private func updateLegacyProgress(_ policy: String, cursor: Int64, complete: Bool, revision: Int64) throws {
        guard revision >= 0, revision < Int64.max else { throw SyncStoreError.constraint("Legacy recheck revision overflow.") }
        try requireChange("UPDATE dedup_recheck_progress SET cursor=?,complete=?,revision=? WHERE target_policy_version=? AND revision=?",
            [.int64(cursor), .int64(complete ? 1 : 0), .int64(revision + 1), .text(policy), .int64(revision)])
    }
    private func resetLegacyRechecks() throws {
        for row in try rows("SELECT target_policy_version,revision FROM dedup_recheck_progress", []) {
            try updateLegacyProgress(text(row[0]), cursor: 0, complete: false, revision: int64(row[1]))
        }
    }
    private func reopenLegacySkipSync(fileID: UUID, expectedStamp: FileStamp, policyVersion: String) throws -> Bool {
        try execute("""
            UPDATE file_record SET state='pending',skip_reason=NULL,
                recheck_policy_version=?,recheck_retry_count=0,recheck_next_retry_at=NULL
            WHERE id IN (SELECT file_record.id FROM file_record JOIN source ON source.id=file_record.source_id
                WHERE \(Self.legacyEligibility) AND file_record.id=? AND size=? AND modified_ns=?)
            """, [.text(policyVersion), .text(policyVersion), .text(fileID.uuidString), .int64(expectedStamp.size), .int64(expectedStamp.modifiedNanoseconds)])
        guard sqlite3_changes(database) == 1 else { return false }
        try execute("DELETE FROM dedup_dependency WHERE file_id=?", [.text(fileID.uuidString)])
        try bumpLocalRevision()
        return true
    }

    public func registerSource(url: URL) async throws -> UUID {
        let normalized = try await readExecutor.execute(sourceID: UUID()) { try self.validateSource(url) }
        try Task.checkCancellation()
        return try await perform { try self.transaction { try self.registerSourceSync(url: normalized) } }
    }

    public func disableSource(id: UUID) async throws {
        try await perform { try self.transaction { try self.retireSourceSync(id: id, removed: false) } }
    }

    /// Removes a source from configuration while retaining its file and submission history.
    /// Existing callbacks can still resolve the source by ID for durable audit records.
    public func removeSource(id: UUID) async throws {
        try await perform { try self.transaction { try self.retireSourceSync(id: id, removed: true) } }
    }

    public func sources() async throws -> [RegisteredSource] {
        try await perform {
            try self.rows("SELECT id, path, enabled FROM source WHERE removed = 0 ORDER BY path", []).map {
                RegisteredSource(id: try self.uuid($0[0]), url: URL(fileURLWithPath: try self.text($0[1])), enabled: try self.int($0[2]) != 0)
            }
        }
    }

    public func source(id: UUID) async throws -> RegisteredSource {
        try await perform {
            guard let row = try self.one("SELECT id, path, enabled FROM source WHERE id = ?", [.text(id.uuidString)]) else { throw SyncStoreError.notFound(id) }
            return RegisteredSource(id: try self.uuid(row[0]), url: URL(fileURLWithPath: try self.text(row[1])), enabled: try self.int(row[2]) != 0)
        }
    }

    func isSourceRemoved(id: UUID) async throws -> Bool {
        try await perform {
            guard let row = try self.one("SELECT removed FROM source WHERE id = ?", [.text(id.uuidString)]) else { throw SyncStoreError.notFound(id) }
            return try self.int(row[0]) != 0
        }
    }

    public func save(_ file: SourceFile, decision: MatchDecision, candidates: [MatchCandidate] = []) async throws -> UUID {
        try await perform {
            try self.transaction {
                let id = UUID()
                let metadata = try self.encode(file.metadata)
                try self.requireChange("""
                    INSERT INTO file_record (id, created_order, source_id, relative_path, filename, size, modified_ns, metadata_json, state, rule_version)
                    VALUES (?, (SELECT COALESCE(MAX(created_order), 0) + 1 FROM file_record), ?, ?, ?, ?, ?, ?, 'pending', ?)
                    """, [.text(id.uuidString), .text(file.sourceID.uuidString), .text(file.relativePath), .text(file.metadata.filename), .int64(file.stamp.size), .int64(file.stamp.modifiedNanoseconds), .text(metadata), .int64(Int64(self.ruleVersion))])
                try self.bumpLocalRevision()
                if case .skip(let keys) = decision {
                    guard Set(keys) == Set(candidates.map(\.key)), keys.count == candidates.count else {
                        throw SyncStoreError.invalidTransition("Skipped files require the complete compared candidate snapshots.")
                    }
                    try self.markSkippedSync(fileID: id, reason: .suspectedDuplicate, candidates: candidates)
                }
                return id
            }
        }
    }

    func saveWithSnapshotValidity(
        _ file: SourceFile,
        decision: MatchDecision,
        candidates: [MatchCandidate],
        validity: any PhotosCandidateValidity
    ) async throws -> SnapshotCommitResult {
        try await perform {
            try self.execute("BEGIN IMMEDIATE")
            do {
                if case .skip = decision, !(try self.localCandidateEvidenceValid(candidates)) {
                    try self.execute("ROLLBACK")
                    return .staleSnapshot
                }
                let id = UUID()
                let metadata = try self.encode(file.metadata)
                try self.requireChange("""
                    INSERT INTO file_record (id, created_order, source_id, relative_path, filename, size, modified_ns, metadata_json, state, rule_version)
                    VALUES (?, (SELECT COALESCE(MAX(created_order), 0) + 1 FROM file_record), ?, ?, ?, ?, ?, ?, 'pending', ?)
                    """, [.text(id.uuidString), .text(file.sourceID.uuidString), .text(file.relativePath), .text(file.metadata.filename), .int64(file.stamp.size), .int64(file.stamp.modifiedNanoseconds), .text(metadata), .int64(Int64(self.ruleVersion))])
                try self.bumpLocalRevision()
                if case .skip(let keys) = decision {
                    guard Set(keys) == Set(candidates.map(\.key)), keys.count == candidates.count else {
                        throw SyncStoreError.invalidTransition("Skipped files require the complete compared candidate snapshots.")
                    }
                    try self.markSkippedSync(fileID: id, reason: .suspectedDuplicate, candidates: candidates)
                }
                guard try validity.commitIfCurrent({ try self.execute("COMMIT") }) else {
                    try self.execute("ROLLBACK")
                    return .staleSnapshot
                }
                return .committed(id)
            } catch {
                try? self.execute("ROLLBACK")
                throw error
            }
        }
    }

    public func file(sourceID: UUID, relativePath: String) async throws -> StoredFile? {
        try await perform { try self.storedFile("SELECT \(Self.fileColumns) FROM file_record JOIN source ON source.id = file_record.source_id WHERE file_record.source_id = ? AND relative_path = ?", [.text(sourceID.uuidString), .text(relativePath)]) }
    }

    /// Pending records observed at the beginning of one source traversal. The caller removes
    /// paths seen by the directory reader and reconciles only after a complete traversal.
    public func pendingPaths(sourceID: UUID) async throws -> [String: UUID] {
        try await perform {
            let rows = try self.rows("SELECT relative_path, id FROM file_record WHERE source_id = ? AND state = 'pending'",
                                     [.text(sourceID.uuidString)])
            var paths: [String: UUID] = [:]
            paths.reserveCapacity(rows.count)
            for row in rows { paths[try self.text(row[0])] = try self.uuid(row[1]) }
            return paths
        }
    }

    /// Retire a source file confirmed absent by a complete directory traversal. A queued row
    /// is safe to remove only when no Photos request was sent or a failure proved non-commit.
    /// Duplicate skips that named this row as a candidate must be reconsidered by normal drain.
    public func removeConfirmedAbsentPending(fileID: UUID) async throws -> Bool {
        try await perform {
            try self.transaction {
                guard let row = try self.one("SELECT state, submitted_at, definitely_not_committed FROM file_record WHERE id = ? AND success_id IS NULL",
                                             [.text(fileID.uuidString)]),
                      try self.fileState(row[0]) == .pending else {
                    return false
                }
                let definitelyNotCommitted = try self.int64(row[2]) == 1
                guard self.optionalDouble(row[1]) == nil || definitelyNotCommitted else { return false }
                let dependents = try self.rows("""
                    SELECT file_record.id FROM match_evidence
                    JOIN file_record ON file_record.id = match_evidence.file_id
                    WHERE match_evidence.candidate_key = ? AND file_record.state = 'skipped'
                      AND file_record.skip_reason = ?
                    """, [.text("file:\(fileID.uuidString)"), .text(SkipReason.suspectedDuplicate.rawValue)])
                for dependent in dependents {
                    let id = try self.text(dependent[0])
                    try self.requireChange("""
                        UPDATE file_record SET state = 'pending', skip_reason = NULL,
                            attempt_id = NULL, placeholder_id = NULL, submitted_at = NULL,
                            definitely_not_committed = 0, retry_count = 0,
                            next_retry_at = NULL, last_error = NULL
                        WHERE id = ? AND state = 'skipped' AND skip_reason = ?
                        """, [.text(id), .text(SkipReason.suspectedDuplicate.rawValue)])
                    try self.execute("DELETE FROM match_evidence WHERE file_id = ?", [.text(id)])
                }
                try self.reopenDependents(candidateID: fileID)
                try self.execute("DELETE FROM dedup_dependency WHERE file_id = ?", [.text(fileID.uuidString)])
                try self.execute("DELETE FROM advanced_match_evidence WHERE file_id = ?", [.text(fileID.uuidString)])
                try self.execute("DELETE FROM file_fingerprint WHERE file_id = ?", [.text(fileID.uuidString)])
                try self.execute("DELETE FROM match_evidence WHERE file_id = ?", [.text(fileID.uuidString)])
                try self.bumpLocalRevision()
                try self.requireChange("DELETE FROM file_record WHERE id = ? AND state = 'pending'", [.text(fileID.uuidString)])
                return true
            }
        }
    }

    public func state(of id: UUID) async throws -> FileState {
        try await perform {
            guard let row = try self.one("SELECT state FROM file_record WHERE id = ?", [.text(id.uuidString)]) else { throw SyncStoreError.notFound(id) }
            return try self.fileState(row[0])
        }
    }

    public func beginAttempt(fileID: UUID, attemptID: UUID) async throws {
        try await perform { try self.transaction {
            try self.beginAttemptSync(fileID: fileID, attemptID: attemptID)
            try self.bumpLocalRevision()
        } }
    }

    public func checkpointPlaceholder(fileID: UUID, attemptID: UUID, identifier: String) throws {
        try queue.sync {
            try requireChange("UPDATE file_record SET placeholder_id = ? WHERE id = ? AND state = 'importing' AND attempt_id = ?", [.text(identifier), .text(fileID.uuidString), .text(attemptID.uuidString)])
        }
    }

    public func markImported(fileID: UUID, attemptID: UUID, identifier: String) async throws {
        try await markImported(fileID: fileID, attemptID: attemptID, identifier: identifier, sourceFingerprint: nil)
    }

    public func markImported(fileID: UUID, attemptID: UUID, identifier: String, sourceFingerprint: PreparedSource?) async throws {
        try await perform { try self.transaction {
            guard let record = try self.storedFile("SELECT \(Self.fileColumns) FROM file_record JOIN source ON source.id = file_record.source_id WHERE file_record.id = ?", [.text(fileID.uuidString)]),
                  record.state == .importing, record.attemptID == attemptID, record.successID == nil else {
                throw SyncStoreError.invalidTransition("Success must resolve the active attempt.")
            }
            // An immutable attempt wins over a later caller/cache value. Never consult
            // Photos/index readiness here: the successful callback is durable evidence.
            let attempt = try self.one("SELECT 1 FROM file_fingerprint WHERE file_id = ? AND purpose = 'attempt' AND attempt_id = ?", [.text(fileID.uuidString), .text(attemptID.uuidString)])
            if attempt != nil {
                try self.execute("INSERT INTO file_fingerprint (file_id, size, modified_ns, fingerprint_version, purpose, attempt_id, width, height, vector) SELECT file_id, size, modified_ns, fingerprint_version, 'success', '', width, height, vector FROM file_fingerprint WHERE file_id = ? AND purpose = 'attempt' AND attempt_id = ?", [.text(fileID.uuidString), .text(attemptID.uuidString)])
            } else if try self.one("SELECT 1 FROM advanced_match_evidence WHERE file_id = ?", [.text(fileID.uuidString)]) == nil,
                      let sourceFingerprint, record.file.metadata.kind == .image,
                      sourceFingerprint.fileID == fileID, sourceFingerprint.file.sourceID == record.file.sourceID,
                      sourceFingerprint.file.relativePath == record.file.relativePath, sourceFingerprint.file.stamp == record.file.stamp,
                      sourceFingerprint.file.metadata == record.file.metadata {
                // Only legacy attempts accept this fallback. An advanced admission without
                // an attempt vector is conservative and must never acquire one at success.
                try self.writeFingerprint(sourceFingerprint, purpose: "success")
            }
            try self.requireChange("UPDATE file_record SET state = 'imported', success_id = ?, success_metadata_json = metadata_json, succeeded_at = ?, attempt_id = NULL, placeholder_id = NULL, retry_count = 0, next_retry_at = NULL, last_error = NULL WHERE id = ? AND state = 'importing' AND attempt_id = ?", [.text(identifier), .double(Date().timeIntervalSince1970), .text(fileID.uuidString), .text(attemptID.uuidString)])
            try self.execute("DELETE FROM file_fingerprint WHERE file_id = ? AND purpose = 'attempt'", [.text(fileID.uuidString)])
            try self.execute("DELETE FROM dedup_dependency WHERE candidate_file_id = ?", [.text(fileID.uuidString)])
            try self.bumpLocalRevision()
        } }
    }

    @discardableResult
    public func recordSourceChange(fileID: UUID, stamp: FileStamp) async throws -> Bool {
        try await perform {
            try self.transaction {
                guard let row = try self.one("SELECT state FROM file_record WHERE id = ?", [.text(fileID.uuidString)]) else {
                    throw SyncStoreError.notFound(fileID)
                }
                if try self.fileState(row[0]) == .importing {
                    return false
                }
                try self.requireChange("UPDATE file_record SET size = ?, modified_ns = ?, state = 'skipped', skip_reason = ?, attempt_id = NULL, placeholder_id = NULL WHERE id = ? AND state <> 'importing'", [.int64(stamp.size), .int64(stamp.modifiedNanoseconds), .text(SkipReason.sourceChanged.rawValue), .text(fileID.uuidString)])
                try self.reopenDependents(candidateID: fileID)
                try self.execute("DELETE FROM dedup_dependency WHERE file_id = ?", [.text(fileID.uuidString)])
                try self.bumpLocalRevision()
                return true
            }
        }
    }

    public func successIdentifier(of id: UUID) async throws -> String? {
        try await perform {
            guard let row = try self.one("SELECT success_id FROM file_record WHERE id = ?", [.text(id.uuidString)]) else { throw SyncStoreError.notFound(id) }
            return self.optionalText(row[0])
        }
    }

    public func countFiles(state: FileState) async throws -> Int {
        try await perform {
            guard let row = try self.one("SELECT COUNT(*) FROM file_record WHERE state = ?", [.text(state.rawValue)]) else { return 0 }
            return Int(try self.int64(row[0]))
        }
    }

    public func countEnabledFiles(state: FileState) async throws -> Int {
        try await perform {
            guard let row = try self.one("SELECT COUNT(*) FROM file_record JOIN source ON source.id = file_record.source_id WHERE file_record.state = ? AND source.enabled = 1 AND source.removed = 0", [.text(state.rawValue)]) else { return 0 }
            return Int(try self.int64(row[0]))
        }
    }

    /// Sources with a persisted, explicitly retryable file failure whose deadline has arrived.
    /// An uncertain importing record never appears here: seeing no callback cannot prove that the
    /// earlier Photos request did not commit.
    public func dueRetrySourceIDs(at now: Date) async throws -> [UUID] {
        try await perform {
            try self.rows("""
                SELECT DISTINCT source.id
                FROM file_record
                JOIN source ON source.id = file_record.source_id
                WHERE source.enabled = 1 AND source.removed = 0
                  AND file_record.state = 'pending'
                  AND file_record.last_error IS NOT NULL
                  AND file_record.definitely_not_committed = 1
                  AND file_record.next_retry_at IS NOT NULL
                  AND file_record.next_retry_at <= ?
                ORDER BY source.id
                """, [.double(now.timeIntervalSince1970)]).map { try self.uuid($0[0]) }
        }
    }

    /// Returns all visible state counters from one SQLite statement, so callers do not combine
    /// independently observed queue states while a submission is changing a record.
    /// `retainedImported` counts successful imports whose source is disabled or removed: they stay
    /// in the database as history but are deliberately outside the counters above, so a person who
    /// retires a source (for example to configure its parent directory instead) is told where the
    /// numbers went instead of seeing the totals silently reset.
    public func activeSourceSummary() async throws -> SyncStatusSummary {
        try await perform {
            guard sqlite3_get_autocommit(self.database) != 0 else {
                throw SyncStoreError.sqlite("An unresolved database transaction prevents a safe summary")
            }
            guard let row = try self.one("""
                WITH scoped AS (
                    SELECT file_record.state AS state,
                           file_record.last_error AS last_error,
                           CASE WHEN source.enabled = 1 AND source.removed = 0 THEN 1 ELSE 0 END AS active
                    FROM file_record
                    JOIN source ON source.id = file_record.source_id
                )
                SELECT
                    COALESCE(SUM(CASE WHEN active = 1 AND state = 'imported' THEN 1 ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN active = 1 AND state = 'skipped' THEN 1 ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN active = 1 AND state = 'pending' AND last_error IS NULL THEN 1 ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN active = 1 AND state = 'importing' THEN 1 ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN active = 1 AND state = 'pending' AND last_error IS NOT NULL THEN 1 ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN active = 0 AND state = 'imported' THEN 1 ELSE 0 END), 0)
                FROM scoped
                """, []) else {
                return SyncStatusSummary()
            }
            return SyncStatusSummary(
                imported: Int(try self.int64(row[0])),
                skipped: Int(try self.int64(row[1])),
                pending: Int(try self.int64(row[2])),
                importing: Int(try self.int64(row[3])),
                retryPending: Int(try self.int64(row[4])),
                retainedImported: Int(try self.int64(row[5]))
            )
        }
    }

    public func listFiles(state: FileState, afterID: UUID?, limit: Int) async throws -> [StoredFile] {
        try await perform {
            guard limit > 0 else { return [] }
            let afterOrder: Int64
            if let afterID {
                guard let row = try self.one("SELECT created_order FROM file_record WHERE id = ?", [.text(afterID.uuidString)]) else { throw SyncStoreError.notFound(afterID) }
                afterOrder = try self.int64(row[0])
            } else { afterOrder = 0 }
            return try self.rows("SELECT \(Self.fileColumns) FROM file_record JOIN source ON source.id = file_record.source_id WHERE file_record.live_photo_operation_id IS NULL AND file_record.state = ? AND created_order > ? ORDER BY created_order LIMIT ?", [.text(state.rawValue), .int64(afterOrder), .int64(Int64(limit))]).map(self.decodeStoredFile)
        }
    }

    /// Selects one active pending record after a stable created-order cursor. The order value
    /// remains valid even if the previous row was normally deleted during another source scan.
    /// The caller owns retry-deadline checks so future retries remain visible to the round.
    public func nextPendingFile(sourceIDs: Set<UUID>, afterOrder: Int64?) async throws -> StoredFile? {
        try await perform {
            guard !sourceIDs.isEmpty else { return nil }
            let orderedSources = sourceIDs.sorted { $0.uuidString < $1.uuidString }
            let placeholders = Array(repeating: "?", count: orderedSources.count).joined(separator: ", ")
            var bindings: [Binding] = [.int64(afterOrder ?? 0)]
            bindings.append(contentsOf: orderedSources.map { .text($0.uuidString) })
            return try self.storedFile("""
                SELECT \(Self.fileColumns)
                FROM file_record
                JOIN source ON source.id = file_record.source_id
                WHERE file_record.state = 'pending'
                  AND file_record.live_photo_operation_id IS NULL
                  AND file_record.created_order > ?
                  AND file_record.source_id IN (\(placeholders))
                  AND source.enabled = 1 AND source.removed = 0
                ORDER BY file_record.created_order
                LIMIT 1
                """, bindings)
        }
    }

    /// Only the unchanged, formal FP16 Source decoder is equivalent. Photos
    /// representations must be regenerated under the new input contract.
    public func rebindEquivalentSourceFingerprints(to configuration: FingerprintConfiguration) async throws {
        let formal = try FingerprintConfiguration(
            modelSHA256: "026e7a43660e29c307941a88dbe35b9c14468693333ff926e9b984eef3b4b8d0",
            inputSide: 320, resizeMode: .stretchFullFrame, colorSpace: "sRGB",
            mean: [0.485, 0.456, 0.406], std: [0.229, 0.224, 0.225])
        guard configuration == formal else { throw AdvancedDedupError.invalidConfiguration }
        let legacy = "ec805406fa61e91384e4bf29ae29a52694b80e3755afd7768da80a6db70c9a1d"
        try await perform {
            try self.transaction {
                guard try self.one("SELECT 1 FROM file_fingerprint WHERE fingerprint_version = ? LIMIT 1", [.text(legacy)]) != nil else { return }
                // SQLite streams the comparison; no Swift collection of historical
                // 4096-byte vectors, even for 100K+ Source rows.
                let keys = "new.file_id = old.file_id AND new.size = old.size AND new.modified_ns = old.modified_ns AND new.purpose = old.purpose AND new.attempt_id = old.attempt_id"
                guard try self.one("""
                    SELECT 1 FROM file_fingerprint old JOIN file_fingerprint new ON \(keys)
                    WHERE old.fingerprint_version = ? AND new.fingerprint_version = ?
                    AND NOT (new.width IS old.width AND new.height IS old.height AND new.vector IS old.vector) LIMIT 1
                    """, [.text(legacy), .text(formal.version)]) == nil else {
                    throw SyncStoreError.invalidTransition("Equivalent Source fingerprint collision has different bytes or facts.")
                }
                // Identical collisions can merge without touching successful or
                // unknown attempt relationships. All other versions remain intact.
                try self.execute("""
                    DELETE FROM file_fingerprint AS old WHERE old.fingerprint_version = ? AND EXISTS (
                        SELECT 1 FROM file_fingerprint new WHERE \(keys) AND new.fingerprint_version = ?)
                    """, [.text(legacy), .text(formal.version)])
                try self.execute("UPDATE file_fingerprint SET fingerprint_version = ? WHERE fingerprint_version = ?", [.text(formal.version), .text(legacy)])
                try self.execute("UPDATE dedup_index_state SET local_revision = local_revision + 1 WHERE id = 1")
            }
        }
    }

    public func fingerprint(fileID: UUID, stamp: FileStamp, version: String) async throws -> Fingerprint? {
        try await perform {
            guard let row = try self.one("SELECT vector FROM file_fingerprint WHERE file_id = ? AND size = ? AND modified_ns = ? AND fingerprint_version = ? AND purpose = 'current'",
                [.text(fileID.uuidString), .int64(stamp.size), .int64(stamp.modifiedNanoseconds), .text(version)]) else { return nil }
            guard case .blob(let bytes) = row[0] else { throw AdvancedDedupError.invalidFingerprint }
            return try Fingerprint(version: version, littleEndianFloat32: bytes)
        }
    }

    /// A current vector is admitted only for the exact observed source stamp. No
    /// successful/unknown submission is replaced by a late source preparation.
    public func cacheFingerprint(_ source: PreparedSource) async throws -> Bool {
        try await perform {
            try self.transaction {
                guard let row = try self.one("SELECT size, modified_ns, state, success_id, enabled, removed FROM file_record JOIN source ON source.id = file_record.source_id WHERE file_record.id = ? AND source_id = ? AND relative_path = ?",
                    [.text(source.fileID.uuidString), .text(source.file.sourceID.uuidString), .text(source.file.relativePath)]),
                    try self.int64(row[0]) == source.file.stamp.size, try self.int64(row[1]) == source.file.stamp.modifiedNanoseconds,
                    try self.text(row[2]) != "importing", try self.text(row[2]) != "imported", self.optionalText(row[3]) == nil,
                    try self.int(row[4]) == 1, try self.int(row[5]) == 0 else { return false }
                let bindings: [Binding] = [.text(source.fileID.uuidString), .int64(source.file.stamp.size),
                    .int64(source.file.stamp.modifiedNanoseconds), .text(source.fingerprint.version)]
                let previous = try self.one("SELECT width, height, vector FROM file_fingerprint WHERE file_id = ? AND size = ? AND modified_ns = ? AND fingerprint_version = ? AND purpose = 'current'", bindings)
                let bytes = source.fingerprint.littleEndianFloat32
                if let previous, self.optionalInteger(previous[0]) == source.size.map({ Int64($0.width) }),
                    self.optionalInteger(previous[1]) == source.size.map({ Int64($0.height) }), case .blob(let old) = previous[2], old == bytes { return true }
                try self.execute("INSERT OR REPLACE INTO file_fingerprint (file_id, size, modified_ns, fingerprint_version, purpose, width, height, vector) VALUES (?, ?, ?, ?, 'current', ?, ?, ?)",
                    bindings + [source.size.map { .int64(Int64($0.width)) } ?? .null,
                                source.size.map { .int64(Int64($0.height)) } ?? .null, .blob(bytes)])
                try self.execute("UPDATE dedup_index_state SET local_revision = local_revision + 1 WHERE id = 1")
                return true
            }
        }
    }

    /// Candidate facts and their admission revision are read in one transaction.
    /// Filename never restricts advanced comparison. Only older active queue
    /// records participate; successful facts survive disabled/removed sources.
    public func localVectorCandidates(beforeOrder: Int64, excluding: UUID, version: String) async throws -> (revision: Int64, entries: [VectorEntry]) {
        try await perform {
            try self.transaction {
                let revision = try self.indexStateRow().map { try self.int64($0[6]) } ?? 0
                let entries = try self.mappedRows("""
                    SELECT f.id, f.state, f.success_id, v.width, v.height, v.vector FROM file_record f
                    JOIN source s ON s.id = f.source_id JOIN file_fingerprint v ON v.file_id = f.id
                    WHERE f.id <> ? AND v.fingerprint_version = ? AND (
                        (f.success_id IS NOT NULL AND v.purpose = 'success') OR
                        (f.success_id IS NULL AND f.state IN ('pending', 'importing') AND f.created_order < ?
                         AND s.enabled = 1 AND s.removed = 0 AND v.purpose = 'current'
                         AND v.size = f.size AND v.modified_ns = f.modified_ns)) ORDER BY f.created_order
                    """, [.text(excluding.uuidString), .text(version), .int64(beforeOrder)]) { row -> VectorEntry in
                    guard case .blob(let data) = row[5] else { throw AdvancedDedupError.invalidFingerprint }
                    let size: PixelSize?
                    if let width = self.optionalInteger(row[3]), let height = self.optionalInteger(row[4]) {
                        size = try PixelSize(width: Int(width), height: Int(height))
                    } else { size = nil }
                    let origin: CandidateOrigin = self.optionalText(row[2]) != nil ? .successHistory :
                        (try self.text(row[1]) == "importing" ? .localImporting : .localPending)
                    return VectorEntry(key: "file:\(try self.text(row[0]))", origin: origin,
                        fingerprint: try Fingerprint(version: version, littleEndianFloat32: data), size: size)
                }
                return (revision, entries)
            }
        }
    }

    /// One read snapshot owns token validation and the complete Photos/local/history scan.
    /// No vector survives its cursor row. Nil means expired publication/token; malformed
    /// facts, failed SQLite reads and cancellation throw without exposing partial results.
    public func vectorCandidates(for fileID: UUID, query: Fingerprint, token: IndexToken,
                                 threshold: Double, diagnosticLimit: Int) async throws -> VectorSearchResult? {
        guard threshold.isFinite, (-1...1).contains(threshold), diagnosticLimit >= 0 else {
            throw AdvancedDedupError.invalidConfiguration
        }
        let collector = SQLiteVectorCollector(version: query.version, threshold: threshold, diagnosticLimit: diagnosticLimit)
        return try await withTaskCancellationHandler(operation: {
            try await self.perform {
                // The store queue is acquired before the transaction. No Photos/model
                // lock or I/O is needed here; commitAdvanced keeps its existing gate order.
                try self.execute("BEGIN")
                do {
                    let result = try self.vectorCandidatesSync(for: fileID, query: query, token: token, collector: collector)
                    try self.execute("COMMIT")
                    return result
                } catch { try? self.execute("ROLLBACK"); throw error }
            }
        }, onCancel: { collector.cancel() })
    }

    /// Successful vectors remain immutable even across source retirement and model upgrades.
    /// A different model cannot prove these histories are nonduplicates.
    public func hasUnsupportedSuccessfulFingerprint(version: String) async throws -> Bool {
        try await perform { try self.hasUnsupportedSuccessfulFingerprintSync(version: version) }
    }
    private func hasUnsupportedSuccessfulFingerprintSync(version: String) throws -> Bool {
        try one("""
            SELECT 1 FROM file_fingerprint v JOIN file_record f ON f.id = v.file_id
            WHERE f.success_id IS NOT NULL AND v.purpose = 'success' AND v.fingerprint_version <> ? LIMIT 1
            """, [.text(version)]) != nil
    }

    private func vectorCandidatesSync(for fileID: UUID, query: Fingerprint, token: IndexToken,
                                      collector: SQLiteVectorCollector) throws -> VectorSearchResult? {
        guard !collector.isCancelled else { throw CancellationError() }
        guard let state = try indexStateRow(), try indexToken(state) == token,
              optionalInteger(state[3]) == token.indexGeneration,
              let published = publishedIndexToken, samePhotosIndex(published, token) else { return nil }
        guard query.version == token.fingerprintVersion else { throw AdvancedDedupError.modelMismatch }
        guard try !hasUnsupportedSuccessfulFingerprintSync(version: query.version) else {
            throw ModelExecutionUnavailable(detail: "Successful history uses an unsupported fingerprint version; preserved pending explicit upgrade")
        }
        // A matching published token with corrupted underlying facts is an error,
        // never a stale-token nil or an empty gallery proving non-duplication.
        guard try indexFactsComplete(state) else { throw AdvancedDedupError.invalidFingerprint }
        guard let incoming = try one("SELECT created_order FROM file_record WHERE id = ?", [.text(fileID.uuidString)]) else {
            throw SyncStoreError.invalidTransition("The incoming file is no longer recorded.")
        }
        let sql = """
            SELECT 'photos:' || length(CAST(asset_id AS BLOB)) || ':' || asset_id || ':' || kind,
                CASE kind WHEN 'original' THEN 'photosOriginal' WHEN 'current' THEN 'photosCurrent' ELSE '' END,
                width, height, vector FROM photos_representation
            WHERE context_id = ? AND context_epoch = ? AND tombstoned = 0
                AND state = 'ready' AND fingerprint_version = ?
            UNION ALL
            SELECT 'file:' || f.id,
                CASE WHEN f.success_id IS NOT NULL THEN 'successHistory'
                     WHEN f.state = 'importing' THEN 'localImporting' ELSE 'localPending' END,
                v.width, v.height, v.vector FROM file_record f
            JOIN source s ON s.id = f.source_id JOIN file_fingerprint v ON v.file_id = f.id
            WHERE f.id <> ? AND v.fingerprint_version = ? AND (
                (f.success_id IS NOT NULL AND v.purpose = 'success') OR
                (f.success_id IS NULL AND f.state IN ('pending', 'importing') AND f.created_order < ?
                 AND s.enabled = 1 AND s.removed = 0 AND v.purpose = 'current'
                 AND v.size = f.size AND v.modified_ns = f.modified_ns))
            """
        let bindings: [Binding] = [.text(token.context.id.uuidString), .int64(token.context.epoch),
            .text(token.fingerprintVersion), .text(fileID.uuidString),
            .text(query.version), .int64(try int64(incoming[0]))]
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        guard sqlite3_stmt_readonly(statement) != 0 else { throw AdvancedDedupError.invalidConfiguration }
        for (offset, binding) in bindings.enumerated() { try bind(binding, to: statement, index: Int32(offset + 1)) }
        let context = Unmanaged.passUnretained(collector).toOpaque()
        let status = query.values.withUnsafeBufferPointer { values in
            ps_vector_scan(statement, values.baseAddress!, collector.threshold, collector.diagnosticFloor,
                { context, row, score in
                    Unmanaged<SQLiteVectorCollector>.fromOpaque(context!).takeUnretainedValue().collect(row: row!, score: score)
                }, { context in
                    Unmanaged<SQLiteVectorCollector>.fromOpaque(context!).takeUnretainedValue().isCancelled ? 1 : 0
                }, context)
        }
        switch status {
        case Int32(PS_VECTOR_OK.rawValue): return collector.result
        case Int32(PS_VECTOR_INVALID_METADATA.rawValue): throw AdvancedDedupError.invalidConfiguration
        case Int32(PS_VECTOR_INVALID_FINGERPRINT.rawValue): throw AdvancedDedupError.invalidFingerprint
        case Int32(PS_VECTOR_CANCELLED.rawValue): throw CancellationError()
        case Int32(PS_VECTOR_COLLECTION_ERROR.rawValue): throw collector.error ?? AdvancedDedupError.invalidConfiguration
        default: throw databaseError()
        }
    }

    public func commitAdvancedSkip(_ admission: AdvancedAdmission) async throws -> Bool {
        guard admission.evidence.evaluation.action == .skip else { return false }
        return try await commitAdvanced(fileID: admission.source.fileID, file: admission.source.file,
            evidence: admission.evidence, validity: admission.validity, prepared: admission.source, attemptID: nil)
    }

    public func beginAdvancedAttempt(_ admission: AdvancedAdmission, attemptID: UUID) async throws -> Bool {
        guard admission.evidence.evaluation.action == .importFile else { return false }
        return try await commitAdvanced(fileID: admission.source.fileID, file: admission.source.file,
            evidence: admission.evidence, validity: admission.validity, prepared: admission.source, attemptID: attemptID)
    }

    public func beginAdvancedAttempt(_ admission: ConservativeSourceAdmission, attemptID: UUID) async throws -> Bool {
        let evaluation = admission.evidence.evaluation
        guard evaluation.action == .importFile, evaluation.content == .notCompared,
              evaluation.reason == .nonComparableSource, evaluation.matchedKeys.isEmpty,
              evaluation.coveringKeys.isEmpty, admission.evidence.decisiveCandidates.isEmpty,
              admission.evidence.diagnostics.isEmpty else { return false }
        return try await commitAdvanced(fileID: admission.fileID, file: admission.file,
            evidence: admission.evidence, validity: admission.validity, prepared: nil, attemptID: attemptID)
    }

    /// Checks only the store/index portion of the post-attempt receipt. Admission
    /// saves pre-attempt revision R and advances it EXACTLY ONCE to R+1 in the same
    /// transaction. Never adopt an observed newer revision here: another write is
    /// new evidence that was not scored. P6 must still guard pause/source/stamp and
    /// Photos validity at physical create, including any intervening await.
    public func advancedAttemptIsCurrent(fileID: UUID, attemptID: UUID) async throws -> Bool {
        try await perform { try self.advancedAttemptReceipt(fileID: fileID, attemptID: attemptID) }
    }

    /// Only call without any Photos-validity or engine-state lock held. The queue
    /// check avoids reentrant sync deadlock; source/Photos I/O never enters here.
    public func advancedAttemptIsCurrentSynchronously(fileID: UUID, attemptID: UUID) throws -> Bool {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            return try advancedAttemptReceipt(fileID: fileID, attemptID: attemptID)
        }
        return try queue.sync { try advancedAttemptReceipt(fileID: fileID, attemptID: attemptID) }
    }

    private func advancedAttemptReceipt(fileID: UUID, attemptID: UUID) throws -> Bool {
        try transaction {
            guard let receipt = try self.one("""
                SELECT e.token_json, e.size, e.modified_ns, f.size, f.modified_ns
                FROM file_record f JOIN source s ON s.id = f.source_id
                JOIN advanced_match_evidence e ON e.file_id = f.id
                WHERE f.id = ? AND f.attempt_id = ? AND f.state = 'importing'
                    AND f.success_id IS NULL AND s.enabled = 1 AND s.removed = 0 AND e.action = 'importFile'
                """, [.text(fileID.uuidString), .text(attemptID.uuidString)]),
                  try self.int64(receipt[1]) == self.int64(receipt[3]),
                  try self.int64(receipt[2]) == self.int64(receipt[4]) else { return false }
            let original = try self.decode(IndexToken.self, from: self.text(receipt[0]))
            let (revision, overflow) = original.localRevision.addingReportingOverflow(1)
            guard !overflow else { return false }
            let expected = IndexToken(context: original.context, photosGeneration: original.photosGeneration,
                indexGeneration: original.indexGeneration, localRevision: revision, fingerprintVersion: original.fingerprintVersion)
            guard let state = try self.indexStateRow(), try self.indexToken(state) == expected,
                  self.optionalInteger(state[3]) == expected.indexGeneration,
                  let published = self.publishedIndexToken, self.samePhotosIndex(published, expected) else { return false }
            return try !self.hasUnsupportedSuccessfulFingerprintSync(version: expected.fingerprintVersion) && self.indexFactsComplete(state)
        }
    }

    private enum AdmissionFailure: Error { case stale }

    /// The Photos gate is acquired before BEGIN and held through COMMIT. All work is
    /// synchronous on the existing SQLite queue; no Photos I/O occurs under the lock.
    private func commitAdvanced(fileID: UUID, file: SourceFile, evidence: AdvancedEvidence,
                                validity: any PhotosCandidateValidity, prepared: PreparedSource?, attemptID: UUID?) async throws -> Bool {
        try await perform {
            do {
                return try validity.commitIfCurrent {
                    try self.transaction {
                        guard evidence.fileID == fileID, evidence.stamp == file.stamp, file.metadata.kind == .image,
                              let state = try self.indexStateRow(), try self.indexToken(state) == evidence.token,
                              self.optionalInteger(state[3]) == evidence.token.indexGeneration,
                              let published = self.publishedIndexToken, self.samePhotosIndex(published, evidence.token),
                              try self.indexFactsComplete(state),
                              try !self.hasUnsupportedSuccessfulFingerprintSync(version: evidence.token.fingerprintVersion),
                              let record = try self.storedFile("SELECT \(Self.fileColumns) FROM file_record JOIN source ON source.id = file_record.source_id WHERE file_record.id = ? AND file_record.live_photo_operation_id IS NULL AND source.enabled = 1 AND source.removed = 0 AND (submitted_at IS NULL OR definitely_not_committed = 1)", [.text(fileID.uuidString)]),
                              record.state == .pending, record.successID == nil, record.file.sourceID == file.sourceID,
                              record.file.relativePath == file.relativePath, record.file.stamp == file.stamp,
                              record.file.metadata == file.metadata,
                              evidence.evaluation.matchedKeys == evidence.decisiveCandidates.map(\.key),
                              evidence.evaluation.coveringKeys.allSatisfy({ evidence.evaluation.matchedKeys.contains($0) }) else {
                            throw AdmissionFailure.stale
                        }
                        if let prepared {
                            guard prepared.fingerprint.version == evidence.token.fingerprintVersion,
                                  evidence.evaluation.content != .notCompared else { throw AdmissionFailure.stale }
                        }
                        for candidate in evidence.decisiveCandidates {
                            guard try self.advancedCandidateIsCurrent(candidate, incoming: record, token: evidence.token) else {
                                throw AdmissionFailure.stale
                            }
                        }
                        // Replace the previous decision's relationships together with its
                        // state/evidence, including legacy evidence left by a recheck.
                        try self.execute("DELETE FROM match_evidence WHERE file_id = ?", [.text(fileID.uuidString)])
                        try self.execute("DELETE FROM dedup_dependency WHERE file_id = ?", [.text(fileID.uuidString)])
                        if attemptID == nil {
                            guard let candidate = evidence.decisiveCandidates.first,
                                  evidence.evaluation.content == .duplicate, evidence.evaluation.reason == .covered,
                                  evidence.evaluation.coveringKeys == [candidate.key],
                                  let sourceSize = prepared?.size, let size = candidate.size,
                                  min(size.width, size.height) >= min(sourceSize.width, sourceSize.height),
                                  max(size.width, size.height) >= max(sourceSize.width, sourceSize.height) else { throw AdmissionFailure.stale }
                            try self.requireChange("UPDATE file_record SET state = 'skipped', skip_reason = ?, attempt_id = NULL, placeholder_id = NULL WHERE id = ? AND state = 'pending'", [.text(SkipReason.suspectedDuplicate.rawValue), .text(fileID.uuidString)])
                            try self.reopenDependents(candidateID: fileID)
                            if candidate.origin == .localPending || candidate.origin == .localImporting {
                                let candidateID = String(candidate.key.dropFirst(5))
                                try self.execute("INSERT INTO dedup_dependency (file_id, candidate_file_id, candidate_revision) VALUES (?, ?, ?)",
                                    [.text(fileID.uuidString), .text(candidateID), .text(try self.encode(evidence.token))])
                            }
                        } else if let attemptID {
                            try self.beginAttemptSync(fileID: fileID, attemptID: attemptID)
                            if let prepared { try self.writeFingerprint(prepared, purpose: "attempt", attemptID: attemptID.uuidString) }
                        }
                        try self.execute("DELETE FROM advanced_match_evidence WHERE file_id = ?", [.text(fileID.uuidString)])
                        try self.execute("INSERT INTO advanced_match_evidence (event_id, file_id, size, modified_ns, token_json, policy_version, action, evidence_json, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                            [.text(evidence.eventID.uuidString), .text(fileID.uuidString), .int64(file.stamp.size), .int64(file.stamp.modifiedNanoseconds),
                             .text(try self.encode(evidence.token)), .text(evidence.policyVersion), .text(evidence.evaluation.action.rawValue),
                             .text(try self.encode(evidence)), .double(Date().timeIntervalSince1970)])
                        // EXACTLY ONE increment: advancedAttemptIsCurrent derives the
                        // immutable post-attempt receipt as evidence.token.R + 1.
                        try self.bumpLocalRevision()
                    }
                }
            } catch AdmissionFailure.stale { return false }
        }
    }

    private func advancedCandidateIsCurrent(_ candidate: ScoredCandidate, incoming: StoredFile, token: IndexToken) throws -> Bool {
        guard candidate.fingerprintVersion == token.fingerprintVersion, candidate.score.isFinite else { return false }
        let row: [Value]?
        switch candidate.origin {
        case .photosOriginal, .photosCurrent:
            let kind = candidate.origin == .photosOriginal ? "original" : "current"
            row = try one("""
                SELECT width, height FROM photos_representation WHERE context_id = ? AND context_epoch = ?
                AND tombstoned = 0 AND state = 'ready' AND vector IS NOT NULL
                AND fingerprint_version = ? AND kind = ?
                AND ('photos:' || length(CAST(asset_id AS BLOB)) || ':' || asset_id || ':' || kind) = ?
                """, [.text(token.context.id.uuidString), .int64(token.context.epoch),
                       .text(token.fingerprintVersion), .text(kind), .text(candidate.key)])
        case .localPending, .localImporting, .successHistory:
            guard candidate.key.hasPrefix("file:"), let id = UUID(uuidString: String(candidate.key.dropFirst(5))), id != incoming.id else { return false }
            var sql = "SELECT v.width, v.height FROM file_record f JOIN source s ON s.id = f.source_id JOIN file_fingerprint v ON v.file_id = f.id WHERE f.id = ? AND v.fingerprint_version = ?"
            var bindings: [Binding] = [.text(id.uuidString), .text(token.fingerprintVersion)]
            if candidate.origin == .successHistory {
                sql += " AND f.success_id IS NOT NULL AND v.purpose = 'success'"
            } else {
                sql += " AND f.success_id IS NULL AND f.state = ? AND f.created_order < ? AND s.enabled = 1 AND s.removed = 0 AND v.purpose = 'current' AND v.size = f.size AND v.modified_ns = f.modified_ns"
                bindings += [.text(candidate.origin == .localPending ? "pending" : "importing"), .int64(incoming.createdOrder)]
            }
            row = try one(sql, bindings)
        }
        guard let row else { return false }
        return try pixelSize(width: row[0], height: row[1]) == candidate.size
    }

    private func writeFingerprint(_ source: PreparedSource, purpose: String, attemptID: String = "") throws {
        try execute("INSERT INTO file_fingerprint (file_id, size, modified_ns, fingerprint_version, purpose, attempt_id, width, height, vector) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [.text(source.fileID.uuidString), .int64(source.file.stamp.size), .int64(source.file.stamp.modifiedNanoseconds),
             .text(source.fingerprint.version), .text(purpose), .text(attemptID), source.size.map { .int64(Int64($0.width)) } ?? .null,
             source.size.map { .int64(Int64($0.height)) } ?? .null, .blob(source.fingerprint.littleEndianFloat32)])
    }

    private func bumpLocalRevision() throws {
        try execute("UPDATE dedup_index_state SET local_revision = local_revision + 1 WHERE id = 1")
    }

    /// Only an unsubmitted duplicate may reopen. Confirmed success and unresolved
    /// submissions never become new pending work, even when their source retires.
    private func reopenDependents(candidateID: UUID) throws {
        let key = candidateID.uuidString
        guard try one("SELECT 1 FROM file_record WHERE id = ? AND success_id IS NOT NULL", [.text(key)]) == nil else { return }
        let dependents = try rows("SELECT file_id FROM dedup_dependency WHERE candidate_file_id = ?", [.text(key)])
        for dependent in dependents {
            let id = try text(dependent[0])
            try execute("""
                UPDATE file_record SET state = 'pending', skip_reason = NULL, attempt_id = NULL, placeholder_id = NULL,
                    submitted_at = NULL, definitely_not_committed = 0, retry_count = 0, next_retry_at = NULL, last_error = NULL
                WHERE id = ? AND state = 'skipped' AND skip_reason = ? AND success_id IS NULL
                    AND (submitted_at IS NULL OR definitely_not_committed = 1)
                """, [.text(id), .text(SkipReason.suspectedDuplicate.rawValue)])
        }
        try execute("DELETE FROM dedup_dependency WHERE candidate_file_id = ?", [.text(key)])
    }

    private func retireSourceSync(id: UUID, removed: Bool) throws {
        try requireChange("UPDATE source SET enabled = 0, removed = ? WHERE id = ? AND removed = 0", [.int64(removed ? 1 : 0), .text(id.uuidString)])
        for row in try rows("SELECT id FROM file_record WHERE source_id = ? AND success_id IS NULL", [.text(id.uuidString)]) {
            try reopenDependents(candidateID: uuid(row[0]))
        }
        try bumpLocalRevision()
    }

    private func beginAttemptSync(fileID: UUID, attemptID: UUID) throws {
        try requireChange("UPDATE file_record SET state = 'importing', attempt_id = ?, placeholder_id = NULL, submitted_at = ?, definitely_not_committed = 0, last_error = NULL WHERE id = ? AND live_photo_operation_id IS NULL AND state = 'pending' AND success_id IS NULL AND (submitted_at IS NULL OR definitely_not_committed = 1)", [.text(attemptID.uuidString), .double(Date().timeIntervalSince1970), .text(fileID.uuidString)])
    }

    public func candidates(filename: String, excludingID: UUID?, olderPendingOnly: Bool = false) async throws -> [MatchCandidate] {
        try await perform {
            var sql = "SELECT id, state, metadata_json, success_id, success_metadata_json FROM file_record WHERE filename = ?"
            var bindings: [Binding] = [.text(filename)]
            if let excludingID { sql += " AND id != ?"; bindings.append(.text(excludingID.uuidString)) }
            if olderPendingOnly, let excludingID {
                sql += " AND (state != 'pending' OR created_order < (SELECT created_order FROM file_record WHERE id = ?))"
                bindings.append(.text(excludingID.uuidString))
            }
            sql += " AND (state IN ('pending', 'importing', 'imported') OR (state = 'skipped' AND success_id IS NOT NULL)) ORDER BY created_order"
            return try self.rows(sql, bindings).compactMap { row in
                let metadataJSON: String
                if try self.text(row[1]) == FileState.skipped.rawValue { metadataJSON = try self.text(row[4]) } else { metadataJSON = try self.text(row[2]) }
                return MatchCandidate(key: "file:\(try self.text(row[0]))", metadata: try self.decode(MediaMetadata.self, from: metadataJSON))
            }
        }
    }

    public func markSkipped(fileID: UUID, reason: SkipReason, candidates: [MatchCandidate]) async throws {
        try await perform { try self.transaction { try self.markSkippedSync(fileID: fileID, reason: reason, candidates: candidates) } }
    }

    func markSkippedWithSnapshotValidity(
        fileID: UUID,
        reason: SkipReason,
        candidates: [MatchCandidate],
        validity: any PhotosCandidateValidity
    ) async throws -> SnapshotCommitResult {
        try await perform {
            try self.execute("BEGIN IMMEDIATE")
            do {
                guard try self.localCandidateEvidenceValid(candidates) else {
                    try self.execute("ROLLBACK")
                    return .staleSnapshot
                }
                try self.markSkippedSync(fileID: fileID, reason: reason, candidates: candidates)
                guard try validity.commitIfCurrent({ try self.execute("COMMIT") }) else {
                    try self.execute("ROLLBACK")
                    return .staleSnapshot
                }
                return .committed(fileID)
            } catch {
                try? self.execute("ROLLBACK")
                throw error
            }
        }
    }

    /// The caller must have physical proof of prevention before mutation (or must
    /// not have called create). Logical cancellation/timeout is not such proof.
    /// Restrict cleanup to the matching, uncheckpointed advanced attempt. Preserve
    /// retry_count; normal admission deferral is not a failed file.
    /// Call only with explicit proof that the physical mutation was prevented before submission.
    func deferUnsubmittedAttempt(fileID: UUID, attemptID: UUID, nextRetry: Date) async throws {
        try await perform { try self.transaction {
            try self.requireChange("""
                UPDATE file_record SET state='pending',attempt_id=NULL,placeholder_id=NULL,submitted_at=NULL,
                    definitely_not_committed=1,next_retry_at=?,last_error=NULL
                WHERE id=? AND state='importing' AND attempt_id=? AND success_id IS NULL
                    AND placeholder_id IS NULL AND live_photo_operation_id IS NULL
                """, [.double(nextRetry.timeIntervalSince1970), .text(fileID.uuidString), .text(attemptID.uuidString)])
            try self.bumpLocalRevision()
        } }
    }

    func deferAdvancedAttempt(fileID: UUID, attemptID: UUID, nextRetry: Date) async throws {
        try await perform { try self.transaction {
            try self.requireChange("""
                UPDATE file_record SET state = 'pending', attempt_id = NULL, placeholder_id = NULL,
                    submitted_at = NULL, definitely_not_committed = 1, next_retry_at = ?
                WHERE id = ? AND state = 'importing' AND attempt_id = ? AND success_id IS NULL
                    AND placeholder_id IS NULL AND last_error IS NULL
                    AND EXISTS (SELECT 1 FROM advanced_match_evidence e
                                WHERE e.file_id = file_record.id AND e.action = 'importFile')
                """, [.double(nextRetry.timeIntervalSince1970), .text(fileID.uuidString), .text(attemptID.uuidString)])
            try self.execute("DELETE FROM file_fingerprint WHERE file_id = ? AND purpose = 'attempt' AND attempt_id = ?",
                             [.text(fileID.uuidString), .text(attemptID.uuidString)])
            try self.bumpLocalRevision()
        } }
    }

    public func recordRetry(fileID: UUID, attemptID: UUID?, nextRetry: Date, error: String, definitelyNotCommitted: Bool) async throws {
        try await perform { try self.transaction {
            let sql: String
            var bindings: [Binding] = [.double(nextRetry.timeIntervalSince1970), .text(error), .int64(definitelyNotCommitted ? 1 : 0), .text(fileID.uuidString)]
            if let attemptID {
                if definitelyNotCommitted {
                    sql = "UPDATE file_record SET state = 'pending', attempt_id = NULL, placeholder_id = NULL, retry_count = retry_count + 1, next_retry_at = ?, last_error = ?, definitely_not_committed = ? WHERE id = ? AND state = 'importing' AND attempt_id = ?"
                } else {
                    sql = "UPDATE file_record SET retry_count = retry_count + 1, next_retry_at = ?, last_error = ?, definitely_not_committed = ? WHERE id = ? AND state = 'importing' AND attempt_id = ?"
                }
                bindings.append(.text(attemptID.uuidString))
            } else {
                sql = "UPDATE file_record SET retry_count = retry_count + 1, next_retry_at = ?, last_error = ?, definitely_not_committed = ? WHERE id = ? AND state = 'pending'"
            }
            try self.requireChange(sql, bindings)
            if definitelyNotCommitted, let attemptID {
                try self.execute("DELETE FROM file_fingerprint WHERE file_id = ? AND purpose = 'attempt' AND attempt_id = ?", [.text(fileID.uuidString), .text(attemptID.uuidString)])
            }
            try self.bumpLocalRevision()
        } }
    }

    public func beginScan(sourceID: UUID, now: Date) async throws -> UUID {
        try await perform {
            let id = UUID()
            try self.requireChange("INSERT INTO scan_run (id, source_id, started_at) VALUES (?, ?, ?)", [.text(id.uuidString), .text(sourceID.uuidString), .double(now.timeIntervalSince1970)])
            return id
        }
    }

    public func recordScanFailure(runID: UUID, error: String) async throws {
        try await perform {
            try self.requireChange("UPDATE scan_run SET complete = 0, failed = failed + 1, last_error = ? WHERE id = ?", [.text(error), .text(runID.uuidString)])
        }
    }

    func latestScanFailureCount(sourceID: UUID) async throws -> Int? {
        try await perform {
            guard let row = try self.one("SELECT failed FROM scan_run WHERE source_id = ? ORDER BY started_at DESC LIMIT 1", [.text(sourceID.uuidString)]) else { return nil }
            return Int(try self.int64(row[0]))
        }
    }

    public func finishScan(runID: UUID, now: Date, complete: Bool, checked: Int, failed: Int, error: String?) async throws {
        try await perform {
            try self.requireChange("UPDATE scan_run SET ended_at = ?, complete = CASE WHEN failed > 0 THEN 0 ELSE ? END, checked = ?, failed = failed + ?, last_error = COALESCE(last_error, ?) WHERE id = ?", [.double(now.timeIntervalSince1970), .int64(complete ? 1 : 0), .int64(Int64(checked)), .int64(Int64(failed)), error.map(Binding.text) ?? .null, .text(runID.uuidString)])
        }
    }

    private func registerSourceSync(url: URL) throws -> UUID {
        let normalized = url
        let path = normalized.path
        let existing = try rows("SELECT id, path, enabled, removed FROM source", []).map {
            (id: try uuid($0[0]), url: URL(fileURLWithPath: try text($0[1])), enabled: try int($0[2]) != 0, removed: try int($0[3]) != 0)
        }

        // Tombstoned sources no longer reserve their paths. Active source conflicts must
        // still be rejected before an exact-path tombstone can be restored.
        for source in existing where !source.removed && normalized.path != source.url.path && SourceRegistry.conflicts(normalized, source.url) {
            throw SourceRegistryError.overlappingSource(source.url)
        }
        if let source = existing.first(where: { $0.url.path == path }) {
            if !source.enabled || source.removed {
                try requireChange("UPDATE source SET enabled = 1, removed = 0 WHERE id = ?", [.text(source.id.uuidString)])
                try resetLegacyRechecks()
                try bumpLocalRevision()
            }
            return source.id
        }
        let id = UUID()
        try requireChange("INSERT INTO source (id, path, enabled, removed) VALUES (?, ?, 1, 0)", [.text(id.uuidString), .text(path)])
        try resetLegacyRechecks()
        try bumpLocalRevision()
        return id
    }

    private func markSkippedSync(fileID: UUID, reason: SkipReason, candidates: [MatchCandidate]) throws {
        try requireChange("""
            UPDATE file_record SET state = 'skipped', skip_reason = ?, attempt_id = NULL, placeholder_id = NULL
            WHERE id = ? AND (
                (state = 'pending' AND success_id IS NULL AND (submitted_at IS NULL OR definitely_not_committed = 1)) OR
                (? = 'sourceChanged' AND success_id IS NOT NULL AND state IN ('imported', 'skipped')))
            """, [.text(reason.rawValue), .text(fileID.uuidString), .text(reason.rawValue)])
        try reopenDependents(candidateID: fileID)
        try execute("DELETE FROM dedup_dependency WHERE file_id = ?", [.text(fileID.uuidString)])
        try bumpLocalRevision()
        try execute("DELETE FROM match_evidence WHERE file_id = ?", [.text(fileID.uuidString)])
        for candidate in candidates {
            try execute("INSERT INTO match_evidence (file_id, candidate_key, candidate_json, rule_version, compared_at) VALUES (?, ?, ?, ?, ?)", [.text(fileID.uuidString), .text(candidate.key), .text(try encode(candidate)), .int64(Int64(ruleVersion)), .double(Date().timeIntervalSince1970)])
        }
    }

    /// Photos validity covers the system library generation. Local candidate removal and
    /// source-change transitions are independently serialized by this SQLite transaction.
    private func localCandidateEvidenceValid(_ candidates: [MatchCandidate]) throws -> Bool {
        for candidate in candidates where candidate.key.hasPrefix("file:") {
            guard let id = UUID(uuidString: String(candidate.key.dropFirst("file:".count))),
                  let row = try one("SELECT state, metadata_json, success_id, success_metadata_json FROM file_record WHERE id = ?",
                                    [.text(id.uuidString)]) else { return false }
            let state = try fileState(row[0])
            let metadataJSON: String
            switch state {
            case .pending, .importing, .imported:
                metadataJSON = try text(row[1])
            case .skipped:
                guard optionalText(row[2]) != nil else { return false }
                metadataJSON = try text(row[3])
            }
            guard try decode(MediaMetadata.self, from: metadataJSON) == candidate.metadata else {
                return false
            }
        }
        return true
    }

    /// Synchronous producer checkpoint, invoked outside PhotoKit/state locks. Each
    /// transaction is bounded; a process-local generation is always paired with runID.
    func recordPhotosChanges(context: LibraryContext, runID: UUID, generation: Int,
                             changed: [String], deleted: [String], content: Set<String>, batchSize: Int,
                             livePhotoUnchanged: Set<String> = []) throws {
        for (ids, removed) in [(changed, false), (deleted, true)] {
            for start in stride(from: 0, to: ids.count, by: max(1, batchSize)) {
                let batch = ids[start..<min(ids.count, start + max(1, batchSize))]
                try queue.sync {
                    try self.transaction {
                        // A catalog change is not necessarily a change to the original
                        // resources. Only explicit per-asset proof preserves LP reads;
                        // unknown/history changes retain the conservative default.
                        let invalidated = batch.filter { !livePhotoUnchanged.contains($0) || content.contains($0) }
                        try self.applyLivePhotoChangesSync(context: context, changed: removed ? [] : invalidated, deleted: removed ? Array(batch) : [])
                        for id in batch {
                            try self.execute("""
                                INSERT INTO photos_content_change(context_id, context_epoch, run_id, asset_id, generation, removed, content_changed)
                                VALUES (?, ?, ?, ?, ?, ?, ?)
                                ON CONFLICT(context_id, context_epoch, run_id, asset_id) DO UPDATE SET
                                generation = excluded.generation, removed = excluded.removed,
                                content_changed = MAX(photos_content_change.content_changed, excluded.content_changed, photos_content_change.removed)
                                """, [.text(context.id.uuidString), .int64(context.epoch), .text(runID.uuidString), .text(id),
                                      .int64(Int64(generation)), .int64(removed ? 1 : 0), .int64(content.contains(id) || removed ? 1 : 0)])
                        }
                    }
                }
            }
        }
    }

    func photosContentChanges(context: LibraryContext, assetIDs: Set<String>) throws -> [String] {
        try queue.sync {
            try assetIDs.sorted().filter { id in
                try self.one("SELECT 1 FROM photos_content_change WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND content_changed = 1 LIMIT 1",
                    [.text(context.id.uuidString), .int64(context.epoch), .text(id)]) != nil
            }
        }
    }

    func photosInputUnchanged(context: LibraryContext, assetIDs: Set<String>) throws -> [String] {
        try queue.sync {
            try assetIDs.sorted().filter { id in
                let row = try self.one("SELECT MIN(content_changed), MAX(content_changed) FROM photos_content_change WHERE context_id = ? AND context_epoch = ? AND asset_id = ?",
                    [.text(context.id.uuidString), .int64(context.epoch), .text(id)])
                return row.map { self.optionalInteger($0[0]) == 0 && self.optionalInteger($0[1]) == 0 } ?? false
            }
        }
    }

    func photosCatalogChanges(context: LibraryContext, runID: UUID, afterGeneration: Int, throughGeneration: Int,
                              afterAssetID: String?, limit: Int) throws -> PhotosCatalogChangeBatch {
        try queue.sync {
            let rows = try self.rows("""
                SELECT asset_id, removed FROM photos_content_change
                WHERE context_id = ? AND context_epoch = ? AND run_id = ? AND generation > ? AND generation <= ?
                AND asset_id > ? ORDER BY asset_id LIMIT ?
                """, [.text(context.id.uuidString), .int64(context.epoch), .text(runID.uuidString), .int64(Int64(afterGeneration)),
                      .int64(Int64(throughGeneration)), .text(afterAssetID ?? ""), .int64(Int64(limit))])
            var changed: [String] = [], deleted: [String] = []
            for row in rows {
                if try self.int64(row[1]) != 0 { deleted.append(try self.text(row[0])) }
                else { changed.append(try self.text(row[0])) }
            }
            return PhotosCatalogChangeBatch(changedAssetIDs: changed, deletedAssetIDs: deleted,
                nextAssetID: rows.count == limit ? try rows.last.map { try self.text($0[0]) } : nil)
        }
    }

    func acknowledgePhotosChanges(context: LibraryContext, runID: UUID, throughGeneration: Int) throws {
        try queue.sync {
            try self.execute("DELETE FROM photos_content_change WHERE context_id = ? AND context_epoch = ? AND (run_id <> ? OR generation <= ?)",
                [.text(context.id.uuidString), .int64(context.epoch), .text(runID.uuidString), .int64(Int64(throughGeneration))])
        }
    }

    func advanceReconciliationEndpoint(generation: Int64, photosGeneration: Int) async throws {
        try await perform {
            guard let state = try self.indexStateRow(), try self.int64(state[2]) == generation,
                  try self.int64(state[7]) == 0 else { throw PhotoKitGatewayError.libraryChanged }
            try self.execute("UPDATE dedup_index_state SET photos_generation = ? WHERE id = 1", [.int64(Int64(photosGeneration))])
        }
    }

    /// Starts a fresh complete-inventory barrier. Existing facts remain intact until a full finish.
    public func beginIndexReconciliation(context: LibraryContext, photosGeneration: Int, fingerprintVersion: String) async throws -> Int64 {
        guard !fingerprintVersion.isEmpty else { throw AdvancedDedupError.invalidConfiguration }
        return try await perform {
            try self.transaction {
                let previous = try self.indexStateRow()
                let generation = try previous.map { try self.int64($0[2]) + 1 } ?? 1
                try self.execute("""
                    INSERT INTO dedup_index_state (id, context_id, context_epoch, generation, fingerprint_version, photos_generation)
                    VALUES (1, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET context_id = excluded.context_id, context_epoch = excluded.context_epoch,
                    generation = excluded.generation, fingerprint_version = excluded.fingerprint_version,
                    photos_generation = excluded.photos_generation, published_generation = NULL,
                    resume_checkpoint = CASE WHEN context_id = excluded.context_id AND context_epoch = excluded.context_epoch THEN resume_checkpoint ELSE NULL END,
                    reconciliation_complete = 0, reconcile_cursor = NULL
                    """, [.text(context.id.uuidString), .int64(context.epoch), .int64(generation), .text(fingerprintVersion), .int64(Int64(photosGeneration))])
                return generation
            }
        }
    }

    @discardableResult
    public func upsertRepresentations(_ descriptors: [RepresentationDescriptor], generation: Int64) async throws -> IndexMutationCounts {
        try await perform {
            try self.transaction {
                guard let state = try self.indexStateRow(), try self.int64(state[2]) == generation,
                      try self.int64(state[7]) == 0 else { throw SyncStoreError.invalidTransition("Stale or finished reconciliation.") }
                return try self.upsertRepresentationsSync(descriptors, state: state, generation: generation)
            }
        }
    }

    private func upsertRepresentationsSync(_ descriptors: [RepresentationDescriptor], state: [Value], generation: Int64) throws -> IndexMutationCounts {
        let context = try self.libraryContext(state)
        let version = try self.text(state[4])
        var counts = IndexMutationCounts()
        for descriptor in descriptors {
            guard descriptor.context == context, !descriptor.key.assetID.isEmpty, !descriptor.revision.isEmpty else {
                throw AdvancedDedupError.invalidConfiguration
            }
            let key = self.representationBindings(descriptor)
            let previous = try self.one("SELECT revision, width, height, equivalent_to_original, revision_is_reliable, fingerprint_version, state, seen_generation, tombstoned, observed_modification_date, successful_modification_date, successful_vector_version, vector IS NOT NULL FROM photos_representation WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", key)
            // Date facts use Date's native reference epoch to preserve every bit
            // of its stored precision instead of rounding through a second epoch.
            let observedDate = descriptor.modificationDate?.timeIntervalSinceReferenceDate
            let validDate = observedDate.flatMap { $0.isFinite ? $0 : nil }
            let sameMetadata = try previous.map { row in
                try self.text(row[0]) == descriptor.revision &&
                self.optionalInteger(row[1]) == descriptor.size.map { Int64($0.width) } &&
                self.optionalInteger(row[2]) == descriptor.size.map { Int64($0.height) } &&
                self.int64(row[3]) == (descriptor.equivalentToOriginal ? 1 : 0) &&
                self.int64(row[4]) == (descriptor.revisionIsReliable ? 1 : 0) && self.text(row[5]) == version
            } ?? false
            let previouslyRemoved = try previous.map { try self.int64($0[8]) != 0 } ?? false
            // Legacy ready rows may bootstrap only from their complete matching
            // revision/contract. Never manufacture a legacy digest/vector pair.
            let bootstrap = try previous.map { row in
                try !previouslyRemoved && validDate != nil && sameMetadata && descriptor.revisionIsReliable &&
                    self.text(row[6]) == "ready" && self.int64(row[12]) != 0 && self.optionalText(row[11]) == nil
            } ?? false
            let reusableDate = try previous.map { row in
                try validDate != nil && validDate == self.optionalDouble(row[10]) &&
                    self.optionalText(row[11]) == version && self.int64(row[12]) != 0
            } ?? false
            let reuseSuccess = reusableDate || bootstrap
            // Preserve an unchanged tombstoned slot until the complete membership
            // pass decides whether it is eligible again. Coalesced current slots
            // otherwise churn pending/tasks on every neutral inventory.
            if previouslyRemoved, sameMetadata, let previous,
               try self.optionalDouble(previous[9]) == validDate { continue }
            // Pending target equality only preserves existing work/backoff. Two
            // unknown dates are never evidence for reusing a successful vector.
            var sameTarget = try previous.map { row in
                try !previouslyRemoved && self.text(row[6]) != "ready" && self.optionalDouble(row[9]) == validDate &&
                    (sameMetadata || (validDate != nil && self.text(row[5]) == version))
            } ?? false
            if sameTarget, !sameMetadata,
               try self.one("SELECT 1 FROM fingerprint_task WHERE context_id=? AND context_epoch=? AND asset_id=? AND kind=? AND failure_kind='photos_read' AND next_retry_at=?", key + [.double(Date.distantFuture.timeIntervalSince1970)]) != nil {
                // A deterministic hold belongs to the exact resource/decoder input,
                // unlike an ordinary transient retry retained by a stable observed date.
                sameTarget = false
            }
            let unchanged = reuseSuccess || sameTarget
            if previous == nil || previouslyRemoved { counts.added += 1 }
            else if !unchanged { counts.changed += 1 }
            if reuseSuccess {
                // An unchanged metadata pass must not rewrite accepted rows or
                // churn the readiness index. Membership is reconciled by keys.
                if let previous, sameMetadata, !bootstrap,
                   try self.text(previous[6]) == "ready",
                   try self.optionalDouble(previous[9]) == validDate { continue }
                try self.execute("DELETE FROM fingerprint_task WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", key)
                try self.execute("""
                    UPDATE photos_representation SET revision = ?, width = ?, height = ?, equivalent_to_original = ?,
                    revision_is_reliable = ?, seen_generation = ?, state = 'ready', fingerprint_version = ?,
                    observed_modification_date = ?, successful_modification_date = ?, successful_vector_version = ?
                    WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?
                    """, [.text(descriptor.revision), descriptor.size.map { .int64(Int64($0.width)) } ?? .null,
                            descriptor.size.map { .int64(Int64($0.height)) } ?? .null,
                            .int64(descriptor.equivalentToOriginal ? 1 : 0), .int64(descriptor.revisionIsReliable ? 1 : 0),
                            .int64(generation), .text(version), validDate.map(Binding.double) ?? .null,
                            validDate.map(Binding.double) ?? .null, .text(version)] + key)
            } else if !sameTarget {
                try self.execute("DELETE FROM fingerprint_task WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", key)
                try self.execute("""
                    INSERT INTO photos_representation (context_id, context_epoch, asset_id, kind, revision, width, height,
                    equivalent_to_original, revision_is_reliable, seen_generation, state, fingerprint_version, observed_modification_date)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)
                    ON CONFLICT(context_id, context_epoch, asset_id, kind) DO UPDATE SET revision = excluded.revision,
                    width = excluded.width, height = excluded.height, equivalent_to_original = excluded.equivalent_to_original,
                    revision_is_reliable = excluded.revision_is_reliable, seen_generation = excluded.seen_generation,
                    state = 'pending', fingerprint_version = excluded.fingerprint_version,
                    observed_modification_date = excluded.observed_modification_date, tombstoned = 0
                    """, key + [.text(descriptor.revision), descriptor.size.map { .int64(Int64($0.width)) } ?? .null,
                                 descriptor.size.map { .int64(Int64($0.height)) } ?? .null,
                                 .int64(descriptor.equivalentToOriginal ? 1 : 0), .int64(descriptor.revisionIsReliable ? 1 : 0),
                                 .int64(generation), .text(version), validDate.map(Binding.double) ?? .null])
            } else if !sameMetadata || !descriptor.revisionIsReliable {
                // A stable observed date retains retry facts, while a changed
                // read locator gets a new issuance and fences old completions.
                try self.execute("""
                    UPDATE photos_representation SET revision = ?, width = ?, height = ?, equivalent_to_original = ?,
                    revision_is_reliable = ?, seen_generation = ?
                    WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?
                    """, [.text(descriptor.revision), descriptor.size.map { .int64(Int64($0.width)) } ?? .null,
                            descriptor.size.map { .int64(Int64($0.height)) } ?? .null,
                            .int64(descriptor.equivalentToOriginal ? 1 : 0), .int64(descriptor.revisionIsReliable ? 1 : 0),
                            .int64(generation)] + key)
                try self.execute("UPDATE fingerprint_task SET revision = ?, generation = ?, issuance_revision = NULL WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", [.text(descriptor.revision), .int64(generation)] + key)
            }
            // Unchanged tasks retain issuance identity and retry facts across publications.
            let ready = try self.one("SELECT state FROM photos_representation WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", key)
            if !unchanged || !previouslyRemoved, try ready.map({ try self.text($0[0]) }) != "ready" {
                try self.execute("""
                    INSERT INTO fingerprint_task (context_id, context_epoch, asset_id, kind, revision, fingerprint_version, generation)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(context_id, context_epoch, asset_id, kind, revision, fingerprint_version)
                    DO NOTHING
                    """, key + [.text(descriptor.revision), .text(version), .int64(generation)])
            }
        }
        return counts
    }


    @discardableResult
    public func finishIndexReconciliation(generation: Int64, seenKeys: Set<RepresentationKey>,
                                          checkpoint: LibraryResumeCheckpoint? = nil,
                                          excludedAssetIDs: Set<String> = []) async throws -> IndexMutationCounts? {
        try await perform {
            try self.transaction {
                guard let state = try self.indexStateRow(), try self.int64(state[2]) == generation,
                      try self.int64(state[7]) == 0 else { return nil }
                let context = try self.libraryContext(state)
                try self.validateCheckpoint(checkpoint, context: context, photosGeneration: Int(self.int64(state[5])), allowEarlierCapture: true)
                let counts = try self.finishRepresentationKeys(seenKeys, context: context, generation: generation, assetIDs: nil)
                try self.updateExclusions(excludedAssetIDs, context: context, affectedIDs: nil)
                try self.finishInventory(checkpoint: checkpoint, context: context)
                return counts
            }
        }
    }

    /// Compatibility entry point for one complete interval that fits one page.
    public func applyIndexDelta(_ delta: PhotosIndexDelta, page: RepresentationPage,
                                fingerprintVersion: String, checkpoint: LibraryResumeCheckpoint?) async throws -> Int64 {
        try await applyIndexDeltaBatch(.init(interval: delta, offset: 0, count: delta.changedAssetIDs.count + delta.deletedAssetIDs.count),
            page: page, fingerprintVersion: fingerprintVersion, checkpoint: checkpoint)
    }

    public func applyIndexDeltaBatch(_ batch: PhotosIndexDeltaBatch, page: RepresentationPage,
                                     fingerprintVersion: String, checkpoint: LibraryResumeCheckpoint?,
                                     reinsertedAssetIDs: Set<String> = [],
                                     diagnostic: IndexDiagnosticOperation? = nil) async throws -> Int64 {
        guard batch.valid else { throw PhotoKitGatewayError.libraryChanged }
        let delta = batch.request, firstBatch = batch.first, lastBatch = batch.last
        let identity = try JSONSerialization.data(withJSONObject: [batch.interval.context.id.uuidString,
            String(batch.interval.context.epoch), String(delta.fromGeneration), String(delta.toGeneration),
            batch.interval.changedAssetIDs, batch.interval.deletedAssetIDs])
        let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let result: (generation: Int64, invalidated: Int, mutations: IndexMutationCounts, finished: IndexMutationCounts) = try await perform {
            try self.transaction {
                guard delta.isValid, let state = try self.indexStateRow(),
                      try self.libraryContext(state) == delta.context, try self.int64(state[7]) == (firstBatch ? 1 : 0),
                      try self.int64(state[5]) == Int64(firstBatch ? delta.fromGeneration : delta.toGeneration),
                      try self.text(state[4]) == fingerprintVersion,
                      page.context == delta.context, page.generation == delta.toGeneration,
                      page.nextOffset == nil, !page.invalidateAllCachedRepresentations else {
                    throw PhotoKitGatewayError.libraryChanged
                }
                if !firstBatch {
                    guard let cursor = try self.one("SELECT reconcile_cursor FROM dedup_index_state WHERE id=1", []),
                          try self.text(cursor[0]) == "delta:\(digest):\(batch.offset)" else { throw PhotoKitGatewayError.libraryChanged }
                }
                let changed = Set(delta.changedAssetIDs)
                let facts = page.descriptors + page.exclusions.map(\.descriptor)
                guard facts.allSatisfy({ $0.context == delta.context && changed.contains($0.key.assetID) }),
                      Set(facts.map { $0.key.assetID }) == changed,
                      Set(facts.map(\.key)).count == facts.count,
                      reinsertedAssetIDs.isSubset(of: changed),
                      Set(page.invalidatedAssetIDs).isSubset(of: changed) else { throw PhotoKitGatewayError.libraryChanged }
                let retainedCheckpoint = try self.libraryResumeCheckpointSync()
                guard checkpoint == nil || checkpoint == retainedCheckpoint,
                      retainedCheckpoint == nil || retainedCheckpoint?.context == delta.context else { throw PhotoKitGatewayError.libraryChanged }
                let generation = try self.int64(state[2]) + (firstBatch ? 1 : 0)
                try self.execute("UPDATE dedup_index_state SET generation = ?, photos_generation = ?, published_generation = NULL, reconciliation_complete = 0 WHERE id = 1",
                                 [.int64(generation), .int64(Int64(delta.toGeneration))])
                // A delete/reinsert interval replaces pending work's identity,
                // even if the final date/read locator is identical. It is not
                // evidence against any already accepted successful analysis.
                for id in reinsertedAssetIDs {
                    try self.execute("UPDATE photos_representation SET seen_generation = ? WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND state <> 'ready' AND tombstoned = 0",
                        [.int64(generation), .text(delta.context.id.uuidString), .int64(delta.context.epoch), .text(id)])
                    try self.execute("UPDATE fingerprint_task SET generation = ?, issuance_revision = NULL WHERE context_id = ? AND context_epoch = ? AND asset_id = ?",
                        [.int64(generation), .text(delta.context.id.uuidString), .int64(delta.context.epoch), .text(id)])
                }
                let mutations = try self.upsertRepresentationsSync(page.descriptors, state: state, generation: generation)
                let affected = changed.union(delta.deletedAssetIDs)
                let seen = Set(page.descriptors.map(\.key))
                let finished = try self.finishRepresentationKeys(seen, context: delta.context, generation: generation, assetIDs: affected)
                let excluded = Set(page.exclusions.filter { $0.reason != .nonImage }.map { $0.descriptor.key.assetID }).subtracting(seen.map(\.assetID))
                try self.updateExclusions(excluded, context: delta.context, affectedIDs: affected)
                if lastBatch { try self.finishInventory(checkpoint: retainedCheckpoint, context: delta.context) }
                else { try self.execute("UPDATE dedup_index_state SET reconcile_cursor = ? WHERE id=1", [.text("delta:\(digest):\(batch.offset + batch.count)")]) }
                self.publishedIndexToken = nil
                return (generation, 0, mutations, finished)
            }
        }
        // Diagnostic classification only, after the unchanged transaction. Zero
        // invalidation alone does not prove continuity or unchanged membership.
        let neutral = delta.deletedAssetIDs.isEmpty && page.invalidatedAssetIDs.isEmpty && page.exclusions.isEmpty &&
            Set(delta.changedAssetIDs).isSubset(of: Set(page.inputUnchangedAssetIDs)) &&
            result.invalidated == 0 && result.mutations.added == 0 && result.mutations.changed == 0 && result.finished.deleted == 0
        if neutral {
            diagnostic?.recordNeutralTransfer(assets: delta.changedAssetIDs.count, generation: result.generation,
                fromGeneration: delta.fromGeneration, throughGeneration: delta.toGeneration)
        } else {
            diagnostic?.record(["phase": "index-invalidation", "source": "live", "reason": "inventory-update", "readyToPending": String(result.invalidated),
                "added": String(result.mutations.added), "changed": String(result.mutations.changed), "deleted": String(result.finished.deleted),
                "deletedAssets": String(delta.deletedAssetIDs.count), "generation": String(result.generation), "fromGeneration": String(delta.fromGeneration), "throughGeneration": String(delta.toGeneration)])
            diagnostic?.finish()
        }
        return result.generation
    }

    private func validateCheckpoint(_ checkpoint: LibraryResumeCheckpoint?, context: LibraryContext, photosGeneration: Int,
                                    allowEarlierCapture: Bool = false) throws {
        if let checkpoint {
            guard checkpoint.context == context, let captured = checkpoint.photosGeneration, captured >= 0,
                  allowEarlierCapture ? captured <= photosGeneration : captured == photosGeneration else {
                throw PhotoKitGatewayError.libraryChanged
            }
        }
    }

    /// Only lightweight keys/flags are visited, never vectors or a second durable inventory.
    private func finishRepresentationKeys(_ seen: Set<RepresentationKey>, context: LibraryContext,
                                          generation: Int64, assetIDs: Set<String>?) throws -> IndexMutationCounts {
        let base: [Binding] = [.text(context.id.uuidString), .int64(context.epoch)]
        let sql = """
            SELECT asset_id, kind, equivalent_to_original, tombstoned,
            COALESCE(observed_modification_date IS NOT NULL AND observed_modification_date = successful_modification_date
                AND successful_vector_version = fingerprint_version AND vector IS NOT NULL, 0)
            FROM photos_representation WHERE context_id = ? AND context_epoch = ?
            """
        let records = try assetIDs.map { ids in
            try ids.sorted().flatMap { try rows(sql + " AND asset_id = ?", base + [.text($0)]) }
        } ?? rows(sql, base)
        var counts = IndexMutationCounts()
        for row in records {
            guard let kind = RepresentationKind(rawValue: try text(row[1])) else { throw AdvancedDedupError.invalidConfiguration }
            let key = RepresentationKey(assetID: try text(row[0]), kind: kind)
            let coalesced = try kind == .current && int64(row[2]) != 0 && seen.contains(.init(assetID: key.assetID, kind: .original))
            let keep = seen.contains(key) && !coalesced
            let tombstoned = try int64(row[3]) != 0
            let bindings = base + [.text(key.assetID), .text(kind.rawValue)]
            if keep && tombstoned {
                // Only complete membership reactivates a removed/coalesced slot.
                // Its retained success is still reusable under the same date/contract.
                let reuseSuccess = try int64(row[4]) != 0
                try execute("UPDATE photos_representation SET tombstoned = 0, state = ?, seen_generation = ? WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", [.text(reuseSuccess ? "ready" : "pending"), .int64(generation)] + bindings)
                if !reuseSuccess {
                    try execute("INSERT OR REPLACE INTO fingerprint_task (context_id, context_epoch, asset_id, kind, revision, fingerprint_version, generation) SELECT context_id, context_epoch, asset_id, kind, revision, fingerprint_version, seen_generation FROM photos_representation WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", bindings)
                }
            } else if !keep && !tombstoned {
                try execute("UPDATE photos_representation SET tombstoned = 1 WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", bindings)
                try execute("DELETE FROM fingerprint_task WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", bindings)
                counts.deleted += 1
            }
        }
        return counts
    }

    private func updateExclusions(_ excluded: Set<String>, context: LibraryContext, affectedIDs: Set<String>?) throws {
        let base: [Binding] = [.text(context.id.uuidString), .int64(context.epoch)]
        let sql = "SELECT asset_id FROM photos_index_exclusion WHERE context_id = ? AND context_epoch = ?"
        let existing = try Set((affectedIDs.map { ids in
            try ids.sorted().flatMap { try rows(sql + " AND asset_id = ?", base + [.text($0)]) }
        } ?? rows(sql, base)).map { try text($0[0]) })
        for id in existing.subtracting(excluded) {
            try execute("DELETE FROM photos_index_exclusion WHERE context_id = ? AND context_epoch = ? AND asset_id = ?", base + [.text(id)])
        }
        for id in excluded.subtracting(existing) {
            try execute("INSERT INTO photos_index_exclusion (context_id, context_epoch, asset_id) VALUES (?, ?, ?)", base + [.text(id)])
        }
    }

    private func finishInventory(checkpoint: LibraryResumeCheckpoint?, context: LibraryContext) throws {
        let data = try checkpoint.map { try JSONEncoder().encode($0) }
        try execute("UPDATE dedup_index_state SET reconciliation_complete = 1, reconcile_cursor = NULL, resume_checkpoint = ?, excluded_assets = (SELECT COUNT(*) FROM photos_index_exclusion WHERE context_id = ? AND context_epoch = ?) WHERE id = 1",
                    [data.map(Binding.blob) ?? .null, .text(context.id.uuidString), .int64(context.epoch)])
    }

    /// Durable history cursor belongs to a completed inventory, not vector readiness.
    public func libraryResumeCheckpoint() async throws -> LibraryResumeCheckpoint? {
        try await perform { try self.libraryResumeCheckpointSync() }
    }

    /// Same-device PhotoKit object namespace, independent of history cursor health.
    /// This application-generated context is not a system photo-library UUID.
    public func inventoryContext() async throws -> LibraryContext? {
        try await perform { try self.indexStateRow().map { try self.libraryContext($0) } }
    }

    private func libraryResumeCheckpointSync() throws -> LibraryResumeCheckpoint? {
        guard let row = try one("SELECT resume_checkpoint, context_id, context_epoch FROM dedup_index_state WHERE id = 1", []),
              case .blob(let data) = row[0],
              let checkpoint = try? JSONDecoder().decode(LibraryResumeCheckpoint.self, from: data),
              checkpoint.context.id.uuidString == (try text(row[1])),
              checkpoint.context.epoch == (try int64(row[2])) else { return nil }
        return checkpoint
    }

    /// Revalidates only known classified failures after catalog reconciliation.
    /// Each input is a primary-key lookup; no inventory/vector materialization or
    /// retry-deadline filtering is involved. Reconciliation can retain a failed
    /// descriptor while moving it to a newer generation, so use current facts.
    func currentFailedRepresentations(_ descriptors: [RepresentationDescriptor],
                                      fingerprintVersion: String) async throws -> [RepresentationDescriptor] {
        guard !descriptors.isEmpty else { return [] }
        return try await perform {
            guard let state = try self.indexStateRow(), try self.text(state[4]) == fingerprintVersion else { return [] }
            let context = try self.libraryContext(state)
            return try descriptors.filter { descriptor in
                guard descriptor.context == context else { return false }
                guard let row = try self.one("""
                    SELECT revision, width, height, equivalent_to_original, revision_is_reliable, observed_modification_date
                    FROM photos_representation WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?
                    AND fingerprint_version = ? AND tombstoned = 0 AND state = 'failed'
                    """, self.representationBindings(descriptor) + [.text(fingerprintVersion)]) else { return false }
                return try self.text(row[0]) == descriptor.revision &&
                    self.pixelSize(width: row[1], height: row[2]) == descriptor.size &&
                    (self.int64(row[3]) != 0) == descriptor.equivalentToOriginal &&
                    (self.int64(row[4]) != 0) == descriptor.revisionIsReliable &&
                    self.optionalDouble(row[5]) == descriptor.modificationDate?.timeIntervalSinceReferenceDate
            }
        }
    }

    /// Read-only counters from the same durable facts used by publication.
    public func indexProgress() async throws -> IndexProgress {
        try await perform {
            guard let state = try self.indexStateRow() else {
                return IndexProgress(state: .preparing, totalsKnown: false, totalAssets: 0, readyAssets: 0,
                                     totalRepresentations: 0, readyRepresentations: 0, excludedAssets: 0, issue: nil)
            }
            let context = try self.libraryContext(state)
            let bindings: [Binding] = [.text(context.id.uuidString), .int64(context.epoch)]
            let row = try self.one("""
                SELECT COUNT(*), COALESCE(SUM(state = 'ready' AND (vector IS NULL) = 0), 0), COALESCE(SUM(state = 'failed'), 0), COUNT(DISTINCT asset_id)
                FROM photos_representation WHERE context_id = ? AND context_epoch = ? AND tombstoned = 0
                """, bindings)!
            let ready = try self.one("""
                SELECT COUNT(*) FROM (SELECT asset_id FROM photos_representation WHERE context_id = ? AND context_epoch = ?
                AND tombstoned = 0 GROUP BY asset_id HAVING MIN(state = 'ready' AND (vector IS NULL) = 0) = 1)
                """, bindings)!
            let readErrors = try self.one("""
                SELECT COUNT(*), COUNT(DISTINCT CASE WHEN t.next_retry_at = ? THEN r.asset_id END)
                FROM photos_representation r, fingerprint_task t WHERE r.context_id = ? AND r.context_epoch = ?
                AND r.tombstoned = 0 AND r.state = 'failed'
                AND
                """ + " " + Self.readFailureMatch, [.double(Date.distantFuture.timeIntervalSince1970)] + bindings + [.int64(try self.int64(state[2])), .text(try self.text(state[4]))])!
            let readErrorCount = Int(try self.int64(readErrors[0]))
            let blockingFailures = Int(try self.int64(row[2])) - readErrorCount
            let excludedRow = try self.one("SELECT excluded_assets FROM dedup_index_state WHERE id = 1", [])!
            let excluded = Int(try self.int64(excludedRow[0]))
            return IndexProgress(state: blockingFailures > 0 ? .waiting : .updating,
                totalsKnown: try self.int64(state[7]) != 0, totalAssets: Int(try self.int64(row[3])) + excluded,
                readyAssets: Int(try self.int64(ready[0])), totalRepresentations: Int(try self.int64(row[0])),
                readyRepresentations: Int(try self.int64(row[1])), readErrorRepresentations: readErrorCount, excludedAssets: excluded,
                issue: blockingFailures > 0 ? "部分图库图像暂时无法读取，正在等待重试。" : nil,
                requiresAttentionAssets: Int(try self.int64(readErrors[1])))
        }
    }

    /// Lightweight admission metadata: never materialize all vector BLOBs just
    /// to render progress, publish readiness or validate a token.
    public func indexReadiness() async throws -> (token: IndexToken, entryCount: Int)? {
        try await perform {
            try self.transaction {
                guard let state = try self.indexStateRow(), try self.indexFactsComplete(state) else { return nil }
                let token = try self.indexToken(state)
                let row = try self.one("SELECT COUNT(*) FROM photos_representation WHERE context_id = ? AND context_epoch = ? AND tombstoned = 0 AND state = 'ready'",
                    [.text(token.context.id.uuidString), .int64(token.context.epoch)])!
                return (token, Int(try self.int64(row[0])))
            }
        }
    }

    public func invalidateIndexPublication() async throws {
        try await perform {
            try self.execute("UPDATE dedup_index_state SET published_generation = NULL WHERE id = 1")
            self.publishedIndexToken = nil
        }
    }

    /// Polling does not claim work. One coordinator must deduplicate and retain
    /// its physical in-flight ownership until each consumer has actually finished.
    /// Cursor selection reads at most `limit` rows across suffix and wrap queries.
    public func nextRepresentationTasks(now: Date, limit: Int, after cursor: RepresentationKey? = nil) async throws -> [RepresentationTask] {
        guard limit > 0 else { return [] }
        return try await perform {
            guard let state = try self.indexStateRow() else { return [] }
            let context = try self.libraryContext(state), version = try self.text(state[4])
            func select(after: Bool, limit: Int) throws -> [[Value]] {
                let keyClause = cursor == nil ? "" : (after
                    ? " AND (r.asset_id > ? OR (r.asset_id = ? AND r.kind > ?))"
                    : " AND (r.asset_id < ? OR (r.asset_id = ? AND r.kind <= ?))")
                var bindings: [Binding] = [.text(context.id.uuidString), .int64(context.epoch), .text(version), .int64(try self.int64(state[2])), .double(now.timeIntervalSince1970), .double(Date.distantFuture.timeIntervalSince1970)]
                if let cursor { bindings += [.text(cursor.assetID), .text(cursor.assetID), .text(cursor.kind.rawValue)] }
                bindings.append(.int64(Int64(limit)))
                return try self.rows("""
                SELECT r.asset_id, r.kind, r.revision, r.width, r.height, r.equivalent_to_original, r.revision_is_reliable,
                t.retry_count, t.next_retry_at, t.generation, COALESCE(t.issuance_revision,t.revision), r.observed_modification_date FROM fingerprint_task t JOIN photos_representation r
                ON r.context_id = t.context_id AND r.context_epoch = t.context_epoch AND r.asset_id = t.asset_id AND r.kind = t.kind
                AND r.revision = t.revision AND r.fingerprint_version = t.fingerprint_version
                WHERE t.context_id = ? AND t.context_epoch = ? AND t.fingerprint_version = ?
                AND r.tombstoned = 0 AND r.seen_generation = t.generation AND t.generation > 0 AND t.generation <= ? AND r.state <> 'ready'
                AND (t.next_retry_at IS NULL OR t.next_retry_at <= ?)
                AND NOT (t.failure_kind IS 'photos_read' AND t.next_retry_at IS ?) \(keyClause) ORDER BY r.asset_id, r.kind LIMIT ?
                """, bindings)
            }
            var rows = try select(after: true, limit: limit)
            if cursor != nil && rows.count < limit { rows += try select(after: false, limit: limit - rows.count) }
            return try rows.map { row in
                guard let kind = RepresentationKind(rawValue: try self.text(row[1])) else { throw AdvancedDedupError.invalidConfiguration }
                let descriptor = RepresentationDescriptor(key: RepresentationKey(assetID: try self.text(row[0]), kind: kind),
                    context: context, revision: try self.text(row[2]), size: try self.pixelSize(width: row[3], height: row[4]),
                    equivalentToOriginal: try self.int64(row[5]) != 0, revisionIsReliable: try self.int64(row[6]) != 0,
                    modificationDate: self.optionalDouble(row[11]).map(Date.init(timeIntervalSinceReferenceDate:)))
                return RepresentationTask(descriptor: descriptor, retryCount: Int(try self.int64(row[7])),
                    nextRetryAt: self.optionalDouble(row[8]).map(Date.init(timeIntervalSince1970:)),
                    fingerprintVersion: version, indexGeneration: try self.int64(row[9]), issuanceRevision: try self.text(row[10]))
            }
        }
    }

    /// Only an explicit user retry rearms unchanged decoded-resource limits.
    /// Keep the v11 photos_read CHECK and candidate exclusion proof unchanged.
    @discardableResult
    public func retryIndexReadLimits(now: Date) async throws -> Int {
        try await perform {
            guard let state = try self.indexStateRow() else { return 0 }
            let context = try self.libraryContext(state)
            try self.execute("""
                UPDATE fingerprint_task AS t SET next_retry_at = ?
                WHERE t.context_id = ? AND t.context_epoch = ? AND t.failure_kind = 'photos_read' AND t.next_retry_at = ?
                AND EXISTS (SELECT 1 FROM photos_representation r WHERE
                """ + " " + Self.readFailureMatch + ")", [.double(now.timeIntervalSince1970), .text(context.id.uuidString), .int64(context.epoch),
                    .double(Date.distantFuture.timeIntervalSince1970), .int64(try self.int64(state[2])), .text(try self.text(state[4]))])
            return Int(sqlite3_changes(self.database))
        }
    }

    /// Metadata-only schedule for the same current issuances selected by nextRepresentationTasks.
    public func indexWorkSchedule(now: Date) async throws -> (pending: Bool, due: Bool, nextRetryAt: Date?) {
        try await perform {
            guard let state = try self.indexStateRow() else { return (false, false, nil) }
            let context = try self.libraryContext(state), hold = Date.distantFuture.timeIntervalSince1970
            let row = try self.one("""
                SELECT COUNT(*), COALESCE(SUM(CASE WHEN (t.next_retry_at IS NULL OR t.next_retry_at <= ?)
                    AND NOT (t.failure_kind IS 'photos_read' AND t.next_retry_at IS ?) THEN 1 ELSE 0 END),0),
                    MIN(CASE WHEN NOT (t.failure_kind IS 'photos_read' AND t.next_retry_at IS ?) THEN t.next_retry_at END)
                FROM fingerprint_task t JOIN photos_representation r
                ON r.context_id=t.context_id AND r.context_epoch=t.context_epoch AND r.asset_id=t.asset_id AND r.kind=t.kind
                    AND r.revision=t.revision AND r.fingerprint_version=t.fingerprint_version
                WHERE t.context_id=? AND t.context_epoch=? AND t.fingerprint_version=?
                    AND r.tombstoned=0 AND r.seen_generation=t.generation AND t.generation>0 AND t.generation<=? AND r.state<>'ready'
                """, [.double(now.timeIntervalSince1970), .double(hold), .double(hold), .text(context.id.uuidString), .int64(context.epoch),
                    .text(try self.text(state[4])), .int64(try self.int64(state[2]))])!
            return (try self.int64(row[0]) > 0, try self.int64(row[1]) > 0, self.optionalDouble(row[2]).map(Date.init(timeIntervalSince1970:)))
        }
    }

    /// Read a proved digest/vector pair, never the mutable requested-version field.
    /// A later generation change still has to pass completeRepresentation's fence.
    public func reusableFingerprint(_ task: RepresentationTask, input: ModelInputDigest) async throws -> Fingerprint? {
        try await perform { try self.reusableFingerprintSync(task, input: input) }
    }

    private func reusableFingerprintSync(_ task: RepresentationTask, input: ModelInputDigest) throws -> Fingerprint? {
        guard try representationTaskIsCurrent(task),
              let retry = try one("SELECT retry_count FROM fingerprint_task WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", representationBindings(task.descriptor)),
              try int64(retry[0]) == Int64(task.retryCount),
              let row = try one("SELECT input_digest, input_digest_contract, input_vector_version, vector FROM photos_representation WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", representationBindings(task.descriptor)),
              case .blob(let digest) = row[0], digest == input.bytes,
              optionalText(row[1]) == input.contract,
              optionalText(row[2]) == task.fingerprintVersion,
              case .blob(let vector) = row[3] else { return nil }
        return try Fingerprint(version: task.fingerprintVersion, littleEndianFloat32: vector)
    }

    /// A stale store-issued task returns false and cannot revive old facts.
    public func completeRepresentation(_ task: RepresentationTask, fingerprint: Fingerprint) async throws -> Bool {
        try await completeRepresentation(task, result: FingerprintResult(fingerprint: fingerprint)) != nil
    }

    /// Diagnostic baselines advance only with an accepted vector in this same transaction.
    /// Missing input evidence preserves any previous successful digest and its own contract.
    public func completeRepresentation(_ task: RepresentationTask, result: FingerprintResult) async throws -> InputDigestComparison? {
        let fingerprint = result.fingerprint
        guard fingerprint.version == task.fingerprintVersion else { throw AdvancedDedupError.modelMismatch }
        return try await perform {
            try self.transaction {
                guard try self.representationTaskIsCurrent(task) else { return nil }
                if result.reusedCachedVector {
                    guard let input = result.inputDigest,
                          try self.reusableFingerprintSync(task, input: input) == fingerprint else { return nil }
                }
                if try self.taskHasReadFailure(task) { try self.revokeReadExclusionPublication() }
                let key = self.representationBindings(task.descriptor)
                let comparison: InputDigestComparison
                if let digest = result.inputDigest {
                    let baseline = try self.one("SELECT input_digest, input_digest_contract FROM photos_representation WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", key)
                    if let baseline, case .blob(let bytes) = baseline[0], let contract = self.optionalText(baseline[1]) {
                        comparison = contract == digest.contract ? (bytes == digest.bytes ? .sameInput : .differentInput) : .incomparable
                    } else { comparison = .missingBaseline }
                    try self.execute("UPDATE photos_representation SET input_digest = ?, input_digest_contract = ? WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", [.blob(digest.bytes), .text(digest.contract)] + key)
                } else { comparison = .missingInput }
                try self.execute("UPDATE photos_representation SET state = 'ready', vector = ?, input_vector_version = ?, successful_modification_date = observed_modification_date, successful_vector_version = ? WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?",
                    [.blob(fingerprint.littleEndianFloat32), result.inputDigest == nil ? .null : .text(fingerprint.version), .text(fingerprint.version)] + key)
                try self.execute("DELETE FROM fingerprint_task WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", key)
                return comparison
            }
        }
    }

    /// Stale failures are no-ops; retry state belongs to the same persisted task issuance.
    @discardableResult
    public func failRepresentation(_ task: RepresentationTask, nextRetryAt: Date, detail: String, failureKind: RepresentationFailureKind? = nil) async throws -> Bool {
        try await perform {
            try self.transaction {
                guard try self.representationTaskIsCurrent(task) else { return false }
                let key = self.representationBindings(task.descriptor)
                if failureKind == nil, try self.taskHasReadFailure(task) { try self.revokeReadExclusionPublication() }
                // Failure changes currentness, never the old accepted vector/date/contract.
                try self.execute("UPDATE photos_representation SET state = 'failed' WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", key)
                try self.execute("UPDATE fingerprint_task SET retry_count = retry_count + 1, next_retry_at = ?, last_error = ?, failure_kind = ? WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", [.double(nextRetryAt.timeIntervalSince1970), .text(detail), failureKind.map { .text($0.rawValue) } ?? .null] + key)
                return true
            }
        }
    }

    /// A lightweight fact-complete publication. Returning it does not authorize admission.
    public func indexPublication() async throws -> IndexPublication? {
        try await perform {
            try self.transaction {
                guard let state = try self.indexStateRow(), try self.indexFactsComplete(state) else { return nil }
                let token = try self.indexToken(state)
                let count = try self.one("SELECT COUNT(*) FROM photos_representation WHERE context_id = ? AND context_epoch = ? AND tombstoned = 0 AND state = 'ready'", [.text(token.context.id.uuidString), .int64(token.context.epoch)])!
                return IndexPublication(token: token, representationCount: Int(try self.int64(count[0])))
            }
        }
    }

    /// Completes this process's publication proof after the coordinator checks Photos.
    public func markIndexPublished(token: IndexToken) async throws -> Bool {
        try await perform {
            try self.transaction {
                guard let state = try self.indexStateRow(), try self.indexToken(state) == token,
                      try self.indexFactsComplete(state) else { return false }
                try self.execute("UPDATE dedup_index_state SET published_generation = generation WHERE id = 1")
                self.publishedIndexToken = token
                return true
            }
        }
    }

    public func indexIsReady(token: IndexToken) async throws -> Bool {
        try await perform {
            guard let state = try self.indexStateRow(), try self.indexToken(state) == token,
                  self.optionalInteger(state[3]) == token.indexGeneration,
                  let published = self.publishedIndexToken, self.samePhotosIndex(published, token) else { return false }
            return try self.indexFactsComplete(state)
        }
    }

    private func samePhotosIndex(_ lhs: IndexToken, _ rhs: IndexToken) -> Bool {
        lhs.context == rhs.context && lhs.photosGeneration == rhs.photosGeneration &&
            lhs.indexGeneration == rhs.indexGeneration && lhs.fingerprintVersion == rhs.fingerprintVersion
    }
    private func representationBindings(_ descriptor: RepresentationDescriptor) -> [Binding] {
        [.text(descriptor.context.id.uuidString), .int64(descriptor.context.epoch), .text(descriptor.key.assetID), .text(descriptor.key.kind.rawValue)]
    }
    private func indexStateRow() throws -> [Value]? {
        try one("SELECT context_id, context_epoch, generation, published_generation, fingerprint_version, photos_generation, local_revision, reconciliation_complete FROM dedup_index_state WHERE id = 1", [])
    }
    private func libraryContext(_ row: [Value]) throws -> LibraryContext { LibraryContext(id: try uuid(row[0]), epoch: try int64(row[1])) }
    private func indexToken(_ row: [Value]) throws -> IndexToken {
        IndexToken(context: try libraryContext(row), photosGeneration: Int(try int64(row[5])),
                   indexGeneration: try int64(row[2]), localRevision: try int64(row[6]), fingerprintVersion: try text(row[4]))
    }
    // Evaluate only metadata; the expression index covers the vector-null check.
    // A failed row and its task must prove the same current issuance. Both sides
    // are checked so an orphan, stale or duplicate task cannot authorize a gap.
    private static let readFailureMatch = """
        t.context_id = r.context_id AND t.context_epoch = r.context_epoch
        AND t.asset_id = r.asset_id AND t.kind = r.kind AND t.revision = r.revision
        AND t.fingerprint_version = r.fingerprint_version AND t.generation = r.seen_generation
        AND t.failure_kind = 'photos_read' AND r.state = 'failed'
        AND t.retry_count > 0 AND t.next_retry_at IS NOT NULL AND t.last_error IS NOT NULL
        AND r.tombstoned = 0 AND r.revision <> '' AND COALESCE(t.issuance_revision,t.revision) <> ''
        AND t.generation > 0 AND t.generation <= ? AND t.fingerprint_version = ?
        """

    private func indexFactsComplete(_ row: [Value]) throws -> Bool {
        guard try int64(row[7]) != 0 else { return false }
        let context = try libraryContext(row)
        let bindings: [Binding] = [.text(context.id.uuidString), .int64(context.epoch),
            .int64(try int64(row[2])), .text(try text(row[4]))]
        let invalidMetadata = try one("SELECT 1 FROM photos_representation WHERE context_id = ? AND context_epoch = ? AND tombstoned = 0 AND (seen_generation <= 0 OR seen_generation > ? OR fingerprint_version <> ?) LIMIT 1", bindings)
        guard invalidMetadata == nil else { return false }
        let incomplete = try one("""
            SELECT 1 FROM photos_representation r WHERE r.context_id = ? AND r.context_epoch = ?
            AND r.tombstoned = 0 AND (r.state <> 'ready' OR (r.vector IS NULL) = 1)
            AND NOT EXISTS (SELECT 1 FROM fingerprint_task t WHERE
            """ + " " + Self.readFailureMatch + ") LIMIT 1", bindings)
        guard incomplete == nil else { return false }
        // Only current classified read failures authorize a gap; retained vectors
        // remain excluded by state in every publication and candidate query.
        let invalidTask = try one("""
            SELECT 1 FROM fingerprint_task t WHERE t.context_id = ? AND t.context_epoch = ?
            AND NOT EXISTS (SELECT 1 FROM photos_representation r WHERE
            """ + " " + Self.readFailureMatch + ") LIMIT 1", bindings)
        return invalidTask == nil
    }

    private func taskHasReadFailure(_ task: RepresentationTask) throws -> Bool {
        try one("SELECT 1 FROM fingerprint_task WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ? AND failure_kind = 'photos_read' LIMIT 1", representationBindings(task.descriptor)) != nil
    }

    private func revokeReadExclusionPublication() throws {
        guard let state = try indexStateRow(), try int64(state[2]) < Int64.max else {
            throw SyncStoreError.constraint("Index generation overflow.")
        }
        try execute("UPDATE dedup_index_state SET generation = generation + 1, published_generation = NULL WHERE id = 1")
    }
    private func representationTaskIsCurrent(_ task: RepresentationTask) throws -> Bool {
        guard let state = try indexStateRow(), try libraryContext(state) == task.descriptor.context,
              try text(state[4]) == task.fingerprintVersion, task.indexGeneration > 0,
              try task.indexGeneration <= int64(state[2]) else { return false }
        let row = try one("SELECT r.revision, r.seen_generation, r.tombstoned, r.width, r.height, r.equivalent_to_original, r.revision_is_reliable, COALESCE(t.issuance_revision,t.revision), r.observed_modification_date FROM photos_representation r JOIN fingerprint_task t ON r.context_id = t.context_id AND r.context_epoch = t.context_epoch AND r.asset_id = t.asset_id AND r.kind = t.kind AND r.revision = t.revision AND r.fingerprint_version = t.fingerprint_version WHERE r.context_id = ? AND r.context_epoch = ? AND r.asset_id = ? AND r.kind = ? AND t.generation = ?", representationBindings(task.descriptor) + [.int64(task.indexGeneration)])
        guard let row else { return false }
        return try text(row[7]) == task.issuanceRevision && int64(row[1]) == task.indexGeneration && int64(row[2]) == 0 &&
            pixelSize(width: row[3], height: row[4]) == task.descriptor.size &&
            (int64(row[5]) != 0) == task.descriptor.equivalentToOriginal &&
            (int64(row[6]) != 0) == task.descriptor.revisionIsReliable &&
            optionalDouble(row[8]) == task.descriptor.modificationDate?.timeIntervalSinceReferenceDate
    }
    private func optionalInteger(_ value: Value) -> Int64? { if case .int64(let integer) = value { return integer }; return nil }
    private func pixelSize(width: Value, height: Value) throws -> PixelSize? {
        if case .null = width, case .null = height { return nil }
        return try PixelSize(width: Int(int64(width)), height: Int(int64(height)))
    }

    // MARK: - Live Photo durable identity, ownership and one-time inventory

    private static let livePhotoInventoryKey = "live-photo-initial-identification-v1"

    func livePhotoSavedContext() async throws -> LibraryContext? {
        try await perform {
            let rows = try self.rows("SELECT context_id,context_epoch FROM live_photo_inventory", [])
            guard rows.count <= 1 else { throw PhotoKitGatewayError.libraryChanged }
            return try rows.first.map { LibraryContext(id: try self.uuid($0[0]), epoch: try self.int64($0[1])) }
        }
    }
    func livePhotoAssetsNeedingDescriptor(context: LibraryContext, now: Date, limit: Int) async throws -> [String] {
        try await perform {
            try self.rows("SELECT asset_id FROM live_photo_inventory_item WHERE context_id=? AND (status='needsDescriptor' OR (status='unresolved' AND descriptor IS NULL AND next_retry_at <= ?)) ORDER BY asset_id LIMIT ?", [.text(context.id.uuidString), .double(now.timeIntervalSince1970), .int64(Int64(limit))]).map { try self.text($0[0]) }
        }
    }
    func refreshLegacyLivePhotoVideoDescriptors(context: LibraryContext) async throws {
        try await perform {
            try self.execute("""
                UPDATE live_photo_inventory_item SET status='needsDescriptor',next_retry_at=NULL
                WHERE context_id=? AND status IN ('queued','unresolved') AND is_live_photo=0 AND descriptor IS NOT NULL
                AND json_extract(descriptor,'$.mediaKind')='video' AND COALESCE(json_extract(descriptor,'$.descriptorVersion'),0)<2
                """, [.text(context.id.uuidString)])
        }
    }
    func hasCurrentLivePhotoIdentity(context: LibraryContext, assetID: String, revision: String) async throws -> Bool {
        try await perform {
            try self.one("SELECT 1 FROM live_photo_observation WHERE context_id=? AND asset_id=? AND revision=? AND current=1 AND content_identifier IS NOT NULL LIMIT 1", [.text(context.id.uuidString), .text(assetID), .text(revision)]) != nil
        }
    }
    func markLivePhotoDescriptorUnresolved(context: LibraryContext, assetID: String) async throws {
        try await perform {
            try self.execute("UPDATE live_photo_inventory_item SET status='unresolved',descriptor=NULL,retry_count=retry_count+1,next_retry_at=? WHERE context_id=? AND asset_id=? AND status!='deleted'", [.double(Date().addingTimeInterval(60).timeIntervalSince1970), .text(context.id.uuidString), .text(assetID)])
        }
    }
    func livePhotoGroup(context: LibraryContext, contentIdentifier: String) async throws -> LivePhotoGroup? {
        try await perform {
            guard let row = try self.one("SELECT id,target_id,deleted,completed FROM live_photo_group WHERE context_id=? AND content_identifier=?", [.text(context.id.uuidString), .text(contentIdentifier)]) else { return nil }
            return LivePhotoGroup(id: try self.uuid(row[0]), contextID: context.id, contentIdentifier: contentIdentifier, targetID: self.optionalText(row[1]), deleted: try self.int64(row[2]) != 0, completed: try self.int64(row[3]) != 0)
        }
    }
    func deletedLivePhotoGroupIDs() async throws -> Set<UUID> {
        try await perform { Set(try self.rows("SELECT id FROM live_photo_group WHERE deleted=1", []).map { try self.uuid($0[0]) }) }
    }
    func livePhotoAssetDescriptor(context: LibraryContext, assetID: String) async throws -> LivePhotoAssetDescriptor? {
        try await perform {
            guard let row = try self.one("SELECT descriptor FROM live_photo_inventory_item WHERE context_id=? AND asset_id=? AND status!='deleted'", [.text(context.id.uuidString), .text(assetID)]), case .blob(let bytes) = row[0] else { return nil }
            return try self.decoder.decode(LivePhotoAssetDescriptor.self, from: bytes)
        }
    }
    func hasUnresolvedLivePhotoCandidates(context: LibraryContext) async throws -> Bool {
        try await perform {
            if try self.one("SELECT 1 FROM live_photo_inventory_item WHERE context_id=? AND descriptor IS NULL AND status!='deleted' LIMIT 1", [.text(context.id.uuidString)]) != nil { return true }
            return try self.one("""
                SELECT 1 FROM live_photo_inventory_item i WHERE context_id=? AND is_live_photo=1 AND status!='deleted' AND
                (status!='checked' OR NOT EXISTS (SELECT 1 FROM live_photo_observation p JOIN live_photo_observation m
                    ON m.context_id=p.context_id AND m.asset_id=p.asset_id AND m.content_identifier=p.content_identifier
                    WHERE p.context_id=i.context_id AND p.asset_id=i.asset_id AND p.current=1 AND m.current=1
                    AND p.role='photo' AND m.role='motion' AND p.content_identifier IS NOT NULL)) LIMIT 1
                """, [.text(context.id.uuidString)]) != nil
        }
    }
    func applyLivePhotoDelta(_ delta: PhotosIndexDelta) async throws {
        try await perform { try self.transaction {
            try self.applyLivePhotoChangesSync(context: delta.context, changed: delta.changedAssetIDs, deleted: delta.deletedAssetIDs)
        } }
    }
    /// Producer entry: classified deletion facts are committed before observer/history delivery can be acknowledged.
    func recordLivePhotoChanges(context: LibraryContext, changed: [String], deleted: [String]) throws {
        try queue.sync { try transaction { try applyLivePhotoChangesSync(context: context, changed: changed, deleted: deleted) } }
    }
    private func applyLivePhotoChangesSync(context: LibraryContext, changed: [String], deleted: [String]) throws {
        for assetID in changed {
            try execute("UPDATE live_photo_observation SET current=0 WHERE context_id=? AND asset_id=?", [.text(context.id.uuidString), .text(assetID)])
            try execute("""
                INSERT INTO live_photo_inventory_item(context_id,asset_id,revision,status,is_live_photo,descriptor)
                VALUES(?,?,'','needsDescriptor',-1,NULL) ON CONFLICT(context_id,asset_id) DO UPDATE SET status='needsDescriptor',retry_count=0,next_retry_at=NULL
                WHERE live_photo_inventory_item.status!='deleted'
                """, [.text(context.id.uuidString), .text(assetID)])
        }
        for assetID in deleted {
            try execute("UPDATE live_photo_observation SET current=0 WHERE context_id=? AND asset_id=?", [.text(context.id.uuidString), .text(assetID)])
            try execute("UPDATE live_photo_inventory_item SET status='deleted' WHERE context_id=? AND asset_id=?", [.text(context.id.uuidString), .text(assetID)])
            try execute("UPDATE live_photo_group SET deleted=1 WHERE context_id=? AND target_id=?", [.text(context.id.uuidString), .text(assetID)])
            let active = try rows("SELECT o.payload FROM live_photo_operation o JOIN live_photo_operation_asset a ON a.operation_id=o.id JOIN live_photo_group g ON g.id=o.group_id WHERE a.asset_id=? AND g.context_id=? AND o.stage!='complete'", [.text(assetID), .text(context.id.uuidString)])
            for row in active {
                let op = try decoder.decode(LivePhotoOperation.self, from: blob(row[0]))
                let ownRetirement = op.oldAssetIDs.contains(assetID) && [.submitted, .unknown, .confirmed].contains(op.retirementEvidence)
                if !ownRetirement { try execute("UPDATE live_photo_group SET deleted=1 WHERE id=?", [.text(op.groupID.uuidString)]) }
            }
        }
    }

    func saveLivePhotoObservation(_ observation: LivePhotoObservation) async throws {
        try await perform { try self.transaction { try self.saveLivePhotoObservationSync(observation) } }
    }

    private func saveLivePhotoObservationSync(_ observation: LivePhotoObservation) throws {
        let ref = observation.resource
        let context: Binding
        if case .photos(let id, _, _, _) = ref { context = .text(id.uuidString) } else { context = .null }
        try execute("UPDATE live_photo_observation SET current = 0 WHERE resource_key = ?", [.text(ref.key)])
        try execute("""
            INSERT INTO live_photo_observation(resource_key, revision, inspection_version, content_identifier, role, context_id, asset_id, file_id, current, payload)
            VALUES(?,?,?,?,?,?,?,?,1,?) ON CONFLICT(resource_key,revision,inspection_version) DO UPDATE SET current = 1, payload = excluded.payload,
            content_identifier = excluded.content_identifier, role = excluded.role,
            handled_context_id = CASE WHEN content_identifier IS excluded.content_identifier AND role IS excluded.role THEN handled_context_id ELSE NULL END,
            handled_target_id = CASE WHEN content_identifier IS excluded.content_identifier AND role IS excluded.role THEN handled_target_id ELSE NULL END
            """, [.text(ref.key), .text(ref.revision), .int64(Int64(observation.inspectionVersion)),
                   observation.identity.map { .text($0.contentIdentifier) } ?? .null, observation.identity.map { .text($0.role.rawValue) } ?? .null,
                   context, ref.assetID.map(Binding.text) ?? .null, ref.sourceFileID.map { .text($0.uuidString) } ?? .null,
                   .blob(try encoder.encode(observation))])
    }

    func livePhotoObservation(for ref: LivePhotoResourceRef) async throws -> LivePhotoObservation? {
        try await perform {
            guard let row = try self.one("SELECT payload FROM live_photo_observation WHERE resource_key = ? AND revision = ? AND inspection_version = 1 AND current = 1", [.text(ref.key), .text(ref.revision)]) else { return nil }
            return try self.decoder.decode(LivePhotoObservation.self, from: self.blob(row[0]))
        }
    }

    /// Historical identity can identify the role to retry, never prove current content.
    func historicalLivePhotoIdentity(for ref: LivePhotoResourceRef) async throws -> LivePhotoIdentity? {
        try await perform {
            guard let row = try self.one("SELECT payload FROM live_photo_observation WHERE resource_key = ? AND revision = ? AND inspection_version = 1", [.text(ref.key), .text(ref.revision)]) else { return nil }
            return try self.decoder.decode(LivePhotoObservation.self, from: self.blob(row[0])).identity
        }
    }

    func livePhotoImportingFileCount(operationID: UUID) async throws -> Int {
        try await perform {
            let row = try self.one("SELECT COUNT(*) FROM file_record f JOIN source s ON s.id=f.source_id WHERE f.live_photo_operation_id=? AND f.attempt_id=? AND f.state='importing' AND s.enabled=1 AND s.removed=0", [.text(operationID.uuidString), .text(operationID.uuidString)])
            return try row.map { Int(try self.int64($0[0])) } ?? 0
        }
    }

    func livePhotoObservations(contentIdentifier: String, context: LibraryContext) async throws -> [LivePhotoObservation] {
        try await perform {
            try self.rows("SELECT payload FROM live_photo_observation WHERE content_identifier = ? AND current = 1 AND (context_id IS NULL OR context_id = ?)", [.text(contentIdentifier), .text(context.id.uuidString)]).map {
                try self.decoder.decode(LivePhotoObservation.self, from: self.blob($0[0]))
            }
        }
    }

    func livePhotoIdentifiedIDs(context: LibraryContext, after: String?, limit: Int) async throws -> [String] {
        try await perform {
            try self.rows("SELECT DISTINCT content_identifier FROM live_photo_observation WHERE current = 1 AND content_identifier IS NOT NULL AND (context_id IS NULL OR context_id = ?) AND content_identifier > ? ORDER BY content_identifier LIMIT ?", [.text(context.id.uuidString), .text(after ?? ""), .int64(Int64(max(1, limit)))]).map { try self.text($0[0]) }
        }
    }

    func reserveLivePhotoOperation(_ incoming: LivePhotoOperation) async throws -> Bool {
        try await perform { try self.transaction {
            var operation = incoming
            let existing = try self.one("SELECT id,deleted,completed,target_id FROM live_photo_group WHERE context_id = ? AND content_identifier = ?", [.text(operation.context.id.uuidString), .text(operation.contentIdentifier)])
            if let existing {
                guard try self.int64(existing[1]) == 0 else { return false }
                operation.requiredTargetID = self.optionalText(existing[3])
                operation.groupID = UUID(uuidString: try self.text(existing[0]))!
                if operation.requiredTargetID == nil, try self.one("SELECT 1 FROM live_photo_operation WHERE group_id = ? AND stage NOT IN ('complete','blocked')", [.text(operation.groupID.uuidString)]) != nil { return false }
                if try self.one("SELECT 1 FROM live_photo_operation WHERE group_id = ? AND holds_unknown = 1", [.text(operation.groupID.uuidString)]) != nil { return false }
            }
            guard Set(operation.sourceFileIDs).count == operation.sourceFileIDs.count else { return false }
            operation.sourceStamps = [:]
            for fileID in operation.sourceFileIDs {
                guard let row = try self.one("SELECT state,live_photo_operation_id,size,modified_ns FROM file_record WHERE id = ?", [.text(fileID.uuidString)]),
                      try self.text(row[0]) != "importing", case .null = row[1] else { return false }
                operation.sourceStamps?[fileID.uuidString] = FileStamp(size: try self.int64(row[2]), modifiedNanoseconds: try self.int64(row[3]))
                for ref in [operation.photo, operation.motion] {
                    if case .source(let id, let stamp) = ref, id == fileID {
                        guard try self.int64(row[2]) == stamp.size, try self.int64(row[3]) == stamp.modifiedNanoseconds else { return false }
                    }
                }
            }
            if existing == nil {
                try self.execute("INSERT INTO live_photo_group(id,context_id,content_identifier) VALUES(?,?,?)", [.text(operation.groupID.uuidString), .text(operation.context.id.uuidString), .text(operation.contentIdentifier)])
            }
            try self.writeLivePhotoOperation(operation)
            for id in operation.sourceFileIDs {
                try self.requireChange("UPDATE file_record SET live_photo_operation_id = ? WHERE id = ? AND live_photo_operation_id IS NULL AND state != 'importing'", [.text(operation.id.uuidString), .text(id.uuidString)])
            }
            return true
        } }
    }

    func livePhotoOperation(id: UUID) async throws -> LivePhotoOperation? {
        try await perform { try self.livePhotoOperationSync(id) }
    }
    private func livePhotoOperationSync(_ id: UUID) throws -> LivePhotoOperation? {
        guard let row = try one("SELECT payload FROM live_photo_operation WHERE id = ?", [.text(id.uuidString)]) else { return nil }
        return try decoder.decode(LivePhotoOperation.self, from: blob(row[0]))
    }
    private func writeLivePhotoOperation(_ operation: LivePhotoOperation) throws {
        try execute("INSERT INTO live_photo_operation(id,group_id,stage,holds_unknown,payload) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET stage=excluded.stage,holds_unknown=excluded.holds_unknown,payload=excluded.payload",
                    [.text(operation.id.uuidString), .text(operation.groupID.uuidString), .text(operation.stage.rawValue), .int64(operation.holdsUnknownMutation ? 1 : 0), .blob(try encoder.encode(operation))])
        try execute("DELETE FROM live_photo_operation_asset WHERE operation_id=?", [.text(operation.id.uuidString)])
        var assets = Set(operation.oldAssetIDs + [operation.photo.assetID, operation.motion.assetID, operation.targetID].compactMap { $0 } + (operation.equivalentResources ?? []).compactMap(\.assetID))
        for id in operation.sourceFileIDs {
            if let row = try one("SELECT success_id FROM file_record WHERE id=?", [.text(id.uuidString)]), let success = optionalText(row[0]) { assets.insert(success) }
        }
        for asset in assets {
            try execute("INSERT INTO live_photo_operation_asset(operation_id,asset_id) VALUES(?,?)", [.text(operation.id.uuidString), .text(asset)])
        }

    }
    func saveLivePhotoOperation(_ updated: LivePhotoOperation, expectedStage: LivePhotoOperation.Stage) async throws -> Bool {
        try await perform { try self.transaction {
            guard let old = try self.livePhotoOperationSync(updated.id), old.stage == expectedStage,
                  old.groupID == updated.groupID, old.context == updated.context else { return false }
            guard Set(updated.sourceFileIDs).isSubset(of: Set(old.sourceFileIDs)) else { return false }
            if old.sourceFileIDs != updated.sourceFileIDs {
                guard old.stage == .planned else { return false }
                for id in Set(old.sourceFileIDs).subtracting(updated.sourceFileIDs) {
                    try self.execute("UPDATE file_record SET live_photo_operation_id=NULL WHERE id=? AND live_photo_operation_id=?", [.text(id.uuidString), .text(old.id.uuidString)])
                }
            }
            try self.writeLivePhotoOperation(updated)
            if updated.releasesMembers {
                try self.execute("UPDATE file_record SET live_photo_operation_id = NULL WHERE live_photo_operation_id = ?", [.text(updated.id.uuidString)])
            }
            return true
        } }
    }

    func beginLivePhotoCreation(operationID: UUID) async throws {
        try await perform { try self.transaction {
            guard var op = try self.livePhotoOperationSync(operationID), op.stage == .planned, !op.holdsUnknownMutation else { throw SyncStoreError.invalidTransition("Live Photo operation is not ready") }
            // A group reservation is held before touching any row. Preserve imported/skipped success history.
            try self.execute("UPDATE file_record SET state='importing',attempt_id=?,placeholder_id=NULL,submitted_at=?,definitely_not_committed=0 WHERE live_photo_operation_id=? AND success_id IS NULL AND state IN ('pending','skipped')", [.text(op.id.uuidString), .double(Date().timeIntervalSince1970), .text(op.id.uuidString)])
            op.stage = .creating; op.creationEvidence = .submitted
            try self.writeLivePhotoOperation(op); try self.bumpLocalRevision()
        } }
    }

    func checkpointLivePhotoPlaceholder(operationID: UUID, identifier: String) throws {
        try queue.sync { try transaction {
            guard var op = try livePhotoOperationSync(operationID), op.stage == .creating else { throw SyncStoreError.invalidTransition("Live Photo placeholder has no active operation") }
            op.placeholderID = identifier; try writeLivePhotoOperation(op)
            try execute("UPDATE file_record SET placeholder_id=? WHERE live_photo_operation_id=? AND state='importing' AND attempt_id=?", [.text(identifier), .text(operationID.uuidString), .text(operationID.uuidString)])
        } }
    }

    func confirmLivePhotoCreation(operationID: UUID, identifier: String) async throws {
        try await perform { try self.transaction {
            guard var op = try self.livePhotoOperationSync(operationID), op.stage == .creating || op.creationEvidence == .unknown else { throw SyncStoreError.invalidTransition("No Live Photo creation to confirm") }
            op.targetID = identifier; op.creationEvidence = .confirmed; op.stage = .created
            try self.writeLivePhotoOperation(op)
            try self.markLivePhotoMembersHandled(op, target: identifier)
            try self.execute("UPDATE file_record SET state='imported',success_id=?,success_metadata_json=metadata_json,succeeded_at=?,attempt_id=NULL,placeholder_id=NULL,retry_count=0,next_retry_at=NULL,last_error=NULL WHERE live_photo_operation_id=? AND success_id IS NULL AND state='importing' AND attempt_id=?", [.text(identifier), .double(Date().timeIntervalSince1970), .text(op.id.uuidString), .text(op.id.uuidString)])
            try self.execute("UPDATE live_photo_group SET target_id=? WHERE id=?", [.text(identifier), .text(op.groupID.uuidString)])
            try self.bumpLocalRevision()
        } }
    }

    func reuseLivePhotoTarget(operationID: UUID, identifier: String) async throws {
        try await perform { try self.transaction {
            guard var op = try self.livePhotoOperationSync(operationID), op.stage == .planned else { throw SyncStoreError.invalidTransition("Cannot reuse target during submission") }
            op.targetID = identifier; op.reusedTarget = true; op.stage = .created
            try self.writeLivePhotoOperation(op)
            try self.markLivePhotoMembersHandled(op, target: identifier)
            try self.execute("UPDATE file_record SET state='skipped',skip_reason='suspectedDuplicate',last_error=NULL WHERE live_photo_operation_id=? AND success_id IS NULL AND state IN ('pending','skipped')", [.text(op.id.uuidString)])
            try self.execute("UPDATE live_photo_group SET target_id=? WHERE id=?", [.text(identifier), .text(op.groupID.uuidString)])
            try self.bumpLocalRevision()
        } }
    }

    func loadLivePhotoOperationsForRecovery() async throws -> [LivePhotoOperation] {
        try await perform {
            try self.rows("SELECT payload FROM live_photo_operation WHERE stage != 'complete' OR holds_unknown=1", []).map { try self.decoder.decode(LivePhotoOperation.self, from: self.blob($0[0])) }
        }
    }
    func sourceFile(id: UUID) async throws -> StoredFile? {
        try await perform { try self.storedFile("SELECT \(Self.fileColumns) FROM file_record JOIN source ON source.id=file_record.source_id WHERE file_record.id=?", [.text(id.uuidString)]) }
    }
    func livePhotoSourceMayParticipate(_ id: UUID) async throws -> Bool {
        try await perform {
            try self.one("SELECT 1 FROM file_record f JOIN source s ON s.id=f.source_id WHERE f.id=? AND s.enabled=1 AND s.removed=0 AND (f.skip_reason IS NULL OR f.skip_reason!='sourceChanged')", [.text(id.uuidString)]) != nil
        }
    }
    func isSourceEnabled(_ id: UUID) async throws -> Bool {
        try await perform {
            guard let row = try self.one("SELECT enabled,removed FROM source WHERE id=?", [.text(id.uuidString)]) else { return false }
            return try self.int64(row[0]) == 1 && self.int64(row[1]) == 0
        }
    }
    func livePhotoMemberIsReserved(id: UUID) async throws -> Bool {
        try await perform { try self.one("SELECT 1 FROM file_record WHERE id=? AND live_photo_operation_id IS NOT NULL", [.text(id.uuidString)]) != nil }
    }

    /// No Photos I/O or await in the final durable intent guard.
    func hasUnconfirmedOrdinaryMutation() throws -> Bool {
        try queue.sync { try one("SELECT 1 FROM file_record WHERE state='importing' AND live_photo_operation_id IS NULL LIMIT 1", []) != nil }
    }
    func hasUnconfirmedLivePhotoMutation() throws -> Bool {
        try queue.sync { try one("SELECT 1 FROM live_photo_operation WHERE holds_unknown=1 LIMIT 1", []) != nil }
    }
    func livePhotoMutationAllowed(operationID: UUID, stage: LivePhotoOperation.Stage) throws -> Bool {
        try queue.sync {
            guard let op = try livePhotoOperationSync(operationID), op.stage == stage,
                  let group = try one("SELECT deleted FROM live_photo_group WHERE id=?", [.text(op.groupID.uuidString)]), try int64(group[0]) == 0 else { return false }
            for id in op.sourceFileIDs {
                guard let frozen = op.sourceStamps?[id.uuidString],
                      let row = try one("SELECT f.size,f.modified_ns,s.enabled,s.removed FROM file_record f JOIN source s ON s.id=f.source_id WHERE f.id=? AND f.live_photo_operation_id=?", [.text(id.uuidString), .text(op.id.uuidString)]),
                      try int64(row[0]) == frozen.size, try int64(row[1]) == frozen.modifiedNanoseconds, try int64(row[2]) == 1, try int64(row[3]) == 0 else { return false }
            }
            for ref in [op.photo, op.motion] {
                if case .source(let id, let stamp) = ref {
                    guard let row = try one("SELECT f.size,f.modified_ns,s.enabled,s.removed FROM file_record f JOIN source s ON s.id=f.source_id WHERE f.id=? AND f.live_photo_operation_id=?", [.text(id.uuidString), .text(op.id.uuidString)]),
                          try int64(row[0]) == stamp.size, try int64(row[1]) == stamp.modifiedNanoseconds, try int64(row[2]) == 1, try int64(row[3]) == 0 else { return false }
                } else if case .photos(_, let asset, _, let revision) = ref {
                    guard let row = try one("SELECT revision,status FROM live_photo_inventory_item WHERE context_id=? AND asset_id=?", [.text(op.context.id.uuidString), .text(asset)]),
                          try text(row[0]) == revision, try text(row[1]) == "checked" else { return false }
                }
            }
            return true
        }
    }
    func recordLivePhotoVerification(operationID: UUID, verification: LivePhotoVerification) async throws {
        try await perform { try self.transaction {
            guard var op = try self.livePhotoOperationSync(operationID), [.created, .verifying].contains(op.stage), op.targetID == verification.assetID else { throw SyncStoreError.invalidTransition("Live Photo verification has no target") }
            op.verification = verification; op.stage = verification.passed ? .readyToRetire : .verifying
            op.error = verification.passed ? nil : "完整资源尚待核实"; op.nextRetryAt = verification.passed ? nil : Date().addingTimeInterval(60)
            try self.writeLivePhotoOperation(op)
            if verification.passed { try self.settleSupersededLivePhotoAttempts(verified: op) }
        } }
    }

    /// Repairs older persisted attempts once per recovery. Same-group identity
    /// alone is insufficient: the verified operation must cover every frozen ref.
    func settleSupersededLivePhotoAttempts(context: LibraryContext) async throws {
        try await perform { try self.transaction {
            let rows = try self.rows("SELECT o.payload FROM live_photo_operation o JOIN live_photo_group g ON g.id=o.group_id WHERE g.context_id=? AND g.deleted=0 AND o.stage IN ('readyToRetire','retiring','complete')", [.text(context.id.uuidString)])
            for row in rows {
                let verified = try self.decoder.decode(LivePhotoOperation.self, from: self.blob(row[0]))
                try self.settleSupersededLivePhotoAttempts(verified: verified)
            }
        } }
    }

    private func settleSupersededLivePhotoAttempts(verified: LivePhotoOperation) throws {
        guard let target = verified.targetID, verified.verification?.passed == true,
              verified.verification?.assetID == target,
              let group = try one("SELECT deleted FROM live_photo_group WHERE id=?", [.text(verified.groupID.uuidString)]), try int64(group[0]) == 0 else { return }
        func requiredResources(_ op: LivePhotoOperation) -> Set<LivePhotoResourceRef> {
            var refs = Set([op.photo, op.motion] + (op.discoveryResources ?? []) + (op.equivalentResources ?? []) + (op.limitedResources ?? []))
            for id in op.sourceFileIDs {
                if let stamp = op.sourceStamps?[id.uuidString] { refs.insert(.source(fileID: id, stamp: stamp)) }
            }
            return refs
        }
        // discoveryResources includes possibilities, not proof of equivalence.
        var covered = Set([verified.photo, verified.motion] + (verified.equivalentResources ?? []))
        for id in verified.sourceFileIDs {
            if let stamp = verified.sourceStamps?[id.uuidString] { covered.insert(.source(fileID: id, stamp: stamp)) }
        }
        let rows = try self.rows("SELECT payload FROM live_photo_operation WHERE group_id=? AND stage='blocked' AND holds_unknown=0", [.text(verified.groupID.uuidString)])
        for row in rows {
            var old = try decoder.decode(LivePhotoOperation.self, from: blob(row[0]))
            guard old.id != verified.id, old.context.id == verified.context.id, old.targetID == nil,
                  [.notSubmitted, .failed].contains(old.creationEvidence), [.notSubmitted, .failed].contains(old.retirementEvidence),
                  old.sourceFileIDs.allSatisfy({ old.sourceStamps?[$0.uuidString] != nil }),
                  requiredResources(old).isSubset(of: covered) else { continue }
            old.stage = .complete; old.supersededByOperationID = verified.id
            old.nextRetryAt = nil; old.error = nil; old.deferralReason = nil
            try writeLivePhotoOperation(old)
            try execute("UPDATE file_record SET live_photo_operation_id=NULL WHERE live_photo_operation_id=?", [.text(old.id.uuidString)])
        }
    }
    func beginLivePhotoRetirement(operationID: UUID, assetIDs: [String]) async throws -> Bool {
        try await perform { try self.transaction {
            guard var op = try self.livePhotoOperationSync(operationID), op.stage == .readyToRetire,
                  op.verification?.passed == true, Set(assetIDs) == Set(op.oldAssetIDs), !assetIDs.isEmpty,
                  let row = try self.one("SELECT deleted FROM live_photo_group WHERE id=?", [.text(op.groupID.uuidString)]), try self.int64(row[0]) == 0 else { return false }
            op.stage = .retiring; op.retirementEvidence = .submitted; try self.writeLivePhotoOperation(op); return true
        } }
    }
    func confirmLivePhotoRetirement(operationID: UUID) async throws {
        try await perform { try self.transaction {
            guard var op = try self.livePhotoOperationSync(operationID), op.stage == .retiring else { throw SyncStoreError.invalidTransition("No Live Photo retirement to confirm") }
            op.retirementEvidence = .confirmed; op.stage = .complete; op.error = nil
            try self.writeLivePhotoOperation(op)
            try self.execute("UPDATE live_photo_group SET completed=1 WHERE id=?", [.text(op.groupID.uuidString)])
            try self.execute("UPDATE file_record SET live_photo_operation_id=NULL WHERE live_photo_operation_id=?", [.text(op.id.uuidString)])
        } }
    }
    func completeLivePhotoWithoutRetirement(operationID: UUID) async throws {
        try await perform { try self.transaction {
            guard var op = try self.livePhotoOperationSync(operationID), op.stage == .readyToRetire, op.oldAssetIDs.isEmpty, op.verification?.passed == true else { throw SyncStoreError.invalidTransition("Live Photo still needs retirement") }
            op.stage = .complete; try self.writeLivePhotoOperation(op)
            try self.execute("UPDATE live_photo_group SET completed=1 WHERE id=?", [.text(op.groupID.uuidString)])
            try self.execute("UPDATE file_record SET live_photo_operation_id=NULL WHERE live_photo_operation_id=?", [.text(op.id.uuidString)])
        } }
    }
    func deferLivePhotoCreation(operationID: UUID, detail: String?, definite: Bool) async throws {
        try await perform { try self.transaction {
            guard var op = try self.livePhotoOperationSync(operationID), op.stage == .creating else { return }
            if definite {
                op.stage = .planned; op.creationEvidence = .notSubmitted; op.placeholderID = nil
                try self.execute("UPDATE file_record SET state='pending',attempt_id=NULL,placeholder_id=NULL,submitted_at=NULL WHERE live_photo_operation_id=? AND state='importing' AND success_id IS NULL", [.text(op.id.uuidString)])
            } else { op.creationEvidence = .unknown }
            op.error = detail; op.nextRetryAt = Date().addingTimeInterval(60); try self.writeLivePhotoOperation(op)
        } }
    }

    func livePhotoDiscoveryIsBlocked(context: LibraryContext, contentIdentifier: String, resources: [LivePhotoResourceRef]) async throws -> Bool {
        try await perform {
            guard let row = try self.one("SELECT o.payload FROM live_photo_operation o JOIN live_photo_group g ON g.id=o.group_id WHERE g.context_id=? AND g.content_identifier=? AND o.stage='blocked' ORDER BY o.rowid DESC LIMIT 1", [.text(context.id.uuidString), .text(contentIdentifier)]) else { return false }
            let operation = try self.decoder.decode(LivePhotoOperation.self, from: self.blob(row[0]))
            return Set(operation.discoveryResources ?? [operation.photo, operation.motion]) == Set(resources)
        }
    }
    func livePhotoObservationNeedsCompletion(_ ref: LivePhotoResourceRef, context: LibraryContext, targetID: String?) async throws -> Bool {
        try await perform {
            if let asset = ref.assetID, asset == targetID { return false }
            guard let row = try self.one("SELECT handled_context_id,handled_target_id FROM live_photo_observation WHERE resource_key=? AND revision=? AND current=1", [.text(ref.key), .text(ref.revision)]) else { return false }
            if self.optionalText(row[0]) == context.id.uuidString && self.optionalText(row[1]) != nil { return false }
            if let fileID = ref.sourceFileID,
               let file = try self.one("SELECT live_photo_operation_id FROM file_record WHERE id=?", [.text(fileID.uuidString)]), self.optionalText(file[0]) != nil { return false }
            return true
        }
    }
    private func markLivePhotoMembersHandled(_ op: LivePhotoOperation, target: String) throws {
        for ref in [op.photo, op.motion] + (op.equivalentResources ?? []) {
            try execute("UPDATE live_photo_observation SET handled_context_id=?,handled_target_id=? WHERE resource_key=? AND revision=? AND current=1", [.text(op.context.id.uuidString), .text(target), .text(ref.key), .text(ref.revision)])
        }
        for id in op.sourceFileIDs {
            try execute("UPDATE live_photo_observation SET handled_context_id=?,handled_target_id=? WHERE file_id=? AND current=1", [.text(op.context.id.uuidString), .text(target), .text(id.uuidString)])
        }
        for id in op.oldAssetIDs {
            if let frozen = op.oldSnapshots[id] {
                try execute("UPDATE live_photo_observation SET handled_context_id=?,handled_target_id=? WHERE context_id=? AND asset_id=? AND revision=? AND current=1", [.text(op.context.id.uuidString), .text(target), .text(op.context.id.uuidString), .text(id), .text(frozen.revision)])
            }
        }
    }
    private func establishLivePhotoAnchors(context: LibraryContext, assetIDs: [String]) throws {
        guard !assetIDs.isEmpty else { return }
        try execute("UPDATE live_photo_inventory SET identity_anchors=? WHERE context_id=? AND task_key=? AND identity_anchors IS NULL", [.blob(try encoder.encode(Array(assetIDs.prefix(8)))), .text(context.id.uuidString), .text(Self.livePhotoInventoryKey)])
    }
    func livePhotoIdentityBinding(context: LibraryContext) async throws -> (anchors: [String], requiresProof: Bool) {
        try await perform {
            let task = try self.one("SELECT identity_anchors FROM live_photo_inventory WHERE context_id=? AND task_key=?", [.text(context.id.uuidString), .text(Self.livePhotoInventoryKey)])
            if let task, case .blob(let bytes) = task[0] {
                let fixed = try self.decoder.decode([String].self, from: bytes)
                let targets = try self.rows("SELECT target_id FROM live_photo_group WHERE context_id=? AND target_id IS NOT NULL AND deleted=0 LIMIT 8", [.text(context.id.uuidString)]).map { try self.text($0[0]) }
                return (Array(Set(fixed + targets)).sorted(), true)
            }
            let successes = try self.rows("SELECT DISTINCT success_id FROM file_record WHERE success_id IS NOT NULL ORDER BY success_id LIMIT 8", []).map { try self.text($0[0]) }
            if !successes.isEmpty { return (successes, true) }
            let priorAssets = try self.rows("SELECT asset_id FROM photos_representation WHERE context_id=? ORDER BY asset_id LIMIT 8", [.text(context.id.uuidString)]).map { try self.text($0[0]) }
            if !priorAssets.isEmpty { return (Array(Set(priorAssets)).sorted(), true) }
            let rows = try self.rows("SELECT o.payload FROM live_photo_operation o JOIN live_photo_group g ON g.id=o.group_id WHERE g.context_id=? AND (o.holds_unknown=1 OR g.target_id IS NOT NULL) LIMIT 8", [.text(context.id.uuidString)])
            let operations = try rows.map { try self.decoder.decode(LivePhotoOperation.self, from: self.blob($0[0])) }
            let anchors = Array(Set(operations.flatMap { [$0.placeholderID, $0.targetID].compactMap { $0 } })).sorted()
            return (anchors, !operations.isEmpty)
        }
    }
    func rebindLivePhotoOperationContext(operationID: UUID, expected: LibraryContext, current: LibraryContext) async throws -> Bool {
        try await perform { try self.transaction {
            guard expected.id == current.id, var op = try self.livePhotoOperationSync(operationID), op.context == expected else { return false }
            op.context = current; try self.writeLivePhotoOperation(op); return true
        } }
    }
    func ensureLivePhotoInventory(context: LibraryContext) async throws {
        try await perform {
            try self.execute("INSERT OR IGNORE INTO live_photo_inventory(context_id,task_key,phase,context_epoch) VALUES(?,?,'enumerating',?)", [.text(context.id.uuidString), .text(Self.livePhotoInventoryKey), .int64(context.epoch)])
        }
    }
    func enqueueLivePhotoAssets(context: LibraryContext, assets: [LivePhotoAssetDescriptor]) async throws {
        try await perform { try self.transaction { try self.enqueueLivePhotoAssetsSync(context: context, assets: assets, trusted: true) } }
    }
    func enqueueLivePhotoCatalogAssets(context: LibraryContext, assets: [LivePhotoAssetDescriptor]) throws {
        try queue.sync { try transaction { try enqueueLivePhotoAssetsSync(context: context, assets: assets) } }
    }
    private func enqueueLivePhotoAssetsSync(context: LibraryContext, assets: [LivePhotoAssetDescriptor], trusted: Bool = false) throws {
        for asset in assets {
            guard asset.context.id == context.id, asset.resourceKinds.count == asset.resources.count,
                  asset.resources.allSatisfy({ ref in
                      if case .photos(let id, let assetID, _, let revision) = ref { return id == context.id && assetID == asset.assetID && revision == asset.revision }
                      return false
                  }) else { throw PhotoKitGatewayError.libraryChanged }
            try self.execute("""
                INSERT INTO live_photo_inventory_item(context_id,asset_id,revision,status,is_live_photo,descriptor) VALUES(?,?,?,'queued',?,?)
                ON CONFLICT(context_id,asset_id) DO UPDATE SET revision=excluded.revision,status='queued',retry_count=0,next_retry_at=NULL,is_live_photo=excluded.is_live_photo,descriptor=excluded.descriptor
                WHERE live_photo_inventory_item.revision != excluded.revision OR live_photo_inventory_item.status IN ('deleted','needsDescriptor') OR live_photo_inventory_item.descriptor IS NULL
                """, [.text(context.id.uuidString), .text(asset.assetID), .text(asset.revision), .int64(asset.isLivePhoto ? 1 : 0), .blob(try self.encoder.encode(asset))])
        }
        if trusted { try establishLivePhotoAnchors(context: context, assetIDs: assets.map(\.assetID)) }
    }
    func finishLivePhotoEnumeration(context: LibraryContext, generation: Int) async throws {
        try await perform {
            try self.execute("UPDATE live_photo_inventory SET phase=CASE WHEN phase='completed' THEN phase ELSE 'identifying' END,enumeration_generation=? WHERE context_id=? AND task_key=?", [.int64(Int64(generation)), .text(context.id.uuidString), .text(Self.livePhotoInventoryKey)])
        }
    }
    func nextLivePhotoInventoryItem(context: LibraryContext, now: Date, preferNative: Bool = true) async throws -> LivePhotoAssetDescriptor? {
        try await perform {
            guard let row = try self.one("SELECT descriptor FROM live_photo_inventory_item WHERE context_id=? AND descriptor IS NOT NULL AND (status='queued' OR (status='unresolved' AND next_retry_at <= ?)) ORDER BY CASE WHEN is_live_photo=? THEN 0 ELSE 1 END,CASE status WHEN 'queued' THEN 0 ELSE 1 END,asset_id LIMIT 1", [.text(context.id.uuidString), .double(now.timeIntervalSince1970), .int64(preferNative ? 1 : 0)]) else { return nil }
            return try self.decoder.decode(LivePhotoAssetDescriptor.self, from: self.blob(row[0]))
        }
    }
    func recordLivePhotoInventoryResult(context: LibraryContext, assetID: String, revision: String, observations: [LivePhotoObservation], retryPolicy: LivePhotoInventoryRetryPolicy, observationsAreCurrent: @escaping @Sendable () throws -> Bool = { true }) async throws {
        try await perform { try self.transaction {
            guard let row = try self.one("SELECT revision FROM live_photo_inventory_item WHERE context_id=? AND asset_id=? AND status IN ('queued','unresolved')", [.text(context.id.uuidString), .text(assetID)]), try self.text(row[0]) == revision else { throw LivePhotoReadDeferred.resourceChanged }
            guard try observationsAreCurrent(), observations.allSatisfy({ $0.resource.assetID == assetID && $0.resource.revision == revision }) else { throw PhotoKitGatewayError.libraryChanged }
            let retryDate: Binding
            switch retryPolicy {
            case .automatic(let date): retryDate = .double(date.timeIntervalSince1970)
            case .requiresAttention: retryDate = .null
            }
            let failures = observations.filter { if case .unresolved = $0.inspection { return true }; return false }
            let resourceLimitSkipped = !failures.isEmpty && failures.allSatisfy { ($0.resourceLimitBytes ?? 0) > 0 }
            let unresolved = observations.isEmpty || (!failures.isEmpty && !resourceLimitSkipped)
            try self.establishLivePhotoAnchors(context: context, assetIDs: [assetID])
            for observation in observations {
                try self.saveLivePhotoObservationSync(observation)
            }
            let status = resourceLimitSkipped ? "resourceLimitSkipped" : unresolved ? "unresolved" : "checked"
            try self.execute("UPDATE live_photo_inventory_item SET status=?,retry_count=retry_count+?,next_retry_at=? WHERE context_id=? AND asset_id=? AND revision=?", [.text(status), .int64(unresolved ? 1 : 0), unresolved ? retryDate : .null, .text(context.id.uuidString), .text(assetID), .text(revision)])
        } }
    }
    func retryLivePhotoInventoryAttention(context: LibraryContext, now: Date) async throws -> Int {
        try await perform {
            try self.execute("UPDATE live_photo_inventory_item SET next_retry_at=? WHERE context_id=? AND status='unresolved' AND next_retry_at IS NULL", [.double(now.timeIntervalSince1970), .text(context.id.uuidString)])
            return Int(sqlite3_changes(self.database))
        }
    }
    func completeLivePhotoInventory(context: LibraryContext, expectedGeneration: Int) async throws -> Bool {
        try await perform { try self.transaction {
            guard let task = try self.one("SELECT phase,enumeration_generation FROM live_photo_inventory WHERE context_id=? AND task_key=?", [.text(context.id.uuidString), .text(Self.livePhotoInventoryKey)]) else { return false }
            if try self.text(task[0]) == "completed" { return true }
            guard try self.text(task[0]) == "identifying", try self.int64(task[1]) == Int64(expectedGeneration),
                  try self.one("SELECT 1 FROM live_photo_inventory_item WHERE context_id=? AND status IN ('queued','needsDescriptor') LIMIT 1", [.text(context.id.uuidString)]) == nil else { return false }
            try self.execute("UPDATE live_photo_inventory SET phase='completed',completed_at=? WHERE context_id=? AND task_key=?", [.double(Date().timeIntervalSince1970), .text(context.id.uuidString), .text(Self.livePhotoInventoryKey)])
            return true
        } }
    }
    func livePhotoInventorySummary(context: LibraryContext) async throws -> LivePhotoInventorySummary {
        try await perform {
            let task = try self.one("SELECT phase,completed_at FROM live_photo_inventory WHERE context_id=? AND task_key=?", [.text(context.id.uuidString), .text(Self.livePhotoInventoryKey)])
            let counts = try self.one("SELECT COUNT(*),COALESCE(SUM(status='checked'),0),COALESCE(SUM(status='unresolved'),0),COALESCE(SUM(status IN ('queued','needsDescriptor')),0),COALESCE(SUM(status='unresolved' AND next_retry_at IS NOT NULL),0),COALESCE(SUM(status='unresolved' AND next_retry_at IS NULL),0),MIN(CASE WHEN status='unresolved' THEN next_retry_at END),COALESCE(SUM(status='resourceLimitSkipped'),0) FROM live_photo_inventory_item WHERE context_id=? AND status!='deleted'", [.text(context.id.uuidString)])!
            let limits = try self.one("""
                SELECT COUNT(DISTINCT i.asset_id) FROM live_photo_inventory_item i
                JOIN live_photo_observation o ON o.context_id=i.context_id AND o.asset_id=i.asset_id AND o.revision=i.revision
                WHERE i.context_id=? AND i.status IN ('unresolved','resourceLimitSkipped') AND i.next_retry_at IS NULL AND o.current=1
                AND json_extract(o.payload,'$.resourceLimitBytes') IS NOT NULL
                """, [.text(context.id.uuidString)])!
            return LivePhotoInventorySummary(phase: task.flatMap { try? self.text($0[0]) }.flatMap(LivePhotoInventoryPhase.init(rawValue:)) ?? .enumerating,
                inventoried: Int(try self.int64(counts[0])), identified: Int(try self.int64(counts[1])), unresolved: Int(try self.int64(counts[2])),
                pending: Int(try self.int64(counts[3])), retryWaiting: Int(try self.int64(counts[4])), requiresAttention: Int(try self.int64(counts[5])),
                nextRetryAt: self.optionalDouble(counts[6]).map(Date.init(timeIntervalSince1970:)),
                completedAt: task.flatMap { self.optionalDouble($0[1]) }.map(Date.init(timeIntervalSince1970:)), resourceLimited: Int(try self.int64(limits[0])), skipped: Int(try self.int64(counts[7])))
        }
    }

    private func migrate() throws {
        let originalVersion = try pragmaUserVersion()
        guard originalVersion <= 12 else { throw SyncStoreError.unsupportedSchema(originalVersion) }
        if originalVersion == 12 { return }
        try transaction {
            if originalVersion < 11 {
                try migrateThroughV10()
                if !(try rows("PRAGMA table_info(file_record)", []).map { try text($0[1]) }).contains("live_photo_operation_id") {
                    try execute("ALTER TABLE file_record ADD COLUMN live_photo_operation_id TEXT")
                }
                try execute(Self.livePhotoSchema)
            }
            // Only current cap-only evidence can become a terminal policy skip.
            // Keep its unresolved observation: this is not negative identity proof.
            // No media, inventory enumeration, successful history or operation is touched.
            try execute("""
                UPDATE live_photo_inventory_item AS i SET status='resourceLimitSkipped',next_retry_at=NULL
                WHERE status='unresolved' AND descriptor IS NOT NULL
                AND EXISTS (SELECT 1 FROM live_photo_observation o
                    WHERE o.context_id=i.context_id AND o.asset_id=i.asset_id AND o.revision=i.revision AND o.current=1
                    AND json_type(o.payload,'$.inspection.unresolved') IS NOT NULL
                    AND json_extract(o.payload,'$.resourceLimitBytes') > 0)
                AND NOT EXISTS (SELECT 1 FROM live_photo_observation o
                    WHERE o.context_id=i.context_id AND o.asset_id=i.asset_id AND o.revision=i.revision AND o.current=1
                    AND json_type(o.payload,'$.inspection.unresolved') IS NOT NULL
                    AND COALESCE(json_extract(o.payload,'$.resourceLimitBytes'),0) <= 0)
                """)
            try execute("PRAGMA user_version = 12")
        }
    }

    private func migrateThroughV10() throws {
        let version = try pragmaUserVersion()
        guard version <= 10 else { throw SyncStoreError.unsupportedSchema(version) }
        if version == 10 {
            // Extend the unpublished investigation shape without changing facts.
            do { try addInputDigestColumns() }
            return
        }
        if version == 9 {
            // Existing digests are diagnostic evidence, not a proved pairing with
            // the current vector. Preserve ready rows without manufacturing a binding.
            do {
                try addInputDigestColumns()
                try execute("PRAGMA user_version = 10")
            }
            return
        }
        if version == 8 {
            // Nullable diagnostics do not revoke publication or schedule new work.
            do {
                try addInputDigestColumns()
                try execute("PRAGMA user_version = 10")
            }
            return
        }
        if version == 7 {
            // Fence durable readiness before new-contract startup. An already-open
            // legacy process is not revoked; normal instance ownership remains required.
            do {
                try execute("UPDATE dedup_index_state SET reconciliation_complete = 0, published_generation = NULL")
                try addInputDigestColumns()
                try execute("PRAGMA user_version = 10")
            }
            return
        }
        if version == 6 {
            do {
                try addReadFailureKindColumn()
                try execute("UPDATE dedup_index_state SET reconciliation_complete = 0, published_generation = NULL")
                try addInputDigestColumns()
                try execute("PRAGMA user_version = 10")
            }
            return
        }
        if version == 5 {
            do {
                try execute(Self.photosChangeSchema)
                if !(try rows("PRAGMA table_info(fingerprint_task)", []).map { try text($0[1]) }).contains("issuance_revision") {
                    try execute("ALTER TABLE fingerprint_task ADD COLUMN issuance_revision TEXT")
                }
                try execute("UPDATE dedup_index_state SET reconciliation_complete = 0, published_generation = NULL")
                try addReadFailureKindColumn()
                try addInputDigestColumns()
                try execute("PRAGMA user_version = 10")
            }
            return
        }
        if version == 4 {
            // P1/P2 integration snapshots already use v4. Extend that unpublished
            // schema transactionally without resetting any previously stored facts.
            do {
                let columns = try rows("PRAGMA table_info(dedup_index_state)", []).map { try text($0[1]) }
                if !columns.contains("resume_checkpoint") { try execute("ALTER TABLE dedup_index_state ADD COLUMN resume_checkpoint BLOB") }
                if !columns.contains("excluded_assets") { try execute("ALTER TABLE dedup_index_state ADD COLUMN excluded_assets INTEGER NOT NULL DEFAULT 0") }
                let fingerprintColumns = try rows("PRAGMA table_info(file_fingerprint)", []).map { try text($0[1]) }
                if !fingerprintColumns.contains("attempt_id") {
                    try execute("ALTER TABLE file_fingerprint RENAME TO old_file_fingerprint")
                    try execute(Self.fingerprintSchema)
                    try execute("INSERT INTO file_fingerprint (file_id, size, modified_ns, fingerprint_version, purpose, width, height, vector) SELECT file_id, size, modified_ns, fingerprint_version, purpose, width, height, vector FROM old_file_fingerprint")
                    try execute("DROP TABLE old_file_fingerprint")
                }
                try execute("CREATE INDEX IF NOT EXISTS advanced_evidence_file ON advanced_match_evidence(file_id)")
                try execute("CREATE INDEX IF NOT EXISTS dedup_dependency_candidate ON dedup_dependency(candidate_file_id, file_id)")
                try execute("DROP INDEX IF EXISTS photos_representation_readiness")
                try execute(Self.readinessIndexSchema)
                try execute(Self.exclusionSchema)
                try execute("UPDATE dedup_index_state SET reconciliation_complete = 0, published_generation = NULL")
                try execute(Self.photosChangeSchema)
                if !(try rows("PRAGMA table_info(fingerprint_task)", []).map { try text($0[1]) }).contains("issuance_revision") {
                    try execute("ALTER TABLE fingerprint_task ADD COLUMN issuance_revision TEXT")
                }
                try addReadFailureKindColumn()
                try addInputDigestColumns()
                try execute("PRAGMA user_version = 10")
                try ensureLegacyRecheckSchema()
            }
            return
        }
        do {
            if version == 0 {
                try execute(Self.schema)
            } else {
                if version < 2 {
                    try execute("CREATE TABLE non_media_skip (source_id TEXT NOT NULL REFERENCES source(id), relative_path TEXT NOT NULL, size INTEGER NOT NULL, modified_ns INTEGER NOT NULL, disposition TEXT NOT NULL, state TEXT NOT NULL CHECK(state = 'skipped'), skip_reason TEXT NOT NULL, PRIMARY KEY(source_id, relative_path))")
                }
                if version < 3, !(try sourceHasColumn(named: "removed")) {
                    try execute("ALTER TABLE source ADD COLUMN removed INTEGER NOT NULL DEFAULT 0")
                }
            }
            try execute(Self.advancedSchema)
            try ensureLegacyRecheckSchema()
            try execute(Self.photosChangeSchema)
            if !(try rows("PRAGMA table_info(fingerprint_task)", []).map { try text($0[1]) }).contains("issuance_revision") {
                try execute("ALTER TABLE fingerprint_task ADD COLUMN issuance_revision TEXT")
            }
            try addReadFailureKindColumn()
            try addInputDigestColumns()
            try execute("PRAGMA user_version = 10")
        }
    }

    private static let livePhotoSchema = """
    CREATE TABLE IF NOT EXISTS live_photo_observation (
     resource_key TEXT NOT NULL, revision TEXT NOT NULL, inspection_version INTEGER NOT NULL,
     content_identifier TEXT, role TEXT, context_id TEXT, asset_id TEXT, file_id TEXT,
     current INTEGER NOT NULL DEFAULT 1, handled_context_id TEXT, handled_target_id TEXT, payload BLOB NOT NULL,
     PRIMARY KEY(resource_key, revision, inspection_version)
    );
    CREATE INDEX IF NOT EXISTS live_photo_observation_identity ON live_photo_observation(content_identifier, current, context_id);
    CREATE INDEX IF NOT EXISTS live_photo_observation_asset ON live_photo_observation(context_id, asset_id, current);
    CREATE INDEX IF NOT EXISTS live_photo_observation_file ON live_photo_observation(file_id, current);
    CREATE TABLE IF NOT EXISTS live_photo_group (
     id TEXT PRIMARY KEY, context_id TEXT NOT NULL, content_identifier TEXT NOT NULL,
     target_id TEXT, deleted INTEGER NOT NULL DEFAULT 0, completed INTEGER NOT NULL DEFAULT 0,
     UNIQUE(context_id, content_identifier)
    );
    CREATE UNIQUE INDEX IF NOT EXISTS live_photo_group_identity ON live_photo_group(context_id, content_identifier);
    CREATE TABLE IF NOT EXISTS live_photo_operation (
     id TEXT PRIMARY KEY, group_id TEXT NOT NULL REFERENCES live_photo_group(id),
     stage TEXT NOT NULL, holds_unknown INTEGER NOT NULL, payload BLOB NOT NULL
    );
    CREATE INDEX IF NOT EXISTS live_photo_operation_stage ON live_photo_operation(stage, group_id);
    CREATE TABLE IF NOT EXISTS live_photo_operation_asset (operation_id TEXT NOT NULL REFERENCES live_photo_operation(id) ON DELETE CASCADE, asset_id TEXT NOT NULL, PRIMARY KEY(operation_id,asset_id));
    CREATE INDEX IF NOT EXISTS live_photo_operation_asset_id ON live_photo_operation_asset(asset_id,operation_id);
    CREATE TABLE IF NOT EXISTS live_photo_inventory (
     context_id TEXT NOT NULL, task_key TEXT NOT NULL, phase TEXT NOT NULL, context_epoch INTEGER NOT NULL DEFAULT 0,
     enumeration_generation INTEGER, completed_at REAL, identity_anchors BLOB,
     PRIMARY KEY(context_id, task_key)
    );
    CREATE TABLE IF NOT EXISTS live_photo_inventory_item (
     context_id TEXT NOT NULL, asset_id TEXT NOT NULL, revision TEXT NOT NULL,
     status TEXT NOT NULL, retry_count INTEGER NOT NULL DEFAULT 0, next_retry_at REAL,
     is_live_photo INTEGER NOT NULL, descriptor BLOB,
     PRIMARY KEY(context_id, asset_id)
    );
    CREATE INDEX IF NOT EXISTS live_photo_inventory_queue ON live_photo_inventory_item(context_id, status, next_retry_at, asset_id);
    CREATE INDEX IF NOT EXISTS live_photo_unknown_descriptor ON live_photo_inventory_item(context_id,asset_id) WHERE descriptor IS NULL AND status!='deleted';
    CREATE INDEX IF NOT EXISTS live_photo_complete_candidates ON live_photo_inventory_item(context_id,asset_id,status) WHERE is_live_photo=1 AND status!='deleted';
    CREATE INDEX IF NOT EXISTS file_live_photo_owner ON file_record(live_photo_operation_id);
    """

    private func addInputDigestColumns() throws {
        let columns = try rows("PRAGMA table_info(photos_representation)", []).map { try text($0[1]) }
        if !columns.contains("input_digest") {
            try execute("ALTER TABLE photos_representation ADD COLUMN input_digest BLOB CHECK(input_digest IS NULL OR (typeof(input_digest) = 'blob' AND length(input_digest) = 32))")
        }
        if !columns.contains("input_digest_contract") {
            try execute("ALTER TABLE photos_representation ADD COLUMN input_digest_contract TEXT CHECK(input_digest_contract IS NULL OR length(input_digest_contract) > 0)")
        }
        if !columns.contains("input_vector_version") {
            try execute("ALTER TABLE photos_representation ADD COLUMN input_vector_version TEXT CHECK(input_vector_version IS NULL OR length(input_vector_version) > 0)")
        }
        if !columns.contains("observed_modification_date") {
            try execute("ALTER TABLE photos_representation ADD COLUMN observed_modification_date REAL")
        }
        if !columns.contains("successful_modification_date") {
            try execute("ALTER TABLE photos_representation ADD COLUMN successful_modification_date REAL")
        }
        if !columns.contains("successful_vector_version") {
            try execute("ALTER TABLE photos_representation ADD COLUMN successful_vector_version TEXT CHECK(successful_vector_version IS NULL OR length(successful_vector_version) > 0)")
        }
    }

    private func addReadFailureKindColumn() throws {
        if !(try rows("PRAGMA table_info(fingerprint_task)", []).map { try text($0[1]) }).contains("failure_kind") {
            try execute("ALTER TABLE fingerprint_task ADD COLUMN failure_kind TEXT CHECK(failure_kind IS NULL OR failure_kind = 'photos_read')")
        }
    }

    private static let photosChangeSchema = """
    CREATE TABLE IF NOT EXISTS photos_content_change (
      context_id TEXT NOT NULL, context_epoch INTEGER NOT NULL, run_id TEXT NOT NULL,
      asset_id TEXT NOT NULL, generation INTEGER NOT NULL, removed INTEGER NOT NULL,
      content_changed INTEGER NOT NULL,
      PRIMARY KEY(context_id, context_epoch, run_id, asset_id)
    );
    CREATE INDEX IF NOT EXISTS photos_content_change_asset ON photos_content_change(context_id, context_epoch, asset_id, content_changed);
    """

    private func ensureLegacyRecheckSchema() throws {
        let columns = try rows("PRAGMA table_info(file_record)", []).map { try text($0[1]) }
        for (name, definition) in [("recheck_policy_version", "TEXT"), ("recheck_retry_count", "INTEGER NOT NULL DEFAULT 0"), ("recheck_next_retry_at", "REAL")] where !columns.contains(name) {
            try execute("ALTER TABLE file_record ADD COLUMN \(name) \(definition)")
        }
        let progressColumns = try rows("PRAGMA table_info(dedup_recheck_progress)", []).map { try text($0[1]) }
        if !progressColumns.contains("revision") {
            try execute("ALTER TABLE dedup_recheck_progress ADD COLUMN revision INTEGER NOT NULL DEFAULT 0")
        }
        try execute("CREATE INDEX IF NOT EXISTS file_recheck_retry ON file_record(recheck_policy_version,recheck_next_retry_at,created_order) WHERE recheck_retry_count > 0")
    }

    private func sourceHasColumn(named name: String) throws -> Bool {
        try rows("PRAGMA table_info(source)", []).contains { try text($0[1]) == name }
    }

    private func ensureIndexes() throws {
        guard try one("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'file_record'", []) != nil else { return }
        try transaction {
            try execute("CREATE INDEX IF NOT EXISTS file_state_created_order ON file_record(state, created_order)")
        }
    }

    private func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try operation(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }

    private func pragmaUserVersion() throws -> Int32 {
        guard let row = try one("PRAGMA user_version", []), case .int64(let value) = row[0] else { throw SyncStoreError.sqlite("Unable to read schema version.") }
        return Int32(value)
    }

    private enum Binding { case text(String), int64(Int64), double(Double), blob(Data), null }
    private enum Value { case text(String), int64(Int64), double(Double), blob(Data), null }

    private func execute(_ sql: String, _ bindings: [Binding] = []) throws {
        if bindings.isEmpty {
            var message: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(database, sql, nil, nil, &message)
            defer { sqlite3_free(message) }
            guard result == SQLITE_OK else {
                let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
                throw result & 0xff == SQLITE_BUSY || result & 0xff == SQLITE_LOCKED
                    ? SyncStoreError.busy(detail) : SyncStoreError.sqlite(detail)
            }
        } else {
            _ = try statement(sql, bindings, collect: false)
        }
    }
    private func requireChange(_ sql: String, _ bindings: [Binding]) throws {
        try execute(sql, bindings)
        guard sqlite3_changes(database) == 1 else { throw SyncStoreError.invalidTransition("The record changed before this operation could be committed.") }
    }
    private func one(_ sql: String, _ bindings: [Binding]) throws -> [Value]? { try statement(sql, bindings, collect: true).first }
    private func rows(_ sql: String, _ bindings: [Binding]) throws -> [[Value]] { try statement(sql, bindings, collect: true) }

    private func statement(_ sql: String, _ bindings: [Binding], collect: Bool) throws -> [[Value]] {
        var result: [[Value]] = []
        try withRows(sql, bindings, collect: collect) { result.append($0) }
        return result
    }

    // Decode vector facts while each SQLite row is current; do not retain a second
    // complete collection of BLOBs alongside the resulting Float32 vectors.
    private func mappedRows<T>(_ sql: String, _ bindings: [Binding], transform: ([Value]) throws -> T) throws -> [T] {
        var result: [T] = []
        try withRows(sql, bindings, collect: true) { result.append(try transform($0)) }
        return result
    }

    private func withRows(_ sql: String, _ bindings: [Binding], collect: Bool,
                          consume: ([Value]) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() { try bind(binding, to: statement, index: Int32(offset + 1)) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return
            case SQLITE_ROW:
                guard collect else { continue }
                try consume((0..<Int(sqlite3_column_count(statement))).map { index in
                    switch sqlite3_column_type(statement, Int32(index)) {
                    case SQLITE_INTEGER: return .int64(sqlite3_column_int64(statement, Int32(index)))
                    case SQLITE_FLOAT: return .double(sqlite3_column_double(statement, Int32(index)))
                    case SQLITE_NULL: return .null
                    case SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(statement, Int32(index)))
                        guard let bytes = sqlite3_column_blob(statement, Int32(index)) else { return .blob(Data()) }
                        return .blob(Data(bytes: bytes, count: count))
                    default: return .text(String(cString: sqlite3_column_text(statement, Int32(index))))
                    }
                })
            default: throw databaseError()
            }
        }
    }

    private func bind(_ value: Binding, to statement: OpaquePointer, index: Int32) throws {
        let result: Int32
        switch value {
        case .text(let text): result = sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        case .int64(let integer): result = sqlite3_bind_int64(statement, index, integer)
        case .double(let double): result = sqlite3_bind_double(statement, index, double)
        case .blob(let data):
            result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        case .null: result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw databaseError() }
    }

    private func databaseError() -> SyncStoreError {
        let message = String(cString: sqlite3_errmsg(database))
        switch sqlite3_errcode(database) & 0xff {
        case SQLITE_BUSY, SQLITE_LOCKED: return .busy(message)
        case SQLITE_CONSTRAINT: return .constraint(message)
        default: return .sqlite(message)
        }
    }

    private static let fileColumns = "file_record.id, file_record.source_id, relative_path, source.path, size, modified_ns, metadata_json, state, attempt_id, placeholder_id, success_id, retry_count, next_retry_at, created_order"
    private func storedFile(_ sql: String, _ bindings: [Binding]) throws -> StoredFile? { try one(sql, bindings).map(decodeStoredFile) }
    private func decodeStoredFile(_ row: [Value]) throws -> StoredFile {
        decodeObserver()
        let metadata = try decode(MediaMetadata.self, from: try text(row[6]))
        return StoredFile(id: try uuid(row[0]), createdOrder: try int64(row[13]), file: SourceFile(sourceID: try uuid(row[1]), relativePath: try text(row[2]), url: URL(fileURLWithPath: try text(row[3])).appendingPathComponent(try text(row[2])), stamp: FileStamp(size: try int64(row[4]), modifiedNanoseconds: try int64(row[5])), metadata: metadata), state: try fileState(row[7]), attemptID: optionalUUID(row[8]), placeholderID: optionalText(row[9]), successID: optionalText(row[10]), retryCount: Int(try int64(row[11])), nextRetryAt: optionalDouble(row[12]).map(Date.init(timeIntervalSince1970:)))
    }
    private func fileState(_ value: Value) throws -> FileState { guard let state = FileState(rawValue: try text(value)) else { throw SyncStoreError.sqlite("Invalid file state.") }; return state }
    private func encode<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    private func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T { try decoder.decode(T.self, from: Data(string.utf8)) }
    private func blob(_ value: Value) throws -> Data { if case .blob(let data) = value { return data }; throw SyncStoreError.sqlite("Expected blob value.") }
    private func text(_ value: Value) throws -> String { if case .text(let text) = value { return text }; throw SyncStoreError.sqlite("Expected text value.") }
    private func optionalText(_ value: Value) -> String? { if case .text(let text) = value { return text }; return nil }
    private func int(_ value: Value) throws -> Int64 { try int64(value) }
    private func int64(_ value: Value) throws -> Int64 { if case .int64(let integer) = value { return integer }; throw SyncStoreError.sqlite("Expected integer value.") }
    private func optionalDouble(_ value: Value) -> Double? { if case .double(let double) = value { return double }; if case .int64(let integer) = value { return Double(integer) }; return nil }
    private func uuid(_ value: Value) throws -> UUID { guard let uuid = UUID(uuidString: try text(value)) else { throw SyncStoreError.sqlite("Invalid UUID.") }; return uuid }
    private func optionalUUID(_ value: Value) -> UUID? { optionalText(value).flatMap(UUID.init(uuidString:)) }

    private static let fingerprintSchema = """
    CREATE TABLE file_fingerprint (
     file_id TEXT NOT NULL REFERENCES file_record(id), size INTEGER NOT NULL, modified_ns INTEGER NOT NULL,
     fingerprint_version TEXT NOT NULL, purpose TEXT NOT NULL CHECK(purpose IN ('current','success','attempt')),
     width INTEGER, height INTEGER, vector BLOB NOT NULL CHECK(length(vector) = 4096),
     attempt_id TEXT NOT NULL DEFAULT '',
     PRIMARY KEY(file_id, size, modified_ns, fingerprint_version, purpose, attempt_id),
     CHECK((purpose = 'attempt' AND attempt_id <> '') OR (purpose <> 'attempt' AND attempt_id = ''))
    );
    """

    private static let readinessIndexSchema = """
    CREATE INDEX IF NOT EXISTS photos_representation_readiness ON photos_representation(context_id,context_epoch,state,fingerprint_version,(vector IS NULL),seen_generation) WHERE tombstoned=0;
    """

    private static let exclusionSchema = """
    CREATE TABLE photos_index_exclusion (
     context_id TEXT NOT NULL, context_epoch INTEGER NOT NULL, asset_id TEXT NOT NULL,
     PRIMARY KEY(context_id, context_epoch, asset_id)
    );
    """

    private static let advancedSchema = """
    CREATE TABLE dedup_index_state (
     id INTEGER PRIMARY KEY CHECK(id = 1), context_id TEXT NOT NULL, context_epoch INTEGER NOT NULL,
     generation INTEGER NOT NULL, published_generation INTEGER, fingerprint_version TEXT NOT NULL,
     photos_generation INTEGER NOT NULL, local_revision INTEGER NOT NULL DEFAULT 0,
     reconcile_cursor TEXT, reconciliation_complete INTEGER NOT NULL DEFAULT 0,
     resume_checkpoint BLOB, excluded_assets INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE photos_representation (
     context_id TEXT NOT NULL, context_epoch INTEGER NOT NULL, asset_id TEXT NOT NULL,
     kind TEXT NOT NULL CHECK(kind IN ('original','current')), revision TEXT NOT NULL,
     width INTEGER, height INTEGER, equivalent_to_original INTEGER NOT NULL,
     revision_is_reliable INTEGER NOT NULL, seen_generation INTEGER NOT NULL,
     state TEXT NOT NULL CHECK(state IN ('ready','pending','failed')), fingerprint_version TEXT NOT NULL,
     vector BLOB, tombstoned INTEGER NOT NULL DEFAULT 0,
     PRIMARY KEY(context_id, context_epoch, asset_id, kind),
     CHECK((width IS NULL AND height IS NULL) OR (width > 0 AND height > 0)),
     CHECK(vector IS NULL OR length(vector) = 4096)
    );
    \(readinessIndexSchema)
    \(exclusionSchema)
    CREATE TABLE fingerprint_task (
     context_id TEXT NOT NULL, context_epoch INTEGER NOT NULL, asset_id TEXT NOT NULL,
     kind TEXT NOT NULL, revision TEXT NOT NULL, fingerprint_version TEXT NOT NULL,
     generation INTEGER NOT NULL, retry_count INTEGER NOT NULL DEFAULT 0, next_retry_at REAL, last_error TEXT,
     PRIMARY KEY(context_id, context_epoch, asset_id, kind, revision, fingerprint_version),
     FOREIGN KEY(context_id, context_epoch, asset_id, kind) REFERENCES photos_representation(context_id, context_epoch, asset_id, kind)
    );
    CREATE INDEX fingerprint_task_due ON fingerprint_task(generation, next_retry_at);
    \(fingerprintSchema)
    CREATE TABLE advanced_match_evidence (
     event_id TEXT PRIMARY KEY, file_id TEXT NOT NULL REFERENCES file_record(id),
     size INTEGER NOT NULL, modified_ns INTEGER NOT NULL, token_json TEXT NOT NULL,
     policy_version TEXT NOT NULL, action TEXT NOT NULL, evidence_json TEXT NOT NULL, created_at REAL NOT NULL
    );
    CREATE INDEX advanced_evidence_file ON advanced_match_evidence(file_id);
    CREATE TABLE dedup_dependency (
     file_id TEXT NOT NULL REFERENCES file_record(id), candidate_file_id TEXT NOT NULL REFERENCES file_record(id),
     candidate_revision TEXT NOT NULL, PRIMARY KEY(file_id, candidate_file_id), CHECK(file_id <> candidate_file_id)
    );
    CREATE INDEX dedup_dependency_candidate ON dedup_dependency(candidate_file_id, file_id);
    CREATE TABLE dedup_recheck_progress (
     target_policy_version TEXT PRIMARY KEY, cursor INTEGER, complete INTEGER NOT NULL DEFAULT 0, revision INTEGER NOT NULL DEFAULT 0
    );
    """

    private static let schema = """
    CREATE TABLE source (id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, enabled INTEGER NOT NULL, removed INTEGER NOT NULL DEFAULT 0, last_scan_at REAL, last_error TEXT);
    CREATE TABLE file_record (id TEXT PRIMARY KEY, created_order INTEGER NOT NULL UNIQUE, source_id TEXT NOT NULL REFERENCES source(id), relative_path TEXT NOT NULL, filename TEXT NOT NULL, size INTEGER NOT NULL, modified_ns INTEGER NOT NULL, metadata_json TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','importing','imported','skipped')), skip_reason TEXT, rule_version INTEGER NOT NULL, attempt_id TEXT, placeholder_id TEXT, submitted_at REAL, definitely_not_committed INTEGER NOT NULL DEFAULT 0, success_id TEXT, success_metadata_json TEXT, succeeded_at REAL, retry_count INTEGER NOT NULL DEFAULT 0, next_retry_at REAL, last_error TEXT, recheck_policy_version TEXT, recheck_retry_count INTEGER NOT NULL DEFAULT 0, recheck_next_retry_at REAL, UNIQUE(source_id, relative_path));
    CREATE TABLE match_evidence (file_id TEXT NOT NULL REFERENCES file_record(id), candidate_key TEXT NOT NULL, candidate_json TEXT NOT NULL, rule_version INTEGER NOT NULL, compared_at REAL NOT NULL, PRIMARY KEY(file_id, candidate_key));
    CREATE TABLE scan_run (id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES source(id), started_at REAL NOT NULL, ended_at REAL, complete INTEGER NOT NULL DEFAULT 0, checked INTEGER NOT NULL DEFAULT 0, failed INTEGER NOT NULL DEFAULT 0, last_error TEXT);
    CREATE INDEX file_state_retry ON file_record(state, next_retry_at); CREATE INDEX file_name ON file_record(filename); CREATE INDEX file_state_created_order ON file_record(state, created_order);
    CREATE TABLE non_media_skip (source_id TEXT NOT NULL REFERENCES source(id), relative_path TEXT NOT NULL, size INTEGER NOT NULL, modified_ns INTEGER NOT NULL, disposition TEXT NOT NULL, state TEXT NOT NULL CHECK(state = 'skipped'), skip_reason TEXT NOT NULL, PRIMARY KEY(source_id, relative_path));
    """
}
