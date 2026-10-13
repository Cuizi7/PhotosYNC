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
        app.setActivationPolicy(args.contains("--interactive") || args.contains("--probe") ? .accessory : .prohibited)
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("source.json"))) as? [String: Any] ?? [:]
        manifest["hostBundle"] = ["identifier": Bundle.main.bundleIdentifier ?? "missing",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "missing",
            "channel": Bundle.main.object(forInfoDictionaryKey: "PhotoSyncReleaseChannel") ?? "missing",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "missing"]
        manifest["limitations"] = ["Native compiled view bitmap; not a system MenuBarExtra popup or compositor capture.",
            "System integrations disabled by injected-model isolation; this is not a product enablement change.",
            "XCTest renders use XCTest Bundle.main metadata; this host uses the same build's app version metadata.",
            "No screen/accessibility permission requests, no global events, no foreground activation."]
        manifest["humanAcceptance"] = "候选证据，等待用户验收"
        manifest["controlActiveStateOverride"] = "SwiftUI environment controlActiveState=.active; affects control appearance only; does not activate app/window or certify focus/hover"
        if args.contains("--probe") {
            var observations: [[String: Any]] = []
            for scenario in [UIReviewScenario.syncing, .many] {
                let model = try makeUIReviewModel(scenario: scenario, root: root)
                for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    // This process is a test-only host. Native alert/popover chrome must use
                    // the selected fixture appearance too, without changing the user's OS.
                    app.appearance = NSAppearance(named: appearance)
                    let view = scenario == .syncing ? AnyView(StatusMenu(model: model)) : AnyView(SourceSettings(model: model))
                    let window = try interactiveWindow(view, width: scenario == .syncing ? 320 : 600, appearance: appearance)
                    window.title = "PhotosYNC 隔离原生交互探针 · \(scenario.rawValue) · \(look)"
                    window.orderFront(nil)
                    guard let host = window.contentView else { throw UIReviewError.invalid("Missing probe host") }
                    _ = waitUntil { window.isVisible }
                    let staticName = "probe-\(scenario.rawValue)-\(look).png"
                    _ = try UIReviewCapture.write(host, to: output.appendingPathComponent(staticName))
                    observations.append(try probe(host: host, window: window, model: model, scenario: scenario,
                        appearance: look, output: output))
                    manifest["interactions"] = observations
                    try save(manifest, output: output, name: "probe-manifest.json")
                    window.contentView = nil
                    window.close()
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
            var windows: [NSWindow] = []
            for surface in ["menu", "settings"] {
                let view = surface == "menu" ? AnyView(StatusMenu(model: model)) : AnyView(SourceSettings(model: model))
                let window = try interactiveWindow(view, width: surface == "menu" ? 320 : 600, appearance: appearance)
                window.title = "PhotosYNC 测试审阅 · \(scenario.rawValue) · \(surface) · \(look)"
                window.orderFront(nil) // Does not activate or request system keyboard focus.
                windows.append(window)
            }
            manifest["interactive"] = ["scenario": raw, "appearance": look,
                "pid": ProcessInfo.processInfo.processIdentifier,
                "windowIDs": windows.map(\.windowNumber), "activationRequested": false,
                "status": "User-controlled fixture session; interactions not automatically certified"]
            try save(manifest, output: output, name: "interactive-manifest.json")
            withExtendedLifetime((model, windows)) { app.run() }
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
            }
        }
        guard captures.count == 70 else { throw UIReviewError.invalid("Incomplete matrix: \(captures.count)/70") }
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
        let identifier = scenario == .syncing ? "sync-details" : "remove-source-\(model.state.sources.first!.id.uuidString)"
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
            // Coordinates were visually checked against this scenario's real compiled PNG.
            // Fail closed if its geometry changes; never infer a target in an unrelated window.
            let expectedHeight: CGFloat = scenario == .syncing ? 212 : 669
            guard abs(host.bounds.height - expectedHeight) <= 1 else {
                result["status"] = "unverified"
                result["failure"] = "AX target unavailable and capture-verified fallback geometry changed"
                return result
            }
            let topPoint = scenario == .syncing ? NSPoint(x: 298, y: 47) : NSPoint(x: 535, y: 165)
            let local = NSPoint(x: topPoint.x, y: host.isFlipped ? topPoint.y : host.bounds.height - topPoint.y)
            point = host.convert(local, to: nil)
            hitView = host.hitTest(point)
            result["inputMethod"] = "NSWindow-scoped mouse at visually verified own-view PNG coordinate; AX target unavailable"
            result["targetPointInWindow"] = [point.x, point.y]
            result["hitView"] = String(describing: hitView)
            guard hitView != nil else {
                result["status"] = "unverified"
                result["failure"] = "No own-window hit target at capture-verified coordinate"
                return result
            }
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

    static func compositorCapture(window: NSWindow, output: URL, name: String) throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else {
            return ["status": "unverified", "failure": "Screen Recording preflight false; no permission requested"]
        }
        guard NSApp.windows.contains(where: { $0 === window }), window.isVisible else {
            throw UIReviewError.invalid("Compositor target must be a visible window owned by this test host")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), "-t", "png", output.appendingPathComponent(name).path]
        let errors = Pipe()
        process.standardError = errors
        do { try process.run() }
        catch { return ["status": "unverified", "failure": String(describing: error)] }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        if process.isRunning {
            process.terminate()
            return ["status": "unverified", "failure": "Own-window screencapture exceeded bounded five-second deadline"]
        }
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
                "ownVisibleUnion": String(describing: groupBounds), "groupEdgeTolerancePoints": 16,
                "captureMethod": "screencapture -x -o -l verified own-process transient windowID; includes its owning test-host group; existing permission only"]
        } catch { return ["status": "unverified", "failure": String(describing: error), "diagnostic": diagnostic] }
    }

    static func save(_ object: [String: Any], output: URL, name: String) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(name), options: .atomic)
    }
}
