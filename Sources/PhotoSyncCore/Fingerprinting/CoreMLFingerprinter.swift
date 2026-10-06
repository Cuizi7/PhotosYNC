import CoreGraphics
import CoreML
import CryptoKit
import Darwin
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

public actor CoreMLFingerprinter: ImageFingerprinting, ModelExecutionRecovering {
    public let configuration: FingerprintConfiguration
    private let predict: (@Sendable (MLMultiArray) throws -> [Float])?
    private let execution: PhysicalModelExecution?
    private let onSubmitted: (@Sendable () -> Void)?
    // A single queue retains the physical slot until prediction returns, even when its waiter cancels.
    private let physicalQueue = DispatchQueue(label: "PhotoSyncCore.SSCD.physicalInference")

    public init(configuration: FingerprintConfiguration,
                predict: @escaping @Sendable (MLMultiArray) throws -> [Float]) {
        self.configuration = configuration
        self.predict = predict
        self.onSubmitted = nil
        self.execution = nil
    }

    init(configuration: FingerprintConfiguration,
         predict: @escaping @Sendable (MLMultiArray) throws -> [Float],
         onSubmitted: @escaping @Sendable () -> Void) {
        self.configuration = configuration
        self.predict = predict
        self.onSubmitted = onSubmitted
        self.execution = nil
    }

    // Physical-boundary seam; the injected factory stands in for Core ML only.
    init(configuration: FingerprintConfiguration, selfTests: [ModelSelfTestCase],
         candidates: [ModelComputeConfiguration] = [.cpuAndNeuralEngine, .cpuAndGPU],
         now: @escaping @Sendable () -> Date = { Date() },
         factory: @escaping @Sendable (ModelComputeConfiguration) throws -> any ModelPredictionSession,
         diagnostics: @escaping @Sendable ([String: String]) -> Void = { _ in }) throws {
        self.configuration = configuration; self.onSubmitted = nil; self.predict = nil
        self.execution = PhysicalModelExecution(configuration: configuration, selfTests: selfTests,
            candidates: candidates, now: now, factory: factory, diagnostics: diagnostics)
    }

    /// Product assembly must supply validated policy and synthetic resources explicitly.
    public init(modelURL: URL, configuration: FingerprintConfiguration,
                policy: ModelExecutionPolicy, selfTest: ModelSelfTest,
                now: @escaping @Sendable () -> Date = { Date() },
                diagnostics: @escaping @Sendable ([String: String]) -> Void = { _ in }) throws {
        try policy.validate()
        guard modelURL.pathExtension == "mlpackage", Self.packageSHA256(modelURL) == configuration.modelSHA256,
              configuration.modelSHA256 == policy.modelSHA256,
              configuration.version == policy.fingerprintVersion else { throw AdvancedDedupError.modelMismatch }
        self.configuration = configuration; self.onSubmitted = nil; self.predict = nil
        execution = PhysicalModelExecution(configuration: configuration, selfTests: selfTest.cases,
            candidates: policy.candidates, now: now,
            factory: { backend in
                let compiled = try Self.compiledModel(modelURL: modelURL, configuration: configuration)
                return try NativeModelSession(compiledURL: compiled, configuration: configuration, backend: backend)
            }, diagnostics: diagnostics)
    }

    public func prepareExecution(forceRetry: Bool = false) async throws {
        guard let execution else { return }
        let flag = CancellationFlag(), queue = physicalQueue
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do { try execution.prepare(forceRetry: forceRetry, cancelled: { flag.isCancelled }); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { flag.cancel() }
    }

    /// Historical CPU-only research/test API. Never selected by product assembly.
    public init(researchCPUOnlyModelURL modelURL: URL, configuration: FingerprintConfiguration) throws {
        guard modelURL.pathExtension == "mlpackage",
              Self.packageSHA256(modelURL) == configuration.modelSHA256 else {
            throw AdvancedDedupError.modelMismatch
        }
        let compiledURL = try Self.compiledModel(modelURL: modelURL, configuration: configuration)
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
        self.onSubmitted = nil
        self.execution = nil
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
    /// The caller lends tensor storage exclusively and must not mutate or reuse it until physical
    /// prediction completes. Logical task cancellation does not release that physical work;
    /// after cancellation, discard the tensor rather than assuming the prediction has finished.
    public func fingerprintPrepared(_ tensor: MLMultiArray) async throws -> Fingerprint {
        try Task.checkCancellation()
        guard tensor.shape.map(\.intValue) == [1, 3, configuration.inputSide, configuration.inputSide],
              tensor.dataType == .float32 else { throw AdvancedDedupError.invalidConfiguration }
        let flag = CancellationFlag()
        let prediction = predict, execution = execution
        let queue = physicalQueue
        let submitted = onSubmitted
        let input = InferenceInput(tensor: tensor)
        let values: [Float] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if flag.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        let values: [Float]
                        if let execution { values = try execution.predict(input.tensor, cancelled: { flag.isCancelled }) }
                        else { values = try prediction!(input.tensor) }
                        if flag.isCancelled { continuation.resume(throwing: CancellationError()) }
                        else { continuation.resume(returning: values) }
                    } catch { continuation.resume(throwing: flag.isCancelled ? CancellationError() : error) }
                }
                submitted?()
            }
        } onCancel: { flag.cancel() }
        return try Fingerprint(version: configuration.version, values: values)
    }

    nonisolated static func compiledModel(modelURL: URL, configuration: FingerprintConfiguration) throws -> URL {
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
        return compiledURL
    }

    public static func packageSHA256(_ url: URL) -> String? {
        // Versioned, length-framed manifest; Python's convert-model.py uses identical bytes.
        let root = url.standardizedFileURL
        guard let attributes = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              attributes.isDirectory == true, attributes.isSymbolicLink != true else { return nil }
        guard let rootPath = canonicalPath(root.path) else { return nil }
        guard let entries = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )?.allObjects.compactMap({ $0 as? URL }) else { return nil }
        var files = [URL]()
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { return nil }
            if values.isRegularFile == true { files.append(entry) }
        }
        var relativeFiles = [(path: URL, relative: Data)]()
        for file in files {
            guard let canonical = canonicalPath(file.path), canonical.hasPrefix(rootPath + "/") else { return nil }
            relativeFiles.append((file, Data(canonical.dropFirst(rootPath.count + 1).utf8)))
        }
        relativeFiles.sort { $0.relative.lexicographicallyPrecedes($1.relative) }
        guard !relativeFiles.isEmpty else { return nil }
        var hasher = SHA256()
        hasher.update(data: Data("PhotoSync.mlpackage.manifest.v2\0".utf8))
        func appendLength(_ value: Int) {
            var littleEndian = UInt64(value).littleEndian
            withUnsafeBytes(of: &littleEndian) { hasher.update(data: Data($0)) }
        }
        appendLength(relativeFiles.count)
        for (file, relative) in relativeFiles {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size >= 0 else { try? handle.close(); return nil }
            appendLength(relative.count); hasher.update(data: relative)
            appendLength(size)
            var readBytes = 0
            do {
                while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                    hasher.update(data: bytes)
                    readBytes += bytes.count
                }
                try handle.close()
            } catch { try? handle.close(); return nil }
            guard readBytes == size else { return nil }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard let pointer = path.withCString({ realpath($0, nil) }) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}

final class NativeModelSession: ModelPredictionSession, @unchecked Sendable {
    private let model: MLModel
    init(compiledURL: URL, configuration: FingerprintConfiguration, backend: ModelComputeConfiguration) throws {
        let runtime = MLModelConfiguration()
        switch backend {
        case .cpuAndNeuralEngine: runtime.computeUnits = .cpuAndNeuralEngine
        case .cpuAndGPU: runtime.computeUnits = .cpuAndGPU
        }
        runtime.allowLowPrecisionAccumulationOnGPU = false
        model = try MLModel(contentsOf: compiledURL, configuration: runtime)
        let input = model.modelDescription.inputDescriptionsByName["image"]?.multiArrayConstraint
        let output = model.modelDescription.outputDescriptionsByName["embedding"]?.multiArrayConstraint
        guard input?.shape.map(\.intValue) == [1,3,configuration.inputSide,configuration.inputSide],
              output?.shape.map(\.intValue) == [1,1024], input?.dataType == .float32, output?.dataType == .float32 else {
            throw AdvancedDedupError.invalidConfiguration
        }
    }
    func predict(_ tensor: MLMultiArray) throws -> [Float] {
        let features = try MLDictionaryFeatureProvider(dictionary: ["image": tensor])
        guard let output = try model.prediction(from: features).featureValue(for: "embedding")?.multiArrayValue,
              output.count == 1024, output.dataType == .float32 else { throw AdvancedDedupError.invalidModelOutput }
        return (0..<output.count).map { output[$0].floatValue }
    }
}
