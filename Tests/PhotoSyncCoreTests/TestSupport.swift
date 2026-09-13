import Foundation

enum TestSupport {
    static func unixSecond(from date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }
}

func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PhotoSyncTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
