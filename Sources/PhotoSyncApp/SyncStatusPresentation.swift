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
        var details: [ProgressDetail] = []
        var title: String { id == "visualIndex" ? "视觉索引" : "Live Photo 配对" }
        var countText: String? {
            guard var text = progressText else { return nil }
            if totalsKnown {
                for prefix in ["已分析 ", "已处理 "] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
            }
            if requiresAttentionAssets > 0 { text += " · \(requiresAttentionAssets) 张需处理" }
            return text
        }
    }
    struct ProgressDetail: Identifiable {
        let title: String
        let text: String
        var id: String { title }
    }
    static let indexExplanation = "视觉索引用于避免重复导入。必要时会从 iCloud 获取原文件并产生流量，系统可能保留本地缓存。分析结果会保存，重启后继续未完成项，不会重复分析未变化的成功结果。"
    static let livePhotoExplanation = "核对原文件中的配对关系，并补齐包含动态画面和声音的 Live Photo。必要时会从 iCloud 获取原文件并产生流量，系统可能保留本地缓存。结果会保存，重启后继续未完成项，不会重复分析未变化的成功结果。"

    var progressRows: [PreparationProgress] {
        var rows = [PreparationProgress]()
        if let p = snapshot.indexProgress, p.state != .ready || p.readErrorRepresentations > 0 || snapshot.indexActivity != .idle {
            let active = !snapshot.isPaused && !unknownMutation && (snapshot.indexActivity == .working || snapshot.indexActivity == .queued)
            let subtitle = snapshot.isPaused ? "视觉索引已暂停" : active ? "正在建立视觉索引" : p.requiresAttentionAssets > 0 ? "视觉索引" : "视觉索引等待恢复"
            var details = [ProgressDetail(title: "用途", text: "分析图库中的照片，建立用于视觉判重的索引，帮助避免重复导入。此任务只读取照片，不修改或删除图库内容。"),
                ProgressDetail(title: "进度含义", text: "已分析 \(p.readyAssets) 张，包含以前保存的结果，并非本次启动重新分析的数量。" + (p.totalsKnown ? "当前需分析的总量为 \(p.totalAssets) 张。" : "当前总量尚未确认，因此不显示百分比。"))]
            if p.requiresAttentionAssets > 0 { details.append(.init(title: "需要处理", text: "有 \(p.requiresAttentionAssets) 张照片解码后的图像超出当前内存上限，已停止自动重试。可在设置中提高“图像处理内存峰值上限”，或点击“立即扫描”重新尝试。其他照片会继续处理，原文件未被修改。")) }
            if let issue = p.issue { details.append(.init(title: "当前状态", text: issue)) }
            details += Self.commonTaskDetails
            rows.append(.init(id: "visualIndex", subtitle: subtitle,
                progressText: p.totalsKnown ? "已分析 \(p.readyAssets) / \(p.totalAssets) 张" : "已分析 \(p.readyAssets) 张",
                fraction: p.totalsKnown ? (p.totalAssets > 0 ? min(1, Double(p.readyAssets) / Double(p.totalAssets)) : 0) : nil,
                explanation: Self.indexExplanation, active: active, totalsKnown: p.totalsKnown,
                requiresAttentionAssets: p.requiresAttentionAssets, details: details))
        }
        let identifying = livePhotoRunnable(.identification)
        let completing = livePhotoRunnable(.completion)
        if identifying || completing || snapshot.hasLivePhotoWork || snapshot.livePhotoActivities.contains(where: { $0 != .idle }) {
            let inventory = snapshot.livePhotoInventory
            let known = inventory?.phase != .enumerating
            let stillIdentifying = identifying || inventory.map { $0.phase != .completed || $0.pending > 0 || $0.unresolved > 0 } == true
            let text = stillIdentifying && (!completing || identifying) ? inventory.map { known ? "已处理 \($0.identified) / \($0.inventoried) 项" : "已处理 \($0.identified) 项" } : nil
            let fraction = stillIdentifying && !completing && known ? ((inventory?.inventoried ?? 0) > 0 ? min(1, Double(inventory!.identified) / Double(inventory!.inventoried)) : 0) : nil
            let active = !snapshot.isPaused && !unknownMutation && (identifying || completing)
            let attention = (inventory?.requiresAttention ?? 0) > 0 || snapshot.livePhotoWork.requiresAttentionGroups > 0
            let subtitle = snapshot.isPaused ? "Live Photo 已暂停" : active ? "正在配对 Live Photo" : attention ? "Live Photo 需处理" : "Live Photo 等待恢复"
            let progressMeaning: String
            if text == nil {
                progressMeaning = "配对信息已核对，正在补齐并验证完整 Live Photo。此阶段没有可靠的总百分比，显示活动进度。"
            } else {
                progressMeaning = "\(inventory?.identified ?? 0)" + (known ? " / \(inventory?.inventoried ?? 0)" : "") + " 是已核对配对信息的图库项目数；完整 Live Photo 按一项计数，不代表已补齐的数量。确定不含配对标识或按时长规则排除的项目也计入，读取失败的项目不计入。" + (known ? "" : "当前总量尚未确认，因此不显示百分比。")
            }
            var details = [ProgressDetail(title: "用途", text: "核对照片与视频原文件中的配对标识，确认它们属于同一张 Live Photo，补齐动态画面和原有声音。只有一半时先保存，发现另一半后再补齐。"),
                ProgressDetail(title: "进度含义", text: progressMeaning),
                ProgressDetail(title: "对已有内容的影响", text: "完整 Live Photo 的原始内容及应保留的信息验证通过后，才移除被替代的单独照片或视频；旧标题可能丢失。不会改动源文件或清空“最近删除”。")]
            if let issue = snapshot.livePhotoIssue ?? snapshot.livePhotoWork.issue { details.append(.init(title: "当前状态", text: issue.summary)) }
            details.append(.init(title: "视频识别范围", text: "超过 10 秒的普通视频跳过 Live Photo 识别，仍正常导入为视频。已有明确配对身份或已标记为 Live Photo 的项目不受此规则影响；时长未知时继续识别。"))
            if (inventory?.requiresAttention ?? 0) > 0 { details.append(.init(title: "需要处理的项目", text: "\(inventory!.requiresAttention) 项无法自动识别配对关系。点击“立即扫描”可重新尝试，已完成的结果会保留。")) }
            if (inventory?.resourceLimited ?? 0) > 0 || snapshot.livePhotoWork.resourceLimitedGroups > 0 {
                details.append(.init(title: "资源读取限制", text: "部分原文件或同时读取的资源超过当前 512 MiB 上限，已停止自动重试。点击“立即扫描”可重新尝试，但上限不变时仍可能受限。其他项目继续处理，原文件未被修改。"))
            }
            if snapshot.livePhotoWork.stoppedGroups > 0 { details.append(.init(title: "已停止补齐", text: "\(snapshot.livePhotoWork.stoppedGroups) 组关联项目已从图库删除，已停止补齐，不会重新创建这些项目。")) }
            details += Self.commonTaskDetails
            rows.append(.init(id: "livePhoto", subtitle: subtitle, progressText: text, fraction: fraction, explanation: Self.livePhotoExplanation, active: active, totalsKnown: known, details: details))
        }
        return rows
    }
    private static let commonTaskDetails = [
        ProgressDetail(title: "iCloud 原件", text: "必要时会从 iCloud 获取原文件，可能产生网络流量并增加系统本地缓存。"),
        ProgressDetail(title: "暂停与重启", text: "已有分析结果会保留，恢复或重启后继续未完成项。图库变化时会重新核对受影响的项目。")]

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
