import Foundation
import SQLite3

public struct StoredFile: Sendable {
    public let id: UUID
    public let file: SourceFile
    public let state: FileState
    public let attemptID: UUID?
    public let placeholderID: String?
    public let successID: String?
    public let nextRetryAt: Date?
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

    public init(url: URL) throws {
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
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public func registerSource(url: URL) async throws -> UUID {
        try await perform { try self.registerSourceSync(url: url) }
    }

    public func disableSource(id: UUID) async throws {
        try await perform { try self.requireChange("UPDATE source SET enabled = 0 WHERE id = ?", [.text(id.uuidString)]) }
    }

    public func sources() async throws -> [RegisteredSource] {
        try await perform {
            try self.rows("SELECT id, path, enabled FROM source ORDER BY path", []).map {
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

    public func file(sourceID: UUID, relativePath: String) async throws -> StoredFile? {
        try await perform { try self.storedFile("SELECT \(Self.fileColumns) FROM file_record JOIN source ON source.id = file_record.source_id WHERE file_record.source_id = ? AND relative_path = ?", [.text(sourceID.uuidString), .text(relativePath)]) }
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
            try self.requireChange("UPDATE file_record SET state = 'imported', success_id = ?, success_metadata_json = metadata_json, succeeded_at = ?, attempt_id = NULL, placeholder_id = NULL, next_retry_at = NULL, last_error = NULL WHERE id = ? AND state = 'importing' AND attempt_id = ?", [.text(identifier), .double(Date().timeIntervalSince1970), .text(fileID.uuidString), .text(attemptID.uuidString)])
        }
    }

    public func recordSourceChange(fileID: UUID, stamp: FileStamp) async throws {
        try await perform {
            try self.requireChange("UPDATE file_record SET size = ?, modified_ns = ?, state = 'skipped', skip_reason = ?, attempt_id = NULL, placeholder_id = NULL WHERE id = ?", [.int64(stamp.size), .int64(stamp.modifiedNanoseconds), .text(SkipReason.sourceChanged.rawValue), .text(fileID.uuidString)])
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

    public func finishScan(runID: UUID, now: Date, complete: Bool, checked: Int, failed: Int, error: String?) async throws {
        try await perform {
            try self.requireChange("UPDATE scan_run SET ended_at = ?, complete = ?, checked = ?, failed = ?, last_error = ? WHERE id = ?", [.double(now.timeIntervalSince1970), .int64(complete ? 1 : 0), .int64(Int64(checked)), .int64(Int64(failed)), error.map(Binding.text) ?? .null, .text(runID.uuidString)])
        }
    }

    private func registerSourceSync(url: URL) throws -> UUID {
        let normalized = try SourceRegistry.normalizedURL(url)
        let path = normalized.path
        let existing = try rows("SELECT id, path, enabled FROM source", []).map { (try uuid($0[0]), URL(fileURLWithPath: try text($0[1])), try int($0[2]) != 0) }
        for (id, existingURL, enabled) in existing where SourceRegistry.conflicts(normalized, existingURL) {
            if normalized.path == existingURL.path {
                if !enabled { try requireChange("UPDATE source SET enabled = 1 WHERE id = ?", [.text(id.uuidString)]) }
                return id
            }
            throw SourceRegistryError.overlappingSource(existingURL)
        }
        let id = UUID()
        try requireChange("INSERT INTO source (id, path, enabled) VALUES (?, ?, 1)", [.text(id.uuidString), .text(path)])
        return id
    }

    private func markSkippedSync(fileID: UUID, reason: SkipReason, candidates: [MatchCandidate]) throws {
        try requireChange("UPDATE file_record SET state = 'skipped', skip_reason = ?, attempt_id = NULL, placeholder_id = NULL WHERE id = ?", [.text(reason.rawValue), .text(fileID.uuidString)])
        try execute("DELETE FROM match_evidence WHERE file_id = ?", [.text(fileID.uuidString)])
        for candidate in candidates {
            try execute("INSERT INTO match_evidence (file_id, candidate_key, candidate_json, rule_version, compared_at) VALUES (?, ?, ?, ?, ?)", [.text(fileID.uuidString), .text(candidate.key), .text(try encode(candidate)), .int64(Int64(ruleVersion)), .double(Date().timeIntervalSince1970)])
        }
    }

    private func migrate() throws {
        let version = try pragmaUserVersion()
        guard version <= 1 else { throw SyncStoreError.unsupportedSchema(version) }
        guard version == 0 else { return }
        try transaction {
            try execute(Self.schema)
            try execute("PRAGMA user_version = 1")
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

    private static let fileColumns = "file_record.id, file_record.source_id, relative_path, source.path, size, modified_ns, metadata_json, state, attempt_id, placeholder_id, success_id, next_retry_at"
    private func storedFile(_ sql: String, _ bindings: [Binding]) throws -> StoredFile? { try one(sql, bindings).map(decodeStoredFile) }
    private func decodeStoredFile(_ row: [Value]) throws -> StoredFile {
        let metadata = try decode(MediaMetadata.self, from: try text(row[6]))
        return StoredFile(id: try uuid(row[0]), file: SourceFile(sourceID: try uuid(row[1]), relativePath: try text(row[2]), url: URL(fileURLWithPath: try text(row[3])).appendingPathComponent(try text(row[2])), stamp: FileStamp(size: try int64(row[4]), modifiedNanoseconds: try int64(row[5])), metadata: metadata), state: try fileState(row[7]), attemptID: optionalUUID(row[8]), placeholderID: optionalText(row[9]), successID: optionalText(row[10]), nextRetryAt: optionalDouble(row[11]).map(Date.init(timeIntervalSince1970:)))
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
    CREATE TABLE source (id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, enabled INTEGER NOT NULL, last_scan_at REAL, last_error TEXT);
    CREATE TABLE file_record (id TEXT PRIMARY KEY, created_order INTEGER NOT NULL UNIQUE, source_id TEXT NOT NULL REFERENCES source(id), relative_path TEXT NOT NULL, filename TEXT NOT NULL, size INTEGER NOT NULL, modified_ns INTEGER NOT NULL, metadata_json TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','importing','imported','skipped')), skip_reason TEXT, rule_version INTEGER NOT NULL, attempt_id TEXT, placeholder_id TEXT, submitted_at REAL, definitely_not_committed INTEGER NOT NULL DEFAULT 0, success_id TEXT, success_metadata_json TEXT, succeeded_at REAL, retry_count INTEGER NOT NULL DEFAULT 0, next_retry_at REAL, last_error TEXT, UNIQUE(source_id, relative_path));
    CREATE TABLE match_evidence (file_id TEXT NOT NULL REFERENCES file_record(id), candidate_key TEXT NOT NULL, candidate_json TEXT NOT NULL, rule_version INTEGER NOT NULL, compared_at REAL NOT NULL, PRIMARY KEY(file_id, candidate_key));
    CREATE TABLE scan_run (id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES source(id), started_at REAL NOT NULL, ended_at REAL, complete INTEGER NOT NULL DEFAULT 0, checked INTEGER NOT NULL DEFAULT 0, failed INTEGER NOT NULL DEFAULT 0, last_error TEXT);
    CREATE INDEX file_state_retry ON file_record(state, next_retry_at); CREATE INDEX file_name ON file_record(filename);
    """
}
