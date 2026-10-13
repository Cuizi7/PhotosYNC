import AppKit
import SwiftUI
@testable import PhotoSyncCore

enum UIReviewScenario: String, CaseIterable {
    case syncing, analyzing, preparing, icloud, paused, pausing, completed, offline
    case fileIssue, unauthorized, unknown, summaryLoading, summaryStale, empty, single, many, longLeaf
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
    case .syncing:
        state.snapshot.activeWork = true
        state.snapshot.latestScan.state = .running
        state.snapshot.latestScan.endedAt = nil
        if let first { state.snapshot.sourcePhases[first] = "正在导入，保留原始文件" }
    case .analyzing, .preparing, .icloud:
        state.snapshot.activeWork = true
        state.snapshot.indexProgress = IndexProgress(
            state: scenario == .preparing ? .preparing : (scenario == .icloud ? .waiting : .updating),
            totalsKnown: scenario != .preparing, totalAssets: 100000, readyAssets: 42680,
            totalRepresentations: 150000, readyRepresentations: 64020, excludedAssets: 3,
            issue: scenario == .icloud ? "正在等待 iCloud 图像，连接恢复后自动继续" : nil)
        if let first { state.snapshot.advancedWaitingReasons[first] = "等待图库分析完成后继续" }
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
                state.snapshot.sourceFileIssueCounts[source.id] = 7
            }
        }
    case .offline:
        state.snapshot.activeWork = true
        if let first { state.snapshot.waitingSources[first] = SourceIssue(
            summary: "来源磁盘尚未挂载，正在等待恢复。", detail: "合成卷诊断", kind: .sourceAvailability) }
        state.snapshot.sourcePhases[state.sources[1].id] = "正在导入，保留原始文件"
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
    case .summaryLoading: state.snapshot.summary = nil
    case .summaryStale: state.snapshot.summaryError = "合成统计读取失败，保留上次统计"
    }
    let model = AppModel(runtime: runtime, initialState: state)
    guard !model.allowsSystemIntegrations else { throw UIReviewError.invalid("System integrations must be disabled") }
    return model
}

enum UIReviewError: Error { case invalid(String) }

@MainActor
enum UIReviewCapture {
    static func render<V: View>(_ view: V, width: CGFloat, appearance: NSAppearance.Name,
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
        let size = try converge(host: host, window: window, width: width)
        try inspect(host, window)
        return size
    }

    static func converge(host: NSHostingView<AnyView>, window: NSWindow, width: CGFloat) throws -> NSSize {
        var previous = NSSize.zero
        var stable = 0
        for _ in 0..<100 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let size = host.fittingSize
            stable = abs(size.width - previous.width) < 0.5 && abs(size.height - previous.height) < 0.5
                && size.height > 100 ? stable + 1 : 0
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

    static func scrollToBottom(_ host: NSView) throws {
        func scrolls(_ v: NSView) -> [NSScrollView] {
            ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrolls)
        }
        let overflowing = scrolls(host).filter { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 1 }
        guard overflowing.count == 1, let list = overflowing.first else {
            throw UIReviewError.invalid("Expected one overflowing source list, got \(overflowing.count)")
        }
        list.contentView.scroll(to: NSPoint(x: 0, y: (list.documentView?.bounds.height ?? 0) - list.contentView.bounds.height))
        list.reflectScrolledClipView(list.contentView)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }
}
