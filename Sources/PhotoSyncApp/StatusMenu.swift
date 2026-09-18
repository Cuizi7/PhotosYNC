import SwiftUI
import PhotoSyncCore

struct StatusMenu: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(model.statusDescription, systemImage: model.status.symbol)
                .font(.headline).accessibilityLabel(model.statusDescription)
                .accessibilityIdentifier("photosync-status")
            if model.isGUIQA {
                Text(model.qaModeDescription).font(.caption).foregroundStyle(.orange)
            }
            if model.state.snapshot.activeWork {
                ProgressView().controlSize(.small)
            }
            ForEach(model.state.sources.filter(\.enabled), id: \.id) { source in
                // The line is plain language; the raw system text stays in the tooltip so the
                // menu never greets a person with "The file “home” couldn’t be opened…".
                if let issue = model.enabledWaiting[source.id] {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.url.lastPathComponent).font(.caption.weight(.medium)).lineLimit(1)
                        Text(issue.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        // Unreadable files keep no record, so this count is the only standing trace
                        // of them beyond the journal; it disappears with the next clean scan.
                        if model.fileIssueCount(for: source.id) > 0 {
                            Text("另有 \(model.fileIssueCount(for: source.id)) 个文件读取失败")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .help("\(source.url.path)\n\(issue.detail)\n\(issue.summary)")
                } else if let phase = model.state.snapshot.sourcePhases[source.id] {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.url.lastPathComponent).font(.caption.weight(.medium)).lineLimit(1)
                        Text(phase).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .help(source.url.path)
                }
            }
            Text(model.counters).font(.caption).foregroundStyle(.secondary)
            Text(model.scanDescription).font(.caption).foregroundStyle(.secondary)
            if let warning = model.notificationWarning {
                Label(warning, systemImage: "bell.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let detail = model.syncDetail {
                Group {
                    if model.status == .error {
                        Label(detail, systemImage: "exclamationmark.triangle")
                    } else {
                        Text(detail)
                    }
                }
                .font(.caption).lineLimit(3)
                // Diagnosis stays one hover away instead of occupying the headline.
                .help(model.syncDetailHelp ?? detail)
            }
            if let hint = model.recoveryAdvice {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            if let next = model.state.nextScan {
                Text("下次扫描：\(next.formatted(date: .omitted, time: .shortened))").font(.caption)
            }
            Divider().padding(.vertical, 2)
            Button("立即扫描", action: model.scan)
                .accessibilityIdentifier("scan-now")
                .disabled(!model.ready || model.state.snapshot.activeWork || model.state.snapshot.isPaused || !model.state.authorized || model.demo)
            Button(model.state.snapshot.isPaused ? "继续同步" : "暂停同步", action: model.togglePause)
                .accessibilityIdentifier("toggle-pause")
                .disabled(!model.canTogglePause)
            if #available(macOS 14.0, *) {
                SettingsLink { Text("设置…") }
                    .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
                    .accessibilityIdentifier("open-settings")
            } else {
                Button("设置…", action: model.openSettingsWindow)
                    .accessibilityIdentifier("open-settings")
            }
            Divider().padding(.vertical, 2)
            Button("退出 PhotosYNC", action: model.quit).keyboardShortcut("q")
        }
        .padding(14).frame(width: 320)
    }
}
