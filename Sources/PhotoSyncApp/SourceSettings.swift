import SwiftUI
import PhotoSyncCore

struct SourceSettings: View {
    static let preferredWidth: CGFloat = 600
    static let initialWindowHeight: CGFloat = 420
    static let maximumContentHeight: CGFloat = 680

    @ObservedObject var model: AppModel
    @State private var measuredContentHeight: CGFloat?
    @State private var pendingRemoval: RegisteredSource?

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
            Button("取消", role: .cancel) {}
        } message: { source in
            Text("这只会移除“\(source.url.lastPathComponent)”的同步配置；不会删除来源文件、Photos 中的照片或既有同步记录。")
        }
    }

    private var contentHeight: CGFloat {
        measuredContentHeight ?? Self.initialWindowHeight
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(model.statusDescription, systemImage: model.status.symbol)
                .font(.headline)
                .accessibilityIdentifier("photosync-settings-status")
            if model.isGUIQA {
                Text(model.qaModeDescription)
                    .font(.callout)
                    .foregroundStyle(.orange)
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
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("来源").font(.headline)
                    Spacer()
                    Button("添加来源目录…", action: model.addSource)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("add-source")
                        .disabled(!model.ready || model.demo)
                }
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
                .accessibilityIdentifier("source-list")
            }

            if !model.state.authorized {
                Divider()
                Text(model.photosAuthorizationDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("授权访问照片", action: model.authorize)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("authorize-photos")
                    .disabled(model.demo || !model.ready)
            }

            Divider()

            Text("同步选项").font(.headline)
            Toggle("来源首次失败和恢复时通知", isOn: Binding(get: { model.notificationsEnabled }, set: model.setNotifications))
                .disabled(!model.allowsSystemIntegrations)
            Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                .disabled(!model.allowsSystemIntegrations || model.changingLogin)
            if model.loginNeedsApproval {
                Text("请在系统设置的“登录项”中批准 PhotosYNC。").font(.caption).foregroundStyle(.secondary)
            }
            Text("启动后扫描，每 30 分钟自动扫描；来源不可用时自动等待恢复。")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            HStack {
                Text("诊断").font(.headline)
                Spacer()
                Button("在 Finder 中打开日志目录", action: model.openLogs)
                    .buttonStyle(.bordered)
                    .disabled(model.demo)
            }
            if let error = model.detail {
                Text(error).foregroundStyle(.red).textSelection(.enabled).lineLimit(5)
                if model.error != nil { Button("关闭提示") { model.error = nil } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var demoSourceRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("/示例来源/很长的目录名称用于验证布局/旅行与家庭照片归档/年份与月份/保留完整可访问路径")
                    .lineLimit(2).truncationMode(.middle)
                Text("界面示例 · 不读取文件").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.url.path).lineLimit(2).truncationMode(.middle).help(source.url.path)
                    .accessibilityLabel(source.url.path)
                Text(source.enabled ? (model.enabledWaiting[source.id] ?? "已启用") : "已停用 · 记录保留")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if source.enabled {
                    Button("停用") { model.disable(source.id) }
                        .buttonStyle(.bordered)
                        .disabled(model.demo)
                }
                Button("移除") { pendingRemoval = source }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("remove-source-\(source.id.uuidString)")
                    .disabled(model.demo || !model.ready)
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
