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
    @Published var ready = false
    @Published var demoStatus: GlobalStatus = .unconfigured
    let demo: Bool
    private var demoWindow: NSWindow?
    private var runtime: SyncRuntime?
    private var polling: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    init(demo: Bool = ProcessInfo.processInfo.arguments.contains("--demo")) {
        self.demo = demo
        if demo {
            ready = true
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--status"), arguments.indices.contains(index + 1),
               let preview = GlobalStatus(rawValue: arguments[index + 1]) { demoStatus = preview }
            if demoStatus == .error { error = "示例错误：来源暂时不可用。此说明仅用于验证长错误摘要的布局与可读性，不访问真实目录或照片图库。" }
            Task { @MainActor in
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 648, height: 640),
                                      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
                if arguments.contains("--light") { window.appearance = NSAppearance(named: .aqua) }
                window.title = "PhotoSync 界面验证"
                window.contentView = NSHostingView(rootView: SourceSettings(model: self))
                window.center(); window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.demoWindow = window
            }
            return
        }
        refreshLogin()
        notificationsEnabled = UserDefaults.standard.bool(forKey: "sourceNotifications")
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
    }

    var status: GlobalStatus {
        if demo { return demoStatus }
        return .resolve(configured: state.sources.contains(where: \.enabled),
                        error: error != nil || state.message != nil || state.snapshot.blockingError != nil,
                        paused: state.snapshot.isPaused,
                        waiting: !state.authorized || !enabledWaiting.isEmpty || state.snapshot.pending > 0 && !state.snapshot.activeWork,
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
    var detail: String? { error ?? state.message ?? state.snapshot.blockingError }
    var counters: String {
        let s = state.snapshot
        return "检查 \(s.checked) · 导入 \(s.imported) · 跳过 \(s.skipped) · 失败 \(s.failed) · 待处理 \(s.pending)"
    }

    func authorize() { guard !demo else { return }; Task { await runtime?.requestAuthorization() } }
    func scan() { guard !demo else { return }; Task { await runtime?.tick(force: true) } }
    func togglePause() {
        guard !demo else { return }
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
    private func refresh() async { if let runtime { state = await runtime.current() } }
    func openLogs() {
        guard !demo else { return }
        Task { if let url = runtime?.logsURL { NSWorkspace.shared.open(url) } }
    }
    func refreshLogin() {
        guard !demo else { return }
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }
    func setLogin(_ enabled: Bool) {
        guard !demo, !changingLogin else { return }
        changingLogin = true
        Task {
            defer { refreshLogin(); changingLogin = false }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch { self.error = "登录启动设置失败：\(error.localizedDescription)" }
        }
    }
    func setNotifications(_ enabled: Bool) {
        guard !demo else { return }
        if !enabled {
            notificationsEnabled = false
            UserDefaults.standard.set(false, forKey: "sourceNotifications")
            return
        }
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                notificationsEnabled = granted
                UserDefaults.standard.set(granted, forKey: "sourceNotifications")
                if !granted { error = "通知未获授权；可在系统设置中允许 PhotoSync 通知。" }
            } catch { self.error = error.localizedDescription }
        }
    }

    func quit() {
        polling?.cancel()
        Task { await runtime?.stop(); NSApplication.shared.terminate(nil) }
    }
}
