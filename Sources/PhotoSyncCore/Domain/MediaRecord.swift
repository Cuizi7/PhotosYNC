import Foundation

public enum FileState: String, Codable, Sendable {
    case pending
    case importing
    case imported
    case skipped
}

public enum SkipReason: String, Codable, Sendable {
    case suspectedDuplicate
    case sourceChanged
    case unsupportedFormat
}

public enum MediaKind: String, Codable, Sendable {
    case image
    case video
}

public struct FileStamp: Codable, Equatable, Sendable {
    public let size: Int64
    public let modifiedNanoseconds: Int64

    public init(size: Int64, modifiedNanoseconds: Int64) {
        self.size = size
        self.modifiedNanoseconds = modifiedNanoseconds
    }
}

public struct MediaMetadata: Codable, Equatable, Sendable {
    public let filename: String
    public let kind: MediaKind
    public let captureSecond: Int64?
    public let rawCaptureTime: String?
    public let rawCaptureOffset: String?
    public let make: String?
    public let model: String?
    public let width: Int?
    public let height: Int?
    public let duration: Double?

    public init(
        filename: String,
        kind: MediaKind,
        captureSecond: Int64?,
        rawCaptureTime: String?,
        rawCaptureOffset: String? = nil,
        make: String?,
        model: String?,
        width: Int?,
        height: Int?,
        duration: Double?
    ) {
        self.filename = filename
        self.kind = kind
        self.captureSecond = captureSecond
        self.rawCaptureTime = rawCaptureTime
        self.rawCaptureOffset = rawCaptureOffset
        self.make = make
        self.model = model
        self.width = width
        self.height = height
        self.duration = duration
    }
}

public struct SourceFile: Codable, Equatable, Sendable {
    public let sourceID: UUID
    public let relativePath: String
    public let url: URL
    public let stamp: FileStamp
    public let metadata: MediaMetadata

    public init(sourceID: UUID, relativePath: String, url: URL, stamp: FileStamp, metadata: MediaMetadata) {
        self.sourceID = sourceID
        self.relativePath = relativePath
        self.url = url
        self.stamp = stamp
        self.metadata = metadata
    }
}

public struct MatchCandidate: Codable, Equatable, Sendable {
    public let key: String
    public let metadata: MediaMetadata

    public init(key: String, metadata: MediaMetadata) {
        self.key = key
        self.metadata = metadata
    }
}

public enum MatchDecision: Equatable, Sendable {
    case importNew
    case skip(candidateKeys: [String])
}
