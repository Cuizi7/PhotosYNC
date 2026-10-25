import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import Foundation

enum FixtureError: Error { case unavailable(String) }

func makeLivePhotoImage(at url: URL, identifier: String?, type: UTType = .jpeg) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    var properties: [String: Any] = [:]
    if let identifier { properties[kCGImagePropertyMakerAppleDictionary as String] = ["17": identifier] }
    CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw FixtureError.unavailable("JPEG fixture") }
}

func makeLivePhotoMotion(at url: URL, identifier: String?, timedSample: Bool = true, audio: Bool = false, duration: Double = 0.1) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    writer.movieTimeScale = 1000
    if let identifier {
        let item = AVMutableMetadataItem(); item.identifier = .quickTimeMetadataContentIdentifier
        item.value = identifier as NSString; item.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [item]
    }
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16])
    video.mediaTimeScale = 1000
    let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16])
    writer.add(video)
    var metadata: AVAssetWriterInput?
    var adaptor: AVAssetWriterInputMetadataAdaptor?
    if timedSample {
        var format: CMMetadataFormatDescription?
        let specs: [[String: Any]] = [[kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time", kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8 as String]]
        guard CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: specs as CFArray, formatDescriptionOut: &format) == noErr else { throw FixtureError.unavailable("metadata format") }
        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
        writer.add(input); metadata = input; adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
    }
    var audioInput: AVAssetWriterInput?
    var audioSample: CMSampleBuffer?
    if audio {
        var description = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else { throw FixtureError.unavailable("audio format") }
        var samples = [Float]()
        for frame in 0..<4410 {
            let phase: Double = Double(frame) * 2.0 * Double.pi * 440.0 / 44100.0
            samples.append(Float(sin(phase) * 0.1))
        }
        let bytes = samples.withUnsafeBytes { Data($0) }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block) == noErr, let block else { throw FixtureError.unavailable("audio block") }
        let copied = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44100), presentationTimeStamp: .zero, decodeTimeStamp: .invalid), size = 4
        guard copied == noErr, CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: samples.count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &audioSample) == noErr else { throw FixtureError.unavailable("audio sample") }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
        writer.add(input); audioInput = input
    }
    guard writer.startWriting() else { throw writer.error! }
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32ARGB, nil, &buffer)
    guard let buffer else { throw FixtureError.unavailable("pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, []); memset(CVPixelBufferGetBaseAddress(buffer), 120, CVPixelBufferGetDataSize(buffer)); CVPixelBufferUnlockBaseAddress(buffer, [])
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        var completed = false
        video.requestMediaDataWhenReady(on: DispatchQueue(label: "LivePhotoFixture.video")) {
            guard !completed, video.isReadyForMoreMediaData else { return }
            completed = true
            let ok = pixels.append(buffer, withPresentationTime: .zero) && pixels.append(buffer, withPresentationTime: CMTime(seconds: duration - 0.001, preferredTimescale: 1000))
            video.markAsFinished()
            if ok { continuation.resume() } else { continuation.resume(throwing: writer.error ?? FixtureError.unavailable("video sample")) }
        }
    }
    if let metadata, let adaptor {
        let item = AVMutableMetadataItem(); item.identifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.still-image-time")
        item.value = NSNumber(value: Int8(0)); item.dataType = kCMMetadataBaseDataType_SInt8 as String
        let group = AVTimedMetadataGroup(items: [item], timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 30)))
        guard adaptor.append(group) else { throw writer.error ?? FixtureError.unavailable("timed sample") }
        metadata.markAsFinished()
    }
    if let audioInput, let audioSample {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var finished = false
            audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "LivePhotoFixture.audio")) {
                guard !finished, audioInput.isReadyForMoreMediaData else { return }; finished = true
                let ok = audioInput.append(audioSample); audioInput.markAsFinished()
                if ok { continuation.resume() } else { continuation.resume(throwing: writer.error ?? FixtureError.unavailable("audio append")) }
            }
        }
    }
    writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 1000))
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in writer.finishWriting { continuation.resume() } }
    guard writer.status == .completed else { throw writer.error ?? FixtureError.unavailable("finish movie") }
}

// Explicit authoring tool. Frozen bytes, not re-encoding, are the normal test inputs.
@main enum GeneratePortableMedia {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw FixtureError.unavailable("expected new output directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.path) else { throw FixtureError.unavailable("output exists") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = "11111111-2222-3333-4444-555555555555"
        try makeLivePhotoImage(at: root.appendingPathComponent("paired.heic"), identifier: identity, type: .heic)
        try makeLivePhotoImage(at: root.appendingPathComponent("paired.jpg"), identifier: identity)
        try makeLivePhotoImage(at: root.appendingPathComponent("plain.jpg"), identifier: nil)
        try await makeLivePhotoMotion(at: root.appendingPathComponent("paired.mov"), identifier: identity, audio: true)
        try await makeLivePhotoMotion(at: root.appendingPathComponent("missing-time.mov"), identifier: identity, timedSample: false)
        for (name, duration) in [("below", 9.999), ("equal", 10.0), ("above", 10.001)] {
            try await makeLivePhotoMotion(at: root.appendingPathComponent(name + ".mov"), identifier: nil, timedSample: false, duration: duration)
        }
        try Data("PhotosYNC intentionally malformed test image".utf8).write(to: root.appendingPathComponent("corrupt.heic"))
        try Data("PhotosYNC intentionally malformed test movie".utf8).write(to: root.appendingPathComponent("corrupt.mov"))
    }
}
