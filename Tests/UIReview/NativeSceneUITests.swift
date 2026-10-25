import AppKit
import CoreGraphics
import XCTest

/// Only this test bundle drives input. The QA app uses the real product scenes,
/// a fake system boundary and a per-run owner lease, never the production app.
@MainActor
final class NativeSceneUITests: XCTestCase {
    func testNativeScenes() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let output = URL(fileURLWithPath: try XCTUnwrap(environment["PHOTOSYNC_NATIVE_OUTPUT"]))
        let matrix = try XCTUnwrap(environment["PHOTOSYNC_NATIVE_MATRIX"])
        let bundleID = try XCTUnwrap(environment["PHOTOSYNC_NATIVE_APP_ID"])
        let bundlePath = try XCTUnwrap(environment["PHOTOSYNC_NATIVE_APP_PATH"])
        let replyURL = try XCTUnwrap(URL(string: try XCTUnwrap(environment["PHOTOSYNC_NATIVE_REPLY_URL"])))
        let replyToken = try XCTUnwrap(environment["PHOTOSYNC_NATIVE_REPLY_TOKEN"])
        XCTAssertEqual(replyURL.host, "127.0.0.1"); XCTAssertEqual(replyURL.scheme, "http"); XCTAssertEqual(replyURL.path, "/reply")
        let owner = try read(output.appendingPathComponent("native-owner.json"))
        XCTAssertEqual(owner["active"] as? Bool, true)
        XCTAssertTrue(bundleID.hasPrefix("local.photosync.native-review."))
        XCTAssertTrue(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
                      "Do not terminate another test's existing app")
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchArguments = ["--native-output", output.path, "--native-matrix", matrix, "--allow-focus", "--native-xcuitest"]
        if environment["PHOTOSYNC_NATIVE_SETTINGS_ONLY"] == "1" { app.launchArguments.append("--settings-only") }
        app.launch()
        defer { if app.state != .notRunning { app.terminate() } }
        var handled = Set<String>()
        var handledRestarts = Set<String>()
        var restarts = 0
        let expectedRestarts = Int(environment["PHOTOSYNC_NATIVE_EXPECTED_RESTARTS"] ?? "0") ?? 0
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            let requestPath = output.appendingPathComponent("native-input-request.json")
            if let request = try? read(requestPath), let id = request["id"] as? String, !handled.contains(id) {
                var response: [String: Any] = ["id":id]
                do {
                    try perform(request, app: app, bundleID: bundleID, bundlePath: bundlePath)
                    response["success"] = true
                } catch {
                    response["success"] = false; response["reason"] = String(describing:error)
                }
                // Xcode's runner intentionally has read-only checkout access.
                // Only the coordinator writes the fixed response file.
                var message = URLRequest(url: replyURL, timeoutInterval: 5)
                message.httpMethod = "POST"; message.setValue(replyToken, forHTTPHeaderField: "X-Photosync-QA-Token")
                message.httpBody = try JSONSerialization.data(withJSONObject: response)
                let (_, result) = try await URLSession.shared.data(for: message)
                XCTAssertEqual((result as? HTTPURLResponse)?.statusCode, 204)
                handled.insert(id)
            }
            if let report = try? read(output.appendingPathComponent("native-captures.json")), let status = report["status"] as? String, status == "restart_required" {
                let restartID = try XCTUnwrap(report["restartID"] as? String)
                if !handledRestarts.insert(restartID).inserted { try await Task.sleep(for: .milliseconds(100)); continue }
                restarts += 1
                XCTAssertLessThanOrEqual(restarts, expectedRestarts)
                if app.state != .notRunning { app.terminate() }
                if !app.launchArguments.contains("--native-resume") { app.launchArguments.append("--native-resume") }
                app.launch()
            } else if let report = try? read(output.appendingPathComponent("native-captures.json")), let status = report["status"] as? String, !["capturing", "restarting"].contains(status) {
                XCTAssertEqual(status, "captured", report["reason"] as? String ?? "Missing native completion")
                XCTAssertEqual(restarts, expectedRestarts)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Native scene handshake exceeded 240 seconds")
    }

    private func perform(_ request: [String: Any], app: XCUIApplication, bundleID: String, bundlePath: String) throws {
        guard let pid = request["pid"] as? Int32,
              let running = NSRunningApplication(processIdentifier: pid), running.bundleIdentifier == bundleID,
              running.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == URL(fileURLWithPath: bundlePath).standardizedFileURL.resolvingSymlinksInPath().path,
              let kind = request["kind"] as? String, let windowID = request["windowID"] as? UInt64,
              let x = request["x"] as? Double, let y = request["y"] as? Double, x.isFinite, y.isFinite else {
            throw DriverFailure.invalid("Input request is not bound to this QA app")
        }
        if kind == "activate" { app.activate(); return }
        guard ["click", "move"].contains(kind) else { throw DriverFailure.invalid("Unsupported UI action") }
        if let target = request["target"] as? String {
            let elements: XCUIElementQuery
            switch target {
            case "task-details-visualIndex", "task-details-livePhoto": elements = app.buttons.matching(identifier: target)
            case "hover-exit": elements = app.buttons.matching(NSPredicate(format: "label == %@", "在 Finder 中打开日志目录"))
            case "add-source": elements = app.buttons.matching(identifier: target)
            case "image-memory-limit": elements = app.popUpButtons.matching(NSPredicate(format: "label == %@", "图像处理内存峰值上限"))
            case "primary-storage-error": elements = app.staticTexts.matching(NSPredicate(format: "value == %@ AND enabled == true", "本地数据库不可用，同步已停止。"))
            default: throw DriverFailure.invalid("Unsupported native control target")
            }
            guard running.isActive else { throw DriverFailure.invalid("QA app is inactive") }
            guard elements.firstMatch.waitForExistence(timeout: 3), elements.count == 1 else {
                print("OWN_QA_HIERARCHY_BEGIN\n\(app.debugDescription)\nOWN_QA_HIERARCHY_END")
                throw DriverFailure.invalid("Unique own-app control was not found: \(target)")
            }
            guard elements.firstMatch.isHittable else { throw DriverFailure.invalid("QA control is occluded or not hittable") }
            if kind == "move" { elements.firstMatch.hover() }
            else if request["count"] as? Int == 2 { elements.firstMatch.doubleClick() }
            else { elements.firstMatch.click() }
            return
        }
        if windowID > UInt32.max {
            let items = app.statusItems
            guard items.firstMatch.waitForExistence(timeout: 3), items.count == 1, items.firstMatch.isHittable else {
                throw DriverFailure.invalid("Unique own-app status item is not hittable")
            }
            items.firstMatch.click()
            return
        }
        let point = CGPoint(x: x, y: y)
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, UInt32(windowID)) as? [[String: Any]],
              let own = rows.first, own[kCGWindowOwnerPID as String] as? Int == Int(pid),
              let dictionary = own[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary), bounds.contains(point) else {
            throw DriverFailure.invalid("Requested point is outside its owned window")
        }
        guard running.isActive else { throw DriverFailure.invalid("QA window is inactive") }
        guard let top = topmostWindow(at: point), top.pid == pid, kind == "move" || top.id == windowID else {
            throw DriverFailure.invalid("QA window is occluded at the requested point")
        }
        let windows = app.windows.allElementsBoundByIndex.filter {
            abs($0.frame.minX - bounds.minX) < 2 && abs($0.frame.minY - bounds.minY) < 2 &&
            abs($0.frame.width - bounds.width) < 2 && abs($0.frame.height - bounds.height) < 2
        }
        guard windows.count == 1, let window = windows.first, window.isHittable else {
            throw DriverFailure.invalid("Unique owned native window is not hittable")
        }
        let coordinate = window.coordinate(withNormalizedOffset: CGVector(dx: (x - bounds.minX) / bounds.width, dy: (y - bounds.minY) / bounds.height))
        if kind == "move" { coordinate.hover() }
        else if request["count"] as? Int == 2 { coordinate.doubleClick() }
        else { coordinate.click() }
    }

    private func topmostWindow(at point: CGPoint) -> (id: UInt64, pid: Int32)? {
        guard let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for row in rows {
            guard let alpha = row[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let dictionary = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary), bounds.contains(point),
                  let id = row[kCGWindowNumber as String] as? NSNumber, let pid = row[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            return (id.uint64Value, pid.int32Value)
        }
        return nil
    }
    private func read(_ path: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] else {
            throw DriverFailure.invalid("Invalid native handshake")
        }
        return value
    }
}

private enum DriverFailure: Error { case invalid(String) }
