import CoreGraphics
import CoreML
import CryptoKit
import Foundation
import ImageIO

public protocol ImageFingerprinting: Sendable {
    func fingerprint(image: CGImage, orientation: CGImagePropertyOrientation) async throws -> Fingerprint
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

private struct InferenceInput: @unchecked Sendable {
    // Immutable tensor ownership moves to the serial queue; no other task writes its storage.
    let tensor: MLMultiArray
}

public actor CoreMLFingerprinter: ImageFingerprinting {
    public let configuration: FingerprintConfiguration
    private let predict: @Sendable (MLMultiArray) throws -> [Float]
    // A single queue retains the physical slot until prediction returns, even when its waiter cancels.
    private let physicalQueue = DispatchQueue(label: "PhotoSyncCore.SSCD.physicalInference")

    public init(configuration: FingerprintConfiguration,
                predict: @escaping @Sendable (MLMultiArray) throws -> [Float]) {
        self.configuration = configuration
        self.predict = predict
    }

    public init(modelURL: URL, configuration: FingerprintConfiguration) throws {
        guard modelURL.pathExtension == "mlpackage",
              Self.packageSHA256(modelURL) == configuration.modelSHA256 else {
            throw AdvancedDedupError.modelMismatch
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let coreMLBuild = Bundle(for: MLModel.self).infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        // A package hash binds conversion SDK output; OS and Core ML runtime build bind compilation.
        let key = "\(configuration.modelSHA256)-\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)-\(coreMLBuild)"
        let cacheBase = ProcessInfo.processInfo.environment["PHOTOSYNC_MODEL_CACHE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("PhotoSyncCore-MLCache", isDirectory: true)
        let cache = cacheBase
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let compiledURL = cache.appendingPathComponent(key).appendingPathExtension("mlmodelc")
        if !FileManager.default.fileExists(atPath: compiledURL.path) {
            let compiled = try MLModel.compileModel(at: modelURL)
            let staging = cache.appendingPathComponent("\(key)-\(UUID().uuidString)").appendingPathExtension("mlmodelc")
            try FileManager.default.copyItem(at: compiled, to: staging)
            defer { try? FileManager.default.removeItem(at: staging) }
            do { try FileManager.default.moveItem(at: staging, to: compiledURL) }
            catch {
                guard FileManager.default.fileExists(atPath: compiledURL.path) else { throw error }
            }
        }
        let runtime = MLModelConfiguration()
        runtime.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: compiledURL, configuration: runtime)
        let input = model.modelDescription.inputDescriptionsByName["image"]?.multiArrayConstraint
        let output = model.modelDescription.outputDescriptionsByName["embedding"]?.multiArrayConstraint
        guard input?.shape.map(\.intValue) == [1, 3, configuration.inputSide, configuration.inputSide],
              output?.shape.reduce(1, { $0 * $1.intValue }) == 1024 else {
            throw AdvancedDedupError.invalidConfiguration
        }
        self.configuration = configuration
        self.predict = { tensor in
            let features = try MLDictionaryFeatureProvider(dictionary: ["image": tensor])
            guard let output = try model.prediction(from: features).featureValue(for: "embedding")?.multiArrayValue,
                  output.count == 1024 else { throw AdvancedDedupError.invalidModelOutput }
            return (0..<output.count).map { output[$0].floatValue }
        }
    }

    public func fingerprint(image: CGImage, orientation: CGImagePropertyOrientation) async throws -> Fingerprint {
        try Task.checkCancellation()
        let tensor = try ImagePreprocessor.prepare(image: image, orientation: orientation,
                                                   configuration: configuration)
        return try await fingerprintPrepared(tensor)
    }

    /// Probe seam: the same serialized prediction path, after independently timed preprocessing.
    public func fingerprintPrepared(_ tensor: MLMultiArray) async throws -> Fingerprint {
        try Task.checkCancellation()
        guard tensor.shape.map(\.intValue) == [1, 3, configuration.inputSide, configuration.inputSide],
              tensor.dataType == .float32 else { throw AdvancedDedupError.invalidConfiguration }
        let flag = CancellationFlag()
        let prediction = predict
        let queue = physicalQueue
        let input = InferenceInput(tensor: tensor)
        let values: [Float] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if flag.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        let values = try prediction(input.tensor)
                        if flag.isCancelled { continuation.resume(throwing: CancellationError()) }
                        else { continuation.resume(returning: values) }
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { flag.cancel() }
        return try Fingerprint(version: configuration.version, values: values)
    }

    public static func packageSHA256(_ url: URL) -> String? {
        // Populated by the conversion manifest helper; R2 probe verifies this before model load.
        guard let entries = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )?.allObjects.compactMap({ $0 as? URL }) else { return nil }
        var files = [URL]()
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { return nil }
            if values.isRegularFile == true { files.append(entry) }
        }
        files.sort {
            let left = Data($0.path.dropFirst(url.path.count + 1).utf8)
            let right = Data($1.path.dropFirst(url.path.count + 1).utf8)
            return left.lexicographicallyPrecedes(right)
        }
        guard !files.isEmpty else { return nil }
        var hasher = SHA256()
        for file in files {
            let relative = String(file.path.dropFirst(url.path.count + 1))
            guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            hasher.update(data: Data(relative.utf8)); hasher.update(data: Data([0]))
            do {
                while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                    hasher.update(data: bytes)
                }
                try handle.close()
            } catch { try? handle.close(); return nil }
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
