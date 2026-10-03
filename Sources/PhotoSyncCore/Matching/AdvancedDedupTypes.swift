import CryptoKit
import Foundation

public enum AdvancedDedupError: Error, Equatable {
    case invalidConfiguration
    case invalidFingerprint
    case modelMismatch
    case invalidImage
    case invalidModelOutput
}

public struct PixelSize: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw AdvancedDedupError.invalidConfiguration }
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey { case width, height }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(width: c.decode(Int.self, forKey: .width), height: c.decode(Int.self, forKey: .height))
    }
}

public enum ResizeMode: String, Codable, Sendable {
    case stretchFullFrame
    case letterbox
}

public struct FingerprintConfiguration: Codable, Equatable, Sendable {
    public let version: String
    public let modelSHA256: String
    public let inputSide: Int
    public let resizeMode: ResizeMode
    public let colorSpace: String
    public let mean: [Float]
    public let std: [Float]

    public init(modelSHA256: String, inputSide: Int, resizeMode: ResizeMode,
                colorSpace: String, mean: [Float], std: [Float]) throws {
        guard modelSHA256.count == 64, modelSHA256.allSatisfy({ $0.isHexDigit }),
              inputSide > 0, inputSide <= 4096, colorSpace == "sRGB",
              mean.count == 3, std.count == 3,
              mean.allSatisfy(\.isFinite), std.allSatisfy({ $0.isFinite && $0 > 0 })
        else { throw AdvancedDedupError.invalidConfiguration }
        self.modelSHA256 = modelSHA256.lowercased()
        self.inputSide = inputSide
        self.resizeMode = resizeMode
        self.colorSpace = colorSpace
        self.mean = mean
        self.std = std
        self.version = Self.computeVersion(modelSHA256: self.modelSHA256, inputSide: inputSide,
                                           resizeMode: resizeMode, colorSpace: colorSpace,
                                           mean: mean, std: std)
    }

    private static func computeVersion(modelSHA256: String, inputSide: Int, resizeMode: ResizeMode,
                                       colorSpace: String, mean: [Float], std: [Float]) -> String {
        // Fixed ordering and Float32 bit patterns avoid locale/JSON-number drift across runs.
        let fields = ["sscd-preprocess-v1", modelSHA256, String(inputSide), resizeMode.rawValue,
                      colorSpace] + mean.map { String($0.bitPattern) } + std.map { String($0.bitPattern) }
        return SHA256.hash(data: Data(fields.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey {
        case version, modelSHA256, inputSide, resizeMode, colorSpace, mean, std
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(modelSHA256: c.decode(String.self, forKey: .modelSHA256),
                      inputSide: c.decode(Int.self, forKey: .inputSide),
                      resizeMode: c.decode(ResizeMode.self, forKey: .resizeMode),
                      colorSpace: c.decode(String.self, forKey: .colorSpace),
                      mean: c.decode([Float].self, forKey: .mean), std: c.decode([Float].self, forKey: .std))
        guard version == (try c.decode(String.self, forKey: .version)) else {
            throw AdvancedDedupError.invalidConfiguration
        }
    }
}

public struct Fingerprint: Equatable, Sendable {
    public let version: String
    public let values: [Float]

    public init(version: String, values: [Float]) throws {
        guard !version.isEmpty, values.count == 1024, values.allSatisfy(\.isFinite) else {
            throw AdvancedDedupError.invalidFingerprint
        }
        let norm = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 0 else { throw AdvancedDedupError.invalidFingerprint }
        self.version = version
        self.values = values.map { Float(Double($0) / norm) }
    }

    public var littleEndianFloat32: Data {
        var data = Data(capacity: values.count * 4)
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }
}

public enum CandidateOrigin: String, Codable, Sendable {
    case photosOriginal, photosCurrent, localPending, localImporting, successHistory
}

public struct ScoredCandidate: Equatable, Sendable {
    public let key: String
    public let origin: CandidateOrigin
    public let score: Double
    public let size: PixelSize?
    public let fingerprintVersion: String

    public init(key: String, origin: CandidateOrigin, score: Double, size: PixelSize?, fingerprintVersion: String) {
        self.key = key; self.origin = origin; self.score = score; self.size = size
        self.fingerprintVersion = fingerprintVersion
    }
}

public enum ContentResult: String, Sendable { case duplicate, notDuplicate }
public enum ImportAction: String, Sendable { case importFile, skip }
public enum DecisionReason: String, Sendable {
    case noMatch, covered, resolutionUpgrade, insufficientSizeEvidence
}

public struct DuplicateEvaluation: Equatable, Sendable {
    public let content: ContentResult
    public let action: ImportAction
    public let reason: DecisionReason
    public let matchedKeys: [String]
    public let coveringKeys: [String]

    public init(content: ContentResult, action: ImportAction, reason: DecisionReason,
                matchedKeys: [String], coveringKeys: [String]) {
        self.content = content; self.action = action; self.reason = reason
        self.matchedKeys = matchedKeys; self.coveringKeys = coveringKeys
    }
}

public struct ResourceLimits: Codable, Sendable {
    public let decodeConcurrency: Int
    public let photoRequestConcurrency: Int
    public let maxDecodedBytes: Int64
    public let requestTimeoutSeconds: Double
    public let retryDelaysSeconds: [Double]
    public let catalogBatchSize: Int
    public let maxInFlightTasks: Int
    public let progressPublishIntervalSeconds: Double
    public let inferenceConcurrency: Int
    public let batchSize: Int

    public init(decodeConcurrency: Int, photoRequestConcurrency: Int, maxDecodedBytes: Int64,
                requestTimeoutSeconds: Double, retryDelaysSeconds: [Double], catalogBatchSize: Int,
                maxInFlightTasks: Int, progressPublishIntervalSeconds: Double,
                inferenceConcurrency: Int, batchSize: Int) throws {
        guard decodeConcurrency > 0, photoRequestConcurrency > 0, maxDecodedBytes > 0,
              requestTimeoutSeconds.isFinite, requestTimeoutSeconds > 0,
              !retryDelaysSeconds.isEmpty, retryDelaysSeconds.allSatisfy({ $0.isFinite && $0 > 0 }),
              catalogBatchSize > 0, maxInFlightTasks > 0,
              progressPublishIntervalSeconds.isFinite, progressPublishIntervalSeconds > 0,
              inferenceConcurrency == 1, batchSize == 1
        else { throw AdvancedDedupError.invalidConfiguration }
        self.decodeConcurrency = decodeConcurrency; self.photoRequestConcurrency = photoRequestConcurrency
        self.maxDecodedBytes = maxDecodedBytes; self.requestTimeoutSeconds = requestTimeoutSeconds
        self.retryDelaysSeconds = retryDelaysSeconds; self.catalogBatchSize = catalogBatchSize
        self.maxInFlightTasks = maxInFlightTasks
        self.progressPublishIntervalSeconds = progressPublishIntervalSeconds
        self.inferenceConcurrency = inferenceConcurrency; self.batchSize = batchSize
    }

    private enum CodingKeys: String, CodingKey {
        case decodeConcurrency, photoRequestConcurrency, maxDecodedBytes, requestTimeoutSeconds
        case retryDelaysSeconds, catalogBatchSize, maxInFlightTasks, progressPublishIntervalSeconds
        case inferenceConcurrency, batchSize
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(decodeConcurrency: c.decode(Int.self, forKey: .decodeConcurrency),
                      photoRequestConcurrency: c.decode(Int.self, forKey: .photoRequestConcurrency),
                      maxDecodedBytes: c.decode(Int64.self, forKey: .maxDecodedBytes),
                      requestTimeoutSeconds: c.decode(Double.self, forKey: .requestTimeoutSeconds),
                      retryDelaysSeconds: c.decode([Double].self, forKey: .retryDelaysSeconds),
                      catalogBatchSize: c.decode(Int.self, forKey: .catalogBatchSize),
                      maxInFlightTasks: c.decode(Int.self, forKey: .maxInFlightTasks),
                      progressPublishIntervalSeconds: c.decode(Double.self, forKey: .progressPublishIntervalSeconds),
                      inferenceConcurrency: c.decode(Int.self, forKey: .inferenceConcurrency),
                      batchSize: c.decode(Int.self, forKey: .batchSize))
    }
}

public struct DedupConfiguration: Codable, Sendable {
    public let fingerprint: FingerprintConfiguration
    public let policyVersion: String
    public let threshold: Double
    public let backend: String
    public let resources: ResourceLimits
    public let evidenceCandidateLimit: Int
    public let acceptanceID: String

    public init(fingerprint: FingerprintConfiguration, policyVersion: String, threshold: Double,
                backend: String, resources: ResourceLimits, evidenceCandidateLimit: Int,
                acceptanceID: String) throws {
        guard threshold.isFinite, threshold > 0, threshold <= 1,
              !backend.isEmpty, evidenceCandidateLimit > 0, !acceptanceID.isEmpty else {
            throw AdvancedDedupError.invalidConfiguration
        }
        guard policyVersion == Self.computePolicyVersion(fingerprintVersion: fingerprint.version,
                                                         threshold: threshold, backend: backend) else {
            throw AdvancedDedupError.invalidConfiguration
        }
        self.fingerprint = fingerprint; self.policyVersion = policyVersion; self.threshold = threshold
        self.backend = backend; self.resources = resources
        self.evidenceCandidateLimit = evidenceCandidateLimit; self.acceptanceID = acceptanceID
    }

    public static func computePolicyVersion(fingerprintVersion: String, threshold: Double,
                                            backend: String) -> String {
        // Length framing binds each field without separator ambiguity. Rule changes require a new tag.
        let fields = ["advanced-dedup-policy-v1", fingerprintVersion,
                      String(threshold.bitPattern), backend,
                      "cover-if-both-sorted-pixel-edges-gte-v1"]
        var bytes = Data()
        for field in fields {
            let encoded = Data(field.utf8)
            var count = UInt64(encoded.count).littleEndian
            withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
            bytes.append(encoded)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey {
        case fingerprint, policyVersion, threshold, backend, resources, evidenceCandidateLimit, acceptanceID
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(fingerprint: c.decode(FingerprintConfiguration.self, forKey: .fingerprint),
                      policyVersion: c.decode(String.self, forKey: .policyVersion),
                      threshold: c.decode(Double.self, forKey: .threshold),
                      backend: c.decode(String.self, forKey: .backend),
                      resources: c.decode(ResourceLimits.self, forKey: .resources),
                      evidenceCandidateLimit: c.decode(Int.self, forKey: .evidenceCandidateLimit),
                      acceptanceID: c.decode(String.self, forKey: .acceptanceID))
    }
}
