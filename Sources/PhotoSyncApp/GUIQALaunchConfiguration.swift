import Foundation

enum GUIQAMode: String, Equatable, Sendable {
    case fake
    case readonly
}

enum GUIQALaunchConfigurationError: Error, Equatable, LocalizedError {
    case missingMode
    case invalidMode(String)
    case missingRoot
    case invalidRoot(String)
    case duplicateArgument(String)
    case productionSupportDirectory
    case outsideWorkingDirectory
    case invalidWorkspace(String)
    case unsafeRoot(String)

    var errorDescription: String? {
        switch self {
        case .missingMode:
            return "GUI QA requires --qa-mode fake or --qa-mode readonly."
        case .invalidMode(let value):
            return "GUI QA mode '\(value)' is not supported."
        case .missingRoot:
            return "GUI QA requires --qa-root <new temporary directory>."
        case .invalidRoot(let value):
            return "GUI QA root '\(value)' is not a usable directory path."
        case .duplicateArgument(let flag):
            return "GUI QA argument '\(flag)' may appear only once."
        case .productionSupportDirectory:
            return "PhotosYNC GUI QA refuses to use the production Application Support directory."
        case .outsideWorkingDirectory:
            return "GUI QA root must be inside the current workspace."
        case .invalidWorkspace(let value):
            return "PhotosYNC GUI QA workspace '\(value)' must be an absolute PhotosYNC workspace."
        case .unsafeRoot(let path):
            return "GUI QA root is unsafe: \(path)"
        }
    }
}

struct GUIQALaunchConfiguration: Equatable, Sendable {
    let mode: GUIQAMode
    let root: URL

    static func parse(
        arguments: [String],
        workingDirectory: URL,
        productionSupportDirectory: URL
    ) throws -> GUIQALaunchConfiguration {
        let modeValue = try value(after: "--qa-mode", arguments: arguments, missing: .missingMode)
        guard let mode = GUIQAMode(rawValue: modeValue) else {
            throw GUIQALaunchConfigurationError.invalidMode(modeValue)
        }
        let workspace = try workspace(arguments: arguments, fallback: workingDirectory)
        let rootValue = try value(after: "--qa-root", arguments: arguments, missing: .missingRoot)
        guard !rootValue.isEmpty, rootValue != "/" else {
            throw GUIQALaunchConfigurationError.invalidRoot(rootValue)
        }
        let root: URL
        if rootValue.hasPrefix("/") {
            root = URL(fileURLWithPath: rootValue, isDirectory: true).standardizedFileURL
        } else {
            root = workspace.appendingPathComponent(rootValue, isDirectory: true).standardizedFileURL
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedProductionSupport = productionSupportDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard !isContained(root, within: resolvedProductionSupport),
              !isContained(resolvedRoot, within: resolvedProductionSupport) else {
            throw GUIQALaunchConfigurationError.productionSupportDirectory
        }
        guard isContained(resolvedRoot, within: workspace) else {
            throw GUIQALaunchConfigurationError.outsideWorkingDirectory
        }
        return GUIQALaunchConfiguration(mode: mode, root: root)
    }

    private static func value(
        after flag: String,
        arguments: [String],
        missing: GUIQALaunchConfigurationError
    ) throws -> String {
        let matches = arguments.indices.filter { arguments[$0] == flag }
        guard matches.count <= 1 else { throw GUIQALaunchConfigurationError.duplicateArgument(flag) }
        guard let index = matches.first else { throw missing }
        let next = arguments.index(after: index)
        guard arguments.indices.contains(next), !arguments[next].hasPrefix("--") else { throw missing }
        return arguments[next]
    }

    private static func workspace(arguments: [String], fallback: URL) throws -> URL {
        let matches = arguments.indices.filter { arguments[$0] == "--qa-workspace" }
        guard matches.count <= 1 else { throw GUIQALaunchConfigurationError.duplicateArgument("--qa-workspace") }
        guard let index = matches.first else {
            return fallback.resolvingSymlinksInPath().standardizedFileURL
        }
        let next = arguments.index(after: index)
        guard arguments.indices.contains(next), !arguments[next].hasPrefix("--") else {
            throw GUIQALaunchConfigurationError.invalidWorkspace("")
        }
        let value = arguments[next]
        guard value.hasPrefix("/"), value != "/" else {
            throw GUIQALaunchConfigurationError.invalidWorkspace(value)
        }
        let candidate = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey]
        let project = resolved.appendingPathComponent("PhotoSync.xcodeproj", isDirectory: true)
        guard let values = try? candidate.resourceValues(forKeys: keys),
              values.isDirectory == true,
              values.isSymbolicLink != true,
              values.isAliasFile != true,
              let projectValues = try? project.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey]),
              projectValues.isDirectory == true,
              projectValues.isSymbolicLink != true,
              projectValues.isAliasFile != true else {
            throw GUIQALaunchConfigurationError.invalidWorkspace(value)
        }
        return resolved
    }
}

struct GUIQADataPaths: Equatable, Sendable {
    let root: URL
    let sessionDirectory: URL
    let stateDirectory: URL
    let databaseURL: URL
    let logsURL: URL

    static func create(
        root: URL,
        productionSupportDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> GUIQADataPaths {
        let candidate = root.standardizedFileURL
        let resolvedProductionSupport = productionSupportDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard !isContained(candidate, within: resolvedProductionSupport) else {
            throw GUIQALaunchConfigurationError.productionSupportDirectory
        }
        let resolvedBeforeCreate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard !isContained(resolvedBeforeCreate, within: resolvedProductionSupport) else {
            throw GUIQALaunchConfigurationError.productionSupportDirectory
        }
        if fileManager.fileExists(atPath: candidate.path) {
            let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey])
            guard values.isDirectory == true else {
                throw GUIQALaunchConfigurationError.unsafeRoot(candidate.path)
            }
            guard values.isSymbolicLink != true, values.isAliasFile != true else {
                throw GUIQALaunchConfigurationError.unsafeRoot(candidate.path)
            }
        }
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
        let resolvedRoot = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard !isContained(resolvedRoot, within: resolvedProductionSupport) else {
            throw GUIQALaunchConfigurationError.productionSupportDirectory
        }
        let sessions = resolvedRoot.appendingPathComponent("Sessions", isDirectory: true)
        if fileManager.fileExists(atPath: sessions.path) {
            let values = try sessions.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey])
            guard values.isDirectory == true, values.isSymbolicLink != true, values.isAliasFile != true else {
                throw GUIQALaunchConfigurationError.unsafeRoot(sessions.path)
            }
        } else {
            try fileManager.createDirectory(at: sessions, withIntermediateDirectories: false)
        }
        let session = sessions.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: session, withIntermediateDirectories: false)
        let resolvedSession = session.resolvingSymlinksInPath().standardizedFileURL
        guard isContained(resolvedSession, within: resolvedRoot),
              !isContained(resolvedSession, within: resolvedProductionSupport) else {
            throw GUIQALaunchConfigurationError.productionSupportDirectory
        }
        let state = resolvedSession.appendingPathComponent("State", isDirectory: true)
        let logs = resolvedSession.appendingPathComponent("Logs", isDirectory: true)
        try fileManager.createDirectory(at: state, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
        return GUIQADataPaths(
            root: resolvedRoot,
            sessionDirectory: resolvedSession,
            stateDirectory: state,
            databaseURL: state.appendingPathComponent("sync.sqlite"),
            logsURL: logs
        )
    }
}

private func isContained(_ candidate: URL, within container: URL) -> Bool {
    let candidatePath = candidate.standardizedFileURL.path
    let containerPath = container.standardizedFileURL.path
    return candidatePath == containerPath || candidatePath.hasPrefix(containerPath + "/")
}
