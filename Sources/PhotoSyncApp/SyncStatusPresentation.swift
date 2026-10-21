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

    /// Maps only enabled sources to the global icon state, so a stale snapshot for a disabled
    /// source cannot hide work that is still progressing elsewhere.
    func globalStatus(
        enabledSourceIDs: Set<UUID>,
        authorized: Bool,
        hasBlockingError: Bool
    ) -> GlobalStatus {
        guard !enabledSourceIDs.isEmpty || snapshot.hasLivePhotoWork else { return .unconfigured }
        guard authorized, !hasBlockingError, !snapshot.livePhotoWork.unknownMutation else { return .error }
        if snapshot.isPaused { return .paused }

        let issues = enabledIssues(for: enabledSourceIDs)
        if issues.contains(where: \.isSourceAvailability) { return .waiting }
        if let progress = snapshot.indexProgress, progress.state != .ready {
            return progress.state == .waiting ? .waiting : .running
        }
        if let inventory = snapshot.livePhotoInventory, inventory.phase != .completed { return .running }
        if snapshot.livePhotoWork.activeGroups > 0 && snapshot.livePhotoInventory?.unresolved == 0 { return .running }
        if snapshot.livePhotoWork.awaitingVerification > 0 || snapshot.livePhotoWork.awaitingRetirement > 0 || snapshot.livePhotoWork.limitedGroups > 0 || snapshot.livePhotoIssue != nil || (snapshot.livePhotoInventory?.unresolved ?? 0) > 0 { return .waiting }
        if enabledSourceIDs.isEmpty { return .completed }
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
        if status == .waiting && snapshot.livePhotoWork.awaitingRetirement > 0 { return "Live Photo 已补齐，旧项目待清理" }
        if status == .waiting && (snapshot.livePhotoInventory?.unresolved ?? 0) > 0 { return "历史识别已完成，部分项目待核实" }
        if !snapshot.isPaused, !issues.contains(where: \.isSourceAvailability),
           let analysis, [.running, .waiting].contains(status) { return analysis.title }
        switch status {
        case .error:
            return status.description
        case .paused:
            return snapshot.activeWork ? "正在暂停，等待当前操作返回" : status.description
        case .waiting:
            if issues.contains(where: \.isSourceAvailability) { return "等待恢复" }
            if hasDeferredWork(for: enabledSourceIDs) { return "稍后继续" }
            if (summary?.importing ?? 0) > 0 { return "等待核对" }
            let pending = summary?.pending ?? 0
            let retryPending = summary?.retryPending ?? 0
            if pending > 0 || retryPending > 0 {
                return pending == 0 ? "等待重试" : status.description
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

    struct Analysis {
        let title: String
        let progressText: String
        let fraction: Double?
        let detail: String?
        let explanation: String
    }

    var analysis: Analysis? {
        if let inventory = snapshot.livePhotoInventory, inventory.phase != .completed {
            return Analysis(title: snapshot.isPaused ? "历史 Live Photo 识别已暂停" : "正在识别历史 Live Photo",
                progressText: "已清点 \(inventory.inventoried) · 已识别 \(inventory.identified) · 待核实 \(inventory.unresolved)",
                fraction: inventory.phase == .identifying && inventory.inventoried > 0 ? Double(inventory.identified + inventory.unresolved) / Double(inventory.inventoried) : nil,
                detail: snapshot.livePhotoIssue?.summary,
                explanation: "首次运行会检查图库中的照片与视频。完成后只处理新增、变化和待核实项目；历史识别不会下载 iCloud 原件。")
        }
        guard let p = snapshot.indexProgress, p.state != .ready else { return nil }
        let title: String
        switch p.state {
        case .preparing: title = "正在准备图库分析"
        case .updating: title = "正在分析图库"
        case .waiting: title = "图库分析正在等待"
        case .paused: title = "图库分析已暂停"
        case .ready: return nil
        }
        return Analysis(title: title,
            progressText: p.totalsKnown ? "已分析 \(p.readyAssets) / \(p.totalAssets) 张" : "正在读取图库…",
            fraction: p.totalsKnown && p.totalAssets > 0 ? Double(p.readyAssets) / Double(p.totalAssets) : nil,
            detail: p.issue,
            explanation: "完成图库分析后开始导入。部分照片可能需要从 iCloud 下载。")
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
        if let inventory = snapshot.livePhotoInventory, inventory.phase == .completed, inventory.unresolved > 0 { notes.append("历史识别已完成，部分项目待核实") }
        if snapshot.livePhotoWork.awaitingRetirement > 0 { notes.append("Live Photo 已补齐，旧项目待清理") }
        if snapshot.livePhotoWork.awaitingVerification > 0 { notes.append("Live Photo 已保存，等待验证") }
        if snapshot.livePhotoWork.limitedGroups > 0 && snapshot.livePhotoWork.awaitingRetirement == 0 { notes.append("部分 Live Photo 待核实") }
        if snapshot.livePhotoWork.unknownMutation { notes.append("Live Photo 提交结果尚未确认，新的提交已停止") }
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
