import Foundation

/// Prepares one decision over a complete current Photos/local vector view. The
/// caller still commits with the evidence token and synchronous Photos validity.
public actor AdvancedDedupService {
    private let store: SyncStore
    private let photos: any PhotosIndexGateway
    private let coordinator: PhotosIndexCoordinator
    private let fingerprinter: any ImageFingerprinting
    private let index: ExactVectorIndex
    private let configuration: DedupConfiguration
    private let executor: ReadExecutor
    private let budget: ImageWorkBudget
    private var paused = false

    public init(store: SyncStore, photos: any PhotosIndexGateway, coordinator: PhotosIndexCoordinator,
                fingerprinter: any ImageFingerprinting, index: ExactVectorIndex,
                configuration: DedupConfiguration, executor: ReadExecutor, budget: ImageWorkBudget) {
        self.store = store; self.photos = photos; self.coordinator = coordinator
        self.fingerprinter = fingerprinter; self.index = index; self.configuration = configuration
        self.executor = executor; self.budget = budget
    }
    public func setPaused(_ paused: Bool) { self.paused = paused }

    public func prepare(fileID: UUID, file: SourceFile) async throws -> AdvancedPreparation {
        do { return try await prepareCurrent(fileID: fileID, file: file) }
        catch is ReadExecutorError { return .waiting(reason: "来源读取稍后继续。") }
        catch is ImageWorkBudgetError { return .waiting(reason: "图像资源稍后可用。") }
        catch is CancellationError { return .waiting(reason: "来源准备已暂停。") }
    }

    private func prepareCurrent(fileID: UUID, file: SourceFile) async throws -> AdvancedPreparation {
        let started = Date()
        guard !paused, file.metadata.kind == .image,
              let record = try await eligibleRecord(fileID: fileID, file: file), !paused else { return waiting() }
        guard let initialToken = await readyToken(), !paused else { return waiting() }
        guard try await stamp(file) == file.stamp, !paused else { return waiting() }
        let size = sourceSize(file)
        var fingerprint = try await store.fingerprint(fileID: fileID, stamp: file.stamp,
                                                       version: configuration.fingerprint.version)
        guard !paused else { return waiting() }
        var conservativeReason: RepresentationConservativeReason?
        if fingerprint == nil {
            // This owned task retains the lease through actual decode/inference
            // completion, even if the preparing caller is canceled or paused.
            let reader = MetadataReader(sourceID: file.sourceID, executor: executor)
            let model = fingerprinter, configuration = configuration, budget = budget
            let work = Task { () throws -> (Fingerprint?, RepresentationConservativeReason?) in
                var loaded: ImageWorkResult<SourceImage>? = try await reader.readForFingerprint(
                    url: file.url, configuration: configuration, budget: budget)
                let lease = loaded!.lease
                do {
                    let result: (Fingerprint?, RepresentationConservativeReason?)
                    switch loaded!.value.eligibility {
                    case .safeSingleFrame:
                        result = (try await model.fingerprint(image: loaded!.value.image,
                            orientation: loaded!.value.orientation), nil)
                    case .conservative(let reason): result = (nil, reason)
                    }
                    loaded = nil; await lease.finishPhysicalWork()
                    return result
                } catch {
                    loaded = nil; await lease.finishPhysicalWork(); throw error
                }
            }
            (fingerprint, conservativeReason) = try await work.value
            guard !paused, !Task.isCancelled, try await stamp(file) == file.stamp, !paused,
                  try await eligibleRecord(fileID: fileID, file: file) != nil, !paused,
                  let current = await readyToken(), samePhotosIndex(initialToken, current), !paused else { return waiting() }
            if let fingerprint {
                guard fingerprint.version == configuration.fingerprint.version else { throw AdvancedDedupError.modelMismatch }
                guard try await store.cacheFingerprint(.init(fileID: fileID, file: file,
                    fingerprint: fingerprint, size: size)), !paused else { return waiting() }
            }
        }
        guard let token = await readyToken(), samePhotosIndex(initialToken, token), !paused else { return waiting() }
        let snapshot: PhotosCandidateSnapshot
        do { snapshot = try await photos.candidateSnapshot() } catch { return waiting() }
        guard !paused, snapshot.generation == token.photosGeneration else { return waiting() }
        let local = try await store.localVectorCandidates(beforeOrder: record.createdOrder, excluding: fileID,
                                                          version: configuration.fingerprint.version)
        guard !paused, local.revision == token.localRevision else { return waiting() }
        let matches: [ScoredCandidate], diagnostics: [ScoredCandidate]
        let evaluation: DuplicateEvaluation
        if conservativeReason != nil {
            matches = []; diagnostics = []
            evaluation = .init(content: .notCompared, action: .importFile, reason: .nonComparableSource,
                               matchedKeys: [], coveringKeys: [])
        } else {
            guard let fingerprint else { return waiting() }
            let photosResult: VectorSearchResult
            do {
                photosResult = try await index.searchWithDiagnostics(query: fingerprint,
                    minimumScore: configuration.threshold, generation: token.indexGeneration, diagnosticLimit: 10)
            } catch { return waiting() }
            guard !paused else { return waiting() }
            let localResult = try ExactVectorIndex.scoreWithDiagnostics(query: fingerprint, entries: local.entries,
                minimumScore: configuration.threshold, diagnosticLimit: 10)
            matches = (photosResult.matches + localResult.matches).sorted(by: Self.ranked)
            diagnostics = Array((photosResult.diagnostics + localResult.diagnostics).sorted(by: Self.ranked).prefix(10))
            evaluation = try AdvancedDuplicatePolicy.evaluate(sourceSize: size, candidates: matches, configuration: configuration)
        }
        guard !paused, !Task.isCancelled, try await eligibleRecord(fileID: fileID, file: file) != nil, !paused,
              try await stamp(file) == file.stamp, !paused,
              (try? await store.indexIsReady(token: token)) == true, !paused,
              (try? snapshot.candidateValidity.commitIfCurrent({})) == true else { return waiting() }
        let coveringKeys = Set(evaluation.coveringKeys)
        let decisive = evaluation.action == .skip
            ? matches.first { coveringKeys.contains($0.key) } : matches.first
        // Policy sees every match. Persist only the independent decisive key;
        // these lists are bounded evidence, never a complete candidate inventory.
        let boundedEvaluation = DuplicateEvaluation(content: evaluation.content, action: evaluation.action,
            reason: evaluation.reason, matchedKeys: decisive.map { [$0.key] } ?? [],
            coveringKeys: decisive.flatMap { coveringKeys.contains($0.key) ? [$0.key] : nil } ?? [])
        let evidence = AdvancedEvidence(eventID: UUID(), fileID: fileID, stamp: file.stamp, token: token,
            policyVersion: configuration.policyVersion, evaluation: boundedEvaluation,
            decisiveCandidates: decisive.map { [$0] } ?? [], diagnostics: diagnostics,
            timingsMS: ["preparation": Date().timeIntervalSince(started) * 1000])
        if let conservativeReason {
            return .conservative(.init(fileID: fileID, file: file, reason: conservativeReason,
                                       evidence: evidence, validity: snapshot.candidateValidity))
        }
        guard let fingerprint else { return waiting() }
        return .ready(.init(source: .init(fileID: fileID, file: file, fingerprint: fingerprint, size: size),
                            evidence: evidence, validity: snapshot.candidateValidity))
    }

    private func eligibleRecord(fileID: UUID, file: SourceFile) async throws -> StoredFile? {
        guard !paused, let record = try await store.file(sourceID: file.sourceID, relativePath: file.relativePath),
              !paused, record.id == fileID, record.file.stamp == file.stamp, record.file.metadata == file.metadata,
              record.state != .importing, record.state != .imported, record.successID == nil else { return nil }
        let source = try await store.source(id: file.sourceID)
        guard !paused, source.enabled, try await !store.isSourceRemoved(id: source.id), !paused else { return nil }
        return record
    }
    private func stamp(_ file: SourceFile) async throws -> FileStamp {
        try await DirectoryReader(sourceID: file.sourceID, executor: executor).stamp(of: URL(fileURLWithPath: file.url.path))
    }
    private func readyToken() async -> IndexToken? {
        guard !paused, let token = try? await coordinator.readyToken(), !paused,
              token.fingerprintVersion == configuration.fingerprint.version else { return nil }
        return token
    }
    private func sourceSize(_ file: SourceFile) -> PixelSize? {
        guard let width = file.metadata.width, let height = file.metadata.height else { return nil }
        return try? PixelSize(width: width, height: height)
    }
    private func samePhotosIndex(_ lhs: IndexToken, _ rhs: IndexToken) -> Bool {
        lhs.context == rhs.context && lhs.photosGeneration == rhs.photosGeneration &&
            lhs.indexGeneration == rhs.indexGeneration && lhs.fingerprintVersion == rhs.fingerprintVersion
    }
    private static func ranked(_ lhs: ScoredCandidate, _ rhs: ScoredCandidate) -> Bool {
        lhs.score == rhs.score ? lhs.key < rhs.key : lhs.score > rhs.score
    }
    private func waiting() -> AdvancedPreparation { .waiting(reason: "来源或图库索引正在等待确认。") }
}
