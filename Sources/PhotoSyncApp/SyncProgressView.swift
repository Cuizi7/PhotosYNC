import AppKit
import SwiftUI
import PhotoSyncCore

/// Standing records from one snapshot; retired history and round events are separate calibers.
struct SyncProgressMetrics {
    let known: Int
    let processed: Int
    let incomplete: Int
    let importedFraction: Double
    let skippedFraction: Double
    let incompleteFraction: Double

    init?(summary: SyncStatusSummary?) {
        guard let summary else { return nil }
        incomplete = summary.pending + summary.importing + summary.retryPending
        processed = summary.imported + summary.skipped
        known = processed + incomplete
        importedFraction = known > 0 ? Double(summary.imported) / Double(known) : 0
        skippedFraction = known > 0 ? Double(summary.skipped) / Double(known) : 0
        incompleteFraction = known > 0 ? Double(incomplete) / Double(known) : 0
    }
}

struct SyncProgressView: View {
    let summary: SyncStatusSummary?
    let stale: Bool
    let snapshot: EngineSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let summary, let metrics = SyncProgressMetrics(summary: summary) {
                counters(metrics.known == 0
                    ? "已发现 0 个文件"
                    : "已处理 \(metrics.processed) / 已发现 \(metrics.known)")
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        segment(.accentColor, fraction: metrics.importedFraction, width: proxy.size.width)
                        segment(Color(nsColor: .secondaryLabelColor), fraction: metrics.skippedFraction, width: proxy.size.width)
                        segment(Color(nsColor: .quaternaryLabelColor), fraction: metrics.incompleteFraction, width: proxy.size.width)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .quaternaryLabelColor))
                    .clipShape(Capsule())
                }
                .frame(height: 6)
                .accessibilityLabel("已导入 \(summary.imported)，已跳过 \(summary.skipped)，未完成 \(metrics.incomplete)")
                HStack(spacing: 12) {
                    legend("已导入", color: .accentColor)
                    legend("已跳过", color: Color(nsColor: .secondaryLabelColor))
                    legend("未完成", color: Color(nsColor: .quaternaryLabelColor))
                }
                if stale {
                    Text("统计暂未更新").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                counters(stale ? "同步统计暂不可用" : "正在读取同步统计…")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync-progress")
    }

    private func counters(_ text: String) -> some View {
        HStack(spacing: 6) {
            StatusMenuSingleLine(text: text).accessibilityIdentifier("sync-counters")
            SyncDetailsButton(snapshot: snapshot)
        }
    }

    @ViewBuilder private func segment(_ color: Color, fraction: Double, width: CGFloat) -> some View {
        if fraction > 0 {
            color.frame(width: width * fraction)
        }
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5).accessibilityHidden(true)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SyncDetailsContent: View {
    let snapshot: EngineSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("已发现的文件").font(.headline)
            if let summary = snapshot.summary {
                VStack(spacing: 5) {
                    count("已导入", summary.imported)
                    count("已跳过", summary.skipped)
                    count("待处理", summary.pending)
                    count("提交中/待确认", summary.importing)
                    count("待重试", summary.retryPending)
                }
                if summary.retainedImported > 0 {
                    Text("另有 \(summary.retainedImported) 条历史属已停用或移除的来源")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(snapshot.summaryError == nil ? "正在读取同步统计…" : "同步统计暂不可用")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(snapshot.summaryError ?? "正在读取同步统计…")
            }
            if let error = snapshot.summaryError, snapshot.summary != nil {
                Text("统计暂未更新")
                    .font(.caption).foregroundStyle(.secondary).help(error)
            }
            Divider()
            Text("本次扫描").font(.headline)
            if snapshot.latestScan.state == .notStarted {
                Text("尚未扫描").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 5) {
                    count("检查候选", snapshot.latestScan.checkedCandidates)
                    count("新增导入", snapshot.latestScan.newlyImported)
                    row("状态", scanState)
                    if snapshot.latestScan.failedFiles > 0 {
                        row("本次读取失败", "\(snapshot.latestScan.failedFiles) 个文件")
                    }
                    let unavailableSources = snapshot.waitingSources.values.filter(\.isSourceAvailability).count
                    if unavailableSources > 0 {
                        row("来源等待恢复", "\(unavailableSources) 个来源")
                    }
                    if let date = snapshot.latestScan.endedAt ?? snapshot.latestScan.startedAt {
                        row("时间", date.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let started = snapshot.latestScan.startedAt, snapshot.latestScan.endedAt != nil {
                        row("开始", started.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            Divider()
            Text("统计当前启用来源的记录，包含此前扫描。总量随新文件发现而增加。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(width: 300, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync-details-content")
    }

    private var scanState: String {
        switch snapshot.latestScan.state {
        case .notStarted: return "尚未扫描"
        case .running: return "进行中"
        case .completed: return "已完成"
        case .interrupted: return snapshot.latestScan.deferred ? "稍后继续" : "已中断"
        }
    }

    private func count(_ title: String, _ value: Int) -> some View {
        row(title, "\(value)")
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

/// Hover is a temporary preview; activating the native button pins the same popover.
struct SyncDetailsButton: View {
    let snapshot: EngineSnapshot
    @State private var presented = false
    @State private var pinned = false
    @State private var buttonHovered = false
    @State private var contentHovered = false
    @State private var hoverTask: Task<Void, Never>?
    @FocusState private var triggerFocused: Bool

    var body: some View {
        Button {
            hoverTask?.cancel()
            pinned = true
            presented = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .focused($triggerFocused)
        .accessibilityLabel("查看同步详情")
        .accessibilityIdentifier("sync-details")
        .onHover { inside in
            buttonHovered = inside
            updateHover()
        }
        .popover(isPresented: $presented, arrowEdge: .trailing) {
            SyncDetailsContent(snapshot: snapshot)
                .onHover { inside in
                    contentHovered = inside
                    updateHover()
                }
                .onExitCommand { presented = false }
        }
        .onExitCommand { presented = false }
        .onChange(of: presented) { visible in
            if !visible {
                hoverTask?.cancel()
                pinned = false
                contentHovered = false
                triggerFocused = true
            }
        }
        .onDisappear {
            hoverTask?.cancel()
            hoverTask = nil
            presented = false
            pinned = false
            buttonHovered = false
            contentHovered = false
        }
    }

    private func updateHover() {
        hoverTask?.cancel()
        guard !pinned else { return }
        let inside = buttonHovered || contentHovered
        guard inside != presented else { return }
        hoverTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 200_000_000) }
            catch { return }
            guard !Task.isCancelled, !pinned,
                  (buttonHovered || contentHovered) == inside else { return }
            presented = inside
        }
    }
}
