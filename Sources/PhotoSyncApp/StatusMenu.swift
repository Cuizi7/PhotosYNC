import SwiftUI
import PhotoSyncCore

struct StatusMenu: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.statusDescription, systemImage: model.status.symbol)
                .font(.headline).accessibilityLabel(model.statusDescription)
            if model.state.snapshot.activeWork { ProgressView().controlSize(.small) }
            ForEach(model.state.sources.filter(\.enabled), id: \.id) { source in
                if let phase = model.enabledWaiting[source.id] ?? model.state.snapshot.sourcePhases[source.id] {
                    Text("\(source.url.lastPathComponent)：\(phase)").font(.caption).lineLimit(2).help(source.url.path)
                }
            }
            Text(model.counters).font(.caption).foregroundStyle(.secondary)
            if let detail = model.detail {
                Text(detail).font(.caption).lineLimit(3)
                Text("若 Photos 提交结果不确定，请等待确认；检查点失败后需退出并重新启动。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let next = model.state.nextScan {
                Text("下次扫描：\(next.formatted(date: .omitted, time: .shortened))").font(.caption)
            }
            Divider()
            Button("立即扫描", action: model.scan)
                .disabled(!model.ready || model.state.snapshot.activeWork || model.state.snapshot.isPaused || !model.state.authorized || model.demo)
            Button(model.state.snapshot.isPaused ? "继续同步" : "暂停同步", action: model.togglePause)
                .disabled(!model.ready || model.demo)
            if #available(macOS 14.0, *) {
                SettingsLink { Text("来源与设置…") }
                    .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
            } else {
                Button("来源与设置…", action: model.openSettingsWindow)
            }
            Button("在 Finder 中打开日志目录", action: model.openLogs).disabled(model.demo)
            Divider()
            Button("退出 PhotoSync", action: model.quit).keyboardShortcut("q")
        }
        .padding(16).frame(width: 320)
    }
}
