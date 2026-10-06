import CoreML
import Foundation

/// Selected Core ML configuration, never a claim about actual physical hardware.
public enum ModelComputeConfiguration: String, Codable, Sendable {
    case cpuAndNeuralEngine, cpuAndGPU
}

public struct ModelExecutionUnavailable: Error, Sendable {
    public static let summary = "照片分析暂时不可用，正在等待恢复。"
    public let detail: String
    public init(detail: String) { self.detail = detail }
}

protocol ModelPredictionSession: AnyObject, Sendable {
    func predict(_ input: MLMultiArray) throws -> [Float]
}

struct ModelSelfTestCase: Sendable {
    let input: Data
    let reference: [Float]
}

import CryptoKit

public struct ModelExecutionPolicy: Decodable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let arm64: [ModelComputeConfiguration]
    public let x86_64: [ModelComputeConfiguration]
    public let maxFallbacks: Int
    public let inputType: String
    public let outputType: String
    public let allowLowPrecisionAccumulationOnGPU: Bool
    public let retryIntervalSeconds: Double
    public let modelSHA256: String
    public let fingerprintVersion: String
    public let selfTestManifestSHA256: String

    public var candidates: [ModelComputeConfiguration] {
        #if arch(arm64)
        return arm64
        #else
        return x86_64
        #endif
    }

    public static func loadValidated(resourceDirectory: URL) throws -> ModelExecutionPolicy {
        let bytes = try modelResourceBytes(root: resourceDirectory, relative: "execution-policy.json")
        let policy = try JSONDecoder().decode(Self.self, from: bytes)
        try policy.validate()
        return policy
    }
    func validate() throws {
        guard self.schemaVersion == 1, self.id == "fp16-ane-gpu-v1",
              self.arm64 == [.cpuAndNeuralEngine, .cpuAndGPU], self.x86_64 == [.cpuAndGPU],
              self.maxFallbacks == 1, self.inputType == "float32", self.outputType == "float32",
              !self.allowLowPrecisionAccumulationOnGPU, self.retryIntervalSeconds == 60,
              self.modelSHA256 == "026e7a43660e29c307941a88dbe35b9c14468693333ff926e9b984eef3b4b8d0",
              self.fingerprintVersion == "ec805406fa61e91384e4bf29ae29a52694b80e3755afd7768da80a6db70c9a1d",
              self.selfTestManifestSHA256 == "8dfb4ccac57943db5ed867d180916dc6477fa8377017ef9e1b1cdf19e0c993f9" else {
            throw AdvancedDedupError.invalidConfiguration
        }
    }

}

public struct ModelSelfTest: Sendable {
    let cases: [ModelSelfTestCase]
    public static func loadValidated(resourceDirectory: URL, policy: ModelExecutionPolicy) throws -> ModelSelfTest {
        try policy.validate()
        let bytes = try modelResourceBytes(root: resourceDirectory, relative: "ModelSelfTest/manifest.json")
        guard modelResourceSHA256(bytes) == policy.selfTestManifestSHA256 else { throw AdvancedDedupError.invalidConfiguration }
        let manifest = try JSONDecoder().decode(Manifest.self, from: bytes)
        guard manifest.schemaVersion == 1, manifest.inputShape == [1,3,320,320], manifest.outputShape == [1,1024],
              manifest.inputType == "float32", manifest.outputType == "float32",
              manifest.comparison == "l2_normalized_float32", manifest.maxAbsError == 0.02,
              manifest.minCosine == 0.999, manifest.cases.count == 4 else { throw AdvancedDedupError.invalidConfiguration }
        var cases = [ModelSelfTestCase]()
        for (i, item) in manifest.cases.enumerated() {
            guard item.input.path == "input-\(i).f32", item.reference.path == "reference-\(i).f32",
                  item.input.bytes == 1228800, item.reference.bytes == 4096 else { throw AdvancedDedupError.invalidConfiguration }
            func read(_ file: Manifest.File) throws -> Data {
                let bytes = try modelResourceBytes(root: resourceDirectory, relative: "ModelSelfTest/" + file.path)
                guard bytes.count == file.bytes, modelResourceSHA256(bytes) == file.sha256,
                      modelFloat32Values(bytes).allSatisfy(\.isFinite) else { throw AdvancedDedupError.invalidConfiguration }
                return bytes
            }
            let input = try read(item.input), reference = try modelFloat32Values(read(item.reference))
            // Validate a nonzero normalized reference without changing comparison semantics.
            _ = try Fingerprint(version: policy.fingerprintVersion, values: reference)
            cases.append(.init(input: input, reference: reference))
        }
        return .init(cases: cases)
    }
    private struct Manifest: Decodable {
        let schemaVersion: Int, inputShape: [Int], outputShape: [Int], inputType: String, outputType: String
        let comparison: String, maxAbsError: Double, minCosine: Double, cases: [Case]
        struct File: Decodable { let path: String, bytes: Int, sha256: String }
        struct Case: Decodable { let input: File, reference: File }
    }
}

func modelResourceSHA256(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

func modelFloat32Values(_ bytes: Data) -> [Float] {
    bytes.withUnsafeBytes { raw in
        stride(from: 0, to: bytes.count, by: 4).map {
            Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
        }
    }
}

/// Explicit fixed paths, with every ancestor checked; no symlink or research-path resolution.
func modelResourceBytes(root: URL, relative: String) throws -> Data {
    let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
          !relative.hasPrefix("/") else { throw AdvancedDedupError.invalidConfiguration }
    var url = root
    guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
        throw AdvancedDedupError.invalidConfiguration
    }
    for part in parts {
        url.appendPathComponent(String(part))
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw AdvancedDedupError.invalidConfiguration
        }
    }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 2 * 1024 * 1024 else { throw AdvancedDedupError.invalidConfiguration }
    return try Data(contentsOf: url)
}

/// A synchronous admission signal, separate from Task cancellation and physical ownership.
/// Revocation stops only new work; already-started successful prediction results remain valid.
final class ModelExecutionEligibility: @unchecked Sendable {
    private let lock = NSLock()
    private var eligible = true
    private var authorized: @Sendable () -> Bool = { true }
    func set(_ value: Bool) { lock.lock(); eligible = value; lock.unlock() }
    func setAuthorization(_ predicate: @escaping @Sendable () -> Bool) {
        lock.lock(); authorized = predicate; lock.unlock()
    }
    var isEligible: Bool {
        lock.lock(); let allowed = eligible, authorization = authorized; lock.unlock()
        // The supplied synchronous provider is evaluated outside the lock. The model
        // knows no Photos API and never captures the runtime actor or performs its I/O.
        return allowed && authorization()
    }
}

public protocol ModelExecutionRecovering: Sendable {
    func setExecutionEligible(_ eligible: Bool)
    func setExecutionAuthorization(_ authorized: @escaping @Sendable () -> Bool)
    /// The caller must enforce pause/source/authorization eligibility before requesting recovery.
    func prepareExecution(forceRetry: Bool) async throws
}
public extension ModelExecutionRecovering {
    // Non-model injected implementations have no implicit physical recovery to gate.
    func setExecutionEligible(_ eligible: Bool) {}
    func setExecutionAuthorization(_ authorized: @escaping @Sendable () -> Bool) {}
}

/// All mutable state is confined to the fingerprinter's one physical queue.
final class PhysicalModelExecution: @unchecked Sendable {
    private let configuration: FingerprintConfiguration
    private let selfTests: [ModelSelfTestCase]
    private let candidates: [ModelComputeConfiguration]
    private let factory: @Sendable (ModelComputeConfiguration) throws -> any ModelPredictionSession
    private let diagnostics: @Sendable ([String: String]) -> Void
    private let now: @Sendable () -> Date
    private var session: (any ModelPredictionSession)?
    private var candidateIndex = 0
    private var retryAt: Date?
    private var hardFailure: Error?
    private var unavailable = ModelExecutionUnavailable(detail: "Model has not been validated")

    init(configuration: FingerprintConfiguration, selfTests: [ModelSelfTestCase], candidates: [ModelComputeConfiguration],
         now: @escaping @Sendable () -> Date,
         factory: @escaping @Sendable (ModelComputeConfiguration) throws -> any ModelPredictionSession,
         diagnostics: @escaping @Sendable ([String: String]) -> Void) {
        self.configuration = configuration; self.selfTests = selfTests; self.candidates = candidates
        self.now = now; self.factory = factory; self.diagnostics = diagnostics
    }

    func prepare(forceRetry: Bool, cancelled: () -> Bool, eligible: () -> Bool) throws {
        if let hardFailure { throw hardFailure }
        if session != nil { return }
        guard eligible() else { throw CancellationError() }
        if let retryAt {
            guard forceRetry || now() >= retryAt else { throw unavailable }
            self.retryAt = nil; candidateIndex = 0
        }
        try select(cancelled: cancelled, eligible: eligible)
    }

    private func log(_ stage: String, result: String, detail: String? = nil) {
        var fields = ["phase": "model-execution", "policy": "fp16-ane-gpu-v1", "stage": stage, "result": result,
            "requested": candidates[min(candidateIndex, candidates.count - 1)].rawValue]
        if session != nil { fields["selected"] = candidates[candidateIndex].rawValue }
        if let detail { fields["detail"] = detail }
        diagnostics(fields)
    }

    private func select(cancelled: () -> Bool, eligible: () -> Bool) throws {
        while candidateIndex < candidates.count {
            if cancelled() || !eligible() { throw CancellationError() }
            do {
                try autoreleasepool {
                    session = try factory(candidates[candidateIndex])
                    log("load", result: "loaded")
                    for (i, golden) in selfTests.enumerated() {
                        if cancelled() || !eligible() { throw CancellationError() }
                        let side = configuration.inputSide
                        guard golden.input.count == 3 * side * side * 4 else { throw AdvancedDedupError.invalidConfiguration }
                        let tensor = try MLMultiArray(shape: [1,3,NSNumber(value: side),NSNumber(value: side)], dataType: .float32)
                        _ = golden.input.withUnsafeBytes { memcpy(tensor.dataPointer, $0.baseAddress!, golden.input.count) }
                        let result = try prediction(tensor)
                        let actual = try Fingerprint(version: configuration.version, values: result)
                        let reference = try Fingerprint(version: configuration.version, values: golden.reference)
                        let maxAbs = zip(actual.values, reference.values).map { abs(Double($0) - Double($1)) }.max()!
                        let cosine = zip(actual.values, reference.values).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
                        diagnostics(["phase": "model-execution", "policy": "fp16-ane-gpu-v1", "stage": "self-test", "case": String(i),
                            "requested": candidates[candidateIndex].rawValue, "maxAbs": String(maxAbs), "cosine": String(cosine),
                            "result": maxAbs <= 0.02 && cosine >= 0.999 ? "passed" : "failed"])
                        guard maxAbs <= 0.02, cosine >= 0.999 else { throw ModelExecutionUnavailable(detail: "Numerical self-test \(i) failed") }
                    }
                    if cancelled() { throw CancellationError() }
                }
                log("validation", result: "passed")
                return
            } catch {
                // No prediction frame or autoreleased Core ML work survives into a new instance.
                autoreleasepool { session = nil }
                if cancelled() || error is CancellationError { throw CancellationError() }
                guard Self.isRecoverable(error) else { hardFailure = error; throw error }
                log("load-or-self-test", result: "failed", detail: String(describing: error))
                unavailable = .init(detail: String(describing: error)); candidateIndex += 1
                if candidateIndex < candidates.count { log("fallback", result: "requested") }
            }
        }
        retryAt = now().addingTimeInterval(60)
        throw unavailable
    }

    private func prediction(_ tensor: MLMultiArray) throws -> [Float] {
        guard let session else { throw unavailable }
        let values = try session.predict(tensor)
        guard values.count == 1024 else { throw AdvancedDedupError.invalidModelOutput }
        guard values.allSatisfy(\.isFinite), values.contains(where: { $0 != 0 }) else {
            throw ModelExecutionUnavailable(detail: "Non-finite or zero model output")
        }
        return values
    }

    func predict(_ tensor: MLMultiArray, cancelled: () -> Bool, eligible: () -> Bool) throws -> [Float] {
        guard eligible() else { throw CancellationError() }
        try prepare(forceRetry: false, cancelled: cancelled, eligible: eligible)
        guard eligible() else { throw CancellationError() }
        do {
            let values = try autoreleasepool { try prediction(tensor) }
            if cancelled() { throw CancellationError() }
            return values
        } catch {
            if cancelled() || error is CancellationError { throw CancellationError() }
            guard Self.isRecoverable(error) else { hardFailure = error; autoreleasepool { session = nil }; throw error }
            autoreleasepool { session = nil }
            log("prediction", result: "failed", detail: String(describing: error))
            unavailable = .init(detail: String(describing: error)); candidateIndex += 1
            if cancelled() || !eligible() { throw CancellationError() }
            guard candidateIndex < candidates.count else { retryAt = now().addingTimeInterval(60); throw unavailable }
            log("fallback", result: "requested")
            try select(cancelled: cancelled, eligible: eligible)
            // One fallback prediction, no recursive retry or third configuration.
            guard eligible() else { throw CancellationError() }
            do {
                let values = try autoreleasepool { try prediction(tensor) }
                if cancelled() { throw CancellationError() }
                return values
            } catch {
                if cancelled() || error is CancellationError { throw CancellationError() }
                autoreleasepool { session = nil }
                guard Self.isRecoverable(error) else { hardFailure = error; throw error }
                log("prediction", result: "failed", detail: String(describing: error))
                candidateIndex = candidates.count; retryAt = now().addingTimeInterval(60)
                unavailable = .init(detail: String(describing: error)); throw unavailable
            }
        }
    }

    private static func isRecoverable(_ error: Error) -> Bool {
        if error is ModelExecutionUnavailable { return true }
        let native = error as NSError
        // Core ML's generic framework failure is retryable; IO, feature types,
        // custom models, parameters and cancellation are not hardware fallback triggers.
        return native.domain == MLModelErrorDomain && native.code == 0
    }
}
