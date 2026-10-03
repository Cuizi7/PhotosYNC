import CoreGraphics
import CoreML
import ImageIO
import XCTest
import PhotoSyncCore

private final class PhysicalStartCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }

    func current() -> Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

final class FingerprintTests: XCTestCase {
    private func configuration(side: Int = 4) throws -> FingerprintConfiguration {
        try FingerprintConfiguration(modelSHA256: String(repeating: "a", count: 64), inputSide: side,
                                     resizeMode: .stretchFullFrame, colorSpace: "sRGB",
                                     mean: [0, 0, 0], std: [1, 1, 1])
    }

    private func image(width: Int, height: Int, pixels: [UInt8], space: CGColorSpace? = nil) -> CGImage {
        let data = Data(pixels) as CFData
        let provider = CGDataProvider(data: data)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    func testAllEightEXIFOrientations() throws {
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255,
                               0, 0, 255, 255, 255, 255, 0, 255,
                               255, 0, 255, 255, 0, 255, 255, 255]
        let source = image(width: 2, height: 3, pixels: pixels)
        let corners: [CGImagePropertyOrientation: (Int, Int)] = [
            .up: (0, 5), .upMirrored: (1, 4), .down: (5, 0), .downMirrored: (4, 1),
            .leftMirrored: (0, 5), .right: (4, 1), .rightMirrored: (5, 0), .left: (1, 4),
        ]
        for (orientation, indices) in corners {
            let tensor = try ImagePreprocessor.prepare(image: source, orientation: orientation,
                                                       configuration: configuration(side: 12))
            let values = tensor.dataPointer.bindMemory(to: Float.self, capacity: tensor.count)
            for channel in 0..<3 {
                let plane = channel * 12 * 12
                XCTAssertEqual(values[plane], Float(pixels[indices.0 * 4 + channel]) / 255,
                               accuracy: 0.08, "top-left orientation \(orientation.rawValue)")
                XCTAssertEqual(values[plane + 143], Float(pixels[indices.1 * 4 + channel]) / 255,
                               accuracy: 0.08, "bottom-right orientation \(orientation.rawValue)")
            }
        }
    }

    func testP3AndSRGBSameVisibleColorUseSamePipeline() throws {
        let srgb = image(width: 1, height: 1, pixels: [128, 64, 32, 255])
        let p3Space = CGColorSpace(name: CGColorSpace.displayP3)!
        let matchingP3 = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 components: [128.0 / 255, 64.0 / 255, 32.0 / 255, 1])!
            .converted(to: p3Space, intent: .defaultIntent, options: nil)!
        let p3Pixels = matchingP3.components!.map { UInt8((min(1, max(0, $0)) * 255).rounded()) }
        let p3 = image(width: 1, height: 1, pixels: p3Pixels, space: p3Space)
        let a = try ImagePreprocessor.prepare(image: srgb, orientation: .up, configuration: configuration())
        let b = try ImagePreprocessor.prepare(image: p3, orientation: .up, configuration: configuration())
        let av = a.dataPointer.bindMemory(to: Float.self, capacity: a.count)
        let bv = b.dataPointer.bindMemory(to: Float.self, capacity: b.count)
        XCTAssertEqual(av[0], 128.0 / 255.0, accuracy: 0.02)
        XCTAssertEqual(av[0], bv[0], accuracy: 0.02)
        XCTAssertEqual(av[16], bv[16], accuracy: 0.02)
        XCTAssertEqual(av[32], bv[32], accuracy: 0.02)
        XCTAssertTrue((0..<a.count).allSatisfy { av[$0].isFinite && bv[$0].isFinite })
    }

    func testWideImageRetainsBothEdges() throws {
        var pixels = [UInt8](repeating: 0, count: 32 * 4)
        for x in 0..<32 { pixels[x * 4 + 3] = 255 }
        pixels[0] = 255
        pixels[(31 * 4) + 2] = 255
        let tensor = try ImagePreprocessor.prepare(image: image(width: 32, height: 1, pixels: pixels),
                                                   orientation: .up, configuration: configuration(side: 32))
        let values = tensor.dataPointer.bindMemory(to: Float.self, capacity: tensor.count)
        XCTAssertGreaterThan(values[0], 0.5)
        XCTAssertGreaterThan(values[2 * 32 * 32 + 31], 0.5)
    }

    func testInvalidVectorsRejected() throws {
        XCTAssertThrowsError(try Fingerprint(version: "unit", values: Array(repeating: 1, count: 1023)))
        XCTAssertThrowsError(try Fingerprint(version: "unit", values: Array(repeating: 0, count: 1024)))
        var nan = Array(repeating: Float(1), count: 1024)
        nan[7] = .nan
        XCTAssertThrowsError(try Fingerprint(version: "unit", values: nan))
    }

    func testTinyGeneratedCoreMLModelLoadsAndPredicts() async throws {
        // Generated offline with Torch 2.13/Core ML Tools 9: flatten 1x3x4x4, append 976 ones,
        // convert as macOS 13 ML Program Float32. The 5.9 KB package has no SSCD weights.
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/FingerprintTiny.mlpackage")
        let hash = try XCTUnwrap(CoreMLFingerprinter.packageSHA256(fixture))
        XCTAssertEqual(hash, "1ba8818cbbe2c89706e09026534f3edba69993d17739e4369d2cf881aff96612")
        let configuration = try FingerprintConfiguration(modelSHA256: hash, inputSide: 4,
                                                        resizeMode: .stretchFullFrame,
                                                        colorSpace: "sRGB", mean: [0, 0, 0], std: [1, 1, 1])
        let fingerprinter = try CoreMLFingerprinter(modelURL: fixture, configuration: configuration)
        let source = image(width: 1, height: 1, pixels: [255, 0, 0, 255])
        let output = try await fingerprinter.fingerprint(image: source, orientation: .up)
        XCTAssertEqual(output.version, configuration.version)
        XCTAssertEqual(output.values.count, 1024)
        XCTAssertEqual(output.values.reduce(0.0) { $0 + $1 * $1 }, 1, accuracy: 0.0001)
    }

    func testCancelledWaitDoesNotStartSecondPhysicalInference() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let starts = PhysicalStartCounter()
        let fingerprinter = CoreMLFingerprinter(configuration: try configuration()) { _ in
            let count = starts.increment()
            if count == 1 { entered.signal(); release.wait() }
            return Array(repeating: 1, count: 1024)
        }
        let source = image(width: 1, height: 1, pixels: [255, 0, 0, 255])
        let first = Task { try await fingerprinter.fingerprint(image: source, orientation: .up) }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        first.cancel()
        let second = Task { try await fingerprinter.fingerprint(image: source, orientation: .up) }
        let before = starts.current()
        XCTAssertEqual(before, 1)
        release.signal()
        _ = try? await first.value
        _ = try await second.value
        let after = starts.current()
        XCTAssertEqual(after, 2)
    }
}
