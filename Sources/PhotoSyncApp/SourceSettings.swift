import SwiftUI
import PhotoSyncCore

struct SourceSettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Label(model.statusDescription, systemImage: model.status.symbol).font(.headline)
            if model.demo {
                Text("界面验证模式：所有同步、授权和登录启动操作均已禁用。")
                Picker("预览状态", selection: $model.demoStatus) {
                    ForEach(GlobalStatus.allCases, id: \.self) { status in
                        Label(status.description, systemImage: status.symbol).tag(status)
                    }
                }
            }
            Text("只读取来源文件，向“照片”新增内容。停用来源会保留同步记录。")
                .foregroundStyle(.secondary)
            List {
                if model.demo {
                    VStack(alignment: .leading) {
                        Text("/示例来源/很长的目录名称用于验证布局/旅行与家庭照片归档/年份与月份/保留完整可访问路径")
                            .lineLimit(2).truncationMode(.middle)
                        Text("界面示例 · 不读取文件").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(model.state.sources, id: \.id) { source in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(source.url.path).lineLimit(2).truncationMode(.middle).help(source.url.path)
                                .accessibilityLabel(source.url.path)
                            Text(source.enabled ? (model.enabledWaiting[source.id] ?? "已启用") : "已停用 · 记录保留")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if source.enabled { Button("停用") { model.disable(source.id) }.disabled(model.demo) }
                    }
                }
            }.frame(height: 150)
            Button("添加来源目录…", action: model.addSource).disabled(!model.ready || model.demo)
            if !model.state.authorized {
                Text("需要“照片”的完整读写权限，才能核对重复并新增照片。请主动授权后开始同步。")
                Button("授权访问照片", action: model.authorize).disabled(model.demo || !model.ready)
            }
            Divider()
            Toggle("来源首次失败和恢复时通知", isOn: Binding(get: { model.notificationsEnabled }, set: model.setNotifications))
                .disabled(model.demo)
            Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                .disabled(model.demo || model.changingLogin)
            if model.loginNeedsApproval { Text("请在系统设置的“登录项”中批准 PhotoSync。").font(.caption) }
            Text("启动后扫描，每 30 分钟自动扫描；来源不可用时自动等待恢复。")
                .font(.caption).foregroundStyle(.secondary)
            Button("在 Finder 中打开日志目录", action: model.openLogs).disabled(model.demo)
            if let error = model.detail {
                Text(error).foregroundStyle(.red).textSelection(.enabled).lineLimit(5)
                if model.error != nil { Button("关闭提示") { model.error = nil } }
            }
        }
        .padding(24)
        }.frame(width: 600, height: 590)
        .onAppear { model.refreshLogin() }
    }
}
