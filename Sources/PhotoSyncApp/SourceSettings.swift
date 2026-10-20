import SwiftUI
import PhotoSyncCore

struct SourceSettings: View {
    static let preferredWidth: CGFloat = 600
    static let initialWindowHeight: CGFloat = 420
    static let maximumContentHeight: CGFloat = 680

    @ObservedObject var model: AppModel
    @State private var measuredContentHeight: CGFloat?
    @State private var pendingRemoval: RegisteredSource?
    @State private var measuredUpperHeight: CGFloat = 1
    @State private var measuredLowerHeight: CGFloat = 1
    @State private var measuredListHeight: CGFloat = 1

    var body: some View {
        ScrollView {
            settingsContent
                .padding(24)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: SourceSettingsContentHeightKey.self, value: proxy.size.height)
                    }
                }
        }
        .frame(width: Self.preferredWidth, height: contentHeight)
        .onAppear {
            model.refreshLogin()
            model.refreshNotificationPermission()
        }
        .onPreferenceChange(SourceSettingsSectionHeightKey.self) { heights in
            if let height = heights["upper"], abs(measuredUpperHeight - height) > 0.5 { measuredUpperHeight = height }
            if let height = heights["lower"], abs(measuredLowerHeight - height) > 0.5 { measuredLowerHeight = height }
            if let height = heights["list"], abs(measuredListHeight - height) > 0.5 { measuredListHeight = height }
        }
        .onPreferenceChange(SourceSettingsContentHeightKey.self) { height in
            guard height > 0 else { return }
            let cappedHeight = min(height, Self.maximumContentHeight)
            guard measuredContentHeight.map({ abs($0 - cappedHeight) > 0.5 }) ?? true else { return }
            measuredContentHeight = cappedHeight
            model.settingsContentHeightDidChange(cappedHeight)
        }
        .confirmationDialog(
            "移除此来源目录？",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { source in
            Button("移除来源", role: .destructive) {
                model.remove(source.id)
                pendingRemoval = nil
            }
            .disabled(model.demo || !model.ready || model.changingSources.contains(source.id))
            Button("取消", role: .cancel) {}
        } message: { source in
            Text("这只会移除“\(source.url.lastPathComponent)”的同步配置；不会删除来源文件、Photos 中的照片或既有同步记录。")
        }
    }

    private var contentHeight: CGFloat {
        measuredContentHeight ?? Self.initialWindowHeight
    }

    // The list gets only the space left by measured static sections. If those sections
    // themselves overflow, the bounded outer ScrollView remains the accessibility fallback.
    private var sourceViewportHeight: CGFloat {
        let staticHeight = measuredUpperHeight + measuredLowerHeight + 36 + 48
        return min(measuredListHeight, max(44, min(280, Self.maximumContentHeight - staticHeight)))
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 18) {
                settingsStatus
                Divider()
                HStack {
                    Text("来源").font(.headline)
                    Spacer()
                    Button("添加来源目录…", action: model.addSource)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("add-source")
                        .disabled(!model.ready || model.demo)
                }
            }
            .background(sectionMeasurement("upper"))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.demo {
                        demoSourceRow
                    } else if model.state.sources.isEmpty {
                        Text("尚未添加来源目录").foregroundStyle(.secondary)
                    }
                    ForEach(model.state.sources, id: \.id) { source in
                        sourceRow(source)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .fixedSize(horizontal: false, vertical: true)
                .background(sectionMeasurement("list"))
            }
            .frame(height: sourceViewportHeight)
            .accessibilityIdentifier("source-list")
            VStack(alignment: .leading, spacing: 18) {
                Divider()
                syncOptions
                Divider()
                HStack {
                    Text("诊断").font(.headline)
                    Spacer()
                    Button("在 Finder 中打开日志目录", action: model.openLogs)
                        .buttonStyle(.bordered)
                        .disabled(model.demo)
                }
                .accessibilityIdentifier("settings-diagnostics")
                Text(releaseDescription).font(.caption).foregroundStyle(.secondary)
            }
            .background(sectionMeasurement("lower"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settingsStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(model.statusDescription, systemImage: model.status.symbol)
                .font(.headline)
                .accessibilityIdentifier("photosync-settings-status")
            if model.isGUIQA {
                Text(model.qaModeDescription)
                    .font(.callout).foregroundStyle(.orange)
                    .accessibilityIdentifier("gui-qa-mode")
                if let root = model.qaRoot {
                    Text("测试数据目录：\(root.path)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if model.demo {
                Text("界面验证模式：所有同步、授权和登录启动操作均已禁用。")
                Picker("预览状态", selection: $model.demoStatus) {
                    ForEach(GlobalStatus.allCases, id: \.self) { status in
                        Label(status.description, systemImage: status.symbol).tag(status)
                    }
                }
            }
            Text(model.syncBoundaryDescription)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.state.authorized {
                Text(model.photosAuthorizationDescription)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("授权访问照片", action: model.authorize)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("authorize-photos")
                    .disabled(model.demo || !model.ready)
            }
            // The authorization explanation is above; preserve independent issues even when
            // AppModel's primary detail gives the permission problem precedence.
            ForEach(settingsIssueSummaries, id: \.self) { detail in
                Text(detail).font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled).lineLimit(5)
                    .help(settingsIssueHelp(for: detail))
            }
            if let advice = model.recoveryAdvice {
                Text(advice).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.error != nil { Button("关闭提示") { model.error = nil } }
        }
    }

    private var settingsIssueSummaries: [String] {
        let candidates: [String?] = [model.state.authorized ? model.syncDetail : nil,
            model.state.snapshot.blockingSummary,
            model.state.snapshot.summaryError == nil ? nil : "同步统计暂时读不到，稍后会自动重试。",
            model.state.message, model.state.warning, model.error]
        return candidates.compactMap { $0 }.reduce(into: []) { result, text in
            if !result.contains(text) { result.append(text) }
        }
    }

    private func settingsIssueHelp(for summary: String) -> String {
        var details: [String?] = [summary]
        if summary == model.state.snapshot.blockingSummary { details.append(model.state.snapshot.blockingError) }
        if summary == "同步统计暂时读不到，稍后会自动重试。" { details.append(model.state.snapshot.summaryError) }
        if summary == model.state.message { details.append(model.state.messageDetail) }
        if summary == model.state.warning { details.append(model.state.warningDetail) }
        if summary == model.syncDetail { details.append(model.syncDetailHelp) }
        return details.compactMap { $0 }.reduce(into: [String]()) { result, detail in
            if !result.contains(detail) { result.append(detail) }
        }.joined(separator: "\n")
    }

    private var syncOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("同步选项").font(.headline)
            Toggle("来源首次失败和恢复时通知", isOn: Binding(get: { model.notificationsEnabled }, set: model.setNotifications))
                .disabled(!model.allowsSystemIntegrations)
            if let warning = model.notificationWarning {
                Label(warning, systemImage: "bell.slash")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                .disabled(!model.allowsSystemIntegrations || model.changingLogin)
            if model.loginNeedsApproval {
                Text("请在系统设置的“登录项”中批准 PhotosYNC。").font(.caption).foregroundStyle(.secondary)
            }
            Text("启动后扫描，每 30 分钟自动扫描；来源不可用时自动等待恢复。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("settings-sync-options")
    }

    private func sectionMeasurement(_ name: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: SourceSettingsSectionHeightKey.self, value: [name: proxy.size.height])
        }
    }

    private var releaseDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let channel = Bundle.main.object(forInfoDictionaryKey: "PhotoSyncReleaseChannel") as? String ?? "beta"
        return "PhotosYNC \(version) \(channel)"
    }

    private var demoSourceRow: some View {
        HStack(spacing: 10) {
            SourceRowLabel(
                url: URL(fileURLWithPath: "/示例来源/很长的目录名称用于验证布局/旅行与家庭照片归档/年份与月份/保留完整可访问路径"),
                status: "界面示例 · 不读取文件")
            HStack(spacing: 6) {
                Button("停用") {}
                    .buttonStyle(.bordered)
                    .disabled(true)
                Button("移除") {}
                    .buttonStyle(.bordered)
                    .disabled(true)
            }
        }
    }

    private func sourceRow(_ source: RegisteredSource) -> some View {
        HStack(spacing: 10) {
            SourceRowLabel(url: source.url,
                status: source.enabled ? (model.enabledWaiting[source.id]?.summary ?? "已启用") : "已停用 · 记录保留",
                issues: source.enabled ? (model.state.snapshot.sourceIssueDetails[source.id] ?? []) : [],
                recoveryPending: source.enabled && model.recoveryPending(for: source.id),
                isScanningDirectory: source.enabled && model.isScanningDirectory(for: source.id))
            HStack(spacing: 6) {
                Button(source.enabled ? "停用" : "启用") {
                    if source.enabled { model.disable(source.id) }
                    else { model.enable(source.id) }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("\(source.enabled ? "disable" : "enable")-source-\(source.id.uuidString)")
                .disabled(model.demo || !model.ready || model.changingSources.contains(source.id))
                Button("移除") { pendingRemoval = source }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("remove-source-\(source.id.uuidString)")
                    .disabled(model.demo || !model.ready || model.changingSources.contains(source.id))
            }
        }
    }
}

private struct SourceSettingsContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SourceSettingsSectionHeightKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
