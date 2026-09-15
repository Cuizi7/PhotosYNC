import XCTest
@testable import PhotoSyncCore

final class GUIQALaunchConfigurationTests: XCTestCase {
    func testMissingModeFailsClosed() {
        XCTAssertThrowsError(
            try GUIQALaunchConfiguration.parse(
                arguments: ["PhotoSyncGUIQA"],
                workingDirectory: URL(fileURLWithPath: "/tmp/guiqa-work"),
                productionSupportDirectory: productionSupportDirectory
            )
        ) { error in
            XCTAssertEqual(error as? GUIQALaunchConfigurationError, .missingMode)
        }
    }

    func testUnknownModeFailsClosed() {
        XCTAssertThrowsError(
            try GUIQALaunchConfiguration.parse(
                arguments: ["PhotoSyncGUIQA", "--qa-mode", "write", "--qa-root", "stage"],
                workingDirectory: URL(fileURLWithPath: "/tmp/guiqa-work"),
                productionSupportDirectory: productionSupportDirectory
            )
        ) { error in
            XCTAssertEqual(error as? GUIQALaunchConfigurationError, .invalidMode("write"))
        }
    }

    func testMissingRootFailsClosed() {
        XCTAssertThrowsError(
            try GUIQALaunchConfiguration.parse(
                arguments: ["PhotoSyncGUIQA", "--qa-mode", "fake"],
                workingDirectory: URL(fileURLWithPath: "/tmp/guiqa-work"),
                productionSupportDirectory: productionSupportDirectory
            )
        ) { error in
            XCTAssertEqual(error as? GUIQALaunchConfigurationError, .missingRoot)
        }
    }

    func testProductionSupportRootIsRejected() {
        XCTAssertThrowsError(
            try GUIQALaunchConfiguration.parse(
                arguments: ["PhotoSyncGUIQA", "--qa-mode", "fake", "--qa-root", productionSupportDirectory.path],
                workingDirectory: URL(fileURLWithPath: "/tmp/guiqa-work"),
                productionSupportDirectory: productionSupportDirectory
            )
        ) { error in
            XCTAssertEqual(error as? GUIQALaunchConfigurationError, .productionSupportDirectory)
        }
    }

    func testRootOutsideWorkingDirectoryFailsClosed() {
        XCTAssertThrowsError(
            try GUIQALaunchConfiguration.parse(
                arguments: ["PhotoSyncGUIQA", "--qa-mode", "fake", "--qa-root", "/tmp/other-root"],
                workingDirectory: URL(fileURLWithPath: "/tmp/guiqa-work"),
                productionSupportDirectory: productionSupportDirectory
            )
        ) { error in
            XCTAssertEqual(error as? GUIQALaunchConfigurationError, .outsideWorkingDirectory)
        }
    }

    func testExplicitWorkspaceOverridesLaunchServicesWorkingDirectory() throws {
        let workspace = try qaWorkspace()
        let root = workspace.appendingPathComponent("work/GUIQA/stage1", isDirectory: true)
        let configuration = try GUIQALaunchConfiguration.parse(
            arguments: [
                "PhotoSyncGUIQA",
                "--qa-workspace", workspace.path,
                "--qa-mode", "fake",
                "--qa-root", root.path
            ],
            workingDirectory: URL(fileURLWithPath: "/"),
            productionSupportDirectory: productionSupportDirectory
        )

        XCTAssertEqual(configuration.mode, .fake)
        XCTAssertEqual(configuration.root, root.standardizedFileURL)
    }

    func testExplicitWorkspaceMustBeAbsoluteAndContainProject() throws {
        XCTAssertThrowsError(
            try GUIQALaunchConfiguration.parse(
                arguments: ["PhotoSyncGUIQA", "--qa-workspace", "work", "--qa-mode", "fake", "--qa-root", "work/GUIQA/stage1"],
                workingDirectory: URL(fileURLWithPath: "/"),
                productionSupportDirectory: productionSupportDirectory
            )
        ) { error in
            XCTAssertEqual(error as? GUIQALaunchConfigurationError, .invalidWorkspace("work"))
        }

        let missingProject = try temporaryDirectory()
        XCTAssertThrowsError(
            try GUIQALaunchConfiguration.parse(
                arguments: ["PhotoSyncGUIQA", "--qa-workspace", missingProject.path, "--qa-mode", "fake", "--qa-root", missingProject.appendingPathComponent("work/GUIQA/stage1").path],
                workingDirectory: URL(fileURLWithPath: "/"),
                productionSupportDirectory: productionSupportDirectory
            )
        ) { error in
            XCTAssertEqual(error as? GUIQALaunchConfigurationError, .invalidWorkspace(missingProject.path))
        }

        let projectFile = try temporaryDirectory()
        try Data().write(to: projectFile.appendingPathComponent("PhotoSync.xcodeproj"))
        XCTAssertThrowsError(
            try GUIQALaunchConfiguration.parse(
                arguments: ["PhotoSyncGUIQA", "--qa-workspace", projectFile.path, "--qa-mode", "fake", "--qa-root", projectFile.appendingPathComponent("work/GUIQA/stage1").path],
                workingDirectory: URL(fileURLWithPath: "/"),
                productionSupportDirectory: productionSupportDirectory
            )
        ) { error in
            XCTAssertEqual(error as? GUIQALaunchConfigurationError, .invalidWorkspace(projectFile.path))
        }
    }

    func testValidRelativeRootUsesWorkingDirectory() throws {
        let configuration = try GUIQALaunchConfiguration.parse(
            arguments: ["PhotoSyncGUIQA", "--qa-mode", "readonly", "--qa-root", "work/GUIQA/stage2"],
            workingDirectory: URL(fileURLWithPath: "/tmp/guiqa-work"),
            productionSupportDirectory: productionSupportDirectory
        )

        XCTAssertEqual(configuration.mode, .readonly)
        XCTAssertEqual(
            configuration.root,
            URL(fileURLWithPath: "/tmp/guiqa-work/work/GUIQA/stage2", isDirectory: true).standardizedFileURL
        )
    }

    func testDataPathsUseFreshSessionInsideRoot() throws {
        let root = try temporaryDirectory().appendingPathComponent("guiqa-root", isDirectory: true)
        let production = try temporaryDirectory().appendingPathComponent("PhotoSync", isDirectory: true)
        let paths = try GUIQADataPaths.create(root: root, productionSupportDirectory: production)

        XCTAssertTrue(paths.sessionDirectory.path.hasPrefix(root.path + "/"))
        XCTAssertTrue(paths.databaseURL.path.hasPrefix(paths.sessionDirectory.path + "/"))
        XCTAssertTrue(paths.logsURL.path.hasPrefix(paths.sessionDirectory.path + "/"))
        XCTAssertNotEqual(paths.sessionDirectory, root)
    }

    func testDataPathsRejectSymlinkThatResolvesIntoProductionSupport() throws {
        let container = try temporaryDirectory()
        let production = container.appendingPathComponent("production/PhotoSync", isDirectory: true)
        try FileManager.default.createDirectory(at: production, withIntermediateDirectories: true)
        let rootLink = container.appendingPathComponent("guiqa-root", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: production)

        XCTAssertThrowsError(
            try GUIQADataPaths.create(root: rootLink, productionSupportDirectory: production)
        ) { error in
            XCTAssertEqual(error as? GUIQALaunchConfigurationError, .productionSupportDirectory)
        }
    }

    func testDataPathsRejectSymlinkedSessionsDirectory() throws {
        let container = try temporaryDirectory()
        let root = container.appendingPathComponent("guiqa-root", isDirectory: true)
        let production = container.appendingPathComponent("production/PhotoSync", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: production, withIntermediateDirectories: true)
        let sessions = root.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: sessions, withDestinationURL: production)

        XCTAssertThrowsError(
            try GUIQADataPaths.create(root: root, productionSupportDirectory: production)
        ) { error in
            XCTAssertEqual(error as? GUIQALaunchConfigurationError, .unsafeRoot(sessions.path))
        }
    }

    func testDataPathsLeaveOldStateAndLogsLinksUntouched() throws {
        let container = try temporaryDirectory()
        let root = container.appendingPathComponent("guiqa-root", isDirectory: true)
        let production = container.appendingPathComponent("production/PhotoSync", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: production, withIntermediateDirectories: true)
        let oldState = root.appendingPathComponent("State", isDirectory: true)
        let oldLogs = root.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: oldState, withDestinationURL: production)
        try FileManager.default.createSymbolicLink(at: oldLogs, withDestinationURL: production)

        let paths = try GUIQADataPaths.create(root: root, productionSupportDirectory: production)

        XCTAssertFalse(paths.databaseURL.path.hasPrefix(oldState.path + "/"))
        XCTAssertFalse(paths.logsURL.path.hasPrefix(oldLogs.path + "/"))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: oldState.path), production.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: oldLogs.path), production.path)
    }

    private var productionSupportDirectory: URL {
        URL(fileURLWithPath: "/Users/example/Library/Application Support/PhotoSync")
    }

    private func qaWorkspace() throws -> URL {
        let workspace = try temporaryDirectory()
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("PhotoSync.xcodeproj", isDirectory: true),
            withIntermediateDirectories: true
        )
        return workspace
    }
}
