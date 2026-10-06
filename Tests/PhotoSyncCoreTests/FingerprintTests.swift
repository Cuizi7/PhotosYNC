import CoreGraphics
import CoreML
import ImageIO
import XCTest
@testable import PhotoSyncCore

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

    func testStoredFloat32DecodePreservesBitsAndHandlesByteViewOffsets() throws {
        // Literal little-endian facts: 1, negative zero, smallest positive subnormal.
        // Their squared norm rounds to 1; decoding must not renormalize or lose bits.
        let payload = Data([0, 0, 128, 63, 0, 0, 0, 128, 1, 0, 0, 0] + [UInt8](repeating: 0, count: 4084))
        var framed = Data([0xff]); framed.append(payload)
        let decoded = try Fingerprint(version: "v1", littleEndianFloat32: framed.dropFirst())
        XCTAssertEqual(decoded.values[0].bitPattern, 0x3f800000)
        XCTAssertEqual(decoded.values[1].bitPattern, 0x80000000)
        XCTAssertEqual(decoded.values[2].bitPattern, 1)
        XCTAssertEqual(decoded.littleEndianFloat32, payload)
        XCTAssertThrowsError(try Fingerprint(version: "", littleEndianFloat32: payload))
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
        XCTAssertEqual(hash, "a29f3271363d7740d0d4cbd29926aec5974877c329278fbc603af4f8da4b9bc6")
        let configuration = try FingerprintConfiguration(modelSHA256: hash, inputSide: 4,
                                                        resizeMode: .stretchFullFrame,
                                                        colorSpace: "sRGB", mean: [0, 0, 0], std: [1, 1, 1])
        let fingerprinter = try CoreMLFingerprinter(researchCPUOnlyModelURL: fixture, configuration: configuration)
        let source = image(width: 1, height: 1, pixels: [255, 0, 0, 255])
        let output = try await fingerprinter.fingerprint(image: source, orientation: .up)
        XCTAssertEqual(output.version, configuration.version)
        XCTAssertEqual(output.values.count, 1024)
        XCTAssertEqual(output.values.reduce(0.0) { $0 + $1 * $1 }, 1, accuracy: 0.0001)
    }

    func testPackageHashSeparatesBinaryFileBoundaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.mlpackage")
        let second = root.appendingPathComponent("second.mlpackage")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data([120, 0, 98, 0, 121]).write(to: first.appendingPathComponent("a"))
        try Data([120]).write(to: second.appendingPathComponent("a"))
        try Data([121]).write(to: second.appendingPathComponent("b"))
        XCTAssertEqual(CoreMLFingerprinter.packageSHA256(first),
                       "687b7c969279950d5afa6a2e23eade95c6b35c79bd5ed2abe9cab59f9bba70bd")
        XCTAssertEqual(CoreMLFingerprinter.packageSHA256(second),
                       "fc30ed02e8ac87e6272d4d692bb62d5e7580638df5052fa841943d848c5b373b")
    }

    func testCancelledWaitDoesNotStartSecondPhysicalInference() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let secondSubmitted = DispatchSemaphore(value: 0)
        let secondPhysicalStart = DispatchSemaphore(value: 0)
        let starts = PhysicalStartCounter()
        let submissions = PhysicalStartCounter()
        let fingerprinter = CoreMLFingerprinter(configuration: try configuration(), predict: { _ in
            let count = starts.increment()
            if count == 1 { entered.signal(); release.wait() }
            if count == 2 { secondPhysicalStart.signal() }
            return Array(repeating: 1, count: 1024)
        }, onSubmitted: {
            if submissions.increment() == 2 { secondSubmitted.signal() }
        })
        let source = image(width: 1, height: 1, pixels: [255, 0, 0, 255])
        let first = Task { try await fingerprinter.fingerprint(image: source, orientation: .up) }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        first.cancel()
        let second = Task { try await fingerprinter.fingerprint(image: source, orientation: .up) }
        XCTAssertEqual(secondSubmitted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(secondPhysicalStart.wait(timeout: .now() + 0.5), .timedOut)
        let before = starts.current()
        XCTAssertEqual(before, 1)
        release.signal()
        do {
            _ = try await first.value
            XCTFail("Cancelled waiter must report cancellation")
        } catch is CancellationError {
            // The physical slot remains occupied until the first predictor returns.
        }
        _ = try await second.value
        let after = starts.current()
        XCTAssertEqual(after, 2)
    }
}

private final class P12Session: ModelPredictionSession, @unchecked Sendable {
    let prediction: (MLMultiArray) throws -> [Float]
    let released: () -> Void
    init(prediction: @escaping (MLMultiArray) throws -> [Float], released: @escaping () -> Void = {}) {
        self.prediction = prediction; self.released = released
    }
    func predict(_ input: MLMultiArray) throws -> [Float] { try prediction(input) }
    deinit { released() }
}

extension FingerprintTests {
    private func golden() -> [ModelSelfTestCase] {
        (0..<4).map { _ in .init(input: Data(repeating: 0, count: 3 * 4 * 4 * 4),
            reference: [1] + Array(repeating: 0, count: 1023)) }
    }
    func testSelfTestFailureSelectsGPUBeforePublishingFingerprint() async throws {
        let released = PhysicalStartCounter(), loads = PhysicalStartCounter()
        let model = try CoreMLFingerprinter(configuration: configuration(), selfTests: golden(), factory: { backend in
            _ = loads.increment()
            if backend == .cpuAndGPU { XCTAssertEqual(released.current(), 1, "old instance released first") }
            return P12Session(prediction: { _ in
                backend == .cpuAndNeuralEngine ? [0, 1] + Array(repeating: 0, count: 1022) : [1] + Array(repeating: 0, count: 1023)
            }, released: { _ = released.increment() })
        })
        let output = try await model.fingerprint(image: image(width: 1, height: 1, pixels: [0, 0, 0, 255]), orientation: .up)
        XCTAssertEqual(output.values[0], 1)
        XCTAssertEqual(loads.current(), 2)
    }
    func testPredictionFailureFallsBackOnlyAfterPhysicalReturn() async throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let calls = PhysicalStartCounter(), released = PhysicalStartCounter(), loads = PhysicalStartCounter()
        let model = try CoreMLFingerprinter(configuration: configuration(), selfTests: golden(), factory: { backend in
            _ = loads.increment()
            if backend == .cpuAndGPU { XCTAssertEqual(released.current(), 1) }
            return P12Session(prediction: { _ in
                if backend == .cpuAndNeuralEngine && calls.increment() == 5 {
                    entered.signal(); release.wait(); throw ModelExecutionUnavailable(detail: "prediction")
                }
                return [1] + Array(repeating: 0, count: 1023)
            }, released: { _ = released.increment() })
        })
        let source = image(width: 1, height: 1, pixels: [0, 0, 0, 255])
        let task = Task { try await model.fingerprint(image: source, orientation: .up) }
        let didEnter = entered.wait(timeout: .now() + 2)
        XCTAssertEqual(didEnter, .success)
        XCTAssertEqual(loads.current(), 1)
        release.signal()
        _ = try await task.value
        XCTAssertEqual(loads.current(), 2)
    }
    func testCancelledPredictionDoesNotStartFallback() async throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let calls = PhysicalStartCounter(), loads = PhysicalStartCounter()
        let model = try CoreMLFingerprinter(configuration: configuration(), selfTests: golden(), factory: { _ in
            _ = loads.increment()
            return P12Session(prediction: { _ in
                if calls.increment() == 5 { entered.signal(); release.wait(); throw ModelExecutionUnavailable(detail: "prediction") }
                return [1] + Array(repeating: 0, count: 1023)
            })
        })
        let source = image(width: 1, height: 1, pixels: [0, 0, 0, 255])
        let task = Task { try await model.fingerprint(image: source, orientation: .up) }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        task.cancel(); release.signal()
        do { _ = try await task.value; XCTFail("canceled prediction") } catch is CancellationError { }
        XCTAssertEqual(loads.current(), 1)
    }
    func testIneligibleModelNeverStartsLazyRecovery() async throws {
        let loads = PhysicalStartCounter()
        let model = try CoreMLFingerprinter(configuration: configuration(), selfTests: golden(), factory: { _ in
            _ = loads.increment(); return P12Session(prediction: { _ in [1] + Array(repeating: 0, count: 1023) })
        })
        model.setExecutionEligible(false)
        do { _ = try await model.fingerprint(image: image(width: 1, height: 1, pixels: [0,0,0,255]), orientation: .up); XCTFail("no lazy recovery while ineligible") }
        catch is CancellationError { }
        XCTAssertEqual(loads.current(), 0)
        model.setExecutionEligible(true); try await model.prepareExecution(); XCTAssertEqual(loads.current(), 1)
    }
    func testIneligibleQueuedPredictionDoesNotConsumePhysicalSlotAndCompletedResultSurvives() async throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), submitted = DispatchSemaphore(value: 0)
        let calls = PhysicalStartCounter(), queued = PhysicalStartCounter()
        let model = CoreMLFingerprinter(configuration: try configuration(), predict: { _ in
            if calls.increment() == 1 { entered.signal(); release.wait() }
            return [1] + Array(repeating: 0, count: 1023)
        }, onSubmitted: { if queued.increment() == 2 { submitted.signal() } })
        let source = image(width: 1, height: 1, pixels: [0,0,0,255])
        let first = Task { try await model.fingerprint(image: source, orientation: .up) }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let second = Task { try await model.fingerprint(image: source, orientation: .up) }
        XCTAssertEqual(submitted.wait(timeout: .now() + 5), .success)
        model.setExecutionEligible(false); XCTAssertEqual(calls.current(), 1)
        release.signal()
        let completed = try await first.value; XCTAssertEqual(completed.values[0], 1, "successful physical work is retained")
        do { _ = try await second.value; XCTFail("queued work must wait for eligibility") } catch is CancellationError { }
        XCTAssertEqual(calls.current(), 1)
    }
    func testEligibilityLossStopsNewSelfTestsWithoutStartingFallback() async throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let calls = PhysicalStartCounter(), loads = PhysicalStartCounter()
        let model = try CoreMLFingerprinter(configuration: configuration(), selfTests: golden(), factory: { _ in
            _ = loads.increment(); return P12Session(prediction: { _ in
                if calls.increment() == 1 { entered.signal(); release.wait() }
                return [1] + Array(repeating: 0, count: 1023)
            })
        })
        let task = Task { try await model.prepareExecution() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        model.setExecutionEligible(false); release.signal()
        do { try await task.value; XCTFail("partial session cannot continue self-tests") } catch is CancellationError { }
        XCTAssertEqual(calls.current(), 1); XCTAssertEqual(loads.current(), 1)
        model.setExecutionEligible(true); try await model.prepareExecution(); XCTAssertEqual(loads.current(), 2)
    }
    func testBackendResourceCorruptionIsNotRetryableHardwareFailure() async throws {
        let resources = try DedupConfiguration.bundledResourceDirectory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["execution-policy.json", "ModelSelfTest"] {
            try FileManager.default.copyItem(at: resources.appendingPathComponent(name), to: root.appendingPathComponent(name))
        }
        let policy = try ModelExecutionPolicy.loadValidated(resourceDirectory: root)
        let selfTest = try ModelSelfTest.loadValidated(resourceDirectory: root, policy: policy)
        let config = try DedupConfiguration.loadValidated(resourceDirectory: resources)
        var altered = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("execution-policy.json"))) as! [String: Any]
        altered["arm64"] = ["cpuAndGPU"]
        let unchecked = try JSONDecoder().decode(ModelExecutionPolicy.self, from: JSONSerialization.data(withJSONObject: altered))
        XCTAssertThrowsError(try CoreMLFingerprinter(modelURL: resources.appendingPathComponent("SSCDLarge.mlpackage"),
            configuration: config.fingerprint, policy: unchecked, selfTest: selfTest))
        try Data([0]).write(to: root.appendingPathComponent("ModelSelfTest/input-0.f32"))
        XCTAssertThrowsError(try ModelSelfTest.loadValidated(resourceDirectory: root, policy: policy)) {
            XCTAssertFalse($0 is ModelExecutionUnavailable)
        }
        let loads = PhysicalStartCounter()
        let model = try CoreMLFingerprinter(configuration: configuration(), selfTests: golden(), factory: { _ in
            _ = loads.increment(); throw AdvancedDedupError.invalidConfiguration
        })
        do { _ = try await model.fingerprint(image: image(width: 1, height: 1, pixels: [0,0,0,255]), orientation: .up); XCTFail("corruption") }
        catch { XCTAssertEqual(error as? AdvancedDedupError, .invalidConfiguration) }
        XCTAssertEqual(loads.current(), 1)
    }
    func testBothBackendsUnavailableNeverUsesCPU() async throws {
        let calls = PhysicalStartCounter()
        let model = try CoreMLFingerprinter(configuration: configuration(), selfTests: golden(), factory: { _ in
            _ = calls.increment()
            return P12Session(prediction: { _ in throw ModelExecutionUnavailable(detail: "unavailable") })
        })
        do { _ = try await model.fingerprint(image: image(width: 1, height: 1, pixels: [0,0,0,255]), orientation: .up); XCTFail("must wait") }
        catch is ModelExecutionUnavailable { }
        XCTAssertEqual(calls.current(), 2)
    }
}
