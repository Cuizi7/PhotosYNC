import Foundation

public final class RunLogger: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "PhotoSync.RunLogger")
    private var reportedFailure = false
    private let maximumFiles = 10
    private let maximumBytes = 10 * 1024 * 1024

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func log(_ fields: [String: String], at date: Date = Date()) {
        queue.async { [weak self] in self?.append(fields, at: date) }
    }

    private func append(_ fields: [String: String], at date: Date) {
        do {
            let url = directory.appendingPathComponent("photo-sync.jsonl")
            try rotateIfNeeded(url)
            var entry = fields
            entry["timestamp"] = ISO8601DateFormatter().string(from: date)
            let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) + Data([0x0A])
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            guard !reportedFailure else { return }
            reportedFailure = true
            fputs("PhotoSync logging failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private func rotateIfNeeded(_ url: URL) throws {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size >= maximumBytes else { return }
        let manager = FileManager.default
        let oldest = directory.appendingPathComponent("photo-sync.\(maximumFiles - 1).jsonl")
        if manager.fileExists(atPath: oldest.path) { try manager.removeItem(at: oldest) }
        for index in stride(from: maximumFiles - 2, through: 1, by: -1) {
            let old = directory.appendingPathComponent("photo-sync.\(index).jsonl")
            let next = directory.appendingPathComponent("photo-sync.\(index + 1).jsonl")
            if manager.fileExists(atPath: old.path) {
                try manager.moveItem(at: old, to: next)
            }
        }
        let first = directory.appendingPathComponent("photo-sync.1.jsonl")
        if manager.fileExists(atPath: first.path) { try manager.removeItem(at: first) }
        try manager.moveItem(at: url, to: first)
    }
}
