import Foundation
import PhotoSyncCore

/// UI text from one engine snapshot, without creating a runtime or querying Photos.
/// Two calibers are kept apart on purpose: the counters line is standing state read from the
/// store, while the scan line describes what this one round did. An unavailable source is state
/// about a source, never a count of failed files.
struct SyncStatusPresentation {
    let snapshot: EngineSnapshot

    /// A drawing-only modifier, after normal status priority has been resolved. The current
    /// engine exposes mount absence in its root diagnostic text, not a separate reason code.
    /// Use that existing diagnosis without probing paths on the UI thread. Other directory
    /// errors, ordinary queued work and a recovery marker without a root diagnosis stay opaque.
    func dimsStatusIcon(status: GlobalStatus, sources: [RegisteredSource]) -> Bool {
        guard status == .waiting else { return false }
        return sources.contains { source in
            source.enabled && snapshot.waitingSources[source.id]?.isSourceAvailability == true &&
                (snapshot.sourceIssueDetails[source.id] ?? []).contains { issue in
                    issue.kind == .sourceAvailability && issue.path == source.url.path &&
                        issue.summary.contains("未挂载")
                }
        }
    }

    var unknownMutation: Bool {
        if snapshot.livePhotoWork.unknownMutation || snapshot.unknownSubmissionBlock { return true }
        if case .uncertainSubmission = snapshot.recoveryHint { return true }
        return (snapshot.summary?.importing ?? 0) > snapshot.livePhotoWork.ownedImportingFiles && !snapshot.sourceActivities.values.contains(.submitting)
    }

    func globalStatus(enabledSourceIDs: Set<UUID>, authorized: Bool, hasBlockingError: Bool) -> GlobalStatus {
        guard authorized, !hasBlockingError else { return .error }
        let initial = snapshot.summary == nil && snapshot.indexProgress == nil && snapshot.livePhotoInventory == nil && snapshot.latestScan.state == .notStarted
        if initial { return snapshot.isPaused ? .paused : .preparing }
        let issues = enabledIssues(for: enabledSourceIDs)
        let synchronizing = snapshot.sourceActivities.contains { enabledSourceIDs.contains($0.key) && $0.value != .waiting } || livePhotoRunnable(.completion)
        let preparing = snapshot.indexActivity == .working || snapshot.indexActivity == .queued || livePhotoRunnable(.identification)
        let attention = (snapshot.indexProgress?.requiresAttentionAssets ?? 0) > 0 || (snapshot.livePhotoInventory?.requiresAttention ?? 0) > 0 || snapshot.livePhotoWork.requiresAttentionGroups > 0 || snapshot.livePhotoActivities.contains { if case .requiresAttention = $0 { return true }; return false } || (hasFileOrSubmissionIssue(issues, enabledSourceIDs: enabledSourceIDs) && (snapshot.summary?.retryPending ?? 0) == 0)
        let waiting = issues.contains(where: \.isSourceAvailability) || hasDeferredWork(for: enabledSourceIDs) ||
            (snapshot.indexProgress.map { $0.state != .ready || $0.readErrorRepresentations > 0 } ?? false) || snapshot.indexActivity == .waiting || snapshot.hasLivePhotoWork ||
            snapshot.livePhotoIssue != nil || (snapshot.summary?.pending ?? 0) > 0 || (snapshot.summary?.retryPending ?? 0) > 0 ||
            snapshot.latestScan.state != .completed || snapshot.livePhotoActivities.contains { $0 != .idle }
        return .resolve(configured: !enabledSourceIDs.isEmpty || snapshot.hasLivePhotoWork || livePhotoRunnable(.completion) || livePhotoRunnable(.identification),
            error: false, paused: snapshot.isPaused, waiting: waiting, running: synchronizing, authorized: authorized,
            preparing: preparing, unknownMutation: unknownMutation, requiresAttention: attention)
    }

    func statusDescription(for status: GlobalStatus, enabledSourceIDs: Set<UUID>) -> String { status.description }

    func statusReason(for status: GlobalStatus, enabledSourceIDs: Set<UUID>) -> String? {
        if unknownMutation { return "等待‘照片’确认结果，新的保存已暂停" }
        if enabledSourceIDs.isEmpty && !snapshot.hasLivePhotoWork && !livePhotoRunnable(.identification) && !livePhotoRunnable(.completion) { return "请添加或启用来源目录" }
        if livePhotoNeedsAttention { return Self.livePhotoAttentionText }
        if status == .paused && snapshot.activeWork { return "当前操作结束后暂停，已完成的结果会保留。" }
        if status == .waiting {
            if enabledIssues(for: enabledSourceIDs).contains(where: \.isSourceAvailability) { return "来源目录暂不可用，连接恢复后自动继续" }
            if snapshot.livePhotoActivities.contains(.draining) { return "等待系统结束资源读取，完成后自动继续。" }
            if (snapshot.livePhotoInventory?.retryWaiting ?? 0) > 0 || snapshot.livePhotoIssue != nil || snapshot.livePhotoWork.retryWaitingGroups > 0 { return "部分项目暂时无法读取，稍后自动重试" }
            if let issue = snapshot.indexProgress?.issue { return issue }
            return "仍有项目等待处理，稍后自动继续。"
        }
        return nil
    }

    private static let livePhotoAttentionText = "部分项目的 Live Photo 配对需要处理，请查看任务说明。"
    private var livePhotoNeedsAttention: Bool {
        (snapshot.livePhotoInventory?.requiresAttention ?? 0) > 0 || snapshot.livePhotoWork.requiresAttentionGroups > 0
    }

    private func enabledIssues(for enabledSourceIDs: Set<UUID>) -> [SourceIssue] {
        snapshot.waitingSources.compactMap { enabledSourceIDs.contains($0.key) ? $0.value : nil }
    }

    private func hasDeferredWork(for enabledSourceIDs: Set<UUID>) -> Bool {
        !snapshot.deferredSources.intersection(enabledSourceIDs).isEmpty
    }

    private func hasFileOrSubmissionIssue(
        _ issues: [SourceIssue],
        enabledSourceIDs: Set<UUID>
    ) -> Bool {
        issues.contains { $0.kind == .file || $0.kind == .submission } ||
            snapshot.sourceFileIssueCounts.contains {
                enabledSourceIDs.contains($0.key) && $0.value > 0
            }
    }

    struct PreparationProgress: Identifiable {
        let id: String
        let subtitle: String
        let progressText: String?
        let fraction: Double?
        let explanation: String
        var active: Bool = false
        var totalsKnown = false
        var requiresAttentionAssets = 0
        var explanationTitle: String?
        var taskTitle: String { id == "visualIndex" ? "视觉索引" : "Live Photo 配对" }
        var title: String { explanationTitle ?? taskTitle }
        var countText: String? {
            guard var text = progressText else { return nil }
            if totalsKnown {
                for prefix in ["已分析 ", "已处理 "] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
            }
            if requiresAttentionAssets > 0 { text += " · \(requiresAttentionAssets) 张需处理" }
            return text
        }
    }
    static let indexExplanation = "分析照片内容，帮助避免重复导入。"
    static let livePhotoExplanation = "识别照片与视频的配对关系，找到另一半后自动补齐。"

    var progressRows: [PreparationProgress] {
        var rows = [PreparationProgress]()
        if let p = snapshot.indexProgress, p.state != .ready || p.readErrorRepresentations > 0 || snapshot.indexActivity != .idle {
            let active = !snapshot.isPaused && !unknownMutation && (snapshot.indexActivity == .working || snapshot.indexActivity == .queued)
            let subtitle = snapshot.isPaused ? "视觉索引已暂停" : active ? "正在建立视觉索引" : p.requiresAttentionAssets > 0 ? "视觉索引" : "视觉索引等待恢复"
            let title: String, body: String
            if snapshot.isPaused { title = "已暂停"; body = "已完成的结果会保留。" }
            else if p.requiresAttentionAssets > 0 {
                title = "需要提高内存上限"; body = "\(p.requiresAttentionAssets) 张照片超出图像处理内存上限。"
            } else if !active, let issue = p.issue {
                title = "视觉索引等待恢复"; body = issue
            } else { title = "视觉索引"; body = Self.indexExplanation }
            rows.append(.init(id: "visualIndex", subtitle: subtitle,
                progressText: p.totalsKnown ? "已分析 \(p.readyAssets) / \(p.totalAssets) 张" : "已分析 \(p.readyAssets) 张",
                fraction: p.totalsKnown ? (p.totalAssets > 0 ? min(1, Double(p.readyAssets) / Double(p.totalAssets)) : 0) : nil,
                explanation: body, active: active, totalsKnown: p.totalsKnown,
                requiresAttentionAssets: p.requiresAttentionAssets, explanationTitle: title))
        }
        let identifying = livePhotoRunnable(.identification)
        let completing = livePhotoRunnable(.completion)
        if identifying || completing || snapshot.hasLivePhotoWork || snapshot.livePhotoActivities.contains(where: { $0 != .idle }) {
            let inventory = snapshot.livePhotoInventory
            let known = inventory?.phase != .enumerating
            let stillIdentifying = identifying || inventory.map { $0.phase != .completed || $0.pending > 0 || $0.unresolved > 0 } == true
            let text = stillIdentifying && (!completing || identifying) ? inventory.map { known ? "已处理 \($0.processed) / \($0.inventoried) 项" : "已处理 \($0.processed) 项" } : nil
            let fraction = stillIdentifying && !completing && known ? ((inventory?.inventoried ?? 0) > 0 ? min(1, Double(inventory!.processed) / Double(inventory!.inventoried)) : 0) : nil
            let active = !snapshot.isPaused && !unknownMutation && (identifying || completing)
            let attention = (inventory?.requiresAttention ?? 0) > 0 || snapshot.livePhotoWork.requiresAttentionGroups > 0
            let subtitle = snapshot.isPaused ? "Live Photo 已暂停" : unknownMutation ? "Live Photo 等待确认" : active ? "正在配对 Live Photo" : attention ? "Live Photo 需处理" : "Live Photo 等待恢复"
            let title: String, body: String
            if unknownMutation {
                title = "等待“照片”确认"; body = "保存结果尚未确认，新的保存已暂停。"
            } else if snapshot.isPaused {
                if snapshot.livePhotoWork.hasOwnedSubmission {
                    title = "正在结束当前操作"; body = "已提交给“照片”的操作会继续收尾，之后暂停。"
                } else { title = "已暂停"; body = "已完成的结果会保留。" }
            } else if attention {
                title = "Live Photo 需处理"
                body = snapshot.livePhotoIssue?.summary ?? snapshot.livePhotoWork.issue?.summary ?? "部分项目无法自动识别配对关系，请在设置中查看诊断。"
            } else if active {
                title = "Live Photo 配对"
                body = completing && !identifying ? "正在补齐包含动态画面和声音的 Live Photo。" : Self.livePhotoExplanation
            } else {
                title = "Live Photo 等待恢复"
                if snapshot.livePhotoActivities.contains(.draining) { body = "正在等待系统结束资源读取，完成后自动继续。" }
                else { body = snapshot.livePhotoIssue?.summary ?? snapshot.livePhotoWork.issue?.summary ?? "部分原文件暂时无法读取，稍后自动重试。" }
            }
            rows.append(.init(id: "livePhoto", subtitle: subtitle, progressText: text, fraction: fraction,
                explanation: body, active: active, totalsKnown: known, explanationTitle: title))
        }
        return rows
    }

    private func livePhotoRunnable(_ kind: LivePhotoActivityKind) -> Bool {
        snapshot.livePhotoActivities.contains(.working(kind)) || snapshot.livePhotoActivities.contains(.queued(kind))
    }

    /// Exact displayed rows, preserving scan events separately from standing records.
    var scanDetailRows: [(title: String, value: String)] {
        let scan = snapshot.latestScan
        guard scan.state != .notStarted else { return [] }
        let state: String
        switch scan.state {
        case .notStarted: return []
        case .running: state = "进行中"
        case .completed: state = "已完成"
        case .interrupted: state = scan.deferred ? "稍后继续" : "已中断"
        }
        var rows = [(title: "检查候选", value: "\(scan.checkedCandidates)"),
            (title: "新增导入", value: "\(scan.newlyImported)"), (title: "状态", value: state)]
        if scan.failedFiles > 0 { rows.append(("本次读取失败", "\(scan.failedFiles) 个文件")) }
        let unavailableSources = snapshot.waitingSources.values.filter(\.isSourceAvailability).count
        if unavailableSources > 0 { rows.append(("来源等待恢复", "\(unavailableSources) 个来源")) }
        if let date = scan.endedAt ?? scan.startedAt {
            rows.append(("时间", date.formatted(date: .abbreviated, time: .shortened)))
        }
        if let started = scan.startedAt, scan.endedAt != nil {
            rows.append(("开始", started.formatted(date: .abbreviated, time: .shortened)))
        }
        return rows
    }

    var baseSummary: String {
        guard let s = snapshot.summary else { return summary }
        return "已导入 \(s.imported) · 已跳过 \(s.skipped) · 待处理 \(s.pending)"
    }

    var summaryNotes: [String] {
        var notes: [String] = []
        if livePhotoNeedsAttention { notes.append(Self.livePhotoAttentionText) }
        if (snapshot.livePhotoInventory?.retryWaiting ?? 0) > 0 { notes.append("部分项目暂时无法读取，稍后自动重试") }
        if unknownMutation { notes.append("等待‘照片’确认结果，新的保存已暂停") }
        if let issue = snapshot.livePhotoIssue { notes.append(issue.summary) }
        guard let s = snapshot.summary else { return notes }
        if s.retryPending > 0 { notes.append("待重试 \(s.retryPending)") }
        if s.importing > 0 { notes.append("提交中/待确认 \(s.importing)") }
        if s.retainedImported > 0 { notes.append("另有 \(s.retainedImported) 条历史属已停用或移除的来源") }
        if snapshot.summaryError != nil { notes.append("统计暂未更新") }
        return notes
    }

    var summary: String {
        guard let summary = snapshot.summary else {
            return snapshot.summaryError == nil ? "正在读取同步统计…" : "同步统计暂不可用"
        }
        var text = "已导入 \(summary.imported) · 已跳过 \(summary.skipped) · 待处理 \(summary.pending)"
        if summary.retryPending > 0 { text += " · 待重试 \(summary.retryPending)" }
        if summary.importing > 0 { text += " · 提交中/待确认 \(summary.importing)" }
        // Retiring a source keeps its history but drops it from these counters, so say where the
        // numbers went instead of letting the totals look lost or reset.
        if summary.retainedImported > 0 { text += "（另有 \(summary.retainedImported) 条历史属已停用或移除的来源）" }
        if snapshot.summaryError != nil { text += "（统计暂未更新）" }
        return text
    }

    var scan: String {
        let scan = snapshot.latestScan
        guard scan.state != .notStarted else { return "尚未扫描" }
        let phase: String
        switch scan.state {
        case .notStarted: return "尚未扫描"
        case .running: phase = "进行中"
        case .completed: phase = "已完成"
        case .interrupted: phase = scan.deferred ? "稍后继续" : "已中断"
        }
        var text = "本次扫描：检查 \(scan.checkedCandidates) 个候选 · 新增导入 \(scan.newlyImported) · \(phase)"
        // An unreadable file leaves no record and is rediscovered by the next scan, so it is
        // reported as this round's reading failure instead of standing state.
        if scan.failedFiles > 0 { text += " · 本次读取失败 \(scan.failedFiles) 个文件" }
        // A missing directory or volume is a source state that clears when the source answers again.
        let unavailableSources = snapshot.waitingSources.values.filter(\.isSourceAvailability).count
        if unavailableSources > 0 { text += " · \(unavailableSources) 个来源等待恢复" }
        if let date = scan.endedAt ?? scan.startedAt {
            text += " · \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        return text
    }

    var recoveryAdvice: String? {
        switch snapshot.recoveryHint {
        case .uncertainSubmission:
            return "Photos 提交结果尚未确认，请等待核对；程序不会根据一次查询不到就重新导入。"
        case .checkpointFailure:
            return "导入检查点保存失败，新的提交已停止。请退出并重新启动以恢复核对；重启不代表可以直接重试导入。"
        case nil:
            return nil
        }
    }
}
