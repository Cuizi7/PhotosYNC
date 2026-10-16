import Foundation
import Photos
import UserNotifications
import PhotoSyncCore

enum RuntimeSourceOperationError: Error, LocalizedError {
    case sourceRemoved
    var errorDescription: String? { "该来源已移除，请重新添加来源目录。" }
}

struct RuntimeState: Sendable {
    var snapshot = EngineSnapshot()
    var sources: [RegisteredSource] = []
    var authorized = false
    var nextScan: Date?
    /// Blocking initialization/operation headline, with its raw detail kept separately.
    var message: String?
    var messageDetail: String?
    /// Logging is best-effort. A logger outage is visible as a warning but must not make the
    /// global sync status an error or stop the engine.
    var warning: String?
    var warningDetail: String?
}

/// Immutable ownership graph; test factories inject only its physical boundaries.
struct AdvancedRuntimeGraph: Sendable {
    let configuration: DedupConfiguration
    let photos: any PhotosIndexGateway
    let model: any ImageFingerprinting
    let budget: ImageWorkBudget
    let coordinator: PhotosIndexCoordinator
    let service: AdvancedDedupService
    let legacy: LegacySkipReevaluation

    init(store: SyncStore, photos: any PhotosIndexGateway, model: any ImageFingerprinting,
         configuration: DedupConfiguration, executor: ReadExecutor, budget: ImageWorkBudget,
         directory: @escaping SyncEngine.DirectoryFactory, now: @escaping @Sendable () -> Date, logger: RunLogger? = nil, indexDiagnostics: IndexDiagnostics? = nil) {
        self.configuration = configuration; self.photos = photos; self.model = model; self.budget = budget
        logger?.log(["phase": "sqlite-vector-query", "backend": configuration.backend,
            "effectiveMmapBytes": String(store.vectorQueryMmapBytes), "ordinaryCacheKiB": "16384"])
        coordinator = PhotosIndexCoordinator(store: store, photos: photos, fingerprinter: model,
            configuration: configuration, wallNow: now, indexDiagnostics: indexDiagnostics, diagnostics: { logger?.log($0) })
        service = AdvancedDedupService(store: store, photos: photos, coordinator: coordinator,
            fingerprinter: model, configuration: configuration, executor: executor, budget: budget)
        legacy = LegacySkipReevaluation(store: store,
            stamp: { file in try await directory(file.sourceID).stamp(of: file.url) },
            policyVersion: configuration.policyVersion, retryDelaysSeconds: configuration.resources.retryDelaysSeconds, now: now)
    }

    static func load(store: SyncStore, executor: ReadExecutor, directory: @escaping SyncEngine.DirectoryFactory,
                     now: @escaping @Sendable () -> Date, resourceDirectory: URL? = nil,
                     configuration: DedupConfiguration? = nil, logger: RunLogger? = nil,
                     authorized: @escaping @Sendable () -> Bool = { true }) async throws -> AdvancedRuntimeGraph {
        // Compilation/model loading is synchronous Core ML work. Keep it off UI and runtime actors.
        try await loadInBackground {
            let root = try resourceDirectory ?? DedupConfiguration.bundledResourceDirectory()
            let configuration = try configuration ?? DedupConfiguration.loadValidated(resourceDirectory: root)
            let policy = try ModelExecutionPolicy.loadValidated(resourceDirectory: root)
            let selfTest = try ModelSelfTest.loadValidated(resourceDirectory: root, policy: policy)
            let model = try CoreMLFingerprinter(modelURL: root.appendingPathComponent("SSCDLarge.mlpackage"),
                configuration: configuration.fingerprint, policy: policy, selfTest: selfTest, now: now,
                diagnostics: { logger?.log($0) })
            model.setExecutionAuthorization(authorized)
            try Task.checkCancellation()
            try await model.prepareExecution()
            try Task.checkCancellation()
            let indexDiagnostics = IndexDiagnostics(sink: { logger?.log($0) })
            let budget = ImageWorkBudget(limits: configuration.resources)
            let photos = PhotoKitGateway(configuration: configuration, imageBudget: budget, indexDiagnostics: indexDiagnostics, diagnostics: { logger?.log($0) })
            return AdvancedRuntimeGraph(store: store, photos: photos, model: model,
                configuration: configuration, executor: executor, budget: budget, directory: directory, now: now, logger: logger, indexDiagnostics: indexDiagnostics)
        }
    }

    /// Owns the off-actor startup task through actual completion.
    static func loadInBackground(_ operation: @escaping @Sendable () async throws -> AdvancedRuntimeGraph) async throws -> AdvancedRuntimeGraph {
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try await operation()
        }
        // Cancellation revokes new phases inside Core ML, but awaiting its result still
        // retains ownership through physical return. A valid completed graph is retained.
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

/// Owns one engine and gateway for the entire process. A poisoned gateway is never replaced.
actor SyncRuntime {
    private var engine: SyncEngine?
    private var store: SyncStore?
    private var logger: RunLogger?
    typealias AdvancedFactory = @Sendable (SyncStore, ReadExecutor, @escaping SyncEngine.DirectoryFactory,
                                           @escaping @Sendable () -> Date, RunLogger?) async throws -> AdvancedRuntimeGraph
    private let executor: ReadExecutor
    private var advancedFactory: AdvancedFactory?
    private let validatesBundledConfiguration: Bool
    private let notification: (@Sendable (String, String) -> Void)?
    private var advancedGraph: AdvancedRuntimeGraph?
    private var loading: Task<Void, Never>?
    private var advancedWork: Task<Void, Never>?
    private var changeObserver: Task<Void, Never>?
    private var advancedLoadAttempted = false
    private var modelRetryAt: Date?
    private var modelRecovery: Task<Void, Error>?
    private var manualModelRetryPending = false
    private var changePending = false
    private var pendingFullChangeSerial: UInt64?
    private var indexEventPending = false
    private var pendingAdvancedScan = false
    private var nextProgressAt: Date?
    private var publishedProgress: IndexProgress?
    private var loggedProgress: IndexProgress?
    private let legacyFailureSummary = "无法读取历史同步记录，稍后会自动重试。"
    private var schedule = ScanSchedule()
    private var round: Task<Void, Never>?
    private var state = RuntimeState()
    private var started = false
    private var stopped = false
    private var loggingWarning: String?
    private var loggingWarningDetail: String?
    private var registeredFailures = Set<UUID>()
    private var lastKnownAuthorization: Bool?
    let logsURL: URL
    private let databaseURL: URL
    private let now: @Sendable () -> Date
    private let authorized: @Sendable () -> Bool
    private let requestAuthorizationAction: @Sendable () async -> Bool
    private let notificationsEnabled: @Sendable () -> Bool
    private let dueRetryQueryFailureSummary = "无法读取本地同步数据库，稍后会自动重试。"

    init(
        store: SyncStore,
        engine: SyncEngine? = nil,
        executor: ReadExecutor = ReadExecutor(),
        advancedFactory: AdvancedFactory? = nil,
        logsURL: URL = URL(fileURLWithPath: "/unused"),
        databaseURL: URL = URL(fileURLWithPath: "/unused"),
        now: @escaping @Sendable () -> Date,
        authorized: @escaping @Sendable () -> Bool,
        requestAuthorization: @escaping @Sendable () async -> Bool = { false },
        notificationsEnabled: @escaping @Sendable () -> Bool = { false },
        notification: (@Sendable (String, String) -> Void)? = nil
    ) {
        self.store = store; self.engine = engine
        self.executor = executor; self.advancedFactory = advancedFactory; self.notification = notification
        validatesBundledConfiguration = false
        self.now = now; self.authorized = authorized
        self.logsURL = logsURL
        self.databaseURL = databaseURL
        requestAuthorizationAction = requestAuthorization
        self.notificationsEnabled = notificationsEnabled
    }

    func prepareInjectedRuntime() async throws {
        started = true
        try await refreshSources()
    }

    func waitForRound() async {
        while loading != nil || modelRecovery != nil || advancedWork != nil || round != nil {
            await loading?.value
            _ = await modelRecovery?.result
            await Task.yield()
            await advancedWork?.value
            await round?.value
        }
    }

    init() {
        executor = ReadExecutor()
        notification = nil
        advancedFactory = nil
        validatesBundledConfiguration = true
        now = { Date() }
        authorized = { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized }
        requestAuthorizationAction = {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
        }
        notificationsEnabled = { UserDefaults.standard.bool(forKey: "sourceNotifications") }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoSync", isDirectory: true)
        logsURL = support.appendingPathComponent("Logs", isDirectory: true)
        databaseURL = support.appendingPathComponent("sync.sqlite")
    }

    func bootstrap() async {
        guard !started else { return }
        started = true
        do {
            let logger = try RunLogger(directory: logsURL, onFailure: { [weak self] message in
                Task { await self?.logFailed(message) }
            })
            self.logger = logger
        } catch {
            // Logging is intentionally non-blocking: continue opening the store and syncing.
            logFailed(error.localizedDescription)
        }
        do {
            store = try SyncStore(url: databaseURL, readExecutor: executor)
        } catch {
            setBootstrapFailure(summary: "无法打开本地同步数据库，同步尚未启动。", error: error)
            return
        }
        do {
            try await refreshSources()
        } catch {
            setBootstrapFailure(summary: "无法读取来源配置，同步尚未启动。", error: error)
            return
        }
        if validatesBundledConfiguration {
            do {
                let root = try DedupConfiguration.bundledResourceDirectory()
                let configuration = try await Task.detached(priority: .utility) {
                    try DedupConfiguration.loadValidated(resourceDirectory: root)
                }.value
                // Freeze the validated records once per process, even with no enabled
                // source. Only expensive model/gateway construction waits for eligibility.
                guard let store else { throw AdvancedDedupError.invalidConfiguration }
                try await store.rebindEquivalentSourceFingerprints(to: configuration.fingerprint)
                let authorization = authorized
                advancedFactory = { store, executor, directory, now, logger in
                    try await AdvancedRuntimeGraph.load(store: store, executor: executor, directory: directory,
                        now: now, resourceDirectory: root, configuration: configuration, logger: logger, authorized: authorization)
                }
            } catch { advancedLoadFailed(error); return }
        }
        await tick(force: true)
    }

    private func logFailed(_ message: String) {
        loggingWarning = "日志文件写入失败，同步仍在继续，但排查信息可能不完整。"
        loggingWarningDetail = message
    }

    private func setBootstrapFailure(summary: String, error: Error) {
        state.message = summary
        state.messageDetail = error.localizedDescription
    }

    func current() async -> RuntimeState {
        refreshAuthorization()
        if let engine { state.snapshot = await engine.snapshot() }
        else if let store {
            do {
                state.snapshot.summary = try await store.activeSourceSummary()
                state.snapshot.summaryError = nil
            } catch {
                state.snapshot.summaryError = error.localizedDescription
            }
        }
        if let graph = advancedGraph {
            // UI polling publishes aggregates at the profile cadence; transitions are also
            // published when an owned batch ends. No per-representation main-actor traffic.
            if nextProgressAt == nil || now() >= nextProgressAt! {
                publishedProgress = await graph.coordinator.progress()
                nextProgressAt = now().addingTimeInterval(graph.configuration.resources.progressPublishIntervalSeconds)
            }
            state.snapshot.indexProgress = publishedProgress
        }
        state.nextScan = schedule.nextScanAt
        var result = state
        result.warning = loggingWarning
        result.warningDetail = loggingWarningDetail
        return result
    }

    /// Losing the Photos permission needs a person, so it is announced on the transition instead
    /// of every poll. The first read only records the state; launch is not a revocation.
    private func refreshAuthorization() {
        let granted = authorized()
        if let previous = lastKnownAuthorization, previous != granted {
            // Permission transitions can hide Photos changes. Resume must reconcile
            // immediately even when the ordinary 30-minute deadline is still future.
            changePending = true
            nextProgressAt = nil
        }
        if let previous = lastKnownAuthorization, previous, !granted {
            postNotification(title: "PhotosYNC 需要处理",
                             body: "失去“照片”读写权限，同步已暂停。请在设置中重新授权。")
        }
        lastKnownAuthorization = granted
        state.authorized = granted
        updateModelEligibility()
    }

    private func postNotification(title: String, body: String) {
        guard notificationsEnabled() else { return }
        if let notification { notification(title, body); return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func requestAuthorization() async {
        _ = await requestAuthorizationAction()
        await tick(force: true)
    }

    func add(_ url: URL) async throws {
        guard let store else { throw CocoaError(.fileReadUnknown) }
        if let engine { _ = try await engine.addSource(url: url) }
        else { _ = try await store.registerSource(url: url) }
        try await refreshSources()
        await tick(force: true)
    }

    func enable(_ id: UUID) async throws {
        guard let store else { throw CocoaError(.fileReadUnknown) }
        // Visible sources exclude removed configurations. Reuse registration so path validation,
        // source identity, and successful history follow the same rules as adding a directory.
        guard let source = try await store.sources().first(where: { $0.id == id }) else {
            throw RuntimeSourceOperationError.sourceRemoved
        }
        try await add(source.url)
    }

    func disable(_ id: UUID) async throws {
        if let engine { try await engine.disableSource(id: id) }
        else { try await store?.disableSource(id: id) }
        schedule.recordSourceRecovered(id)
        registeredFailures.remove(id)
        try await refreshSources()
        await applyAnalysisEligibility()
    }

    func removeSource(_ id: UUID) async throws {
        guard let store else { throw CocoaError(.fileReadUnknown) }
        if let engine { try await engine.removeSource(id: id) }
        else { try await store.removeSource(id: id) }
        schedule.recordSourceRecovered(id)
        registeredFailures.remove(id)
        state.snapshot.sourcePhases.removeValue(forKey: id)
        state.snapshot.waitingSources.removeValue(forKey: id)
        state.snapshot.sourceIssueDetails.removeValue(forKey: id)
        try await refreshSources()
        await applyAnalysisEligibility()
    }

    private func refreshSources() async throws {
        state.sources = try await store?.sources() ?? []
    }

    func pause() async {
        schedule.pause()
        modelRecovery?.cancel()
        state.snapshot.isPaused = true
        updateModelEligibility()
        await engine?.pause()
        await applyAnalysisEligibility()
        await advancedGraph?.coordinator.setPaused(true)
        if let graph = advancedGraph { publishedProgress = await graph.coordinator.progress() }
    }

    func resume() async {
        guard !stopped else { return }
        // Resume clears engine pause without dispatching a second competing scan.
        state.snapshot.isPaused = false
        await engine?.setPaused(false)
        await applyAnalysisEligibility()
        if schedule.resume(now: now()) { schedule.finished(now: now()) }
        await tick(force: true, retryModel: true)
    }

    func stop() async {
        stopped = true
        updateModelEligibility()
        changeObserver?.cancel(); changeObserver = nil
        schedule.pause()
        await engine?.pause()
        await advancedGraph?.coordinator.setPaused(true)
        // Do not cancel physical Photos submission: the engine persists its callback.
    }

    func tick(force: Bool = false, includeAdvanced: Bool = true, retryModel: Bool = false) async {
        guard !stopped else { return }
        refreshAuthorization()
        await applyAnalysisEligibility()
        guard eligibleForWork else { return }
        if retryModel { manualModelRetryPending = true }
        if engine == nil { startAdvancedGraphIfNeeded(); return }
        if let model = advancedGraph?.model as? any ModelExecutionRecovering {
            // Coalesce ticks while the single physical queue is loading/validating.
            guard modelRecovery == nil else { return }
            let retry = manualModelRetryPending
            manualModelRetryPending = false
            let recovery = Task { try await model.prepareExecution(forceRetry: retry) }
            modelRecovery = recovery
            var failure: Error?
            do { try await recovery.value } catch { failure = error }
            modelRecovery = nil
            refreshAuthorization()
            if let failure, !(failure is ModelExecutionUnavailable) && !(failure is CancellationError) {
                advancedLoadFailed(failure); return
            }
            if manualModelRetryPending && eligibleForWork {
                await tick(force: true); return
            }
            guard failure == nil, eligibleForWork else { return }
        }
        guard let engine else { return }
        if includeAdvanced { scheduleAdvancedWork(force: force) }
        let explicitForce = force
        let force = force || pendingAdvancedScan
        let now = now()
        if round != nil {
            // Observe periodic ticks even while busy so their cadence is advanced and dropped.
            if !force { _ = schedule.request(now: now) }
            return
        }
        let enabled = Set(state.sources.filter(\.enabled).map(\.id))
        let ids: [UUID]
        if force {
            guard schedule.requestNow(now: now) else { return }
            // Index readiness reopens healthy work, but is not a manual request to
            // bypass an unavailable source's recovery deadline.
            let due = Set(schedule.dueRecoverySources(now: now)).intersection(enabled)
            let unavailableRoots = Set(state.sources.compactMap { source -> UUID? in
                let rootIssue = state.snapshot.sourceIssueDetails[source.id]?.contains {
                    $0.kind == .sourceAvailability && $0.path == source.url.path
                } == true
                return rootIssue ? source.id : nil
            })
            ids = explicitForce ? Array(enabled)
                : Array(enabled.subtracting(registeredFailures.intersection(unavailableRoots)).union(due))
        } else if schedule.request(now: now) {
            let due = Set(schedule.dueRecoverySources(now: now)).intersection(enabled)
            ids = Array(enabled.subtracting(registeredFailures).union(due))
        } else {
            guard let store else { return }
            let dueFiles: Set<UUID>
            do {
                dueFiles = Set(try await store.dueRetrySourceIDs(at: now))
                if state.message == dueRetryQueryFailureSummary {
                    state.message = nil
                    state.messageDetail = nil
                }
            } catch {
                guard !stopped else { return }
                state.message = dueRetryQueryFailureSummary
                state.messageDetail = error.localizedDescription
                return
            }

            // The store query suspends this actor. Permission, pause, source configuration, and
            // an existing round can all change while it is in flight, so do not reuse the earlier
            // admission decision.
            refreshAuthorization()
            guard !stopped, state.authorized, !state.snapshot.isPaused, round == nil else { return }
            let refreshedEnabled = Set(state.sources.filter(\.enabled).map(\.id))
            guard !refreshedEnabled.isEmpty else { return }
            let dueSourceRecovery = Set(schedule.dueRecoverySources(now: now)).intersection(refreshedEnabled)
            let heldSources = registeredFailures.union(state.snapshot.deferredSources)
            let eligibleFiles = dueFiles.intersection(refreshedEnabled).subtracting(heldSources)
                .union(dueFiles.intersection(dueSourceRecovery))

            if !eligibleFiles.isEmpty {
                // File retry deadlines are independent from the 60-second source-recovery poll.
                guard schedule.requestNow(now: now) else { return }
                ids = Array(eligibleFiles.union(dueSourceRecovery))
            } else if (!dueSourceRecovery.isEmpty || state.snapshot.blockingError != nil), schedule.requestRecovery(now: now) {
                ids = state.snapshot.blockingError != nil
                    ? Array(refreshedEnabled.subtracting(registeredFailures).union(dueSourceRecovery))
                    : Array(dueSourceRecovery)
            } else {
                return
            }
        }
        pendingAdvancedScan = false
        round = Task {
            await engine.scan(sourceIDs: ids)
            await self.finishedRound(ids: ids, snapshot: await engine.snapshot())
        }
    }

    private func finishedRound(ids: [UUID], snapshot: EngineSnapshot) async {
        state.snapshot = snapshot
        let enabled = Set(state.sources.filter(\.enabled).map(\.id))
        // Count failures once per attempted round, never once per UI polling tick.
        for id in ids where enabled.contains(id) {
            let sourceUnavailable = snapshot.waitingSources[id]?.isSourceAvailability == true
            let deferred = snapshot.deferredSources.contains(id)
            if sourceUnavailable {
                schedule.recordSourceFailure(id, now: now())
                registeredFailures.insert(id)
            } else {
                // File and submission issues do not quarantine a healthy source.
                schedule.recordSourceFailureRecovered(id)
                registeredFailures.remove(id)
            }
            if deferred {
                // Normal waiting: come back shortly without recording a failure or showing one.
                schedule.recordSourceDeferral(id, now: now())
            } else {
                schedule.recordSourceDeferralRecovered(id)
            }
        }
        schedule.finished(now: now())
        round = nil
        if pendingAdvancedScan { await tick(includeAdvanced: false) }
    }

    private var eligibleForWork: Bool {
        !stopped && state.authorized && !state.snapshot.isPaused && state.sources.contains(where: \.enabled)
    }

    private func updateModelEligibility() {
        let eligible = eligibleForWork
        (advancedGraph?.model as? any ModelExecutionRecovering)?.setExecutionEligible(eligible)
        if !eligible { manualModelRetryPending = false; modelRecovery?.cancel(); loading?.cancel() }
    }

    private func applyAnalysisEligibility() async {
        updateModelEligibility()
        guard let graph = advancedGraph else { return }
        await graph.coordinator.setPaused(!eligibleForWork)
        await graph.service.setPaused(!eligibleForWork)
    }

    private func startAdvancedGraphIfNeeded() {
        guard loading == nil, let store, let advancedFactory else { return }
        // A hard resource failure remains one-shot. Ordinary scan urgency never grants
        // the separate user-authorized exception to the model loading deadline.
        guard !advancedLoadAttempted || modelRetryAt != nil else { return }
        if let modelRetryAt, !manualModelRetryPending, now() < modelRetryAt { return }
        manualModelRetryPending = false
        modelRetryAt = now().addingTimeInterval(60)
        advancedLoadAttempted = true
        state.snapshot.indexProgress = IndexProgress(state: .preparing, totalsKnown: false, totalAssets: 0,
            readyAssets: 0, totalRepresentations: 0, readyRepresentations: 0, excludedAssets: 0, issue: nil)
        let executor = self.executor, now = self.now
        let directory: SyncEngine.DirectoryFactory = { DirectoryReader(sourceID: $0, executor: executor) }
        loading = Task { [weak self] in
            do {
                let graph = try await advancedFactory(store, executor, directory, now, self?.logger)
                await self?.install(graph, store: store, directory: directory)
            } catch is CancellationError { await self?.advancedLoadCancelled() }
            catch { await self?.advancedLoadFailed(error) }
        }
    }

    private func advancedLoadCancelled() async {
        loading = nil; advancedLoadAttempted = false
        state.message = nil; state.messageDetail = nil
        state.snapshot.indexProgress = IndexProgress(state: state.snapshot.isPaused ? .paused : .waiting,
            totalsKnown: false, totalAssets: 0, readyAssets: 0, totalRepresentations: 0,
            readyRepresentations: 0, excludedAssets: 0, issue: nil)
        refreshAuthorization()
        if manualModelRetryPending && eligibleForWork { await tick(force: true) }
    }

    private func advancedLoadFailed(_ error: Error) {
        loading = nil
        if error is ModelExecutionUnavailable {
            modelRetryAt = now().addingTimeInterval(60)
            state.message = nil; state.messageDetail = nil
            state.snapshot.indexProgress = IndexProgress(state: .waiting, totalsKnown: false, totalAssets: 0,
                readyAssets: 0, totalRepresentations: 0, readyRepresentations: 0, excludedAssets: 0,
                issue: ModelExecutionUnavailable.summary)
            logger?.log(["phase": "advanced-initialization", "result": "model-waiting", "error": String(describing: error)])
            return
        }
        modelRetryAt = nil
        state.message = "照片判重配置不可用，同步尚未启动。"
        state.messageDetail = error.localizedDescription
        state.snapshot.indexProgress = IndexProgress(state: .waiting, totalsKnown: false, totalAssets: 0,
            readyAssets: 0, totalRepresentations: 0, readyRepresentations: 0, excludedAssets: 0,
            issue: "照片判重配置不可用，请检查应用资源。")
        logger?.log(["phase": "advanced-initialization", "result": "unavailable", "error": String(describing: error)])
    }

    private func install(_ graph: AdvancedRuntimeGraph, store: SyncStore, directory: @escaping SyncEngine.DirectoryFactory) async {
        advancedGraph = graph
        (graph.model as? any ModelExecutionRecovering)?.setExecutionAuthorization(authorized)
        updateModelEligibility()
        modelRetryAt = nil; state.message = nil; state.messageDetail = nil
        let executor = self.executor
        engine = SyncEngine(store: store, photos: graph.photos, directory: directory,
            metadata: { MetadataReader(sourceID: $0, executor: executor) }, logger: logger,
            advancedDedup: graph.service, indexCoordinator: graph.coordinator, requiresAdvancedDedup: true,
            dedupConfiguration: graph.configuration, legacySkipReevaluation: graph.legacy,
            notifyIssue: { [weak self] summary in
                Task { await self?.postNotification(title: "PhotosYNC 需要处理", body: summary) }
            }, notifySourceIssue: { [weak self] _, recovered, issue in
                Task { await self?.postNotification(title: recovered ? "PhotosYNC 来源已恢复" : "PhotosYNC 来源等待恢复",
                    body: recovered ? "来源已恢复正常同步。" : (issue?.summary ?? "来源暂时不可用，将自动重试。恢复后不再提示。")) }
            }, now: now)
        await engine?.setPaused(state.snapshot.isPaused || stopped)
        refreshAuthorization()
        await applyAnalysisEligibility()
        if !stopped {
            let events = graph.photos.changes()
            changeObserver = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { break }
                    await self?.libraryChanged(event)
                }
            }
        }
        loading = nil
        await tick(force: true)
    }

    func libraryChanged(_ event: PhotosIndexChange) async {
        indexEventPending = true
        let receipt = await advancedGraph?.coordinator.libraryChanged(event)
        let name: String, count: Int?
        switch event {
        case .incremental(let delta): name = "incremental"; count = delta.changedAssetIDs.count + delta.deletedAssetIDs.count
        case .fullReconcileRequired: name = "fullReconcileRequired"; count = nil
        case .contextInvalidated: name = "contextInvalidated"; count = nil
        }
        if event == .fullReconcileRequired || event == .contextInvalidated {
            if let receipt { pendingFullChangeSerial = max(pendingFullChangeSerial ?? receipt, receipt) }
            else { changePending = true }
        }
        var fields = ["phase": "index-trigger", "trigger": "photos-event", "event": name, "unit": "eventAssetIDs"]
        fields["count"] = count.map(String.init)
        logger?.log(fields)
        // The coordinator may finish a pass while this handler awaits its receipt.
        await consumeCoveredFullChange()
        await tick()
    }

    private func consumeCoveredFullChange() async {
        guard let receipt = pendingFullChangeSerial, let graph = advancedGraph else { return }
        let covered = await graph.coordinator.reconciliationCovers(change: receipt)
        // A newer event or forced request may arrive while the actor query waits.
        // Only the captured event receipt is consumed; force and wake flags survive.
        if covered && pendingFullChangeSerial == receipt { pendingFullChangeSerial = nil }
    }

    private func scheduleAdvancedWork(force: Bool) {
        guard let graph = advancedGraph else { return }
        if force { changePending = true }
        let reconcile = schedule.requestPhotosReconciliation(now: now(), force: changePending || pendingFullChangeSerial != nil)
        guard advancedWork == nil else {
            // A due-work-only batch can be busy when a periodic reconcile becomes due.
            // Release a newly acquired schedule gate; explicit changes remain coalesced.
            if reconcile { schedule.finishedPhotosReconciliation() }
            return
        }
        if reconcile { changePending = false; pendingFullChangeSerial = nil }
        indexEventPending = false
        advancedWork = Task { await self.runAdvancedWork(graph, reconcile: reconcile) }
    }

    private func runAdvancedWork(_ graph: AdvancedRuntimeGraph, reconcile: Bool) async {
        let previousReady = publishedProgress?.state == .ready
        if eligibleForWork {
            if reconcile {
                logger?.log(["phase": "index-trigger", "trigger": "runtime-reconcile"])
                do { try await graph.coordinator.reconcile() }
                catch is CancellationError { /* Paused before another catalog page. */ }
                catch { logger?.log(["phase": "index-reconcile", "result": "waiting", "error": String(describing: error)]) }
            }
            if eligibleForWork { await graph.coordinator.processDueWork(now: now()) }
            if eligibleForWork, let engine {
                do {
                    let reopened = try await engine.processLegacySkips(limit: graph.configuration.resources.catalogBatchSize)
                    if reopened > 0 { pendingAdvancedScan = true }
                    if state.message == legacyFailureSummary { state.message = nil; state.messageDetail = nil }
                } catch is CancellationError {
                    // Cancellation never fabricates a file/source failure.
                } catch {
                    state.message = legacyFailureSummary; state.messageDetail = error.localizedDescription
                }
            }
        }
        publishedProgress = await graph.coordinator.progress()
        state.snapshot.indexProgress = publishedProgress
        nextProgressAt = now().addingTimeInterval(graph.configuration.resources.progressPublishIntervalSeconds)
        if let p = publishedProgress, p != loggedProgress {
            loggedProgress = p
            logger?.log(["phase": "index-progress", "state": p.state.rawValue, "unit": "representations",
                "ready": String(p.readyRepresentations), "total": p.totalsKnown ? String(p.totalRepresentations) : "unknown",
                "readErrors": String(p.readErrorRepresentations),
                "waiting": p.totalsKnown ? String(max(0, p.totalRepresentations - p.readyRepresentations - p.readErrorRepresentations)) : "unknown",
                "readyAssets": String(p.readyAssets), "totalAssets": p.totalsKnown ? String(p.totalAssets) : "unknown"])
        }
        if !previousReady && publishedProgress?.state == .ready { pendingAdvancedScan = true }
        await consumeCoveredFullChange()
        if reconcile { schedule.finishedPhotosReconciliation() }
        advancedWork = nil
        // A change delivered while busy is coalesced into one fresh batch. Zero legacy
        // reopens never marks that durable queue complete; the next existing tick retries it.
        if changePending || pendingFullChangeSerial != nil || indexEventPending { await tick() }
        else if pendingAdvancedScan && round == nil { await tick(includeAdvanced: false) }
    }
}
