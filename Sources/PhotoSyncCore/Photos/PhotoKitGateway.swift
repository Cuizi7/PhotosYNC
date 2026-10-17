import Foundation
import Photos

enum PhotoKitAccess: Sendable, Equatable { case notDetermined, authorized, denied }

// Internal deterministic ordering probe; production construction leaves it nil.
enum PhotoKitQueueSubmissionPhase: Sendable { case observerRecorded, snapshotContended }

struct PhotoKitCreateCommand: Equatable, Sendable {
    let fileURL: URL
    let kind: MediaKind
    let shouldMoveFile: Bool
}

enum PhotoKitSubmissionResult: Sendable {
    case committed(identifier: String)
    case checkpointFailed
    case preventedBeforeMutation
}

enum PhotoKitSubmissionError: Error {
    case checkpointFailed(Error)
}

struct PhotoKitCandidateAsset: Sendable {
    let identifier: String
    let candidates: [MatchCandidate]
    var inputUnchanged: Bool = false
    // Diagnostic facts are independent of the conservative invalidation decision.
    // nil means unavailable; an empty field list means observed with no difference.
    var assetContentChanged: Bool? = nil
    var visibleInputFields: [String]? = nil
    var metadataFields: [String]? = nil

    static func changedRepresentationFields(before: PhotoKitRepresentationAsset, after: PhotoKitRepresentationAsset) -> [String] {
        var fields: [String] = []
        if before.playbackStyle != after.playbackStyle { fields.append("playbackStyle") }
        if before.resources.map({ $0.type.rawValue }).sorted() != after.resources.map({ $0.type.rawValue }).sorted() { fields.append("resourceTypes") }
        if before.resources.map(\.uti).sorted() != after.resources.map(\.uti).sorted() { fields.append("resourceUTIs") }
        if before.resources.map(\.filename).sorted() != after.resources.map(\.filename).sorted() { fields.append("resourceFilenames") }
        let sizes: (PhotoKitRepresentationAsset) -> [String] = { $0.resources.map { resource in
            resource.size.map { "\($0.width)x\($0.height)" } ?? "unknown"
        }.sorted() }
        if sizes(before) != sizes(after) { fields.append("resourceSizes") }
        // Resource associations matter even if the independent field multisets match.
        let associations: (PhotoKitRepresentationAsset) -> [String] = { $0.resources.map { resource in
            "\(resource.type.rawValue):\(resource.uti):\(resource.filename.utf8.count):\(resource.filename):\(resource.size?.width ?? 0)x\(resource.size?.height ?? 0)"
        }.sorted() }
        if fields.isEmpty && associations(before) != associations(after) { fields.append("resourceAssociations") }
        return fields
    }
}

enum PhotoKitCandidateIndexChange: Sendable {
    case incremental(
        removedAssetIDs: Set<String>,
        insertedAssets: [PhotoKitCandidateAsset],
        changedAssets: [PhotoKitCandidateAsset]
    )
    case reload
}

protocol PhotoKitLifecycle: Sendable {
    func currentAccess() -> PhotoKitAccess
    func requestReadWriteAuthorization() async -> PhotoKitAccess
    func isAvailable() -> Bool
    func loadCandidateAssets() throws -> [PhotoKitCandidateAsset]
    func candidateIndexChange(for change: PHChange?) throws -> PhotoKitCandidateIndexChange
    func submit(
        _ command: PhotoKitCreateCommand,
        beforeMutation: @escaping @Sendable () -> Bool,
        onPlaceholder: @escaping @Sendable (String) throws -> Void
    ) async throws -> PhotoKitSubmissionResult
    func fetch(identifier: String) throws -> Bool
    func resetRepresentationCatalog()
    func representationCatalog(offset: Int, limit: Int, context: LibraryContext, generation: Int) throws -> RepresentationPage
    func representationDelta(assetIDs: [String], context: LibraryContext, generation: Int) throws -> RepresentationPage
    func archivedChangeToken() throws -> Data?
    func replayPersistentChanges(_ token: Data, onChange: (PhotosIndexChange) -> Void, onContentChange: ([String]) -> Void) throws -> Bool
}

extension PhotoKitLifecycle {
    func resetRepresentationCatalog() {}
    func representationCatalog(offset: Int, limit: Int, context: LibraryContext, generation: Int) throws -> RepresentationPage {
        throw PhotosRepresentationError.unavailable
    }
    func representationDelta(assetIDs: [String], context: LibraryContext, generation: Int) throws -> RepresentationPage { throw PhotoKitGatewayError.libraryChanged }
    func archivedChangeToken() throws -> Data? { nil }
    func replayPersistentChanges(_ token: Data, onChange: (PhotosIndexChange) -> Void, onContentChange: ([String]) -> Void) throws -> Bool { false }
}

public final class PhotoKitGateway: NSObject, PhotosIndexGateway, @unchecked Sendable {
    private static let candidateLoadAttempts = 3
    private let lifecycle: any PhotoKitLifecycle
    private let photoLibrary: PHPhotoLibrary?
    private let state = PhotoKitState()
    private let candidateIndex: PhotoKitCandidateIndex
    private let representationReader: PhotosRepresentationReader?
    private let catalogBatchSize: Int
    private let changeChannel: PhotosIndexChangeChannel
    private let indexDiagnostics: IndexDiagnostics
    private let diagnostics: @Sendable ([String: String]) -> Void
    private let historyRetry: PhotosHistoryRetry

    public override convenience init() {
        let library = PHPhotoLibrary.shared()
        self.init(lifecycle: SystemPhotoKitLifecycle(photoLibrary: library), observedLibrary: library)
    }

    public convenience init(configuration: DedupConfiguration, imageBudget: ImageWorkBudget, indexDiagnostics: IndexDiagnostics? = nil, diagnostics: @escaping @Sendable ([String: String]) -> Void = { _ in }) {
        let library = PHPhotoLibrary.shared()
        let context = indexDiagnostics ?? IndexDiagnostics(sink: diagnostics)
        let reader = PhotosRepresentationReader(requester: SystemPhotosRepresentationRequester(), budget: imageBudget,
                                                configuration: configuration, indexDiagnostics: context,
                                                resourceLimits: PhotosResourceLimits(maxEncodedBytes: configuration.resources.maxEncodedBytes,
                                                    freeSpaceReserveBytes: configuration.resources.freeSpaceReserveBytes))
        self.init(lifecycle: SystemPhotoKitLifecycle(photoLibrary: library, eventBatchSize: configuration.resources.catalogBatchSize, diagnostics: { context.observation($0) }, indexDiagnostics: context), observedLibrary: library,
                  representationReader: reader, catalogBatchSize: configuration.resources.catalogBatchSize, indexDiagnostics: context, diagnostics: diagnostics)
    }

    init(lifecycle: any PhotoKitLifecycle, representationReader: PhotosRepresentationReader? = nil, catalogBatchSize: Int = 0,
         indexDiagnostics: IndexDiagnostics? = nil, diagnostics: @escaping @Sendable ([String: String]) -> Void = { _ in },
         queueSubmissionProbe: (@Sendable (PhotoKitQueueSubmissionPhase) -> Void)? = nil,
         historyNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        historyRetry = PhotosHistoryRetry(now: historyNow)
        candidateIndex = PhotoKitCandidateIndex(submissionProbe: queueSubmissionProbe)
        let context = indexDiagnostics ?? IndexDiagnostics(sink: diagnostics)
        self.indexDiagnostics = context; self.diagnostics = { context.observation($0) }
        self.representationReader = representationReader
        self.catalogBatchSize = catalogBatchSize
        changeChannel = PhotosIndexChangeChannel(capacity: max(1, catalogBatchSize))
        self.lifecycle = lifecycle
        photoLibrary = nil
        super.init()
    }

    private init(lifecycle: any PhotoKitLifecycle, observedLibrary: PHPhotoLibrary,
                 representationReader: PhotosRepresentationReader? = nil, catalogBatchSize: Int = 0, indexDiagnostics: IndexDiagnostics? = nil, diagnostics: @escaping @Sendable ([String: String]) -> Void = { _ in }) {
        historyRetry = PhotosHistoryRetry(now: { ProcessInfo.processInfo.systemUptime })
        candidateIndex = PhotoKitCandidateIndex()
        let context = indexDiagnostics ?? IndexDiagnostics(sink: diagnostics)
        self.indexDiagnostics = context; self.diagnostics = { context.observation($0) }
        self.representationReader = representationReader
        self.catalogBatchSize = catalogBatchSize
        changeChannel = PhotosIndexChangeChannel(capacity: max(1, catalogBatchSize))
        self.lifecycle = lifecycle
        photoLibrary = observedLibrary
        super.init()
        observedLibrary.register(self as PHPhotoLibraryChangeObserver)
        observedLibrary.register(self as PHPhotoLibraryAvailabilityObserver)
    }

    deinit {
        photoLibrary?.unregisterChangeObserver(self)
        photoLibrary?.unregisterAvailabilityObserver(self)
    }

    public func candidateSnapshot() async throws -> PhotosCandidateSnapshot {
        let start = ProcessInfo.processInfo.systemUptime
        defer { indexDiagnostics.recordTiming(stage: "photos_candidate_snapshot_wall", seconds: ProcessInfo.processInfo.systemUptime - start) }
        for attempt in 0..<Self.candidateLoadAttempts {
            _ = try await usableGeneration()
            do {
                let snapshot = try await candidateIndex.snapshot(
                    lifecycle: lifecycle,
                    currentGeneration: { [state] in state.snapshot().generation },
                    validity: { [state] generation in state.validity(generation: generation) },
                    needsRebuild: { [state] generation in state.needsReindex(generation: generation) }
                )
                let generation = snapshot.generation
                try verifyUsable(generation: generation)
                guard state.markIndexed(generation: generation) else {
                    // A change can arrive between verification and indexing. Recheck so
                    // unavailability and permission loss do not become retryable races.
                    try verifyUsable(generation: generation)
                    throw PhotoKitGatewayError.libraryChanged
                }
                return snapshot
            } catch let error as PhotoKitGatewayError where error == .libraryChanged {
                guard attempt + 1 < Self.candidateLoadAttempts else { throw error }
                await Task.yield()
            }
        }
        throw PhotoKitGatewayError.libraryChanged
    }

    public func changes() -> AsyncStream<PhotosIndexChange> { changeChannel.stream() }

    public func beginCatalogSession(expectedGeneration: Int) async throws -> PhotosCatalogSession {
        let session = try state.beginCatalogSession(expectedGeneration: expectedGeneration)
        lifecycle.resetRepresentationCatalog()
        return session
    }
    public func representationCatalog(session: PhotosCatalogSession, offset: Int, limit: Int) async throws -> RepresentationPage {
        try state.validateCatalogSession(session)
        let page = try await representationCatalog(offset: offset, limit: limit, expectedGeneration: session.baselineGeneration)
        try state.validateCatalogSession(session)
        return page
    }
    public func catalogCoverage(session: PhotosCatalogSession) async throws -> Int {
        try state.validateCatalogSession(session)
        let endpoint = try await catalogCoverage(baselineGeneration: session.baselineGeneration)
        try state.validateCatalogSession(session)
        return endpoint
    }

    public func catalogInvalidationTransferred(session: PhotosCatalogSession) async throws {
        try state.markCatalogInvalidationTransferred(session)
    }
    public func representationCatalogDelta(session: PhotosCatalogSession, delta: PhotosIndexDelta) async throws -> RepresentationPage {
        try state.validateCatalogSession(session)
        let page = try await representationDelta(delta, recoveringSession: session)
        try state.validateCatalogSession(session)
        return page
    }

    public func invalidateObservationContinuity() {
        state.requireInventoryReconciliation()
        diagnostics(["phase": "photos-observer-continuity", "event": "revoked", "reason": "runtime-permission-transition"])
    }

    public func attachIndexStore(_ store: SyncStore) { state.attach(store) }
    public func prepareInventoryReconciliation(previousCheckpoint: LibraryResumeCheckpoint?) async throws -> PhotosInventoryContinuity {
        try historyRetry.check()
        // Drain the ordered classifier before deciding whether the observer session
        // is intact. An inventory wakeup alone is not a content-continuity gap.
        let snapshot = try await candidateSnapshot()
        if let continuous = try state.continuousInventory(previousCheckpoint: previousCheckpoint,
                                                          expectedGeneration: snapshot.generation) {
            diagnostics(["phase": "photos-inventory-continuity", "mode": "observer", "checkpoint": "retained"])
            return continuous
        }
        let checkpoint = try await contextCheckpoint()
        let covered: Bool
        if let previousCheckpoint, let checkpoint {
            covered = try await coverPersistentHistory(from: previousCheckpoint, through: checkpoint)
        } else { covered = false }
        let decision = try state.recoveryInventory(checkpoint: checkpoint, covered: covered)
        diagnostics(["phase": "photos-inventory-continuity", "mode": "recovery",
                     "cacheContinuity": covered ? "covered" : "unknown"])
        return decision
    }

    public func acknowledgeInventory(expectedGeneration: Int, continuity: PhotosInventoryContinuity) async throws {
        let generation = try await usableGeneration()
        guard generation == expectedGeneration, continuity.observerFence != nil,
              state.acknowledgeReconciliation(generation: expectedGeneration, continuity: continuity,
                  { [changeChannel] in changeChannel.reconciled() }) else {
            throw PhotoKitGatewayError.libraryChanged
        }
        historyRetry.succeeded()
        diagnostics(["phase": "photos-inventory-ack", "event": String(expectedGeneration),
                     "delivery": "reconciled", "historyAdmission": "unchanged", "observerContinuity": "established"])
    }

    public func acknowledgeInventory(expectedGeneration: Int) async throws {
        let generation = try await usableGeneration()
        guard generation == expectedGeneration,
              state.acknowledgeReconciliation(generation: expectedGeneration, { [changeChannel] in changeChannel.reconciled() }) else {
            throw PhotoKitGatewayError.libraryChanged
        }
        diagnostics(["phase": "photos-inventory-ack", "event": String(expectedGeneration), "delivery": "reconciled", "historyAdmission": "unchanged"])
    }
    public func catalogCoverage(baselineGeneration: Int) async throws -> Int {
        _ = try await candidateSnapshot() // drains ordered producer classification
        return try state.catalogCoverage(baseline: baselineGeneration)
    }
    public func catalogChanges(baselineGeneration: Int, throughGeneration: Int, afterAssetID: String?, limit: Int) async throws -> PhotosCatalogChangeBatch {
        guard try state.catalogCoverage(baseline: baselineGeneration) == throughGeneration else { throw PhotoKitGatewayError.libraryChanged }
        return try state.catalogChanges(baseline: baselineGeneration, endpoint: throughGeneration, after: afterAssetID, limit: limit)
    }

    public func representationCatalog(offset: Int, limit: Int, expectedGeneration: Int) async throws -> RepresentationPage {
        guard offset >= 0, limit > 0, limit <= catalogBatchSize else { throw PhotosRepresentationError.invalidPage }
        let generation = try await usableGeneration()
        if offset == 0 { guard generation == expectedGeneration else { throw PhotoKitGatewayError.libraryChanged } }
        _ = try state.catalogCoverage(baseline: expectedGeneration)
        let context = state.snapshot().context
        let page = try measured("photos_catalog_body_wall") {
            try lifecycle.representationCatalog(offset: offset, limit: limit, context: context, generation: expectedGeneration)
        }
        _ = try await candidateSnapshot()
        _ = try state.catalogCoverage(baseline: expectedGeneration)
        guard page.context == context, page.generation == expectedGeneration, page.descriptors.count + page.exclusions.count <= limit,
              (page.descriptors + page.exclusions.map(\.descriptor)).allSatisfy({ $0.context == context }),
              page.nextOffset.map({ $0 > offset }) ?? true else { throw PhotosRepresentationError.invalidPage }
        // Reconciliation acknowledgement belongs to the caller after all pages,
        // persisted facts and derived index publish succeed; fetching a last page
        // alone is not sufficient to clear the sticky dirty bit.
        let evidence = try measured("photos_content_evidence_db_wall") {
            try state.invalidationEvidence(generation: state.snapshot().generation,
                pageAssetIDs: Set((page.descriptors + page.exclusions.map(\.descriptor)).map { $0.key.assetID }))
        }
        return RepresentationPage(context: page.context, generation: page.generation, descriptors: page.descriptors,
                                  nextOffset: page.nextOffset, exclusions: page.exclusions,
                                  invalidatedAssetIDs: evidence.ids, invalidateAllCachedRepresentations: evidence.all, inputUnchangedAssetIDs: evidence.unchanged)
    }

    public func representationDelta(_ delta: PhotosIndexDelta) async throws -> RepresentationPage {
        try await representationDelta(delta, recoveringSession: nil)
    }
    private func representationDelta(_ delta: PhotosIndexDelta, recoveringSession: PhotosCatalogSession?) async throws -> RepresentationPage {
        guard delta.isValid, delta.changedAssetIDs.count + delta.deletedAssetIDs.count <= catalogBatchSize else { throw PhotoKitGatewayError.libraryChanged }
        let generation = try await usableGeneration()
        guard generation == delta.toGeneration, state.snapshot().context == delta.context else { throw PhotoKitGatewayError.libraryChanged }
        let page = try measured("photos_delta_body_wall") {
            try lifecycle.representationDelta(assetIDs: delta.changedAssetIDs, context: delta.context, generation: generation)
        }
        try verifyUsable(generation: generation)
        let facts = page.descriptors + page.exclusions.map(\.descriptor)
        guard page.context == delta.context, page.generation == generation, page.nextOffset == nil,
              facts.count <= catalogBatchSize, facts.allSatisfy({ $0.context == delta.context }),
              Set(facts.map(\.key)).count == facts.count,
              Set(facts.map { $0.key.assetID }) == Set(delta.changedAssetIDs) else { throw PhotoKitGatewayError.libraryChanged }
        let transferred = try recoveringSession.map { try state.hasTransferredCatalogInvalidation($0) } ?? false
        let evidence = try measured("photos_content_evidence_db_wall") {
            try state.invalidationEvidence(generation: generation, pageAssetIDs: Set(delta.changedAssetIDs),
                permittingUnverifiedInputEvidence: transferred)
        }
        guard !evidence.all || transferred else { throw PhotoKitGatewayError.libraryChanged }
        return RepresentationPage(context: delta.context, generation: generation, descriptors: page.descriptors,
            nextOffset: nil, exclusions: page.exclusions, invalidatedAssetIDs: evidence.ids, inputUnchangedAssetIDs: evidence.unchanged)
    }

    public func acknowledgeReconciliation(expectedGeneration: Int) async throws {
        let generation = try await usableGeneration()
        guard generation == expectedGeneration,
              state.acknowledgeReconciliation(generation: expectedGeneration, admitHistory: true, { [changeChannel] in changeChannel.reconciled() }) else {
            throw PhotoKitGatewayError.libraryChanged
        }
        diagnostics(["phase": "photos-ready-ack", "event": String(expectedGeneration), "delivery": "reconciled", "historyAdmission": "open"])
    }

    public func representationReadAdmission() async -> PhotosReaderAdmission {
        guard let representationReader else { return .available }
        return await representationReader.admission()
    }

    public func readRepresentation(_ descriptor: RepresentationDescriptor) async throws -> LoadedRepresentation {
        _ = try await usableGeneration()
        let ticket = try state.beginRepresentationRead(descriptor)
        defer { state.endRepresentationRead(ticket) }
        guard let representationReader else { throw PhotosRepresentationError.unavailable }
        let loaded = try await representationReader.read(descriptor) { [state, lifecycle] in
            state.representationReadIsCurrent(ticket, context: descriptor.context) &&
                lifecycle.currentAccess() == .authorized && lifecycle.isAvailable()
        }
        do { _ = try await candidateSnapshot() }
        catch { await loaded.lease.finishPhysicalWork(); throw error }
        guard state.representationReadIsCurrent(ticket, context: descriptor.context),
              lifecycle.currentAccess() == .authorized, lifecycle.isAvailable() else {
            await loaded.lease.finishPhysicalWork(); throw PhotoKitGatewayError.libraryChanged
        }
        return loaded
    }

    public func contextCheckpoint() async throws -> LibraryResumeCheckpoint? {
        try historyRetry.check()
        let start = ProcessInfo.processInfo.systemUptime
        defer { indexDiagnostics.recordTiming(stage: "photos_checkpoint_wall", seconds: ProcessInfo.processInfo.systemUptime - start) }
        do {
            let generation = try await usableGeneration()
            guard let token = try lifecycle.archivedChangeToken() else {
                state.invalidateHistoryAdmission(); state.requireInventoryReconciliation(); return nil
            }
            try verifyUsable(generation: generation)
            return LibraryResumeCheckpoint(context: state.snapshot().context, archivedChangeToken: token, photosGeneration: generation)
        } catch {
            state.invalidateHistoryAdmission(); state.requireInventoryReconciliation()
            historyRetry.failed(); throw error
        }
    }

    public func coverPersistentHistory(from previous: LibraryResumeCheckpoint, through proposed: LibraryResumeCheckpoint) async throws -> Bool {
        try historyRetry.check()
        // This closes existing snapshot/submit fences as well as future admission.
        // No state lock is held during PhotoKit history or SQLite journal work.
        let ticket = state.beginHistoryCoverage()
        defer { state.finishChangeDetails() }
        let diagnostic = indexDiagnostics.operation("history")
        diagnostic.record(["phase": "photos-history-range", "source": "history", "fromRange": indexDiagnostics.tokenHandle(previous.archivedChangeToken), "throughRange": indexDiagnostics.tokenHandle(proposed.archivedChangeToken), "fromGeneration": previous.photosGeneration.map(String.init) ?? "unknown", "throughGeneration": proposed.photosGeneration.map(String.init) ?? "unknown", "tokenEquality": "unknown"])
        defer { diagnostic.finish() }
        guard state.hasStore, previous.context == proposed.context,
              proposed.context == ticket.context, let upperGeneration = proposed.photosGeneration,
              upperGeneration >= 0, upperGeneration <= ticket.generation,
              lifecycle.currentAccess() == .authorized, lifecycle.isAvailable() else {
            state.requireInventoryReconciliation(); return false
        }
        var unknown = false
        let complete: Bool
        do {
            complete = try measured("photos_history_replay_wall") { try lifecycle.replayPersistentChanges(previous.archivedChangeToken, onChange: { event in
                if event == .fullReconcileRequired || event == .contextInvalidated { unknown = true }
            }, onContentChange: { [state, indexDiagnostics] ids in
                let start = ProcessInfo.processInfo.systemUptime
                // History identifies possible updates, not changed model inputs.
                // The mandatory metadata inventory checks every asset's date.
                state.invalidateActiveReads(Set(ids))
                indexDiagnostics.recordTiming(stage: "photos_history_scope_wall", seconds: ProcessInfo.processInfo.systemUptime - start)
                for id in ids { indexDiagnostics.recordCause(context: ticket.context, assetID: id, source: "history", generation: ticket.generation,
                    facts: ["category": "unknown", "content": "unknown", "assetContentChanged": "unknown", "visibleInputFields": "unknown", "metadataFields": "unknown"], operation: diagnostic.id) }
                diagnostic.record(["phase": "photos-history-obligation", "source": "history", "category": "unknown", "reason": "conservative-history-identifiers", "assets": String(ids.count)])
                for id in ids { diagnostic.record(["phase": "photos-history-sample", "source": "history", "category": "unknown", "reason": "conservative-history-identifiers"], assetID: id) }
            }) }
        } catch {
            state.requireInventoryReconciliation()
            diagnostics(["phase": "photos-history-coverage", "result": "unknown", "reason": "history-unavailable"])
            if Self.isUnusableHistoryCursor(error) { historyRetry.succeeded(); return false }
            historyRetry.failed(); throw error
        }
        let coverage = state.historyCoverageFacts(ticket)
        guard complete, !unknown, coverage.valid,
              lifecycle.currentAccess() == .authorized, lifecycle.isAvailable() else {
            state.requireInventoryReconciliation()
            diagnostics(["phase": "photos-history-coverage", "result": "unknown"])
            return false
        }
        // A process-local fence can move while complete durable history is replayed.
        // Keep admission closed and retry with a fresh checkpoint; no content scope
        // has been proved unknown merely because observer details are unfinished.
        if let reason = upperGeneration != ticket.generation ? "upper-generation-stale" : coverage.retryReason {
            diagnostics(["phase": "photos-history-coverage", "result": "deferred", "reason": reason])
            throw PhotoKitGatewayError.libraryChanged
        }
        diagnostics(["phase": "photos-history-coverage", "result": "covered"])
        historyRetry.succeeded()
        return true
    }

    public func restoreInventoryContext(_ context: LibraryContext) async throws {
        let generation = try await usableGeneration()
        guard state.adoptContext(context, generation: generation) != nil else { throw PhotoKitGatewayError.libraryChanged }
    }

    public func resumeContext(_ checkpoint: LibraryResumeCheckpoint) async throws -> Bool {
        try historyRetry.check()
        do {
            try await restoreInventoryContext(checkpoint.context)
            let generation = state.recordChange(expectingDetails: true)
            state.setReplayContext(checkpoint.context)
            let diagnostic = indexDiagnostics.operation("history-resume")
            let start = ProcessInfo.processInfo.systemUptime
            defer {
                state.finishChangeDetails(); state.setReplayContext(nil)
                indexDiagnostics.recordTiming(stage: "photos_history_replay_wall", seconds: ProcessInfo.processInfo.systemUptime - start)
                diagnostic.finish()
            }
            guard try lifecycle.replayPersistentChanges(checkpoint.archivedChangeToken, onChange: { [state] event in
                if event == .fullReconcileRequired || event == .contextInvalidated { state.requireInventoryReconciliation() }
            }, onContentChange: { [state, indexDiagnostics] ids in
                let start = ProcessInfo.processInfo.systemUptime
                // History identifies possible updates, not changed model inputs.
                // The mandatory metadata inventory checks every asset's date.
                state.invalidateActiveReads(Set(ids))
                indexDiagnostics.recordTiming(stage: "photos_history_scope_wall", seconds: ProcessInfo.processInfo.systemUptime - start)
                for id in ids { indexDiagnostics.recordCause(context: checkpoint.context, assetID: id, source: "history", generation: generation,
                    facts: ["category": "unknown", "content": "unknown", "assetContentChanged": "unknown", "visibleInputFields": "unknown", "metadataFields": "unknown"], operation: diagnostic.id) }
            }), let adoptedGeneration = state.adoptContext(checkpoint.context, generation: generation, completingReplay: true) else {
                state.requireInventoryReconciliation(); changeChannel.send(.fullReconcileRequired); return false
            }
            try verifyUsable(generation: adoptedGeneration)
            changeChannel.send(.fullReconcileRequired)
            historyRetry.succeeded()
            return true
        } catch {
            state.requireInventoryReconciliation(); changeChannel.send(.fullReconcileRequired)
            if Self.isUnusableHistoryCursor(error) { historyRetry.succeeded(); return false }
            historyRetry.failed(); throw error
        }
    }

    private static func isUnusableHistoryCursor(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == PHPhotosErrorDomain {
            return error.code == PHPhotosError.persistentChangeTokenExpired.rawValue ||
                error.code == PHPhotosError.persistentChangeDetailsUnavailable.rawValue
        }
        return error.domain == NSCocoaErrorDomain &&
            [NSCoderReadCorruptError, NSCoderValueNotFoundError, NSCoderInvalidValueError].contains(error.code)
    }

    public func loadCandidates() async throws -> [MatchCandidate] {
        try await candidateSnapshot().allCandidates
    }

    public func create(
        fileURL: URL,
        kind: MediaKind,
        expectedGeneration: Int,
        onPlaceholder: @escaping @Sendable (String) throws -> Void
    ) async throws -> String {
        try await create(fileURL: fileURL, kind: kind, expectedGeneration: expectedGeneration,
                         beforeMutation: { true }, guarded: false, onPlaceholder: onPlaceholder)
    }

    public func create(
        fileURL: URL,
        kind: MediaKind,
        expectedGeneration: Int,
        beforeMutation: @escaping @Sendable () throws -> Bool,
        onPlaceholder: @escaping @Sendable (String) throws -> Void
    ) async throws -> String {
        try await create(fileURL: fileURL, kind: kind, expectedGeneration: expectedGeneration,
                         beforeMutation: beforeMutation, guarded: true, onPlaceholder: onPlaceholder)
    }

    private func create(fileURL: URL, kind: MediaKind, expectedGeneration: Int,
                        beforeMutation: @escaping @Sendable () throws -> Bool, guarded: Bool,
                        onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        let generation = try await usableGeneration()
        guard generation == expectedGeneration else {
            if guarded { throw PhotosAdmissionDeferred() }
            throw PhotoKitGatewayError.definitelyNotCommitted("The Photos candidate index was stale before PhotoKit submission.")
        }
        do {
            try requireAdmission(generation: generation)
        } catch PhotoKitGatewayError.libraryChanged {
            if guarded { throw PhotosAdmissionDeferred() }
            throw PhotoKitGatewayError.definitelyNotCommitted("The Photos candidate index was stale before PhotoKit submission.")
        }
        guard fileURL.isFileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PhotoKitGatewayError.definitelyNotCommitted("The source file was unavailable before PhotoKit submission.")
        }

        let guardCheck = PhotoKitMutationGuard(beforeMutation)
        let result: PhotoKitSubmissionResult
        do {
            result = try await lifecycle.submit(
                PhotoKitCreateCommand(fileURL: fileURL, kind: kind, shouldMoveFile: false),
                beforeMutation: { [state, lifecycle] in
                    guardCheck.check() && lifecycle.currentAccess() == .authorized && lifecycle.isAvailable() && state.isReady(generation: generation)
                },
                onPlaceholder: onPlaceholder
            )
        } catch {
            if case .checkpointFailed = error as? PhotoKitSubmissionError {
                state.blockAdditions(.checkpointFailed)
                throw PhotoKitGatewayError.checkpointFailed("The placeholder checkpoint failed.")
            }
            throw classifyChangeFailure(error)
        }

        switch result {
        case .preventedBeforeMutation:
            if let error = guardCheck.failure {
                if let storageError = error as? SyncStoreError { throw storageError }
                throw PhotoKitGatewayError.definitelyNotCommitted(error.localizedDescription)
            }
            if guarded { throw PhotosAdmissionDeferred() }
            throw PhotoKitGatewayError.definitelyNotCommitted("The Photos submission was prevented before mutation.")
        case .checkpointFailed:
            state.blockAdditions(.checkpointFailed)
            throw PhotoKitGatewayError.checkpointFailed("The placeholder checkpoint failed.")
        case .committed(let identifier):
            // A successful PhotoKit completion is the durable success signal. Later
            // fetch or permission loss is health evidence that blocks additions only.
            postCommitHealthCheck(identifier: identifier)
            return identifier
        }
    }

    public func create(
        fileURL: URL,
        kind: MediaKind,
        onPlaceholder: @escaping @Sendable (String) throws -> Void
    ) async throws -> String {
        let snapshot = try await candidateSnapshot()
        return try await create(fileURL: fileURL, kind: kind, expectedGeneration: snapshot.generation, onPlaceholder: onPlaceholder)
    }

    public func reconcile(placeholder: String?) async throws -> ImportEvidence {
        let generation = try await usableGeneration()
        guard let placeholder, !placeholder.isEmpty else { return .unknown }
        let found = try lifecycle.fetch(identifier: placeholder)
        try verifyUsable(generation: generation)
        return found ? .found(identifier: placeholder) : .unknown
    }

    func recordLibraryChangeForTesting() { enqueueLibraryChange(nil) }

    private func enqueueLibraryChange(_ change: PHChange?) {
        let diagnostic = indexDiagnostics.operation("live")
        candidateIndex.enqueueChange(
            change,
            recordChange: { [state] in state.recordObserverChange() },
            lifecycle: lifecycle, indexDiagnostics: indexDiagnostics, diagnostic: diagnostic,
            didIndex: { [weak self] generation in
                guard let self else { return false }
                return self.state.markIndexed(generation: generation)
            },
            onChange: { [state, changeChannel, catalogBatchSize, indexDiagnostics] event, knownNeutral in
                switch event {
                case .incremental(let delta):
                    let persistStart = ProcessInfo.processInfo.systemUptime
                    if !state.recordCatalogChanges(delta, capacity: max(1, catalogBatchSize)) { state.requireInventoryReconciliation() }
                    indexDiagnostics.recordTiming(stage: "photos_live_catalog_persist_wall", seconds: ProcessInfo.processInfo.systemUptime - persistStart)
                    // A large complete scope is durable; stream buffers hold only a wakeup.
                    if delta.changedAssetIDs.count + delta.deletedAssetIDs.count > max(1, catalogBatchSize / 2), state.hasStore {
                        changeChannel.send(.fullReconcileRequired)
                    } else { changeChannel.send(event) }
                    if knownNeutral {
                        // Diagnostic classification only: the original catalog
                        // persistence and publication above always run unchanged.
                        if !delta.changedAssetIDs.isEmpty {
                            indexDiagnostics.observation(["phase": "photos-live-neutral", "source": "live", "category": "input-unchanged",
                                "assets": String(delta.changedAssetIDs.count), "event": String(delta.toGeneration)], assetID: delta.changedAssetIDs.first)
                        }
                    } else if !delta.changedAssetIDs.isEmpty || !delta.deletedAssetIDs.isEmpty {
                        diagnostic.record(["phase": "photos-live-scope", "source": "live", "category": "inventory", "changed": String(delta.changedAssetIDs.count), "deleted": String(delta.deletedAssetIDs.count), "fromGeneration": String(delta.fromGeneration), "throughGeneration": String(delta.toGeneration)])
                        for id in delta.changedAssetIDs { diagnostic.record(["phase": "photos-live-sample", "source": "live", "category": "inventory-changed", "content": "unknown", "event": String(delta.toGeneration)], assetID: id) }
                        for id in delta.deletedAssetIDs { diagnostic.record(["phase": "photos-live-sample", "source": "live", "category": "deleted", "event": String(delta.toGeneration)], assetID: id) }
                    }
                case .contextInvalidated: state.requireInventoryReconciliation(); changeChannel.send(event)
                case .fullReconcileRequired: state.requireInventoryReconciliation(); changeChannel.send(event)
                }
            },
            onContentChange: { [state, catalogBatchSize, indexDiagnostics] ids in
                let start = ProcessInfo.processInfo.systemUptime
                _ = state.recordContentChanges(ids, capacity: max(1, catalogBatchSize))
                indexDiagnostics.recordTiming(stage: "photos_live_content_persist_wall", seconds: ProcessInfo.processInfo.systemUptime - start)
            },
            didFinishDetails: { [state] in state.finishChangeDetails() },
            diagnostics: { [indexDiagnostics] fields in
                var fields = fields; fields["source"] = "live"
                indexDiagnostics.observation(fields)
            }
        )
    }

    private func measured<T>(_ stage: String, _ body: () throws -> T) rethrows -> T {
        let start = ProcessInfo.processInfo.systemUptime
        defer { indexDiagnostics.recordTiming(stage: stage, seconds: ProcessInfo.processInfo.systemUptime - start) }
        return try body()
    }

    private func usableGeneration() async throws -> Int {
        var access = lifecycle.currentAccess()
        if access == .notDetermined { access = await lifecycle.requestReadWriteAuthorization() }
        guard access == .authorized else { state.requireInventoryReconciliation(); throw PhotoKitGatewayError.authorizationRequired }
        guard lifecycle.isAvailable() else { state.requireInventoryReconciliation(); throw PhotoKitGatewayError.libraryUnavailable }
        let snapshot = state.snapshot()
        guard snapshot.available else { throw PhotoKitGatewayError.libraryUnavailable }
        return snapshot.generation
    }

    private func verifyUsable(generation: Int) throws {
        guard lifecycle.currentAccess() == .authorized else { state.requireInventoryReconciliation(); throw PhotoKitGatewayError.authorizationRequired }
        guard lifecycle.isAvailable() else { state.requireInventoryReconciliation(); throw PhotoKitGatewayError.libraryUnavailable }
        let snapshot = state.snapshot()
        guard snapshot.available else { throw PhotoKitGatewayError.libraryUnavailable }
        guard snapshot.generation == generation else { throw PhotoKitGatewayError.libraryChanged }
    }

    private func requireAdmission(generation: Int) throws {
        switch state.admission(generation: generation) {
        case .ready: return
        case .libraryChanged: throw PhotoKitGatewayError.libraryChanged
        case .blockedAfterCheckpointFailure:
            throw PhotoKitGatewayError.checkpointFailed("New imports are blocked until the gateway is recreated after reconciliation.")
        case .blockedAfterUnknownOutcome:
            throw PhotoKitGatewayError.resultUnknown("New imports are blocked until the gateway is recreated after reconciliation.")
        }
    }

    private func postCommitHealthCheck(identifier: String) {
        do {
            guard lifecycle.currentAccess() == .authorized,
                  lifecycle.isAvailable(),
                  try lifecycle.fetch(identifier: identifier) else {
                state.blockAdditions(.unknownOutcome)
                return
            }
        } catch {
            state.blockAdditions(.unknownOutcome)
        }
    }

    private func classifyChangeFailure(_ error: Error) -> PhotoKitGatewayError {
        let nsError = error as NSError
        guard nsError.domain == PHPhotosErrorDomain,
              let code = PHPhotosError.Code(rawValue: nsError.code) else {
            return .definitelyNotCommitted(nsError.localizedDescription)
        }
        switch code {
        case .accessRestricted, .accessUserDenied: return .authorizationRequired
        case .libraryVolumeOffline, .relinquishingLibraryBundleToWriter, .switchingSystemPhotoLibrary: return .libraryUnavailable
        default: return .definitelyNotCommitted(nsError.localizedDescription)
        }
    }
}

extension PhotoKitGateway: PHPhotoLibraryChangeObserver, PHPhotoLibraryAvailabilityObserver {
    public func photoLibraryDidChange(_ changeInstance: PHChange) { enqueueLibraryChange(changeInstance) }
    public func photoLibraryDidBecomeUnavailable(_ photoLibrary: PHPhotoLibrary) { state.recordUnavailable(); changeChannel.send(.contextInvalidated) }
}

private final class SystemPhotoKitLifecycle: @unchecked Sendable, PhotoKitLifecycle {
    private let photoLibrary: PHPhotoLibrary
    private var fetchedAssets: PHFetchResult<PHAsset>?
    private let representationQueue = DispatchQueue(label: "PhotoSync.PhotoKitRepresentationCatalog")
    private var representationAssets: PHFetchResult<PHAsset>?
    private var representationGeneration: Int?
    private let eventBatchSize: Int
    private let diagnostics: @Sendable ([String: String]) -> Void
    private let indexDiagnostics: IndexDiagnostics?
    init(photoLibrary: PHPhotoLibrary, eventBatchSize: Int = 1, diagnostics: @escaping @Sendable ([String: String]) -> Void = { _ in }, indexDiagnostics: IndexDiagnostics? = nil) {
        self.photoLibrary = photoLibrary; self.eventBatchSize = eventBatchSize; self.diagnostics = diagnostics; self.indexDiagnostics = indexDiagnostics
    }

    func currentAccess() -> PhotoKitAccess {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        default: return .denied
        }
    }
    func requestReadWriteAuthorization() async -> PhotoKitAccess {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return currentAccess()
    }
    func isAvailable() -> Bool { photoLibrary.unavailabilityReason == nil }
    func loadCandidateAssets() throws -> [PhotoKitCandidateAsset] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        let assets = PHAsset.fetchAssets(with: options)
        fetchedAssets = assets
        var result: [PhotoKitCandidateAsset] = []
        assets.enumerateObjects { asset, _, _ in
            let candidates = PHAssetResource.assetResources(for: asset).compactMap { resource -> MatchCandidate? in
                guard !resource.originalFilename.isEmpty else { return nil }
                return MatchCandidate(key: "photos:\(asset.localIdentifier):\(resource.originalFilename)", metadata: Self.metadata(asset: asset, filename: resource.originalFilename))
            }
            result.append(PhotoKitCandidateAsset(identifier: asset.localIdentifier, candidates: candidates))
        }
        return result
    }

    func candidateIndexChange(for change: PHChange?) throws -> PhotoKitCandidateIndexChange {
        guard let change, let before = fetchedAssets else {
            diagnostics(["phase": "photos-fetch-details", "fallback": "missing-change-or-fetch-baseline"])
            return .reload
        }
        guard let details = change.changeDetails(for: before) else {
            return .incremental(removedAssetIDs: [], insertedAssets: [], changedAssets: [])
        }
        guard details.fetchResultBeforeChanges === before else {
            diagnostics(["phase": "photos-fetch-details", "fallback": "fetch-before-identity-mismatch"])
            return .reload
        }
        diagnostics(["phase": "photos-fetch-details", "incremental": String(details.hasIncrementalChanges),
            "classification": "object-content-and-input-facts"])
        let after = details.fetchResultAfterChanges
        let makeCandidate: (PHAsset) -> PhotoKitCandidateAsset = { asset in
            PhotoKitCandidateAsset(identifier: asset.localIdentifier, candidates: PHAssetResource.assetResources(for: asset).compactMap { resource in
                guard !resource.originalFilename.isEmpty else { return nil }
                return MatchCandidate(key: "photos:\(asset.localIdentifier):\(resource.originalFilename)", metadata: Self.metadata(asset: asset, filename: resource.originalFilename))
            })
        }
        var removed = Set<String>(), inserted: [PhotoKitCandidateAsset] = [], changed: [PhotoKitCandidateAsset] = []
        var beforeIDs = Set<String>(), incompleteObjectDetails = false
        before.enumerateObjects { old, _, _ in
            beforeIDs.insert(old.localIdentifier)
            guard let object = change.changeDetails(for: old) else { return }
            if object.objectWasDeleted { removed.insert(old.localIdentifier); return }
            guard let current = object.objectAfterChanges else { incompleteObjectDetails = true; return }
            var candidate = makeCandidate(current)
            let beforeFacts = PhotoKitRepresentationAsset(asset: old), afterFacts = PhotoKitRepresentationAsset(asset: current)
            candidate.inputUnchanged = old.mediaType == current.mediaType && old.mediaSubtypes == current.mediaSubtypes &&
                old.pixelWidth == current.pixelWidth && old.pixelHeight == current.pixelHeight &&
                afterFacts.inputsUnchanged(from: beforeFacts, assetContentChanged: object.assetContentChanged)
            candidate.assetContentChanged = object.assetContentChanged
            var inputFields = PhotoKitCandidateAsset.changedRepresentationFields(before: beforeFacts, after: afterFacts)
            if old.mediaType != current.mediaType { inputFields.append("mediaType") }
            if old.mediaSubtypes != current.mediaSubtypes { inputFields.append("mediaSubtypes") }
            if old.pixelWidth != current.pixelWidth { inputFields.append("pixelWidth") }
            if old.pixelHeight != current.pixelHeight { inputFields.append("pixelHeight") }
            candidate.visibleInputFields = inputFields.sorted()
            var metadataFields: [String] = []
            if old.modificationDate != current.modificationDate { metadataFields.append("modificationDate") }
            if old.creationDate != current.creationDate { metadataFields.append("creationDate") }
            if old.isFavorite != current.isFavorite { metadataFields.append("isFavorite") }
            if old.isHidden != current.isHidden { metadataFields.append("isHidden") }
            if old.duration != current.duration { metadataFields.append("duration") }
            if old.location != current.location { metadataFields.append("location") }
            candidate.metadataFields = metadataFields.sorted()
            changed.append(candidate)
        }
        guard !incompleteObjectDetails else {
            diagnostics(["phase": "photos-fetch-details", "fallback": "missing-object-after-details"])
            return .reload
        }
        after.enumerateObjects { asset, _, _ in
            if !beforeIDs.contains(asset.localIdentifier) { inserted.append(makeCandidate(asset)) }
        }
        // A complete after membership is authoritative even for nonincremental details.
        let afterIDs = Set((0..<after.count).map { after.object(at: $0).localIdentifier })
        removed.formUnion(beforeIDs.subtracting(afterIDs))
        fetchedAssets = after
        return .incremental(removedAssetIDs: removed, insertedAssets: inserted, changedAssets: changed)
    }

    func resetRepresentationCatalog() {
        representationQueue.sync { representationAssets = nil; representationGeneration = nil }
    }
    func representationCatalog(offset: Int, limit: Int, context: LibraryContext, generation: Int) throws -> RepresentationPage {
        try representationQueue.sync {
            if representationGeneration != generation {
                guard offset == 0 else { throw PhotoKitGatewayError.libraryChanged }
                let options = PHFetchOptions()
                options.includeHiddenAssets = true; options.includeAllBurstAssets = true
                options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
                representationAssets = PHAsset.fetchAssets(with: options)
                representationGeneration = generation
            }
            guard let assets = representationAssets, offset <= assets.count * 2 else { throw PhotosRepresentationError.invalidPage }
            let end = min(offset + limit, assets.count * 2)
            var descriptors: [RepresentationDescriptor] = []
            var exclusions: [RepresentationCatalogExclusion] = []
            for position in offset..<end {
                let facts = PhotoKitRepresentationAsset(asset: assets.object(at: position / 2))
                let kind: RepresentationKind = position % 2 == 0 ? .original : .current
                let descriptor = facts.descriptor(kind: kind, context: context)
                do {
                    switch try facts.eligibility(kind) {
                    case .safeSingleFrame: descriptors.append(descriptor)
                    case .conservative(let reason): exclusions.append(RepresentationCatalogExclusion(descriptor: descriptor, reason: .conservative(reason)))
                    }
                } catch PhotosRepresentationError.unsupportedRAW {
                    exclusions.append(RepresentationCatalogExclusion(descriptor: descriptor, reason: .rawResource))
                }
            }
            return RepresentationPage(context: context, generation: generation, descriptors: descriptors,
                                      nextOffset: end < assets.count * 2 ? end : nil, exclusions: exclusions)
        }
    }
    func representationDelta(assetIDs: [String], context: LibraryContext, generation: Int) throws -> RepresentationPage {
        try representationQueue.sync {
            guard !assetIDs.isEmpty else { return .init(context: context, generation: generation, descriptors: [], nextOffset: nil) }
            let options = PHFetchOptions()
            options.includeHiddenAssets = true; options.includeAllBurstAssets = true
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: options)
            guard assets.count == assetIDs.count else { throw PhotoKitGatewayError.libraryChanged }
            var descriptors: [RepresentationDescriptor] = [], exclusions: [RepresentationCatalogExclusion] = []
            for i in 0..<assets.count {
                let asset = assets.object(at: i)
                // Full inventory remains image-only. A broad candidate event can contain video IDs.
                let facts = PhotoKitRepresentationAsset(asset: asset)
                if asset.mediaType != .image {
                    exclusions.append(.init(descriptor: facts.descriptor(kind: .original, context: context), reason: .nonImage))
                    continue
                }
                for kind in [RepresentationKind.original, .current] {
                    let descriptor = facts.descriptor(kind: kind, context: context)
                    do {
                        switch try facts.eligibility(kind) {
                        case .safeSingleFrame: descriptors.append(descriptor)
                        case .conservative(let reason): exclusions.append(.init(descriptor: descriptor, reason: .conservative(reason)))
                        }
                    } catch PhotosRepresentationError.unsupportedRAW { exclusions.append(.init(descriptor: descriptor, reason: .rawResource)) }
                }
            }
            return .init(context: context, generation: generation, descriptors: descriptors, nextOffset: nil, exclusions: exclusions)
        }
    }
    func archivedChangeToken() throws -> Data? {
        try NSKeyedArchiver.archivedData(withRootObject: photoLibrary.currentChangeToken, requiringSecureCoding: true)
    }
    func replayPersistentChanges(_ token: Data, onChange: (PhotosIndexChange) -> Void, onContentChange: ([String]) -> Void) throws -> Bool {
        guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: token) else { return false }
        let result = try photoLibrary.fetchPersistentChanges(since: token)
        let diagnostic = indexDiagnostics?.operation("history-replay")
        defer { diagnostic?.finish() }
        var updated = 0, deleted = 0, inserted = 0
        defer { indexDiagnostics?.emit(["phase": "photos-history-categories", "source": "history", "updated": String(updated), "deleted": String(deleted), "inserted": String(inserted), "updatedContent": "unknown", "reason": "conservative-history-identifiers"]) }
        for change in result {
            let details = try change.changeDetails(for: .asset)
            updated += details.updatedLocalIdentifiers.count; deleted += details.deletedLocalIdentifiers.count; inserted += details.insertedLocalIdentifiers.count
            for (category, ids) in [("updated", details.updatedLocalIdentifiers), ("deleted", details.deletedLocalIdentifiers), ("inserted", details.insertedLocalIdentifiers)] {
                for id in ids { diagnostic?.record(["phase": "photos-history-sample", "source": "history", "category": category, "content": "unknown", "reason": "conservative-history-identifiers"], assetID: id) }
                let ordered = ids.sorted()
                for offset in stride(from: 0, to: ordered.count, by: max(1, eventBatchSize)) {
                    onContentChange(Array(ordered[offset..<min(ordered.count, offset + max(1, eventBatchSize))]))
                }
            }
            // Persistent replay only supplies invalidation/continuity for the mandatory
            // restart inventory. It cannot manufacture a process-local live delta baseline.

        }
        return true
    }
    func submit(_ command: PhotoKitCreateCommand, beforeMutation: @escaping @Sendable () -> Bool, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> PhotoKitSubmissionResult {
        let state = SubmissionState()
        do {
            try await photoLibrary.performChanges {
                guard beforeMutation() else { state.prevent(); return }
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = command.shouldMoveFile
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: command.kind == .image ? .photo : .video, fileURL: command.fileURL, options: options)
                guard let identifier = request.placeholderForCreatedAsset?.localIdentifier else { state.checkpointFailed(); return }
                do { try onPlaceholder(identifier); state.commit(identifier: identifier) }
                catch { state.checkpointFailed() }
            }
        } catch {
            if state.isCheckpointFailed { throw PhotoKitSubmissionError.checkpointFailed(error) }
            throw error
        }
        return state.result()
    }
    func fetch(identifier: String) throws -> Bool {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).count == 1
    }
    private static func metadata(asset: PHAsset, filename: String) -> MediaMetadata {
        MediaMetadata(filename: filename, kind: asset.mediaType == .video ? .video : .image, captureSecond: nil, rawCaptureTime: nil, rawCaptureOffset: nil, make: nil, model: nil, width: asset.pixelWidth == 0 ? nil : asset.pixelWidth, height: asset.pixelHeight == 0 ? nil : asset.pixelHeight, duration: asset.mediaType == .video ? asset.duration : nil)
    }
}

private final class PhotoKitCandidateIndex: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PhotoSync.PhotoKitCandidateIndex")
    // Orders generation capture with queue insertion, never with physical work.
    private let submissionLock = NSLock()
    private let submissionProbe: (@Sendable (PhotoKitQueueSubmissionPhase) -> Void)?
    init(submissionProbe: (@Sendable (PhotoKitQueueSubmissionPhase) -> Void)? = nil) {
        self.submissionProbe = submissionProbe
    }
    private var byAsset: [String: [MatchCandidate]] = [:]
    private var byFilename: [String: [MatchCandidate]] = [:]
    private var indexedGeneration: Int?

    func snapshot(
        lifecycle: any PhotoKitLifecycle,
        currentGeneration: @escaping @Sendable () -> Int,
        validity: @escaping @Sendable (Int) -> any PhotosCandidateValidity,
        needsRebuild: @escaping @Sendable (Int) -> Bool
    ) async throws -> PhotosCandidateSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            if !submissionLock.try() {
                submissionProbe?(.snapshotContended)
                submissionLock.lock()
            }
            let generation = currentGeneration()
            let snapshotValidity = validity(generation)
            queue.async {
                do {
                    if self.indexedGeneration != generation || needsRebuild(generation) {
                        let assets = try lifecycle.loadCandidateAssets()
                        self.byAsset = Dictionary(uniqueKeysWithValues: assets.map { ($0.identifier, $0.candidates) })
                        self.byFilename = Self.buckets(self.byAsset)
                        self.indexedGeneration = generation
                    }
                    continuation.resume(returning: PhotosCandidateSnapshot(generation: generation,
                        candidatesByFilename: self.byFilename, validity: snapshotValidity))
                } catch { continuation.resume(throwing: error) }
            }
            submissionLock.unlock()
        }
    }

    func enqueueChange(_ change: PHChange?, recordChange: @Sendable () -> (generation: Int, context: LibraryContext), lifecycle: any PhotoKitLifecycle,
                       indexDiagnostics: IndexDiagnostics, diagnostic: IndexDiagnosticOperation,
                       didIndex: @escaping @Sendable (Int) -> Bool,
                       onChange: @escaping @Sendable (PhotosIndexChange, Bool) -> Void,
                       onContentChange: @escaping @Sendable ([String]) -> Void,
                       didFinishDetails: @escaping @Sendable () -> Void,
                       diagnostics: @escaping @Sendable ([String: String]) -> Void) {
        let queuedAt = ProcessInfo.processInfo.systemUptime
        submissionLock.lock()
        let (generation, context) = recordChange()
        submissionProbe?(.observerRecorded)
        queue.async { [weak self] in
            let classificationStart = ProcessInfo.processInfo.systemUptime
            indexDiagnostics.recordTiming(stage: "photos_notification_queue_wall", seconds: classificationStart - queuedAt)
            var classificationFinished = false
            defer {
                didFinishDetails()
                if !classificationFinished { indexDiagnostics.recordTiming(stage: "photos_notification_classification_wall", seconds: ProcessInfo.processInfo.systemUptime - classificationStart) }
                diagnostic.finish()
            }
            guard let self else { return }
            guard case let .incremental(removed, inserted, changed) = (try? lifecycle.candidateIndexChange(for: change)) else {
                diagnostics(["phase": "photos-change-classification", "event": String(generation), "fallback": "missing-or-unclassified-fetch-details", "contentScope": "unknown"])
                onChange(.fullReconcileRequired, false); return
            }
            guard self.indexedGeneration == generation - 1 else {
                diagnostics(["phase": "photos-change-classification", "event": String(generation), "fallback": "candidate-baseline-gap", "contentScope": "unknown",
                    "expectedBaseline": String(generation - 1), "actualBaseline": self.indexedGeneration.map(String.init) ?? "none"])
                onChange(.fullReconcileRequired, false); return
            }
            let insertedIDs = Set(inserted.map(\.identifier))
            let changedIDs = Set(changed.map(\.identifier))
            guard insertedIDs.count == inserted.count,
                  changedIDs.count == changed.count,
                  removed.isDisjoint(with: insertedIDs),
                  removed.isDisjoint(with: changedIDs),
                  insertedIDs.isDisjoint(with: changedIDs),
                  removed.allSatisfy({ self.byAsset[$0] != nil }),
                  inserted.allSatisfy({ self.byAsset[$0.identifier] == nil }),
                  changed.allSatisfy({ self.byAsset[$0.identifier] != nil }) else {
                diagnostics(["phase": "photos-change-classification", "event": String(generation), "fallback": "malformed-membership-details", "contentScope": "unknown"])
                onChange(.fullReconcileRequired, false); return
            }
            for asset in changed {
                indexDiagnostics.recordCause(context: context, assetID: asset.identifier, source: "live", generation: generation,
                    facts: ["category": "changed", "assetContentChanged": asset.assetContentChanged.map(String.init) ?? "unknown",
                        "visibleInputFields": asset.visibleInputFields.map { $0.isEmpty ? "none" : $0.sorted().joined(separator: ",") } ?? "unknown",
                        "metadataFields": asset.metadataFields.map { $0.isEmpty ? "none" : $0.sorted().joined(separator: ",") } ?? "unknown"], operation: diagnostic.id,
                    inputObligation: !asset.inputUnchanged)
            }
            for asset in inserted { indexDiagnostics.recordCause(context: context, assetID: asset.identifier, source: "live", generation: generation,
                facts: ["category": "inserted", "assetContentChanged": "unknown", "visibleInputFields": "unknown", "metadataFields": "unknown"], operation: diagnostic.id) }
            for id in removed { indexDiagnostics.recordCause(context: context, assetID: id, source: "live", generation: generation,
                facts: ["category": "deleted", "assetContentChanged": "unknown", "visibleInputFields": "unknown", "metadataFields": "unknown"], operation: diagnostic.id) }
            for id in removed { self.remove(id) }
            for asset in changed { self.remove(asset.identifier); self.insert(asset) }
            for asset in inserted { self.insert(asset) }
            self.indexedGeneration = generation
            _ = didIndex(generation)
            diagnostics(["phase": "photos-change-classification", "event": String(generation), "contentScope": "known",
                "inserted": String(inserted.count), "deleted": String(removed.count),
                "contentChanged": String(changed.filter { !$0.inputUnchanged }.count),
                "inputUnchanged": String(changed.filter(\.inputUnchanged).count)])
            indexDiagnostics.recordTiming(stage: "photos_notification_classification_wall", seconds: ProcessInfo.processInfo.systemUptime - classificationStart)
            classificationFinished = true
            onContentChange(changed.filter { !$0.inputUnchanged }.map(\.identifier) + removed.sorted())
            onChange(.incremental(.init(context: context, fromGeneration: generation - 1, toGeneration: generation,
                changedAssetIDs: (inserted + changed).map(\.identifier).sorted(), deletedAssetIDs: removed.sorted())),
                inserted.isEmpty && removed.isEmpty && changed.allSatisfy(\.inputUnchanged))
        }
        submissionLock.unlock()
        // Diagnostics may call injected hooks; admission is closed and ordered work
        // is already queued before invoking them, with no lock held.
        diagnostics(["phase": "photos-notification", "event": String(generation), "publication": "closed", "classification": "pending"])
    }

    private func remove(_ identifier: String) {
        guard let old = byAsset.removeValue(forKey: identifier) else { return }
        for candidate in old {
            let filename = candidate.metadata.filename
            byFilename[filename]?.removeAll { $0.key == candidate.key }
            if byFilename[filename]?.isEmpty == true { byFilename.removeValue(forKey: filename) }
        }
    }

    private func insert(_ asset: PhotoKitCandidateAsset) {
        byAsset[asset.identifier] = asset.candidates
        for candidate in asset.candidates { byFilename[candidate.metadata.filename, default: []].append(candidate) }
    }

    private static func buckets(_ assets: [String: [MatchCandidate]]) -> [String: [MatchCandidate]] {
        var result: [String: [MatchCandidate]] = [:]
        for candidates in assets.values { for candidate in candidates { result[candidate.metadata.filename, default: []].append(candidate) } }
        return result
    }
}

private final class SubmissionState: @unchecked Sendable {
    private let lock = NSLock(); private var value: PhotoKitSubmissionResult = .preventedBeforeMutation
    func prevent() { lock.lock(); value = .preventedBeforeMutation; lock.unlock() }
    func checkpointFailed() { lock.lock(); value = .checkpointFailed; lock.unlock() }
    func commit(identifier: String) { lock.lock(); value = .committed(identifier: identifier); lock.unlock() }
    func result() -> PhotoKitSubmissionResult { lock.lock(); defer { lock.unlock() }; return value }
    var isCheckpointFailed: Bool { lock.lock(); defer { lock.unlock() }; if case .checkpointFailed = value { return true }; return false }
}

private final class PhotoKitState: @unchecked Sendable {
    enum AdditionBlockReason { case checkpointFailed, unknownOutcome }
    private let lock = NSLock(); private var available = true; private var generation = 0; private var indexedGeneration: Int?; private var additionsBlocked: AdditionBlockReason?
    private var context = LibraryContext(id: UUID(), epoch: 0)
    struct HistoryCoverageTicket { let context: LibraryContext; let generation: Int; let admissionRevision: UInt64 }
    private var admissionRevision: UInt64 = 0
    private var historyAdmissionBlocked = false
    private var observerFence = UUID()
    private var observerContinuous = false
    private var observerCheckpoint: LibraryResumeCheckpoint?

    private func revokeObserverContinuityLocked() {
        observerFence = UUID(); observerContinuous = false; observerCheckpoint = nil
        admissionRevision &+= 1
        // Filename-only gateways have no inventory acknowledgement cycle. Their
        // candidate index remains valid after a classified membership change.
        if store != nil { historyAdmissionBlocked = true }
    }
    func continuousInventory(previousCheckpoint: LibraryResumeCheckpoint?, expectedGeneration: Int) throws -> PhotosInventoryContinuity? {
        lock.lock(); defer { lock.unlock() }
        guard available, generation == expectedGeneration, pendingChangeDetails == 0 else { throw PhotoKitGatewayError.libraryChanged }
        guard observerContinuous, !inventoryUnverified, store != nil,
              previousCheckpoint == observerCheckpoint else { return nil }
        return .init(checkpoint: previousCheckpoint, preservesCachedRepresentations: true, observerFence: observerFence)
    }
    func recoveryInventory(checkpoint: LibraryResumeCheckpoint?, covered: Bool) throws -> PhotosInventoryContinuity {
        lock.lock(); defer { lock.unlock() }
        guard available, pendingChangeDetails == 0,
              checkpoint == nil || checkpoint?.context == context else { throw PhotoKitGatewayError.libraryChanged }
        return .init(checkpoint: checkpoint, preservesCachedRepresentations: covered, observerFence: observerFence)
    }

    func invalidateHistoryAdmission() {
        lock.lock(); revokeObserverContinuityLocked(); historyAdmissionBlocked = true; indexedGeneration = nil; lock.unlock()
    }
    func beginHistoryCoverage() -> HistoryCoverageTicket {
        lock.lock(); defer { lock.unlock() }
        revokeObserverContinuityLocked()
        historyAdmissionBlocked = true; indexedGeneration = nil
        pendingChangeDetails += 1
        return .init(context: context, generation: generation, admissionRevision: admissionRevision)
    }
    func historyCoverageFacts(_ ticket: HistoryCoverageTicket) -> (valid: Bool, retryReason: String?) {
        lock.lock(); defer { lock.unlock() }
        guard available, context == ticket.context, store != nil, !inventoryUnverified else { return (false, nil) }
        if generation != ticket.generation { return (true, "upper-generation-stale") }
        if pendingChangeDetails != 1 { return (true, "observer-details-pending") }
        if admissionRevision != ticket.admissionRevision { return (true, "coverage-superseded") }
        return (true, nil)
    }
    private var catalogSession: (session: PhotosCatalogSession, context: LibraryContext, invalidationTransferred: Bool, observerFence: UUID)?
    func beginCatalogSession(expectedGeneration: Int) throws -> PhotosCatalogSession {
        lock.lock(); defer { lock.unlock() }
        guard available, generation == expectedGeneration, pendingChangeDetails == 0 else { throw PhotoKitGatewayError.libraryChanged }
        let session = PhotosCatalogSession(baselineGeneration: expectedGeneration)
        catalogSession = (session, context, false, observerFence)
        return session
    }
    func validateCatalogSession(_ session: PhotosCatalogSession) throws {
        lock.lock(); defer { lock.unlock() }
        guard available, catalogSession?.session == session, catalogSession?.context == context, catalogSession?.observerFence == observerFence,
              unknownGeneration <= session.baselineGeneration else { throw PhotoKitGatewayError.libraryChanged }
    }
    func markCatalogInvalidationTransferred(_ session: PhotosCatalogSession) throws {
        lock.lock(); defer { lock.unlock() }
        guard available, catalogSession?.session == session, catalogSession?.context == context, catalogSession?.observerFence == observerFence,
              unknownGeneration <= session.baselineGeneration else { throw PhotoKitGatewayError.libraryChanged }
        catalogSession?.invalidationTransferred = true
    }
    func hasTransferredCatalogInvalidation(_ session: PhotosCatalogSession) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard available, catalogSession?.session == session, catalogSession?.context == context, catalogSession?.observerFence == observerFence,
              pendingChangeDetails == 0, unknownGeneration <= session.baselineGeneration else { throw PhotoKitGatewayError.libraryChanged }
        return catalogSession?.invalidationTransferred == true
    }
    private var contentChangedIDs = Set<String>() // fallback only, bounded by one catalog page
    private var store: SyncStore?
    private let runID = UUID()
    private var unknownGeneration = -1
    private var replayContext: LibraryContext?
    var hasStore: Bool { lock.lock(); defer { lock.unlock() }; return store != nil }
    func attach(_ store: SyncStore) { lock.lock(); self.store = store; lock.unlock() }
    func catalogCoverage(baseline: Int) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard available, pendingChangeDetails == 0, baseline <= generation, unknownGeneration <= baseline else { throw PhotoKitGatewayError.libraryChanged }
        return generation
    }
    func catalogChanges(baseline: Int, endpoint: Int, after: String?, limit: Int) throws -> PhotosCatalogChangeBatch {
        lock.lock(); let store = store, context = context; lock.unlock()
        guard let store else {
            guard endpoint == baseline else { return .init(changedAssetIDs: [], deletedAssetIDs: [], nextAssetID: nil) }
            return .init(changedAssetIDs: [], deletedAssetIDs: [], nextAssetID: nil)
        }
        return try store.photosCatalogChanges(context: context, runID: runID, afterGeneration: baseline,
            throughGeneration: endpoint, afterAssetID: after, limit: limit)
    }
    func recordCatalogChanges(_ delta: PhotosIndexDelta, capacity: Int) -> Bool {
        lock.lock(); let store = store; lock.unlock()
        do {
            try store?.recordPhotosChanges(context: delta.context, runID: runID, generation: delta.toGeneration,
                changed: delta.changedAssetIDs, deleted: delta.deletedAssetIDs, content: [], batchSize: capacity)
            return true
        } catch { return false }
    }
    private var inventoryUnverified = false
    private var pendingChangeDetails = 0

    private var reads: [UUID: (assetID: String, valid: Bool)] = [:]
    func beginRepresentationRead(_ descriptor: RepresentationDescriptor) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard available, context == descriptor.context, pendingChangeDetails == 0 else { throw PhotoKitGatewayError.libraryChanged }
        let ticket = UUID(); reads[ticket] = (descriptor.key.assetID, true); return ticket
    }
    func endRepresentationRead(_ ticket: UUID) { lock.lock(); reads.removeValue(forKey: ticket); lock.unlock() }
    func representationReadIsCurrent(_ ticket: UUID, context expected: LibraryContext) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return available && context == expected && reads[ticket]?.valid == true
    }
    func invalidateActiveReads(_ ids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        for (ticket, read) in reads where ids.contains(read.assetID) { reads[ticket] = (read.assetID, false) }
    }
    func recordObserverChange() -> (generation: Int, context: LibraryContext) {
        lock.lock(); defer { lock.unlock() }
        generation += 1; indexedGeneration = nil; pendingChangeDetails += 1
        return (generation, context)
    }

    @discardableResult
    func recordContentChanges(_ ids: [String], capacity: Int) -> Bool {
        invalidateActiveReads(Set(ids))
        lock.lock()
        let store = store, context = replayContext ?? context, generation = generation
        if store == nil {
            for id in ids {
                if contentChangedIDs.count >= capacity && !contentChangedIDs.contains(id) {
                    revokeObserverContinuityLocked(); inventoryUnverified = true; unknownGeneration = generation; contentChangedIDs.removeAll(); break
                }
                contentChangedIDs.insert(id)
            }
        }
        lock.unlock()
        do {
            try store?.recordPhotosChanges(context: context, runID: runID, generation: generation,
                changed: ids, deleted: [], content: Set(ids), batchSize: capacity)
            return store != nil
        } catch { requireInventoryReconciliation(); return false }
    }
    // Revoke discovery/admission continuity only. This never changes stored
    // representation readiness or successful analysis facts.
    func requireInventoryReconciliation() {
        lock.lock(); revokeObserverContinuityLocked(); inventoryUnverified = true; unknownGeneration = generation; contentChangedIDs.removeAll()
        for (ticket, read) in reads { reads[ticket] = (read.assetID, false) }
        lock.unlock()
    }
    func finishChangeDetails() {
        lock.lock(); pendingChangeDetails -= 1; lock.unlock()
    }
    func invalidationEvidence(generation expected: Int, pageAssetIDs: Set<String>, permittingUnverifiedInputEvidence: Bool = false) throws -> (ids: [String], all: Bool, unchanged: [String]) {
        lock.lock()
        let usable = available && generation == expected && pendingChangeDetails == 0
        let store = store, context = context, fallback = contentChangedIDs.intersection(pageAssetIDs).sorted()
        let all = inventoryUnverified
        lock.unlock()
        guard usable else { throw PhotoKitGatewayError.libraryChanged }
        return (try store?.photosContentChanges(context: context, assetIDs: pageAssetIDs) ?? fallback, all,
                all && !permittingUnverifiedInputEvidence ? [] : try store?.photosInputUnchanged(context: context, assetIDs: pageAssetIDs) ?? [])
    }
    func acknowledgeReconciliation(generation expected: Int, admitHistory: Bool = false, continuity: PhotosInventoryContinuity? = nil, _ acknowledge: () -> Void) -> Bool {
        lock.lock()
        guard available, generation == expected, pendingChangeDetails == 0,
              continuity == nil || continuity?.observerFence == observerFence,
              !admitHistory || store == nil || observerContinuous else { lock.unlock(); return false }
        let store = store, context = context
        lock.unlock()
        do { try store?.acknowledgePhotosChanges(context: context, runID: runID, throughGeneration: expected) }
        catch { return false }
        lock.lock(); defer { lock.unlock() }
        guard available, generation == expected, pendingChangeDetails == 0,
              continuity == nil || continuity?.observerFence == observerFence,
              !admitHistory || store == nil || observerContinuous else { return false }
        if let continuity {
            observerCheckpoint = continuity.checkpoint; observerContinuous = true
        }
        contentChangedIDs.removeAll(); inventoryUnverified = false
        if admitHistory { historyAdmissionBlocked = false }
        acknowledge()
        return true
    }
    func setReplayContext(_ value: LibraryContext?) {
        lock.lock()
        if value != nil { revokeObserverContinuityLocked() }
        replayContext = value
        lock.unlock()
    }
    func snapshot() -> (available: Bool, generation: Int, context: LibraryContext) { lock.lock(); defer { lock.unlock() }; return (available, generation, context) }
    func adoptContext(_ context: LibraryContext, generation expected: Int, completingReplay: Bool = false) -> Int? {
        lock.lock(); defer { lock.unlock() }
        // A resume owns one pending replay marker; any observer marker beyond
        // it is still an unfinished classification and prevents adoption.
        let expectedDetails = completingReplay ? 1 : 0
        guard available, generation == expected, pendingChangeDetails == expectedDetails,
              !completingReplay || replayContext == context else { return nil }
        self.context = context
        // Replay runs outside the lock. Snapshots acquired during that work
        // belong to the provisional context and must not survive adoption.
        generation += 1; indexedGeneration = nil
        return generation
    }
    func validity(generation expected: Int) -> any PhotosCandidateValidity {
        lock.lock(); let revision = admissionRevision; lock.unlock()
        return PhotoKitGenerationValidity(state: self, generation: expected, admissionRevision: revision)
    }
    func needsReindex(generation expected: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return indexedGeneration != expected }
    func recordChange(expectingDetails: Bool = false) -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1; indexedGeneration = nil
        if expectingDetails { pendingChangeDetails += 1 }
        return generation
    }
    func recordUnavailable() {
        lock.lock(); defer { lock.unlock() }
        revokeObserverContinuityLocked(); available = false; generation += 1; indexedGeneration = nil
        for (ticket, read) in reads { reads[ticket] = (read.assetID, false) }
    }
    func markIndexed(generation expected: Int) -> Bool { lock.lock(); defer { lock.unlock() }; guard available, generation == expected else { return false }; indexedGeneration = expected; return true }
    enum Admission { case ready, libraryChanged, blockedAfterCheckpointFailure, blockedAfterUnknownOutcome }
    func admission(generation expected: Int) -> Admission {
        lock.lock(); defer { lock.unlock() }
        switch additionsBlocked {
        case .checkpointFailed: return .blockedAfterCheckpointFailure
        case .unknownOutcome: return .blockedAfterUnknownOutcome
        case nil: return available && !historyAdmissionBlocked && pendingChangeDetails == 0 && generation == expected && indexedGeneration == expected ? .ready : .libraryChanged
        }
    }
    func isReady(generation expected: Int) -> Bool { admission(generation: expected) == .ready }
    func blockAdditions(_ reason: AdditionBlockReason) { lock.lock(); additionsBlocked = reason; lock.unlock() }

    func commitIfCurrent(generation expected: Int, admissionRevision expectedRevision: UInt64, _ commit: @escaping @Sendable () throws -> Void) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard available, generation == expected, admissionRevision == expectedRevision,
              !historyAdmissionBlocked, pendingChangeDetails == 0 else { return false }
        try commit()
        return true
    }
}

private final class PhotoKitGenerationValidity: PhotosCandidateValidity, @unchecked Sendable {
    private let state: PhotoKitState
    private let generation: Int
    private let admissionRevision: UInt64

    init(state: PhotoKitState, generation: Int, admissionRevision: UInt64) {
        self.state = state
        self.generation = generation
        self.admissionRevision = admissionRevision
    }

    func commitIfCurrent(_ commit: @escaping @Sendable () throws -> Void) throws -> Bool {
        try state.commitIfCurrent(generation: generation, admissionRevision: admissionRevision, commit)
    }
}

/// Stores only a synchronous predicate failure. It never holds its lock while
/// calling the engine, reading the source, or entering the store queue.
private final class PhotoKitMutationGuard: @unchecked Sendable {
    private let predicate: @Sendable () throws -> Bool
    private let lock = NSLock()
    private var error: Error?
    init(_ predicate: @escaping @Sendable () throws -> Bool) { self.predicate = predicate }
    func check() -> Bool {
        do { return try predicate() }
        catch { lock.lock(); self.error = error; lock.unlock(); return false }
    }
    var failure: Error? { lock.lock(); defer { lock.unlock() }; return error }
}

/// No Photos/SQLite work under this lock. Bounds retries even when runtime ticks
/// arrive frequently; permanent token loss takes the metadata path immediately.
private final class PhotosHistoryRetry: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private var failures = 0
    private var nextAttempt: TimeInterval = 0
    init(now: @escaping @Sendable () -> TimeInterval) { self.now = now }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        guard now() >= nextAttempt else { throw PhotoKitGatewayError.libraryChanged }
    }
    func failed() {
        lock.lock(); defer { lock.unlock() }
        failures = min(failures + 1, 4)
        nextAttempt = now() + [5.0, 15, 30, 60][failures - 1]
    }
    func succeeded() { lock.lock(); failures = 0; nextAttempt = 0; lock.unlock() }
}
