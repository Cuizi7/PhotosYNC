import AppKit
import SwiftUI
import XCTest
@testable import PhotoSyncCore

@MainActor
final class AppViewTests: XCTestCase {
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
        _ view: V, width: CGFloat, appearance: NSAppearance.Name = .aqua
    ) throws -> NSSize {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let host = NSHostingView(rootView: view)
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
               abs(size.height - previous.height) < 0.5, size.height > 100 {
                stablePasses += 1
            } else {
                stablePasses = 0
            }
            previous = size
            if stablePasses >= 4 {
                XCTAssertFalse(window.isVisible)
                return size
            }
        }
        throw FixtureError.unavailable("Offscreen layout did not converge: \(previous)")
    }
}

extension AppViewTests {
    func testCompactAnalysisAndCountersFitNativeMenu() async throws {
        let model = try await makeModel(sourceCount: 1)
        model.state.snapshot.waitingSources = [:]
        model.state.snapshot.summary = SyncStatusSummary(imported: 999999, skipped: 999999,
            pending: 999999, importing: 3, retryPending: 4, retainedImported: 5)
        let cloud = "正在等待 iCloud 图像，连接恢复后自动继续"
        for text in [model.counters, cloud] {
            let row = NSHostingView(rootView: StatusMenuSingleLine(text: text))
            let size = row.fittingSize
            XCTAssertLessThanOrEqual(size.width, 292, "Critical row must fit at native caption size: \(text)")
            XCTAssertLessThanOrEqual(size.height, 16, "Critical row must remain a single native line")
        }
        XCTAssertEqual(model.counterNotes.count, 3)
        for state in [IndexState.preparing, .updating, .waiting, .paused, .ready] {
            model.state.snapshot.indexProgress = IndexProgress(state: state, totalsKnown: state != .preparing,
                totalAssets: 100000, readyAssets: 50000, totalRepresentations: 200000,
                readyRepresentations: 100000, excludedAssets: 0, issue: state == .waiting ? cloud : nil)
            let size = try measure(StatusMenu(model: model), width: 320)
            XCTAssertEqual(size.width, 320, accuracy: 1)
            XCTAssertLessThanOrEqual(size.height, 680)
            XCTAssertEqual(model.analysis == nil, state == .ready)
            if state == .waiting || state == .ready { try renderMenu(model, name: state.rawValue) }
        }
    }

    private func renderMenu(_ model: AppModel, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["P8_NATIVE_OUTPUT"] else { return }
        let host = NSHostingView(rootView: StatusMenu(model: model)
            .environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: .aqua)
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
