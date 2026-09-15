import SwiftUI
import PhotoSyncCore

struct SourceSettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
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
                    VStack(alignment: .leading, spacing: 12) {
                        if model.demo {
                            VStack(alignment: .leading) {
                                Text("/示例来源/很长的目录名称用于验证布局/旅行与家庭照片归档/年份与月份/保留完整可访问路径")
                                    .lineLimit(2).truncationMode(.middle)
                                Text("界面示例 · 不读取文件").font(.caption).foregroundStyle(.secondary)
                            }
                        } else if model.state.sources.isEmpty {
                            Text("尚未添加来源目录").foregroundStyle(.secondary)
                        }
                        ForEach(model.state.sources, id: \.id) { source in
                            HStack(spacing: 10) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(source.url.path).lineLimit(2).truncationMode(.middle).help(source.url.path)
                                        .accessibilityLabel(source.url.path)
                                    Text(source.enabled ? (model.enabledWaiting[source.id] ?? "已启用") : "已停用 · 记录保留")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                if source.enabled {
                                    Button("停用") { model.disable(source.id) }
                                        .buttonStyle(.bordered)
                                        .disabled(model.demo)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
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
            .padding(24)
        }
        .frame(width: 600, height: 590)
        .onAppear { model.refreshLogin() }
    }
}
