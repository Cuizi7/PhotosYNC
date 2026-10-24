import AppKit
import SwiftUI
@testable import PhotoSyncCore

enum UIReviewScenario: String, CaseIterable {
    case syncing, analyzing, preparing, icloud, paused, pausing, completed, offline
    case fileIssue, unauthorized, unknown, summaryLoading, summaryStale, empty, single, many, longLeaf
    case mixedIssues, longIssues, recoveryPending, analysisPaused, analysisZero
    case taskVisualUnknown, taskLiveKnown, tasksMixed, tasksKnown, tasksWaiting, tasksPaused, tasksAttention, taskCompletion
    case taskLiveAttention, taskLiveAttentionWaiting, taskLiveAttentionPaused, tasksLiveAttention
}

@MainActor
func makeUIReviewModel(scenario: UIReviewScenario, root: URL) throws -> AppModel {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try SyncStore(url: root.appendingPathComponent("\(UUID().uuidString).sqlite"))
    let runtime = SyncRuntime(store: store, now: { Date(timeIntervalSince1970: 1_791_878_400) }, authorized: { true })
    var state = RuntimeState()
    state.authorized = true
    state.snapshot.summary = SyncStatusSummary(imported: 120, skipped: 30, pending: 49, importing: 1)
    state.snapshot.latestScan = ScanProgress(state: .completed)
    let count = scenario == .empty ? 0 : (scenario == .many ? 30 : (scenario == .offline ? 2 : 1))
    state.sources = (0..<count).map { index in
        let path: String
        if scenario == .longLeaf {
            path = "/示例来源/家人/旅行👨‍👩‍👧‍👦/假日e\u{301}/" + String(repeating: "很长的末级目录", count: 18)
        } else {
            path = "/示例来源/\(index.isMultiple(of: 2) ? "家庭" : "旅行")/2026/\(index)/旅行与家庭照片归档"
        }
        return RegisteredSource(id: UUID(), url: URL(fileURLWithPath: path),
            enabled: scenario != .many || index.isMultiple(of: 2))
    }
    let first = state.sources.first?.id
    let date = Date(timeIntervalSince1970: 1_791_878_400) // 2026-10-13 08:00 UTC
    state.snapshot.latestScan.startedAt = date
    state.snapshot.latestScan.endedAt = date.addingTimeInterval(60)
    state.snapshot.latestScan.checkedCandidates = 86
    state.snapshot.latestScan.newlyImported = 24
    state.nextScan = date.addingTimeInterval(1_800)
    switch scenario {
    case .taskLiveAttention, .taskLiveAttentionWaiting, .taskLiveAttentionPaused, .tasksLiveAttention:
        state.nextScan = nil; state.snapshot.summary = .init()
        state.snapshot.livePhotoInventory = .init(phase: .completed, inventoried: 16224, identified: 1021, unresolved: 15203,
            retryWaiting: 15202, requiresAttention: 1, resourceLimited: 1)
        state.snapshot.livePhotoWork.stoppedGroups = 1
        state.snapshot.isPaused = scenario == .taskLiveAttentionPaused
        state.snapshot.activeWork = scenario == .taskLiveAttention || scenario == .tasksLiveAttention
        state.snapshot.livePhotoActivities = [state.snapshot.activeWork ? .working(.identification) : .waiting(nextRetryAt: nil)]
        if scenario == .tasksLiveAttention {
            state.snapshot.indexActivity = .working
            state.snapshot.indexProgress = .init(state: .updating, totalsKnown: false, totalAssets: 16000, readyAssets: 15716,
                totalRepresentations: 16000, readyRepresentations: 15716, excludedAssets: 0, issue: nil)
        }
    case .syncing:
        state.snapshot.activeWork = true
        state.snapshot.latestScan.state = .running
        state.snapshot.latestScan.endedAt = nil
        if let first { state.snapshot.sourcePhases[first] = "正在同步"; state.snapshot.sourceActivities[first] = .submitting }
    case .analyzing, .preparing, .icloud, .analysisPaused, .analysisZero:
        state.snapshot.summary = .init(imported: 120, skipped: 30, pending: 50)
        state.snapshot.indexActivity = [.icloud, .analysisPaused].contains(scenario) ? .waiting : .working
        state.snapshot.activeWork = true
        state.snapshot.indexProgress = IndexProgress(
            state: scenario == .preparing ? .preparing : (scenario == .icloud ? .waiting : (scenario == .analysisPaused ? .paused : .updating)),
            totalsKnown: scenario != .preparing, totalAssets: scenario == .analysisZero ? 0 : 100000, readyAssets: scenario == .analysisZero ? 0 : 42680,
            totalRepresentations: 150000, readyRepresentations: 64020, excludedAssets: 3,
            issue: scenario == .icloud ? "正在等待 iCloud 图像，连接恢复后自动继续" : nil)
        if let first { state.snapshot.advancedWaitingReasons[first] = "等待图库分析完成后继续" }
    case .taskVisualUnknown, .taskLiveKnown, .tasksMixed, .tasksKnown, .tasksWaiting, .tasksPaused, .tasksAttention, .taskCompletion:
        state.nextScan = nil
        state.snapshot.summary = .init()
        state.snapshot.activeWork = ![.tasksWaiting, .tasksPaused, .tasksAttention].contains(scenario)
        if scenario != .taskLiveKnown && scenario != .taskCompletion {
            let known = ![.taskVisualUnknown, .tasksMixed].contains(scenario)
            state.snapshot.indexProgress = .init(state: .updating, totalsKnown: known,
                totalAssets: 16000, readyAssets: 15716, totalRepresentations: 16000,
                readyRepresentations: 15716, readErrorRepresentations: scenario == .tasksAttention ? 3 : 0,
                excludedAssets: 0, issue: nil, requiresAttentionAssets: scenario == .tasksAttention ? 3 : 0)
            state.snapshot.indexActivity = state.snapshot.activeWork ? .working : .waiting
        }
        if scenario != .taskVisualUnknown && scenario != .tasksAttention {
            state.snapshot.livePhotoInventory = .init(phase: .identifying, inventoried: 16222, identified: 45, pending: 16177)
            state.snapshot.livePhotoActivities = [state.snapshot.activeWork ? .working(.identification) : .waiting(nextRetryAt: nil)]
        }
        if scenario == .tasksPaused { state.snapshot.isPaused = true }
        if scenario == .tasksWaiting {
            state.snapshot.livePhotoIssue = .init(summary: "部分项目暂时无法读取，稍后自动重试", detail: "合成读取等待", kind: .file)
        }
        if scenario == .taskCompletion {
            state.snapshot.livePhotoInventory = .init(phase: .completed, inventoried: 16222, identified: 16222)
            state.snapshot.livePhotoActivities = [.working(.completion)]
            state.snapshot.livePhotoWork.activeGroups = 1
        }
    case .paused, .pausing:
        state.snapshot.isPaused = true
        state.snapshot.activeWork = scenario == .pausing
    case .completed, .single, .many, .longLeaf, .empty:
        state.snapshot.summary = SyncStatusSummary(imported: 170, skipped: 30)
        if scenario == .many || scenario == .longLeaf {
            for source in state.sources where source.enabled {
                state.snapshot.waitingSources[source.id] = SourceIssue(
                    summary: "来源目录暂时不可用，正在等待恢复。请检查磁盘或网络连接。",
                    detail: "合成诊断：未挂载；完整路径 \(source.url.path)", kind: .sourceAvailability)
                state.snapshot.sourceIssueDetails[source.id] = reviewIssues().map { issue in
                    var issue = issue
                    issue.path = source.url.path + String(issue.path.dropFirst("/示例来源".count))
                    return issue
                }
                state.snapshot.sourceFileIssueCounts[source.id] = 2
            }
        }
    case .offline:
        state.snapshot.activeWork = true
        if let first { state.snapshot.waitingSources[first] = SourceIssue(
            summary: "来源磁盘尚未挂载，正在等待恢复。", detail: "合成卷诊断", kind: .sourceAvailability) }
        state.snapshot.sourcePhases[state.sources[1].id] = "正在同步"; state.snapshot.sourceActivities[state.sources[1].id] = .submitting
    case .fileIssue:
        state.snapshot.summary = SyncStatusSummary(imported: 120, skipped: 30, retryPending: 3)
        if let first {
            state.snapshot.sourceFileIssueCounts[first] = 3
            state.snapshot.waitingSources[first] = SourceIssue(summary: "部分文件不可读，稍后重试。",
                detail: "合成文件诊断", kind: .file)
        }
    case .unauthorized: state.authorized = false
    case .unknown:
        state.snapshot.summary = SyncStatusSummary(imported: 120, skipped: 30, importing: 1)
        state.snapshot.blockingSummary = "Photos 提交结果尚未确认，正在等待核对。"
        state.snapshot.blockingError = "合成 unknown 提交诊断"
        state.snapshot.recoveryHint = .uncertainSubmission(message: "合成 unknown 提交诊断")
    case .mixedIssues, .longIssues:
        if let first {
            let issues = reviewIssues(long: scenario == .longIssues)
            state.snapshot.sourceIssueDetails[first] = issues
            let primary = issues.filter { $0.kind == .sourceAvailability }.sorted {
                $0.path == $1.path ? $0.id < $1.id : $0.path < $1.path
            }.first ?? issues[0]
            state.snapshot.waitingSources[first] = SourceIssue(summary: primary.summary, detail: primary.detail, kind: primary.kind)
            state.snapshot.sourceFileIssueCounts[first] = issues.filter { $0.kind == .file }.count
        }
    case .recoveryPending:
        if let first {
            state.snapshot.waitingSources[first] = SourceIssue(summary: "目录扫描尚未完成，稍后继续", detail: "合成目录恢复标记", kind: .sourceAvailability)
        }
    case .summaryLoading: state.snapshot.summary = nil
    case .summaryStale: state.snapshot.summaryError = "合成统计读取失败，保留上次统计"
    }
    if let first, scenario == .offline {
        state.snapshot.sourceIssueDetails[first] = [SourceIssueDetail(id: "offline-directory", kind: .sourceAvailability,
            path: state.sources[0].url.path, summary: "来源磁盘尚未挂载，正在等待恢复。", stage: "枚举来源目录",
            detail: "NSPOSIXErrorDomain Code=2 合成卷诊断")]
    }
    if let first, scenario == .fileIssue {
        state.snapshot.sourceIssueDetails[first] = [
            SourceIssueDetail(id: "file-a", kind: .file, path: state.sources[0].url.path + "/a.jpg",
                summary: "访问权限不足。", stage: nil, detail: "NSPOSIXErrorDomain Code=13"),
            SourceIssueDetail(id: "file-b", kind: .file, path: state.sources[0].url.path + "/b.mov",
                summary: "视频元数据读取失败。", stage: "读取时长", detail: "AVFoundationErrorDomain Code=-11800"),
            SourceIssueDetail(id: "file-c", kind: .file, path: state.sources[0].url.path + "/c.jpg",
                summary: "文件暂时无法读取，具体原因尚无法确定。", stage: nil, detail: "NSCocoaErrorDomain Code=256")]
    }
    let model = AppModel(runtime: runtime, initialState: state)
    guard !model.allowsSystemIntegrations else { throw UIReviewError.invalid("System integrations must be disabled") }
    return model
}

enum UIReviewError: Error { case invalid(String) }

@MainActor
enum UIReviewCapture {
    static func render<V: View>(_ view: V, width: CGFloat, appearance: NSAppearance.Name, minimumHeight: CGFloat = 100,
        inspect: (NSHostingView<AnyView>, NSWindow) throws -> Void) throws -> NSSize {
        let host = NSHostingView(rootView: AnyView(view
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
            .environment(\.controlActiveState, .active)
            .background(Color(nsColor: .windowBackgroundColor))))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        let size = try converge(host: host, window: window, width: width, minimumHeight: minimumHeight)
        try inspect(host, window)
        return size
    }

    static func converge(host: NSHostingView<AnyView>, window: NSWindow, width: CGFloat, minimumHeight: CGFloat = 100) throws -> NSSize {
        var previous = NSSize.zero
        var stable = 0
        for _ in 0..<100 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let size = host.fittingSize
            stable = abs(size.width - previous.width) < 0.5 && abs(size.height - previous.height) < 0.5
                && size.height > minimumHeight ? stable + 1 : 0
            previous = size
            if stable >= 4 {
                guard abs(size.width - width) <= 1, size.height <= 681 else {
                    throw UIReviewError.invalid("Unexpected review geometry: \(size), expected width \(width)")
                }
                window.setContentSize(size)
                host.setFrameSize(size)
                host.layoutSubtreeIfNeeded()
                return size
            }
        }
        throw UIReviewError.invalid("UI review layout did not converge: \(previous)")
    }

    static func write(_ view: NSView, to url: URL) throws -> [String: Any] {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw UIReviewError.invalid("No bitmap for \(url.lastPathComponent)")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try validate(bitmap, logicalSize: view.bounds.size)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw UIReviewError.invalid("PNG encoding failed")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try validateFile(url, logicalSize: view.bounds.size)
        return ["logicalWidth": view.bounds.width, "logicalHeight": view.bounds.height,
            "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh,
            "captureMethod": "NSView.cacheDisplay native view bitmap; controlActiveState=.active for color comparison; no WindowServer frame/shadow or actual focus claim"]
    }

    static func validateFile(_ url: URL, logicalSize: NSSize) throws {
        guard let image = NSBitmapImageRep(data: try Data(contentsOf: url)) else {
            throw UIReviewError.invalid("Missing or invalid PNG \(url.path)")
        }
        try validate(image, logicalSize: logicalSize)
    }

    static func validate(_ image: NSBitmapImageRep, logicalSize: NSSize) throws {
        guard logicalSize.width > 0, logicalSize.height > 0, image.pixelsWide > 0, image.pixelsHigh > 0 else {
            throw UIReviewError.invalid("Zero-sized image")
        }
        let scaleX = Double(image.pixelsWide) / logicalSize.width
        let scaleY = Double(image.pixelsHigh) / logicalSize.height
        guard scaleX >= 1, scaleX <= 3, abs(scaleX - scaleY) <= 0.02 else {
            throw UIReviewError.invalid("Mis-sized image: \(image.pixelsWide)x\(image.pixelsHigh) for \(logicalSize)")
        }
        var levels: Set<Int> = []
        for y in stride(from: 0, to: image.pixelsHigh, by: max(1, image.pixelsHigh / 160)) {
            for x in stride(from: 0, to: image.pixelsWide, by: max(1, image.pixelsWide / 160)) {
                guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.1 else { continue }
                levels.insert(Int((c.redComponent + c.greenComponent + c.blueComponent) * 85))
            }
        }
        guard levels.count > 8, let low = levels.min(), let high = levels.max(), high - low > 15 else {
            throw UIReviewError.invalid("Blank or near-uniform image")
        }
    }

    static func scrollToBottom(_ host: NSView, allowNoOverflow: Bool = false) throws {
        func scrolls(_ v: NSView) -> [NSScrollView] {
            ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrolls)
        }
        let overflowing = scrolls(host).filter { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 1 }
        if allowNoOverflow && overflowing.isEmpty { return }
        guard overflowing.count == 1, let list = overflowing.first else {
            throw UIReviewError.invalid("Expected one overflowing source list, got \(overflowing.count)")
        }
        list.contentView.scroll(to: NSPoint(x: 0, y: (list.documentView?.bounds.height ?? 0) - list.contentView.bounds.height))
        list.reflectScrolledClipView(list.contentView)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }
}

/// Values captured in a synthetic snapshot. No path is opened by this fixture.
func reviewIssues(long: Bool = false) -> [SourceIssueDetail] {
    if long {
        return (0..<20).map { index in
            SourceIssueDetail(id: String(format: "read-%02d", index), kind: .file,
                path: "/示例来源/家人/旅行👨‍👩‍👧‍👦/假日e\u{301}/" + String(repeating: "长目录与原始文件名称/", count: 5) + String(format: "FINAL-%02d.jpg", index),
                summary: "文件暂时无法读取，具体原因尚无法确定。", stage: "读取公共元数据",
                detail: String(repeating: "NSCocoaErrorDomain Code=256 合成诊断：无法完成读取。", count: 4) + String(format: " CAUSE-END-%02d", index))
        }
    }
    return [
        SourceIssueDetail(id: "directory-b", kind: .sourceAvailability, path: "/示例来源/B", summary: "目录暂时不可用。", stage: "枚举目录", detail: "NSPOSIXErrorDomain Code=2"),
        SourceIssueDetail(id: "directory-a", kind: .sourceAvailability, path: "/示例来源/A", summary: "访问权限不足。", stage: nil, detail: "NSCocoaErrorDomain Code=257"),
        SourceIssueDetail(id: "scan-same", kind: .file, path: "/示例来源/same.jpg", summary: "文件无法访问，请检查访问权限。", stage: nil, detail: "NSPOSIXErrorDomain Code=13"),
        SourceIssueDetail(id: "video", kind: .file, path: "/示例来源/video.mov", summary: "视频元数据读取失败。", stage: "读取时长", detail: "AVFoundationErrorDomain Code=-11800"),
        SourceIssueDetail(id: "submit-same", kind: .submission, path: "/示例来源/same.jpg", summary: "导入结果尚未确认。", stage: "提交原始文件", detail: "NSCocoaErrorDomain Code=512")
    ]
}
