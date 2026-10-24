import AppKit
import SwiftUI
import XCTest
import Vision
@testable import PhotoSyncCore

@MainActor
final class AppViewTests: XCTestCase {
    func testAttentionAndSubmittedPauseHelpFitCompactNativePopover() throws {
        for submittedPause in [false, true] {
            var snapshot = EngineSnapshot()
            snapshot.isPaused = submittedPause
            snapshot.livePhotoActivities = [.working(.completion)]
            snapshot.livePhotoWork.activeGroups = 1
            snapshot.livePhotoWork.requiresAttentionGroups = submittedPause ? 0 : 1
            snapshot.livePhotoWork.hasOwnedSubmission = submittedPause
            let row = try XCTUnwrap(SyncStatusPresentation(snapshot: snapshot).progressRows.first)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let size = try UIReviewCapture.render(TaskDetailsContent(row: row), width: 284, appearance: appearance, minimumHeight: 40) { host, _ in
                    let text = try self.recognizedText(in: host).map(\.text).joined(separator: "")
                    XCTAssertTrue(text.contains(submittedPause ? "当前操作" : "需处理"), text)
                    if let folder = ProcessInfo.processInfo.environment["P8_NATIVE_OUTPUT"] {
                        let output = URL(fileURLWithPath: folder); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        _ = try UIReviewCapture.write(host, to: output.appendingPathComponent("review-priority-\(submittedPause)-\(appearance.rawValue).png"))
                    }
                }
                XCTAssertEqual(size.width, 284, accuracy: 1)
                XCTAssertGreaterThan(size.height, 40); XCTAssertLessThanOrEqual(size.height, 150)
            }
        }
    }
    func testTaskHoverNativeLayoutIsCompactWithoutScrolling() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        func hasScrollView(_ view: NSView) -> Bool { view is NSScrollView || view.subviews.contains(where: hasScrollView) }
        for scenario in [UIReviewScenario.taskVisualUnknown, .taskLiveKnown, .tasksMixed, .tasksKnown,
                         .tasksWaiting, .tasksPaused, .tasksAttention, .taskCompletion] {
            let model = try makeUIReviewModel(scenario: scenario, root: root)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for row in model.progressRows {
                    let size = try UIReviewCapture.render(TaskDetailsContent(row: row), width: 284, appearance: appearance, minimumHeight: 40) { host, _ in
                        XCTAssertFalse(hasScrollView(host), scenario.rawValue)
                        XCTAssertFalse(row.explanation.contains("\n"))
                        if let folder = ProcessInfo.processInfo.environment["P8_NATIVE_OUTPUT"] {
                            let output = URL(fileURLWithPath: folder); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                            _ = try UIReviewCapture.write(host, to: output.appendingPathComponent("compact-\(scenario.rawValue)-\(row.id)-\(appearance.rawValue).png"))
                        }
                    }
                    XCTAssertEqual(size.width, 284, accuracy: 1)
                    XCTAssertGreaterThan(size.height, 40); XCTAssertLessThanOrEqual(size.height, 150, scenario.rawValue)
                }
            }
        }
    }

    func testNormalLivePhotoSkipsDoNotReappearInMenuOrSyncHover() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        for scenario in [UIReviewScenario.completed, .offline] {
            let model = try makeUIReviewModel(scenario: scenario, root: root)
            model.state.snapshot.summary = .init(imported: 120, skipped: 30)
            model.state.snapshot.activeWork = false
            model.state.snapshot.sourceActivities = [:]; model.state.snapshot.sourcePhases = [:]
            model.state.snapshot.livePhotoInventory = .init(phase: .completed, inventoried: 16233, identified: 16228, resourceLimited: 5, skipped: 5)
            model.state.snapshot.livePhotoActivities = [.idle]
            XCTAssertTrue(model.progressRows.isEmpty)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for (surface, view, width) in [("menu", AnyView(StatusMenu(model: model)), CGFloat(320)),
                                              ("sync-details", AnyView(SyncDetailsContent(snapshot: model.state.snapshot)), CGFloat(300))] {
                    _ = try UIReviewCapture.render(view, width: width, appearance: appearance) { host, _ in
                        let text = try self.allScrolledText(in: host)
                        XCTAssertFalse(text.contains("Live Photo"), text)
                        if let folder = ProcessInfo.processInfo.environment["P8_NATIVE_OUTPUT"] {
                            let output = URL(fileURLWithPath: folder); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                            _ = try UIReviewCapture.write(host, to: output.appendingPathComponent("normal-skip-\(scenario.rawValue)-\(surface)-\(appearance.rawValue).png"))
                        }
                    }
                }
            }
        }
    }
    func testSettingsShowsImagePeakBudgetPurposeAndDefaultAndCustomValues() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for value in [ImageMemoryLimit.gib2, .gib4] {
                let model = try makeUIReviewModel(scenario: .completed, root: root)
                model.state.imageMemoryLimit = value
                _ = try measure(SourceSettings(model: model), width: 600, appearance: appearance) { host in
                    let text = try self.recognizedText(in: host).map(\.text).joined(separator: " ")
                    XCTAssertTrue(text.contains("图像处理内存峰值上限"), text)
                    XCTAssertTrue(text.contains("解码") && text.contains("视觉判重") && text.contains("按需"), text)
                    XCTAssertTrue(text.contains("模型") && text.contains("系统缓存"), text)
                    // SwiftUI's picker need not use NSPopUpButton as its backing class.
                    // Verify the value actually drawn for the user instead.
                    XCTAssertTrue(text.replacingOccurrences(of: " ", with: "").contains(value.label.replacingOccurrences(of: " ", with: "")), text)
                    XCTAssertEqual(text.contains("默认"), value == .gib2, text)
                    try self.capture(host, name: "memory-settings-\(value.rawValue)-\(appearance.rawValue)")
                }
            }
        }
    }
    func testEachTaskHasItsOwnCaptionAlignedDetailsButton() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeUIReviewModel(scenario: .analyzing, root: root)
        model.state.snapshot.indexProgress = .init(state: .updating, totalsKnown: true, totalAssets: 16000, readyAssets: 15716, totalRepresentations: 16000, readyRepresentations: 15716, excludedAssets: 0, issue: nil)
        model.state.snapshot.livePhotoInventory = .init(phase: .identifying, inventoried: 16222, identified: 45, pending: 16177)
        model.state.snapshot.livePhotoActivities = [.working(.identification)]
        _ = try UIReviewCapture.render(StatusMenu(model: model), width: 320, appearance: .darkAqua) { host, _ in
            let buttons = self.nativeAccessibility(in: host).compactMap { $0 as? NSButton }
            // SwiftUI exposes identifiers through its remote AX bridge; its backing NSButtons
            // do not carry them. This isolated fixture has exactly two task info controls.
            XCTAssertEqual(buttons.count, 2)
            let visual = try XCTUnwrap(buttons.first)
            let live = try XCTUnwrap(buttons.last)
            let texts = try self.recognizedText(in: host)
            let visualText = try XCTUnwrap(texts.first { $0.text.contains("正在建立视觉索引") })
            let liveText = try XCTUnwrap(texts.first { $0.text.contains("正在配对 Live Photo") })
            XCTAssertEqual(host.convert(visual.bounds, from: visual).midY, visualText.frame.midY, accuracy: 4)
            XCTAssertEqual(host.convert(live.bounds, from: live).midY, liveText.frame.midY, accuracy: 4)
            XCTAssertEqual(texts.filter { $0.text.contains("正在建立视觉索引") }.count, 1)
            XCTAssertEqual(texts.filter { $0.text.contains("正在配对 Live Photo") }.count, 1)
        }
    }
    func testConcurrentProgressIsConsistentAcrossMenuSettingsAndDetails() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeUIReviewModel(scenario: .analyzing, root: root)
        model.state.snapshot.indexProgress = .init(state: .updating, totalsKnown: true, totalAssets: 100, readyAssets: 50, totalRepresentations: 300, readyRepresentations: 250, excludedAssets: 0, issue: nil)
        model.state.snapshot.livePhotoInventory = .init(phase: .identifying, inventoried: 16222, identified: 2, unresolved: 626, retryWaiting: 626)
        model.state.snapshot.livePhotoActivities = [.working(.identification)]
        for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (name, view, width) in [("menu", AnyView(StatusMenu(model: model)), CGFloat(320)), ("settings", AnyView(SourceSettings(model: model)), CGFloat(600)), ("details", AnyView(SyncDetailsContent(snapshot: model.state.snapshot)), CGFloat(300))] {
                _ = try UIReviewCapture.render(view, width: width, appearance: appearance) { host, _ in
                    let text = try self.allScrolledText(in: host)
                    XCTAssertTrue(text.contains("16222") && text.contains("50"), text)
                    XCTAssertTrue(text.contains("Live Photo") && text.contains("索引"), text)
                    for obsolete in ["已清点", "已识别", "待核实", "正在下载", "不会下载"] { XCTAssertFalse(text.contains(obsolete), text) }
                    if let folder = ProcessInfo.processInfo.environment["P8_NATIVE_OUTPUT"] {
                        let output = URL(fileURLWithPath: folder); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        _ = try UIReviewCapture.write(host, to: output.appendingPathComponent("dual-\(look)-\(name).png"))
                    }
                }
            }
        }
    }
    func testHistoricalLivePhotoProgressFitsExistingMenuAndDetails() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeUIReviewModel(scenario: .analyzing, root: root)
        model.state.sources = []
        model.state.snapshot.indexProgress = nil
        model.state.snapshot.livePhotoActivities = [.working(.identification)]
        model.state.snapshot.livePhotoInventory = .init(phase: .identifying, inventoried: 200000, identified: 120000, unresolved: 25)
        for (view, width) in [(AnyView(StatusMenu(model: model)), CGFloat(320)), (AnyView(SyncDetailsContent(snapshot: model.state.snapshot)), CGFloat(300))] {
            let height = try measure(view, width: width, minimumHeight: 0) { host in
                XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1)
                let text = try self.recognizedText(in: host).map(\.text).joined(separator: " ")
                XCTAssertTrue(text.contains("Live Photo"), text)
                XCTAssertFalse(text.contains("operation_id"), text)
            }
            XCTAssertLessThan(height.height, 800)
        }
    }

    func testAnalysisDetailsUseSameAssetProgressAsMenu() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeUIReviewModel(scenario: .analyzing, root: root)
        model.state.snapshot.indexActivity = .working
            model.state.snapshot.indexProgress = IndexProgress(state: .updating, totalsKnown: true,
            totalAssets: 15702, readyAssets: 2192, totalRepresentations: 45000,
            readyRepresentations: 6789, excludedAssets: 99, issue: nil)
        for (view, width) in [(AnyView(StatusMenu(model: model)), CGFloat(320)), (AnyView(SyncDetailsContent(snapshot: model.state.snapshot)), CGFloat(300))] {
            _ = try measure(view, width: width, minimumHeight: 0) { host in
                XCTAssertEqual(SyncStatusPresentation(snapshot: model.state.snapshot).progressRows.first?.progressText, "已分析 2192 / 15702 张")
                let texts = try self.recognizedText(in: host).map(\.text).joined(separator: "\n")
                XCTAssertTrue(texts.contains("2192") && texts.contains("15702"), texts)
                XCTAssertFalse(texts.contains("6789"), texts)
                XCTAssertFalse(texts.contains("45000"), texts)
            }
        }
    }

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

    func testKnownAndUnknownTracksHaveEqualWidthHeightAndSolidFill() throws {
        let known = SyncStatusPresentation.PreparationProgress(id: "visualIndex", subtitle: "", progressText: nil,
            fraction: 0.5, explanation: "", active: false)
        let unknown = SyncStatusPresentation.PreparationProgress(id: "livePhoto", subtitle: "", progressText: nil,
            fraction: nil, explanation: "", active: false)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = VStack(spacing: 20) { TaskProgressTrack(row: known); TaskProgressTrack(row: unknown) }
                .padding(.horizontal, 14).frame(width: 320, height: 130)
            _ = try UIReviewCapture.render(view, width: 320, appearance: appearance) { host, _ in
                let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: image)
                let scale = CGFloat(image.pixelsWide) / 320
                let background = try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: 0)?.usingColorSpace(.deviceRGB))
                func different(_ c: NSColor, _ b: NSColor) -> Bool {
                    abs(c.redComponent - b.redComponent) + abs(c.greenComponent - b.greenComponent) + abs(c.blueComponent - b.blueComponent) > 0.04
                }
                var tracks: [[Int]] = []
                for y in 0..<image.pixelsHigh {
                    let occupied = (0..<image.pixelsWide).filter { x in
                        guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                        return different(c, background)
                    }
                    if occupied.count > Int(285 * scale) { tracks.append([y, occupied.first!, occupied.last!]) }
                }
                let groups = tracks.reduce(into: [[[Int]]]()) { groups, line in
                    if let last = groups.last?.last, line[0] == last[0] + 1 { groups[groups.count - 1].append(line) }
                    else { groups.append([line]) }
                }
                XCTAssertEqual(groups.count, 2)
                for group in groups {
                    XCTAssertEqual(CGFloat(group.count) / scale, 5, accuracy: 1)
                    let middle = group[group.count / 2]
                    XCTAssertEqual(CGFloat(middle[2] - middle[1] + 1) / scale, 292, accuracy: 1)
                    let blues = (middle[1]...middle[2]).compactMap { image.colorAt(x: $0, y: middle[0])?.usingColorSpace(.deviceRGB) }
                        .filter { $0.blueComponent > $0.redComponent + 0.2 }
                    XCTAssertGreaterThan(blues.count, Int(60 * scale))
                    let interior = blues.dropFirst(3).dropLast(3)
                    if let first = interior.first { XCTAssertTrue(interior.allSatisfy { !different($0, first) }, "Fill must be solid, without a gradient") }
                }
                if groups.count == 2 { XCTAssertEqual(groups[0][groups[0].count / 2][1...2], groups[1][groups[1].count / 2][1...2]) }
            }
        }
    }

    func testTaskCaptionsKeepNameInfoAndCountOnOneLine() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        for scenario in [UIReviewScenario.taskVisualUnknown, .taskLiveKnown, .tasksMixed, .tasksKnown, .tasksWaiting, .tasksPaused, .tasksAttention, .taskCompletion] {
            let model = try makeUIReviewModel(scenario: scenario, root: root)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                _ = try UIReviewCapture.render(StatusMenu(model: model), width: 320, appearance: appearance) { host, _ in
                    let rows = model.progressRows
                    let buttons = self.nativeAccessibility(in: host).compactMap { $0 as? NSButton }
                    XCTAssertEqual(buttons.count, rows.count)
                    let texts = try self.recognizedText(in: host)
                    for (row, button) in zip(rows, buttons) {
                        let frame = host.convert(button.bounds, from: button)
                        // This test checks native geometry, not Vision's Chinese spelling
                        // (for example 索引 can be recognized as 素引). Locate the caption
                        // to the left of its real info button; a missing or wrapped title
                        // still fails the vertical alignment checks below. No OCR hints.
                        let title = try XCTUnwrap(texts.filter { $0.frame.minX < frame.minX && $0.frame.maxX <= frame.maxX + 4 }
                            .min { abs($0.frame.midY - frame.midY) < abs($1.frame.midY - frame.midY) }, "\(scenario.rawValue): \(texts)")
                        XCTAssertEqual(frame.midY, title.frame.midY, accuracy: 4, scenario.rawValue)
                        if let count = row.countText {
                            let number = try XCTUnwrap(count.split(whereSeparator: { !$0.isNumber }).first)
                            let visible = try XCTUnwrap(texts.first { $0.text.contains(number) }, "\(scenario.rawValue): \(texts)")
                            XCTAssertEqual(visible.frame.midY, title.frame.midY, accuracy: 4, scenario.rawValue)
                            XCTAssertLessThanOrEqual(visible.frame.maxX, 308, scenario.rawValue)
                        }
                    }
                    if let folder = ProcessInfo.processInfo.environment["P8_NATIVE_OUTPUT"] {
                        _ = try UIReviewCapture.write(host, to: URL(fileURLWithPath: folder).appendingPathComponent("task-\(scenario.rawValue)-\(appearance.rawValue).png"))
                    }
                }
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
                if let directory = ProcessInfo.processInfo.environment["PHOTOSYNC_UI_DIAGNOSTICS"] {
                    try self.capture(host, name: "scan-state-\(state)-deferred-\(deferred)", directory: directory)
                    let url = URL(fileURLWithPath: directory).appendingPathComponent("scan-state-\(state)-deferred-\(deferred).txt")
                    try ("state=\(state) deferred=\(deferred) bounds=\(host.bounds)\n" + (texts + ["AX:"] + self.nativeAccessibility(in: host).map { "\(type(of: $0)) role=\($0.accessibilityRole()?.rawValue ?? "nil") label=\($0.accessibilityLabel() ?? "nil") value=\(String(describing: $0.accessibilityValue())) children=\($0.accessibilityChildren()?.count ?? 0)" }).joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8)
                }
                // Exact row semantics are asserted from the same pure projection consumed
                // by the native view; OCR remains a visual observation, not a Unicode parser.
                let rows = SyncStatusPresentation(snapshot: snapshot).scanDetailRows
                let values = Dictionary(uniqueKeysWithValues: rows.map { ($0.title, $0.value) })
                XCTAssertTrue(texts.contains(expected), "Missing visible state: \(texts)")
                XCTAssertEqual(texts.contains("检查候选"), state != .notStarted, "Exact visible row: \(texts)")
                XCTAssertEqual(values["检查候选"], state == .notStarted ? nil : "0")
                XCTAssertEqual(values["新增导入"], state == .notStarted ? nil : "0")
                XCTAssertEqual(values["状态"], state == .notStarted ? nil : expected)
                XCTAssertEqual(values["时间"], state == .notStarted ? nil : (snapshot.latestScan.endedAt ?? date).formatted(date: .abbreviated, time: .shortened))
                XCTAssertEqual(values["开始"], state == .completed ? date.formatted(date: .abbreviated, time: .shortened) : nil)
                XCTAssertNil(values["本次读取失败"])
                XCTAssertNil(values["来源等待恢复"])
                XCTAssertFalse(rows.contains { $0.value.contains("99") })
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
                let count = try XCTUnwrap(self.recognizedText(in: host).first { $0.text.contains("已处理") })
                XCTAssertEqual(frame.minX, 14 + countSize.width + 7, accuracy: 2)
                // Adjacency is relative to the count row, independent of the headline icon's
                // intrinsic height/baseline. Moving the button to another row must still fail.
                XCTAssertEqual(frame.midY, count.frame.midY, accuracy: 4)
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
        // One fixed observation scale for the entire corpus. The original native bitmap
        // remains the evidence artifact; no vocabulary hints or character replacement.
        let original = try XCTUnwrap(bitmap.cgImage)
        let context = try XCTUnwrap(CGContext(data: nil, width: original.width * 2,
            height: original.height * 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .high
        // Transparent cacheDisplay text needs an opaque background in the OCR input only.
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let background: CGFloat = dark ? 0 : 1
        context.setFillColor(CGColor(red: background, green: background, blue: background, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.draw(original, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        try VNImageRequestHandler(cgImage: try XCTUnwrap(context.makeImage())).perform([request])
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

    func testReviewIssueSnapshotsKeepLegacyAndDetailedProjectionsConsistent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for (scenario, expectedKind, expectedCount, expectedPrimaryID) in [
            (UIReviewScenario.mixedIssues, SourceIssueKind.sourceAvailability, 2, "directory-a"),
            (.longIssues, .file, 20, "read-00")
        ] {
            let model = try makeUIReviewModel(scenario: scenario, root: root)
            let sourceID = try XCTUnwrap(model.state.sources.first?.id)
            let details = try XCTUnwrap(model.state.snapshot.sourceIssueDetails[sourceID])
            let primary = try XCTUnwrap(model.state.snapshot.waitingSources[sourceID])
            let expected = try XCTUnwrap(details.first { $0.id == expectedPrimaryID })
            XCTAssertEqual(primary.kind, expectedKind, scenario.rawValue)
            XCTAssertEqual(primary.summary, expected.summary, scenario.rawValue)
            XCTAssertEqual(primary.detail, expected.detail, scenario.rawValue)
            XCTAssertEqual(model.state.snapshot.sourceFileIssueCounts[sourceID], expectedCount, scenario.rawValue)
            XCTAssertEqual(details.filter { $0.kind == .file }.count, expectedCount, scenario.rawValue)
            XCTAssertFalse(model.recoveryPending(for: sourceID), scenario.rawValue)
            if scenario == .mixedIssues { XCTAssertEqual(model.statusDescription, "等待恢复") }
            else { XCTAssertTrue(details.allSatisfy { $0.kind == .file }) }
        }
        let permission = try XCTUnwrap(reviewIssues().first { $0.id == "scan-same" })
        XCTAssertEqual(permission.summary, "文件无法访问，请检查访问权限。")
        XCTAssertEqual(permission.summary, SourceIssueText.fileUnreadable(relativePath: "same.jpg",
            url: URL(fileURLWithPath: permission.path), error: NSError(domain: NSPOSIXErrorDomain, code: 13)).summary)
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

    func testSourceRowSeparatesDirectoryAvailabilityFromFileProblemCount() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let size = try measure(SourceRowLabel(url: URL(fileURLWithPath: "/示例来源/旅行"),
                status: "原来的人话", issues: reviewIssues()).frame(width: 292),
                width: 292, appearance: appearance, minimumHeight: 0) { host in
                let texts = try self.recognizedText(in: host).map(\.text).joined(separator: "\n")
                XCTAssertEqual(SourceRowLabel(url: URL(fileURLWithPath: "/示例来源"), status: "原来的人话", issues: reviewIssues()).statusText, "部分子目录不可用 · 发现 3 项问题")
                XCTAssertTrue(texts.contains("发现") && texts.contains("3") && texts.contains("项问题"), texts)
                XCTAssertTrue(texts.contains("部分子目录不可用"), texts)
                XCTAssertFalse(texts.contains("读取失败"), texts)
                XCTAssertFalse(texts.contains("原来的人话"), texts)
            }
            XCTAssertLessThanOrEqual(size.height, 58)
        }
    }

    func testUnavailableRootShowsStatusInMenuAndSettingsWithoutProblemCount() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeUIReviewModel(scenario: .offline, root: root)
        let source = model.state.sources[0]
        let issues = try XCTUnwrap(model.state.snapshot.sourceIssueDetails[source.id])
        XCTAssertEqual(SourceRowLabel(url: source.url, status: "等待恢复", issues: issues).statusText,
            "来源目录不可用，等待恢复")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for view in [AnyView(StatusMenu(model: model)), AnyView(SourceSettings(model: model))] {
                _ = try measure(view, width: 560, appearance: appearance, minimumHeight: 0) { host in
                    let text = try self.allScrolledText(in: host)
                    // Exact semantic copy is asserted above; OCR sometimes reads 录 as 求.
                    XCTAssertTrue(text.contains("来源") && text.contains("不可用"), text)
                    XCTAssertFalse(text.contains("项问题"), text)
                }
            }
            _ = try measure(SourceIssuesContent(sourceURL: source.url, issues: issues, recoveryPending: false),
                width: 360, appearance: appearance, minimumHeight: 0) { host in
                let text = try self.allScrolledText(in: host)
                // Exact semantic copy is asserted above; OCR sometimes reads 录 as 求.
                    XCTAssertTrue(text.contains("来源") && text.contains("不可用"), text)
                XCTAssertFalse(text.contains("项问题"), text)
            }
        }
    }

    func testAvailableDirectoryCountsOnlyFileAndSubmissionProblems() {
        let issues = reviewIssues().filter { $0.kind != .sourceAvailability }
        let url = URL(fileURLWithPath: "/示例来源")
        XCTAssertEqual(SourceRowLabel(url: url, status: "已启用", issues: issues).statusText, "发现 3 项问题")
        XCTAssertEqual(SourceRowLabel(url: url, status: "已启用", issues: issues, recoveryPending: true).statusText,
            "目录扫描尚未完成，稍后继续 · 发现 3 项问题")
    }

    func testSourceDetailsGroupCompletePathsAndCauses() throws {
        let issues = reviewIssues()
        let groups = SourceIssuesContent(sourceURL: URL(fileURLWithPath: "/示例来源"), issues: issues, recoveryPending: false).groups
        XCTAssertEqual(groups.map(\.title), ["目录与连接", "读取与解析", "导入与提交"])
        XCTAssertEqual(groups.map { $0.members.count }, [2, 2, 1])
        XCTAssertEqual(groups[0].members.map(\.path), ["/示例来源/A", "/示例来源/B"])
        XCTAssertEqual(groups.flatMap(\.members).map(\.id).sorted(), issues.map(\.id).sorted())
        XCTAssertEqual(groups[1].members[0].path, "/示例来源/same.jpg")
        XCTAssertEqual(groups[2].members[0].path, "/示例来源/same.jpg")
        _ = try measure(SourceIssuesContent(sourceURL: URL(fileURLWithPath: "/示例来源"),
            issues: issues, recoveryPending: false), width: 360, minimumHeight: 0) { host in
            let texts = try self.allScrolledText(in: host)
            for title in ["目录与连接", "读取与解析", "导入与提交"] {
                XCTAssertTrue(texts.contains(title), texts)
            }
            XCTAssertEqual(issues.filter { $0.path == "/示例来源/same.jpg" }.count, 2)
            XCTAssertTrue(texts.contains("same.jpg"), texts)
            XCTAssertTrue(texts.contains("3") && texts.contains("项问题"), texts)
            for detail in ["NSPOSIXErrorDomain", "NSCocoaErrorDomain", "读取时长"] {
                XCTAssertTrue(texts.contains(detail), texts)
            }
        }
        _ = try measure(SourceIssuesContent(sourceURL: URL(fileURLWithPath: "/示例来源"),
            issues: Array(issues.prefix(1)), recoveryPending: false), width: 360, minimumHeight: 0) { host in
            let text = try self.recognizedText(in: host).map(\.text).joined(separator: "\n")
            XCTAssertEqual(SourceIssuesContent(sourceURL: URL(fileURLWithPath: "/示例来源"), issues: Array(issues.prefix(1)), recoveryPending: false).groups.map(\.title), ["目录与连接"])
            XCTAssertTrue(text.contains("连接") && text.contains("NSPOSIXErrorDomain"), text)
            XCTAssertFalse(text.contains("读取与解析"), text)
            XCTAssertFalse(text.contains("导入与提交"), text)
        }
    }

    func testDirectoryRescanCopyFollowsActualSourcePhase() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeUIReviewModel(scenario: .recoveryPending, root: root)
        let id = model.state.sources[0].id
        let cases: [(phase: String?, paused: Bool, expected: String)] = [
            (nil, false, "目录扫描尚未完成"),
            ("扫描目录与元数据", false, "正在扫描目录"),
            ("新增到照片", false, "目录扫描尚未完成"),
            ("扫描目录与元数据", true, "目录扫描尚未完成")]
        for item in cases {
            model.state.snapshot.sourcePhases[id] = item.phase
            model.state.snapshot.sourceActivities[id] = item.phase == "扫描目录与元数据" ? .scanning : nil
            model.state.snapshot.isPaused = item.paused
            XCTAssertEqual(model.isScanningDirectory(for: id), item.expected == "正在扫描目录")
            for view in [AnyView(StatusMenu(model: model)), AnyView(SourceSettings(model: model))] {
                _ = try measure(view, width: 560, minimumHeight: 0) { host in
                    let text = try self.allScrolledText(in: host)
                    XCTAssertTrue(text.contains(item.expected), text)
                    XCTAssertFalse(text.contains("等待确认来源恢复"), text)
                    XCTAssertFalse(text.contains("项问题"), text)
                    if item.expected != "正在扫描目录" { XCTAssertFalse(text.contains("正在扫描目录"), text) }
                }
            }
        }
        _ = try measure(SourceIssuesContent(sourceURL: model.state.sources[0].url, issues: [],
            recoveryPending: true, isScanningDirectory: true), width: 360, minimumHeight: 0) { host in
            let text = try self.recognizedText(in: host).map(\.text).joined(separator: "\n")
            XCTAssertTrue(text.contains("正在扫描目录"), text)
            XCTAssertFalse(text.contains("项问题"), text)
        }
    }

    func testRecoveryPendingDoesNotInventIssueCount() throws {
        _ = try measure(SourceRowLabel(url: URL(fileURLWithPath: "/示例来源"), status: "已启用",
            issues: [], recoveryPending: true).frame(width: 292), width: 292, minimumHeight: 0) { host in
            let text = try self.recognizedText(in: host).map(\.text).joined(separator: "\n")
            XCTAssertTrue(text.contains("目录扫描尚未完成，稍后继续"), text)
            XCTAssertFalse(text.contains("项问题"), text)
        }
    }

    func testLongSourceIssuesScrollWithoutTruncatingFinalItem() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let size = try measure(SourceIssuesContent(sourceURL: URL(fileURLWithPath: "/示例来源"),
                issues: reviewIssues(long: true), recoveryPending: true), width: 360, appearance: appearance,
                minimumHeight: 0) { host in
                XCTAssertLessThanOrEqual(host.bounds.height, 420)
                let scroll = try XCTUnwrap(self.scrollViews(in: host).first)
                XCTAssertGreaterThan(scroll.documentView?.bounds.height ?? 0, scroll.bounds.height)
                try UIReviewCapture.scrollToBottom(host)
                let text = try self.recognizedText(in: host).map(\.text).joined(separator: "\n")
                XCTAssertTrue(text.contains("FINAL-19"), text)
                XCTAssertTrue(text.contains("CAUSE-END-19"), text)
            }
            XCTAssertEqual(size.width, 360, accuracy: 1)
            XCTAssertLessThanOrEqual(size.height, 420)
        }
    }

    func testAnalysisDetailsCoverUnknownZeroWaitingPausedAndReady() throws {
        for state in [IndexState.preparing, .updating, .waiting, .paused, .ready] {
            var snapshot = EngineSnapshot()
            snapshot.summary = SyncStatusSummary(imported: 12, retainedImported: 3)
            snapshot.indexProgress = IndexProgress(state: state, totalsKnown: state != .preparing,
                totalAssets: 0, readyAssets: 0, totalRepresentations: 999,
                readyRepresentations: 888, excludedAssets: 2, issue: state == .waiting ? "正在等待 iCloud 图像，连接恢复后自动继续" : nil)
            snapshot.isPaused = true
            _ = try measure(SyncDetailsContent(snapshot: snapshot), width: 300, minimumHeight: 0) { host in
                let text = try self.allScrolledText(in: host)
                XCTAssertEqual(text.contains("视觉索引"), state != .ready, text)
                XCTAssertTrue(text.contains("已发现") && text.contains("文件") && text.contains("已导入"), text)
                XCTAssertTrue(text.contains("本次扫描"), text)
                XCTAssertTrue(text.contains("统计当前启用来源") && text.contains("记录") && text.contains("此前扫描"), text)
                XCTAssertTrue(text.contains("仅统计本轮扫描事件"), text)
                if state != .ready {
                    XCTAssertTrue(text.contains("已完成") && text.contains("保留"), text)
                    XCTAssertTrue((text.contains("已分析") && text.contains("0")), text)
                }
                if state == .waiting { XCTAssertFalse(text.contains("iCloud"), "Paused task help should show only its current pause explanation") }
                XCTAssertFalse(text.contains("888"), text)
            }
        }
    }

    func testReaderCapacityAndStalledWaitingAreVisibleInNativeDetails() throws {
        for issue in ["正在等待图像读取资源，稍后自动继续。", "正在等待系统结束图像读取，完成后自动继续。"] {
            var snapshot = EngineSnapshot()
            snapshot.indexProgress = IndexProgress(state: .waiting, totalsKnown: true, totalAssets: 40,
                readyAssets: 16, totalRepresentations: 40, readyRepresentations: 16, excludedAssets: 0, issue: issue)
            _ = try measure(SyncDetailsContent(snapshot: snapshot), width: 300, minimumHeight: 0) { host in
                let text = try self.allScrolledText(in: host)
                XCTAssertTrue(text.contains(issue), text)
                XCTAssertTrue(text.contains("16") && text.contains("40"), text)
                XCTAssertFalse(text.contains("文件失败"), text)
            }
        }
    }

    func testTaskDetailsStayAnchoredAcrossCountQueueWaitAndPauseChanges() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        for taskIndex in [0, 1] {
            let model = try makeUIReviewModel(scenario: .tasksKnown, root: root)
            _ = try UIReviewCapture.render(StatusMenu(model: model), width: 320, appearance: .aqua) { host, window in
                let before = Set(NSApp.windows.map(\.windowNumber))
                window.orderFront(nil); defer { window.orderOut(nil) }
                @MainActor func buttons() -> [NSButton] { self.nativeAccessibility(in: host).compactMap { $0 as? NSButton } }
                let button = try XCTUnwrap(buttons().dropFirst(taskIndex).first)
                button.performClick(nil)
                let popup = try XCTUnwrap(self.waitForWindow(excluding: before))
                defer { popup.orderOut(nil); popup.close() }
                let content = try XCTUnwrap(popup.contentView)
                for stage in 0..<4 {
                    model.state.snapshot.indexProgress = .init(state: .updating, totalsKnown: true, totalAssets: 16000, readyAssets: 15717, totalRepresentations: 16000, readyRepresentations: 15717, excludedAssets: 0, issue: nil)
                    model.state.snapshot.livePhotoInventory?.identified = 46
                    model.state.snapshot.indexActivity = stage < 2 ? .queued : .waiting
                    model.state.snapshot.livePhotoActivities = stage < 2 ? [.queued(.identification)] : [.waiting(nextRetryAt: nil)]
                    model.state.snapshot.isPaused = stage == 3
                    let expected = stage == 3 ? "保留" : taskIndex == 0 ? "照片" : "Live Photo"
                    XCTAssertTrue(self.waitUntil { (try? self.recognizedText(in: content).map(\.text).joined()).map { $0.contains(expected) } ?? false })
                    XCTAssertTrue(popup.isVisible)
                    XCTAssertTrue(buttons().dropFirst(taskIndex).first === button, "Trigger must survive ordinary task lifecycle gaps")
                    XCTAssertEqual(model.progressRows.map(\.id), ["visualIndex", "livePhoto"])
                    if let folder = ProcessInfo.processInfo.environment["P8_NATIVE_OUTPUT"] {
                        do {
                            // The native popover bitmap has transparent monochrome text.
                            // Its content is verified by OCR above; the opaque-host image
                            // validator is inappropriate for this unmodified native capture.
                            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                            content.cacheDisplay(in: content.bounds, to: bitmap)
                            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
                            XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
                            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                            let directory = URL(fileURLWithPath: folder)
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                            try data.write(to: directory.appendingPathComponent("task-details-\(taskIndex)-stage-\(stage).png"), options: .atomic)
                        }
                        catch { XCTFail("Native popover image capture failed: \(error)"); return }
                    }
                }
                // This non-key fixture verifies native click/popover identity. Escape and hover
                // event delivery are recorded separately by the no-activation UIReview probe.

            }
        }
    }

    private func allScrolledText(in host: NSView) throws -> String {
        guard let scroll = scrollViews(in: host).first else {
            return try recognizedText(in: host).map(\.text).joined(separator: "\n")
        }
        let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
        var text: [String] = []
        var offset: CGFloat = 0
        repeat {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            text += try recognizedText(in: host).map(\.text)
            if offset >= maximum { break }
            offset = min(maximum, offset + max(1, scroll.contentView.bounds.height - 50))
        } while true
        return text.joined(separator: "\n")
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        return condition()
    }

    private func waitForWindow(excluding ids: Set<Int>) -> NSWindow? {
        var result: NSWindow?
        _ = waitUntil {
            result = NSApp.windows.first { $0.isVisible && !ids.contains($0.windowNumber) }
            return result != nil
        }
        return result
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
        XCTAssertEqual(model.statusDescription, "等待恢复")
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
            model.state.snapshot.indexActivity = .working
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
            model.state.snapshot.indexActivity = state == .ready ? .idle : .working
            model.state.snapshot.indexProgress = IndexProgress(state: state, totalsKnown: state != .preparing,
                totalAssets: 2, readyAssets: 1, totalRepresentations: 3,
                readyRepresentations: 1, excludedAssets: 0, issue: nil)
            XCTAssertEqual(model.status, state == .ready ? .waiting : .preparing)
            XCTAssertEqual(model.statusDescription, state == .ready ? "等待恢复" : "正在准备")
            XCTAssertEqual(!model.progressRows.isEmpty, state != .ready)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let size = try measure(StatusMenu(model: model), width: 320, appearance: appearance)
                XCTAssertEqual(size.width, 320, accuracy: 1)
                XCTAssertLessThanOrEqual(size.height, 680)
                try renderMenu(model, name: "source-unavailable-\(state)-\(appearance.rawValue)", appearance: appearance)
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
        XCTAssertEqual(model.counterNotes.count, 4)
        let details = NSHostingView(rootView: SyncDetailsContent(snapshot: model.state.snapshot))
        XCTAssertLessThanOrEqual(details.fittingSize.width, 320)
        // The counter fixture above intentionally contains unknown imports. Task
        // activity scenes must not inherit that independent submission barrier.
        model.state.snapshot.summary?.importing = 0
        for state in [IndexState.preparing, .updating, .waiting, .paused, .ready] {
            model.state.snapshot.isPaused = state == .paused
            model.state.snapshot.indexActivity = state == .ready ? .idle : (state == .waiting || state == .paused) ? .waiting : .working
            model.state.snapshot.indexProgress = IndexProgress(state: state, totalsKnown: state != .preparing,
                totalAssets: 100000, readyAssets: 50000, totalRepresentations: 200000,
                readyRepresentations: 100000, excludedAssets: 0, issue: state == .waiting ? cloud : nil)
            let expected = state == .ready ? nil : state == .paused ? "视觉索引已暂停" : state == .waiting ? "视觉索引等待恢复" : "正在建立视觉索引"
            XCTAssertEqual(model.progressRows.first?.subtitle, expected)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let size = try measure(StatusMenu(model: model), width: 320, appearance: appearance)
                XCTAssertEqual(size.width, 320, accuracy: 1)
                XCTAssertLessThanOrEqual(size.height, 680)
                XCTAssertEqual(model.progressRows.isEmpty, state == .ready)
                try renderMenu(model, name: "\(state)-\(appearance.rawValue)", appearance: appearance)
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
