import Foundation

public enum ScanProgressState: Equatable, Sendable {
    case notStarted
    case running
    case completed
    case interrupted
}

public struct ScanProgress: Equatable, Sendable {
    public var state: ScanProgressState
    public var checkedCandidates: Int
    public var newlyImported: Int
    public var failed: Int
    public var startedAt: Date?
    public var endedAt: Date?

    public init(
        state: ScanProgressState = .notStarted,
        checkedCandidates: Int = 0,
        newlyImported: Int = 0,
        failed: Int = 0,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        self.state = state
        self.checkedCandidates = checkedCandidates
        self.newlyImported = newlyImported
        self.failed = failed
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public enum EngineRecoveryHint: Equatable, Sendable {
    case uncertainSubmission(message: String)
    case checkpointFailure(message: String)
}

public struct EngineSnapshot: Sendable {
    public init() {}
    /// Nil means the app has not yet completed a summary read.
    public var summary: SyncStatusSummary?
    /// A failed refresh retains `summary` when a prior value exists.
    public var summaryError: String?
    public var latestScan = ScanProgress()
    public var activeWork = false
    public var sourcePhases: [UUID: String] = [:]
    public var waitingSources: [UUID: String] = [:]
    public var blockingError: String?
    public var recoveryHint: EngineRecoveryHint?
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
    private let notify: @Sendable (UUID, Bool) -> Void
    private var status = EngineSnapshot()
    private var scanning = false
    private var recovering = false
    private var storageFailed = false
    private var drainTask: Task<Void, Never>?
    private var activeAttempt: UUID?
    private var uncertainSubmissions: Set<UUID> = []
    private var uncertainSubmissionHints: [UUID: EngineRecoveryHint] = [:]
    private var uncertainSubmissionErrors: [UUID: String] = [:]
    private var hasUncertainSubmissionBlock = false
    private var indexed: [MatchCandidate] = []
    private var disabledSources: Set<UUID> = []
    private var removedSources: Set<UUID> = []
    private var rounds: [UUID: ScanRound] = [:]
    private var latestRoundID: UUID?
    private var reportedWaitingSources: Set<UUID> = []
    private var sourceIssues: [UUID: [String: String]] = [:]

    private struct ScanRound {
        var sources: Set<UUID>
        var runs: [UUID: UUID] = [:]
        var progress: ScanProgress
        var interrupted = false
    }

    private struct SubmissionContext {
        let roundID: UUID
        let runID: UUID?
    }

    public init(store: SyncStore, photos: any PhotosGateway,
                directory: @escaping DirectoryFactory = { DirectoryReader(sourceID: $0) },
                metadata: @escaping MetadataFactory = { MetadataReader(sourceID: $0) },
                policy: DuplicatePolicy = DuplicatePolicy(), logger: RunLogger? = nil,
                notify: @escaping @Sendable (UUID, Bool) -> Void = { _, _ in }) {
        self.store = store; self.photos = photos; self.directory = directory
        self.metadata = metadata; self.policy = policy; self.logger = logger; self.notify = notify
    }

    public func sources() async throws -> [RegisteredSource] { try await store.sources() }
    public func addSource(url: URL) async throws -> UUID {
        let id = try await store.registerSource(url: url)
        disabledSources.remove(id)
        removedSources.remove(id)
        return id
    }
    public func disableSource(id: UUID) async throws {
        // Admission closes before the durable update suspends this actor.
        disabledSources.insert(id)
        try await store.disableSource(id: id)
    }
    public func removeSource(id: UUID) async throws {
        // Removal must close both scan and Photos admission before the database update awaits.
        disabledSources.insert(id)
        removedSources.insert(id)
        clearRemovedSourceStatus(id)
        do {
            try await store.removeSource(id: id)
        } catch {
            stopStorage(error)
            throw error
        }
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
        await refreshSummary()
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
        let sources = Set(sourceIDs).subtracting(disabledSources)
        guard !sources.isEmpty else {
            await refreshSummary()
            return
        }
        scanning = true
        let roundID = beginRound(sources: sources)
        clearBlockingError()
        await recoverImports()
        if !uncertainSubmissions.isEmpty {
            setUncertainSubmissionBlock()
        }
        guard !storageFailed else {
            scanning = false
            await refreshSummary()
            finishRound(roundID)
            return
        }
        do { indexed = try await photos.loadCandidates() }
        catch {
            setBlockingError(error.localizedDescription)
            interruptRound(roundID)
            scanning = false
            await refreshSummary()
            finishRound(roundID)
            return
        }
        await withTaskGroup(of: Void.self) { group in
            for sourceID in sources { group.addTask { await self.scanSource(sourceID, roundID: roundID) } }
        }
        scanning = false
        // Existing physical Photos work owns the one drain task. New rounds may still scan.
        if let task = drainTask { await task.value }
        startDrain(roundID: roundID)
        if let task = drainTask { await task.value }
        await refreshSummary()
        finishRound(roundID)
    }

    public func recoverImports() async {
        guard !recovering, !storageFailed else { return }
        recovering = true
        defer { recovering = false }
        do {
            for record in try await allFiles(.importing) where record.attemptID != activeAttempt {
                guard let attempt = record.attemptID else { continue }
                do {
                    if try await store.isSourceRemoved(id: record.file.sourceID) {
                        removedSources.insert(record.file.sourceID)
                    }
                    switch try await photos.reconcile(placeholder: record.placeholderID) {
                    case .found(let id):
                        try await store.markImported(fileID: record.id, attemptID: attempt, identifier: id)
                        uncertainSubmissions.remove(record.id)
                        uncertainSubmissionHints.removeValue(forKey: record.id)
                        uncertainSubmissionErrors.removeValue(forKey: record.id)
                        clearUncertainSubmissionBlockIfResolved()
                        resolveSourceIssue(record.file.sourceID, key: issueKey(for: record.id))
                    case .definitelyNotCommitted:
                        try await store.recordRetry(fileID: record.id, attemptID: attempt, nextRetry: Date(), error: "Confirmed not committed", definitelyNotCommitted: true)
                        uncertainSubmissions.remove(record.id)
                        uncertainSubmissionHints.removeValue(forKey: record.id)
                        uncertainSubmissionErrors.removeValue(forKey: record.id)
                        clearUncertainSubmissionBlockIfResolved()
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

    private func scanSource(_ sourceID: UUID, roundID: UUID) async {
        status.sourcePhases[sourceID] = "扫描目录与元数据"
        defer { status.sourcePhases.removeValue(forKey: sourceID) }
        var checked = 0, failed = 0
        var run: UUID?
        do {
            let source = try await store.source(id: sourceID)
            guard source.enabled, canScan(sourceID: sourceID) else { return }
            run = try await store.beginScan(sourceID: sourceID, now: Date())
            setRun(run, sourceID: sourceID, roundID: roundID)
            logEvent(phase: "scan", result: "started", sourceID: sourceID, runID: run)
            let reader = directory(sourceID)
            let metadataReader = metadata(sourceID)
            var directories: [(url: URL, relative: String)] = [(source.url, "")]
            var lastFailure: String?
            scanLoop: while !directories.isEmpty, canScan(sourceID: sourceID) {
                let folder = directories.removeFirst()
                do {
                    for entry in try await reader.entries(in: folder.url) {
                        guard canScan(sourceID: sourceID) else { break scanLoop }
                        if entry.isDirectory { directories.append((entry.url, folder.relative + entry.url.lastPathComponent + "/")); continue }
                        let classification = MetadataReader.classification(entry.url)
                        if let failure = entry.failure {
                            if classification == "image" || classification == "video" {
                                checked += 1
                                recordCandidateChecked(roundID)
                            }
                            failed += 1
                            recordRoundFailure(roundID)
                            lastFailure = failure
                            let error = NSError(domain: "PhotoSync.DirectoryEntry", code: 1, userInfo: [NSLocalizedDescriptionKey: failure])
                            setSourceIssue(sourceID, key: "scan", message: failure, runID: run, error: error)
                            logEvent(phase: "metadata", result: "failed", sourceID: sourceID, runID: run, path: entry.url.path, error: error)
                            continue
                        }
                        guard classification == "image" || classification == "video" else {
                            logEvent(phase: "classification", result: classification, sourceID: sourceID, runID: run, path: entry.url.path)
                            continue
                        }
                        checked += 1
                        recordCandidateChecked(roundID)
                        do {
                            let stamp = try await reader.stamp(of: entry.url)
                            guard canScan(sourceID: sourceID) else { break scanLoop }
                            let relative = folder.relative + entry.url.lastPathComponent
                            if let old = try await store.file(sourceID: sourceID, relativePath: relative) {
                                guard canScan(sourceID: sourceID) else { break scanLoop }
                                // Never discard the identity of an unresolved actual import.
                                if old.state != .importing, old.file.stamp != stamp {
                                    try await store.recordSourceChange(fileID: old.id, stamp: stamp)
                                    resolveSourceIssue(sourceID, key: issueKey(for: old.id), runID: run, fileID: old.id)
                                }
                                continue
                            }
                            let info = try await metadataReader.read(url: entry.url, filename: entry.url.lastPathComponent)
                            guard canScan(sourceID: sourceID) else { break scanLoop }
                            let file = SourceFile(sourceID: sourceID, relativePath: relative, url: entry.url, stamp: stamp, metadata: info)
                            let decision = policy.evaluate(info, candidates: indexed)
                            let evidence = matchingCandidates(decision, candidates: indexed)
                            _ = try await store.save(file, decision: decision, candidates: evidence)
                        } catch let error as SyncStoreError { throw error }
                        catch {
                            failed += 1
                            recordRoundFailure(roundID)
                            lastFailure = error.localizedDescription
                            setSourceIssue(sourceID, key: "scan", message: error.localizedDescription, runID: run, error: error)
                            logEvent(phase: "metadata", result: "failed", sourceID: sourceID, runID: run, path: entry.url.path, error: error)
                        }
                    }
                } catch let error as SyncStoreError { throw error }
                catch {
                    failed += 1
                    recordRoundFailure(roundID)
                    lastFailure = error.localizedDescription
                    setSourceIssue(sourceID, key: "scan", message: error.localizedDescription, runID: run, error: error)
                    logEvent(phase: "directory", result: "failed", sourceID: sourceID, runID: run, error: error)
                }
            }
            if let run {
                let complete = failed == 0 && canScan(sourceID: sourceID)
                try await store.finishScan(runID: run, now: Date(), complete: complete, checked: checked, failed: failed, error: lastFailure)
                if !complete { interruptRound(roundID) }
                if complete { resolveSourceIssue(sourceID, key: "scan", runID: run) }
                let result: String
                if status.isPaused {
                    result = "paused"
                } else if complete {
                    result = "completed"
                } else if disabledSources.contains(sourceID) {
                    result = "stopped"
                } else {
                    result = "failed"
                }
                logEvent(phase: "scan", result: result, sourceID: sourceID, runID: run)
            }
            startDrain(roundID: roundID)
        } catch {
            interruptRound(roundID)
            stopStorage(error)
        }
    }

    private func startDrain(roundID: UUID) {
        guard drainTask == nil, !status.isPaused, !storageFailed, status.blockingError == nil else { return }
        guard let sources = rounds[roundID]?.sources, !sources.isEmpty else { return }
        drainTask = Task { await self.drain(roundID: roundID, sources: sources); self.drainTask = nil }
    }

    private func drain(roundID: UUID, sources: Set<UUID>) async {
        do {
            var visited: Set<UUID> = []
            while !status.isPaused, !storageFailed, status.blockingError == nil {
                let records = try await allFiles(.pending)
                guard let record = records.first(where: { !visited.contains($0.id) && sources.contains($0.file.sourceID) }) else { break }
                visited.insert(record.id)
                let context = SubmissionContext(roundID: roundID, runID: runID(for: record.file.sourceID, roundID: roundID))
                guard canSubmit(sourceID: record.file.sourceID) else { continue }
                guard try await store.source(id: record.file.sourceID).enabled else { continue }
                if let retry = record.nextRetryAt, retry > Date() { continue }
                do {
                    let stamp = try await directory(record.file.sourceID).stamp(of: record.file.url)
                    guard stamp == record.file.stamp else {
                        try await store.recordSourceChange(fileID: record.id, stamp: stamp)
                        resolveSourceIssue(record.file.sourceID, key: issueKey(for: record.id), runID: context.runID, fileID: record.id)
                        continue
                    }
                } catch let error as SyncStoreError { throw error }
                catch {
                    let message = error.localizedDescription
                    recordRoundFailure(context.roundID)
                    setSourceIssue(record.file.sourceID, key: issueKey(for: record.id), message: message, runID: context.runID, fileID: record.id, error: error)
                    logEvent(phase: "submission-stamp", result: "failed", sourceID: record.file.sourceID, runID: context.runID, fileID: record.id, error: error)
                    try await store.recordRetry(fileID: record.id, attemptID: nil, nextRetry: nextRetry(for: record), error: message, definitelyNotCommitted: true)
                    if let run = context.runID { try await store.recordScanFailure(runID: run, error: message) }
                    continue
                }
                guard canSubmit(sourceID: record.file.sourceID) else { break }
                do { indexed = try await photos.loadCandidates() }
                catch {
                    recordRoundFailure(context.roundID)
                    setBlockingError(error.localizedDescription)
                    break
                }
                let local = try await store.candidates(filename: record.file.metadata.filename, excludingID: record.id, olderPendingOnly: true)
                guard canSubmit(sourceID: record.file.sourceID) else { break }
                let candidates = indexed + local
                let decision = policy.evaluate(record.file.metadata, candidates: candidates)
                if case .skip = decision {
                    try await store.markSkipped(fileID: record.id, reason: .suspectedDuplicate, candidates: matchingCandidates(decision, candidates: candidates))
                    resolveSourceIssue(record.file.sourceID, key: issueKey(for: record.id), runID: context.runID, fileID: record.id)
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
                    status.sourcePhases[record.file.sourceID] = "新增到照片"
                    defer { status.sourcePhases.removeValue(forKey: record.file.sourceID) }
                    let id = try await photos.create(fileURL: record.file.url, kind: record.file.metadata.kind) { identifier in
                        try store.checkpointPlaceholder(fileID: record.id, attemptID: attempt, identifier: identifier)
                    }
                    // Even pause or loss of library health cannot erase a committed callback.
                    try await store.markImported(fileID: record.id, attemptID: attempt, identifier: id)
                    indexed.append(MatchCandidate(key: id, metadata: record.file.metadata))
                    recordRoundImport(context.roundID)
                    resolveSourceIssue(record.file.sourceID, key: issueKey(for: record.id), runID: context.runID, fileID: record.id, attemptID: attempt)
                    logEvent(phase: "submission", result: "imported", sourceID: record.file.sourceID, runID: context.runID, fileID: record.id, attemptID: attempt)
                } catch let error as SyncStoreError { activeAttempt = nil; throw error }
                catch {
                    let definite = (error as? PhotoKitGatewayError)?.recoveryEvidence == .definitelyNotCommitted
                    try await store.recordRetry(fileID: record.id, attemptID: attempt, nextRetry: nextRetry(for: record), error: error.localizedDescription, definitelyNotCommitted: definite)
                    recordRoundFailure(context.roundID)
                    setSourceIssue(record.file.sourceID, key: issueKey(for: record.id), message: error.localizedDescription, runID: context.runID, fileID: record.id, attemptID: attempt, error: error)
                    logEvent(phase: "submission", result: "failed", sourceID: record.file.sourceID, runID: context.runID, fileID: record.id, attemptID: attempt, error: error)
                    // A gateway reporting unknown may still own a physical request. Keep this
                    // instance and stop submissions until its own lifecycle permits recovery.
                    if !definite {
                        uncertainSubmissions.insert(record.id)
                        uncertainSubmissionErrors[record.id] = error.localizedDescription
                        if let gatewayError = error as? PhotoKitGatewayError {
                            switch gatewayError {
                            case .resultUnknown(let message):
                                uncertainSubmissionHints[record.id] = .uncertainSubmission(message: message)
                            case .checkpointFailed(let message):
                                uncertainSubmissionHints[record.id] = .checkpointFailure(message: message)
                            default:
                                uncertainSubmissionHints.removeValue(forKey: record.id)
                            }
                        } else {
                            uncertainSubmissionHints.removeValue(forKey: record.id)
                        }
                        setUncertainSubmissionBlock()
                    }
                }
                activeAttempt = nil
            }
        } catch {
            activeAttempt = nil
            interruptRound(roundID)
            stopStorage(error)
        }
        await refreshSummary()
    }

    private func canSubmit(sourceID: UUID) -> Bool {
        !status.isPaused && !storageFailed && status.blockingError == nil && uncertainSubmissions.isEmpty && !disabledSources.contains(sourceID)
    }

    private func canScan(sourceID: UUID) -> Bool {
        !status.isPaused && !storageFailed && !disabledSources.contains(sourceID)
    }

    private func nextRetry(for record: StoredFile, now: Date = Date()) -> Date {
        now.addingTimeInterval(retryDelay(failureCount: record.retryCount + 1))
    }

    private func issueKey(for fileID: UUID) -> String { "file:\(fileID.uuidString)" }

    private func setSourceIssue(_ sourceID: UUID, key: String, message: String, runID: UUID? = nil, fileID: UUID? = nil, attemptID: UUID? = nil, error: Error?) {
        guard !removedSources.contains(sourceID) else { return }
        sourceIssues[sourceID, default: [:]][key] = message
        syncSourceIssueStatus(sourceID, runID: runID, fileID: fileID, attemptID: attemptID, error: error)
    }

    private func resolveSourceIssue(_ sourceID: UUID, key: String, runID: UUID? = nil, fileID: UUID? = nil, attemptID: UUID? = nil) {
        guard !removedSources.contains(sourceID) else { return }
        sourceIssues[sourceID]?.removeValue(forKey: key)
        if sourceIssues[sourceID]?.isEmpty == true { sourceIssues.removeValue(forKey: sourceID) }
        syncSourceIssueStatus(sourceID, runID: runID, fileID: fileID, attemptID: attemptID, error: nil)
    }

    private func syncSourceIssueStatus(_ sourceID: UUID, runID: UUID? = nil, fileID: UUID? = nil, attemptID: UUID? = nil, error: Error?) {
        guard !removedSources.contains(sourceID) else { return }
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
        notify(sourceID, false)
        logEvent(phase: "recovery", result: "waiting", sourceID: sourceID, runID: runID, fileID: fileID, attemptID: attemptID, error: error)
    }

    private func logSourceRecovered(_ sourceID: UUID, runID: UUID? = nil, fileID: UUID? = nil, attemptID: UUID? = nil) {
        guard reportedWaitingSources.remove(sourceID) != nil else { return }
        notify(sourceID, true)
        logEvent(phase: "recovery", result: "recovered", sourceID: sourceID, runID: runID, fileID: fileID, attemptID: attemptID)
    }

    private func clearRemovedSourceStatus(_ sourceID: UUID) {
        status.sourcePhases.removeValue(forKey: sourceID)
        status.waitingSources.removeValue(forKey: sourceID)
        sourceIssues.removeValue(forKey: sourceID)
        reportedWaitingSources.remove(sourceID)
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

    private func beginRound(sources: Set<UUID>) -> UUID {
        let id = UUID()
        let progress = ScanProgress(state: .running, startedAt: Date())
        rounds[id] = ScanRound(sources: sources, progress: progress)
        latestRoundID = id
        status.latestScan = progress
        return id
    }

    private func setRun(_ runID: UUID?, sourceID: UUID, roundID: UUID) {
        guard let runID, var round = rounds[roundID] else { return }
        round.runs[sourceID] = runID
        rounds[roundID] = round
    }

    private func runID(for sourceID: UUID, roundID: UUID) -> UUID? {
        rounds[roundID]?.runs[sourceID]
    }

    private func recordCandidateChecked(_ roundID: UUID) {
        updateRound(roundID) { $0.progress.checkedCandidates += 1 }
    }

    private func recordRoundImport(_ roundID: UUID) {
        updateRound(roundID) { $0.progress.newlyImported += 1 }
    }

    private func recordRoundFailure(_ roundID: UUID) {
        updateRound(roundID) {
            $0.progress.failed += 1
            $0.interrupted = true
        }
    }

    private func interruptRound(_ roundID: UUID) {
        updateRound(roundID) { $0.interrupted = true }
    }

    private func finishRound(_ roundID: UUID) {
        guard var round = rounds[roundID] else { return }
        let stoppedSource = round.sources.contains { disabledSources.contains($0) }
        round.progress.state = round.interrupted || stoppedSource || status.isPaused || storageFailed ? .interrupted : .completed
        round.progress.endedAt = Date()
        rounds[roundID] = round
        publish(round: round, id: roundID)
        rounds.removeValue(forKey: roundID)
    }

    private func updateRound(_ roundID: UUID, _ update: (inout ScanRound) -> Void) {
        guard var round = rounds[roundID] else { return }
        update(&round)
        rounds[roundID] = round
        publish(round: round, id: roundID)
    }

    private func publish(round: ScanRound, id: UUID) {
        guard latestRoundID == id else { return }
        status.latestScan = round.progress
    }

    private func refreshSummary() async {
        guard !storageFailed else { return }
        do {
            status.summary = try await store.activeSourceSummary()
            status.summaryError = nil
        } catch {
            status.summaryError = error.localizedDescription
            stopStorage(error)
        }
    }

    private func clearBlockingError() {
        status.blockingError = nil
        status.recoveryHint = nil
        hasUncertainSubmissionBlock = false
    }

    private func setBlockingError(_ message: String) {
        status.blockingError = message
        status.recoveryHint = nil
        hasUncertainSubmissionBlock = false
    }

    private func setUncertainSubmissionBlock() {
        hasUncertainSubmissionBlock = true
        let fileID = uncertainSubmissions.min { $0.uuidString < $1.uuidString }
        status.blockingError = fileID.flatMap { uncertainSubmissionErrors[$0] }
            ?? "A Photos submission from this session remains uncertain. Waiting for confirmation."
        status.recoveryHint = fileID.flatMap { uncertainSubmissionHints[$0] }
    }

    private func clearUncertainSubmissionBlockIfResolved() {
        guard uncertainSubmissions.isEmpty,
              hasUncertainSubmissionBlock else {
            return
        }
        clearBlockingError()
    }

    private func stopStorage(_ error: Error) {
        storageFailed = true
        status.blockingError = "Storage stopped: \(error.localizedDescription)"
        status.summaryError = error.localizedDescription
        status.recoveryHint = nil
        hasUncertainSubmissionBlock = false
        logger?.log(["error": error.localizedDescription, "scope": "storage"])
    }
}
