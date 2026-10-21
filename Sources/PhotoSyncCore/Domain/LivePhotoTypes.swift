import Foundation

public enum LivePhotoRole: String, Codable, Sendable { case photo, motion }

public struct LivePhotoIdentity: Codable, Equatable, Sendable {
    public let contentIdentifier: String
    public let role: LivePhotoRole
    public let stillImageTime: Double?
    public let hasAudio: Bool?

    public init(contentIdentifier: String, role: LivePhotoRole, stillImageTime: Double? = nil, hasAudio: Bool? = nil) {
        self.contentIdentifier = contentIdentifier
        self.role = role
        self.stillImageTime = stillImageTime
        self.hasAudio = hasAudio
    }
}

public enum LivePhotoInspection: Codable, Equatable, Sendable {
    case identified(LivePhotoIdentity)
    case noIdentifier
    case unresolved(String)
}

public enum LivePhotoResourceRef: Codable, Hashable, Sendable {
    case source(fileID: UUID, stamp: FileStamp)
    case photos(contextID: UUID, assetID: String, resourceKey: String, revision: String)

    var key: String {
        switch self {
        case .source(let id, _): return "source:\(id.uuidString)"
        case .photos(let context, let asset, let resource, _):
            return "photos:\(context.uuidString):\(asset.utf8.count):\(asset):\(resource)"
        }
    }
    var revision: String {
        switch self {
        case .source(_, let stamp): return "\(stamp.size):\(stamp.modifiedNanoseconds)"
        case .photos(_, _, _, let revision): return revision
        }
    }
    var assetID: String? { if case .photos(_, let id, _, _) = self { return id }; return nil }
    var sourceFileID: UUID? { if case .source(let id, _) = self { return id }; return nil }
}

public struct LivePhotoObservation: Codable, Equatable, Sendable {
    public let resource: LivePhotoResourceRef
    public let inspection: LivePhotoInspection
    public let inspectionVersion: Int
    public let checkedAt: Date
    public var identity: LivePhotoIdentity? { if case .identified(let value) = inspection { return value }; return nil }
    public init(resource: LivePhotoResourceRef, inspection: LivePhotoInspection, inspectionVersion: Int = 1, checkedAt: Date = Date()) {
        self.resource = resource; self.inspection = inspection; self.inspectionVersion = inspectionVersion; self.checkedAt = checkedAt
    }
}

public struct LivePhotoAssetDescriptor: Codable, Equatable, Sendable {
    public let context: LibraryContext
    public let assetID: String
    public let revision: String
    public let isLivePhoto: Bool
    public let mediaKind: MediaKind
    public let resources: [LivePhotoResourceRef]
    public var originalFilenames: [String]
    public var resourceKinds: [MediaKind?]
    public init(context: LibraryContext, assetID: String, revision: String, isLivePhoto: Bool, mediaKind: MediaKind,
                resources: [LivePhotoResourceRef], originalFilenames: [String] = [], resourceKinds: [MediaKind?] = []) {
        self.context = context; self.assetID = assetID; self.revision = revision; self.isLivePhoto = isLivePhoto
        self.mediaKind = mediaKind; self.resources = resources; self.originalFilenames = originalFilenames
        self.resourceKinds = resourceKinds.isEmpty ? Array(repeating: mediaKind, count: resources.count) : resourceKinds
    }
}

public enum PreservedField<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    case emptyOrNotApplicable
    case value(Value)
    case unknown
    var isKnown: Bool { if case .unknown = self { return false }; return true }
}

public struct LivePhotoLocation: Codable, Equatable, Sendable {
    public var latitude: Double, longitude: Double, altitude: Double
}

public struct LivePhotoPreservationSnapshot: Codable, Equatable, Sendable {
    public var revision: String
    public var creationDate: PreservedField<Date> = .unknown
    public var location: PreservedField<LivePhotoLocation> = .unknown
    public var favorite: PreservedField<Bool> = .unknown
    public var hidden: PreservedField<Bool> = .unknown
    public var rating: PreservedField<Int> = .unknown
    public var title: PreservedField<String> = .unknown
    public var caption: PreservedField<String> = .unknown
    public var keywords: PreservedField<[String]> = .unknown
    public var albumIDs: PreservedField<[String]> = .unknown
    public var hasAdjustments: PreservedField<Bool> = .unknown
    public var hasExtraResources: PreservedField<Bool> = .unknown
    public var isSharedAlbum: PreservedField<Bool> = .unknown
    public init(revision: String) { self.revision = revision }
}

public struct LivePhotoGroup: Codable, Equatable, Sendable {
    public var id: UUID
    public let contextID: UUID
    public let contentIdentifier: String
    public var targetID: String?
    public var deleted: Bool
    public var completed: Bool
    public init(id: UUID = UUID(), contextID: UUID, contentIdentifier: String, targetID: String? = nil, deleted: Bool = false, completed: Bool = false) {
        self.id = id; self.contextID = contextID; self.contentIdentifier = contentIdentifier
        self.targetID = targetID; self.deleted = deleted; self.completed = completed
    }
}

public struct LivePhotoVerification: Codable, Equatable, Sendable {
    public var assetID: String
    public var revision: String
    public var passed: Bool
    public var details: [String]
    public init(assetID: String, revision: String, passed: Bool, details: [String] = []) {
        self.assetID = assetID; self.revision = revision; self.passed = passed; self.details = details
    }
}

public struct LivePhotoOperation: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable { case planned, creating, created, verifying, readyToRetire, retiring, complete, blocked }
    public enum Evidence: String, Codable, Sendable { case notSubmitted, submitted, confirmed, unknown, failed }
    public var id: UUID
    public var groupID: UUID
    public var context: LibraryContext
    public let contentIdentifier: String
    public var photo: LivePhotoResourceRef
    public var motion: LivePhotoResourceRef
    public var sourceFileIDs: [UUID]
    public var oldAssetIDs: [String]
    public var preservation: LivePhotoPreservationSnapshot?
    public var oldSnapshots: [String: LivePhotoPreservationSnapshot] = [:]
    public var stage: Stage = .planned
    public var creationEvidence: Evidence = .notSubmitted
    public var retirementEvidence: Evidence = .notSubmitted
    public var placeholderID: String?
    public var targetID: String?
    public var reusedTarget = false
    public var requiredTargetID: String?
    public var discoveryResources: [LivePhotoResourceRef]?
    public var equivalentResources: [LivePhotoResourceRef]?
    public var sourceStamps: [String: FileStamp]?
    public var verification: LivePhotoVerification?
    public var error: String?
    public var nextRetryAt: Date?
    public init(id: UUID = UUID(), groupID: UUID = UUID(), context: LibraryContext, contentIdentifier: String,
                photo: LivePhotoResourceRef, motion: LivePhotoResourceRef, sourceFileIDs: [UUID] = [], oldAssetIDs: [String] = []) {
        self.id = id; self.groupID = groupID; self.context = context; self.contentIdentifier = contentIdentifier
        self.photo = photo; self.motion = motion; self.sourceFileIDs = sourceFileIDs; self.oldAssetIDs = oldAssetIDs
    }
    var holdsUnknownMutation: Bool { creationEvidence == .unknown || creationEvidence == .submitted || retirementEvidence == .unknown || retirementEvidence == .submitted }
    var releasesMembers: Bool { stage == .complete || (stage == .blocked && !holdsUnknownMutation && targetID == nil) }
}

public enum LivePhotoInventoryPhase: String, Codable, Sendable { case enumerating, identifying, completed }
public struct LivePhotoInventorySummary: Equatable, Sendable {
    public var phase: LivePhotoInventoryPhase
    public var inventoried: Int
    public var identified: Int
    public var unresolved: Int
    public var completedAt: Date?
    public init(phase: LivePhotoInventoryPhase = .enumerating, inventoried: Int = 0, identified: Int = 0, unresolved: Int = 0, completedAt: Date? = nil) {
        self.phase = phase; self.inventoried = inventoried; self.identified = identified; self.unresolved = unresolved; self.completedAt = completedAt
    }
}
public struct LivePhotoWorkSummary: Equatable, Sendable {
    public var activeGroups = 0, awaitingVerification = 0, awaitingRetirement = 0
    public var unknownMutation = false
    public var limitedGroups = 0
    public var issue: SourceIssue?
    public init() {}
}

public struct LivePhotoAssetPage: Sendable {
    public let context: LibraryContext
    public let generation: Int
    public let assets: [LivePhotoAssetDescriptor]
    public let nextOffset: Int?
    public init(context: LibraryContext, generation: Int, assets: [LivePhotoAssetDescriptor], nextOffset: Int?) {
        self.context = context; self.generation = generation; self.assets = assets; self.nextOffset = nextOffset
    }
}
