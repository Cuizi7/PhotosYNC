import Foundation
import SQLite3

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
    case constraint(String)
    case notFound(UUID)
    case invalidTransition(String)
    case unsupportedSchema(Int32)

    public var errorDescription: String? {
        switch self {
        case .sqlite(let message), .constraint(let message), .invalidTransition(let message): return message
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
    /// A durable published marker cannot prove that this instance rebuilt its derived index.
    /// Accessed only on the database queue. Local candidate revisions do not change that index.
    private var publishedIndexToken: IndexToken?

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
            try execute("PRAGMA foreign_keys = ON")
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
            return try self.rows("SELECT \(Self.fileColumns) FROM file_record JOIN source ON source.id = file_record.source_id WHERE file_record.state = ? AND created_order > ? ORDER BY created_order LIMIT ?", [.text(state.rawValue), .int64(afterOrder), .int64(Int64(limit))]).map(self.decodeStoredFile)
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
                  AND file_record.created_order > ?
                  AND file_record.source_id IN (\(placeholders))
                  AND source.enabled = 1 AND source.removed = 0
                ORDER BY file_record.created_order
                LIMIT 1
                """, bindings)
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
                let rows = try self.rows("""
                    SELECT f.id, f.state, f.success_id, v.width, v.height, v.vector FROM file_record f
                    JOIN source s ON s.id = f.source_id JOIN file_fingerprint v ON v.file_id = f.id
                    WHERE f.id <> ? AND v.fingerprint_version = ? AND (
                        (f.success_id IS NOT NULL AND v.purpose = 'success') OR
                        (f.success_id IS NULL AND f.state IN ('pending', 'importing') AND f.created_order < ?
                         AND s.enabled = 1 AND s.removed = 0 AND v.purpose = 'current'
                         AND v.size = f.size AND v.modified_ns = f.modified_ns)) ORDER BY f.created_order
                    """, [.text(excluding.uuidString), .text(version), .int64(beforeOrder)])
                let entries = try rows.map { row -> VectorEntry in
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
            return try self.indexFactsComplete(state)
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
                              let record = try self.storedFile("SELECT \(Self.fileColumns) FROM file_record JOIN source ON source.id = file_record.source_id WHERE file_record.id = ? AND source.enabled = 1 AND source.removed = 0 AND (submitted_at IS NULL OR definitely_not_committed = 1)", [.text(fileID.uuidString)]),
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
                AND seen_generation = ? AND tombstoned = 0 AND state = 'ready' AND vector IS NOT NULL
                AND fingerprint_version = ? AND kind = ?
                AND ('photos:' || length(CAST(asset_id AS BLOB)) || ':' || asset_id || ':' || kind) = ?
                """, [.text(token.context.id.uuidString), .int64(token.context.epoch), .int64(token.indexGeneration),
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
        try requireChange("UPDATE file_record SET state = 'importing', attempt_id = ?, placeholder_id = NULL, submitted_at = ?, definitely_not_committed = 0, last_error = NULL WHERE id = ? AND state = 'pending' AND success_id IS NULL AND (submitted_at IS NULL OR definitely_not_committed = 1)", [.text(attemptID.uuidString), .double(Date().timeIntervalSince1970), .text(fileID.uuidString)])
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
                let context = try self.libraryContext(state)
                let version = try self.text(state[4])
                var counts = IndexMutationCounts()
                for descriptor in descriptors {
                    guard descriptor.context == context, !descriptor.key.assetID.isEmpty, !descriptor.revision.isEmpty else {
                        throw AdvancedDedupError.invalidConfiguration
                    }
                    let key = self.representationBindings(descriptor)
                    let previous = try self.one("SELECT revision, width, height, equivalent_to_original, revision_is_reliable, fingerprint_version, state, seen_generation, tombstoned FROM photos_representation WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", key)
                    let unchanged = try previous.map { row in
                        try descriptor.revisionIsReliable && self.int64(row[4]) != 0 &&
                        self.text(row[0]) == descriptor.revision &&
                        self.optionalInteger(row[1]) == descriptor.size.map { Int64($0.width) } &&
                        self.optionalInteger(row[2]) == descriptor.size.map { Int64($0.height) } &&
                        self.int64(row[3]) == (descriptor.equivalentToOriginal ? 1 : 0) &&
                        self.text(row[5]) == version
                    } ?? false
                    let previouslyRemoved = try previous.map { try self.int64($0[8]) != 0 } ?? false
                    if previous == nil || previouslyRemoved {
                        counts.added += 1
                    } else if !unchanged { counts.changed += 1 }
                    if unchanged {
                        try self.execute("UPDATE photos_representation SET seen_generation = ?, tombstoned = 0 WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", [.int64(generation)] + key)
                    } else {
                        try self.execute("DELETE FROM fingerprint_task WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", key)
                        try self.execute("""
                            INSERT INTO photos_representation (context_id, context_epoch, asset_id, kind, revision, width, height,
                            equivalent_to_original, revision_is_reliable, seen_generation, state, fingerprint_version)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)
                            ON CONFLICT(context_id, context_epoch, asset_id, kind) DO UPDATE SET revision = excluded.revision,
                            width = excluded.width, height = excluded.height, equivalent_to_original = excluded.equivalent_to_original,
                            revision_is_reliable = excluded.revision_is_reliable, seen_generation = excluded.seen_generation,
                            state = 'pending', fingerprint_version = excluded.fingerprint_version, vector = NULL, tombstoned = 0
                            """, key + [.text(descriptor.revision), descriptor.size.map { .int64(Int64($0.width)) } ?? .null,
                                         descriptor.size.map { .int64(Int64($0.height)) } ?? .null,
                                         .int64(descriptor.equivalentToOriginal ? 1 : 0), .int64(descriptor.revisionIsReliable ? 1 : 0),
                                         .int64(generation), .text(version)])
                    }
                    // Retried work remains a fact; move it to the newly issued generation only after it was seen.
                    let ready = try self.one("SELECT state FROM photos_representation WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", key)
                    if try ready.map({ try self.text($0[0]) }) != "ready" {
                        try self.execute("""
                            INSERT INTO fingerprint_task (context_id, context_epoch, asset_id, kind, revision, fingerprint_version, generation)
                            VALUES (?, ?, ?, ?, ?, ?, ?)
                            ON CONFLICT(context_id, context_epoch, asset_id, kind, revision, fingerprint_version)
                            DO UPDATE SET generation = excluded.generation
                            """, key + [.text(descriptor.revision), .text(version), .int64(generation)])
                    }
                }
                return counts
            }
        }
    }

    @discardableResult
    public func finishIndexReconciliation(generation: Int64, checkpoint: LibraryResumeCheckpoint? = nil, excludedAssets: Int = 0) async throws -> IndexMutationCounts? {
        guard excludedAssets >= 0 else { throw AdvancedDedupError.invalidConfiguration }
        return try await perform {
            try self.transaction {
                guard let state = try self.indexStateRow(), try self.int64(state[2]) == generation,
                      try self.int64(state[7]) == 0 else { return nil }
                var counts = IndexMutationCounts()
                let context = try self.libraryContext(state)
                if let checkpoint, checkpoint.context != context { throw AdvancedDedupError.invalidConfiguration }
                let key: [Binding] = [.text(context.id.uuidString), .int64(context.epoch), .int64(generation)]
                // A proven equivalent current slot shares the original vector. Only
                // coalesce when that original is eligible in this complete inventory.
                try self.execute("""
                    UPDATE photos_representation SET tombstoned = 1 WHERE context_id = ? AND context_epoch = ?
                    AND tombstoned = 0 AND kind = 'current' AND equivalent_to_original = 1 AND seen_generation = ?
                    AND EXISTS (SELECT 1 FROM photos_representation original WHERE original.context_id = photos_representation.context_id
                    AND original.context_epoch = photos_representation.context_epoch AND original.asset_id = photos_representation.asset_id
                    AND original.kind = 'original' AND original.seen_generation = photos_representation.seen_generation AND original.tombstoned = 0)
                    """, key)
                counts.deleted += Int(sqlite3_changes(self.database))
                try self.execute("UPDATE photos_representation SET tombstoned = 1 WHERE context_id = ? AND context_epoch = ? AND seen_generation <> ? AND tombstoned = 0", key)
                counts.deleted += Int(sqlite3_changes(self.database))
                try self.execute("""
                    DELETE FROM fingerprint_task WHERE EXISTS (SELECT 1 FROM photos_representation r
                    WHERE r.context_id = fingerprint_task.context_id AND r.context_epoch = fingerprint_task.context_epoch
                    AND r.asset_id = fingerprint_task.asset_id AND r.kind = fingerprint_task.kind AND r.tombstoned = 1)
                    """)
                let data = try checkpoint.map { try JSONEncoder().encode($0) }
                try self.execute("UPDATE dedup_index_state SET reconciliation_complete = 1, reconcile_cursor = NULL, resume_checkpoint = ?, excluded_assets = ? WHERE id = 1",
                                 [data.map(Binding.blob) ?? .null, .int64(Int64(excludedAssets))])
                return counts
            }
        }
    }

    /// Durable history cursor belongs to a completed inventory, not vector readiness.
    public func libraryResumeCheckpoint() async throws -> LibraryResumeCheckpoint? {
        try await perform {
            guard let row = try self.one("SELECT resume_checkpoint FROM dedup_index_state WHERE id = 1", []),
                  case .blob(let data) = row[0] else { return nil }
            return try JSONDecoder().decode(LibraryResumeCheckpoint.self, from: data)
        }
    }

    /// Page invalidation is authoritative even when a reliable metadata revision
    /// matches. Invalidate before upsert; an all-invalid page also covers earlier pages.
    public func invalidateRepresentations(assetIDs: [String]?, generation: Int64) async throws {
        try await perform {
            try self.transaction {
                guard let state = try self.indexStateRow(), try self.int64(state[2]) == generation,
                      try self.int64(state[7]) == 0 else { throw SyncStoreError.invalidTransition("Stale reconciliation invalidation.") }
                let context = try self.libraryContext(state)
                let base: [Binding] = [.text(context.id.uuidString), .int64(context.epoch)]
                let ids: [String?] = assetIDs.map { $0.map(Optional.some) } ?? [nil]
                for asset in ids {
                    let filter = "context_id = ? AND context_epoch = ?" + (asset == nil ? "" : " AND asset_id = ?")
                    let bindings = base + (asset.map { [Binding.text($0)] } ?? [])
                    try self.execute("UPDATE photos_representation SET state = 'pending', vector = NULL WHERE " + filter, bindings)
                    try self.execute("DELETE FROM fingerprint_task WHERE " + filter, bindings)
                    // Earlier pages may already have been upserted in this generation.
                    try self.execute("""
                        INSERT INTO fingerprint_task (context_id, context_epoch, asset_id, kind, revision, fingerprint_version, generation)
                        SELECT context_id, context_epoch, asset_id, kind, revision, fingerprint_version, seen_generation
                        FROM photos_representation WHERE
                        """ + " " + filter + " AND seen_generation = ? AND tombstoned = 0", bindings + [.int64(generation)])
                }
            }
        }
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
            let context = try self.libraryContext(state), generation = try self.int64(state[2])
            return try descriptors.filter { descriptor in
                guard descriptor.context == context else { return false }
                guard let row = try self.one("""
                    SELECT revision, width, height, equivalent_to_original, revision_is_reliable
                    FROM photos_representation WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?
                    AND seen_generation = ? AND fingerprint_version = ? AND tombstoned = 0 AND state = 'failed'
                    """, self.representationBindings(descriptor) + [.int64(generation), .text(fingerprintVersion)]) else { return false }
                return try self.text(row[0]) == descriptor.revision &&
                    self.pixelSize(width: row[1], height: row[2]) == descriptor.size &&
                    (self.int64(row[3]) != 0) == descriptor.equivalentToOriginal &&
                    (self.int64(row[4]) != 0) == descriptor.revisionIsReliable
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
            let bindings: [Binding] = [.text(context.id.uuidString), .int64(context.epoch), .int64(try self.int64(state[2]))]
            let row = try self.one("""
                SELECT COUNT(*), COALESCE(SUM(state = 'ready'), 0), COALESCE(SUM(state = 'failed'), 0), COUNT(DISTINCT asset_id)
                FROM photos_representation WHERE context_id = ? AND context_epoch = ? AND seen_generation = ? AND tombstoned = 0
                """, bindings)!
            let ready = try self.one("""
                SELECT COUNT(*) FROM (SELECT asset_id FROM photos_representation WHERE context_id = ? AND context_epoch = ?
                AND seen_generation = ? AND tombstoned = 0 GROUP BY asset_id HAVING MIN(state = 'ready') = 1)
                """, bindings)!
            let excludedRow = try self.one("SELECT excluded_assets FROM dedup_index_state WHERE id = 1", [])!
            let excluded = Int(try self.int64(excludedRow[0]))
            return IndexProgress(state: try self.int64(row[2]) > 0 ? .waiting : .updating,
                totalsKnown: try self.int64(state[7]) != 0, totalAssets: Int(try self.int64(row[3])) + excluded,
                readyAssets: Int(try self.int64(ready[0])), totalRepresentations: Int(try self.int64(row[0])),
                readyRepresentations: Int(try self.int64(row[1])), excludedAssets: excluded,
                issue: try self.int64(row[2]) > 0 ? "部分图库图像暂时无法读取，正在等待重试。" : nil)
        }
    }

    /// Lightweight admission metadata: never materialize all vector BLOBs just
    /// to render progress or validate a token. Publication still decodes every vector.
    public func indexReadiness() async throws -> (token: IndexToken, entryCount: Int)? {
        try await perform {
            try self.transaction {
                guard let state = try self.indexStateRow(), try self.indexFactsComplete(state) else { return nil }
                let token = try self.indexToken(state)
                let row = try self.one("SELECT COUNT(*) FROM photos_representation WHERE context_id = ? AND context_epoch = ? AND tombstoned = 0 AND seen_generation = ?",
                    [.text(token.context.id.uuidString), .int64(token.context.epoch), .int64(token.indexGeneration)])!
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
    public func nextRepresentationTasks(now: Date, limit: Int) async throws -> [RepresentationTask] {
        guard limit > 0 else { return [] }
        return try await perform {
            guard let state = try self.indexStateRow() else { return [] }
            let context = try self.libraryContext(state), generation = try self.int64(state[2]), version = try self.text(state[4])
            let rows = try self.rows("""
                SELECT r.asset_id, r.kind, r.revision, r.width, r.height, r.equivalent_to_original, r.revision_is_reliable,
                t.retry_count, t.next_retry_at FROM fingerprint_task t JOIN photos_representation r
                ON r.context_id = t.context_id AND r.context_epoch = t.context_epoch AND r.asset_id = t.asset_id AND r.kind = t.kind
                AND r.revision = t.revision AND r.fingerprint_version = t.fingerprint_version
                WHERE t.context_id = ? AND t.context_epoch = ? AND t.generation = ? AND t.fingerprint_version = ?
                AND r.tombstoned = 0 AND r.seen_generation = ? AND r.state <> 'ready'
                AND (t.next_retry_at IS NULL OR t.next_retry_at <= ?) ORDER BY r.asset_id, r.kind LIMIT ?
                """, [.text(context.id.uuidString), .int64(context.epoch), .int64(generation), .text(version), .int64(generation), .double(now.timeIntervalSince1970), .int64(Int64(limit))])
            return try rows.map { row in
                guard let kind = RepresentationKind(rawValue: try self.text(row[1])) else { throw AdvancedDedupError.invalidConfiguration }
                let descriptor = RepresentationDescriptor(key: RepresentationKey(assetID: try self.text(row[0]), kind: kind),
                    context: context, revision: try self.text(row[2]), size: try self.pixelSize(width: row[3], height: row[4]),
                    equivalentToOriginal: try self.int64(row[5]) != 0, revisionIsReliable: try self.int64(row[6]) != 0)
                return RepresentationTask(descriptor: descriptor, retryCount: Int(try self.int64(row[7])),
                    nextRetryAt: self.optionalDouble(row[8]).map(Date.init(timeIntervalSince1970:)),
                    fingerprintVersion: version, indexGeneration: generation)
            }
        }
    }

    /// A stale store-issued task returns false and cannot revive old facts.
    public func completeRepresentation(_ task: RepresentationTask, fingerprint: Fingerprint) async throws -> Bool {
        guard fingerprint.version == task.fingerprintVersion else { throw AdvancedDedupError.modelMismatch }
        return try await perform {
            try self.transaction {
                guard try self.representationTaskIsCurrent(task) else { return false }
                try self.execute("UPDATE photos_representation SET state = 'ready', vector = ? WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", [.blob(fingerprint.littleEndianFloat32)] + self.representationBindings(task.descriptor))
                try self.execute("DELETE FROM fingerprint_task WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", self.representationBindings(task.descriptor))
                return true
            }
        }
    }

    /// Stale failures are no-ops; retry scheduling never crosses a generation.
    @discardableResult
    public func failRepresentation(_ task: RepresentationTask, nextRetryAt: Date, detail: String) async throws -> Bool {
        try await perform {
            try self.transaction {
                guard try self.representationTaskIsCurrent(task) else { return false }
                let key = self.representationBindings(task.descriptor)
                try self.execute("UPDATE photos_representation SET state = 'failed' WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", key)
                try self.execute("UPDATE fingerprint_task SET retry_count = retry_count + 1, next_retry_at = ?, last_error = ? WHERE context_id = ? AND context_epoch = ? AND asset_id = ? AND kind = ?", [.double(nextRetryAt.timeIntervalSince1970), .text(detail)] + key)
                return true
            }
        }
    }

    /// A reconstructible immutable snapshot. Returning it does not make it ready for admission.
    public func indexPublication() async throws -> IndexPublication? {
        try await perform {
            try self.transaction {
                guard let state = try self.indexStateRow(), try self.indexFactsComplete(state) else { return nil }
                let token = try self.indexToken(state)
                let rows = try self.rows("SELECT asset_id, kind, width, height, fingerprint_version, vector FROM photos_representation WHERE context_id = ? AND context_epoch = ? AND tombstoned = 0 AND seen_generation = ? ORDER BY asset_id, kind", [.text(token.context.id.uuidString), .int64(token.context.epoch), .int64(token.indexGeneration)])
                let entries = try rows.map { row -> VectorEntry in
                    guard let kind = RepresentationKind(rawValue: try self.text(row[1])),
                          try self.text(row[4]) == token.fingerprintVersion, case .blob(let data) = row[5] else {
                        throw AdvancedDedupError.invalidFingerprint
                    }
                    // Length framing keeps opaque asset IDs, including separators, collision-free.
                    let asset = try self.text(row[0])
                    return VectorEntry(key: "photos:\(asset.utf8.count):\(asset):\(kind.rawValue)",
                        origin: kind == .original ? .photosOriginal : .photosCurrent,
                        fingerprint: try Fingerprint(version: token.fingerprintVersion, littleEndianFloat32: data),
                        size: try self.pixelSize(width: row[2], height: row[3]))
                }
                return IndexPublication(token: token, entries: entries)
            }
        }
    }

    /// The caller must first install the complete immutable derived generation.
    /// This transaction validates facts/token, but cannot inspect an external index.
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
    private func indexFactsComplete(_ row: [Value]) throws -> Bool {
        guard try int64(row[7]) != 0 else { return false }
        let context = try libraryContext(row)
        let incomplete = try one("SELECT 1 FROM photos_representation WHERE context_id = ? AND context_epoch = ? AND tombstoned = 0 AND (seen_generation <> ? OR state <> 'ready' OR fingerprint_version <> ? OR vector IS NULL) LIMIT 1", [.text(context.id.uuidString), .int64(context.epoch), .int64(try int64(row[2])), .text(try text(row[4]))])
        guard incomplete == nil else { return false }
        return try one("SELECT 1 FROM fingerprint_task WHERE context_id = ? AND context_epoch = ? AND generation = ? AND fingerprint_version = ? LIMIT 1", [.text(context.id.uuidString), .int64(context.epoch), .int64(try int64(row[2])), .text(try text(row[4]))]) == nil
    }
    private func representationTaskIsCurrent(_ task: RepresentationTask) throws -> Bool {
        guard let state = try indexStateRow(), try libraryContext(state) == task.descriptor.context,
              try int64(state[2]) == task.indexGeneration, try text(state[4]) == task.fingerprintVersion else { return false }
        let row = try one("SELECT r.revision, r.seen_generation, r.tombstoned, r.width, r.height, r.equivalent_to_original, r.revision_is_reliable FROM photos_representation r JOIN fingerprint_task t ON r.context_id = t.context_id AND r.context_epoch = t.context_epoch AND r.asset_id = t.asset_id AND r.kind = t.kind AND r.revision = t.revision AND r.fingerprint_version = t.fingerprint_version WHERE r.context_id = ? AND r.context_epoch = ? AND r.asset_id = ? AND r.kind = ? AND t.generation = ?", representationBindings(task.descriptor) + [.int64(task.indexGeneration)])
        guard let row else { return false }
        return try text(row[0]) == task.descriptor.revision && int64(row[1]) == task.indexGeneration && int64(row[2]) == 0 &&
            pixelSize(width: row[3], height: row[4]) == task.descriptor.size &&
            (int64(row[5]) != 0) == task.descriptor.equivalentToOriginal &&
            (int64(row[6]) != 0) == task.descriptor.revisionIsReliable
    }
    private func optionalInteger(_ value: Value) -> Int64? { if case .int64(let integer) = value { return integer }; return nil }
    private func pixelSize(width: Value, height: Value) throws -> PixelSize? {
        if case .null = width, case .null = height { return nil }
        return try PixelSize(width: Int(int64(width)), height: Int(int64(height)))
    }

    private func migrate() throws {
        let version = try pragmaUserVersion()
        guard version <= 4 else { throw SyncStoreError.unsupportedSchema(version) }
        guard version < 4 else {
            // P1/P2 integration snapshots already use v4. Extend that unpublished
            // schema transactionally without resetting any previously stored facts.
            try transaction {
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
                try ensureLegacyRecheckSchema()
            }
            return
        }
        try transaction {
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
            try execute("PRAGMA user_version = 4")
        }
    }

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
                throw SyncStoreError.sqlite(detail)
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
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() { try bind(binding, to: statement, index: Int32(offset + 1)) }
        var result: [[Value]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return result
            case SQLITE_ROW:
                guard collect else { continue }
                result.append((0..<Int(sqlite3_column_count(statement))).map { index in
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
        return sqlite3_errcode(database) == SQLITE_CONSTRAINT ? .constraint(message) : .sqlite(message)
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
