import AppKit
import SwiftUI
import Combine
import PhotoSyncCore
import ServiceManagement
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var state = RuntimeState()
    @Published var error: String?
    @Published var loginEnabled = false
    @Published var loginNeedsApproval = false
    @Published var changingLogin = false
    @Published var notificationsEnabled = false
    @Published private(set) var notificationIssue: NotificationPermissionWarning?
    @Published var ready = false
    @Published var demoStatus: GlobalStatus = .unconfigured
    @Published private(set) var qaMode: GUIQAMode?
    @Published private(set) var qaRoot: URL?
    @Published private(set) var qaBlockedReason: String?
    let demo: Bool
    private var demoWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var runtime: SyncRuntime?
    private var polling: Task<Void, Never>?
    private var notificationPolling: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private lazy var notificationPermissions: NotificationPermissionController = {
        NotificationPermissionController(
            preferenceEnabled: UserDefaults.standard.bool(forKey: "sourceNotifications"),
            readAuthorization: {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                return settings.authorizationStatus == .authorized
            },
            requestAuthorization: {
                try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            },
            persistPreference: { enabled in
                UserDefaults.standard.set(enabled, forKey: "sourceNotifications")
            }
        )
    }()

    init(demo: Bool = ProcessInfo.processInfo.arguments.contains("--demo")) {
        self.demo = demo
#if GUI_QA
        let arguments = ProcessInfo.processInfo.arguments
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoSync", isDirectory: true)
        do {
            let configuration = try GUIQALaunchConfiguration.parse(
                arguments: arguments,
                workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
                productionSupportDirectory: support
            )
            qaMode = configuration.mode
            qaRoot = configuration.root
            polling = Task { [weak self] in
                guard let self else { return }
                do {
                    let runtime = try GUIQARuntimeFactory.make(
                        configuration: configuration,
                        productionSupportDirectory: support
                    )
                    self.runtime = runtime
                    try await runtime.prepareInjectedRuntime()
                    self.ready = true
                    await runtime.tick(force: true)
                    self.state = await runtime.current()
                    while !Task.isCancelled {
                        await runtime.tick()
                        self.state = await runtime.current()
                        try? await Task.sleep(for: .seconds(1))
                    }
                } catch {
                    self.qaBlockedReason = error.localizedDescription
                    self.error = "GUI QA 已阻止：\(error.localizedDescription)"
                    self.ready = true
                }
            }
        } catch {
            qaBlockedReason = error.localizedDescription
            self.error = "GUI QA 已阻止：\(error.localizedDescription)"
            ready = true
        }
        return
#endif
        if demo {
            ready = true
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--status"), arguments.indices.contains(index + 1),
               let preview = GlobalStatus(rawValue: arguments[index + 1]) { demoStatus = preview }
            if demoStatus == .error { error = "示例错误：来源暂时不可用。此说明仅用于验证长错误摘要的布局与可读性，不访问真实目录或照片图库。" }
            Task { @MainActor in
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                           width: SourceSettings.preferredWidth,
                                                           height: SourceSettings.initialWindowHeight),
                                      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
                if arguments.contains("--light") { window.appearance = NSAppearance(named: .aqua) }
                window.title = "PhotosYNC 界面验证"
                window.contentView = NSHostingView(rootView: SourceSettings(model: self))
                window.center(); window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.demoWindow = window
            }
            return
        }
        refreshLogin()
        applyNotificationState(notificationPermissions.state)
        polling = Task { [weak self] in
            let runtime = SyncRuntime()
            self?.runtime = runtime
            await runtime.bootstrap()
            self?.ready = true
            while !Task.isCancelled {
                await runtime.tick()
                let state = await runtime.current()
                self?.state = state
                try? await Task.sleep(for: .seconds(1))
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in await self?.runtime?.tick(force: true) } }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshNotificationPermissionState() }
        }
        startNotificationPolling()
    }

    var status: GlobalStatus {
        if qaBlockedReason != nil { return .error }
        if demo { return demoStatus }
        return .resolve(configured: state.sources.contains(where: \.enabled),
                        error: error != nil || state.message != nil || state.snapshot.blockingError != nil || state.snapshot.summaryError != nil,
                        paused: state.snapshot.isPaused,
                        waiting: !state.authorized || !enabledWaiting.isEmpty || ((state.snapshot.summary?.pending ?? 0) > 0 || (state.snapshot.summary?.importing ?? 0) > 0) && !state.snapshot.activeWork,
                        running: state.snapshot.activeWork)
    }
    var enabledWaiting: [UUID: String] {
        let ids = Set(state.sources.filter(\.enabled).map(\.id))
        return state.snapshot.waitingSources.filter { ids.contains($0.key) }
    }
    var statusDescription: String {
        if state.snapshot.isPaused && state.snapshot.activeWork { return "正在暂停，等待当前操作返回" }
        if !ready { return "正在读取配置" }
        return status.description
    }
    var syncDetail: String? {
        state.snapshot.blockingError ?? state.snapshot.summaryError ?? state.message ?? error
    }
    var notificationWarning: String? {
        guard let notificationIssue else { return nil }
        switch notificationIssue {
        case .authorizationDenied:
            return "通知未获授权；可在系统设置中允许 PhotosYNC 通知。"
        case .authorizationStatusUnavailable(let message):
            return "无法读取通知权限：\(message)。请稍后重试或在系统设置中检查 PhotosYNC 通知。"
        case .authorizationRequestFailed(let message):
            return "无法请求通知权限：\(message)。请稍后重试或在系统设置中检查 PhotosYNC 通知。"
        }
    }
    var counters: String { SyncStatusPresentation(snapshot: state.snapshot).summary }
    var scanDescription: String { SyncStatusPresentation(snapshot: state.snapshot).scan }
    var recoveryAdvice: String? { SyncStatusPresentation(snapshot: state.snapshot).recoveryAdvice }
    var hasEnabledSources: Bool { state.sources.contains(where: \.enabled) }
    var canTogglePause: Bool { ready && !demo && hasEnabledSources }
    var isGUIQA: Bool {
#if GUI_QA
        true
#else
        false
#endif
    }
    var isReadOnlyGUIQA: Bool { isGUIQA && qaMode == .readonly }
    var allowsSystemIntegrations: Bool { !demo && !isGUIQA }
    var qaModeDescription: String {
        switch qaMode {
        case .fake:
            return "GUI QA · Fake Photos 网关：不访问系统照片图库"
        case .readonly:
            return "GUI QA · Photos 只读验证：禁止新增、编辑和删除"
        case nil:
            return "GUI QA 已阻止，未创建同步运行环境"
        }
    }
    var photosAuthorizationDescription: String {
        if isReadOnlyGUIQA {
            return "GUI QA 只读验证只枚举现有 Photos 候选。系统授权类别仍显示为“照片”访问，但此构建不会调用任何新增、编辑或删除 API。"
        }
        return "需要“照片”的完整读写权限，才能核对重复并新增照片。请主动授权后开始同步。"
    }
    var syncBoundaryDescription: String {
        if isReadOnlyGUIQA {
            return "GUI QA 只读验证：来源文件和 Photos 仅供读取；所有 Photos 写入请求都会被测试构建拒绝。"
        }
        return "只读取来源文件，向“照片”新增内容。停用来源会保留同步记录。"
    }

    func openSettingsWindow() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                       width: SourceSettings.preferredWidth,
                                                       height: SourceSettings.initialWindowHeight),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "PhotosYNC 设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SourceSettings(model: self))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.deminiaturize(nil)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func authorize() { guard !demo else { return }; Task { await runtime?.requestAuthorization() } }
    func scan() { guard !demo else { return }; Task { await runtime?.tick(force: true) } }
    func togglePause() {
        guard canTogglePause else { return }
        Task {
            if state.snapshot.isPaused { await runtime?.resume() } else { await runtime?.pause() }
            if let runtime { state = await runtime.current() }
        }
    }
    func addSource() {
        guard !demo, ready else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "添加来源"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try await self?.runtime?.add(url); await self?.refresh() }
                catch { self?.error = error.localizedDescription }
            }
        }
    }
    func disable(_ id: UUID) {
        guard !demo else { return }
        Task {
            do { try await runtime?.disable(id); await refresh() }
            catch { self.error = error.localizedDescription }
        }
    }
    func remove(_ id: UUID) {
        guard !demo else { return }
        Task {
            do { try await runtime?.removeSource(id); await refresh() }
            catch { self.error = error.localizedDescription }
        }
    }
    func settingsContentHeightDidChange(_ height: CGFloat) {
        let contentSize = NSSize(width: SourceSettings.preferredWidth, height: height)
        for window in [demoWindow, settingsWindow].compactMap({ $0 }) {
            guard abs((window.contentView?.bounds.height ?? 0) - height) > 0.5 else { continue }
            window.setContentSize(contentSize)
        }
    }
    private func refresh() async { if let runtime { state = await runtime.current() } }
    func openLogs() {
        guard !demo else { return }
        Task { if let url = runtime?.logsURL { NSWorkspace.shared.open(url) } }
    }
    func refreshLogin() {
        guard allowsSystemIntegrations else { return }
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }
    func setLogin(_ enabled: Bool) {
        guard allowsSystemIntegrations, !changingLogin else { return }
        changingLogin = true
        Task {
            defer { refreshLogin(); changingLogin = false }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch { self.error = "登录启动设置失败：\(error.localizedDescription)" }
        }
    }
    func refreshNotificationPermission() {
        guard allowsSystemIntegrations else { return }
        Task { [weak self] in
            await self?.refreshNotificationPermissionState()
        }
    }
    func setNotifications(_ enabled: Bool) {
        guard allowsSystemIntegrations else { return }
        applyNotificationState(notificationPermissions.setPreferenceEnabled(enabled))
        guard enabled else { return }
        Task {
            let state = await notificationPermissions.requestAuthorization()
            applyNotificationState(state)
        }
    }

    private func startNotificationPolling() {
        notificationPolling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshNotificationPermissionState()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
            }
        }
    }

    private func refreshNotificationPermissionState() async {
        guard allowsSystemIntegrations else { return }
        let state = await notificationPermissions.refreshAuthorizationIfNeeded()
        applyNotificationState(state)
    }

    private func applyNotificationState(_ state: NotificationPermissionState) {
        notificationsEnabled = state.preferenceEnabled
        notificationIssue = state.warning
    }

    func quit() {
        polling?.cancel()
        notificationPolling?.cancel()
        Task { await runtime?.stop(); NSApplication.shared.terminate(nil) }
    }
}
