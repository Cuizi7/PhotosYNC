import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

public protocol MetadataReading: Sendable {
    func read(url: URL, filename: String) async throws -> MediaMetadata
}

public enum MetadataError: Error {
    case unreadable
    case unsupported
}

public struct MetadataReader: MetadataReading {
    private let sourceID: UUID
    private let executor: ReadExecutor

    public init(sourceID: UUID = UUID(), executor: ReadExecutor = .shared) {
        self.sourceID = sourceID
        self.executor = executor
    }

    public func read(url: URL, filename: String) async throws -> MediaMetadata {
        if Self.classification(url) != "image" && Self.classification(url) != "video" {
            throw MetadataError.unsupported
        }
        if Self.classification(url) == "video" {
            return try await executor.executeAsync(sourceID: sourceID) {
                try await readVideo(url: url, filename: filename)
            }
        }
        return try await executor.execute(sourceID: sourceID) {
            try readImage(url: url, filename: filename)
        }
    }

    public static func classification(_ url: URL) -> String {
        if isRaw(url) { return "raw" }
        if ["xmp", "aae", "thm", "lrv", "srt"].contains(url.pathExtension.lowercased()) { return "sidecar" }
        // Stable built-in formats also work when LaunchServices type registration is unavailable.
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "jpe", "png", "gif", "tif", "tiff", "bmp", "heic", "heif", "webp", "ico", "jp2"].contains(ext) { return "image" }
        if ["mov", "mp4", "m4v", "avi", "mpeg", "mpg", "3gp", "3g2"].contains(ext) { return "video" }
        guard let type = UTType(filenameExtension: ext) else { return "unsupported" }
        if type.conforms(to: .movie) { return "video" }
        let supported = CGImageSourceCopyTypeIdentifiers() as! [String]
        if type.conforms(to: .image), supported.contains(type.identifier), !type.conforms(to: .svg) { return "image" }
        return "unsupported"
    }

    public static func captureSecond(rawCaptureTime: String?, offsetTimeOriginal: String?) -> Int64? {
        guard let rawCaptureTime, let offsetTimeOriginal,
              let date = parseDate(rawCaptureTime, offsetTimeOriginal: offsetTimeOriginal) else {
            return nil
        }
        return Int64(date.timeIntervalSince1970.rounded(.down))
    }

    public static func videoCaptureSecond(rawCaptureTime: String?) -> Int64? {
        parsedVideoCaptureSecond(rawCaptureTime)
    }

    private func readVideo(url: URL, filename: String) async throws -> MediaMetadata {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let creationDate = try await asset.load(.creationDate)
        let metadata = try await asset.load(.commonMetadata)
        let creationItem = creationDate ?? metadata.first(where: { $0.commonKey == .commonKeyCreationDate })
        let rawCaptureTime = try await creationItem?.load(.stringValue)
        let dimensions = try? await asset.load(.tracks).first(where: { $0.mediaType == .video })?.load(.naturalSize)
        return MediaMetadata(
            filename: filename,
            kind: .video,
            captureSecond: MetadataReader.videoCaptureSecond(rawCaptureTime: rawCaptureTime),
            rawCaptureTime: rawCaptureTime,
            rawCaptureOffset: videoOffset(rawCaptureTime),
            make: nil,
            model: nil,
            width: dimensions.map { Int(abs($0.width)) },
            height: dimensions.map { Int(abs($0.height)) },
            duration: duration.seconds.isFinite ? duration.seconds : nil
        )
    }
}

private func readImage(url: URL, filename: String) throws -> MediaMetadata {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else {
        throw MetadataError.unreadable
    }
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    let rawCaptureTime = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
    let offset = exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String
    return MediaMetadata(
        filename: filename,
        kind: .image,
        captureSecond: MetadataReader.captureSecond(rawCaptureTime: rawCaptureTime, offsetTimeOriginal: offset),
        rawCaptureTime: rawCaptureTime,
        rawCaptureOffset: offset,
        make: tiff?[kCGImagePropertyTIFFMake] as? String,
        model: tiff?[kCGImagePropertyTIFFModel] as? String,
        width: properties[kCGImagePropertyPixelWidth] as? Int,
        height: properties[kCGImagePropertyPixelHeight] as? Int,
        duration: nil
    )
}

private func parseDate(_ raw: String, offsetTimeOriginal: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss.SSSSSS"
    guard let timeZone = timeZone(offsetTimeOriginal) else { return nil }
    formatter.timeZone = timeZone
    return formatter.date(from: raw) ?? {
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: raw)
    }()
}

private func timeZone(_ offset: String) -> TimeZone? {
    let bytes = Array(offset.utf8)
    guard bytes.count == 6,
          bytes[0] == 43 || bytes[0] == 45,
          bytes[3] == 58,
          bytes[1...2].allSatisfy(isASCIIDigit),
          bytes[4...5].allSatisfy(isASCIIDigit),
          let hours = Int(String(decoding: bytes[1...2], as: UTF8.self)),
          let minutes = Int(String(decoding: bytes[4...5], as: UTF8.self)),
          hours <= 23,
          minutes <= 59 else { return nil }
    let seconds = (hours * 3_600 + minutes * 60) * (bytes[0] == 45 ? -1 : 1)
    return TimeZone(secondsFromGMT: seconds)
}

private func isASCIIDigit(_ byte: UInt8) -> Bool {
    byte >= 48 && byte <= 57
}

private func parsedVideoCaptureSecond(_ rawCaptureTime: String?) -> Int64? {
    guard let rawCaptureTime,
          let date = ISO8601DateFormatter().date(from: rawCaptureTime),
          videoOffset(rawCaptureTime) != nil else { return nil }
    return Int64(date.timeIntervalSince1970.rounded(.down))
}

private func videoOffset(_ rawCaptureTime: String?) -> String? {
    guard let rawCaptureTime else { return nil }
    if rawCaptureTime.hasSuffix("Z") { return "+00:00" }
    guard rawCaptureTime.count >= 6 else { return nil }
    let suffix = String(rawCaptureTime.suffix(6))
    return timeZone(suffix) == nil ? nil : suffix
}

private func isRaw(_ url: URL) -> Bool {
    let rawExtensions: Set<String> = [
        "3fr", "arw", "bay", "cap", "cr2", "cr3", "crw", "dcr", "dcs", "dng", "drf", "eip", "erf", "fff",
        "iiq", "k25", "kdc", "mdc", "mef", "mos", "mrw", "nef", "nrw", "obm", "orf", "pef", "ptx", "pxn",
        "r3d", "raf", "raw", "rwl", "rw2", "rwz", "sr2", "srf", "srw", "x3f"
    ]
    if rawExtensions.contains(url.pathExtension.lowercased()) { return true }
    guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
    return type.conforms(to: .rawImage)
}
