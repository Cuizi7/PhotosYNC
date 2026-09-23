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
    private let database: OpaquePointer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let ruleVersion = 1
    private let readExecutor: ReadExecutor
    private let validateSource: @Sendable (URL) throws -> URL
    private let decodeObserver: @Sendable () -> Void

    public init(url: URL, readExecutor: ReadExecutor = .shared,
                validateSource: @escaping @Sendable (URL) throws -> URL = { try SourceRegistry.normalizedURL($0) },
                decodeObserver: @escaping @Sendable () -> Void = {}) throws {
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

    public func registerSource(url: URL) async throws -> UUID {
        let normalized = try await readExecutor.execute(sourceID: UUID()) { try self.validateSource(url) }
        try Task.checkCancellation()
        return try await perform { try self.transaction { try self.registerSourceSync(url: normalized) } }
    }

    public func disableSource(id: UUID) async throws {
        try await perform { try self.requireChange("UPDATE source SET enabled = 0 WHERE id = ? AND removed = 0", [.text(id.uuidString)]) }
    }

    /// Removes a source from configuration while retaining its file and submission history.
    /// Existing callbacks can still resolve the source by ID for durable audit records.
    public func removeSource(id: UUID) async throws {
        try await perform { try self.requireChange("UPDATE source SET enabled = 0, removed = 1 WHERE id = ? AND removed = 0", [.text(id.uuidString)]) }
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
                guard let row = try self.one("SELECT state, submitted_at, definitely_not_committed FROM file_record WHERE id = ?",
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
                try self.execute("DELETE FROM match_evidence WHERE file_id = ?", [.text(fileID.uuidString)])
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
        try await perform {
            try self.requireChange("UPDATE file_record SET state = 'importing', attempt_id = ?, placeholder_id = NULL, submitted_at = ?, definitely_not_committed = 0, last_error = NULL WHERE id = ? AND state = 'pending'", [.text(attemptID.uuidString), .double(Date().timeIntervalSince1970), .text(fileID.uuidString)])
        }
    }

    public func checkpointPlaceholder(fileID: UUID, attemptID: UUID, identifier: String) throws {
        try queue.sync {
            try requireChange("UPDATE file_record SET placeholder_id = ? WHERE id = ? AND state = 'importing' AND attempt_id = ?", [.text(identifier), .text(fileID.uuidString), .text(attemptID.uuidString)])
        }
    }

    public func markImported(fileID: UUID, attemptID: UUID, identifier: String) async throws {
        try await perform {
            try self.requireChange("UPDATE file_record SET state = 'imported', success_id = ?, success_metadata_json = metadata_json, succeeded_at = ?, attempt_id = NULL, placeholder_id = NULL, retry_count = 0, next_retry_at = NULL, last_error = NULL WHERE id = ? AND state = 'importing' AND attempt_id = ?", [.text(identifier), .double(Date().timeIntervalSince1970), .text(fileID.uuidString), .text(attemptID.uuidString)])
        }
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

    public func recordRetry(fileID: UUID, attemptID: UUID?, nextRetry: Date, error: String, definitelyNotCommitted: Bool) async throws {
        try await perform {
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
        }
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
            }
            return source.id
        }
        let id = UUID()
        try requireChange("INSERT INTO source (id, path, enabled, removed) VALUES (?, ?, 1, 0)", [.text(id.uuidString), .text(path)])
        return id
    }

    private func markSkippedSync(fileID: UUID, reason: SkipReason, candidates: [MatchCandidate]) throws {
        try requireChange("UPDATE file_record SET state = 'skipped', skip_reason = ?, attempt_id = NULL, placeholder_id = NULL WHERE id = ?", [.text(reason.rawValue), .text(fileID.uuidString)])
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

    private func migrate() throws {
        let version = try pragmaUserVersion()
        guard version <= 3 else { throw SyncStoreError.unsupportedSchema(version) }
        guard version < 3 else { return }
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
            try execute("PRAGMA user_version = 3")
        }
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

    private enum Binding { case text(String), int64(Int64), double(Double), null }
    private enum Value { case text(String), int64(Int64), double(Double), null }

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

    private static let schema = """
    CREATE TABLE source (id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, enabled INTEGER NOT NULL, removed INTEGER NOT NULL DEFAULT 0, last_scan_at REAL, last_error TEXT);
    CREATE TABLE file_record (id TEXT PRIMARY KEY, created_order INTEGER NOT NULL UNIQUE, source_id TEXT NOT NULL REFERENCES source(id), relative_path TEXT NOT NULL, filename TEXT NOT NULL, size INTEGER NOT NULL, modified_ns INTEGER NOT NULL, metadata_json TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','importing','imported','skipped')), skip_reason TEXT, rule_version INTEGER NOT NULL, attempt_id TEXT, placeholder_id TEXT, submitted_at REAL, definitely_not_committed INTEGER NOT NULL DEFAULT 0, success_id TEXT, success_metadata_json TEXT, succeeded_at REAL, retry_count INTEGER NOT NULL DEFAULT 0, next_retry_at REAL, last_error TEXT, UNIQUE(source_id, relative_path));
    CREATE TABLE match_evidence (file_id TEXT NOT NULL REFERENCES file_record(id), candidate_key TEXT NOT NULL, candidate_json TEXT NOT NULL, rule_version INTEGER NOT NULL, compared_at REAL NOT NULL, PRIMARY KEY(file_id, candidate_key));
    CREATE TABLE scan_run (id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES source(id), started_at REAL NOT NULL, ended_at REAL, complete INTEGER NOT NULL DEFAULT 0, checked INTEGER NOT NULL DEFAULT 0, failed INTEGER NOT NULL DEFAULT 0, last_error TEXT);
    CREATE INDEX file_state_retry ON file_record(state, next_retry_at); CREATE INDEX file_name ON file_record(filename); CREATE INDEX file_state_created_order ON file_record(state, created_order);
    CREATE TABLE non_media_skip (source_id TEXT NOT NULL REFERENCES source(id), relative_path TEXT NOT NULL, size INTEGER NOT NULL, modified_ns INTEGER NOT NULL, disposition TEXT NOT NULL, state TEXT NOT NULL CHECK(state = 'skipped'), skip_reason TEXT NOT NULL, PRIMARY KEY(source_id, relative_path));
    """
}
