import Foundation

public struct DirectoryEntry: Sendable {
    public let url: URL
    public let isDirectory: Bool
    public let stamp: FileStamp?

    public init(url: URL, isDirectory: Bool, stamp: FileStamp?) {
        self.url = url
        self.isDirectory = isDirectory
        self.stamp = stamp
    }
}

public protocol DirectoryReading: Sendable {
    func entries(in directory: URL) async throws -> [DirectoryEntry]
    func stamp(of file: URL) async throws -> FileStamp
}

public struct DirectoryReader: DirectoryReading {
    public init() {}

    public func entries(in directory: URL) async throws -> [DirectoryEntry] {
        try await ReadExecutor.shared.execute(sourceID: directory.absoluteString) {
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey,
                .isHiddenKey,
                .isSymbolicLinkKey,
                .isPackageKey,
                .isAliasFileKey,
                .fileSizeKey,
                .contentModificationDateKey
            ]
            let contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            return try contents.compactMap { url in
                let values = try url.resourceValues(forKeys: keys)
                guard values.isHidden != true,
                      values.isSymbolicLink != true,
                      values.isAliasFile != true,
                      values.isPackage != true else {
                    return nil
                }
                let isDirectory = values.isDirectory == true
                return DirectoryEntry(
                    url: url,
                    isDirectory: isDirectory,
                    stamp: isDirectory ? nil : try fileStamp(values: values)
                )
            }
            .sorted { $0.url.path < $1.url.path }
        }
    }

    public func stamp(of file: URL) async throws -> FileStamp {
        try await ReadExecutor.shared.execute(sourceID: file.absoluteString) {
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
