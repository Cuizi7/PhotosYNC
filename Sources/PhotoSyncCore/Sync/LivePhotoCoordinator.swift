import Foundation

public protocol LivePhotoDirectoryObserving: Sendable {
    func observeDirectory(sourceID: UUID, relativeDirectory: String, fileIDs: [UUID]) async throws
}

struct DirectoryBatchKey: Hashable, Sendable {
    let sourceID: UUID
    let relativeDirectory: String
    init(sourceID: UUID, relativeDirectory: String) {
        self.sourceID = sourceID
        self.relativeDirectory = relativeDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    init(file: SourceFile) {
        self.init(sourceID: file.sourceID, relativeDirectory: (file.relativePath as NSString).deletingLastPathComponent)
    }
}

enum DirectoryBatchState: Sendable { case enumerating, identifying, ready }

/// One serial owner of group intentions. The gateway owns the actual, shared PhotoKit request slot.
public actor LivePhotoCoordinator: LivePhotoDirectoryObserving {
    private let store: SyncStore
    private let photos: any LivePhotoPhotosGateway
    private let metadata: any LivePhotoMetadataReading
    private let budget: LivePhotoResourceBudget
    private let executor: ReadExecutor
    private let sourceAdmission: @Sendable (SourceFile) -> Bool
    private let admission = LivePhotoPauseGate()
    private var paused = false, working = false, recovered = false
    private var discoveryCursor: String?
    private var operationCursor: UUID?
    /// Source admission must synchronously consult the current directory round;
    /// it is checked again by the physical mutation guard. Without it only
    /// Photos-only groups can advance. The gateway still owns callback lifetime.
    public init(store: SyncStore, photos: any LivePhotoPhotosGateway, metadata: any LivePhotoMetadataReading = LivePhotoMetadataReader(),
                budget: LivePhotoResourceBudget = .shared, executor: ReadExecutor = .shared, sourceAdmission: @escaping @Sendable (SourceFile) -> Bool = { _ in false }) {
        self.store = store; self.photos = photos; self.metadata = metadata; self.budget = budget; self.executor = executor; self.sourceAdmission = sourceAdmission
    }
    public func setPaused(_ value: Bool) { paused = value; admission.setPaused(value) }
    public func observeDirectory(sourceID: UUID, relativeDirectory: String, fileIDs: [UUID]) async throws {
        guard !paused else { return }
        let context = try await photos.livePhotoLibraryContext()
        var ids = Set<String>()
        for id in fileIDs {
            guard let file = try await store.sourceFile(id: id),
                  let observation = try await store.livePhotoObservation(for: .source(fileID: id, stamp: file.file.stamp)), let identity = observation.identity else { continue }
            ids.insert(identity.contentIdentifier)
        }
        for id in ids.sorted() { try await discover(id: id, context: context) }
    }
    private func discover(id: String, context: LibraryContext) async throws {
        let group = try await store.livePhotoGroup(context: context, contentIdentifier: id)
        if group?.deleted == true { return }
        let observations = try await store.livePhotoObservations(contentIdentifier: id, context: context)
        var available = [LivePhotoObservation](), files = [UUID](), hasNewMember = false
        for observation in observations {
            let needsCompletion = try await store.livePhotoObservationNeedsCompletion(observation.resource, context: context, targetID: group?.targetID)
            if let fileID = observation.resource.sourceFileID {
                guard let file = try await store.sourceFile(id: fileID), file.state != .importing,
                      file.file.stamp == sourceStamp(observation.resource), try await store.livePhotoSourceMayParticipate(fileID) else { continue }
                if needsCompletion { files.append(fileID) }
            }
            hasNewMember = hasNewMember || needsCompletion
            available.append(observation)
        }
        guard !paused, hasNewMember, let photo = available.first(where: { $0.identity?.role == .photo }), let motion = available.first(where: { $0.identity?.role == .motion }) else { return }
        guard !(try await store.livePhotoDiscoveryIsBlocked(context: context, contentIdentifier: id, resources: available.map(\.resource))) else { return }
        var op = LivePhotoOperation(context: context, contentIdentifier: id, photo: photo.resource, motion: motion.resource, sourceFileIDs: Array(Set(files)).sorted { $0.uuidString < $1.uuidString })
        op.discoveryResources = available.map(\.resource)
        _ = try await store.reserveLivePhotoOperation(op)
    }
    private func sourceStamp(_ ref: LivePhotoResourceRef) -> FileStamp? { if case .source(_, let stamp) = ref { return stamp }; return nil }

    public func recover() async throws {
        guard !working else { return }
        working = true; defer { working = false }
        let operations = try await store.loadLivePhotoOperationsForRecovery()
        await photos.setLivePhotoRecoveryBlocks(Set(operations.filter(\.holdsUnknownMutation).map(\.id)))
        guard !paused else { return }
        let currentContext = try await photos.livePhotoLibraryContext()
        let binding = try await store.livePhotoIdentityBinding(context: currentContext)
        guard !paused, try await photos.verifyLivePhotoContext(context: currentContext, anchorAssetIDs: binding.anchors, allowUnanchored: !binding.requiresProof) else { return }
        for original in operations where original.context.id == currentContext.id {
            guard !paused else { return }
            var op = original
            if op.context != currentContext {
                guard try await store.rebindLivePhotoOperationContext(operationID: op.id, expected: op.context, current: currentContext) else { continue }
                op.context = currentContext
            }
            guard op.creationEvidence == .submitted || op.creationEvidence == .unknown else { continue }
            // A missing placeholder is unknown; it never grants permission to create again.
            if case .found(let id) = try await photos.reconcile(placeholder: op.placeholderID) {
                try await store.confirmLivePhotoCreation(operationID: op.id, identifier: id)
            }
        }
        try await refreshBlocks(); recovered = true
    }
    private func refreshBlocks() async throws {
        let ops = try await store.loadLivePhotoOperationsForRecovery()
        await photos.setLivePhotoRecoveryBlocks(Set(ops.filter(\.holdsUnknownMutation).map(\.id)))
    }
    public func summary() async throws -> LivePhotoWorkSummary {
        let operations = try await store.loadLivePhotoOperationsForRecovery()
        var value = LivePhotoWorkSummary()
        var active = Set<UUID>(), verify = Set<UUID>(), retire = Set<UUID>(), limited = Set<UUID>()
        for op in operations {
            if op.holdsUnknownMutation { value.unknownMutation = true }
            if let error = op.error {
                if !op.holdsUnknownMutation { limited.insert(op.groupID) }
                if value.issue == nil { value.issue = SourceIssue(summary: op.targetID == nil ? "部分 Live Photo 待核实" : "Live Photo 已补齐，旧项目待清理", detail: error, kind: .submission) }
            }
            if op.stage == .created || op.stage == .verifying { verify.insert(op.groupID) }
            if op.stage == .readyToRetire || op.stage == .retiring { retire.insert(op.groupID) }
            if op.stage != .blocked && op.error == nil { active.insert(op.groupID) }
        }
        value.activeGroups = active.count; value.awaitingVerification = verify.count; value.awaitingRetirement = retire.count; value.limitedGroups = limited.count
        return value
    }
    public func advanceNext(now: Date) async throws -> Bool {
        guard !paused, !working else { return false }
        if !recovered { try await recover() }
        guard !paused, !working else { return false }
        working = true; defer { working = false }
        let context = try await photos.livePhotoLibraryContext()
        let ids = try await store.livePhotoIdentifiedIDs(context: context, after: discoveryCursor, limit: 64)
        for id in ids { try await discover(id: id, context: context) }
        discoveryCursor = ids.last
        let operations = try await store.loadLivePhotoOperationsForRecovery()
        guard !operations.contains(where: \.holdsUnknownMutation), !paused else { return false }
        let prioritized = operations.filter { $0.context == context && $0.stage != .blocked && ($0.nextRetryAt == nil || $0.nextRetryAt! <= now) }
            .sorted { ($0.stage == .planned ? 1 : 0, $0.id.uuidString) < ($1.stage == .planned ? 1 : 0, $1.id.uuidString) }
        var ordered = prioritized
        if let operationCursor, let index = prioritized.firstIndex(where: { $0.id == operationCursor }) {
            ordered = Array(prioritized.dropFirst(index + 1)) + Array(prioritized.prefix(index + 1))
        }
        for op in ordered.prefix(64) {
            operationCursor = op.id
            guard !paused else { return false }
            if let group = try await store.livePhotoGroup(context: context, contentIdentifier: op.contentIdentifier), group.deleted {
                var stopped = op; stopped.stage = .blocked; stopped.error = "关联项目已删除，已停止自动补齐"
                _ = try await store.saveLivePhotoOperation(stopped, expectedStage: op.stage); continue
            }
            do { if try await advance(op, now: now) { return true } }
            catch {
                if error is CancellationError { return false }
                if error is PhotosAdmissionDeferred || error is ReadExecutorError { continue }
                // Read/verification limits affect this group, not unrelated ordinary imports.
                if let current = try await store.livePhotoOperation(id: op.id), !current.holdsUnknownMutation {
                    var waiting = current; waiting.error = "Live Photo 补齐受限：" + SourceIssueText.systemDiagnostic(error); waiting.nextRetryAt = now.addingTimeInterval(60)
                    _ = try await store.saveLivePhotoOperation(waiting, expectedStage: current.stage)
                }
                throw error
            }
        }
        return false
    }
    private func advance(_ incoming: LivePhotoOperation, now: Date) async throws -> Bool {
        var op = incoming
        switch op.stage {
        case .planned:
            let generation = try await photos.candidateSnapshot().generation
            guard try await photos.livePhotoLibraryContext() == op.context else { return false }
            var unresolvedTarget = false
            if op.requiredTargetID == nil { unresolvedTarget = try await store.hasUnresolvedLivePhotoCandidates(context: op.context) }
            guard try await store.livePhotoInventorySummary(context: op.context).phase == .completed,
                  !unresolvedTarget, !paused else { return false }
            guard let resolved = try await resolve(op) else {
                op.discoveryResources = try await eligibleDiscoveryResources(context: op.context, identifier: op.contentIdentifier)
                op.stage = .blocked; op.error = "配对资源存在歧义或暂不可用，已保留原项目"
                _ = try await store.saveLivePhotoOperation(op, expectedStage: .planned); return true
            }
            op = resolved
            guard !paused, try await store.saveLivePhotoOperation(op, expectedStage: .planned) else { return false }
            if let target = try await existingTarget(op) {
                guard !paused, try await sourcesAdmitted(op), try await photos.livePhotoLibraryContext() == op.context else { return false }
                try await store.reuseLivePhotoTarget(operationID: op.id, identifier: target); return true
            }
            let photo = try await input(op.photo), motion = try await input(op.motion)
            let photoIdentity = try await metadata.inspect(resource: photo, kind: .image)
            let motionIdentity = try await metadata.inspect(resource: motion, kind: .video)
            guard case .identified(let p) = photoIdentity, case .identified(let m) = motionIdentity,
                  p.role == .photo, m.role == .motion, p.contentIdentifier == op.contentIdentifier, m.contentIdentifier == op.contentIdentifier,
                  m.stillImageTime != nil else {
                try await store.saveLivePhotoObservation(.init(resource: op.photo, inspection: photoIdentity))
                try await store.saveLivePhotoObservation(.init(resource: op.motion, inspection: motionIdentity))
                throw PhotosRepresentationError.ambiguousResource
            }
            guard !paused, try await sourcesAdmitted(op) else { return false }
            guard !paused, try await photos.livePhotoLibraryContext() == op.context, try store.livePhotoMutationAllowed(operationID: op.id, stage: .planned) else { return false }
            try await store.beginLivePhotoCreation(operationID: op.id)
            do {
                let check = try await mutationGuard(op: op, stage: .creating)
                let id = try await photos.createLivePhoto(photoURL: photo.url, motionURL: motion.url, photoFilename: try await filename(op.photo), motionFilename: try await filename(op.motion), preservation: op.preservation ?? LivePhotoRetirementPolicy.empty,
                    expectedGeneration: generation, beforeMutation: check, onPlaceholder: { [store, id = op.id] placeholder in try store.checkpointLivePhotoPlaceholder(operationID: id, identifier: placeholder) })
                // Leases remain strongly held until the actual lifecycle completion, including cancellation.
                withExtendedLifetime([photo, motion]) {}
                try await store.confirmLivePhotoCreation(operationID: op.id, identifier: id)
            } catch {
                let deferred = error is PhotosAdmissionDeferred
                let definite = deferred || (error as? PhotoKitGatewayError)?.recoveryEvidence == .definitelyNotCommitted
                if !definite { await photos.setLivePhotoRecoveryBlocks([op.id]) }
                try await store.deferLivePhotoCreation(operationID: op.id, detail: deferred ? nil : SourceIssueText.systemDiagnostic(error), definite: definite)
                try await refreshBlocks()
                if !deferred { throw error }
                return false
            }
            return true
        case .created, .verifying:
            guard let target = op.targetID, !paused else { return false }
            let verification = try await photos.verifyLivePhoto(assetID: target, operation: op)
            guard !paused else { return false }
            let preserved = verification.passed ? try await targetContainsInputs(op) : false
            var result = verification
            result.passed = result.passed && preserved
            result.details.append(preserved ? "原始资源逐字节一致，方向、画面、时长和音轨保持" : "原始资源一致性尚未确认")
            try await store.recordLivePhotoVerification(operationID: op.id, verification: result)
            return true
        case .readyToRetire:
            guard !paused, let target = op.targetID else { return false }
            if op.oldAssetIDs.isEmpty { try await store.completeLivePhotoWithoutRetirement(operationID: op.id); return true }
            let generation = try await photos.candidateSnapshot().generation
            let targetDescriptor = try await photos.livePhotoAssets(assetIDs: [target], context: op.context).first
            guard targetDescriptor?.isLivePhoto == true, targetDescriptor?.revision == op.verification?.revision else { throw PhotoKitGatewayError.libraryChanged }
            let targetSnapshot = try await photos.livePhotoPreservationSnapshot(assetID: target, context: op.context)
            var reasons = [String]()
            for id in op.oldAssetIDs {
                guard let frozen = op.oldSnapshots[id] else { reasons.append("旧项目快照未知"); continue }
                let current = try await photos.livePhotoPreservationSnapshot(assetID: id, context: op.context)
                let descriptor = try await photos.livePhotoAssets(assetIDs: [id], context: op.context).first
                // Titles are explicitly excluded from retirement protection; resource revision checks remain mandatory.
                var comparable = current; comparable.title = frozen.title
                guard comparable == frozen, descriptor?.revision == frozen.revision, descriptor?.isLivePhoto == false else { throw PhotoKitGatewayError.libraryChanged }
                let preserved = try await oldResourcePreserved(id: id, target: targetDescriptor!, op: op)
                if case .retain(let why) = LivePhotoRetirementPolicy.evaluate(old: current, target: targetSnapshot, resourcePreserved: preserved) { reasons += why }
            }
            guard reasons.isEmpty else {
                op.error = "Live Photo 已补齐，旧项目待清理：" + Set(reasons).sorted().joined(separator: "；")
                op.nextRetryAt = .distantFuture // Do not repeatedly prompt or reread unchanged protected information.
                _ = try await store.saveLivePhotoOperation(op, expectedStage: .readyToRetire); return true
            }
            guard !paused, try await sourcesAdmitted(op), try await photos.candidateSnapshot().generation == generation,
                  try await store.beginLivePhotoRetirement(operationID: op.id, assetIDs: op.oldAssetIDs) else { return false }
            do {
                let check = try await mutationGuard(op: op, stage: .retiring)
                try await photos.retireLivePhotoComponents(assetIDs: op.oldAssetIDs, expectedGeneration: generation, beforeMutation: check)
                try await store.confirmLivePhotoRetirement(operationID: op.id)
            } catch {
                if var current = try await store.livePhotoOperation(id: op.id) {
                    current.error = "Live Photo 已补齐，旧项目待清理：" + SourceIssueText.systemDiagnostic(error)
                    current.nextRetryAt = .distantFuture
                    if error is PhotosAdmissionDeferred {
                        current.error = nil; current.nextRetryAt = now.addingTimeInterval(5)
                        current.retirementEvidence = .notSubmitted; current.stage = .readyToRetire
                    } else if (error as? PhotoKitGatewayError)?.recoveryEvidence == .definitelyNotCommitted {
                        current.retirementEvidence = .failed; current.stage = .readyToRetire
                    } else { current.retirementEvidence = .unknown }
                    _ = try await store.saveLivePhotoOperation(current, expectedStage: .retiring)
                }
                try await refreshBlocks()
            }
            return true
        default: return false
        }
    }
    private func eligibleDiscoveryResources(context: LibraryContext, identifier: String) async throws -> [LivePhotoResourceRef] {
        let observed = try await store.livePhotoObservations(contentIdentifier: identifier, context: context)
        var refs = [LivePhotoResourceRef]()
        for item in observed {
            if let id = item.resource.sourceFileID {
                guard let file = try await store.sourceFile(id: id), file.state != .importing,
                      file.file.stamp == sourceStamp(item.resource), try await store.livePhotoSourceMayParticipate(id) else { continue }
            }
            refs.append(item.resource)
        }
        return refs
    }
    private func resolve(_ op: LivePhotoOperation) async throws -> LivePhotoOperation? {
        if let target = op.requiredTargetID { return try await resolveAgainstTarget(op, targetID: target) }
        let observations = try await store.livePhotoObservations(contentIdentifier: op.contentIdentifier, context: op.context)
        var result = op, selected = [LivePhotoResourceRef](), oldIDs = Set<String>()
        result.equivalentResources = []
        result.sourceFileIDs = []
        for id in op.sourceFileIDs where try await store.livePhotoSourceMayParticipate(id) {
            result.sourceFileIDs.append(id)
        }
        for role in [LivePhotoRole.photo, .motion] {
            var refs = [LivePhotoResourceRef]()
            for o in observations where o.identity?.role == role {
                if let id = o.resource.assetID {
                    guard let descriptor = try await store.livePhotoAssetDescriptor(context: op.context, assetID: id) else { continue }
                    if !descriptor.isLivePhoto { oldIDs.insert(id); refs.append(o.resource) }
                } else if let id = o.resource.sourceFileID, let file = try await store.sourceFile(id: id), try await store.livePhotoSourceMayParticipate(id), file.file.stamp == sourceStamp(o.resource) {
                    // A prior successful item must have an accessible, identified original; never resurrect a missing Photos asset.
                    if let success = file.successID {
                        guard let descriptor = try await store.livePhotoAssetDescriptor(context: op.context, assetID: success), !descriptor.isLivePhoto else { continue }
                        guard observations.contains(where: { $0.resource.assetID == success && $0.identity?.role == role }) else { throw PhotosRepresentationError.unavailable }
                    }
                    refs.append(o.resource)
                }
            }
            refs.sort { ($0.assetID == nil ? 1 : 0, $0.key) < ($1.assetID == nil ? 1 : 0, $1.key) }
            // Different versions, including existing complete targets, remain ambiguous.
            for ref in observations.filter({ $0.identity?.role == role && $0.resource.assetID != nil }).map(\.resource) where !refs.contains(ref) { refs.append(ref) }
            guard let first = refs.first else { return nil }
            for ref in refs.dropFirst() { if try await !equal(first, ref) { return nil } }
            result.equivalentResources?.append(contentsOf: refs.filter { $0.assetID != nil })
            selected.append(first)
        }
        result.photo = selected[0]; result.motion = selected[1]; result.oldAssetIDs = oldIDs.sorted()
        result.oldSnapshots = [:]
        for id in result.oldAssetIDs { result.oldSnapshots[id] = try await photos.livePhotoPreservationSnapshot(assetID: id, context: op.context) }
        let photo = result.photo.assetID.flatMap { result.oldSnapshots[$0] } ?? LivePhotoRetirementPolicy.empty
        let motion = result.motion.assetID.flatMap { result.oldSnapshots[$0] } ?? LivePhotoRetirementPolicy.empty
        result.preservation = LivePhotoRetirementPolicy.mergeForCreation(photo: photo, motion: motion)
        return result
    }
    private func resolveAgainstTarget(_ op: LivePhotoOperation, targetID: String) async throws -> LivePhotoOperation? {
        guard let target = try await photos.livePhotoAssets(assetIDs: [targetID], context: op.context).first, target.isLivePhoto,
              target.resourceKinds.filter({ $0 == .image }).count == 1, target.resourceKinds.filter({ $0 == .video }).count == 1 else { throw PhotosRepresentationError.unavailable }
        try await store.enqueueLivePhotoAssets(context: op.context, assets: [target])
        let cached = try await store.livePhotoObservations(contentIdentifier: op.contentIdentifier, context: op.context)
        var observations = [LivePhotoObservation]()
        var byRole = [LivePhotoRole: LivePhotoResourceRef]()
        var needsInventoryResult = false
        for (i, ref) in target.resources.enumerated() {
            guard i < target.resourceKinds.count, let kind = target.resourceKinds[i] else { continue }
            let inspection: LivePhotoInspection
            if let known = cached.first(where: { $0.resource == ref }) { inspection = known.inspection }
            else {
                let lease = try await input(ref)
                inspection = try await metadata.inspect(resource: lease, kind: kind)
                needsInventoryResult = true
            }
            guard case .identified(let identity) = inspection, identity.contentIdentifier == op.contentIdentifier else { return nil }
            byRole[identity.role] = ref; observations.append(.init(resource: ref, inspection: inspection))
        }
        guard let photo = byRole[.photo], let motion = byRole[.motion] else { return nil }
        if needsInventoryResult {
            try await store.recordLivePhotoInventoryResult(context: op.context, assetID: targetID, revision: target.revision, observations: observations)
        }
        var result = op; result.photo = photo; result.motion = motion; result.oldAssetIDs = []; result.oldSnapshots = [:]
        result.equivalentResources = [photo, motion]
        result.sourceFileIDs = []
        for id in op.sourceFileIDs where try await store.livePhotoSourceMayParticipate(id) { result.sourceFileIDs.append(id) }
        let all = try await store.livePhotoObservations(contentIdentifier: op.contentIdentifier, context: op.context)
        for observed in all {
            let sourceMember = observed.resource.sourceFileID.map { result.sourceFileIDs.contains($0) } ?? false
            let needsCompletion = try await store.livePhotoObservationNeedsCompletion(observed.resource, context: op.context, targetID: targetID)
            guard sourceMember || (observed.resource.assetID != nil && needsCompletion) else { continue }
            guard let role = observed.identity?.role, let counterpart = byRole[role], try await equal(observed.resource, counterpart) else { return nil }
            if observed.resource.assetID != nil { result.equivalentResources?.append(observed.resource) }
            if let asset = observed.resource.assetID, let descriptor = try await store.livePhotoAssetDescriptor(context: op.context, assetID: asset), !descriptor.isLivePhoto {
                result.oldAssetIDs.append(asset)
            }
        }
        result.oldAssetIDs = Array(Set(result.oldAssetIDs)).sorted()
        for id in result.oldAssetIDs { result.oldSnapshots[id] = try await photos.livePhotoPreservationSnapshot(assetID: id, context: op.context) }
        return result
    }
    private func existingTarget(_ op: LivePhotoOperation) async throws -> String? {
        if let target = op.requiredTargetID { return target }
        let obs = try await store.livePhotoObservations(contentIdentifier: op.contentIdentifier, context: op.context)
        for id in Set(obs.compactMap { $0.resource.assetID }).sorted() {
            guard let d = try await store.livePhotoAssetDescriptor(context: op.context, assetID: id), d.isLivePhoto,
                  let p = obs.first(where: { $0.resource.assetID == id && $0.identity?.role == .photo }),
                  let m = obs.first(where: { $0.resource.assetID == id && $0.identity?.role == .motion }) else { continue }
            if try await equal(p.resource, op.photo), try await equal(m.resource, op.motion) { return id }
        }
        return nil
    }
    private func input(_ ref: LivePhotoResourceRef) async throws -> LivePhotoResourceLease {
        if case .source(let id, let stamp) = ref {
            guard let file = try await store.sourceFile(id: id), file.file.stamp == stamp,
                  try await DirectoryReader(sourceID: file.file.sourceID, executor: executor).stamp(of: file.file.url) == stamp else { throw PhotoKitGatewayError.libraryChanged }
            return .init(url: file.file.url)
        }
        return try await photos.readLivePhotoResource(ref, purpose: .completion, budget: budget)
    }
    private func equal(_ a: LivePhotoResourceRef, _ b: LivePhotoResourceRef) async throws -> Bool {
        if a == b { return true }
        let left = try await input(a), right = try await input(b)
        return try await executor.execute(sourceID: UUID()) { try LivePhotoResourceLease.filesEqual(left.url, right.url) }
    }
    private func filename(_ ref: LivePhotoResourceRef) async throws -> String? {
        if let id = ref.sourceFileID { return try await store.sourceFile(id: id)?.file.metadata.filename }
        guard let id = ref.assetID, let d = try await store.livePhotoAssetDescriptor(context: try await photos.livePhotoLibraryContext(), assetID: id),
              let index = d.resources.firstIndex(of: ref), index < d.originalFilenames.count else { return nil }
        return d.originalFilenames[index]
    }
    private func targetContainsInputs(_ op: LivePhotoOperation) async throws -> Bool {
        guard let target = op.targetID, let d = try await photos.livePhotoAssets(assetIDs: [target], context: op.context).first else { return false }
        let pairs = d.resources.enumerated().compactMap { i, ref -> (MediaKind, LivePhotoResourceRef)? in guard i < d.resourceKinds.count, let kind = d.resourceKinds[i] else { return nil }; return (kind, ref) }
        guard let photo = pairs.first(where: { $0.0 == .image })?.1, let motion = pairs.first(where: { $0.0 == .video })?.1 else { return false }
        let photoEqual = try await equal(photo, op.photo)
        return photoEqual ? try await equal(motion, op.motion) : false
    }
    private func oldResourcePreserved(id: String, target: LivePhotoAssetDescriptor, op: LivePhotoOperation) async throws -> Bool {
        guard let old = try await store.livePhotoAssetDescriptor(context: op.context, assetID: id), !old.isLivePhoto, old.resources.count == 1,
              let observed = try await store.livePhotoObservation(for: old.resources[0]), let role = observed.identity?.role else { return false }
        let kind: MediaKind = role == .photo ? .image : .video
        guard let index = target.resourceKinds.firstIndex(where: { $0 == kind }), index < target.resources.count else { return false }
        return try await equal(old.resources[0], target.resources[index])
    }
    private func sourcesAdmitted(_ op: LivePhotoOperation) async throws -> Bool {
        for id in op.sourceFileIDs {
            guard let file = try await store.sourceFile(id: id), let frozen = op.sourceStamps?[id.uuidString], file.file.stamp == frozen, sourceAdmission(file.file),
                  try await DirectoryReader(sourceID: file.file.sourceID, executor: executor).stamp(of: file.file.url) == file.file.stamp,
                  sourceAdmission(file.file) else { return false }
        }
        return !paused
    }
    private func mutationGuard(op: LivePhotoOperation, stage: LivePhotoOperation.Stage) async throws -> @Sendable () throws -> Bool {
        var sources = [SourceFile]()
        for id in op.sourceFileIDs {
            guard let file = try await store.sourceFile(id: id), file.file.stamp == op.sourceStamps?[id.uuidString] else { throw PhotosAdmissionDeferred() }
            sources.append(file.file)
        }
        let frozen = sources
        return { [admission, store, sourceAdmission] in
            guard admission.allowed, frozen.allSatisfy(sourceAdmission), try store.livePhotoMutationAllowed(operationID: op.id, stage: stage) else { return false }
            for file in frozen {
                _ = try SourceRegistry.normalizedURL(file.url.deletingLastPathComponent())
                let values = try file.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, let date = values.contentModificationDate,
                      FileStamp(size: Int64(size), modifiedNanoseconds: Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded(.down))) == file.stamp else { return false }
            }
            return true
        }
    }
}

private final class LivePhotoPauseGate: @unchecked Sendable {
    private let lock = NSLock(); private var paused = false
    func setPaused(_ value: Bool) { lock.lock(); paused = value; lock.unlock() }
    var allowed: Bool { lock.lock(); defer { lock.unlock() }; return !paused }
}
