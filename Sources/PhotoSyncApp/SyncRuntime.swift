import Foundation
import Photos
import UserNotifications
import PhotoSyncCore

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

/// Owns one engine and gateway for the entire process. A poisoned gateway is never replaced.
actor SyncRuntime {
    private var engine: SyncEngine?
    private var store: SyncStore?
    private var logger: RunLogger?
    private let executor = ReadExecutor()
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

    init(
        store: SyncStore,
        engine: SyncEngine,
        logsURL: URL = URL(fileURLWithPath: "/unused"),
        databaseURL: URL = URL(fileURLWithPath: "/unused"),
        now: @escaping @Sendable () -> Date,
        authorized: @escaping @Sendable () -> Bool,
        requestAuthorization: @escaping @Sendable () async -> Bool = { false },
        notificationsEnabled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.store = store; self.engine = engine
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

    func waitForRound() async { await round?.value }

    init() {
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
        if let previous = lastKnownAuthorization, previous, !granted {
            postNotification(title: "PhotosYNC 需要处理",
                             body: "失去“照片”读写权限，同步已暂停。请在设置中重新授权。")
        }
        lastKnownAuthorization = granted
        state.authorized = granted
    }

    private func postNotification(title: String, body: String) {
        guard notificationsEnabled() else { return }
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

    func disable(_ id: UUID) async throws {
        if let engine { try await engine.disableSource(id: id) }
        else { try await store?.disableSource(id: id) }
        schedule.recordSourceRecovered(id)
        registeredFailures.remove(id)
        try await refreshSources()
    }

    func removeSource(_ id: UUID) async throws {
        guard let store else { throw CocoaError(.fileReadUnknown) }
        if let engine { try await engine.removeSource(id: id) }
        else { try await store.removeSource(id: id) }
        schedule.recordSourceRecovered(id)
        registeredFailures.remove(id)
        state.snapshot.sourcePhases.removeValue(forKey: id)
        state.snapshot.waitingSources.removeValue(forKey: id)
        try await refreshSources()
    }

    private func refreshSources() async throws {
        state.sources = try await store?.sources() ?? []
    }

    func pause() async {
        schedule.pause()
        state.snapshot.isPaused = true
        await engine?.pause()
    }

    func resume() async {
        guard !stopped else { return }
        // Resume clears engine pause without dispatching a second competing scan.
        await engine?.setPaused(false)
        state.snapshot.isPaused = false
        if schedule.resume(now: now()) { schedule.finished(now: now()) }
        await tick(force: true)
    }

    func stop() async {
        stopped = true
        schedule.pause()
        await engine?.pause()
        // Do not cancel physical Photos submission: the engine persists its callback.
    }

    func tick(force: Bool = false) async {
        guard !stopped else { return }
        refreshAuthorization()
        guard state.authorized, state.sources.contains(where: \.enabled), !state.snapshot.isPaused else { return }
        if engine == nil, let store {
            let executor = self.executor
            engine = SyncEngine(store: store, photos: PhotoKitGateway(),
                                directory: { DirectoryReader(sourceID: $0, executor: executor) },
                                metadata: { MetadataReader(sourceID: $0, executor: executor) }, logger: logger,
                                // Keep the old transition hook available to injected clients, but
                                // let the summary-carrying hook below drive user notifications.
                                notify: { _, _ in },
                                notifyIssue: { summary in
                                    Task {
                                        await self.postNotification(title: "PhotosYNC 需要处理", body: summary)
                                    }
                                },
                                notifySourceIssue: { _, recovered, issue in
                                    Task {
                                        await self.postNotification(
                                            title: recovered ? "PhotosYNC 来源已恢复" : "PhotosYNC 来源等待恢复",
                                            body: recovered ? "来源已恢复正常同步。" : (issue?.summary ?? "来源暂时不可用，将自动重试。恢复后不再提示。")
                                        )
                                    }
                                })
        }
        guard let engine else { return }
        let now = now()
        if round != nil {
            // Observe periodic ticks even while busy so their cadence is advanced and dropped.
            if !force { _ = schedule.request(now: now) }
            return
        }
        let enabled = Set(state.sources.filter(\.enabled).map(\.id))
        let due = Set(schedule.dueRecoverySources(now: now)).intersection(enabled)
        let ids: [UUID]
        if force {
            guard schedule.requestNow(now: now) else { return }
            ids = Array(enabled)
        } else if schedule.request(now: now) {
            ids = Array(enabled.subtracting(registeredFailures).union(due))
        } else if (!due.isEmpty || state.snapshot.blockingError != nil), schedule.requestRecovery(now: now) {
            ids = state.snapshot.blockingError != nil ? Array(enabled.subtracting(registeredFailures).union(due)) : Array(due)
        } else { return }
        round = Task {
            await engine.scan(sourceIDs: ids)
            self.finishedRound(ids: ids, snapshot: await engine.snapshot())
        }
    }

    private func finishedRound(ids: [UUID], snapshot: EngineSnapshot) {
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
    }
}
