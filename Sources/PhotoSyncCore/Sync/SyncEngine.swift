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
    /// File-level failures in this round: unreadable entries and failed metadata reads.
    /// An unavailable source directory is not a file failure and is reported per source instead.
    public var failedFiles: Int
    /// Some work was left for a later attempt because a bounded read was refused or timed out.
    /// A deferred round is normal waiting, not a failure, so the menu says "稍后继续".
    public var deferred: Bool
    public var startedAt: Date?
    public var endedAt: Date?

    public init(
        state: ScanProgressState = .notStarted,
        checkedCandidates: Int = 0,
        newlyImported: Int = 0,
        failed: Int = 0,
        failedFiles: Int = 0,
        deferred: Bool = false,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        self.state = state
        self.checkedCandidates = checkedCandidates
        self.newlyImported = newlyImported
        self.failed = failed
        self.failedFiles = failedFiles
        self.deferred = deferred
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public enum EngineRecoveryHint: Equatable, Sendable {
    case uncertainSubmission(message: String)
    case checkpointFailure(message: String)
}

/// The operation that produced a source issue. Runtime scheduling uses this explicit distinction
/// so a bad file or an uncertain submission cannot quarantine an otherwise healthy source.
public enum SourceIssueKind: String, Equatable, Sendable {
    case sourceAvailability
    case file
    case submission
}

/// One problem worth telling a person about. `summary` is what the menu and notifications show —
/// plain language, no system error text. `detail` keeps the raw message for the journal, the scan
/// batch row and the menu tooltip, so nothing needed for support is lost.
public struct SourceIssue: Equatable, Sendable {
    public var summary: String
    public var detail: String
    public var kind: SourceIssueKind

    public init(summary: String, detail: String, kind: SourceIssueKind = .sourceAvailability) {
        self.summary = summary; self.detail = detail; self.kind = kind
    }

    public var isSourceAvailability: Bool { kind == .sourceAvailability }
}

/// One current diagnostic identity. Paths and stages are captured at failure time, without I/O.
public struct SourceIssueDetail: Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: SourceIssueKind
    public var path: String
    public var summary: String
    public var stage: String?
    public var detail: String

    public init(id: String, kind: SourceIssueKind, path: String, summary: String, stage: String?, detail: String) {
        self.id = id; self.kind = kind; self.path = path; self.summary = summary
        self.stage = stage; self.detail = detail
    }
}

private struct TrackedSourceIssue {
    var primary: SourceIssue
    var diagnostics: [String: SourceIssueDetail]
}

/// Wording for failures the engine can classify from the operation that failed. A missing volume
/// is not a mysterious file error to the person reading the menu: it is an unmounted disk or share.
enum SourceIssueText {
    static func directoryUnavailable(sourceURL: URL, failingURL: URL, isRoot: Bool, error: Error) -> SourceIssue {
        SourceIssue(summary: directorySummary(sourceURL: sourceURL, isRoot: isRoot, error: error),
                    detail: "\(failingURL.path): \(systemDiagnostic(error))",
                    kind: .sourceAvailability)
    }

    static func fileUnreadable(relativePath: String, url: URL, error: Error) -> SourceIssue {
        let isVideoMetadata = underlyingNSErrorChain(error).contains { $0.domain == "PhotoSync.VideoMetadata" }
        return SourceIssue(summary: readableSummary(subject: "文件", error: error) ?? (isVideoMetadata
            ? "视频元数据读取失败，具体原因尚无法确定。"
            : "文件暂时无法读取，具体原因尚无法确定。"),
            detail: "\(url.path): \(systemDiagnostic(error))", kind: .file)
    }

    static func entryUnreadable(url: URL, error: Error) -> SourceIssue {
        SourceIssue(summary: readableSummary(subject: "目录项", error: error) ?? "目录项暂时无法读取，具体原因尚无法确定。",
                    detail: "\(url.path): \(systemDiagnostic(error))", kind: .file)
    }

    private static func readableSummary(subject: String, error: Error) -> String? {
        for failure in underlyingNSErrorChain(error) {
            if (failure.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code)) ||
               (failure.domain == NSPOSIXErrorDomain && [Int(ENOENT), Int(ENOTDIR), Int(ENODEV)].contains(failure.code)) {
                return "\(subject)路径不可用，请检查磁盘或网络连接。"
            }
            if (failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoPermissionError) ||
               (failure.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(failure.code)) {
                return "\(subject)无法访问，请检查访问权限。"
            }
            if failure.domain == NSPOSIXErrorDomain,
               [Int(ENETDOWN), Int(ENETUNREACH), Int(ENOTCONN), Int(ECONNRESET), Int(ETIMEDOUT), Int(EPIPE), Int(EHOSTDOWN)].contains(failure.code) {
                return "\(subject)所在的网络共享连接已中断，恢复后会自动继续。"
            }
        }
        return nil
    }

    /// A stamp read happens before any Photos submission, so a failed one never leaves the import
    /// in doubt: the record stays pending and is attempted again.
    static func submissionStampFailed(error: Error) -> SourceIssue {
        SourceIssue(summary: "读取来源文件失败，尚未提交，稍后会自动重试。",
                    detail: error.localizedDescription, kind: .submission)
    }

    static let uncertainImport = "上次导入的结果尚未确认，已暂停新的导入。"
    static let checkpointFailure = "导入检查点保存失败，已暂停新的导入。"
    static let authorizationRequired = "未获“照片”读写权限，同步已暂停。请在设置中点“授权访问照片”。"
    static let libraryUnavailable = "无法读取系统照片图库，已暂停导入。"
    static let storageStopped = "本地数据库不可用，同步已停止。"

    static func blockingSummary(for error: Error) -> String {
        if let error = error as? PhotoKitGatewayError {
            switch error {
            case .authorizationRequired:
                return authorizationRequired
            case .libraryUnavailable, .libraryChanged:
                return libraryUnavailable
            case .checkpointFailed:
                return checkpointFailure
            case .resultUnknown:
                return uncertainImport
            case .definitelyNotCommitted:
                return "有文件导入失败，稍后会自动重试。"
            }
        }
        return libraryUnavailable
    }

    /// The bounded reader refuses a second concurrent read of one source, ends its own logical
    /// wait, or has no free slot. None of that found a problem: the work stays queued and comes
    /// back shortly, so these are the only read results the app treats as normal waiting instead
    /// of reporting them.
    static func isReadContention(_ error: Error) -> Bool {
        error is ReadExecutorError
    }

    private static func directorySummary(sourceURL: URL, isRoot: Bool, error: Error) -> String {
        let subject = isRoot ? "来源目录" : "部分子目录"
        if let configurationError = error as? SourceRegistryError {
            switch configurationError {
            case .aliasOrLink:
                return isRoot
                    ? "来源配置无效：不支持别名或符号链接，请重新选择实际文件夹。"
                    : "部分子目录包含不支持的别名或符号链接，已停止读取该目录。"
            case .notDirectory:
                return isRoot
                    ? "来源配置无效：所选路径不是文件夹，请重新选择来源目录。"
                    : "部分子目录不是有效文件夹，已停止读取该目录。"
            case .notFileURL:
                return isRoot
                    ? "来源配置无效：所选来源不是本地文件夹，请重新选择来源目录。"
                    : "部分子目录配置无效，已停止读取该目录。"
            case .overlappingSource:
                return isRoot
                    ? "来源配置无效：来源目录与已有目录重叠，请调整来源配置。"
                    : "部分子目录配置无效，已停止读取该目录。"
            }
        }
        // A network share that is not mounted is the most specific thing we can say about a root.
        if isRoot, let mount = missingMount(for: sourceURL) {
            return "所在磁盘或网络共享 \(mount) 未挂载；挂载后会自动继续同步。"
        }
        for nsError in underlyingNSErrorChain(error) {
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError {
                return "\(subject)不可用，正在等待恢复。请检查磁盘或网络连接。"
            }
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
                return "\(subject)无法访问，请检查访问权限；恢复后会自动继续。"
            }
            if nsError.domain == NSPOSIXErrorDomain,
               [Int(ENOENT), Int(ENOTDIR), Int(ENODEV)].contains(nsError.code) {
                return "\(subject)不可用，正在等待恢复。请检查磁盘或网络连接。"
            }
            if nsError.domain == NSPOSIXErrorDomain,
               [Int(EACCES), Int(EPERM)].contains(nsError.code) {
                return "\(subject)无法访问，请检查访问权限；恢复后会自动继续。"
            }
            if nsError.domain == NSPOSIXErrorDomain,
               [Int(ENETDOWN), Int(ENETUNREACH), Int(ENOTCONN), Int(ECONNRESET), Int(ETIMEDOUT), Int(EPIPE), Int(EHOSTDOWN)].contains(nsError.code) {
                return "\(subject)所在的网络共享连接已中断；恢复后会自动继续。"
            }
        }
        return "\(subject)暂时无法读取，正在等待恢复。"
    }

    /// Wrapped failures keep their cause in `NSUnderlyingErrorKey`; the outer error is often a
    /// generic transport error. Keep every available cause and stop at repeated objects.
    static func underlyingNSErrorChain(_ error: Error) -> [NSError] {
        var errors: [NSError] = []
        var seen: Set<ObjectIdentifier> = []
        var current: NSError? = error as NSError
        while let failure = current, seen.insert(ObjectIdentifier(failure)).inserted {
            errors.append(failure)
            current = failure.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return errors
    }

    static func systemDiagnostic(_ error: Error) -> String {
        underlyingNSErrorChain(error).map { "\($0.domain) \($0.code): \($0.localizedDescription)" }.joined(separator: " <- ")
    }

    /// `/Volumes/<name>` that the source path depends on but that does not exist right now.
    private static func missingMount(for url: URL) -> String? {
        let components = url.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return nil }
        let mount = "/" + components[1] + "/" + components[2]
        return FileManager.default.fileExists(atPath: mount) ? nil : mount
    }
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
    public var waitingSources: [UUID: SourceIssue] = [:]
    /// Migration aid for clients that consumed the pre-SourceIssue `[UUID: String]` view.
    /// New code should read `waitingSources[id]?.summary` and, when needed, `.detail`/`.kind`.
    @available(*, deprecated, message: "Use waitingSources and read SourceIssue.summary")
    public var waitingSourceSummaries: [UUID: String] {
        waitingSources.mapValues(\.summary)
    }
    /// Unresolved file-level scan issues per source. They are reported next to that source's
    /// primary message and disappear when the file is readable again or a clean scan completes.
    public var sourceFileIssueCounts: [UUID: Int] = [:]
    /// Current diagnostic identities, sorted by full path and ID. Empty sources have no key.
    /// An availability recovery marker may remain in waitingSources without any diagnostics.
    public var sourceIssueDetails: [UUID: [SourceIssueDetail]] = [:]
    /// Sources whose last round left work for a later attempt because a read was deferred. They
    /// are waiting, not failing: nothing is reported for them and they are retried within seconds.
    public var deferredSources: Set<UUID> = []
    /// Current advanced preparation wait, separate from source read failures.
    public var advancedWaitingReasons: [UUID: String] = [:]
    public var indexProgress: IndexProgress?
    /// Raw engine-level failure, kept for the journal and the menu tooltip.
    public var blockingError: String?
    /// Plain-language headline for `blockingError`, and the text a notification carries.
    public var blockingSummary: String?
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
    private let legacySkipReevaluation: LegacySkipReevaluation?
    private let advancedDedup: AdvancedDedupService?
    private let indexCoordinator: PhotosIndexCoordinator?
    private let requiresAdvancedDedup: Bool
    private let dedupConfiguration: DedupConfiguration?
    private let submissionState = EngineSubmissionState()
    private let policy: DuplicatePolicy
    private let logger: RunLogger?
    private let notify: @Sendable (UUID, Bool) -> Void
    /// Source transition notifications retain the compatibility callback above while this
    /// callback carries the classified human summary. `detail` is intentionally not sent here.
    private let notifySourceIssue: @Sendable (UUID, Bool, SourceIssue?) -> Void
    /// Announces a blocking problem that needs a person. Unlike `notify`, it carries the message.
    private let notifyIssue: @Sendable (String) -> Void
    private let now: @Sendable () -> Date
    private var status = EngineSnapshot() { didSet { refreshSubmissionState() } }
    private var scanning = false
    private var recovering = false
    private var storageFailed = false
    private var drainTask: Task<Void, Never>?
    private var activeAttempt: UUID?
    private var uncertainSubmissions: Set<UUID> = []
    private var uncertainSubmissionHints: [UUID: EngineRecoveryHint] = [:]
    private var uncertainSubmissionErrors: [UUID: String] = [:]
    private var hasUncertainSubmissionBlock = false
    private var disabledSources: Set<UUID> = [] { didSet { refreshSubmissionState() } }
    // Root admission is distinct from partial child-directory issues. Unknown roots
    // cannot feed the shared pending drain until actual enumeration succeeds.
    private var rootClosureRevisions: [UUID: UInt64] = [:]
    private var verifiedRoots: Set<UUID> = [] { didSet { refreshSubmissionState() } }
    private var unavailableRoots: [UUID: String] = [:] { didSet { refreshSubmissionState() } }
    private var removedSources: Set<UUID> = []
    private var rounds: [UUID: ScanRound] = [:]
    private var latestRoundID: UUID?
    private var reportedWaitingSources: Set<UUID> = []
    private var sourceIssues: [UUID: [String: TrackedSourceIssue]] = [:]
    /// One signature per source, phase, and file identity so an unchanged failure is not journaled every round.
    private var lastFailureLogSignatures: [String: String] = [:]
    // The single drain may await retry persistence while a scan resolves the same file.
    private var pendingStampFailureID: UUID?
    /// The blocking message already announced, so one unresolved block notifies once.
    private var lastNotifiedIssue: String?

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
                advancedDedup: AdvancedDedupService? = nil, indexCoordinator: PhotosIndexCoordinator? = nil,
                requiresAdvancedDedup: Bool = false, dedupConfiguration: DedupConfiguration? = nil, legacySkipReevaluation: LegacySkipReevaluation? = nil,
                notify: @escaping @Sendable (UUID, Bool) -> Void = { _, _ in },
                notifyIssue: @escaping @Sendable (String) -> Void = { _ in },
                notifySourceIssue: @escaping @Sendable (UUID, Bool, SourceIssue?) -> Void = { _, _, _ in },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.advancedDedup = advancedDedup; self.indexCoordinator = indexCoordinator
        self.requiresAdvancedDedup = requiresAdvancedDedup
        self.dedupConfiguration = dedupConfiguration
        self.legacySkipReevaluation = legacySkipReevaluation
        self.store = store; self.photos = photos; self.directory = directory
        self.metadata = metadata; self.policy = policy; self.logger = logger; self.notify = notify
        self.notifyIssue = notifyIssue; self.notifySourceIssue = notifySourceIssue
        self.now = now
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
        // A disabled source is not waiting for anything; its issues are re-detected if it returns.
        clearRemovedSourceStatus(id)
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
    /// P8 supplies the validated profile's batch limit and schedules this on its existing tick.
    /// Reopened rows enter the ordinary P6 drain; this operation never calls Photos create.
    /// Zero counts actual reopens, not completion: later bounded ticks must continue retries.
    @discardableResult
    public func processLegacySkips(limit: Int) async throws -> Int {
        guard !status.isPaused, !storageFailed, let legacySkipReevaluation else { return 0 }
        let reopened = try await legacySkipReevaluation.processBatch(limit: limit)
        await refreshSummary()
        return reopened
    }

    public func startupScan() async { await scanEnabledSources() }
    public func manualScan() async { await scanEnabledSources() }
    public func wakeScan() async { await scanEnabledSources() }
    public func setPaused(_ paused: Bool) async {
        status.isPaused = paused
        await legacySkipReevaluation?.setPaused(paused)
        await advancedDedup?.setPaused(status.isPaused)
    }
    public func pause() async {
        await setPaused(true)
        logEvent(phase: "scan", result: "paused")
    }
    public func resume() async {
        await setPaused(false)
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
        // A round that starts with nothing blocking is a clean slate: the same problem is
        // announced again only after it has actually gone away. `clearBlockingError` re-reads the
        // conditions every round, so clearing the message alone must not clear the announcement.
        if status.blockingError == nil { lastNotifiedIssue = nil }
        clearBlockingError()
        await recoverImports()
        if !uncertainSubmissions.isEmpty {
            setUncertainSubmissionBlock()
        }
        guard !storageFailed, status.blockingError == nil else {
            scanning = false
            await refreshSummary()
            finishRound(roundID)
            return
        }
        let photoSnapshot: PhotosCandidateSnapshot
        do { photoSnapshot = try await photos.candidateSnapshot() }
        catch {
            setBlockingError(error.localizedDescription, summary: SourceIssueText.blockingSummary(for: error))
            interruptRound(roundID)
            scanning = false
            await refreshSummary()
            finishRound(roundID)
            return
        }
        await withTaskGroup(of: Void.self) { group in
            for sourceID in sources {
                group.addTask {
                    await self.scanSource(sourceID, roundID: roundID, photosSnapshot: photoSnapshot)
                }
            }
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
                        resolveSourceIssue(record.file.sourceID, key: issueKey(for: record.id), fileID: record.id)
                    case .definitelyNotCommitted:
                        try await store.recordRetry(fileID: record.id, attemptID: attempt, nextRetry: now(), error: "Confirmed not committed", definitelyNotCommitted: true)
                        uncertainSubmissions.remove(record.id)
                        uncertainSubmissionHints.removeValue(forKey: record.id)
                        uncertainSubmissionErrors.removeValue(forKey: record.id)
                        clearUncertainSubmissionBlockIfResolved()
                        resolveSourceIssue(record.file.sourceID, key: issueKey(for: record.id), fileID: record.id)
                    case .unknown:
                        setSourceIssue(record.file.sourceID, key: issueKey(for: record.id),
                                       issue: SourceIssue(summary: SourceIssueText.uncertainImport,
                                                          detail: "An earlier Photos import is awaiting confirmation.", kind: .submission),
                                       path: record.file.url.path, stage: "核对导入结果", fileID: record.id, attemptID: attempt, error: nil)
                    }
                } catch let error as SyncStoreError { throw error }
                catch {
                    if let gatewayError = error as? PhotoKitGatewayError,
                       gatewayError == .authorizationRequired {
                        setBlockingError(error.localizedDescription, summary: SourceIssueText.authorizationRequired)
                    } else {
                        setSourceIssue(record.file.sourceID, key: issueKey(for: record.id),
                                       issue: SourceIssue(summary: SourceIssueText.uncertainImport, detail: error.localizedDescription, kind: .submission),
                                       path: record.file.url.path, stage: "核对导入结果", fileID: record.id, attemptID: attempt, error: error)
                    }
                }
            }
        } catch { stopStorage(error) }
    }

    private func scanSource(_ sourceID: UUID, roundID: UUID, photosSnapshot: PhotosCandidateSnapshot) async {
        status.sourcePhases[sourceID] = "扫描目录与元数据"
        status.deferredSources.remove(sourceID)
        status.advancedWaitingReasons.removeValue(forKey: sourceID)
        defer { status.sourcePhases.removeValue(forKey: sourceID) }
        var checked = 0, failed = 0
        var run: UUID?
        do {
            let source = try await store.source(id: sourceID)
            guard source.enabled, canScan(sourceID: sourceID) else { return }
            run = try await store.beginScan(sourceID: sourceID, now: now())
            setRun(run, sourceID: sourceID, roundID: roundID)
            logEvent(phase: "scan", result: "started", sourceID: sourceID, runID: run)
            let reader = directory(sourceID)
            let metadataReader = metadata(sourceID)
            var directories: [(url: URL, relative: String)] = [(source.url, "")]
            // Only an exhaustive traversal may retire pending files absent from the source.
            var unseenPending = try await store.pendingPaths(sourceID: sourceID)
            // Failed metadata may have no stored row. Track only old diagnostics for absence
            // reconciliation, using this traversal's observations and no additional I/O.
            var unseenScanIssueKeys = Set(sourceIssues[sourceID]?.keys.filter { $0.hasPrefix("scan:file:") } ?? [])
            var directoryTraversalComplete = true
            var lastFailure: String?
            scanLoop: while !directories.isEmpty, canScan(sourceID: sourceID) {
                let folder = directories.removeFirst()
                guard folder.relative.isEmpty || canReadSource(sourceID) else {
                    directoryTraversalComplete = false
                    break scanLoop
                }
                let rootClosureRevision = rootClosureRevisions[sourceID, default: 0]
                do {
                    let entries = try await reader.entries(in: folder.url)
                    guard canScan(sourceID: sourceID) else {
                        directoryTraversalComplete = false
                        break scanLoop
                    }
                    if folder.relative.isEmpty {
                        guard rootClosureRevision == rootClosureRevisions[sourceID, default: 0] else {
                            directoryTraversalComplete = false
                            break scanLoop
                        }
                        verifiedRoots.insert(sourceID)
                        unavailableRoots.removeValue(forKey: sourceID)
                    }
                    guard canReadSource(sourceID) else { directoryTraversalComplete = false; break scanLoop }
                    resolveDirectoryDiagnostic(sourceID, path: folder.url.path, runID: run)
                    for entry in entries {
                        guard canReadSource(sourceID) else {
                            directoryTraversalComplete = false
                            break scanLoop
                        }
                        let relative = folder.relative + entry.url.lastPathComponent
                        unseenScanIssueKeys.remove(fileScanIssueKey(relative))
                        if entry.isDirectory {
                            resolveSourceIssue(sourceID, key: fileScanIssueKey(relative), runID: run)
                            directories.append((entry.url, relative + "/"))
                            continue
                        }
                        unseenPending.removeValue(forKey: relative)
                        let classification = MetadataReader.classification(entry.url)
                        if let failure = entry.failure {
                            // Resource attributes failed before the reader knew whether this
                            // entry was a file or a directory. Its descendants may be unvisited.
                            directoryTraversalComplete = false
                            if try await holdSourceIfRootUnavailable(source, reader: reader, roundID: roundID, runID: run) {
                                break scanLoop
                            }
                            if classification == "image" || classification == "video" {
                                checked += 1
                                recordCandidateChecked(roundID)
                            }
                            failed += 1
                            recordRoundFailure(roundID, fileLevel: true)
                            lastFailure = failure
                            let entryError = entry.failureCause ?? NSError(domain: "PhotoSync.DirectoryEntry", code: 1, userInfo: [NSLocalizedDescriptionKey: failure])
                            setSourceIssue(sourceID, key: fileScanIssueKey(relative),
                                           issue: SourceIssueText.entryUnreadable(url: entry.url, error: entryError),
                                           path: entry.url.path, stage: "读取目录项属性", runID: run, error: entryError)
                            logFailureOnce(phase: "metadata", sourceID: sourceID, keyPath: relative, runID: run, path: entry.url.path, stage: "读取目录项属性", error: entryError)
                            continue
                        }
                        guard classification == "image" || classification == "video" else {
                            resolveSourceIssue(sourceID, key: fileScanIssueKey(relative), runID: run)
                            logEvent(phase: "classification", result: classification, sourceID: sourceID, runID: run, path: entry.url.path)
                            continue
                        }
                        checked += 1
                        recordCandidateChecked(roundID)
                        var readStage = "读取文件属性"
                        do {
                            let stamp = try await reader.stamp(of: entry.url)
                            guard canReadSource(sourceID) else {
                                directoryTraversalComplete = false
                                break scanLoop
                            }
                            if let old = try await store.file(sourceID: sourceID, relativePath: relative) {
                                guard canReadSource(sourceID) else {
                                    directoryTraversalComplete = false
                                    break scanLoop
                                }
                                // The store reads and updates under one transaction, so a
                                // submission that began after this snapshot keeps its identity.
                                if old.file.stamp != stamp {
                                    let changed = try await store.recordSourceChange(fileID: old.id, stamp: stamp)
                                    if changed {
                                        resolveSourceIssue(sourceID, key: issueKey(for: old.id), runID: run, fileID: old.id)
                                    }
                                }
                                resolveSourceIssue(sourceID, key: fileScanIssueKey(relative), runID: run, fileID: old.id)
                                continue
                            }
                            readStage = "读取媒体元数据"
                            let info = try await metadataReader.read(url: entry.url, filename: entry.url.lastPathComponent)
                            guard canReadSource(sourceID) else {
                                directoryTraversalComplete = false
                                break scanLoop
                            }
                            let file = SourceFile(sourceID: sourceID, relativePath: relative, url: entry.url, stamp: stamp, metadata: info)
                            try await saveScannedFile(file, initialSnapshot: photosSnapshot)
                            resolveSourceIssue(sourceID, key: fileScanIssueKey(relative), runID: run)
                        } catch let error as SyncStoreError { throw error }
                        catch let error as PhotoKitGatewayError {
                            lastFailure = error.localizedDescription
                            recordRoundFailure(roundID)
                            setBlockingError(error.localizedDescription, summary: SourceIssueText.blockingSummary(for: error))
                            directoryTraversalComplete = false
                            break scanLoop
                        }
                        catch {
                            guard canReadSource(sourceID) else {
                                directoryTraversalComplete = false
                                break scanLoop
                            }
                            if SourceIssueText.isReadContention(error) {
                                // Bounded-reader contention is queue pressure, not a bad file.
                                // Leave all persisted scan-run failure fields untouched.
                                recordDeferral(roundID, sourceID: sourceID)
                            } else {
                                if try await holdSourceIfRootUnavailable(source, reader: reader, roundID: roundID, runID: run) {
                                    directoryTraversalComplete = false
                                    break scanLoop
                                }
                                failed += 1
                                lastFailure = error.localizedDescription
                                recordRoundFailure(roundID, fileLevel: true)
                                setSourceIssue(sourceID, key: fileScanIssueKey(relative),
                                               issue: SourceIssueText.fileUnreadable(relativePath: relative, url: entry.url, error: error),
                                               path: entry.url.path, stage: MetadataReader.videoMetadataStage(error) ?? readStage, runID: run, error: error)
                                logFailureOnce(phase: "metadata", sourceID: sourceID, keyPath: relative, runID: run, path: entry.url.path, stage: MetadataReader.videoMetadataStage(error) ?? readStage, error: error)
                            }
                        }
                    }
                } catch let error as SyncStoreError { throw error }
                catch {
                    directoryTraversalComplete = false
                    guard canScan(sourceID: sourceID) else { break scanLoop }
                    if SourceIssueText.isReadContention(error) {
                        if folder.relative.isEmpty { closeRootAdmission(sourceID) }
                        recordDeferral(roundID, sourceID: sourceID)
                    } else {
                        if !folder.relative.isEmpty,
                           try await holdSourceIfRootUnavailable(source, reader: reader, roundID: roundID, runID: run) {
                            break scanLoop
                        }
                        failed += 1
                        lastFailure = error.localizedDescription
                        recordRoundFailure(roundID)
                        if folder.relative.isEmpty {
                            recordRootUnavailable(source, runID: run, error: error)
                            break scanLoop
                        }
                        setSourceIssue(sourceID, key: Self.directoryScanIssueKey,
                                       issue: SourceIssueText.directoryUnavailable(sourceURL: source.url, failingURL: folder.url,
                                                                                   isRoot: false, error: error),
                                       path: folder.url.path, stage: "枚举目录", runID: run, error: error)
                        logFailureOnce(phase: "directory", sourceID: sourceID, runID: run, path: folder.url.path, stage: "枚举目录", error: error)
                    }
                }
            }
            if !directories.isEmpty || !canReadSource(sourceID) {
                directoryTraversalComplete = false
            }
            if directoryTraversalComplete && directories.isEmpty && canReadSource(sourceID) {
                // File metadata failures do not make directory enumeration incomplete. A missing
                // pending file is normal source deletion only after every directory answered.
                for (relative, fileID) in unseenPending.sorted(by: { $0.key < $1.key }) {
                    guard canReadSource(sourceID) else { break }
                    if try await store.removeConfirmedAbsentPending(fileID: fileID) {
                        resolveSourceIssue(sourceID, key: issueKey(for: fileID), runID: run,
                                           fileID: fileID, announceRecovery: false)
                        resolveSourceIssue(sourceID, key: fileScanIssueKey(relative), runID: run,
                                           announceRecovery: false)
                        logEvent(phase: "source-file", result: "deleted", sourceID: sourceID, runID: run,
                                 fileID: fileID, path: source.url.appendingPathComponent(relative).path)
                    }
                }
                // Absence of an unstored failed file is proven only by a complete, non-deferred
                // round. Normal deletion closes its diagnostic without a recovery notification.
                if canReadSource(sourceID), !status.deferredSources.contains(sourceID) {
                    for key in unseenScanIssueKeys.sorted() {
                        resolveSourceIssue(sourceID, key: key, runID: run, announceRecovery: false)
                    }
                }
                if canReadSource(sourceID) {
                    resolveSourceIssue(sourceID, key: Self.directoryScanIssueKey, runID: run)
                }
            }
            if let run {
                let deferred = status.deferredSources.contains(sourceID)
                let complete = failed == 0 && canReadSource(sourceID)
                try await store.finishScan(runID: run, now: now(), complete: complete, checked: checked, failed: failed, error: lastFailure)
                if !complete { interruptRound(roundID) }
                // The drain can learn root loss while finishScan suspends this actor.
                // A completed traversal must not erase that newer outage or normal wait.
                if complete && !deferred && canReadSource(sourceID) && verifiedRoots.contains(sourceID)
                    && !status.deferredSources.contains(sourceID) {
                    resolveScanIssues(sourceID, runID: run)
                    status.deferredSources.remove(sourceID)
                    status.advancedWaitingReasons.removeValue(forKey: sourceID)
                }
                let result: String
                if status.isPaused {
                    result = "paused"
                } else if deferred {
                    result = "deferred"
                } else if complete {
                    result = "completed"
                } else if disabledSources.contains(sourceID) {
                    result = "stopped"
                } else {
                    result = "failed"
                }
                if result == "failed" {
                    logFailureOnce(phase: "scan", sourceID: sourceID, runID: run)
                } else {
                    logEvent(phase: "scan", result: result, sourceID: sourceID, runID: run)
                }
            }
            startDrain(roundID: roundID)
        } catch {
            interruptRound(roundID)
            stopStorage(error)
        }
    }

    private static let snapshotCommitAttempts = 3

    private func saveScannedFile(_ file: SourceFile, initialSnapshot: PhotosCandidateSnapshot) async throws {
        if file.metadata.kind == .image && usesAdvancedDedup {
            _ = try await store.save(file, decision: .importNew)
            return
        }
        var photoSnapshot = initialSnapshot
        var localCandidates = try await store.candidates(filename: file.metadata.filename, excludingID: nil)
        var candidates = photoSnapshot.candidates(named: file.metadata.filename) + localCandidates
        var decision = policy.evaluate(file.metadata, candidates: candidates)
        var evidence = matchingCandidates(decision, candidates: candidates)
        var latestSnapshotChecked = false
        var refreshLocalCandidates = false
        var staleAttempts = 0

        while true {
            if case .skip = decision {
                if !latestSnapshotChecked {
                    let latestSnapshot = try await photos.candidateSnapshot()
                    let generationChanged = latestSnapshot.generation != photoSnapshot.generation
                    photoSnapshot = latestSnapshot
                    if generationChanged || refreshLocalCandidates {
                        localCandidates = try await store.candidates(filename: file.metadata.filename, excludingID: nil)
                        candidates = photoSnapshot.candidates(named: file.metadata.filename) + localCandidates
                        decision = policy.evaluate(file.metadata, candidates: candidates)
                        evidence = matchingCandidates(decision, candidates: candidates)
                    }
                    latestSnapshotChecked = true
                    refreshLocalCandidates = false
                    if case .importNew = decision { continue }
                }

                switch try await store.saveWithSnapshotValidity(
                    file,
                    decision: decision,
                    candidates: evidence,
                    validity: photoSnapshot.candidateValidity
                ) {
                case .committed:
                    return
                case .staleSnapshot:
                    staleAttempts += 1
                    guard staleAttempts < Self.snapshotCommitAttempts else {
                        throw PhotoKitGatewayError.libraryChanged
                    }
                    latestSnapshotChecked = false
                    refreshLocalCandidates = true
                    continue
                }
            } else {
                _ = try await store.save(file, decision: decision, candidates: evidence)
                return
            }
        }
    }

    private func startDrain(roundID: UUID) {
        guard drainTask == nil, !status.isPaused, !storageFailed, status.blockingError == nil else { return }
        guard let sources = rounds[roundID]?.sources, !sources.isEmpty else { return }
        drainTask = Task { await self.drain(roundID: roundID, sources: sources); self.drainTask = nil }
    }

    private func drain(roundID: UUID, sources: Set<UUID>) async {
        do {
            var cursor: Int64?
            drainLoop: while !status.isPaused, !storageFailed, status.blockingError == nil {
                guard let record = try await store.nextPendingFile(sourceIDs: sources, afterOrder: cursor) else { break }
                // Advance before any await so one round cannot revisit a future-retry or
                // temporarily blocked row. The next nil-cursor drain handles recovered rows.
                cursor = record.createdOrder
                let context = SubmissionContext(roundID: roundID, runID: runID(for: record.file.sourceID, roundID: roundID))
                guard canSubmit(sourceID: record.file.sourceID) else { continue }
                let source = try await store.source(id: record.file.sourceID)
                guard source.enabled, canSubmit(sourceID: source.id) else { continue }
                if let retry = record.nextRetryAt, retry > now() { continue }
                do {
                    let stamp = try await directory(record.file.sourceID).stamp(of: record.file.url)
                    guard stamp == record.file.stamp else {
                        let changed: Bool
                        do { changed = try await store.recordSourceChange(fileID: record.id, stamp: stamp) }
                        catch let error as SyncStoreError {
                            switch error {
                            case .notFound, .invalidTransition:
                                guard try await pendingRecordWasSuperseded(record) else { throw error }
                                continue drainLoop
                            default: throw error
                            }
                        }
                        if changed {
                            resolveSourceIssue(record.file.sourceID, key: issueKey(for: record.id), runID: context.runID, fileID: record.id)
                        }
                        continue
                    }
                } catch let error as SyncStoreError { throw error }
                catch {
                    if SourceIssueText.isReadContention(error) {
                        // The stamp is read before any Photos request. A contention result is
                        // ordinary queueing: keep the pending row byte-for-byte equivalent and
                        // let the independent source deferral schedule bring it back.
                        recordDeferral(context.roundID, sourceID: record.file.sourceID)
                    } else {
                        if try await holdSourceIfRootUnavailable(source, reader: directory(source.id),
                                                                 roundID: context.roundID, runID: context.runID) {
                            continue
                        }
                        let message = error.localizedDescription
                        // Nothing was submitted. A concurrent scan may supersede this file
                        // during either the stamp read or retry write. Reserve publication
                        // before awaiting, so a matching resolution can cancel the late issue.
                        pendingStampFailureID = record.id
                        defer { pendingStampFailureID = nil }
                        do {
                            try await store.recordRetry(fileID: record.id, attemptID: nil, nextRetry: nextRetry(for: record), error: message, definitelyNotCommitted: true)
                        } catch let error as SyncStoreError {
                            guard case .invalidTransition = error else { throw error }
                            guard try await pendingRecordWasSuperseded(record) else { throw error }
                            // A completed or deleted row needs no further submission from this
                            // stale drain cursor. Deletion already clears its in-memory issue.
                            continue
                        }
                        guard pendingStampFailureID == record.id else { continue }
                        recordRoundFailure(context.roundID)
                        setSourceIssue(record.file.sourceID, key: issueKey(for: record.id),
                                       issue: SourceIssueText.submissionStampFailed(error: error),
                                       path: record.file.url.path, stage: "提交前读取来源文件", runID: context.runID, fileID: record.id, error: error)
                        logFailureOnce(phase: "submission-stamp", sourceID: record.file.sourceID,
                                       keyPath: record.file.relativePath, runID: context.runID,
                                       fileID: record.id, path: record.file.url.path, stage: "提交前读取来源文件", error: error)
                        if let run = context.runID { try await store.recordScanFailure(runID: run, error: message) }
                    }
                    continue
                }
                guard canSubmit(sourceID: record.file.sourceID) else { continue drainLoop }
                var photoSnapshot: PhotosCandidateSnapshot
                var advanced: AdvancedPreparation?
                if record.file.metadata.kind == .image && usesAdvancedDedup {
                    guard let advancedDedup, indexCoordinator != nil else {
                        recordAdvancedWait("照片判重组件尚未就绪。", record: record, context: context)
                        continue
                    }
                    let preparation: AdvancedPreparation
                    do { preparation = try await advancedDedup.prepare(fileID: record.id, file: record.file) }
                    catch let error as SyncStoreError { throw error }
                    catch {
                        if SourceIssueText.isReadContention(error) {
                            recordDeferral(context.roundID, sourceID: source.id)
                            continue
                        }
                        if try await holdSourceIfRootUnavailable(source, reader: directory(source.id),
                                                                 roundID: context.roundID, runID: context.runID) {
                            continue
                        }
                        // Preparation is still known not to have sent a Photos request.
                        // Share the single drain reservation so source-change resolution
                        // during retry persistence cancels this failure publication too.
                        pendingStampFailureID = record.id
                        defer { pendingStampFailureID = nil }
                        do {
                            try await store.recordRetry(fileID: record.id, attemptID: nil, nextRetry: nextRetry(for: record),
                                                        error: error.localizedDescription, definitelyNotCommitted: true)
                        } catch let storeError as SyncStoreError {
                            guard case .invalidTransition = storeError,
                                  try await pendingRecordWasSuperseded(record) else { throw storeError }
                            continue
                        }
                        guard pendingStampFailureID == record.id else { continue }
                        guard canSubmit(sourceID: record.file.sourceID) else { continue }
                        recordRoundFailure(context.roundID)
                        setSourceIssue(record.file.sourceID, key: issueKey(for: record.id),
                            issue: SourceIssueText.submissionStampFailed(error: error), path: record.file.url.path,
                            stage: "准备照片判重", runID: context.runID, fileID: record.id, error: error)
                        continue
                    }
                    guard canSubmit(sourceID: record.file.sourceID) else { continue }
                    switch preparation {
                    case .waiting(let reason):
                        recordAdvancedWait(reason, record: record, context: context)
                        continue
                    case .ready(let admission):
                        if admission.evidence.evaluation.action == .skip {
                            let admissionStarted = ProcessInfo.processInfo.systemUptime
                            if try await store.commitAdvancedSkip(admission) {
                                logAdvancedDecision(.ready(admission), timings: ["databaseAdmission": (ProcessInfo.processInfo.systemUptime - admissionStarted) * 1000])
                                resolveSourceIssue(record.file.sourceID, key: issueKey(for: record.id), runID: context.runID, fileID: record.id)
                            } else { recordAdvancedWait("照片判重依据已变化，稍后继续。", record: record, context: context) }
                            continue
                        }
                        photoSnapshot = PhotosCandidateSnapshot(generation: admission.evidence.token.photosGeneration, candidates: [])
                    case .conservative(let admission):
                        photoSnapshot = PhotosCandidateSnapshot(generation: admission.evidence.token.photosGeneration, candidates: [])
                    }
                    advanced = preparation
                } else {
                    do { photoSnapshot = try await photos.candidateSnapshot() }
                    catch {
                        recordRoundFailure(context.roundID)
                        setBlockingError(error.localizedDescription, summary: SourceIssueText.blockingSummary(for: error))
                        break
                    }
                    var local = try await store.candidates(filename: record.file.metadata.filename, excludingID: record.id, olderPendingOnly: true)
                    guard canSubmit(sourceID: record.file.sourceID) else { continue drainLoop }
                    var candidates = photoSnapshot.candidates(named: record.file.metadata.filename) + local
                    var decision = policy.evaluate(record.file.metadata, candidates: candidates)
                    var evidence = matchingCandidates(decision, candidates: candidates)
                    var staleAttempts = 0
                    while true {
                        if case .skip = decision {
                            let skipResult: SnapshotCommitResult
                            do {
                                skipResult = try await store.markSkippedWithSnapshotValidity(
                                    fileID: record.id,
                                    reason: .suspectedDuplicate,
                                    candidates: evidence,
                                    validity: photoSnapshot.candidateValidity
                                )
                            } catch let error as SyncStoreError {
                                guard case .invalidTransition = error,
                                      try await pendingRecordWasSuperseded(record) else { throw error }
                                continue drainLoop
                            }
                            switch skipResult {
                            case .committed:
                                resolveSourceIssue(record.file.sourceID, key: issueKey(for: record.id), runID: context.runID, fileID: record.id)
                                continue drainLoop
                            case .staleSnapshot:
                                staleAttempts += 1
                                guard staleAttempts < Self.snapshotCommitAttempts else {
                                    recordRoundFailure(context.roundID)
                                    setBlockingError(PhotoKitGatewayError.libraryChanged.localizedDescription,
                                                     summary: SourceIssueText.blockingSummary(for: PhotoKitGatewayError.libraryChanged))
                                    break drainLoop
                                }
                                do { photoSnapshot = try await photos.candidateSnapshot() }
                                catch {
                                    recordRoundFailure(context.roundID)
                                    setBlockingError(error.localizedDescription, summary: SourceIssueText.blockingSummary(for: error))
                                    break drainLoop
                                }
                                local = try await store.candidates(filename: record.file.metadata.filename, excludingID: record.id, olderPendingOnly: true)
                                candidates = photoSnapshot.candidates(named: record.file.metadata.filename) + local
                                decision = policy.evaluate(record.file.metadata, candidates: candidates)
                                evidence = matchingCandidates(decision, candidates: candidates)
                                continue
                            }
                        }
                        break
                    }
                }
                guard canSubmit(sourceID: record.file.sourceID) else { continue drainLoop }
                guard try await store.source(id: record.file.sourceID).enabled else { continue }
                guard canSubmit(sourceID: record.file.sourceID) else { continue drainLoop }
                let attempt = UUID()
                activeAttempt = attempt
                do {
                    let admissionStarted = ProcessInfo.processInfo.systemUptime
                    let admitted: Bool
                    switch advanced {
                    case .ready(let admission): admitted = try await store.beginAdvancedAttempt(admission, attemptID: attempt)
                    case .conservative(let admission): admitted = try await store.beginAdvancedAttempt(admission, attemptID: attempt)
                    default:
                        try await store.beginAttempt(fileID: record.id, attemptID: attempt)
                        admitted = true
                    }
                    if admitted, let advanced { logAdvancedDecision(advanced, timings: ["databaseAdmission": (ProcessInfo.processInfo.systemUptime - admissionStarted) * 1000]) }
                    guard admitted else {
                        activeAttempt = nil
                        recordAdvancedWait("照片判重依据已变化，稍后继续。", record: record, context: context)
                        continue
                    }
                } catch let error as SyncStoreError {
                    guard case .invalidTransition = error else { throw error }
                    guard try await pendingRecordWasSuperseded(record) else { throw error }
                    activeAttempt = nil
                    continue
                }
                let enabled = try await store.source(id: record.file.sourceID).enabled
                guard enabled, canSubmit(sourceID: record.file.sourceID) else {
                    // A durable attempt exists, but no Photos request has been dispatched.
                    if advanced != nil {
                        try await deferAdvancedAttempt(record, attempt: attempt, context: context)
                    } else {
                        try await store.recordRetry(fileID: record.id, attemptID: attempt, nextRetry: now(), error: "Submission stopped before dispatch", definitelyNotCommitted: true)
                    }
                    activeAttempt = nil
                    continue
                }
                do {
                    let submissionStarted = ProcessInfo.processInfo.systemUptime
                    defer {
                        if advanced != nil {
                            logger?.log(["phase": "advanced-submission-timing", "file": record.id.uuidString,
                                "attempt": attempt.uuidString, "timingMS.nativeSubmissionWait": String((ProcessInfo.processInfo.systemUptime - submissionStarted) * 1000)])
                        }
                    }
                    let store = self.store
                    status.sourcePhases[record.file.sourceID] = "新增到照片"
                    defer { status.sourcePhases.removeValue(forKey: record.file.sourceID) }
                    let id: String
                    let checkpoint: @Sendable (String) throws -> Void = { identifier in
                        try store.checkpointPlaceholder(fileID: record.id, attemptID: attempt, identifier: identifier)
                    }
                    if let advanced {
                        let validity: any PhotosCandidateValidity
                        switch advanced {
                        case .ready(let admission): validity = admission.validity
                        case .conservative(let admission): validity = admission.validity
                        case .waiting: preconditionFailure("Waiting preparation cannot begin an attempt")
                        }
                        let state = submissionState
                        id = try await photos.create(fileURL: record.file.url, kind: record.file.metadata.kind,
                            expectedGeneration: photoSnapshot.generation, beforeMutation: {
                                guard state.allows(record.file.sourceID) else { return false }
                                // One inline probe belongs to the native submission's physical
                                // lifetime. No detached read, DB/Photos/state lock, or logical
                                // timeout can release this submission while the OS call lives.
                                guard try Self.physicalStampMatches(record.file),
                                      try store.advancedAttemptIsCurrentSynchronously(fileID: record.id, attemptID: attempt),
                                      state.allows(record.file.sourceID) else { return false }
                                // Queue has been released before taking Photos validity.
                                return try validity.commitIfCurrent({})
                            }, onPlaceholder: checkpoint)
                    } else {
                        id = try await photos.create(fileURL: record.file.url, kind: record.file.metadata.kind,
                            expectedGeneration: photoSnapshot.generation, onPlaceholder: checkpoint)
                    }
                    // Even pause or loss of library health cannot erase a committed callback.
                    try await store.markImported(fileID: record.id, attemptID: attempt, identifier: id)
                    recordRoundImport(context.roundID)
                    resolveSourceIssue(record.file.sourceID, key: issueKey(for: record.id), runID: context.runID, fileID: record.id, attemptID: attempt)
                    logEvent(phase: "submission", result: "imported", sourceID: record.file.sourceID, runID: context.runID, fileID: record.id, attemptID: attempt)
                } catch is PhotosAdmissionDeferred {
                    // Only the gateway's explicit no-mutation outcome reaches this
                    // path. Never infer it from a stale token on an in-flight call.
                    try await deferAdvancedAttempt(record, attempt: attempt, context: context)
                } catch let error as SyncStoreError { activeAttempt = nil; throw error }
                catch {
                    let definite = (error as? PhotoKitGatewayError)?.recoveryEvidence == .definitelyNotCommitted
                    try await store.recordRetry(fileID: record.id, attemptID: attempt, nextRetry: nextRetry(for: record), error: error.localizedDescription, definitelyNotCommitted: definite)
                    recordRoundFailure(context.roundID)
                    setSourceIssue(record.file.sourceID, key: issueKey(for: record.id),
                                   issue: SourceIssue(summary: definite ? "有文件导入失败，稍后会自动重试。" : SourceIssueText.uncertainImport,
                                                      detail: error.localizedDescription, kind: .submission),
                                   path: record.file.url.path, stage: "提交导入", runID: context.runID, fileID: record.id, attemptID: attempt, error: error)
                    logEvent(phase: "submission", result: "failed", sourceID: record.file.sourceID, runID: context.runID,
                             fileID: record.id, attemptID: attempt, path: record.file.url.path, error: error,
                             detail: "提交导入: \(SourceIssueText.systemDiagnostic(error))")
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

    private func pendingRecordWasSuperseded(_ record: StoredFile) async throws -> Bool {
        let current = try await store.file(sourceID: record.file.sourceID,
                                           relativePath: record.file.relativePath)
        // An importing row may own an unknown Photos result and must remain blocking.
        // Only deletion, replacement, or an already terminal row supersedes this cursor.
        return current == nil || current?.id != record.id ||
            current?.state == .skipped || current?.state == .imported
    }

    private func deferAdvancedAttempt(_ record: StoredFile, attempt: UUID, context: SubmissionContext) async throws {
        try await store.deferAdvancedAttempt(fileID: record.id, attemptID: attempt,
            nextRetry: now().addingTimeInterval(sourceDeferralDelay(count: 1)))
        recordAdvancedWait("照片判重依据已变化或同步已暂停，稍后继续。", record: record, context: context)
    }

    private var usesAdvancedDedup: Bool {
        requiresAdvancedDedup || advancedDedup != nil || indexCoordinator != nil
    }

    private func refreshSubmissionState() {
        submissionState.update(paused: status.isPaused,
            blocked: storageFailed || status.blockingError != nil || !uncertainSubmissions.isEmpty,
            disabled: disabledSources.union(unavailableRoots.keys), verified: verifiedRoots)
    }

    private func recordAdvancedWait(_ reason: String, record: StoredFile, context: SubmissionContext) {
        guard canScan(sourceID: record.file.sourceID) else { return }
        recordDeferral(context.roundID, sourceID: record.file.sourceID)
        status.advancedWaitingReasons[record.file.sourceID] = reason
        let key = "\(record.file.sourceID.uuidString)|advanced-wait|\(record.id.uuidString)"
        if lastFailureLogSignatures[key] != reason {
            lastFailureLogSignatures[key] = reason
            logEvent(phase: "advanced-dedup", result: "waiting", sourceID: record.file.sourceID,
                     runID: context.runID, fileID: record.id, detail: reason)
        }
    }

    private func logAdvancedDecision(_ preparation: AdvancedPreparation, timings: [String: Double]) {
        guard let dedupConfiguration else { return }
        switch preparation {
        case .ready(let admission):
            logger?.logDecision(admission.evidence, configuration: dedupConfiguration, sourceSize: admission.source.size, additionalTimingsMS: timings)
        case .conservative(let admission):
            let m = admission.file.metadata
            let size = m.width.flatMap { width in m.height.flatMap { try? PixelSize(width: width, height: $0) } }
            logger?.logDecision(admission.evidence, configuration: dedupConfiguration,
                sourceSize: size, conservativeReason: admission.reason, additionalTimingsMS: timings)
        case .waiting: break
        }
    }

    private nonisolated static func physicalStampMatches(_ file: SourceFile) throws -> Bool {
        let url = URL(fileURLWithPath: file.url.path)
        _ = try SourceRegistry.normalizedURL(url.deletingLastPathComponent())
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw DirectoryReaderError.missingFileAttributes }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values.fileSize, let modified = values.contentModificationDate else { throw DirectoryReaderError.missingFileAttributes }
        return FileStamp(size: Int64(size), modifiedNanoseconds: Int64((modified.timeIntervalSince1970 * 1_000_000_000).rounded(.down))) == file.stamp
    }

    private func canSubmit(sourceID: UUID) -> Bool {
        !status.isPaused && !storageFailed && status.blockingError == nil && uncertainSubmissions.isEmpty && !disabledSources.contains(sourceID) && verifiedRoots.contains(sourceID) && unavailableRoots[sourceID] == nil
    }

    private func canScan(sourceID: UUID) -> Bool {
        !status.isPaused && !storageFailed && status.blockingError == nil && !disabledSources.contains(sourceID)
    }

    private func canReadSource(_ sourceID: UUID) -> Bool {
        canScan(sourceID: sourceID) && unavailableRoots[sourceID] == nil
    }

    private func closeRootAdmission(_ sourceID: UUID) {
        rootClosureRevisions[sourceID, default: 0] &+= 1
        verifiedRoots.remove(sourceID)
    }

    private func recordRootUnavailable(_ source: RegisteredSource, runID: UUID?, error: Error) {
        closeRootAdmission(source.id)
        unavailableRoots[source.id] = source.url.path
        status.deferredSources.remove(source.id)
        setSourceIssue(source.id, key: Self.directoryScanIssueKey,
                       issue: SourceIssueText.directoryUnavailable(sourceURL: source.url, failingURL: source.url, isRoot: true, error: error),
                       path: source.url.path, stage: "枚举目录", runID: runID, error: error)
        logFailureOnce(phase: "directory", sourceID: source.id, runID: runID,
                       path: source.url.path, stage: "枚举目录", error: error)
    }

    /// A failed child read alone cannot prove root loss. Probe through the same bounded
    /// reader; a logical timeout only defers this round and never becomes outage evidence.
    private func holdSourceIfRootUnavailable(_ source: RegisteredSource, reader: any DirectoryReading,
                                             roundID: UUID, runID: UUID?) async throws -> Bool {
        guard canReadSource(source.id) else { return true }
        do {
            _ = try await reader.entries(in: source.url)
            return !canReadSource(source.id)
        } catch {
            guard canReadSource(source.id) else { return true }
            if SourceIssueText.isReadContention(error) {
                closeRootAdmission(source.id)
                recordDeferral(roundID, sourceID: source.id)
            } else {
                recordRootUnavailable(source, runID: runID, error: error)
                recordRoundFailure(roundID)
                interruptRound(roundID)
                if let runID { try await store.recordScanFailure(runID: runID, error: error.localizedDescription) }
            }
            return true
        }
    }

    private func nextRetry(for record: StoredFile) -> Date {
        now().addingTimeInterval(retryDelay(failureCount: record.retryCount + 1))
    }

    private func issueKey(for fileID: UUID) -> String { "file:\(fileID.uuidString)" }

    /// Source directories and individual files are tracked separately so an unavailable volume
    /// and unreadable files can be reported at the same time instead of overwriting each other.
    private static let directoryScanIssueKey = "scan:directory"
    private func fileScanIssueKey(_ relativePath: String) -> String { "scan:file:\(relativePath)" }

    private func setSourceIssue(_ sourceID: UUID, key: String, issue: SourceIssue, path: String,
                                stage: String? = nil, runID: UUID? = nil, fileID: UUID? = nil, attemptID: UUID? = nil, error: Error?) {
        guard !removedSources.contains(sourceID), !disabledSources.contains(sourceID) else { return }
        let diagnosticID = key == Self.directoryScanIssueKey ? "\(key):\(path)" : key
        let operation = stage.map { " [\($0)]" } ?? ""
        let detail = "\(path)\(operation): " + (error.map { SourceIssueText.systemDiagnostic($0) } ?? issue.detail)
        let diagnostic = SourceIssueDetail(id: diagnosticID, kind: issue.kind, path: path,
                                           summary: issue.summary, stage: stage, detail: detail)
        var tracked = (key == Self.directoryScanIssueKey ? sourceIssues[sourceID]?[key] : nil)
            ?? TrackedSourceIssue(primary: issue, diagnostics: [:])
        tracked.diagnostics[diagnosticID] = diagnostic
        sourceIssues[sourceID, default: [:]][key] = refreshedPrimary(tracked)
        // Individual submission evidence must outlive the snapshot even when this source's
        // once-per-outage waiting notification has already been sent for another file.
        if issue.kind == .submission {
            logFailureOnce(phase: "submission-diagnostic", sourceID: sourceID, keyPath: diagnosticID,
                           runID: runID, fileID: fileID, attemptID: attemptID, path: path, stage: stage,
                           result: "unresolved", error: error, detail: diagnostic.detail)
        }
        syncSourceIssueStatus(sourceID, runID: runID, fileID: fileID, attemptID: attemptID, error: error)
    }

    private func refreshedPrimary(_ tracked: TrackedSourceIssue) -> TrackedSourceIssue {
        var result = tracked
        if let first = tracked.diagnostics.values.sorted(by: Self.diagnosticOrder).first {
            result.primary = SourceIssue(summary: first.summary, detail: first.detail, kind: first.kind)
        } else {
            // Keep the source-availability marker until the existing exhaustive traversal gate.
            result.primary = SourceIssue(summary: "目录扫描尚未完成，稍后继续", detail: "完整目录扫描尚未结束，后续扫描会继续检查。", kind: tracked.primary.kind)
        }
        return result
    }

    private static func diagnosticOrder(_ lhs: SourceIssueDetail, _ rhs: SourceIssueDetail) -> Bool {
        lhs.path == rhs.path ? lhs.id < rhs.id : lhs.path < rhs.path
    }

    private func resolveDirectoryDiagnostic(_ sourceID: UUID, path: String, runID: UUID?) {
        guard var tracked = sourceIssues[sourceID]?[Self.directoryScanIssueKey],
              tracked.diagnostics.removeValue(forKey: "\(Self.directoryScanIssueKey):\(path)") != nil else { return }
        sourceIssues[sourceID]?[Self.directoryScanIssueKey] = refreshedPrimary(tracked)
        lastFailureLogSignatures.removeValue(forKey: "\(sourceID.uuidString)|directory|\(path)")
        syncSourceIssueStatus(sourceID, runID: runID, error: nil)
    }

    private func resolveSourceIssue(_ sourceID: UUID, key: String, runID: UUID? = nil, fileID: UUID? = nil,
                                    attemptID: UUID? = nil, announceRecovery: Bool = true) {
        if let fileID, key == issueKey(for: fileID) { lastFailureLogSignatures.removeValue(forKey: "\(sourceID.uuidString)|advanced-wait|\(fileID.uuidString)") }
        if let fileID, key == issueKey(for: fileID), pendingStampFailureID == fileID {
            pendingStampFailureID = nil
        }
        guard !removedSources.contains(sourceID) else { return }
        sourceIssues[sourceID]?.removeValue(forKey: key)
        if sourceIssues[sourceID]?.isEmpty == true { sourceIssues.removeValue(forKey: sourceID) }
        // Complete traversal ends this directory outage even when file issues remain.
        // A later outage must be journaled without resetting those files' signatures.
        if key == Self.directoryScanIssueKey {
            let prefix = "\(sourceID.uuidString)|directory|"
            lastFailureLogSignatures = lastFailureLogSignatures.filter { !$0.key.hasPrefix(prefix) }
        }
        // A readable file is a new condition: if it breaks again, that failure is journaled again.
        if key.hasPrefix("scan:file:") {
            lastFailureLogSignatures.removeValue(forKey: "\(sourceID.uuidString)|metadata|\(key.dropFirst("scan:file:".count))")
        }
        // Submission-stamp issues already carry their persisted file ID. Resetting one read
        // failure must not re-enable identical log rows for any other file in this source.
        if key.hasPrefix("file:"), let fileID {
            lastFailureLogSignatures.removeValue(forKey: "\(sourceID.uuidString)|submission-stamp|\(fileID.uuidString)")
            lastFailureLogSignatures.removeValue(forKey: "\(sourceID.uuidString)|submission-diagnostic|\(fileID.uuidString)")
        }
        syncSourceIssueStatus(sourceID, runID: runID, fileID: fileID, attemptID: attemptID,
                              error: nil, announceRecovery: announceRecovery)
    }

    /// A clean scan means the source answered for every entry it enumerated, so no scan-stage
    /// issue from an earlier round survives it. Submission issues keep their own lifetime.
    private func resolveScanIssues(_ sourceID: UUID, runID: UUID? = nil) {
        guard let keys = sourceIssues[sourceID]?.keys.filter({ $0.hasPrefix("scan:") }), !keys.isEmpty else { return }
        for key in keys { sourceIssues[sourceID]?.removeValue(forKey: key) }
        if sourceIssues[sourceID]?.isEmpty == true { sourceIssues.removeValue(forKey: sourceID) }
        syncSourceIssueStatus(sourceID, runID: runID, error: nil)
    }

    /// The source line shows the most explanatory unresolved problem: a missing directory first,
    /// then a blocked import, then unreadable files.
    private func primaryIssue(_ issues: [String: TrackedSourceIssue]) -> SourceIssue? {
        if let issue = issues[Self.directoryScanIssueKey] { return issue.primary }
        if let key = issues.keys.filter({ $0.hasPrefix("file:") }).sorted().first { return issues[key]?.primary }
        if let key = issues.keys.filter({ $0.hasPrefix("scan:file:") }).sorted().first { return issues[key]?.primary }
        return issues.keys.sorted().first.flatMap { issues[$0]?.primary }
    }

    private func syncSourceIssueStatus(_ sourceID: UUID, runID: UUID? = nil, fileID: UUID? = nil,
                                       attemptID: UUID? = nil, error: Error?, announceRecovery: Bool = true) {
        guard !removedSources.contains(sourceID) else { return }
        var issues = sourceIssues[sourceID] ?? [:]
        if let root = unavailableRoots[sourceID], let directory = issues[Self.directoryScanIssueKey],
           let diagnostic = directory.diagnostics["\(Self.directoryScanIssueKey):\(root)"] {
            issues = [Self.directoryScanIssueKey: TrackedSourceIssue(
                primary: SourceIssue(summary: diagnostic.summary, detail: diagnostic.detail, kind: diagnostic.kind),
                diagnostics: [diagnostic.id: diagnostic])]
        }
        let diagnostics = issues.values.flatMap { $0.diagnostics.values }.sorted(by: Self.diagnosticOrder)
        if diagnostics.isEmpty { status.sourceIssueDetails.removeValue(forKey: sourceID) }
        else { status.sourceIssueDetails[sourceID] = diagnostics }
        if let issue = primaryIssue(issues) {
            status.waitingSources[sourceID] = issue
            let fileIssues = issues.keys.filter { $0.hasPrefix("scan:file:") }.count
            if fileIssues > 0 {
                status.sourceFileIssueCounts[sourceID] = fileIssues
            } else {
                status.sourceFileIssueCounts.removeValue(forKey: sourceID)
            }
            logSourceWaiting(sourceID, issue: issue, runID: runID, fileID: fileID, attemptID: attemptID, error: error)
        } else {
            status.waitingSources.removeValue(forKey: sourceID)
            status.sourceFileIssueCounts.removeValue(forKey: sourceID)
            clearFailureLogSignatures(sourceID)
            if announceRecovery {
                logSourceRecovered(sourceID, runID: runID, fileID: fileID, attemptID: attemptID)
            } else {
                // Normal deletion closes a stale retry, not a recovered source failure.
                reportedWaitingSources.remove(sourceID)
            }
        }
    }

    private func logSourceWaiting(_ sourceID: UUID, issue: SourceIssue, runID: UUID? = nil, fileID: UUID? = nil, attemptID: UUID? = nil, error: Error?) {
        guard reportedWaitingSources.insert(sourceID).inserted else { return }
        notify(sourceID, false)
        notifySourceIssue(sourceID, false, issue)
        logEvent(phase: "recovery", result: "waiting", sourceID: sourceID, runID: runID, fileID: fileID, attemptID: attemptID, error: error, detail: issue.detail)
    }

    private func logSourceRecovered(_ sourceID: UUID, runID: UUID? = nil, fileID: UUID? = nil, attemptID: UUID? = nil) {
        guard reportedWaitingSources.remove(sourceID) != nil else { return }
        notify(sourceID, true)
        notifySourceIssue(sourceID, true, nil)
        logEvent(phase: "recovery", result: "recovered", sourceID: sourceID, runID: runID, fileID: fileID, attemptID: attemptID)
    }

    private func clearRemovedSourceStatus(_ sourceID: UUID) {
        closeRootAdmission(sourceID)
        unavailableRoots.removeValue(forKey: sourceID)
        status.sourcePhases.removeValue(forKey: sourceID)
        status.waitingSources.removeValue(forKey: sourceID)
        status.sourceFileIssueCounts.removeValue(forKey: sourceID)
        status.sourceIssueDetails.removeValue(forKey: sourceID)
        status.deferredSources.remove(sourceID)
        status.advancedWaitingReasons.removeValue(forKey: sourceID)
        sourceIssues.removeValue(forKey: sourceID)
        reportedWaitingSources.remove(sourceID)
        clearFailureLogSignatures(sourceID, includeAdvanced: true)
    }

    private func clearFailureLogSignatures(_ sourceID: UUID, includeAdvanced: Bool = false) {
        let prefix = "\(sourceID.uuidString)|"
        lastFailureLogSignatures = lastFailureLogSignatures.filter {
            !$0.key.hasPrefix(prefix) || (!includeAdvanced && $0.key.hasPrefix(prefix + "advanced-wait|"))
        }
    }

    /// Journals a failure only while its signature changes. Every attempt still persists its own
    /// `scan_run` row, so an unchanged failure repeating on each recovery round adds no evidence.
    /// fileID is the preferred dedupe identity; keyPath is its fallback while path stays the
    /// logged physical location.
    private func logFailureOnce(phase: String, sourceID: UUID, keyPath: String? = nil, runID: UUID? = nil,
                                fileID: UUID? = nil, attemptID: UUID? = nil, path: String? = nil, stage: String? = nil,
                                result: String = "failed", error: Error? = nil, detail: String? = nil) {
        let identity = fileID?.uuidString ?? keyPath ?? path ?? ""
        let key = "\(sourceID.uuidString)|\(phase)|\(identity)"
        let diagnostic = detail ?? error.map { SourceIssueText.systemDiagnostic($0) } ?? ""
        let signature = "\(result)|\(stage ?? "")|\(diagnostic)"
        guard lastFailureLogSignatures[key] != signature else { return }
        lastFailureLogSignatures[key] = signature
        let logDetail = detail ?? stage.map { "\($0): \(diagnostic)" }
        logEvent(phase: phase, result: result, sourceID: sourceID, runID: runID, fileID: fileID, attemptID: attemptID, path: path, error: error, detail: logDetail)
    }

    private func logEvent(phase: String, result: String, sourceID: UUID? = nil, runID: UUID? = nil, fileID: UUID? = nil, attemptID: UUID? = nil, path: String? = nil, error: Error? = nil, detail: String? = nil) {
        var fields = ["phase": phase, "result": result]
        if let sourceID { fields["source"] = sourceID.uuidString }
        if let runID { fields["run"] = runID.uuidString }
        if let fileID { fields["file"] = fileID.uuidString }
        if let attemptID { fields["attempt"] = attemptID.uuidString }
        if let path { fields["path"] = path }
        if let error { fields["error"] = error.localizedDescription }
        if let detail { fields["detail"] = detail }
        else if let error { fields["detail"] = SourceIssueText.systemDiagnostic(error) }
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
        let progress = ScanProgress(state: .running, startedAt: now())
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

    /// A deferred read is waiting, not failing: it never creates an issue, never counts as an
    /// unreadable file, and never notifies. It only marks the round so the UI can say "稍后继续"
    /// and so the source is retried shortly.
    private func recordDeferral(_ roundID: UUID, sourceID: UUID) {
        guard unavailableRoots[sourceID] == nil else { return }
        status.deferredSources.insert(sourceID)
        updateRound(roundID) {
            $0.progress.deferred = true
            $0.interrupted = true
        }
    }

    private func recordRoundFailure(_ roundID: UUID, fileLevel: Bool = false) {
        updateRound(roundID) {
            $0.progress.failed += 1
            if fileLevel { $0.progress.failedFiles += 1 }
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
        round.progress.endedAt = now()
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
        status.blockingSummary = nil
        status.recoveryHint = nil
        hasUncertainSubmissionBlock = false
    }

    private func setBlockingError(_ message: String, summary: String) {
        status.blockingError = message
        status.blockingSummary = summary
        status.recoveryHint = nil
        hasUncertainSubmissionBlock = false
        publishIssueNotification(summary)
    }

    private func setUncertainSubmissionBlock() {
        hasUncertainSubmissionBlock = true
        let fileID = uncertainSubmissions.min { $0.uuidString < $1.uuidString }
        let message = fileID.flatMap { uncertainSubmissionErrors[$0] }
            ?? "A Photos submission from this session remains uncertain. Waiting for confirmation."
        let hint = fileID.flatMap { uncertainSubmissionHints[$0] }
        let summary: String
        if case .checkpointFailure? = hint {
            summary = SourceIssueText.checkpointFailure
        } else {
            summary = SourceIssueText.uncertainImport
        }
        status.blockingError = message
        status.recoveryHint = hint
        status.blockingSummary = summary
        publishIssueNotification(summary)
    }

    /// Blocks that need a person are announced once per distinct headline instead of once per round.
    private func publishIssueNotification(_ summary: String) {
        guard lastNotifiedIssue != summary else { return }
        lastNotifiedIssue = summary
        notifyIssue(summary)
    }

    private func clearUncertainSubmissionBlockIfResolved() {
        guard uncertainSubmissions.isEmpty,
              hasUncertainSubmissionBlock else {
            return
        }
        clearBlockingError()
    }

    private func stopStorage(_ error: Error) {
        let firstStop = !storageFailed
        storageFailed = true
        status.blockingError = "Storage stopped: \(error.localizedDescription)"
        status.blockingSummary = SourceIssueText.storageStopped
        status.summaryError = error.localizedDescription
        status.recoveryHint = nil
        hasUncertainSubmissionBlock = false
        logger?.log(["error": error.localizedDescription, "scope": "storage"])
        if firstStop { publishIssueNotification(SourceIssueText.storageStopped) }
    }
}

/// Synchronous mirror for the existing native beforeMutation callback. Its lock
/// is never held across source I/O, SQLite, or Photos validity checks.
private final class EngineSubmissionState: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false, blocked = false
    private var disabled: Set<UUID> = []
    private var verified: Set<UUID> = []
    func update(paused: Bool, blocked: Bool, disabled: Set<UUID>, verified: Set<UUID>) {
        lock.lock(); self.paused = paused; self.blocked = blocked; self.disabled = disabled; self.verified = verified; lock.unlock()
    }
    func allows(_ source: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !paused && !blocked && !disabled.contains(source) && verified.contains(source)
    }
}
