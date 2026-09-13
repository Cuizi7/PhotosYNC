import Foundation

public struct DirectoryEntry: Sendable {
    public let url: URL
    public let isDirectory: Bool
    public let stamp: FileStamp?
    public let failure: String?

    public init(url: URL, isDirectory: Bool, stamp: FileStamp?, failure: String? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.stamp = stamp
        self.failure = failure
    }
}

public protocol DirectoryReading: Sendable {
    func entries(in directory: URL) async throws -> [DirectoryEntry]
    func stamp(of file: URL) async throws -> FileStamp
}

public struct DirectoryReader: DirectoryReading {
    private let sourceID: UUID
    private let executor: ReadExecutor
    private let attributes: @Sendable (URL, Set<URLResourceKey>) throws -> URLResourceValues

    public init(sourceID: UUID = UUID(), executor: ReadExecutor = .shared,
                attributes: @escaping @Sendable (URL, Set<URLResourceKey>) throws -> URLResourceValues = { try $0.resourceValues(forKeys: $1) }) {
        self.sourceID = sourceID
        self.executor = executor
        self.attributes = attributes
    }

    public func entries(in directory: URL) async throws -> [DirectoryEntry] {
        try await executor.execute(sourceID: sourceID) {
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey,
                .isHiddenKey,
                .isSymbolicLinkKey,
                .isPackageKey,
                .isAliasFileKey,
                .fileSizeKey,
                .contentModificationDateKey
            ]
            let verified = try SourceRegistry.normalizedURL(directory)
            let contents = try FileManager.default.contentsOfDirectory(
                at: verified,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            return contents.compactMap { url in
                do {
                let values = try attributes(url, keys)
                guard values.isHidden != true,
                      values.isSymbolicLink != true,
                      values.isAliasFile != true,
                      values.isPackage != true,
                      url.pathExtension.lowercased() != "photoslibrary" else {
                    return nil
                }
                let isDirectory = values.isDirectory == true
                return DirectoryEntry(
                    url: url,
                    isDirectory: isDirectory,
                    stamp: isDirectory ? nil : try fileStamp(values: values)
                )
                } catch {
                    return DirectoryEntry(url: url, isDirectory: false, stamp: nil, failure: error.localizedDescription)
                }
            }
            .sorted { $0.url.path < $1.url.path }
        }
    }

    public func stamp(of file: URL) async throws -> FileStamp {
        try await executor.execute(sourceID: sourceID) {
            _ = try SourceRegistry.normalizedURL(file.deletingLastPathComponent())
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard fileAttributes[.type] as? FileAttributeType == .typeRegular else { throw DirectoryReaderError.missingFileAttributes }
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return try fileStamp(values: values)
        }
    }
}

private func fileStamp(values: URLResourceValues) throws -> FileStamp {
    guard let size = values.fileSize, let modified = values.contentModificationDate else {
        throw DirectoryReaderError.missingFileAttributes
    }
    return FileStamp(
        size: Int64(size),
        modifiedNanoseconds: Int64((modified.timeIntervalSince1970 * 1_000_000_000).rounded(.down))
    )
}

public enum DirectoryReaderError: Error {
    case missingFileAttributes
}
