import Foundation

public enum SourceRegistry {
    public static func normalizedURL(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw SourceRegistryError.notFileURL }
        let standardized = url.standardizedFileURL
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

    public var errorDescription: String? {
        switch self {
        case .notFileURL: return "A source must be a file URL."
        case .notDirectory(let url): return "The source is not a directory: \(url.path)."
        case .aliasOrLink(let url): return "Aliases and symbolic links cannot be configured as sources: \(url.path)."
        case .overlappingSource(let url): return "The source overlaps \(url.path)."
        }
    }
}
