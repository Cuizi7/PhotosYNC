import Foundation

public enum SourceRegistry {
    public static func normalizedURL(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw SourceRegistryError.notFileURL }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    public static func conflicts(_ first: URL, _ second: URL) -> Bool {
        let firstParts = first.pathComponents
        let secondParts = second.pathComponents
        return firstParts.starts(with: secondParts) || secondParts.starts(with: firstParts)
    }
}

public enum SourceRegistryError: Error, LocalizedError {
    case notFileURL
    case overlappingSource(URL)

    public var errorDescription: String? {
        switch self {
        case .notFileURL: return "A source must be a file URL."
        case .overlappingSource(let url): return "The source overlaps \(url.path)."
        }
    }
}
