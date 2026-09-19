import Foundation
import PhotoSyncCore

/// UI text from one engine snapshot, without creating a runtime or querying Photos.
/// Two calibers are kept apart on purpose: the counters line is standing state read from the
/// store, while the scan line describes what this one round did. An unavailable source is state
/// about a source, never a count of failed files.
struct SyncStatusPresentation {
    let snapshot: EngineSnapshot

    /// Maps only enabled sources to the global icon state, so a stale snapshot for a disabled
    /// source cannot hide work that is still progressing elsewhere.
    func globalStatus(
        enabledSourceIDs: Set<UUID>,
        authorized: Bool,
        hasBlockingError: Bool
    ) -> GlobalStatus {
        guard !enabledSourceIDs.isEmpty else { return .unconfigured }
        guard authorized, !hasBlockingError else { return .error }
        if snapshot.isPaused { return .paused }

        let issues = enabledIssues(for: enabledSourceIDs)
        if issues.contains(where: \.isSourceAvailability) { return .waiting }
        if snapshot.activeWork { return .running }
        if hasDeferredWork(for: enabledSourceIDs) { return .waiting }

        let summary = snapshot.summary
        if (summary?.importing ?? 0) > 0 { return .waiting }
        if (summary?.pending ?? 0) > 0 || (summary?.retryPending ?? 0) > 0 { return .waiting }
        if hasFileOrSubmissionIssue(issues, enabledSourceIDs: enabledSourceIDs) { return .error }
        return snapshot.latestScan.state == .completed ? .completed : .waiting
    }

    func statusDescription(for status: GlobalStatus, enabledSourceIDs: Set<UUID>) -> String {
        let issues = enabledIssues(for: enabledSourceIDs)
        let summary = snapshot.summary
        switch status {
        case .error:
            return hasFileOrSubmissionIssue(issues, enabledSourceIDs: enabledSourceIDs)
                ? "部分文件需要处理"
                : status.description
        case .paused:
            return snapshot.activeWork ? "正在暂停，等待当前操作返回" : status.description
        case .waiting:
            if issues.contains(where: \.isSourceAvailability) { return "等待恢复" }
            if hasDeferredWork(for: enabledSourceIDs) { return "稍后继续" }
            if (summary?.importing ?? 0) > 0 { return "等待核对" }
            let pending = summary?.pending ?? 0
            let retryPending = summary?.retryPending ?? 0
            if pending > 0 || retryPending > 0 {
                return pending == 0 ? "等待重试" : "等待处理"
            }
            return "等待扫描"
        default:
            return status.description
        }
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
