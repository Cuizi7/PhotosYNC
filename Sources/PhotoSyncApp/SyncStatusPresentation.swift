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
        let synchronizing = snapshot.sourceActivities.contains { enabledSourceIDs.contains($0.key) && $0.value != .waiting } || snapshot.livePhotoActivities.contains(.working(.completion))
        let preparing = snapshot.indexActivity == .working || snapshot.livePhotoActivities.contains(.working(.identification))
        let attention = (snapshot.livePhotoInventory?.requiresAttention ?? 0) > 0 || snapshot.livePhotoWork.requiresAttentionGroups > 0 || snapshot.livePhotoActivities.contains { if case .requiresAttention = $0 { return true }; return false } || (hasFileOrSubmissionIssue(issues, enabledSourceIDs: enabledSourceIDs) && (snapshot.summary?.retryPending ?? 0) == 0)
        let waiting = issues.contains(where: \.isSourceAvailability) || hasDeferredWork(for: enabledSourceIDs) ||
            (snapshot.indexProgress.map { $0.state != .ready } ?? false) || snapshot.hasLivePhotoWork ||
            snapshot.livePhotoIssue != nil || (snapshot.summary?.pending ?? 0) > 0 || (snapshot.summary?.retryPending ?? 0) > 0 ||
            snapshot.latestScan.state != .completed || snapshot.livePhotoActivities.contains { $0 != .idle }
        return .resolve(configured: !enabledSourceIDs.isEmpty || snapshot.hasLivePhotoWork || snapshot.livePhotoActivities.contains(.working(.completion)) || snapshot.livePhotoActivities.contains(.working(.identification)),
            error: false, paused: snapshot.isPaused, waiting: waiting, running: synchronizing, authorized: authorized,
            preparing: preparing, unknownMutation: unknownMutation, requiresAttention: attention)
    }

    func statusDescription(for status: GlobalStatus, enabledSourceIDs: Set<UUID>) -> String { status.description }

    func statusReason(for status: GlobalStatus, enabledSourceIDs: Set<UUID>) -> String? {
        if unknownMutation { return "等待‘照片’确认结果，新的保存已暂停" }
        if enabledSourceIDs.isEmpty && !snapshot.hasLivePhotoWork { return "请添加或启用来源目录" }
        if let attention = snapshot.livePhotoActivities.compactMap({ activity -> SourceIssue? in
            if case .requiresAttention(let issue) = activity { return issue }; return nil
        }).first { return attention.summary }
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
    }
    static let indexExplanation = "视觉索引用于避免重复导入。必要时会从 iCloud 获取原文件并产生流量，系统可能保留本地缓存。分析结果会保存，重启后继续未完成项，不会重复分析未变化的成功结果。"
    static let livePhotoExplanation = "核对原文件中的配对关系，并补齐包含动态画面和声音的 Live Photo。必要时会从 iCloud 获取原文件并产生流量，系统可能保留本地缓存。结果会保存，重启后继续未完成项，不会重复分析未变化的成功结果。"

    var progressRows: [PreparationProgress] {
        guard !snapshot.isPaused else { return [] }
        var rows = [PreparationProgress]()
        if snapshot.indexActivity == .working, let p = snapshot.indexProgress, p.state != .ready {
            rows.append(.init(id: "visualIndex", subtitle: "正在建立视觉索引",
                progressText: p.totalsKnown ? "已分析 \(p.readyAssets) / \(p.totalAssets) 张" : "已分析 \(p.readyAssets) 张",
                fraction: p.totalsKnown && p.totalAssets > 0 ? min(1, Double(p.readyAssets) / Double(p.totalAssets)) : nil,
                explanation: Self.indexExplanation))
        }
        let identifying = snapshot.livePhotoActivities.contains(.working(.identification))
        let completing = snapshot.livePhotoActivities.contains(.working(.completion))
        if identifying || completing {
            let inventory = snapshot.livePhotoInventory
            let known = inventory?.phase != .enumerating
            let text = identifying ? inventory.map { known ? "已处理 \($0.identified) / \($0.inventoried) 项" : "已处理 \($0.identified) 项" } : nil
            let fraction = identifying && !completing && known && (inventory?.inventoried ?? 0) > 0 ? Double(inventory!.identified) / Double(inventory!.inventoried) : nil
            rows.append(.init(id: "livePhoto", subtitle: "正在配对 Live Photo", progressText: text, fraction: fraction, explanation: Self.livePhotoExplanation))
        }
        return rows
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
        if (snapshot.livePhotoInventory?.requiresAttention ?? 0) > 0 || snapshot.livePhotoWork.requiresAttentionGroups > 0 { notes.append("部分 Live Photo 需要处理，请重新尝试或查看诊断。") }
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
