import AVFoundation
import Foundation
import ImageIO

public protocol MetadataReading: Sendable {
    func read(url: URL, filename: String) async throws -> MediaMetadata
}

public enum MetadataError: Error {
    case unreadable
    case unsupported
}

public struct MetadataReader: MetadataReading {
    public init() {}

    public func read(url: URL, filename: String) async throws -> MediaMetadata {
        if isRaw(url) {
            throw MetadataError.unsupported
        }
        if isVideo(url) {
            return try await readVideo(url: url, filename: filename)
        }
        return try await ReadExecutor.shared.execute(sourceID: url.absoluteString) {
            try readImage(url: url, filename: filename)
        }
    }

    public static func captureSecond(rawCaptureTime: String?, offsetTimeOriginal: String?) -> Int64? {
        guard let rawCaptureTime, let offsetTimeOriginal,
              let date = parseDate(rawCaptureTime, offsetTimeOriginal: offsetTimeOriginal) else {
            return nil
        }
        return Int64(date.timeIntervalSince1970.rounded(.down))
    }

    private func readVideo(url: URL, filename: String) async throws -> MediaMetadata {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let metadata = try await asset.load(.commonMetadata)
        let rawCaptureTime = metadata.first(where: { $0.commonKey == .commonKeyCreationDate })?.stringValue
        let dimensions = try? await asset.load(.tracks).first(where: { $0.mediaType == .video })?.load(.naturalSize)
        return MediaMetadata(
            filename: filename,
            kind: .video,
            captureSecond: nil,
            rawCaptureTime: rawCaptureTime,
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
    guard offset.count == 6,
          let sign = offset.first,
          sign == "+" || sign == "-",
          offset.dropFirst().dropLast(3).allSatisfy({ $0.isNumber }),
          offset.suffix(2).allSatisfy({ $0.isNumber }) else { return nil }
    let hours = Int(offset.dropFirst().prefix(2))!
    let minutes = Int(offset.suffix(2))!
    let seconds = (hours * 3_600 + minutes * 60) * (sign == "-" ? -1 : 1)
    return TimeZone(secondsFromGMT: seconds)
}

private func isRaw(_ url: URL) -> Bool {
    ["arw", "cr2", "cr3", "dng", "nef", "orf", "raf", "rw2"].contains(url.pathExtension.lowercased())
}

private func isVideo(_ url: URL) -> Bool {
    ["avi", "m4v", "mov", "mp4", "mpeg", "mpg"].contains(url.pathExtension.lowercased())
}
