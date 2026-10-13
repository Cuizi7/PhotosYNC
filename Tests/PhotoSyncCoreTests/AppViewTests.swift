import AppKit
import SwiftUI
import XCTest
import Vision
@testable import PhotoSyncCore

@MainActor
final class AppViewTests: XCTestCase {
    func testFeedbackNativeActionsHaveEqualColumns() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeUIReviewModel(scenario: .syncing, root: root)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            _ = try UIReviewCapture.render(StatusMenu(model: model), width: 320, appearance: appearance) { host, _ in
                let frames = self.nativeAccessibility(in: host).compactMap { node -> NSRect? in
                    guard let view = node as? NSView else { return nil }
                    let frame = host.convert(view.bounds, from: view)
                    return frame.width > 40 && frame.width < 290 && frame.height > 15 && frame.height < 35
                        && frame.minY > host.bounds.height - 90 ? frame : nil
                }.sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
                XCTAssertEqual(frames.count, 4, "Expected four native action/focus frames: \(frames)")
                guard frames.count == 4 else { return }
                for pair in [Array(frames[0..<2]), Array(frames[2..<4])] {
                    XCTAssertEqual(pair[0].width, pair[1].width, accuracy: 1)
                    XCTAssertEqual(pair[0].height, pair[1].height, accuracy: 1)
                    XCTAssertGreaterThan(pair[0].width, 130)
                    XCTAssertLessThanOrEqual(pair[1].minX - pair[0].maxX, 10)
                }
                let texts = try self.recognizedText(in: host)
                let settings = try XCTUnwrap(texts.first { $0.text == "设置" })
                let quit = try XCTUnwrap(texts.first { $0.text.contains("退出 PhotosYNC") })
                XCTAssertEqual(settings.frame.minX, 14, accuracy: 3)
                XCTAssertEqual(quit.frame.maxX, 306, accuracy: 3)
            }
        }
    }

    func testFeedbackAnalysisCountPrecedesBarAndHasAdjacentInfo() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeUIReviewModel(scenario: .analyzing, root: root)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            _ = try UIReviewCapture.render(StatusMenu(model: model), width: 320, appearance: appearance) { host, _ in
                let texts = try self.recognizedText(in: host)
                XCTAssertFalse(texts.contains { $0.text == "图库分析" })
                let count = try XCTUnwrap(texts.first { $0.text.contains("已分析") })
                let progress = try XCTUnwrap(self.nativeAccessibility(in: host).compactMap { $0 as? NSProgressIndicator }
                    .first { !$0.isIndeterminate })
                let barFrame = host.convert(progress.bounds, from: progress)
                XCTAssertLessThan(count.frame.maxY, barFrame.minY)
                let info = try XCTUnwrap(self.nativeAccessibility(in: host).compactMap { $0 as? NSButton }.first)
                let infoFrame = host.convert(info.bounds, from: info)
                XCTAssertEqual(infoFrame.midY, count.frame.midY, accuracy: 4)
                XCTAssertGreaterThan(infoFrame.minX, count.frame.maxX)
                XCTAssertLessThan(infoFrame.minX - count.frame.maxX, 20)
            }
        }
    }

    func testFeedbackScanDetailsRenderIndependentAlignedRows() throws {
        var snapshot = EngineSnapshot()
        snapshot.summary = SyncStatusSummary(imported: 120, skipped: 30, pending: 49, importing: 1)
        snapshot.latestScan = ScanProgress(state: .interrupted)
        snapshot.latestScan.checkedCandidates = 86
        snapshot.latestScan.newlyImported = 24
        snapshot.latestScan.deferred = true
        snapshot.latestScan.failed = 99
        snapshot.latestScan.failedFiles = 3
        snapshot.waitingSources[UUID()] = SourceIssue(summary: "合成来源问题", detail: "synthetic", kind: .sourceAvailability)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            _ = try UIReviewCapture.render(SyncDetailsContent(snapshot: snapshot), width: 300, appearance: appearance) { host, _ in
                let texts = try self.recognizedText(in: host)
                let checked = try XCTUnwrap(texts.first { $0.text == "检查候选" })
                let imported = try XCTUnwrap(texts.first { $0.text == "新增导入" })
                let checkedValue = try XCTUnwrap(texts.first { $0.text == "86" })
                let importedValue = try XCTUnwrap(texts.first { $0.text == "24" })
                XCTAssertEqual(checked.frame.minX, imported.frame.minX, accuracy: 2)
                XCTAssertEqual(checkedValue.frame.maxX, importedValue.frame.maxX, accuracy: 2)
                XCTAssertEqual(checked.frame.midY, checkedValue.frame.midY, accuracy: 2)
                XCTAssertEqual(imported.frame.midY, importedValue.frame.midY, accuracy: 2)
                XCTAssertTrue(texts.contains { $0.text == "稍后继续" })
                XCTAssertTrue(texts.contains { $0.text == "本次读取失败" })
                XCTAssertTrue(texts.contains { $0.text == "来源等待恢复" })
                XCTAssertFalse(texts.contains { $0.text.contains("99") })
            }
        }
    }

    func testFeedbackScanStateDatesAndOptionalRowsComeFromSnapshot() throws {
        let date = Date(timeIntervalSince1970: 1_791_878_400)
        for (state, deferred, expected) in [(ScanProgressState.notStarted, false, "尚未扫描"),
            (.running, false, "进行中"), (.completed, false, "已完成"), (.interrupted, false, "已中断"),
            (.interrupted, true, "稍后继续")] {
            var snapshot = EngineSnapshot()
            snapshot.summary = SyncStatusSummary()
            snapshot.latestScan = ScanProgress(state: state)
            snapshot.latestScan.deferred = deferred
            snapshot.latestScan.startedAt = date
            snapshot.latestScan.endedAt = state == .completed ? date.addingTimeInterval(60) : nil
            snapshot.latestScan.failed = 99
            snapshot.waitingSources[UUID()] = SourceIssue(summary: "文件问题", detail: "synthetic", kind: .file)
            _ = try UIReviewCapture.render(SyncDetailsContent(snapshot: snapshot), width: 300, appearance: .aqua) { host, _ in
                let texts = try self.recognizedText(in: host).map(\.text)
                XCTAssertTrue(texts.contains(expected), "Missing scan state \(expected): \(texts)")
                XCTAssertEqual(texts.contains("检查候选"), state != .notStarted)
                XCTAssertEqual(texts.contains("时间"), state != .notStarted)
                XCTAssertEqual(texts.contains("开始"), state == .completed)
                XCTAssertFalse(texts.contains("本次读取失败"))
                XCTAssertFalse(texts.contains("来源等待恢复"))
                XCTAssertFalse(texts.contains { $0.contains("99") })
            }
        }
    }

    func testFeedbackSyncInfoStaysAdjacentToStandingSummary() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeUIReviewModel(scenario: .syncing, root: root)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            _ = try UIReviewCapture.render(StatusMenu(model: model), width: 320, appearance: appearance) { host, _ in
                let info = try XCTUnwrap(self.nativeAccessibility(in: host).compactMap { $0 as? NSButton }.first)
                let frame = host.convert(info.bounds, from: info)
                let countSize = NSHostingView(rootView: StatusMenuSingleLine(text: "已处理 150 / 已发现 200")).fittingSize
                XCTAssertEqual(frame.minX, 14 + countSize.width + 7, accuracy: 2)
                XCTAssertEqual(frame.midY, 47, accuracy: 2)
            }
        }
    }

    private func nativeAccessibility(in object: Any) -> [any NSAccessibilityProtocol] {
        var seen: Set<ObjectIdentifier> = []
        func walk(_ object: Any) -> [any NSAccessibilityProtocol] {
            guard let node = object as? any NSAccessibilityProtocol,
                  seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            return [node] + ((node.accessibilityChildren() ?? []) + ((object as? NSView)?.subviews ?? [])).flatMap(walk)
        }
        return walk(object)
    }

    private func recognizedText(in view: NSView) throws -> [(text: String, frame: NSRect)] {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { result in
            guard let candidate = result.topCandidates(1).first else { return nil }
            let text = candidate.string
            // Vision may group the adjacent info symbol into a text observation. Measure
            // the recognized analysis string itself, preserving the native symbol frame.
            let box: CGRect
            if text.hasPrefix("已分析"), let end = text.firstIndex(of: "张"),
               let bounds = try? candidate.boundingBox(for: text.startIndex..<text.index(after: end)) {
                box = bounds.boundingBox
            } else {
                box = result.boundingBox
            }
            return (text, NSRect(x: box.minX * view.bounds.width, y: (1 - box.maxY) * view.bounds.height,
                width: box.width * view.bounds.width, height: box.height * view.bounds.height))
        }
    }

    // An empty/default fixture must not silently erase counts, source rows or isolation.
    func testReviewScenariosStayIsolatedAndHaveExpectedCounts() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for scenario in UIReviewScenario.allCases {
            let model = try makeUIReviewModel(scenario: scenario, root: root)
            XCTAssertFalse(model.allowsSystemIntegrations, scenario.rawValue)
            if scenario == .syncing || scenario == .completed {
                let summary = try XCTUnwrap(model.state.snapshot.summary)
                XCTAssertEqual(summary.imported, scenario == .syncing ? 120 : 170)
                XCTAssertEqual(summary.skipped, 30)
                XCTAssertEqual(summary.pending, scenario == .syncing ? 49 : 0)
                XCTAssertEqual(summary.importing, scenario == .syncing ? 1 : 0)
                XCTAssertEqual(summary.retryPending, 0)
                let metrics = try XCTUnwrap(SyncProgressMetrics(summary: summary))
                XCTAssertEqual(metrics.known, 200)
                XCTAssertEqual(metrics.processed, scenario == .syncing ? 150 : 200)
                XCTAssertEqual(model.state.snapshot.latestScan.checkedCandidates, 86)
                XCTAssertEqual(model.state.snapshot.latestScan.newlyImported, 24)
            }
            if scenario == .analyzing {
                XCTAssertEqual(model.state.snapshot.indexProgress?.readyAssets, 42680)
                XCTAssertEqual(model.state.snapshot.indexProgress?.totalAssets, 100000)
                XCTAssertEqual(model.state.snapshot.advancedWaitingReasons.count, 1)
            }
            if scenario == .unknown { XCTAssertEqual(model.state.snapshot.summary?.importing, 1) }
            if scenario == .many { XCTAssertEqual(model.state.sources.count, 30) }
        }
    }

    // A missing/nonconvergent renderer must fail even when output is not requested.
    func testRenderAllReviewScenarios() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for scenario in UIReviewScenario.allCases {
            let model = try makeUIReviewModel(scenario: scenario, root: root)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for (surface, view, width) in [("menu", AnyView(StatusMenu(model: model)), CGFloat(320)),
                    ("settings", AnyView(SourceSettings(model: model)), CGFloat(600))] {
                    let size = try UIReviewCapture.render(view, width: width, appearance: appearance) { host, _ in
                        // Validation runs even without PHOTOSYNC_UI_OUTPUT.
                        let temporary = root.appendingPathComponent("checked.png")
                        _ = try UIReviewCapture.write(host, to: temporary)
                        if let directory = ProcessInfo.processInfo.environment["PHOTOSYNC_UI_OUTPUT"] {
                            try self.capture(host, name: "\(scenario.rawValue)-\(appearance.rawValue)-\(surface)", directory: directory)
                            if scenario == .many, surface == "settings" {
                                try UIReviewCapture.scrollToBottom(host)
                                try self.capture(host, name: "many-\(appearance.rawValue)-settings-bottom", directory: directory)
                            }
                        }
                    }
                    XCTAssertEqual(size.width, width, accuracy: 1)
                    XCTAssertGreaterThan(size.height, 100)
                    XCTAssertLessThanOrEqual(size.height, 681)
                }
            }
        }
    }

    func testReviewCaptureRejectsMissingBlankAndWrongGeometry() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try UIReviewCapture.validateFile(root.appendingPathComponent("absent.png"), logicalSize: NSSize(width: 10, height: 10)))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 10,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<10 { for y in 0..<10 { bitmap.setColor(.white, atX: x, y: y) } }
        XCTAssertThrowsError(try UIReviewCapture.validate(bitmap, logicalSize: NSSize(width: 10, height: 10)))
        XCTAssertThrowsError(try UIReviewCapture.validate(bitmap, logicalSize: .zero))
        XCTAssertThrowsError(try UIReviewCapture.validate(bitmap, logicalSize: NSSize(width: 320, height: 240)))
    }
    // Removing the menu's bounded viewport must fail this comparison: long menus may not
    // grow with every source, while one-row menus must not reserve the full scroll height.
    func testMenuBoundsLongListsAndLetsSmallMenusShrink() async throws {
        let empty = try await makeModel(sourceCount: 0)
        let one = try await makeModel(sourceCount: 1)
        let many = try await makeModel(sourceCount: 30)
        let emptySize = try measure(StatusMenu(model: empty), width: 320)
        let oneSize = try measure(StatusMenu(model: one), width: 320)
        let manySize = try measure(StatusMenu(model: many), width: 320)
        for size in [emptySize, oneSize, manySize] {
            XCTAssertEqual(size.width, 320, accuracy: 1)
        }
        XCTAssertGreaterThan(oneSize.height, emptySize.height + 10)
        XCTAssertGreaterThan(manySize.height, oneSize.height + 10)
        XCTAssertLessThanOrEqual(manySize.height, 680)
    }

    // Catches an uncapped settings list, a lost desktop width, or a preference update that
    // leaves both compact and overflowing content stuck at the initial window height.
    func testSettingsBoundLongErrorsAndMixedSourcesInBothAppearances() async throws {
        let compact = try await makeModel(sourceCount: 0)
        let many = try await makeModel(sourceCount: 30)
        many.state.sources = many.state.sources.enumerated().map { index, source in
            RegisteredSource(id: source.id, url: source.url, enabled: index.isMultiple(of: 2))
        }
        many.loginNeedsApproval = true
        many.error = String(repeating: "来源暂时不可用，请检查连接后重试。", count: 12)
        let compactSize = try measure(SourceSettings(model: compact), width: 600)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            // Exercise the permission section once, then the long operation error once.
            many.state.authorized = appearance == .darkAqua
            let size = try measure(SourceSettings(model: many), width: 600, appearance: appearance)
            XCTAssertEqual(size.width, 600, accuracy: 1)
            XCTAssertLessThanOrEqual(size.height, 681)
            XCTAssertGreaterThan(size.height, compactSize.height + 10)
        }
        XCTAssertEqual(compactSize.width, 600, accuracy: 1)
        XCTAssertLessThan(compactSize.height, 680)
    }

    // A very long blocking summary plus recovery advice must remain inside the menu's
    // scroll area rather than push the separate action section outside the height bound.
    func testBlockingMenuKeepsHeightBoundWithRecoveryAndProgressContent() async throws {
        let model = try await makeModel(sourceCount: 1)
        let sourceID = try XCTUnwrap(model.state.sources.first?.id)
        model.state.snapshot.activeWork = true
        model.state.snapshot.sourceFileIssueCounts[sourceID] = 2
        model.state.snapshot.summary = SyncStatusSummary(imported: 8, pending: 2, importing: 1, retryPending: 3)
        model.state.snapshot.blockingSummary = String(repeating: "导入结果尚未确认，正在等待恢复。", count: 15)
        model.state.snapshot.blockingError = "synthetic diagnostic only"
        model.state.snapshot.recoveryHint = .uncertainSubmission(message: "synthetic unknown result")
        model.state.nextScan = Date(timeIntervalSince1970: 1_800)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let size = try measure(StatusMenu(model: model), width: 320, appearance: appearance)
            XCTAssertEqual(size.width, 320, accuracy: 1)
            XCTAssertGreaterThan(size.height, 240)
            XCTAssertLessThanOrEqual(size.height, 680)
        }
    }

    func testSourcePathStaysOneLineAtConstrainedWidths() throws {
        let paths = ["/", "/照片/旅行", "/Volumes/非常长的父目录/2026/旅行照片",
            "/家人/旅行👨‍👩‍👧‍👦/假日e\u{301}", "/照片/" + String(repeating: "很长末级目录", count: 20)]
        for path in paths {
            for width in [CGFloat(180), 292, 360] {
                let size = try measure(SourcePathLabel(url: URL(fileURLWithPath: path))
                    .frame(width: width), width: width, minimumHeight: 0)
                XCTAssertEqual(size.width, width, accuracy: 1)
                XCTAssertLessThanOrEqual(size.height, 20)
            }
        }
    }

    func testSourceRowKeepsFileFailureCountInTwoLines() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let size = try measure(SourceRowLabel(
                url: URL(fileURLWithPath: "/Volumes/非常长的父目录/旅行与家庭照片归档"),
                status: String(repeating: "来源目录暂时不可用，正在等待恢复。", count: 12),
                detail: "synthetic raw detail", fileIssueCount: 7).frame(width: 292),
                width: 292, appearance: appearance, minimumHeight: 0,
                inspect: { try self.capture($0, name: "source-row-\(appearance.rawValue)") })
            XCTAssertEqual(size.width, 292, accuracy: 1)
            XCTAssertLessThanOrEqual(size.height, 42)
        }
    }

    func testSettingsSourceViewportBoundsThirtyMixedSources() async throws {
        var sizes: [NSSize] = []
        for count in [0, 1, 30] {
            let model = try await makeModel(sourceCount: count)
            model.state.sources = model.state.sources.enumerated().map { index, source in
                RegisteredSource(id: source.id, url: source.url, enabled: index.isMultiple(of: 2))
            }
            model.loginNeedsApproval = true
            model.error = String(repeating: "来源暂时不可用，请检查连接后重试。", count: 3)
            for source in model.state.sources { model.state.snapshot.sourceFileIssueCounts[source.id] = 7 }
            let size = try measure(SourceSettings(model: model), width: 600, inspect: { host in
                try self.capture(host, name: "settings-\(count)-top")
                if count == 30 {
                    let overflowing = self.scrollViews(in: host).filter {
                        ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 1
                    }
                    XCTAssertEqual(overflowing.count, 1, "Only the source list should scroll in this normal mixed-source fixture")
                    let list = try XCTUnwrap(overflowing.first)
                    XCTAssertLessThanOrEqual(list.frame.height, 280)
                    XCTAssertGreaterThanOrEqual(list.frame.height, 44)
                    let bottom = (list.documentView?.bounds.height ?? 0) - list.contentView.bounds.height
                    list.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                    list.reflectScrolledClipView(list.contentView)
                    host.layoutSubtreeIfNeeded()
                    try self.capture(host, name: "settings-30-bottom")
                }
            })
            XCTAssertEqual(size.width, 600, accuracy: 1)
            XCTAssertLessThanOrEqual(size.height, 680)
            sizes.append(size)
        }
        XCTAssertLessThan(sizes[0].height, sizes[2].height)
        XCTAssertLessThan(sizes[1].height, sizes[2].height)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? [])
            + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func capture(_ host: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["P8_NATIVE_OUTPUT"] else { return }
        try capture(host, name: name, directory: directory)
    }

    private func capture(_ host: NSView, name: String, directory: String) throws {
        _ = try UIReviewCapture.write(host, to: URL(fileURLWithPath: directory).appendingPathComponent("native-\(name).png"))
    }

    private func makeModel(sourceCount: Int) async throws -> AppModel {
        // Rendering needs source descriptors, not 30 files or a running scan. Keep an actual
        // injected runtime for the view's model; the descriptor URLs are never traversed.
        let fixture = try await makeEngineFixture(sourceCount: 0)
        let runtime = SyncRuntime(store: fixture.store, engine: fixture.engine,
                                  now: { Date() }, authorized: { true })
        try await runtime.prepareInjectedRuntime()
        let root = fixture.databaseURL.deletingLastPathComponent()
        addTeardownBlock {
            await runtime.stop()
            await runtime.waitForRound()
            try FileManager.default.removeItem(at: root)
        }
        var state = await runtime.current()
        state.sources = (0..<sourceCount).map { index in
            RegisteredSource(id: UUID(), url: root.appendingPathComponent("来源-\(index)-旅行与家庭照片归档"), enabled: true)
        }
        state.snapshot.summary = SyncStatusSummary()
        state.snapshot.latestScan = ScanProgress(state: .completed)
        for source in state.sources {
            state.snapshot.waitingSources[source.id] = SourceIssue(
                summary: "来源目录暂时不可用，正在等待恢复。请检查磁盘或网络连接。",
                detail: "synthetic source diagnosis",
                kind: .sourceAvailability
            )
        }
        let model = AppModel(runtime: runtime, initialState: state)
        // SourceSettings.onAppear invokes refresh methods; this is a safety precondition for
        // every offscreen host, not an assertion that system permission APIs themselves work.
        guard !model.allowsSystemIntegrations else {
            throw FixtureError.unavailable("Offscreen model must not own system integrations")
        }
        return model
    }

    private func measure<V: View>(
        _ view: V, width: CGFloat, appearance: NSAppearance.Name = .aqua,
        minimumHeight: CGFloat = 100, inspect: ((NSView) throws -> Void)? = nil
    ) throws -> NSSize {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        XCTAssertFalse(window.isVisible)
        var previous = NSSize.zero
        var stablePasses = 0
        // Drain SwiftUI's preference/layout work until the measured size converges. A bounded
        // timeout fails explicitly; a fixed delay alone is not accepted as layout completion.
        for _ in 0..<50 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let size = host.fittingSize
            if abs(size.width - previous.width) < 0.5,
               abs(size.height - previous.height) < 0.5, size.height > minimumHeight {
                stablePasses += 1
            } else {
                stablePasses = 0
            }
            previous = size
            if stablePasses >= 4 {
                XCTAssertFalse(window.isVisible)
                host.setFrameSize(size)
                host.layoutSubtreeIfNeeded()
                try inspect?(host)
                return size
            }
        }
        throw FixtureError.unavailable("Offscreen layout did not converge: \(previous)")
    }
}

extension AppViewTests {
    func testProgressCountsAllUnfinishedStatesButNotHistoryOrRoundEvents() throws {
        let summary = SyncStatusSummary(imported: 120, skipped: 30, pending: 40,
            importing: 1, retryPending: 9, retainedImported: 500)
        let p = try XCTUnwrap(SyncProgressMetrics(summary: summary))
        XCTAssertEqual(p.known, 200)
        XCTAssertEqual(p.processed, 150)
        XCTAssertEqual(p.incomplete, 50)
        XCTAssertEqual(p.importedFraction, 0.6, accuracy: 0.000001)
        XCTAssertEqual(p.skippedFraction, 0.15, accuracy: 0.000001)
        XCTAssertEqual(p.incompleteFraction, 0.25, accuracy: 0.000001)
    }

    func testProgressNilZeroAndDiscoveryGrowth() throws {
        XCTAssertNil(SyncProgressMetrics(summary: nil))
        let zero = try XCTUnwrap(SyncProgressMetrics(summary: SyncStatusSummary()))
        XCTAssertEqual(zero.known, 0)
        XCTAssertEqual(zero.importedFraction + zero.skippedFraction + zero.incompleteFraction, 0)
        let grown = try XCTUnwrap(SyncProgressMetrics(summary:
            SyncStatusSummary(imported: 120, skipped: 30, pending: 249, importing: 1)))
        XCTAssertEqual(grown.known, 400)
        XCTAssertEqual(grown.processed, 150)
        XCTAssertEqual(grown.importedFraction + grown.skippedFraction, 0.375)
    }

    func testProgressPreservesBlockingHeadlineAndStaleSummary() async throws {
        let model = try await makeModel(sourceCount: 1)
        model.state.snapshot.summary = SyncStatusSummary(imported: 200)
        XCTAssertEqual(model.statusDescription, "等待恢复")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let size = try measure(StatusMenu(model: model), width: 320, appearance: appearance)
            XCTAssertEqual(size.width, 320, accuracy: 1)
            XCTAssertLessThanOrEqual(size.height, 680)
            try renderMenu(model, name: "progress-full-unavailable-\(appearance.rawValue)", appearance: appearance)
        }
        model.state.snapshot.waitingSources = [:]
        model.state.snapshot.blockingSummary = "Photos 提交结果尚未确认。"
        model.state.snapshot.blockingError = "synthetic unknown result"
        model.state.snapshot.recoveryHint = .uncertainSubmission(message: "synthetic unknown result")
        XCTAssertEqual(model.statusDescription, "需要处理错误")
        model.state.snapshot.summaryError = "synthetic stale summary"
        XCTAssertEqual(try XCTUnwrap(SyncProgressMetrics(summary: model.state.snapshot.summary)).processed, 200)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let size = try measure(StatusMenu(model: model), width: 320, appearance: appearance)
            XCTAssertEqual(size.width, 320, accuracy: 1)
            XCTAssertLessThanOrEqual(size.height, 680)
            try renderMenu(model, name: "progress-blocked-stale-\(appearance.rawValue)", appearance: appearance)
        }
    }

    func testProgressLargeCountsAndAnalysisStatesRemainBounded() async throws {
        let model = try await makeModel(sourceCount: 1)
        model.state.snapshot.waitingSources = [:]
        model.state.snapshot.summary = SyncStatusSummary(imported: 999999, skipped: 999999,
            pending: 999999, importing: 3, retryPending: 4, retainedImported: 5)
        let p = try XCTUnwrap(SyncProgressMetrics(summary: model.state.snapshot.summary))
        XCTAssertEqual(p.known, 3000004)
        XCTAssertEqual(p.processed, 1999998)
        let summary = NSHostingView(rootView: StatusMenuSingleLine(text: "已处理 1999998 / 已发现 3000004"))
        XCTAssertLessThanOrEqual(summary.fittingSize.width, 266)
        for totalsKnown in [true, false] {
            model.state.snapshot.indexProgress = IndexProgress(state: .updating, totalsKnown: totalsKnown,
                totalAssets: 100000, readyAssets: 50000, totalRepresentations: 200000,
                readyRepresentations: 100000, excludedAssets: 0, issue: nil)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let size = try measure(StatusMenu(model: model), width: 320, appearance: appearance)
                XCTAssertEqual(size.width, 320, accuracy: 1)
                XCTAssertLessThanOrEqual(size.height, 680)
            }
        }
    }

    func testUnavailableSourceKeepsRecoveryHeadlineAndAnalysisInNativeMenu() async throws {
        let model = try await makeModel(sourceCount: 1)
        for state in [IndexState.preparing, .updating, .waiting, .ready] {
            model.state.snapshot.indexProgress = IndexProgress(state: state, totalsKnown: state != .preparing,
                totalAssets: 2, readyAssets: 1, totalRepresentations: 3,
                readyRepresentations: 1, excludedAssets: 0, issue: nil)
            XCTAssertEqual(model.status, .waiting)
            XCTAssertEqual(model.statusDescription, "等待恢复")
            XCTAssertEqual(model.analysis != nil, state != .ready)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let size = try measure(StatusMenu(model: model), width: 320, appearance: appearance)
                XCTAssertEqual(size.width, 320, accuracy: 1)
                XCTAssertLessThanOrEqual(size.height, 680)
                try renderMenu(model, name: "source-unavailable-\(state.rawValue)-\(appearance.rawValue)", appearance: appearance)
            }
        }
    }

    func testCompactAnalysisAndCountersFitNativeMenu() async throws {
        let model = try await makeModel(sourceCount: 1)
        model.state.snapshot.waitingSources = [:]
        model.state.snapshot.summary = SyncStatusSummary(imported: 999999, skipped: 999999,
            pending: 999999, importing: 3, retryPending: 4, retainedImported: 5)
        let cloud = "正在等待 iCloud 图像，连接恢复后自动继续"
        for text in ["已处理 1999998 / 已发现 3000004", cloud] {
            let row = NSHostingView(rootView: StatusMenuSingleLine(text: text))
            let size = row.fittingSize
            XCTAssertLessThanOrEqual(size.width, 292, "Critical row must fit at native caption size: \(text)")
            XCTAssertLessThanOrEqual(size.height, 16, "Critical row must remain a single native line")
        }
        XCTAssertEqual(model.counterNotes.count, 3)
        let details = NSHostingView(rootView: SyncDetailsContent(snapshot: model.state.snapshot))
        XCTAssertLessThanOrEqual(details.fittingSize.width, 320)
        for state in [IndexState.preparing, .updating, .waiting, .paused, .ready] {
            model.state.snapshot.indexProgress = IndexProgress(state: state, totalsKnown: state != .preparing,
                totalAssets: 100000, readyAssets: 50000, totalRepresentations: 200000,
                readyRepresentations: 100000, excludedAssets: 0, issue: state == .waiting ? cloud : nil)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let size = try measure(StatusMenu(model: model), width: 320, appearance: appearance)
                XCTAssertEqual(size.width, 320, accuracy: 1)
                XCTAssertLessThanOrEqual(size.height, 680)
                XCTAssertEqual(model.analysis == nil, state == .ready)
                try renderMenu(model, name: "\(state.rawValue)-\(appearance.rawValue)", appearance: appearance)
            }
        }
    }

    private func renderMenu(_ model: AppModel, name: String, appearance: NSAppearance.Name) throws {
        guard let directory = ProcessInfo.processInfo.environment["P8_NATIVE_OUTPUT"] else { return }
        let host = NSHostingView(rootView: StatusMenu(model: model)
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 680)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)); host.layoutSubtreeIfNeeded() }
        host.setFrameSize(host.fittingSize); host.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("native-\(name).png"))
    }
}
