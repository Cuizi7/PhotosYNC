import AppKit
import SwiftUI
import PhotoSyncCore

struct StatusMenu: View {
    @ObservedObject var model: AppModel
    @State private var measuredStatusHeight: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                statusContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: StatusMenuContentHeightKey.self, value: proxy.size.height)
                        }
                    }
            }
            .frame(height: min(measuredStatusHeight, maximumStatusHeight))
            Divider().padding(.vertical, 8)
            actions
        }
        .padding(14).frame(width: 320)
        .onPreferenceChange(StatusMenuContentHeightKey.self) { height in
            guard height > 0, abs(measuredStatusHeight - height) > 0.5 else { return }
            measuredStatusHeight = height
        }
    }

    private var maximumStatusHeight: CGFloat {
        let visibleScreenHeight = NSScreen.screens.map { $0.visibleFrame.height }.min() ?? 660
        return min(440, max(160, visibleScreenHeight - 220))
    }

    private var statusContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.statusDescription, systemImage: model.status.symbol)
                    .font(.headline).accessibilityLabel(model.statusDescription)
                    .accessibilityIdentifier("photosync-status")
                Spacer()
                if model.analysis == nil && !model.state.sources.contains(where: \.enabled) {
                    SyncDetailsButton(snapshot: model.state.snapshot)
                }
                if model.state.snapshot.activeWork {
                    ProgressView().controlSize(.small)
                }
            }
            if model.isGUIQA {
                Text(model.qaModeDescription).font(.caption).foregroundStyle(.orange)
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
                .help(model.syncDetailHelp ?? detail)
            }
            if let hint = model.recoveryAdvice {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            if let analysis = model.analysis {
                LibraryAnalysisView(analysis: analysis, snapshot: model.state.snapshot).tint(.accentColor)
                if model.state.snapshot.summary != nil, model.state.snapshot.summaryError != nil {
                    Text("统计暂未更新").font(.caption).foregroundStyle(.secondary)
                }
            } else if model.state.sources.contains(where: \.enabled) {
                SyncProgressView(summary: model.state.snapshot.summary,
                    stale: model.state.snapshot.summaryError != nil, snapshot: model.state.snapshot)
            } else if model.state.snapshot.summary != nil, model.state.snapshot.summaryError != nil {
                Text("统计暂未更新").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.state.sources.filter(\.enabled), id: \.id) { source in
                if let issue = model.enabledWaiting[source.id] {
                    SourceRowLabel(url: source.url, status: issue.summary, detail: issue.detail,
                        fileIssueCount: model.fileIssueCount(for: source.id))
                } else if let phase = model.state.snapshot.advancedWaitingReasons[source.id] ?? model.state.snapshot.sourcePhases[source.id] {
                    SourceRowLabel(url: source.url, status: phase,
                        fileIssueCount: model.fileIssueCount(for: source.id))
                }
            }
            if let warning = model.notificationWarning {
                Label(warning, systemImage: "bell.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let next = model.state.nextScan, !model.state.snapshot.activeWork {
                Text("下次扫描：\(next.formatted(date: .omitted, time: .shortened))").font(.caption)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: model.scan) {
                    Text("立即扫描").frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("scan-now")
                .disabled(!model.ready || model.state.snapshot.activeWork || model.state.snapshot.isPaused || !model.state.authorized || model.demo)
                Button(action: model.togglePause) {
                    Text(model.state.snapshot.isPaused ? "继续同步" : "暂停同步")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("toggle-pause")
                .disabled(!model.canTogglePause)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            Divider()
            HStack(spacing: 4) {
                if #available(macOS 14.0, *) {
                    SettingsLink { Text("设置").frame(maxWidth: .infinity, alignment: .leading) }
                        .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
                        .accessibilityIdentifier("open-settings")
                } else {
                    Button(action: model.openSettingsWindow) {
                        Text("设置").frame(maxWidth: .infinity, alignment: .leading)
                    }
                        .accessibilityIdentifier("open-settings")
                }
                Divider().frame(height: 14)
                Button(action: model.quit) {
                    Text("退出 PhotosYNC").frame(maxWidth: .infinity, alignment: .trailing)
                }
                .keyboardShortcut("q")
            }
            .buttonStyle(.plain)
        }
    }
}

private struct StatusMenuContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The critical passive rows keep system caption metrics and never truncate counts.
struct StatusMenuSingleLine: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: true)
    }
}

struct LibraryAnalysisView: View {
    let analysis: SyncStatusPresentation.Analysis
    let snapshot: EngineSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                StatusMenuSingleLine(text: analysis.progressText)
                SyncDetailsButton(snapshot: snapshot)
            }
            if let fraction = analysis.fraction {
                ProgressView(value: fraction).accessibilityLabel(analysis.progressText)
            } else {
                ProgressView().controlSize(.small).accessibilityLabel(analysis.progressText)
            }
            if let detail = analysis.detail {
                if detail == "正在等待 iCloud 图像，连接恢复后自动继续" {
                    StatusMenuSingleLine(text: detail)
                } else {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(analysis.explanation).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-analysis")
    }
}
