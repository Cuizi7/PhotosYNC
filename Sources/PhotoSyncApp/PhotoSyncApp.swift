import AppKit
import Darwin
import PhotoSyncCore
import SwiftUI

@main
struct PhotoSyncApp: App {
    @StateObject private var model: AppModel
    private let instanceLock: SingleInstanceLock

    init() {
        instanceLock = Self.acquireInstanceLock()
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(model: model)
        } label: {
            Image(systemName: model.status.symbol).accessibilityLabel(model.statusDescription)
        }.menuBarExtraStyle(.window)
#if GUI_QA
        WindowGroup("PhotosYNC GUI QA") {
            SourceSettings(model: model)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 600, height: 590)
#endif
        Settings { SourceSettings(model: model) }

    }

    private static func acquireInstanceLock() -> SingleInstanceLock {
        let applicationIdentifier = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        do {
            let lockURL = try SingleInstanceLock.lockURL(applicationIdentifier: applicationIdentifier)
            switch SingleInstanceLock.acquire(at: lockURL) {
            case .acquired(let lock):
                // Older PhotoSync builds did not hold this lock. A concurrent new
                // launch will observe this flock and exit; a peer that remains
                // after the bounded wait is treated as the existing instance.
                if let existing = existingInstanceAfterContentionWait(bundleIdentifier: Bundle.main.bundleIdentifier) {
                    _ = existing.activate(options: [.activateAllWindows])
                    exit(EXIT_SUCCESS)
                }
                return lock
            case .alreadyRunning(let ownerPID):
                activateExistingInstance(ownerPID: ownerPID, bundleIdentifier: Bundle.main.bundleIdentifier)
                exit(EXIT_SUCCESS)
            case .failed(let error):
                terminateForLockError(error)
            }
        } catch {
            terminateForLockError(error)
        }
    }

    private static func activateExistingInstance(ownerPID: Int32?, bundleIdentifier: String?) {
        _ = existingInstance(ownerPID: ownerPID, bundleIdentifier: bundleIdentifier)?
            .activate(options: [.activateAllWindows])
    }

    private static func existingInstanceAfterContentionWait(bundleIdentifier: String?) -> NSRunningApplication? {
        guard existingInstance(ownerPID: nil, bundleIdentifier: bundleIdentifier) != nil else { return nil }
        for _ in 0..<8 {
            usleep(25_000)
            guard existingInstance(ownerPID: nil, bundleIdentifier: bundleIdentifier) != nil else { return nil }
        }
        return existingInstance(ownerPID: nil, bundleIdentifier: bundleIdentifier)
    }

    private static func existingInstance(
        ownerPID: Int32?,
        bundleIdentifier: String?
    ) -> NSRunningApplication? {
        if let ownerPID,
           let running = NSRunningApplication(processIdentifier: ownerPID),
           !running.isTerminated,
           bundleIdentifier == nil || running.bundleIdentifier == bundleIdentifier {
            return running
        }

        // A PID is available after lock contention; otherwise inspect the same app identity.
        guard let bundleIdentifier else { return nil }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != currentPID && !$0.isTerminated }
    }

    private static func terminateForLockError(_ error: Error) -> Never {
        let message = "PhotosYNC could not start: \(error.localizedDescription)\n"
        FileHandle.standardError.write(Data(message.utf8))
        exit(EXIT_FAILURE)
    }
}
