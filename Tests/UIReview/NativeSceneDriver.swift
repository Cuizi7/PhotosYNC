// Compiled only by run-native-scenes.py. The @main and Settings/MenuBarExtra
// declarations come from the unchanged production PhotoSyncApp.swift scene tree.
import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Vision
@testable import PhotoSyncCore

struct NativeSceneMatrix: Decodable {
    struct Scenario: Decodable { let id: String, steps: [String] }
    let schemaVersion: Int, scenarios: [Scenario], appearances: [String], requiredMenuFrames: [String], copy: [String: [String]]
}

@MainActor
enum NativeSceneSession {
    static var runtime: SyncRuntime!
    static var model: AppModel!
    static let output = argument("--native-output").map { URL(fileURLWithPath: $0) }!
    static let allowFocus = CommandLine.arguments.contains("--allow-focus")
    static let settingsOnly = CommandLine.arguments.contains("--settings-only")
    static let usesXCTest = CommandLine.arguments.contains("--native-xcuitest")
    static let owner = (try? JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("native-owner.json")))) as? [String: Any] ?? [:]
    static let preferenceName = "PhotosYNC.NativeReview." + (owner["runID"] as? String ?? "invalid")
    static let preferences = UserDefaults(suiteName: preferenceName)!
    static func argument(_ flag: String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.indices.contains(i + 1) else { return nil }
        return CommandLine.arguments[i + 1]
    }
    static func makeModel() -> AppModel {
        do {
            // The runner owns a new root. No standard preferences, production
            // support path or system Photos adapter is ever constructed here.
            guard output.isFileURL, !output.path.contains("/Library/Application Support/"),
                  FileManager.default.fileExists(atPath: output.appendingPathComponent("native-owner.json").path) else { throw NativeSceneError.invalid("Unowned native output") }
            if usesXCTest {
                guard owner["active"] as? Bool == true, let runID = owner["runID"] as? String, UUID(uuidString: runID) != nil,
                      let expires = owner["expiresAt"] as? Double, expires > Date().timeIntervalSince1970 else {
                    throw NativeSceneError.invalid("Expired or cancelled native test lease")
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + min(180, expires - Date().timeIntervalSince1970)) {
                    kill(getpid(), SIGTERM)
                }
            }
            try write(["pid": ProcessInfo.processInfo.processIdentifier, "executable": Bundle.main.executableURL!.path,
                "inputPosting":CGPreflightPostEventAccess(), "screenCapture":CGPreflightScreenCaptureAccess()], "native-process.json")
            runtime = try makeRuntime()
            var state = RuntimeState(); state.authorized = true
            model = AppModel(runtime: runtime, initialState: state)
            return model
        } catch { fatalError("Isolated native fixture failed: \(error)") }
    }
    static func makeRuntime() throws -> SyncRuntime {
        let root = output.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let c = try DedupConfiguration.loadValidated(resourceDirectory: DedupConfiguration.bundledResourceDirectory())
        return SyncRuntime(store: nil, advancedFactory: { store, executor, directory, now, logger in
            let budget = ImageWorkBudget(limits: c.resources)
            return AdvancedRuntimeGraph(store: store, photos: NativeScenePhotos(), model: NativeSceneModel(), configuration: c,
                executor: executor, budget: budget, directory: directory, now: now, logger: logger)
        }, logsURL: root.appendingPathComponent("Logs"), databaseURL: root.appendingPathComponent("state.sqlite"),
            now: { Date() }, authorized: { true }, imageMemoryPreferences: preferences)
    }
    static func write(_ value: Any, _ name: String) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic)
    }
}

struct NativeSceneLauncher: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if #available(macOS 14, *) { NativeSceneOpener(model: model) }
        else { Color.clear.onAppear { try? NativeSceneSession.write(["status":"blocked_environment", "reason":"This Settings scene driver needs macOS 14; macOS 13 fallback requires separate smoke evidence."], "native-captures.json"); NSApp.terminate(nil) } }
    }
}

@available(macOS 14, *)
private struct NativeSceneOpener: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Color.clear.task {
            for window in NSApp.windows where window.title == "PhotosYNC Native Driver" { window.orderOut(nil) }
            // A directly owned QA executable needs a regular foreground
            // activation policy. The production scene/view tree is unchanged.
            NSApp.setActivationPolicy(NativeSceneSession.usesXCTest ? .accessory : NativeSceneSession.allowFocus ? .regular : .accessory)
            do {
                let driver = NativeSceneDriver(model: model, open: { openSettings() })
                try await driver.run()
            } catch {
                let path = NativeSceneSession.output.appendingPathComponent("native-captures.json")
                var report = ((try? Data(contentsOf: path)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
                report["status"] = "blocked_environment"; report["reason"] = String(describing: error)
                try? NativeSceneSession.write(report, "native-captures.json")
            }
            NSApp.terminate(nil)
        }
    }
}

private enum NativeSceneError: Error { case invalid(String) }

@MainActor
private final class NativeSceneDriver {
    let model: AppModel, open: () -> Void
    let output = NativeSceneSession.output
    var frames = [[String: Any]]()
    init(model: AppModel, open: @escaping () -> Void) { self.model = model; self.open = open }
    func run() async throws {
        guard !NSScreen.screens.isEmpty else { throw NativeSceneError.invalid("No logged-in graphical desktop") }
        let matrix = try JSONDecoder().decode(NativeSceneMatrix.self, from: Data(contentsOf: URL(fileURLWithPath: NativeSceneSession.argument("--native-matrix")!)))
        guard matrix.schemaVersion == 1 else { throw NativeSceneError.invalid("Unknown native matrix") }
        var start = [0, 0, 0]
        if CommandLine.arguments.contains("--native-resume") {
            guard let checkpoint = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("native-checkpoint.json"))) as? [String: Any],
                  checkpoint["runID"] as? String == NativeSceneSession.owner["runID"] as? String,
                  let cursor = checkpoint["cursor"] as? [Int], cursor.count == 3,
                  let previousFrames = checkpoint["frames"] as? [[String: Any]] else { throw NativeSceneError.invalid("Invalid native restart checkpoint") }
            start = cursor; frames = previousFrames
        }
        await NativeSceneSession.runtime.bootstrap(); await NativeSceneSession.runtime.waitForRound()
        if NativeSceneSession.allowFocus { NSApp.activate(ignoringOtherApps: true) }
        for (appearanceIndex, appearance) in matrix.appearances.enumerated() {
            if appearanceIndex < start[0] { continue }
            NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
            for (scenarioIndex, scenario) in matrix.scenarios.enumerated() {
                if appearanceIndex == start[0] && scenarioIndex < start[1] { continue }
                for (stepIndex, step) in scenario.steps.enumerated() {
                    if appearanceIndex == start[0] && scenarioIndex == start[1] && stepIndex < start[2] { continue }
                    var errors = [String]()
                    var actions = [String]()
                    if step.hasPrefix("memory-") {
                        if step == "memory-default" {
                            await NativeSceneSession.runtime.stop(); await NativeSceneSession.runtime.waitForRound()
                            if step == "memory-default" {
                                NativeSceneSession.preferences.removeObject(forKey: ImageMemoryLimit.preferenceKey)
                                NativeSceneSession.preferences.removeObject(forKey: ImageMemoryLimit.handledKey)
                            }
                            NativeSceneSession.runtime = try NativeSceneSession.makeRuntime()
                            model.nativeReviewReplaceRuntime(NativeSceneSession.runtime)
                            await NativeSceneSession.runtime.bootstrap(); await NativeSceneSession.runtime.waitForRound()
                            actions.append("new-runtime-same-isolated-preferences")
                        }
                        if step == "memory-reopen" {
                            guard CommandLine.arguments.contains("--native-resume"), start == [appearanceIndex, scenarioIndex, stepIndex] else {
                                throw NativeSceneError.invalid("Memory persistence must be verified in a new QA process")
                            }
                            actions.append("new-qa-process-same-isolated-preferences")
                        }
                        try setFixture(.completed)
                        model.state.imageMemoryLimit = await NativeSceneSession.runtime.current().imageMemoryLimit
                        if step != "memory-change" {
                            let expected: ImageMemoryLimit = step == "memory-default" ? .gib2 : .gib4
                            guard model.state.imageMemoryLimit == expected else { throw NativeSceneError.invalid("Memory preference did not persist") }
                        }
                    } else if step == "database-errors" || step.hasPrefix("reopen-") || step == "selection" || step == "scroll" {
                        try setFixture(step == "scroll" ? .many : .tasksWaiting)
                        if step != "scroll" {
                            // Match the reported combination: one waiting task,
                            // two enabled sources and both independent errors.
                            model.state.snapshot.indexProgress = nil
                            model.state.snapshot.livePhotoInventory = nil
                            let second = RegisteredSource(id: UUID(), url: output.appendingPathComponent("synthetic-source-2"), enabled: true)
                            model.state.sources.append(second)
                        }
                        errors = matrix.copy["database-errors"]!
                        model.state.snapshot.blockingSummary = errors[0]
                        model.state.snapshot.blockingError = "synthetic permanent storage failure"
                        model.state.snapshot.summaryError = "same synthetic storage failure"
                        // Real runtime errors can arrive on separate UI turns.
                        // Exercise the first row's layout before inserting the
                        // independent second message, rather than coalescing both.
                        try await settle()
                        model.state.message = errors[1]
                    } else if step == "database-wait" {
                        try setFixture(.completed); errors = matrix.copy[step]!
                        model.state.snapshot.summaryError = "synthetic busy"; model.state.snapshot.storageRetryPending = true
                    } else if step.hasPrefix("hover-") { try setFixture(.tasksMixed) }
                    else { try setFixture(step == "recovered" ? .completed : UIReviewScenario(rawValue: step)!) }

                    if let old = settings(), step.hasPrefix("reopen-") { old.close(); actions.append("close") }
                    open(); try await settle()
                    guard let window = settings(), let content = window.contentView else { throw NativeSceneError.invalid("Actual Settings scene window missing") }
                    window.appearance = NSApp.appearance
                    if NativeSceneSession.allowFocus {
                        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                        if !NSApp.isActive {
                            _ = try await requestInput("activate", windowID: window.windowNumber, point: .zero)
                        }
                        for _ in 0..<5 {
                            try await settle()
                            if NSApp.isActive, window.isKeyWindow { break }
                        }
                        guard NSApp.isActive else { throw NativeSceneError.invalid("Requested foreground activation did not occur") }
                    }
                    if NativeSceneSession.allowFocus, appearance == "light", scenario.id == "U01", step == "taskVisualUnknown" {
                        let point = NSPoint(x: 30, y: 45)
                        let overlay = NSWindow(contentRect: window.frame,
                            styleMask: .borderless, backing: .buffered, defer: false)
                        overlay.level = .floating; overlay.isReleasedWhenClosed = false; overlay.orderFront(nil)
                        defer { overlay.close() }
                        try await settle()
                        _ = try await physicalInput("click", window: window, point: point, expectedRejection: true, target: "add-source")
                        actions.append("occluded-window-input-refused")
                        overlay.close(); window.makeKeyAndOrderFront(nil); try await settle()
                    }
                    if step == "memory-change" {
                        let pickers = views(content).compactMap { $0 as? NSPopUpButton }
                        for picker in pickers { picker.menu?.update() }
                        if let picker = pickers.first(where: { $0.itemTitles.contains("4 GiB") }), let action = picker.action {
                            picker.selectItem(withTitle: "4 GiB"); NSApp.sendAction(action, to: picker.target, from: picker)
                            actions.append("native-picker-change")
                        } else {
                            try NativeSceneSession.write(views(content).map { view -> [String: Any] in
                                ["class":String(describing:type(of:view)), "title":(view as? NSButton)?.title ?? "", "label":view.accessibilityLabel() ?? "",
                                 "menuItems":(view as? NSPopUpButton)?.itemTitles ?? []]
                            }, "picker-diagnostic.json")
                            if NativeSceneSession.allowFocus {
                                try await chooseMemoryMenu(window: window)
                                actions.append("native-menu-picker-change")
                            } else {
                                guard NativeSceneSession.settingsOnly else { throw NativeSceneError.invalid("Actual memory picker not exposed") }
                                model.setImageMemoryLimit(.gib4); actions.append("model-setting-action-only")
                            }
                        }
                        try await settle(); await NativeSceneSession.runtime.waitForRound()
                        guard await NativeSceneSession.runtime.current().imageMemoryLimit == .gib4 else { throw NativeSceneError.invalid("Picker did not update isolated runtime") }
                    }
                    if step.hasPrefix("reopen-") {
                        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 720, height: window.frame.height + 40)), display: true)
                        try await settle(); actions += ["open-settings", "request-resize-observe-fixed-content-constraint"]
                    }
                    if step == "selection" {
                        if NativeSceneSession.settingsOnly && !NativeSceneSession.allowFocus {
                            actions.append("selection-not-exercised-background-scope")
                        } else {
                            try await selectText(window: window, text: errors[0])
                            actions.append("select-native-text-range"); errors = []
                        }
                    }
                    if step == "scroll", let scroll = views(content).compactMap({ $0 as? NSScrollView }).first(where: { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 1 }), let document = scroll.documentView {
                        document.scroll(NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                        scroll.reflectScrolledClipView(scroll.contentView); actions.append("scroll-own-document")
                        errors = []
                    }
                    try await settle()
                    let id = scenario.id + "/" + step
                    if step.hasPrefix("hover-") {
                        let task = String(step.dropFirst(6))
                        try await hover(window: window, task: task, id: id, appearance: appearance, expected: matrix.copy[step]!)
                    } else {
                        try capture(window, id: id, appearance: appearance, kind: "Settings", errors: errors,
                            expected: step == "scroll" ? ["图像处理内存峰值上限"] : matrix.copy[step] ?? [model.status.description], actions: actions)
                    }
                    if matrix.requiredMenuFrames.contains(id), !NativeSceneSession.settingsOnly {
                        guard NativeSceneSession.allowFocus else { throw NativeSceneError.invalid("Real menu activation requires explicit --allow-focus") }
                        window.orderOut(nil)
                        try await captureMenu(id: id, appearance: appearance)
                    }
                    if step == "memory-change" {
                        try NativeSceneSession.write(["runID":NativeSceneSession.owner["runID"]!, "cursor":[appearanceIndex, scenarioIndex, stepIndex + 1], "frames":frames], "native-checkpoint.json")
                        try NativeSceneSession.write(["status":"restart_required", "restartID":UUID().uuidString, "frames":frames], "native-captures.json")
                        // XCUITest terminates and launches this same isolated app;
                        // do not replace this with another in-process runtime.
                        return
                    }
                }
            }
        }
        await NativeSceneSession.runtime.stop(); await NativeSceneSession.runtime.waitForRound()
        NativeSceneSession.preferences.removePersistentDomain(forName: NativeSceneSession.preferenceName)
        try NativeSceneSession.write(["status":"captured", "scope":NativeSceneSession.settingsOnly ? "settings-only" : "native",
            "pid":ProcessInfo.processInfo.processIdentifier, "frames":frames], "native-captures.json")
    }
    private func setFixture(_ scenario: UIReviewScenario) throws {
        let fixture = try makeUIReviewModel(scenario: scenario, root: output.appendingPathComponent("fixtures"))
        model.state = fixture.state
    }
    private func settings() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.frame.width >= 590 && $0.title != "PhotosYNC Native Driver" } }
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(220))
        if NativeSceneSession.usesXCTest,
           let owner = (try? JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("native-owner.json")))) as? [String: Any],
           owner["active"] as? Bool != true { throw NativeSceneError.invalid("Native QA cancelled") }
        if !NativeSceneSession.allowFocus, NSApp.isActive { throw NativeSceneError.invalid("Background QA became active") }
    }
    private func nodes(_ object: Any) -> [any NSAccessibilityProtocol] {
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: Any) -> [any NSAccessibilityProtocol] {
            guard let element = object as? any NSAccessibilityProtocol, seen.insert(ObjectIdentifier(element)).inserted else { return [] }
            return [element] + ((element.accessibilityChildren() ?? []) + ((object as? NSView)?.subviews ?? [])).flatMap(visit)
        }
        return visit(object)
    }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func observedTextPoint(_ text: String, window: NSWindow, prefix: Bool = false) throws -> NSPoint {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { throw NativeSceneError.invalid("Cannot locate native text target") }
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let normalize: (String) -> String = { $0.filter { !$0.isWhitespace && !"，。,:：".contains($0) } }
        guard let line = request.results?.first(where: { observation in
            guard let value = observation.topCandidates(1).first?.string else { return false }
            return prefix ? normalize(value).hasPrefix(normalize(text)) : normalize(value) == normalize(text)
        }) else { throw NativeSceneError.invalid("Control text was not observed in current native window") }
        return NSPoint(x: line.boundingBox.midX * window.frame.width, y: line.boundingBox.midY * window.frame.height)
    }
    private func physicalInput(_ kind: String, window: NSWindow, point: NSPoint, count: Int = 1, screenCoordinates: Bool = false, expectedRejection: Bool = false, target: String? = nil) async throws -> CGPoint? {
        guard NativeSceneSession.allowFocus else { throw NativeSceneError.invalid("Physical input is outside background QA scope") }
        let screen = screenCoordinates ? point : window.convertPoint(toScreen: point)
        let quartz = CGPoint(x: screen.x, y: CGDisplayBounds(CGMainDisplayID()).height - screen.y)
        return try await requestInput(kind, windowID: window.windowNumber, point: quartz, count: count, expectedRejection: expectedRejection, target: target)
    }
    private func requestInput(_ kind: String, windowID: Int, point: CGPoint, count: Int = 1, expectedRejection: Bool = false, target: String? = nil) async throws -> CGPoint? {
        let id = UUID().uuidString
        var request: [String: Any] = ["id":id, "kind":kind, "pid":ProcessInfo.processInfo.processIdentifier,
            "windowID":windowID, "x":point.x, "y":point.y, "count":count]
        if let target { request["target"] = target }
        try NativeSceneSession.write(request, "native-input-request.json")
        for _ in 0..<(NativeSceneSession.usesXCTest ? 150 : 30) {
            try await Task.sleep(for: .milliseconds(100))
            if NativeSceneSession.usesXCTest,
               let owner = (try? JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("native-owner.json")))) as? [String: Any],
               owner["active"] as? Bool != true { throw NativeSceneError.invalid("Native QA cancelled") }
            guard let data = try? Data(contentsOf: output.appendingPathComponent("native-input-result.json")),
                  let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], result["id"] as? String == id else { continue }
            if expectedRejection {
                guard result["success"] as? Bool == false, (result["reason"] as? String)?.contains("occluded") == true else {
                    throw NativeSceneError.invalid("Occlusion negative control did not reject input")
                }
                return nil
            }
            guard result["success"] as? Bool == true else { throw NativeSceneError.invalid(result["reason"] as? String ?? "Physical input failed") }
            if let previous = result["previous"] as? [String: Double], let x = previous["x"], let y = previous["y"] { return CGPoint(x: x, y: y) }
            return nil
        }
        throw NativeSceneError.invalid("Native input controller did not acknowledge within its deadline")
    }
    private func chooseMemoryMenu(window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        let point = try observedTextPoint("2 GiB", window: window, prefix: true)
        var chosen = false
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            guard let menu = note.object as? NSMenu else { return }
            if let index = menu.items.firstIndex(where: { $0.title == "4 GiB" }) {
                menu.performActionForItem(at: index); menu.cancelTracking(); chosen = true
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = try await physicalInput("click", window: window, point: point, target: "image-memory-limit")
        for _ in 0..<10 { try await settle(); if chosen { return } }
        throw NativeSceneError.invalid("Actual memory menu did not deliver selection")
    }
    private func selectText(window: NSWindow, text: String) async throws {
        let direct = views(window.contentView!).compactMap { $0 as? NSTextView }.first { $0.isSelectable && $0.string.contains(text) }
        if let direct { direct.setSelectedRange(NSRange(location: 0, length: (text as NSString).length)); return }
        guard NativeSceneSession.allowFocus else { throw NativeSceneError.invalid("Text selection requires the approved foreground QA phase") }
        window.makeKeyAndOrderFront(nil)
        let point = try observedTextPoint(text, window: window)
        _ = try await physicalInput("click", window: window, point: point, count: 2, target: "primary-storage-error")
        try await settle()
        let client = window.firstResponder as? any NSTextInputClient
        let selectedRanges = [client?.selectedRange()].compactMap { $0 } + nodes(window.contentView!).map { $0.accessibilitySelectedTextRange() }
        guard selectedRanges.contains(where: { $0.location != NSNotFound && $0.length > 0 }) else {
            if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try png.write(to: output.appendingPathComponent("selection-diagnostic.png"))
            }
            try NativeSceneSession.write(["responder":String(describing:window.firstResponder), "ranges":selectedRanges.map { NSStringFromRange($0) }, "views":views(window.contentView!).map { String(describing:type(of:$0)) }], "selection-diagnostic.json")
            throw NativeSceneError.invalid("Actual selected text range not observable")
        }
    }
    private func hover(window: NSWindow, task: String, id: String, appearance: String, expected: [String]) async throws {
        let content = window.contentView!
        var target = nodes(content).first(where: { $0.accessibilityIdentifier() == "task-details-" + task })
        if target == nil {
            // SwiftUI may not export custom identifiers on its native buttons.
            // Inspect this window's real controls; require the exact task count
            // before selecting the corresponding row, never guess coordinates.
            let buttons = views(content).compactMap { $0 as? NSButton }.filter { $0.isEnabled && $0.bounds.width > 0 && $0.bounds.width < 30 && $0.bounds.height < 30 }
            let rows = model.progressRows
            if buttons.count == rows.count, let index = rows.firstIndex(where: { $0.id == task }) { target = buttons[index] }
        }
        guard let target else { throw NativeSceneError.invalid("Task help anchor missing") }
        let prior = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        let bounds = (target as? NSView).map { window.convertToScreen($0.convert($0.bounds, to: nil)) } ?? target.accessibilityFrame()
        window.acceptsMouseMovedEvents = true
        let point = window.convertPoint(fromScreen: NSPoint(x: bounds.midX, y: bounds.midY))
        if NativeSceneSession.allowFocus {
            _ = try await physicalInput("move", window: window, point: NSPoint(x: bounds.midX, y: bounds.midY), screenCoordinates: true, target: "task-details-" + task)
        } else if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0) { window.sendEvent(event) }
        // The first native presentation may take longer than the button's
        // 200 ms hover debounce. Observe the result with a bounded condition,
        // rather than substituting a press after one fixed 350 ms sample.
        let started = ContinuousClock.now
        var popup: NSWindow?
        var samples = [[String: Any]]()
        for _ in 0..<40 {
            if let candidate = NSApp.windows.first(where: { $0.isVisible && !prior.contains($0.windowNumber) }),
               let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(candidate.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
                samples.append(["elapsed":String(describing:started.duration(to: .now)), "windowID":candidate.windowNumber,
                    "frame":NSStringFromRect(candidate.frame), "pixelWidth":image.width, "pixelHeight":image.height])
                // WindowServer can expose a tiny animated presentation before
                // its final pixels reach the already laid-out NSWindow frame.
                // Wait for that same window to reach full compositor size.
                if candidate.frame.width > 200, candidate.frame.height > 40,
                   CGFloat(image.width) >= candidate.frame.width * candidate.backingScaleFactor - 4,
                   CGFloat(image.height) >= candidate.frame.height * candidate.backingScaleFactor - 4 {
                    popup = candidate; break
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let popup else {
            try NativeSceneSession.write(["step":id, "appearance":appearance, "priorWindowIDs":Array(prior),
                "windows":NSApp.windows.map { ["number":$0.windowNumber, "visible":$0.isVisible, "frame":NSStringFromRect($0.frame)] }], "hover-diagnostic.json")
            throw NativeSceneError.invalid("Hover did not open a native popover within two seconds")
        }
        try capture(popup, id: id, appearance: appearance, kind: "Popover", errors: [], expected: expected,
            actions: ["target-window-hover"])
        frames[frames.count - 1]["hoverOpened"] = true
        frames[frames.count - 1]["hoverObservationWait"] = String(describing: started.duration(to: .now))
        frames[frames.count - 1]["hoverWindowSamples"] = samples
        // Close only this process's presentation; no global Escape/shortcut.
        if NativeSceneSession.allowFocus {
            _ = try await physicalInput("move", window: window, point: NSPoint(x: 8, y: 40), target: "hover-exit")
            try await Task.sleep(for: .milliseconds(400))
            guard !popup.isVisible else { throw NativeSceneError.invalid("Hover popover did not dismiss on pointer exit") }
        } else { popup.close(); try await settle() }
    }
    private func captureMenu(id: String, appearance: String) async throws {
        let previouslyVisible = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        let buttons = NSApp.windows.flatMap { $0.contentView.map(views) ?? [] }.compactMap { $0 as? NSStatusBarButton }
        let targets = NSApp.accessibilityExtrasMenuBar().map { nodes($0).filter { $0.accessibilityRole() == .menuBarItem || $0.accessibilityRole() == .button } } ?? []
        if buttons.count == 1, let statusWindow = buttons[0].window {
            let bounds = buttons[0].convert(buttons[0].bounds, to: nil)
            _ = try await physicalInput("click", window: statusWindow, point: NSPoint(x: bounds.midX, y: bounds.midY))
        }
        else if targets.count == 1, targets[0].accessibilityPerformPress() { }
        else { throw NativeSceneError.invalid("Own native menu-bar button is not exposed") }
        try await Task.sleep(for: .milliseconds(700))
        let candidates = NSApp.windows.filter { $0.isVisible && !previouslyVisible.contains($0.windowNumber) && $0.frame.width >= 300 && $0.frame.width < 500 && $0.contentView != nil }
        guard candidates.count == 1, let menu = candidates.first else {
            try NativeSceneSession.write(["buttonCount":buttons.count, "axTargets":targets.count, "windows":NSApp.windows.map { ["title":$0.title,"frame":NSStringFromRect($0.frame),"visible":$0.isVisible,"level":$0.level.rawValue] }], "menu-diagnostic.json")
            throw NativeSceneError.invalid("Real MenuBarExtra window missing")
        }
        try capture(menu, id: id + "/menu", appearance: appearance, kind: "MenuBarExtra", errors: [], expected: [model.status.description], actions: ["own-extras-menu-bar-press"])
        if let statusWindow = buttons.first?.window, let button = buttons.first {
            let rect = button.convert(button.bounds, to: nil)
            _ = try await physicalInput("click", window: statusWindow, point: NSPoint(x: rect.midX, y: rect.midY))
        }
        try await settle()
        guard !menu.isVisible else { throw NativeSceneError.invalid("Native status-item toggle did not dismiss the menu") }
    }
    private func capture(_ window: NSWindow, id: String, appearance: String, kind: String, errors: [String], expected: [String], actions: [String]) throws {
        window.displayIfNeeded()
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw NativeSceneError.invalid("Own-window compositor capture unavailable") }
        let name = id.replacingOccurrences(of: "/", with: "-") + "-" + appearance + ".png"
        try png.write(to: output.appendingPathComponent(name))
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        guard !text.isEmpty else { throw NativeSceneError.invalid("Empty/black window capture") }
        let bars = nodes(window.contentView!).filter { $0.accessibilityIdentifier()?.hasPrefix("task-progress-") == true }
            .map { ["id":$0.accessibilityIdentifier()!, "width":$0.accessibilityFrame().width, "height":$0.accessibilityFrame().height] as [String: Any] }
        var frame: [String: Any] = ["scenarioID":String(id.prefix(3)), "step":id, "appearance":appearance, "windowKind":kind,
            "pid":ProcessInfo.processInfo.processIdentifier, "windowID":window.windowNumber, "width":window.frame.width, "height":window.frame.height, "backingScale":window.backingScaleFactor,
            "pixelWidth":image.width, "pixelHeight":image.height, "captureMode":"WindowServer-own-window", "file":name,
            "text":text, "expectedText":expected, "actions":actions, "taskBars":bars, "appActive":NSApp.isActive]
        frame["requestedFocus"] = NativeSceneSession.allowFocus
        if !errors.isEmpty {
            frame["orientationReferences"] = try errors.enumerated().map { index, line in
                let file = name.replacingOccurrences(of: ".png", with: "-text-\(index).png")
                try reference(line, at: output.appendingPathComponent(file), scale: window.backingScaleFactor)
                return file
            }
        }
        frames.append(frame)
        try NativeSceneSession.write(["status":"capturing", "frames":frames], "native-captures.json")
    }
    private func reference(_ text: String, at url: URL, scale: CGFloat) throws {
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let value = NSAttributedString(string: text, attributes: [.font:font, .foregroundColor:NSColor.red])
        let size = value.size(), image = NSImage(size: NSSize(width: size.width + 4, height: size.height + 4))
        image.lockFocus(); NSColor.white.setFill(); NSRect(origin: .zero, size: image.size).fill(); value.draw(at: NSPoint(x: 2, y: 2)); image.unlockFocus()
        guard let bytes = image.tiffRepresentation, let rep = NSBitmapImageRep(data: bytes), let png = rep.representation(using: .png, properties: [:]) else { throw NativeSceneError.invalid("Orientation reference generation failed") }
        try png.write(to: url)
    }
}

private actor NativeSceneModel: ImageFingerprinting {
    func fingerprint(image: CGImage, orientation: CGImagePropertyOrientation) async throws -> Fingerprint { throw NativeSceneError.invalid("UI fixture must not run image inference") }
}
private actor NativeScenePhotos: PhotosIndexGateway {
    let context = LibraryContext(id: UUID(), epoch: 0)
    nonisolated func changes() -> AsyncStream<PhotosIndexChange> { AsyncStream { $0.finish() } }
    func candidateSnapshot() async throws -> PhotosCandidateSnapshot { .init(generation: 0, candidates: []) }
    func representationCatalog(offset: Int, limit: Int, expectedGeneration: Int) async throws -> RepresentationPage { .init(context: context, generation: 0, descriptors: [], nextOffset: nil) }
    func readRepresentation(_ descriptor: RepresentationDescriptor) async throws -> LoadedRepresentation { throw NativeSceneError.invalid("No real Photos resources in UI QA") }
    func reconcile(placeholder: String?) async throws -> ImportEvidence { .unknown }
    func create(fileURL: URL, kind: MediaKind, expectedGeneration: Int, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String { throw NativeSceneError.invalid("UI QA refuses external mutations") }
}
