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

public struct Fingerprint: Codable, Equatable, Sendable {
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

    /// Stored vectors are normalized Float32 facts; decoding must preserve their exact bytes.
    public init(version: String, littleEndianFloat32 data: Data) throws {
        guard !version.isEmpty, data.count == 4096 else { throw AdvancedDedupError.invalidFingerprint }
        var values = [Float]()
        values.reserveCapacity(1024)
        data.withUnsafeBytes { bytes in
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let bits = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                values.append(Float(bitPattern: bits))
            }
        }
        let norm = values.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard values.allSatisfy(\.isFinite), norm.isFinite, abs(norm - 1) <= 0.00001 else {
            throw AdvancedDedupError.invalidFingerprint
        }
        self.version = version; self.values = values
    }

    private enum CodingKeys: String, CodingKey { case version, littleEndianFloat32 }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(version: c.decode(String.self, forKey: .version),
                      littleEndianFloat32: c.decode(Data.self, forKey: .littleEndianFloat32))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(littleEndianFloat32, forKey: .littleEndianFloat32)
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

public struct ScoredCandidate: Codable, Equatable, Sendable {
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

public enum ContentResult: String, Codable, Sendable { case duplicate, notDuplicate, notCompared }
public enum ImportAction: String, Codable, Sendable { case importFile, skip }
public enum DecisionReason: String, Codable, Sendable {
    case noMatch, covered, resolutionUpgrade, insufficientSizeEvidence, nonComparableSource
}

public struct DuplicateEvaluation: Codable, Equatable, Sendable {
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

public struct ResourceLimits: Codable, Equatable, Sendable {
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

public struct DedupConfiguration: Codable, Equatable, Sendable {
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

public struct LibraryContext: Codable, Equatable, Sendable {
    public let id: UUID
    public let epoch: Int64
    public init(id: UUID, epoch: Int64) { self.id = id; self.epoch = epoch }
}
public enum RepresentationKind: String, Codable, Sendable { case original, current }
public struct RepresentationKey: Codable, Hashable, Sendable {
    public let assetID: String
    public let kind: RepresentationKind
    public init(assetID: String, kind: RepresentationKind) { self.assetID = assetID; self.kind = kind }
}
public struct RepresentationDescriptor: Codable, Equatable, Sendable {
    public let key: RepresentationKey
    public let context: LibraryContext
    public let revision: String
    public let size: PixelSize?
    public let equivalentToOriginal: Bool
    public let revisionIsReliable: Bool
    public init(key: RepresentationKey, context: LibraryContext, revision: String, size: PixelSize?,
                equivalentToOriginal: Bool, revisionIsReliable: Bool) {
        self.key = key; self.context = context; self.revision = revision; self.size = size
        self.equivalentToOriginal = equivalentToOriginal; self.revisionIsReliable = revisionIsReliable
    }
}
public struct IndexToken: Codable, Equatable, Sendable {
    public let context: LibraryContext
    public let photosGeneration: Int
    public let indexGeneration: Int64
    public let localRevision: Int64
    public let fingerprintVersion: String
    public init(context: LibraryContext, photosGeneration: Int, indexGeneration: Int64,
                localRevision: Int64, fingerprintVersion: String) {
        self.context = context; self.photosGeneration = photosGeneration
        self.indexGeneration = indexGeneration; self.localRevision = localRevision
        self.fingerprintVersion = fingerprintVersion
    }
}
public enum IndexState: String, Codable, Sendable { case preparing, updating, ready, waiting, paused }
public struct IndexProgress: Codable, Equatable, Sendable {
    public let state: IndexState
    public let totalsKnown: Bool
    public let totalAssets: Int
    public let readyAssets: Int
    public let totalRepresentations: Int
    public let readyRepresentations: Int
    public let readErrorRepresentations: Int
    public let excludedAssets: Int
    public let issue: String?
    public init(state: IndexState, totalsKnown: Bool, totalAssets: Int, readyAssets: Int,
                totalRepresentations: Int, readyRepresentations: Int, readErrorRepresentations: Int = 0,
                excludedAssets: Int, issue: String?) {
        self.state = state; self.totalsKnown = totalsKnown; self.totalAssets = totalAssets
        self.readyAssets = readyAssets; self.totalRepresentations = totalRepresentations
        self.readyRepresentations = readyRepresentations; self.excludedAssets = excludedAssets; self.issue = issue
        self.readErrorRepresentations = readErrorRepresentations
    }
}
public enum RepresentationFailureKind: String, Sendable { case photosRead = "photos_read" }
public struct RepresentationTask: Codable, Equatable, Sendable {
    public let descriptor: RepresentationDescriptor
    public let retryCount: Int
    public let nextRetryAt: Date?
    public let fingerprintVersion: String
    /// Persistent task issuance, changed only when this task is replaced, not the
    /// current global publication generation. Unchanged tasks may complete across
    /// later reconciliations if their persisted identity and full descriptor still
    /// match; replaced tasks reject late results even when revision strings match.
    public let indexGeneration: Int64
    public let issuanceRevision: String
    public init(descriptor: RepresentationDescriptor, retryCount: Int, nextRetryAt: Date?,
                fingerprintVersion: String, indexGeneration: Int64, issuanceRevision: String? = nil) {
        self.descriptor = descriptor; self.retryCount = retryCount; self.nextRetryAt = nextRetryAt
        self.fingerprintVersion = fingerprintVersion; self.indexGeneration = indexGeneration
        self.issuanceRevision = issuanceRevision ?? descriptor.revision
    }
}
public struct IndexPublication: Codable, Equatable, Sendable {
    public let token: IndexToken
    public let representationCount: Int
    public init(token: IndexToken, representationCount: Int) { self.token = token; self.representationCount = representationCount }
}
// VectorEntry remains the independent research/oracle representation.
extension VectorEntry: Equatable, Codable {
    public static func == (lhs: VectorEntry, rhs: VectorEntry) -> Bool {
        lhs.key == rhs.key && lhs.origin == rhs.origin && lhs.fingerprint == rhs.fingerprint && lhs.size == rhs.size
    }
    private enum CodingKeys: String, CodingKey { case key, origin, fingerprint, size }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(key: c.decode(String.self, forKey: .key), origin: c.decode(CandidateOrigin.self, forKey: .origin),
                  fingerprint: c.decode(Fingerprint.self, forKey: .fingerprint), size: c.decodeIfPresent(PixelSize.self, forKey: .size))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key); try c.encode(origin, forKey: .origin)
        try c.encode(fingerprint, forKey: .fingerprint); try c.encodeIfPresent(size, forKey: .size)
    }
}
public struct PreparedSource: Codable, Equatable, Sendable {
    public let fileID: UUID
    public let file: SourceFile
    public let fingerprint: Fingerprint
    public let size: PixelSize?
    public init(fileID: UUID, file: SourceFile, fingerprint: Fingerprint, size: PixelSize?) {
        self.fileID = fileID; self.file = file; self.fingerprint = fingerprint; self.size = size
    }
}
public struct VectorSearchResult: Codable, Equatable, Sendable {
    public let matches: [ScoredCandidate]
    public let diagnostics: [ScoredCandidate]
    public init(matches: [ScoredCandidate], diagnostics: [ScoredCandidate]) { self.matches = matches; self.diagnostics = diagnostics }
}
/// Durable bounded evidence, not the complete search result. The producer runs
/// policy over every threshold match, then projects evaluation matched/covering
/// keys to the zero/one independently chosen decisive candidate. Diagnostics are
/// at most ten nearest candidates and cannot decide a skip. Consumers validate
/// decisive evidence; they must not interpret key arrays as a candidate inventory.
public struct AdvancedEvidence: Codable, Equatable, Sendable {
    public let eventID: UUID
    public let fileID: UUID
    public let stamp: FileStamp
    public let token: IndexToken
    public let policyVersion: String
    public let evaluation: DuplicateEvaluation
    public let decisiveCandidates: [ScoredCandidate]
    public let diagnostics: [ScoredCandidate]
    public let timingsMS: [String: Double]
    public init(eventID: UUID, fileID: UUID, stamp: FileStamp, token: IndexToken, policyVersion: String,
                evaluation: DuplicateEvaluation, decisiveCandidates: [ScoredCandidate],
                diagnostics: [ScoredCandidate], timingsMS: [String: Double]) {
        self.eventID = eventID; self.fileID = fileID; self.stamp = stamp; self.token = token
        self.policyVersion = policyVersion; self.evaluation = evaluation
        self.decisiveCandidates = Array(decisiveCandidates.prefix(1))
        self.diagnostics = Array(diagnostics.prefix(10)); self.timingsMS = timingsMS
    }
}
public struct AdvancedAdmission: Sendable {
    public let source: PreparedSource
    public let evidence: AdvancedEvidence
    public let validity: any PhotosCandidateValidity
    public init(source: PreparedSource, evidence: AdvancedEvidence, validity: any PhotosCandidateValidity) {
        self.source = source; self.evidence = evidence; self.validity = validity
    }
}
/// Explicit notCompared/importFile evidence for confirmed readable content that
/// cannot be safely compared, including a decoded resource limit. No fingerprint,
/// vector cache, success vector, uniqueness claim or automatic skip is created.
/// The caller must preserve the original URL/bytes and all final source, stamp,
/// success/unknown, pause, index and native submission guards. Store the evidence
/// through the conservative attempt overload; never send this through a skip path.
public struct ConservativeSourceAdmission: Sendable {
    public let fileID: UUID
    public let file: SourceFile
    public let reason: RepresentationConservativeReason
    public let evidence: AdvancedEvidence
    public let validity: any PhotosCandidateValidity
    public init(fileID: UUID, file: SourceFile, reason: RepresentationConservativeReason,
                evidence: AdvancedEvidence, validity: any PhotosCandidateValidity) {
        self.fileID = fileID; self.file = file; self.reason = reason
        self.evidence = evidence; self.validity = validity
    }
}
/// Waiting carries no import decision. Conservative is an explicit original-byte
/// import without comparison; ready contains a real fingerprint and policy result.
public enum AdvancedPreparation: Sendable {
    case ready(AdvancedAdmission), conservative(ConservativeSourceAdmission), waiting(reason: String)
}

extension DedupConfiguration {
    /// Four fixed resource names and raw-byte hashes bind the user decision to its regression evidence.
    /// Research paths embedded in records are explanatory only and are never followed here.
    public static func loadValidated(resourceDirectory: URL) throws -> DedupConfiguration {
        let decoder = JSONDecoder()
        let execution = try ModelExecutionPolicy.loadValidated(resourceDirectory: resourceDirectory)
        _ = try ModelSelfTest.loadValidated(resourceDirectory: resourceDirectory, policy: execution)
        let executionID = modelResourceSHA256(try modelResourceBytes(root: resourceDirectory, relative: "execution-policy.json"))
        let decisionBytes = try modelResourceBytes(root: resourceDirectory, relative: "decision.json")
        let profileBytes = try modelResourceBytes(root: resourceDirectory, relative: "profile.json")
        let regressionBytes = try modelResourceBytes(root: resourceDirectory, relative: "regression.json")
        let closeoutBytes = try modelResourceBytes(root: resourceDirectory, relative: "closeout.json")
        let decision = try decoder.decode(IntegrationDecision.self, from: decisionBytes)
        let profile = try decoder.decode(DedupConfiguration.self, from: profileBytes)
        let regression = try decoder.decode(IntegrationRegression.self, from: regressionBytes)
        let closeout = try decoder.decode(IntegrationCloseout.self, from: closeoutBytes)
        func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
        let decisionID = hash(decisionBytes), profileID = hash(profileBytes), regressionID = hash(regressionBytes)
        let d = decision.configuration
        guard decision.schemaVersion == 1, decision.basis == "explicit_user_selected_threshold",
              decision.decision == "close_research_and_select_configuration_for_integration",
              !decision.userInstruction.isEmpty, decision.selectedThreshold == 0.98,
              decision.comparison == "score >= threshold",
              d.computeUnits == execution.id, d.weightPrecision == "float16",
              decision.executionPolicySHA256 == executionID,
              decision.selfTestManifestSHA256 == execution.selfTestManifestSHA256,
              d.resources.decodeConcurrency == 1, d.resources.photoRequestConcurrency == 1,
              d.resources.maxDecodedBytes == 536870912, d.resources.requestTimeoutSeconds == 30,
              d.resources.retryDelaysSeconds == [5, 15, 30, 60], d.resources.catalogBatchSize == 128,
              d.resources.maxInFlightTasks == 2, d.resources.progressPublishIntervalSeconds == 1,
              d.resources.inferenceConcurrency == 1, d.resources.batchSize == 1,
              d.evidenceCandidateLimit == 200000,
              d.fingerprint.modelSHA256 == execution.modelSHA256, d.fingerprint.version == execution.fingerprintVersion,
              d.fingerprint.inputSide == 320, d.fingerprint.resizeMode == .stretchFullFrame,
              d.fingerprint.colorSpace == "sRGB", d.fingerprint.mean == [0.485, 0.456, 0.406],
              d.fingerprint.std == [0.229, 0.224, 0.225], d.backend == "sqlite-exact-f32-v1",
              profile.threshold == decision.selectedThreshold, profile.fingerprint == d.fingerprint,
              profile.policyVersion == d.policyVersion, profile.backend == d.backend,
              profile.resources == d.resources, profile.evidenceCandidateLimit == d.evidenceCandidateLimit,
              profile.acceptanceID == "user-decision:" + decisionID,
              regression.schemaVersion == 1, regression.kind == "fixed_user_threshold_actual_fp16_inference",
              regression.thresholdBasis == "explicit_user_choice_not_independent_calibration",
              regression.decisionSHA256 == decisionID, regression.integrationProfileSHA256 == profileID,
              regression.threshold == profile.threshold, regression.policyVersion == profile.policyVersion,
              regression.fingerprintVersion == profile.fingerprint.version, regression.backend == profile.backend,
              regression.activeSuiteSHA256 == decision.activeSuite.sha256,
              regression.expectedResultsSHA256 == decision.activeSuite.expectedResultsSHA256,
              isSHA256(regression.sourceVectorManifestSHA256), isSHA256(regression.sourceReportSHA256),
              regression.newImageInference, !regression.independentValidation,
              decision.activeSuite.caseCount == 33, regression.caseCount == 33, regression.passCount == 33,
              regression.cases.count == 33, Set(regression.cases.map(\.id)).count == 33,
              regression.contentFailures.isEmpty, regression.actionFailures.isEmpty,
              regression.cases.allSatisfy({ $0.pass && $0.contentPass && $0.actionPass &&
                  $0.expectedContent == $0.observed.content && $0.expectedAction == $0.observed.action &&
                  isSHA256($0.observed.queryVectorSHA256) && !$0.gallery.isEmpty &&
                  $0.observed.candidates.allSatisfy({ isSHA256($0.vectorSHA256) && $0.score.isFinite }) }),
              closeout.schemaVersion == 1, closeout.status == "closed_with_user_selected_configuration",
              closeout.approvedForProductIntegration, closeout.decisionSHA256 == decisionID,
              closeout.profileSHA256 == profileID, closeout.regression.sha256 == regressionID,
              closeout.acceptanceID == profile.acceptanceID, closeout.threshold == profile.threshold,
              closeout.thresholdBasis == "explicit_user_choice", closeout.computeUnits == execution.id,
              closeout.backend == profile.backend, closeout.fingerprintVersion == profile.fingerprint.version,
              closeout.policyVersion == profile.policyVersion, closeout.modelSHA256 == profile.fingerprint.modelSHA256,
              closeout.activeSuiteSHA256 == regression.activeSuiteSHA256,
              closeout.regression.caseCount == 33, closeout.regression.passCount == 33,
              closeout.regression.contentFailures.isEmpty, closeout.regression.actionFailures.isEmpty,
              !closeout.regression.sameImagePairsAndVectors, !closeout.regression.independent,
              closeout.regression.newImageInference, closeout.statisticalAcceptance.status == "not_performed",
              !closeout.statisticalAcceptance.falseSkipUpperBoundClaimed,
              !closeout.statisticalAcceptance.recallConfidenceClaimed
        else { throw AdvancedDedupError.invalidConfiguration }
        return profile
    }
    private static func isSHA256(_ string: String) -> Bool { string.count == 64 && string.allSatisfy(\.isHexDigit) }
}
private struct IntegrationDecision: Decodable {
    let schemaVersion: Int, basis: String, userInstruction: String, decision: String
    let selectedThreshold: Double, comparison: String
    let executionPolicySHA256: String, selfTestManifestSHA256: String
    let configuration: Selection
    let activeSuite: Suite
    struct Selection: Decodable {
        let fingerprint: FingerprintConfiguration
        let policyVersion: String, backend: String, computeUnits: String, weightPrecision: String
        let resources: ResourceLimits
        let evidenceCandidateLimit: Int
    }
    struct Suite: Decodable { let sha256: String, expectedResultsSHA256: String; let caseCount: Int }
}
private struct IntegrationRegression: Decodable {
    let schemaVersion: Int, kind: String, thresholdBasis: String
    let decisionSHA256: String, integrationProfileSHA256: String, activeSuiteSHA256: String, expectedResultsSHA256: String
    let sourceVectorManifestSHA256: String, sourceReportSHA256: String
    let fingerprintVersion: String, policyVersion: String, backend: String
    let threshold: Double, newImageInference: Bool, independentValidation: Bool, caseCount: Int, passCount: Int
    let contentFailures: [String], actionFailures: [String], cases: [ReplayCase]
    struct ReplayCase: Decodable {
        let id: String, gallery: [String], expectedContent: ContentResult, expectedAction: ImportAction
        let pass: Bool, contentPass: Bool, actionPass: Bool
        let observed: Observation
    }
    struct Observation: Decodable {
        let content: ContentResult, action: ImportAction, queryVectorSHA256: String, candidates: [Candidate]
    }
    struct Candidate: Decodable { let vectorSHA256: String, score: Double }
}
private struct IntegrationCloseout: Decodable {
    let schemaVersion: Int, status: String, approvedForProductIntegration: Bool
    let decisionSHA256: String, profileSHA256: String, acceptanceID: String, thresholdBasis: String, computeUnits: String
    let backend: String, fingerprintVersion: String, policyVersion: String, modelSHA256: String, activeSuiteSHA256: String
    let threshold: Double, regression: Regression, statisticalAcceptance: Statistical
    struct Regression: Decodable {
        let sha256: String, caseCount: Int, passCount: Int, contentFailures: [String], actionFailures: [String]
        let sameImagePairsAndVectors: Bool, independent: Bool, newImageInference: Bool
    }
    struct Statistical: Decodable { let status: String, falseSkipUpperBoundClaimed: Bool, recallConfidenceClaimed: Bool }
}

public extension DedupConfiguration {
    /// Folder resource copied into PhotoSyncCore by the package step. Never search work/research paths.
    static func bundledResourceDirectory() throws -> URL {
        guard let root = Bundle(for: PhotoKitGateway.self).resourceURL else { throw AdvancedDedupError.invalidConfiguration }
        return root.appendingPathComponent("AdvancedDedup", isDirectory: true)
    }
}

/// Committed representation-row mutations, not photo counts. A batch may later abort.
public struct IndexMutationCounts: Sendable, Equatable {
    public var added = 0
    public var changed = 0
    public var deleted = 0
    public init() {}
}
