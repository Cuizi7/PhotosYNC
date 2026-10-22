import AppKit
import CoreGraphics
import SwiftUI
import PhotoSyncCore

/// Test-only executable. No production app entry point, runtime start, activation or global input.
@main
@MainActor
enum ReviewHost {
    static func main() {
        do { try run() }
        catch {
            fputs("UI review failed: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() throws {
        let args = CommandLine.arguments
        func argument(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let directory = argument("--output-dir") else { throw UIReviewError.invalid("Missing output directory") }
        let output = URL(fileURLWithPath: directory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotosYNC-UIReview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = NSApplication.shared
        app.setActivationPolicy(args.contains("--interactive") || args.contains("--probe") || args.contains("--controlled-capture") ? .accessory : .prohibited)
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("source.json"))) as? [String: Any] ?? [:]
        manifest["hostBundle"] = ["identifier": Bundle.main.bundleIdentifier ?? "missing",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "missing",
            "channel": Bundle.main.object(forInfoDictionaryKey: "PhotoSyncReleaseChannel") ?? "missing",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "missing"]
        manifest["limitations"] = ["Native compiled view bitmap; not a system MenuBarExtra popup or compositor capture.",
            "System integrations disabled by injected-model isolation; this is not a product enablement change.",
            "XCTest renders use XCTest Bundle.main metadata; this host uses the same build's app version metadata.",
            "No screen/accessibility permission requests, no global events, no foreground activation."]
        manifest["humanAcceptance"] = "候选证据，等待协调代理审阅；未声称用户本人验收"
        manifest["controlActiveStateOverride"] = "SwiftUI environment controlActiveState=.active; affects control appearance only; does not activate app/window or certify focus/hover"
        if args.contains("--controlled-capture") {
            try controlledCapture(output: output, root: root, manifest: manifest)
            return
        }
        if args.contains("--probe") {
            var observations: [[String: Any]] = []
            let scenarios = argument("--scenario").flatMap(UIReviewScenario.init(rawValue:)).map { [$0] }
                ?? [UIReviewScenario.syncing, .analyzing, .preparing, .icloud, .analysisPaused, .analysisZero, .mixedIssues, .longIssues]
            for scenario in scenarios {
                let appearances: [(String, NSAppearance.Name)] = argument("--appearance").map {
                    [($0, $0 == "dark" ? .darkAqua : .aqua)]
                } ?? [("light", .aqua), ("dark", .darkAqua)]
                for (look, appearance) in appearances {
                    // Each task gets a fresh model because probes mutate activity and counts.
                    for taskIndex in (scenario == .tasksMixed || scenario == .tasksKnown ? [0, 1] : [0]) {
                    let model = try makeUIReviewModel(scenario: scenario, root: root)
                    // This process is a test-only host. Native alert/popover chrome must use
                    // the selected fixture appearance too, without changing the user's OS.
                    app.appearance = NSAppearance(named: appearance)
                    let view = scenario != .many ? AnyView(StatusMenu(model: model)) : AnyView(SourceSettings(model: model))
                    let window = try interactiveWindow(view, width: scenario != .many ? 320 : 600, appearance: appearance)
                    window.title = "PhotosYNC 隔离原生交互探针 · \(scenario.rawValue) · \(look)"
                    window.orderFront(nil)
                    guard let host = window.contentView else { throw UIReviewError.invalid("Missing probe host") }
                    _ = waitUntil { window.isVisible }
                    let staticName = "probe-\(scenario.rawValue)-\(look).png"
                    _ = try UIReviewCapture.write(host, to: output.appendingPathComponent(staticName))
                    observations.append(try probeDetails(host: host, window: window, model: model, scenario: scenario,
                        appearance: look, output: output, taskIndex: taskIndex))
                    manifest["interactions"] = observations
                    try save(manifest, output: output, name: "probe-manifest.json")
                    window.contentView = nil
                    window.close()
                    }
                }
            }
            manifest["interactions"] = observations
            try save(manifest, output: output, name: "probe-manifest.json")
            print("Bounded own-window interaction probe complete; no activation requested")
            return
        }
        if args.contains("--interactive") {
            guard let raw = argument("--scenario"), let scenario = UIReviewScenario(rawValue: raw),
                  let look = argument("--appearance"), ["light", "dark"].contains(look) else {
                throw UIReviewError.invalid("Interactive requires valid --scenario and --appearance")
            }
            let model = try makeUIReviewModel(scenario: scenario, root: root)
            let appearance: NSAppearance.Name = look == "dark" ? .darkAqua : .aqua
            app.appearance = NSAppearance(named: appearance)
            let surface = argument("--surface")
            guard surface == nil || surface == "menu" || surface == "settings" else {
                throw UIReviewError.invalid("Interactive --surface must be menu or settings")
            }
            let captureUserOpen = args.contains("--capture-user-open")
            let timeout = argument("--capture-timeout").flatMap(TimeInterval.init) ?? 180
            guard timeout > 0, timeout <= 180 else {
                throw UIReviewError.invalid("Capture timeout must be within 0–180 seconds")
            }
            var windows: [NSWindow] = []
            for surface in surface.map({ [$0] }) ?? ["menu", "settings"] {
                let view = surface == "menu" ? AnyView(StatusMenu(model: model)) : AnyView(SourceSettings(model: model))
                let window = try interactiveWindow(view, width: surface == "menu" ? 320 : 600, appearance: appearance)
                window.title = "PhotosYNC 测试审阅 · \(scenario.rawValue) · \(surface) · \(look)"
                window.orderFront(nil) // Does not activate or request system keyboard focus.
                windows.append(window)
            }
            manifest["interactive"] = ["scenario": raw, "appearance": look, "surface": surface ?? "both",
                "pid": ProcessInfo.processInfo.processIdentifier,
                "windowIDs": windows.map(\.windowNumber), "activationRequested": false,
                "captureOnUserOpen": captureUserOpen, "captureTimeoutSeconds": timeout,
                "status": "User-controlled fixture session; interactions not automatically certified"]
            try save(manifest, output: output, name: "interactive-manifest.json")
            var observer: Timer?
            if captureUserOpen {
                let initialIDs = Set(NSApp.windows.map(\.windowNumber))
                let deadline = Date().addingTimeInterval(timeout)
                let timer = Timer(timeInterval: 0.25, repeats: true) { timer in
                    Task { @MainActor in
                        // Observe only the user's activation and actual new native presentation.
                        // No event injection, window activation or key-window forcing occurs here.
                        let transient = NSApp.windows.first {
                            $0.isVisible && !initialIDs.contains($0.windowNumber) &&
                            $0.contentView != nil && $0.frame.width >= 100 && $0.frame.height >= 100
                        }
                        guard (NSApp.isActive && transient != nil) || Date() >= deadline else { return }
                        timer.invalidate()
                        do {
                            var observation: [String: Any] = ["applicationActive": NSApp.isActive,
                                "hostWindowIDs": windows.map(\.windowNumber),
                                "hostKeyWindows": windows.map(\.isKeyWindow),
                                "ownVisibleWindowIDs": NSApp.windows.filter(\.isVisible).map(\.windowNumber),
                                "pid": ProcessInfo.processInfo.processIdentifier, "inputInjected": false,
                                "activationRequested": false]
                            if NSApp.isActive, let transient {
                                observation["transientWindowID"] = transient.windowNumber
                                observation["transientKeyWindow"] = transient.isKeyWindow
                                let acquisition = try compositorCapture(window: transient, output: output,
                                    name: "user-open-\(raw)-\(look)-\(transient.windowNumber).png")
                                observation.merge(userOpenCaptureResult(acquisition), uniquingKeysWith: { _, new in new })
                            } else {
                                observation["status"] = "unverified"
                                observation["failure"] = "No active, user-opened own-host presentation before bounded timeout"
                            }
                            manifest["userOpenCapture"] = observation
                            try save(manifest, output: output, name: "interactive-manifest.json")
                        } catch {
                            manifest["userOpenCapture"] = ["status": "unverified", "failure": String(describing: error)]
                            try? save(manifest, output: output, name: "interactive-manifest.json")
                        }
                        try? FileManager.default.removeItem(at: root)
                        app.terminate(nil)
                    }
                }
                observer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            withExtendedLifetime((model, windows)) { app.run() }
            observer?.invalidate()
            for window in windows { window.contentView = nil; window.close() }
            return
        }
        var captures: [[String: Any]] = []
        var probes: [[String: Any]] = []
        for scenario in UIReviewScenario.allCases {
            let model = try makeUIReviewModel(scenario: scenario, root: root)
            guard !model.allowsSystemIntegrations else { throw UIReviewError.invalid("Unsafe model") }
            for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for surface in ["menu", "settings"] {
                    let view = surface == "menu" ? AnyView(StatusMenu(model: model)) : AnyView(SourceSettings(model: model))
                    _ = try UIReviewCapture.render(view, width: surface == "menu" ? 320 : 600, appearance: appearance) { host, window in
                        let filename = "\(scenario.rawValue)-\(look)-\(surface).png"
                        var item = try UIReviewCapture.write(host, to: output.appendingPathComponent(filename))
                        item.merge(["scenario": scenario.rawValue, "appearance": look, "surface": surface,
                            "file": filename, "windowID": window.windowNumber, "input": inputs(model)], uniquingKeysWith: { _, new in new })
                        captures.append(item)
                        if (scenario == .syncing && surface == "menu") || (scenario == .many && surface == "settings") {
                            probes.append(try probe(host: host, window: window, model: model, scenario: scenario,
                                appearance: look, output: output))
                        }
                        if scenario == .many, surface == "settings" {
                            try UIReviewCapture.scrollToBottom(host)
                            let name = "many-\(look)-settings-bottom.png"
                            var bottom = try UIReviewCapture.write(host, to: output.appendingPathComponent(name))
                            bottom.merge(["scenario": "many", "appearance": look, "surface": "settings-bottom",
                                "file": name, "windowID": window.windowNumber, "input": inputs(model)], uniquingKeysWith: { _, new in new })
                            captures.append(bottom)
                        }
                    }
                }
                if scenario.rawValue.hasPrefix("task") {
                    for row in SyncStatusPresentation(snapshot: model.state.snapshot).progressRows {
                        _ = try UIReviewCapture.render(TaskDetailsContent(row: row), width: 334, appearance: appearance) { host, window in
                            for position in ["top", "bottom"] {
                                if position == "bottom" { try UIReviewCapture.scrollToBottom(host, allowNoOverflow: true) }
                                let surface = "task-details-\(row.id)-\(position)"
                                let filename = "\(scenario.rawValue)-\(look)-\(surface).png"
                                var item = try UIReviewCapture.write(host, to: output.appendingPathComponent(filename))
                                item.merge(["scenario": scenario.rawValue, "appearance": look, "surface": surface,
                                    "file": filename, "windowID": window.windowNumber, "input": inputs(model),
                                    "limitation": "Standalone task details content; not an opened popover/material capture"], uniquingKeysWith: { _, b in b })
                                captures.append(item)
                            }
                        }
                    }
                }
                if [.mixedIssues, .longIssues, .analyzing, .preparing, .icloud, .analysisPaused, .analysisZero].contains(scenario) {
                    let sourceDetails = scenario == .mixedIssues || scenario == .longIssues
                    let details = sourceDetails
                        ? AnyView(SourceIssuesContent(sourceURL: model.state.sources[0].url,
                            issues: model.state.snapshot.sourceIssueDetails[model.state.sources[0].id] ?? [], recoveryPending: false))
                        : AnyView(SyncDetailsContent(snapshot: model.state.snapshot))
                    let width: CGFloat = sourceDetails ? 360 : 300
                    let kind = sourceDetails ? "source-details" : "sync-details"
                    _ = try UIReviewCapture.render(details, width: width, appearance: appearance) { host, window in
                        for position in ["top", "bottom"] {
                            if position == "bottom" { try UIReviewCapture.scrollToBottom(host) }
                            let filename = "\(scenario.rawValue)-\(look)-\(kind)-\(position).png"
                            var item = try UIReviewCapture.write(host, to: output.appendingPathComponent(filename))
                            item.merge(["scenario": scenario.rawValue, "appearance": look, "surface": "\(kind)-\(position)",
                                "file": filename, "windowID": window.windowNumber, "input": inputs(model),
                                "limitation": "Standalone native content on test window background; not an opened popover/material capture"], uniquingKeysWith: { _, b in b })
                            captures.append(item)
                        }
                    }
                }
            }
        }
        let expected = UIReviewScenario.allCases.count * 4 + 2 + 7 * 4 + 17 * 4
        guard captures.count == expected else { throw UIReviewError.invalid("Incomplete matrix: \(captures.count)/\(expected)") }
        manifest["captures"] = captures
        manifest["interactions"] = probes
        try save(manifest, output: output, name: "manifest.json")
        print("Captured \(captures.count) validated native images; interaction outcomes in manifest.json")
    }

    static func inputs(_ model: AppModel) -> [String: Any] {
        let s = model.state.snapshot.summary
        return ["sourceCount": model.state.sources.count, "enabledSources": model.state.sources.filter(\.enabled).count,
            "paths": model.state.sources.map { $0.url.path }, "authorized": model.state.authorized,
            "allowsSystemIntegrations": model.allowsSystemIntegrations,
            "imported": s.map { $0.imported as Any } ?? NSNull(), "skipped": s.map { $0.skipped as Any } ?? NSNull(),
            "pending": s.map { $0.pending as Any } ?? NSNull(), "importing": s.map { $0.importing as Any } ?? NSNull(),
            "retryPending": s.map { $0.retryPending as Any } ?? NSNull(),
            "checkedCandidates": model.state.snapshot.latestScan.checkedCandidates,
            "newlyImported": model.state.snapshot.latestScan.newlyImported,
            "analysisState": model.state.snapshot.indexProgress.map { String(describing: $0.state) as Any } ?? NSNull(),
            "analysisReadyAssets": model.state.snapshot.indexProgress.map { $0.readyAssets as Any } ?? NSNull(),
            "analysisTotalAssets": model.state.snapshot.indexProgress.map { $0.totalAssets as Any } ?? NSNull(),
            "status": model.statusDescription, "fixtureDate": "2026-10-13"]
    }

    static func interactiveWindow(_ view: AnyView, width: CGFloat, appearance: NSAppearance.Name) throws -> NSWindow {
        let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
            .environment(\.controlActiveState, .active)
            .background(Color(nsColor: .windowBackgroundColor))))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        _ = try UIReviewCapture.converge(host: host, window: window, width: width)
        return window
    }

    static func accessibility(in object: Any, visited: inout Set<ObjectIdentifier>) -> [any NSAccessibilityProtocol] {
        guard let element = object as? any NSAccessibilityProtocol else { return [] }
        let id = ObjectIdentifier(element)
        guard visited.insert(id).inserted else { return [] }
        let children = (element.accessibilityChildren() ?? []) + ((object as? NSView)?.subviews ?? [])
        return [element] + children.flatMap { accessibility(in: $0, visited: &visited) }
    }

    static func waitUntil(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        repeat {
            if predicate() { return true }
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.02)))
        } while Date() < deadline
        return predicate()
    }

    /// Only documented, process-local AX and NSWindow routing. No real pointer or global keys.
    static func probe(host: NSView, window: NSWindow, model: AppModel, scenario: UIReviewScenario,
        appearance: String, output: URL) throws -> [String: Any] {
        var visited: Set<ObjectIdentifier> = []
        let elements = accessibility(in: host, visited: &visited)
        let identifier = scenario != .many ? "sync-details" : "remove-source-\(model.state.sources.first!.id.uuidString)"
        let target = elements.first { $0.accessibilityIdentifier() == identifier }
        let before = Set(NSApp.windows.map(\.windowNumber))
        var result: [String: Any] = ["scenario": scenario.rawValue, "appearance": appearance,
            "hostWindowID": window.windowNumber, "hostVisible": window.isVisible,
            "hostKeyWindow": window.isKeyWindow, "targetIdentifier": identifier,
            "applicationActiveBeforeInput": NSApp.isActive,
            "nativeAppAppearance": NSApp.effectiveAppearance.name.rawValue,
            "nativeWindowAppearance": window.effectiveAppearance.name.rawValue,
            "accessibilityNodeCount": elements.count, "targetFound": target != nil,
            "helpText": elements.compactMap { $0.accessibilityHelp() }.filter { !$0.isEmpty }]
        if !window.isVisible {
            result["status"] = "unverified"
            result["failure"] = "Default offscreen capture never dispatches input or opens windows; use bounded --probe or user-controlled --interactive host"
            result["missing"] = ["actual popover/tooltip/dialog", "hover/pin/keyboard dismissal", "visible focus restoration"]
            return result
        }
        let point: NSPoint
        var hitView: NSView?
        if let target {
            let frame = target.accessibilityFrame()
            point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            hitView = target as? NSView
        } else {
            result["status"] = "unverified"
            result["failure"] = "Native AX target not exposed; stale hardcoded coordinate fallback removed"
            return result
        }
        window.acceptsMouseMovedEvents = true
        func mouse(_ type: NSEvent.EventType, at location: NSPoint? = nil) {
            if let event = NSEvent.mouseEvent(with: type, location: location ?? point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 0) { window.sendEvent(event) }
        }
        func key(_ chars: String, code: UInt16, destination: NSWindow? = nil) {
            let destination = destination ?? window
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: destination.windowNumber,
                context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                destination.sendEvent(event)
            }
        }
        func presentations() -> [NSWindow] {
            NSApp.windows.filter { $0.isVisible && !before.contains($0.windowNumber) }
        }
        if scenario == .many {
            let path = model.state.sources.first!.url.path
            let pathElement = elements.first { $0.accessibilityLabel() == path }
            result["fullPathAccessibilityLabelFound"] = pathElement != nil
            result["fullPathHelp"] = pathElement?.accessibilityHelp() ?? "not exposed"
            if let pathElement {
                let f = pathElement.accessibilityFrame()
                mouse(.mouseMoved, at: window.convertPoint(fromScreen: NSPoint(x: f.midX, y: f.midY)))
                result["nativeTooltipObserved"] = waitUntil { !presentations().isEmpty }
            } else {
                let y: CGFloat = 159
                let pathPoint = host.convert(NSPoint(x: 250, y: host.isFlipped ? y : host.bounds.height - y), to: nil)
                mouse(.mouseMoved, at: pathPoint)
                result["nativeTooltipObserved"] = waitUntil { !presentations().isEmpty }
                result["tooltipProbeMethod"] = "Process-local movement over capture-verified first source label; no forced tooltip callbacks"
            }
        }
        mouse(.mouseMoved)
        result["hoverOpenedNativeWindow"] = waitUntil { !presentations().isEmpty }
        mouse(.leftMouseDown); mouse(.leftMouseUp)
        result["clickOpenedNativeWindow"] = waitUntil { !presentations().isEmpty }
        if presentations().isEmpty {
            result["accessibilityPressAccepted"] = target?.accessibilityPerformPress() ?? false
            result["pressOpenedNativeWindow"] = waitUntil { !presentations().isEmpty }
        }
        if let hitView { result["makeFirstResponderAccepted"] = window.makeFirstResponder(hitView) }
        result["firstResponderBeforeKeys"] = String(describing: window.firstResponder)
        if scenario == .syncing {
            key(" ", code: 49)
            result["nativeWindowPresentAfterSpace"] = waitUntil { !presentations().isEmpty }
            key("\r", code: 36)
            result["nativeWindowPresentAfterReturn"] = waitUntil { !presentations().isEmpty }
        }
        var presented: [[String: Any]] = []
        for transient in presentations() {
            guard let content = transient.contentView else { continue }
            let name = "transient-\(scenario.rawValue)-\(appearance)-\(transient.windowNumber).png"
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            var capture: [String: Any]
            do {
                capture = try UIReviewCapture.write(content, to: output.appendingPathComponent(name))
                capture["captureAccepted"] = true
            }
            catch { capture = ["captureError": String(describing: error), "captureAccepted": false] }
            capture.merge(["file": name, "windowID": transient.windowNumber, "visible": transient.isVisible,
                "keyWindow": transient.isKeyWindow], uniquingKeysWith: { _, new in new })
            var seen: Set<ObjectIdentifier> = []
            let nodes = accessibility(in: content, visited: &seen)
            capture["accessibleLabels"] = nodes.compactMap { $0.accessibilityLabel() }
            capture["compositor"] = try compositorCapture(window: transient, output: output,
                name: "compositor-\(scenario.rawValue)-\(appearance)-\(transient.windowNumber).png")
            if scenario != .many {
                capture["parentCompositor"] = try compositorCapture(window: window, output: output,
                    name: "parent-compositor-\(scenario.rawValue)-\(appearance)-\(window.windowNumber).png")
            }
            presented.append(capture)
            if scenario == .many {
                result["cancelAccessibilityPressAccepted"] = nodes.first { $0.accessibilityLabel() == "取消" }?.accessibilityPerformPress() ?? false
                key("\u{1b}", code: 53, destination: transient)
            }
        }
        result["presentations"] = presented
        key("\u{1b}", code: 53)
        result["escapeDismissed"] = waitUntil { presentations().isEmpty }
        if !presentations().isEmpty {
            for transient in presentations() { key("\u{1b}", code: 53, destination: transient) }
            result["transientScopedEscapeDismissed"] = waitUntil { presentations().isEmpty }
        }
        result["firstResponderAfterEscape"] = String(describing: window.firstResponder)
        result["hostKeyWindowAfterInput"] = window.isKeyWindow
        result["applicationActiveAfterInput"] = NSApp.isActive
        result["cleanupWindowIDs"] = presentations().map(\.windowNumber)
        for transient in presentations() { transient.orderOut(nil); transient.close() }
        result["status"] = "unverified"
        result["failure"] = presented.isEmpty
            ? "Local AX/mouse/keyboard dispatch produced no observable native presentation in non-key host"
            : "Actual presentation captured; non-key host cannot certify physical hover, outside click or visible focus ring"
        result["missing"] = ["physical hover/tooltip", "independent Space/Return pin verification", "outside click dismissal", "system keyboard focus/ring", "focus restoration acceptance", "compositor/frame/material appearance"]
        return result
    }

    /// Opens the real production popover by a native button in this test host's view tree.
    /// No activation, global pointer, key event, permissions or production runtime are used.
    static func probeDetails(host: NSView, window: NSWindow, model: AppModel, scenario: UIReviewScenario,
        appearance: String, output: URL, taskIndex: Int = 0) throws -> [String: Any] {
        func buttons(_ view: NSView) -> [NSButton] {
            ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons)
        }
        let candidates = buttons(host).filter { $0.isEnabled && $0.bounds.width > 0 && $0.bounds.height > 0 }
        let isSource = scenario == .mixedIssues || scenario == .longIssues
        // Menu content has one native info button followed by the single synthetic source's
        // summary button. Locate real controls, then use their actual native frames.
        let taskRows = SyncStatusPresentation(snapshot: model.state.snapshot).progressRows
        let taskRow = !isSource && taskRows.indices.contains(taskIndex) ? taskRows[taskIndex] : nil
        let candidateIndex = isSource ? 1 : taskIndex
        let captureName = scenario.rawValue + (taskRow.map { "-" + $0.id } ?? "")
        var result: [String: Any] = ["scenario": scenario.rawValue, "appearance": appearance,
            "pid": ProcessInfo.processInfo.processIdentifier, "hostWindowID": window.windowNumber,
            "applicationActive": NSApp.isActive, "hostKeyWindow": window.isKeyWindow,
            "activationRequested": false, "globalInputInjected": false,
            "buttonDiscovery": "NSView tree native NSButton order in synthetic menu; task order verified by rendered XCTest; no hardcoded coordinate",
            "targetTaskID": taskRow?.id ?? "sourceOrSync",
            "nativeButtons": candidates.map { ["title": $0.title, "frame": String(describing: host.convert($0.bounds, from: $0))] },
            "input": inputs(model)]
        guard candidates.indices.contains(candidateIndex) else {
            result["status"] = "unverified"; result["failure"] = "Expected native details button absent"; return result
        }
        let trigger = candidates[candidateIndex]
        let before = Set(NSApp.windows.map(\.windowNumber))
        func presentations() -> [NSWindow] { NSApp.windows.filter { $0.isVisible && !before.contains($0.windowNumber) } }
        window.acceptsMouseMovedEvents = true
        let center = trigger.convert(NSPoint(x: trigger.bounds.midX, y: trigger.bounds.midY), to: nil)
        if let movement = NSEvent.mouseEvent(with: .mouseMoved, location: center, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 0, pressure: 0) { window.sendEvent(movement) }
        result["processLocalHoverOpened"] = waitUntil { !presentations().isEmpty }
        trigger.performClick(nil) // Pin the same popup, or verify click separately if hover was unavailable.
        result["nativeClickOpened"] = waitUntil { !presentations().isEmpty }
        guard let popup = presentations().first, let content = popup.contentView else {
            result["status"] = "unverified"; result["failure"] = "Native performClick produced no popup in non-key host"; return result
        }
        defer { for popup in presentations() { popup.orderOut(nil); popup.close() } }
        var captures: [[String: Any]] = []
        var compositorAvailable = true
        let popupID = CGWindowID(popup.windowNumber)
        let paintStart = Date()
        let paintDeadline = paintStart.addingTimeInterval(3)
        var paintFrames: [[String: Any]] = []
        var stablePaintFrames = 0
        var lastBounds = ""
        repeat {
            let records = CGWindowListCopyWindowInfo([.optionIncludingWindow], popupID) as? [[String: Any]] ?? []
            let own = records.first {
                ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == popupID &&
                    ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier
            }
            let bounds = own?[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
            let onScreen = (own?[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
            let matches = onScreen && abs(width - popup.frame.width) <= 2 && abs(height - popup.frame.height) <= 2
            stablePaintFrames = matches ? stablePaintFrames + 1 : 0
            let signature = "\(width)x\(height)/\(popup.frame.size)/\(onScreen)"
            if signature != lastBounds || stablePaintFrames == 3 {
                paintFrames.append(["elapsedMilliseconds": Int(Date().timeIntervalSince(paintStart) * 1000),
                    "cgBounds": bounds, "nativeFrame": String(describing: popup.frame),
                    "onScreen": onScreen, "matchesNativeSize": matches, "stableFrames": stablePaintFrames])
                lastBounds = signature
            }
            if stablePaintFrames >= 3 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < paintDeadline
        let paintObserved = stablePaintFrames >= 3
        result["paintObservation"] = paintFrames
        result["paintTimeoutSeconds"] = 3
        compositorAvailable = paintObserved
        result["popupOnScreenObserved"] = paintObserved
        result["popupWindowID"] = popup.windowNumber
        result["popupFrame"] = String(describing: popup.frame)
        result["screenVisibleFrames"] = NSScreen.screens.map { String(describing: $0.visibleFrame) }
        let ownRecords = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        result["ownWindowServerRecords"] = ownRecords.filter {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier
        }.map { record in
            ["windowID": record[kCGWindowNumber as String] ?? NSNull(),
             "bounds": record[kCGWindowBounds as String] ?? NSNull(),
             "onScreen": record[kCGWindowIsOnscreen as String] ?? NSNull(),
             "layer": record[kCGWindowLayer as String] ?? NSNull()]
        }
        func capture(_ phase: String) throws {
            content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
            let filename = "popover-\(captureName)-\(appearance)-\(phase).png"
            var entry: [String: Any] = ["phase": phase, "file": filename, "windowID": popup.windowNumber,
                "visible": popup.isVisible, "keyWindow": popup.isKeyWindow, "input": inputs(model)]
            do {
                entry.merge(try UIReviewCapture.write(content, to: output.appendingPathComponent(filename)), uniquingKeysWith: { _, b in b })
                entry["captureAccepted"] = true
            } catch { entry["captureAccepted"] = false; entry["captureError"] = String(describing: error) }
            if entry["captureAccepted"] as? Bool != true,
               let raw = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: raw)
                let rawName = "raw-\(filename)"
                try raw.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(rawName))
                entry["rawUnvalidatedFile"] = rawName
            }
            if compositorAvailable {
                let acquisition = try compositorCapture(window: popup, output: output,
                    name: "compositor-\(captureName)-\(appearance)-\(phase).png")
                entry["compositor"] = acquisition
                compositorAvailable = acquisition["status"] as? String == "captured"
            } else {
                entry["compositor"] = ["status": "unverified", "failure": paintObserved
                    ? "Not retried after the same own-window acquisition failure"
                    : "Own popup CG bounds did not converge to its native frame; acquisition not attempted"]
            }
            captures.append(entry)
        }
        _ = waitUntil { content.bounds.width >= (isSource ? 360 : 300) && content.bounds.height > 100 }
        try capture("opened")
        if scenario == .longIssues {
            try UIReviewCapture.scrollToBottom(content)
            try capture("bottom")
        }
        if let taskRow {
            var stages: [[String: Any]] = []
            for (stage, activity) in [("queued", IndexActivity.queued), ("waiting", .waiting), ("paused", .waiting)] {
                if model.state.snapshot.indexProgress != nil {
                    model.state.snapshot.indexProgress = .init(state: .updating, totalsKnown: true,
                        totalAssets: 16000, readyAssets: 15717, totalRepresentations: 16000,
                        readyRepresentations: 15717, excludedAssets: 0, issue: nil)
                    model.state.snapshot.indexActivity = activity
                }
                model.state.snapshot.livePhotoInventory?.identified = 46
                if model.state.snapshot.livePhotoInventory != nil {
                    model.state.snapshot.livePhotoActivities = stage == "queued" ? [.queued(.identification)] : [.waiting(nextRetryAt: nil)]
                }
                model.state.snapshot.isPaused = stage == "paused"
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                let rows = SyncStatusPresentation(snapshot: model.state.snapshot).progressRows
                let sameTrigger = buttons(host).dropFirst(candidateIndex).first === trigger
                stages.append(["stage": stage, "taskIDs": rows.map(\.id),
                    "captions": rows.map { $0.subtitle + " · " + ($0.countText ?? "") },
                    "sameTrigger": sameTrigger, "samePopupVisible": popup.isVisible])
                guard sameTrigger, popup.isVisible, rows.contains(where: { $0.id == taskRow.id }) else {
                    throw UIReviewError.invalid("Task hover lost its native anchor in \(stage)")
                }
                try capture(stage)
            }
            result["taskTransitions"] = stages
        }
        result["presentations"] = captures
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popup.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
            popup.sendEvent(event)
        }
        result["escapeDismissed"] = waitUntil { presentations().isEmpty }
        result["status"] = compositorAvailable ? "native-capture-awaiting-coordinator-inspection" : "unverified-native-material"
        if !compositorAvailable { result["failure"] = "Real popup observed; native material acquisition failed. Bitmap/text evidence does not certify popover appearance." }
        result["limitations"] = ["Programmatic native click is not physical hover/Space/Return/outside click acceptance",
            "Non-key test host cannot certify visible focus ring or physical focus restoration",
            "See each compositor acquisition; cacheDisplay alone does not certify native material appearance",
            "No real MenuBarExtra popup, Photos, sources or production database"]
        return result
    }

    /// Explicitly opt-in, one activation, one bounded synthetic QA session.
    static func controlledCapture(output: URL, root: URL, manifest initial: [String: Any]) throws {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let original = NSWorkspace.shared.frontmostApplication, original.processIdentifier != ownPID else {
            throw UIReviewError.invalid("Need a distinct original frontmost app before the one allowed QA activation")
        }
        let originalPID = original.processIdentifier
        let started = Date()
        let deadline = started.addingTimeInterval(30)
        var manifest = initial
        var observations: [[String: Any]] = []
        var captures: [[String: Any]] = []
        var windows: [NSWindow] = []
        var activated = false
        var userSwitched = false
        var failure: String?
        var restore: [String: Any] = ["attempted": false]
        manifest["limitations"] = ["Explicit authorization for one synthetic QA foreground activation, maximum 30 seconds.",
            "Only own PID/windowID compositor captures; stop immediately after observing a user switch.",
            "No global keys/mouse, permission requests, system settings changes, production runtime or Photos access.",
            "Acquisition is not user acceptance; every original screenshot and frontmost guard is recorded."]
        manifest["controlActiveStateOverride"] = "Synthetic SwiftUI appearance override; separate single QA activation is explicitly recorded below."
        manifest["controlledSession"] = ["originalFrontmost": ["pid": originalPID, "bundleID": original.bundleIdentifier ?? "unknown"],
            "qaPID": ownPID, "qaActivationCalls": 0, "maximumSeconds": 30,
            "status": "prepared-before-activation", "startedAt": started.ISO8601Format()]
        try save(manifest, output: output, name: "controlled-manifest.json")
        func frontmost() -> [String: Any] {
            let app = NSWorkspace.shared.frontmostApplication
            return ["pid": app.map { $0.processIdentifier as Any } ?? NSNull(), "bundleID": app?.bundleIdentifier ?? "unknown"]
        }
        func mayContinue() -> Bool {
            guard Date() < deadline else { return false }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID else {
                userSwitched = true
                return false
            }
            return true
        }
        func closeOwnWindows() {
            for window in NSApp.windows where window.isVisible { window.orderOut(nil); window.close() }
            windows.removeAll()
        }
        func capture(_ popup: NSWindow, scenario: UIReviewScenario, look: String, phase: String) throws {
            guard mayContinue(), deadline.timeIntervalSinceNow > 6 else { throw UIReviewError.invalid("QA foreground/session deadline ended before capture") }
            let popupID = CGWindowID(popup.windowNumber)
            let paintDeadline = min(deadline, Date().addingTimeInterval(3))
            var frames: [[String: Any]] = []
            var stable = 0
            repeat {
                guard mayContinue() else { break }
                let records = CGWindowListCopyWindowInfo([.optionIncludingWindow], popupID) as? [[String: Any]] ?? []
                let own = records.first { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownPID && ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == popupID }
                let bounds = own?[kCGWindowBounds as String] as? [String: Any] ?? [:]
                let w = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
                let h = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
                let matches = abs(w - popup.frame.width) <= 2 && abs(h - popup.frame.height) <= 2 && w > 100 && h > 100
                stable = matches ? stable + 1 : 0
                frames.append(["elapsedMilliseconds": Int(Date().timeIntervalSince(started) * 1000), "cgBounds": bounds,
                    "nativeFrame": String(describing: popup.frame), "stableFrames": stable, "frontmost": frontmost()])
                if stable >= 3 { break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            } while Date() < paintDeadline
            guard mayContinue(), stable >= 3, deadline.timeIntervalSinceNow > 6 else {
                observations.append(["scenario": scenario.rawValue, "appearance": look, "phase": phase, "paintFrames": frames])
                throw UIReviewError.invalid("Native/CG popup dimensions or session guard did not converge; no activation retry")
            }
            let entryFront = frontmost()
            let acquisition = try compositorCapture(window: popup, output: output,
                name: "controlled-\(scenario.rawValue)-\(look)-\(phase).png", captureAllowed: mayContinue)
            captures.append(["scenario": scenario.rawValue, "appearance": look, "phase": phase,
                "pid": ownPID, "windowID": popup.windowNumber, "nativeFrame": String(describing: popup.frame),
                "frontmostBefore": entryFront, "frontmostAfter": frontmost(), "paintFrames": frames, "acquisition": acquisition])
            guard mayContinue(), acquisition["status"] as? String == "captured" else {
                throw UIReviewError.invalid("One controlled native acquisition did not succeed; no reactivation/retry")
            }
        }
        do {
            for scenario in [UIReviewScenario.mixedIssues, .longIssues, .analyzing] {
                for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    if activated, !mayContinue() { throw UIReviewError.invalid("User switched away or bounded session expired") }
                    guard deadline.timeIntervalSinceNow > 6 else { throw UIReviewError.invalid("Bounded session time budget reached") }
                    let model = try makeUIReviewModel(scenario: scenario, root: root)
                    NSApp.appearance = NSAppearance(named: appearance)
                    let window = try interactiveWindow(AnyView(StatusMenu(model: model)), width: 320, appearance: appearance)
                    windows.append(window)
                    if !activated {
                        // Persist the original foreground immediately before the sole QA activation.
                        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == originalPID else {
                            userSwitched = true
                            throw UIReviewError.invalid("Original foreground changed before QA activation; session stopped")
                        }
                        manifest["frontmostBeforeActivation"] = frontmost()
                        try save(manifest, output: output, name: "controlled-manifest.json")
                        guard deadline.timeIntervalSinceNow > 6 else { throw UIReviewError.invalid("Session budget expired before the sole QA activation") }
                        // The sole QA activation. There is no reactivation path.
                        window.orderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                        activated = true
                        guard waitUntil({
                            let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                            if let currentPID, currentPID != originalPID, currentPID != ownPID {
                                userSwitched = true
                                return true
                            }
                            return currentPID == ownPID
                        }), !userSwitched, NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID else {
                            throw UIReviewError.invalid("The single QA activation did not become frontmost or a user switch was observed")
                        }
                    }
                    guard mayContinue() else { throw UIReviewError.invalid("QA no longer frontmost before own-window presentation") }
                    window.makeKeyAndOrderFront(nil)
                    // Keep one QA host visible between scenes so closing the prior scene
                    // does not itself surrender foreground and resemble a user switch.
                    for previous in windows where previous !== window {
                        previous.contentView = nil; previous.orderOut(nil); previous.close()
                    }
                    windows = [window]
                    guard let host = window.contentView else { throw UIReviewError.invalid("Missing synthetic menu host") }
                    func buttons(_ view: NSView) -> [NSButton] {
                        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons)
                    }
                    let candidates = buttons(host).filter { $0.isEnabled && $0.bounds.width > 0 && $0.bounds.height > 0 }
                    let index = scenario == .analyzing ? 0 : 1
                    guard candidates.indices.contains(index), mayContinue() else { throw UIReviewError.invalid("Native details trigger unavailable or QA lost foreground") }
                    let trigger = candidates[index]
                    let before = Set(NSApp.windows.map(\.windowNumber))
                    trigger.performClick(nil)
                    var popup: NSWindow?
                    guard waitUntil({
                        guard mayContinue() else { return true }
                        popup = NSApp.windows.first { $0.isVisible && !before.contains($0.windowNumber) }
                        return popup != nil
                    }), mayContinue(), let popup else { throw UIReviewError.invalid("No native popup in the authorized foreground session") }
                    observations.append(["scenario": scenario.rawValue, "appearance": look,
                        "hostWindowID": window.windowNumber, "popupWindowID": popup.windowNumber, "input": inputs(model)])
                    try capture(popup, scenario: scenario, look: look, phase: "opened")
                    if scenario != .analyzing {
                        guard let content = popup.contentView else { throw UIReviewError.invalid("Missing source popup content") }
                        try UIReviewCapture.scrollToBottom(content)
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                        try capture(popup, scenario: scenario, look: look, phase: "bottom")
                    } else {
                        model.state.snapshot.indexProgress = IndexProgress(state: .updating, totalsKnown: true,
                            totalAssets: 15702, readyAssets: 2192, totalRepresentations: 45000,
                            readyRepresentations: 6789, excludedAssets: 99, issue: "合成更新原因")
                        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                        try capture(popup, scenario: scenario, look: look, phase: "progress")
                        model.state.snapshot.indexProgress = IndexProgress(state: .ready, totalsKnown: true,
                            totalAssets: 15702, readyAssets: 15702, totalRepresentations: 45000,
                            readyRepresentations: 45000, excludedAssets: 99, issue: nil)
                        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                        try capture(popup, scenario: scenario, look: look, phase: "ready")
                        observations.append(["scenario": scenario.rawValue, "appearance": look,
                            "samePopupVisibleAfterReady": popup.isVisible, "sameTriggerAfterReady": buttons(host).first === trigger,
                            "readyAccessibilityNameProjection": SyncDetailsButton(snapshot: model.state.snapshot).accessibilityLabel])
                    }
                    popup.orderOut(nil); popup.close()
                }
            }
        } catch { failure = String(describing: error) }
        let frontBeforeRestore = frontmost()
        // Restore before normal own-window cleanup, only while QA still owns foreground
        // and no user switch has ever been observed. Never activateAllWindows or retry.
        if activated, !userSwitched, NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID,
           let liveOriginal = NSRunningApplication(processIdentifier: originalPID), !liveOriginal.isTerminated,
           liveOriginal.bundleIdentifier == original.bundleIdentifier {
            restore = ["attempted": true, "accepted": liveOriginal.activate(options: [])]
            let restoreDeadline = min(deadline, Date().addingTimeInterval(0.75))
            var observed = false
            var thirdParty = false
            repeat {
                let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                if currentPID == originalPID { observed = true; break }
                if let currentPID, currentPID != ownPID { thirdParty = true; break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            } while Date() < restoreDeadline
            restore["observedOriginalFrontmost"] = observed
            restore["stoppedOnThirdPartySwitch"] = thirdParty
            restore["frontmostAtObservationEnd"] = frontmost()
        }
        closeOwnWindows()
        manifest["controlledSession"] = ["originalFrontmost": ["pid": originalPID, "bundleID": original.bundleIdentifier ?? "unknown"],
            "qaPID": ownPID, "qaActivationCalls": activated ? 1 : 0, "maximumSeconds": 30,
            "elapsedSeconds": Date().timeIntervalSince(started), "userSwitchObserved": userSwitched,
            "frontmostBeforeRestore": frontBeforeRestore, "restore": restore, "frontmostAfter": frontmost(),
            "status": failure == nil ? "acquired-awaiting-coordinator-inspection" : "unverified",
            "failure": failure.map { $0 as Any } ?? NSNull(), "observations": observations, "captures": captures,
            "systemSettingsChanged": false, "globalInputInjected": false]
        try save(manifest, output: output, name: "controlled-manifest.json")
    }

    static func userOpenCaptureResult(_ acquisition: [String: Any]) -> [String: Any] {
        var result: [String: Any] = ["compositor": acquisition]
        if acquisition["status"] as? String == "captured" {
            result["status"] = "captured"
            result["visualAcceptance"] = "Acquisition only; requires inspection"
        } else {
            result["status"] = "unverified"
            result["failure"] = acquisition["failure"]
                ?? "Capture acquisition did not return an accepted result"
        }
        return result
    }

    static func compositorCapture(window: NSWindow, output: URL, name: String, captureAllowed: (() -> Bool)? = nil) throws -> [String: Any] {
        if captureAllowed?() == false { return ["status": "unverified", "failure": "Controlled foreground/session guard ended before acquisition"] }
        guard CGPreflightScreenCaptureAccess() else {
            return ["status": "unverified", "failure": "Screen Recording preflight false; no permission requested"]
        }
        guard NSApp.windows.contains(where: { $0 === window }), window.isVisible else {
            throw UIReviewError.invalid("Compositor target must be a visible window owned by this test host")
        }
        let windowID = CGWindowID(window.windowNumber)
        let visibleWindows = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]] ?? []
        guard visibleWindows.contains(where: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID &&
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier
        }) else { throw UIReviewError.invalid("WindowServer target PID/ID does not match this test host") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), "-t", "png", output.appendingPathComponent(name).path]
        let errors = Pipe()
        process.standardError = errors
        do { try process.run() }
        catch { return ["status": "unverified", "failure": String(describing: error)] }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            if captureAllowed?() == false {
                process.terminate()
                return ["status": "unverified", "failure": "Controlled foreground/session guard ended during acquisition"]
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        if process.isRunning {
            process.terminate()
            return ["status": "unverified", "failure": "Own-window screencapture exceeded bounded five-second deadline"]
        }
        if captureAllowed?() == false { return ["status": "unverified", "failure": "Controlled foreground/session guard ended after acquisition"] }
        let diagnostic = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            return ["status": "unverified", "exitCode": process.terminationStatus, "failure": diagnostic]
        }
        do {
            let url = output.appendingPathComponent(name)
            guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url)) else {
                throw UIReviewError.invalid("Missing compositor PNG")
            }
            let scale = window.backingScaleFactor
            let size = NSSize(width: CGFloat(bitmap.pixelsWide) / scale, height: CGFloat(bitmap.pixelsHigh) / scale)
            // macOS captures this transient's owning window group, not only its contentView.
            // Every member below is from this test process; no desktop crop is requested.
            let ownedVisible = NSApp.windows.filter(\.isVisible)
            let groupBounds = ownedVisible.map(\.frame).reduce(NSRect.null) { $0.union($1) }
            guard abs(size.width - groupBounds.width) <= 16, abs(size.height - groupBounds.height) <= 16 else {
                throw UIReviewError.invalid("Unexpected own-window group capture geometry \(size); union \(groupBounds.size)")
            }
            try UIReviewCapture.validate(bitmap, logicalSize: size)
            return ["status": "captured", "file": name, "windowID": window.windowNumber,
                "logicalWindowWidth": window.frame.width, "logicalWindowHeight": window.frame.height,
                "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh,
                "logicalCaptureWidth": size.width, "logicalCaptureHeight": size.height,
                "ownVisibleWindowIDs": ownedVisible.map(\.windowNumber),
                "verifiedOwnerPID": ProcessInfo.processInfo.processIdentifier,
                "ownVisibleUnion": String(describing: groupBounds), "groupEdgeTolerancePoints": 16,
                "captureMethod": "screencapture -x -o -l verified own-process windowID; includes its owning test-host group; existing permission only"]
        } catch { return ["status": "unverified", "failure": String(describing: error), "diagnostic": diagnostic] }
    }

    static func save(_ object: [String: Any], output: URL, name: String) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(name), options: .atomic)
    }
}
