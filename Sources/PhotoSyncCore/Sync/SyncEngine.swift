import Foundation

public struct EngineSnapshot: Sendable {
    public init() {}
    /// These counters describe the latest accepted scan round, including its recovery work.
    public var checked = 0
    public var imported = 0
    public var skipped = 0
    public var failed = 0
    /// Pending is a current persisted queue count, not a cumulative total.
    public var pending = 0
    public var activeWork = false
    public var waitingSources: [UUID: String] = [:]
    public var blockingError: String?
    public var isPaused = false
}

public actor SyncEngine {
    public typealias DirectoryFactory = @Sendable (UUID) -> any DirectoryReading
    public typealias MetadataFactory = @Sendable (UUID) -> any MetadataReading
    private let store: SyncStore
    private let photos: any PhotosGateway
    private let directory: DirectoryFactory
    private let metadata: MetadataFactory
    private let policy: DuplicatePolicy
    private let logger: RunLogger?
    private var status = EngineSnapshot()
    private var scanning = false
    private var recovering = false
    private var storageFailed = false
    private var drainTask: Task<Void, Never>?
    private var activeAttempt: UUID?
    private var uncertainSubmissions: Set<UUID> = []
    private var indexed: [MatchCandidate] = []
    private var eligibleSources: Set<UUID> = []
    private var disabledSources: Set<UUID> = []
    private var scanRuns: [UUID: UUID] = [:]
    private var reportedWaitingSources: Set<UUID> = []
    private var sourceIssues: [UUID: [String: String]] = [:]

    public init(store: SyncStore, photos: any PhotosGateway,
                directory: @escaping DirectoryFactory = { DirectoryReader(sourceID: $0) },
                metadata: @escaping MetadataFactory = { MetadataReader(sourceID: $0) },
                policy: DuplicatePolicy = DuplicatePolicy(), logger: RunLogger? = nil) {
        self.store = store; self.photos = photos; self.directory = directory
        self.metadata = metadata; self.policy = policy; self.logger = logger
    }

    public func sources() async throws -> [RegisteredSource] { try await store.sources() }
    public func addSource(url: URL) async throws -> UUID {
        let id = try await store.registerSource(url: url)
        disabledSources.remove(id)
        return id
    }
    public func disableSource(id: UUID) async throws {
        // Admission closes before the durable update suspends this actor.
        disabledSources.insert(id)
        try await store.disableSource(id: id)
    }
    public func startupScan() async { await scanEnabledSources() }
    public func manualScan() async { await scanEnabledSources() }
    public func wakeScan() async { await scanEnabledSources() }
    public func setPaused(_ paused: Bool) { status.isPaused = paused }
    public func pause() async {
        status.isPaused = true
        logEvent(phase: "scan", result: "paused")
    }
    public func resume() async {
        status.isPaused = false
        logEvent(phase: "scan", result: "resumed")
        await scanEnabledSources()
    }
    public func snapshot() async -> EngineSnapshot {
        await updatePending()
        var result = status
        result.activeWork = scanning || drainTask != nil || recovering
        return result
    }
    public func scanEnabledSources() async {
        do { await scan(sourceIDs: try await store.sources().filter(\.enabled).map(\.id)) }
        catch { stopStorage(error) }
    }

    public func scan(sourceIDs: [UUID]) async {
        guard !scanning, !status.isPaused, !storageFailed else { return }
        scanning = true
        status.checked = 0; status.imported = 0; status.skipped = 0; status.failed = 0
        status.blockingError = nil
        await recoverImports()
        if !uncertainSubmissions.isEmpty {
            status.blockingError = "A Photos submission from this session remains uncertain. Waiting for confirmation."
        }
        guard !storageFailed else { scanning = false; return }
        do { indexed = try await photos.loadCandidates() }
        catch { status.blockingError = error.localizedDescription; scanning = false; return }
        eligibleSources = Set(sourceIDs)
        await withTaskGroup(of: Void.self) { group in
            for sourceID in Set(sourceIDs) { group.addTask { await self.scanSource(sourceID) } }
        }
        scanning = false
        // Existing physical Photos work owns the one drain task. New rounds may still scan.
        if let task = drainTask { await task.value }
        startDrain()
        if let task = drainTask { await task.value }
        await updatePending()
    }

    public func recoverImports() async {
        guard !recovering, !storageFailed else { return }
        recovering = true
        defer { recovering = false }
        do {
            for record in try await allFiles(.importing) where record.attemptID != activeAttempt {
                guard let attempt = record.attemptID else { continue }
                do {
                    switch try await photos.reconcile(placeholder: record.placeholderID) {
                    case .found(let id):
                        try await store.markImported(fileID: record.id, attemptID: attempt, identifier: id)
                        uncertainSubmissions.remove(record.id)
                        status.imported += 1
                        resolveSourceIssue(record.file.sourceID, key: issueKey(for: record.id))
                    case .definitelyNotCommitted:
                        try await store.recordRetry(fileID: record.id, attemptID: attempt, nextRetry: Date(), error: "Confirmed not committed", definitelyNotCommitted: true)
                        uncertainSubmissions.remove(record.id)
                        resolveSourceIssue(record.file.sourceID, key: issueKey(for: record.id))
                    case .unknown:
                        setSourceIssue(record.file.sourceID, key: issueKey(for: record.id), message: "An earlier Photos import is awaiting confirmation.", fileID: record.id, attemptID: attempt, error: nil)
                    }
                } catch let error as SyncStoreError { throw error }
                catch {
                    setSourceIssue(record.file.sourceID, key: issueKey(for: record.id), message: error.localizedDescription, fileID: record.id, attemptID: attempt, error: error)
                }
            }
        } catch { stopStorage(error) }
    }

    private func scanSource(_ sourceID: UUID) async {
        var checked = 0, failed = 0
        var run: UUID?
        do {
            let source = try await store.source(id: sourceID)
            guard source.enabled, !status.isPaused else { return }
            run = try await store.beginScan(sourceID: sourceID, now: Date())
            scanRuns[sourceID] = run
            logEvent(phase: "scan", result: "started", sourceID: sourceID, runID: run)
            let reader = directory(sourceID)
            let metadataReader = metadata(sourceID)
            var directories: [(url: URL, relative: String)] = [(source.url, "")]
            var lastFailure: String?
            while !directories.isEmpty, !status.isPaused, !storageFailed {
                let folder = directories.removeFirst()
                do {
                    for entry in try await reader.entries(in: folder.url) {
                        if status.isPaused || storageFailed { break }
                        if entry.isDirectory { directories.append((entry.url, folder.relative + entry.url.lastPathComponent + "/")); continue }
                        checked += 1; status.checked += 1
                        do {
                            let stamp = try await reader.stamp(of: entry.url)
                            let relative = folder.relative + entry.url.lastPathComponent
                            if let old = try await store.file(sourceID: sourceID, relativePath: relative) {
                                // Never discard the identity of an unresolved actual import.
                                if old.state != .importing, old.file.stamp != stamp {
                                    try await store.recordSourceChange(fileID: old.id, stamp: stamp)
                                    status.skipped += 1
                                    resolveSourceIssue(sourceID, key: issueKey(for: old.id), runID: run, fileID: old.id)
                                }
                                continue
                            }
                            let info = try await metadataReader.read(url: entry.url, filename: entry.url.lastPathComponent)
                            let file = SourceFile(sourceID: sourceID, relativePath: relative, url: entry.url, stamp: stamp, metadata: info)
                            let decision = policy.evaluate(info, candidates: indexed)
                            let evidence = matchingCandidates(decision, candidates: indexed)
                            _ = try await store.save(file, decision: decision, candidates: evidence)
                            if case .skip = decision { status.skipped += 1 }
                        } catch MetadataError.unsupported { continue }
                        catch let error as SyncStoreError { throw error }
                        catch {
                            failed += 1; status.failed += 1
                            lastFailure = error.localizedDescription
                            setSourceIssue(sourceID, key: "scan", message: error.localizedDescription, runID: run, error: error)
                            logEvent(phase: "metadata", result: "failed", sourceID: sourceID, runID: run, path: entry.url.path, error: error)
                        }
                    }
                } catch let error as SyncStoreError { throw error }
                catch {
                    failed += 1; status.failed += 1
                    lastFailure = error.localizedDescription
                    setSourceIssue(sourceID, key: "scan", message: error.localizedDescription, runID: run, error: error)
                    logEvent(phase: "directory", result: "failed", sourceID: sourceID, runID: run, error: error)
                }
            }
            if let run {
                let complete = failed == 0 && !status.isPaused && !storageFailed
                try await store.finishScan(runID: run, now: Date(), complete: complete, checked: checked, failed: failed, error: lastFailure)
                if complete { resolveSourceIssue(sourceID, key: "scan", runID: run) }
                let result = status.isPaused ? "paused" : (complete ? "completed" : "failed")
                logEvent(phase: "scan", result: result, sourceID: sourceID, runID: run)
            }
            startDrain()
        } catch { stopStorage(error) }
    }

    private func startDrain() {
        guard drainTask == nil, !status.isPaused, !storageFailed, status.blockingError == nil else { return }
        drainTask = Task { await self.drain(); self.drainTask = nil }
    }

    private func drain() async {
        do {
            var visited: Set<UUID> = []
            while !status.isPaused, !storageFailed, status.blockingError == nil {
                let records = try await allFiles(.pending)
                guard let record = records.first(where: { !visited.contains($0.id) && eligibleSources.contains($0.file.sourceID) }) else { break }
                visited.insert(record.id)
                guard try await store.source(id: record.file.sourceID).enabled else { continue }
                if let retry = record.nextRetryAt, retry > Date() { continue }
                do {
                    let stamp = try await directory(record.file.sourceID).stamp(of: record.file.url)
                    guard stamp == record.file.stamp else {
                        try await store.recordSourceChange(fileID: record.id, stamp: stamp)
                        status.skipped += 1
                        resolveSourceIssue(record.file.sourceID, key: issueKey(for: record.id), runID: scanRuns[record.file.sourceID], fileID: record.id)
                        continue
                    }
                } catch let error as SyncStoreError { throw error }
                catch {
                    let message = error.localizedDescription
                    status.failed += 1
                    setSourceIssue(record.file.sourceID, key: issueKey(for: record.id), message: message, runID: scanRuns[record.file.sourceID], fileID: record.id, error: error)
                    logEvent(phase: "submission-stamp", result: "failed", sourceID: record.file.sourceID, runID: scanRuns[record.file.sourceID], fileID: record.id, error: error)
                    try await store.recordRetry(fileID: record.id, attemptID: nil, nextRetry: nextRetry(for: record), error: message, definitelyNotCommitted: true)
                    if let run = scanRuns[record.file.sourceID] { try await store.recordScanFailure(runID: run, error: message) }
                    continue
                }
                guard canSubmit(sourceID: record.file.sourceID) else { break }
                do { indexed = try await photos.loadCandidates() }
                catch { status.blockingError = error.localizedDescription; break }
                let local = try await store.candidates(filename: record.file.metadata.filename, excludingID: record.id, olderPendingOnly: true)
                guard canSubmit(sourceID: record.file.sourceID) else { break }
                let candidates = indexed + local
                let decision = policy.evaluate(record.file.metadata, candidates: candidates)
                if case .skip = decision {
                    try await store.markSkipped(fileID: record.id, reason: .suspectedDuplicate, candidates: matchingCandidates(decision, candidates: candidates))
                    status.skipped += 1
                    resolveSourceIssue(record.file.sourceID, key: issueKey(for: record.id), runID: scanRuns[record.file.sourceID], fileID: record.id)
                    continue
                }
                guard canSubmit(sourceID: record.file.sourceID) else { break }
                guard try await store.source(id: record.file.sourceID).enabled else { continue }
                guard canSubmit(sourceID: record.file.sourceID) else { break }
                let attempt = UUID()
                activeAttempt = attempt
                try await store.beginAttempt(fileID: record.id, attemptID: attempt)
                let enabled = try await store.source(id: record.file.sourceID).enabled
                guard enabled, canSubmit(sourceID: record.file.sourceID) else {
                    // A durable attempt exists, but no Photos request has been dispatched.
                    try await store.recordRetry(fileID: record.id, attemptID: attempt, nextRetry: Date(), error: "Submission stopped before dispatch", definitelyNotCommitted: true)
                    activeAttempt = nil
                    break
                }
                do {
                    let store = self.store
                    let id = try await photos.create(fileURL: record.file.url, kind: record.file.metadata.kind) { identifier in
                        try store.checkpointPlaceholder(fileID: record.id, attemptID: attempt, identifier: identifier)
                    }
                    // Even pause or loss of library health cannot erase a committed callback.
                    try await store.markImported(fileID: record.id, attemptID: attempt, identifier: id)
                    indexed.append(MatchCandidate(key: id, metadata: record.file.metadata))
                    status.imported += 1
                    resolveSourceIssue(record.file.sourceID, key: issueKey(for: record.id), runID: scanRuns[record.file.sourceID], fileID: record.id, attemptID: attempt)
                    logEvent(phase: "submission", result: "imported", sourceID: record.file.sourceID, runID: scanRuns[record.file.sourceID], fileID: record.id, attemptID: attempt)
                } catch let error as SyncStoreError { activeAttempt = nil; throw error }
                catch {
                    let definite = (error as? PhotoKitGatewayError)?.recoveryEvidence == .definitelyNotCommitted
                    try await store.recordRetry(fileID: record.id, attemptID: attempt, nextRetry: nextRetry(for: record), error: error.localizedDescription, definitelyNotCommitted: definite)
                    status.failed += 1
                    setSourceIssue(record.file.sourceID, key: issueKey(for: record.id), message: error.localizedDescription, runID: scanRuns[record.file.sourceID], fileID: record.id, attemptID: attempt, error: error)
                    logEvent(phase: "submission", result: "failed", sourceID: record.file.sourceID, runID: scanRuns[record.file.sourceID], fileID: record.id, attemptID: attempt, error: error)
                    // A gateway reporting unknown may still own a physical request. Keep this
                    // instance and stop submissions until its own lifecycle permits recovery.
                    if !definite {
                        uncertainSubmissions.insert(record.id)
                        status.blockingError = error.localizedDescription
                    }
                }
                activeAttempt = nil
            }
        } catch { activeAttempt = nil; stopStorage(error) }
        await updatePending()
    }

    private func canSubmit(sourceID: UUID) -> Bool {
        !status.isPaused && !storageFailed && status.blockingError == nil && uncertainSubmissions.isEmpty && !disabledSources.contains(sourceID)
    }

    private func nextRetry(for record: StoredFile, now: Date = Date()) -> Date {
        now.addingTimeInterval(retryDelay(failureCount: record.retryCount + 1))
    }

    private func issueKey(for fileID: UUID) -> String { "file:\(fileID.uuidString)" }

    private func setSourceIssue(_ sourceID: UUID, key: String, message: String, runID: UUID? = nil, fileID: UUID? = nil, attemptID: UUID? = nil, error: Error?) {
        sourceIssues[sourceID, default: [:]][key] = message
        syncSourceIssueStatus(sourceID, runID: runID, fileID: fileID, attemptID: attemptID, error: error)
    }

    private func resolveSourceIssue(_ sourceID: UUID, key: String, runID: UUID? = nil, fileID: UUID? = nil, attemptID: UUID? = nil) {
        sourceIssues[sourceID]?.removeValue(forKey: key)
        if sourceIssues[sourceID]?.isEmpty == true { sourceIssues.removeValue(forKey: sourceID) }
        syncSourceIssueStatus(sourceID, runID: runID, fileID: fileID, attemptID: attemptID, error: nil)
    }

    private func syncSourceIssueStatus(_ sourceID: UUID, runID: UUID? = nil, fileID: UUID? = nil, attemptID: UUID? = nil, error: Error?) {
        if let message = sourceIssues[sourceID]?.values.sorted().first {
            status.waitingSources[sourceID] = message
            logSourceWaiting(sourceID, runID: runID, fileID: fileID, attemptID: attemptID, error: error)
        } else {
            status.waitingSources.removeValue(forKey: sourceID)
            logSourceRecovered(sourceID, runID: runID, fileID: fileID, attemptID: attemptID)
        }
    }

    private func logSourceWaiting(_ sourceID: UUID, runID: UUID? = nil, fileID: UUID? = nil, attemptID: UUID? = nil, error: Error?) {
        guard reportedWaitingSources.insert(sourceID).inserted else { return }
        logEvent(phase: "recovery", result: "waiting", sourceID: sourceID, runID: runID, fileID: fileID, attemptID: attemptID, error: error)
    }

    private func logSourceRecovered(_ sourceID: UUID, runID: UUID? = nil, fileID: UUID? = nil, attemptID: UUID? = nil) {
        guard reportedWaitingSources.remove(sourceID) != nil else { return }
        logEvent(phase: "recovery", result: "recovered", sourceID: sourceID, runID: runID, fileID: fileID, attemptID: attemptID)
    }

    private func logEvent(phase: String, result: String, sourceID: UUID? = nil, runID: UUID? = nil, fileID: UUID? = nil, attemptID: UUID? = nil, path: String? = nil, error: Error? = nil) {
        var fields = ["phase": phase, "result": result]
        if let sourceID { fields["source"] = sourceID.uuidString }
        if let runID { fields["run"] = runID.uuidString }
        if let fileID { fields["file"] = fileID.uuidString }
        if let attemptID { fields["attempt"] = attemptID.uuidString }
        if let path { fields["path"] = path }
        if let error { fields["error"] = error.localizedDescription }
        logger?.log(fields)
    }

    private func allFiles(_ state: FileState) async throws -> [StoredFile] {
        var result: [StoredFile] = [], cursor: UUID?
        while true {
            let page = try await store.listFiles(state: state, afterID: cursor, limit: 256)
            result += page
            guard page.count == 256 else { return result }
            cursor = page.last?.id
        }
    }
    private func matchingCandidates(_ decision: MatchDecision, candidates: [MatchCandidate]) -> [MatchCandidate] {
        guard case .skip(let keys) = decision else { return [] }
        return candidates.filter { keys.contains($0.key) }
    }
    private func updatePending() async {
        do { status.pending = try await store.countEnabledFiles(state: .pending) }
        catch { stopStorage(error) }
    }
    private func stopStorage(_ error: Error) {
        storageFailed = true; status.blockingError = "Storage stopped: \(error.localizedDescription)"
        logger?.log(["error": error.localizedDescription, "scope": "storage"])
    }
}
