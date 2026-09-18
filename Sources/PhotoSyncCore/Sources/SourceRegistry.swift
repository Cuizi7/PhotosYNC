import Foundation

public enum SourceRegistry {
    public static func normalizedURL(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw SourceRegistryError.notFileURL }
        // Only the OS-owned /var and /tmp aliases are canonicalized, and only if
        // their link destinations are exactly the expected /private paths.
        var standardized = url.standardizedFileURL
        for name in ["var", "tmp"] where standardized.pathComponents.dropFirst().first == name {
            let alias = "/" + name
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: alias)) == "private/" + name ||
                (try? FileManager.default.destinationOfSymbolicLink(atPath: alias)) == "/private/" + name {
                standardized = URL(fileURLWithPath: "/private" + standardized.path)
            }
        }
        var componentURL = URL(fileURLWithPath: "/", isDirectory: true)
        for component in standardized.pathComponents.dropFirst() {
            componentURL.appendPathComponent(component)
            let attributes = try FileManager.default.attributesOfItem(atPath: componentURL.path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw SourceRegistryError.aliasOrLink(componentURL)
            }
            let values = try componentURL.resourceValues(forKeys: [.isAliasFileKey])
            guard values.isAliasFile != true else { throw SourceRegistryError.aliasOrLink(componentURL) }
        }
        let values = try standardized.resourceValues(forKeys: [.isDirectoryKey, .isAliasFileKey, .isSymbolicLinkKey])
        guard values.isDirectory == true else { throw SourceRegistryError.notDirectory(standardized) }
        guard values.isAliasFile != true, values.isSymbolicLink != true else { throw SourceRegistryError.aliasOrLink(standardized) }
        return standardized
    }

    public static func conflicts(_ first: URL, _ second: URL) -> Bool {
        let firstParts = first.pathComponents
        let secondParts = second.pathComponents
        return firstParts.starts(with: secondParts) || secondParts.starts(with: firstParts)
    }
}

public enum SourceRegistryError: Error, LocalizedError {
    case notFileURL
    case notDirectory(URL)
    case aliasOrLink(URL)
    case overlappingSource(URL)

    /// These reach the menu directly when a person adds a source, so they are written for people.
    public var errorDescription: String? {
        switch self {
        case .notFileURL: return "来源必须是本机文件夹路径。"
        case .notDirectory(let url): return "所选路径不是文件夹：\(url.path)"
        case .aliasOrLink(let url): return "不能把替身或符号链接配置为来源：\(url.path)"
        case .overlappingSource(let url): return "该来源与已有来源重叠：\(url.path)"
        }
    }
}
