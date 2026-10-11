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

struct SourceImage: @unchecked Sendable {
    let image: CGImage
    let orientation: CGImagePropertyOrientation
    let eligibility: RepresentationEligibility
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

    /// Restore the bound R2 full-frame bounded ImageIO decode before its common
    /// stretch/orientation/color pipeline. Reserve the full allowance first;
    /// original-backing preflight still decides conservative oversize admission.
    func readForFingerprint(url: URL, configuration: DedupConfiguration, budget: ImageWorkBudget) async throws -> ImageWorkResult<SourceImage> {
        let allowance = configuration.resources.maxDecodedBytes
        return try await executor.executeImage(sourceID: sourceID, budget: budget,
            bytes: allowance, limits: configuration.resources) {
            _ = try SourceRegistry.normalizedURL(url.deletingLastPathComponent())
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw MetadataError.unreadable }
            guard Self.classification(url) == "image" else { throw MetadataError.unreadable }
            return try EncodedImageDecoder.decode(url: url, configuration: configuration, decodedAllowance: allowance)
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
        do {
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
        } catch {
            throw Self.videoMetadataError(error)
        }
    }

    /// Keep the underlying AVFoundation and OSStatus codes in diagnostics. The localized system
    /// sentence can be generic even when the nested error identifies a repeatable file failure.
    static func videoMetadataError(_ error: Error) -> NSError {
        var codes: [String] = []
        var current: NSError? = error as NSError
        for _ in 0..<3 {
            guard let failure = current else { break }
            codes.append("\(failure.domain) \(failure.code)")
            current = failure.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return NSError(domain: "PhotoSync.VideoMetadata", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Video metadata could not be read (\(codes.joined(separator: " <- "))).",
            NSUnderlyingErrorKey: error
        ])
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
    guard matches(raw, pattern: "^[0-9]{4}:[0-9]{2}:[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?$"),
          let timeZone = timeZone(offsetTimeOriginal) else { return nil }

    let base = String(raw.prefix(19))
    guard let date = validatedCalendarSecond(base, format: "yyyy:MM:dd HH:mm:ss", timeZone: timeZone) else {
        return nil
    }
    return date
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
          matches(rawCaptureTime, pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$"),
          let offset = videoOffset(rawCaptureTime),
          let timeZone = timeZone(offset) else { return nil }

    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let integral = ISO8601DateFormatter()
    integral.formatOptions = [.withInternetDateTime]
    guard (fractional.date(from: rawCaptureTime) ?? integral.date(from: rawCaptureTime)) != nil else {
        return nil
    }

    let base = String(rawCaptureTime.prefix(19))
    guard let integralDate = validatedCalendarSecond(base, format: "yyyy-MM-dd'T'HH:mm:ss", timeZone: timeZone) else {
        return nil
    }
    return Int64(integralDate.timeIntervalSince1970)
}

private func validatedCalendarSecond(_ value: String, format: String, timeZone: TimeZone) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    formatter.calendar = calendar
    formatter.timeZone = timeZone
    formatter.dateFormat = format
    formatter.isLenient = false
    guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
        return nil
    }
    return date
}

private func matches(_ value: String, pattern: String) -> Bool {
    guard let range = value.range(of: pattern, options: .regularExpression) else { return false }
    return range == value.startIndex..<value.endIndex
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
