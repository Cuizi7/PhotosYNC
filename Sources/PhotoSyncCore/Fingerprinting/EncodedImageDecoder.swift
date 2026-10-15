import Foundation
import ImageIO

/// The Source and Photos encoded-byte paths use exactly the same ImageIO math.
enum EncodedImageDecoder {
    static func decode(url: URL, configuration: DedupConfiguration, decodedAllowance allowance: Int64) throws -> SourceImage {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else {
            throw MetadataError.unreadable
        }
        var eligibility: RepresentationEligibility
        if CGImageSourceGetCount(source) != 1 { eligibility = .conservative(.multiFrameOrCompound) }
        else if ["public.jpeg", "public.png", "public.heic", "public.heif"].contains(type) { eligibility = .safeSingleFrame }
        else { eligibility = .conservative(.unverifiedContainer) }
        if eligibility == .safeSingleFrame {
            // Header facts precede eager decode. Four channels, component
            // storage rounded up to bytes, and aligned rows conservatively
            // estimate native backing; opaque ImageIO storage is measured
            // separately by release resource validation.
            guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  let depth = properties[kCGImagePropertyDepth] as? Int,
                  width > 0, height > 0, (1...16).contains(depth) else { throw MetadataError.unreadable }
            let (rowBytes, rowOverflow) = Int64(width).multipliedReportingOverflow(by: Int64(((depth + 7) / 8) * 4))
            let (padded, paddingOverflow) = rowBytes.addingReportingOverflow(127)
            let (estimate, sizeOverflow) = (padded / 128 * 128).multipliedReportingOverflow(by: Int64(height))
            guard !rowOverflow, !paddingOverflow, !sizeOverflow, estimate > 0 else {
                throw MetadataError.unreadable
            }
            if estimate > allowance { eligibility = .conservative(.decodedResourceLimit) }
        }
        let image: CGImage
        switch eligibility {
        case .safeSingleFrame:
            guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw MetadataError.unreadable }
            let long = max(width, height), short = min(width, height)
            let decodedSide = Int(sqrt(Double(allowance) / (4 * Double(short) / Double(long))))
            let bounded = min(4096, long, decodedSide)
            guard bounded >= 1, let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: bounded,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceShouldCacheImmediately: false
            ] as CFDictionary) else { throw MetadataError.unreadable }
            image = decoded
        case .conservative:
            // Validate readability without inference. A complete image
            // container with unverified content or excessive native backing
            // is imported as original bytes. This bounded readability probe
            // never enters R2/inference or supplies comparable dimensions.
            guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: configuration.fingerprint.inputSide,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary) else { throw MetadataError.unreadable }
            image = decoded
        }
        guard CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              image.height > 0, image.bytesPerRow > 0,
              Int64(image.bytesPerRow) <= allowance / Int64(image.height) else { throw MetadataError.unreadable }
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        return SourceImage(image: image, orientation: orientation, eligibility: eligibility)
    }
}
