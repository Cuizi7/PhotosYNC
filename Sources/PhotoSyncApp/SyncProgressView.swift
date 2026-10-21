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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let summary, let metrics = SyncProgressMetrics(summary: summary) {
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
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync-progress")
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
        DetailsScrollView(width: 300) {
            VStack(alignment: .leading, spacing: 10) {
                let presentation = SyncStatusPresentation(snapshot: snapshot)
                ForEach(presentation.progressRows) { progress in
                    Text(progress.subtitle).font(.headline)
                    if let text = progress.progressText { row("进度", text) }
                    Text(progress.explanation).font(.caption).foregroundStyle(.secondary)
                    Divider()
                }
                if presentation.progressRows.isEmpty, let p = snapshot.indexProgress, p.state != .ready {
                    Text("视觉索引").font(.headline)
                    row("进度", p.totalsKnown ? "已分析 \(p.readyAssets) / \(p.totalAssets) 张" : "已分析 \(p.readyAssets) 张")
                    if let issue = p.issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
                    Text(SyncStatusPresentation.indexExplanation).font(.caption).foregroundStyle(.secondary)
                    Divider()
                }
                if let inventory = snapshot.livePhotoInventory, !presentation.progressRows.contains(where: { $0.id == "livePhoto" }) {
                    Text("Live Photo").font(.headline)
                    row("进度", inventory.phase == .enumerating ? "已处理 \(inventory.identified) 项" : "已处理 \(inventory.identified) / \(inventory.inventoried) 项")
                    if inventory.retryWaiting > 0 { row("等待重试", "\(inventory.retryWaiting)") }
                    if inventory.requiresAttention > 0 { row("需要处理", "\(inventory.requiresAttention)") }
                    Text(SyncStatusPresentation.livePhotoExplanation).font(.caption).foregroundStyle(.secondary)
                    Divider()
                }
                ForEach(presentation.summaryNotes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
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
                Text("统计当前启用来源的记录，包含此前扫描。总量随新文件发现而增加。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("本次扫描").font(.headline)
                if snapshot.latestScan.state == .notStarted {
                    Text("尚未扫描").font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 5) {
                        ForEach(SyncStatusPresentation(snapshot: snapshot).scanDetailRows, id: \.title) { item in
                            row(item.title, item.value)
                        }
                    }
                }
                Text("仅统计本轮扫描事件；文件读取失败与来源等待分别计数，不与上方记录数相加。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync-details-content")
    }

    private func count(_ title: String, _ value: Int) -> some View {
        row(title, "\(value)")
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

struct SyncDetailsButton: View {
    let snapshot: EngineSnapshot

    var accessibilityLabel: String {
        SyncStatusPresentation(snapshot: snapshot).progressRows.isEmpty ? "查看同步详情" : "查看图库分析与同步详情"
    }

    var body: some View {
        HoverDetailsButton(accessibilityLabel: accessibilityLabel, accessibilityIdentifier: "sync-details") {
            Image(systemName: "info.circle")
        } content: {
            SyncDetailsContent(snapshot: snapshot)
        }
    }
}

/// Both surfaces consume the same rows. The details trigger retains identity through activity changes.
struct SyncWorkProgressView: View {
    let snapshot: EngineSnapshot
    let showSourceProgress: Bool
    let showActiveProgress: Bool

    private var rows: [SyncStatusPresentation.PreparationProgress] { showActiveProgress ? SyncStatusPresentation(snapshot: snapshot).progressRows : [] }
    private var sourceCount: String {
        guard let metrics = SyncProgressMetrics(summary: snapshot.summary) else { return snapshot.summaryError == nil ? "正在读取同步统计…" : "同步统计暂不可用" }
        return "已处理 \(metrics.processed) / 已发现 \(metrics.known)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let text = rows.first?.progressText { StatusMenuSingleLine(text: text) }
                else if showSourceProgress { StatusMenuSingleLine(text: sourceCount) }
                SyncDetailsButton(snapshot: snapshot)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0, let text = row.progressText { StatusMenuSingleLine(text: text) }
                if let fraction = row.fraction {
                    ProgressView(value: fraction).accessibilityLabel(row.progressText ?? row.subtitle)
                } else { ProgressView().controlSize(.small).accessibilityLabel(row.subtitle) }
                Text(row.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            if showActiveProgress && showSourceProgress && (rows.isEmpty || snapshot.sourceActivities.values.contains(where: { $0 != .waiting })) {
                if !rows.isEmpty { StatusMenuSingleLine(text: sourceCount) }
                SyncProgressView(summary: snapshot.summary, stale: snapshot.summaryError != nil)
            }
            if showActiveProgress && rows.isEmpty && !showSourceProgress { ProgressView().controlSize(.small) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync-work-progress")
        .tint(.accentColor)
    }
}
