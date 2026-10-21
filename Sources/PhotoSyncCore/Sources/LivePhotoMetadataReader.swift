import AVFoundation
import CoreMedia
import Foundation
import ImageIO

public protocol LivePhotoMetadataReading: Sendable {
    func inspect(url: URL, kind: MediaKind) async throws -> LivePhotoInspection
    func inspect(resource: LivePhotoResourceLease, kind: MediaKind) async throws -> LivePhotoInspection
}
public extension LivePhotoMetadataReading {
    func inspect(resource: LivePhotoResourceLease, kind: MediaKind) async throws -> LivePhotoInspection {
        try await inspect(url: resource.url, kind: kind)
    }
}

/// Reads encoded metadata only. Timed metadata tracks are read without video-frame decoding.
public struct LivePhotoMetadataReader: LivePhotoMetadataReading {
    private let sourceID: UUID
    private let executor: ReadExecutor
    private let beforeRead: (@Sendable () -> Void)?
    private static let stillImageIdentifier = "mdta/com.apple.quicktime.still-image-time"

    public init(sourceID: UUID = UUID(), executor: ReadExecutor = .shared) {
        self.sourceID = sourceID; self.executor = executor; beforeRead = nil
    }

    init(sourceID: UUID = UUID(), executor: ReadExecutor, beforeRead: @escaping @Sendable () -> Void) {
        self.sourceID = sourceID; self.executor = executor; self.beforeRead = beforeRead
    }

    public func inspect(resource: LivePhotoResourceLease, kind: MediaKind) async throws -> LivePhotoInspection {
        try await inspect(url: resource.url, kind: kind, retaining: resource)
    }
    public func inspect(url: URL, kind: MediaKind) async throws -> LivePhotoInspection {
        try await inspect(url: url, kind: kind, retaining: nil)
    }
    private func inspect(url: URL, kind: MediaKind, retaining: LivePhotoResourceLease?) async throws -> LivePhotoInspection {
        if kind == .image {
            return try await executor.execute(sourceID: sourceID) {
                defer { withExtendedLifetime(retaining) {} }
                beforeRead?()
                try Self.validate(url)
                guard let image = CGImageSourceCreateWithURL(url as CFURL, nil),
                      CGImageSourceGetCount(image) > 0,
                      let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any] else { throw MetadataError.unreadable }
                let apple = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any]
                // Apple Maker Note tag 17 is a format convention, not a named ImageIO constant.
                guard let identifier = Self.nonempty(apple?["17"] as? String) else { return .noIdentifier }
                return .identified(.init(contentIdentifier: identifier, role: .photo))
            }
        }
        return try await executor.executeAsync(sourceID: sourceID) {
            defer { withExtendedLifetime(retaining) {} }
            beforeRead?()
            try Self.validate(url)
            let asset = AVURLAsset(url: url)
            let metadata = try await asset.loadMetadata(for: .quickTimeMetadata)
            var identifiers = Set<String>()
            for item in metadata where item.identifier == .quickTimeMetadataContentIdentifier {
                if let value = Self.nonempty(try await item.load(.stringValue)) { identifiers.insert(value) }
            }
            guard !identifiers.isEmpty else {
                // Force validation rather than treating an unreadable MOV as ordinary media.
                guard try await asset.load(.isReadable) else { throw MetadataError.unreadable }
                return .noIdentifier
            }
            guard identifiers.count == 1, let identifier = identifiers.first else { return .unresolved("视频包含多个拍摄标识") }
            let tracks = try await asset.loadTracks(withMediaType: .metadata)
            for track in tracks {
                let formats = try await track.load(.formatDescriptions)
                let declared = formats.flatMap { CMMetadataFormatDescriptionGetIdentifiers($0) as? [String] ?? [] }
                guard declared.contains(Self.stillImageIdentifier) else { continue }
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                guard reader.canAdd(output) else { throw MetadataError.unreadable }
                reader.add(output)
                let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
                guard reader.startReading() else { throw reader.error ?? MetadataError.unreadable }
                defer { reader.cancelReading() }
                while let group = adaptor.nextTimedMetadataGroup() {
                    try Task.checkCancellation()
                    if group.items.contains(where: { $0.identifier?.rawValue == Self.stillImageIdentifier }) {
                        let time = group.timeRange.start.seconds
                        guard time.isFinite else { return .unresolved("动态照片时间样本无效") }
                        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
                        return .identified(.init(contentIdentifier: identifier, role: .motion, stillImageTime: time, hasAudio: hasAudio))
                    }
                }
                if reader.status == .failed { throw reader.error ?? MetadataError.unreadable }
            }
            return .unresolved("视频有拍摄标识，但缺少可读动态照片时间样本")
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func validate(_ url: URL) throws {
        _ = try SourceRegistry.normalizedURL(url.deletingLastPathComponent())
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw MetadataError.unreadable }
    }
}
