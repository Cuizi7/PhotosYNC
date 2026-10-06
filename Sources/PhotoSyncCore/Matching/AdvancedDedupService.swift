import Foundation

/// Prepares one decision over a complete current Photos/local vector view. The
/// caller still commits with the evidence token and synchronous Photos validity.
public actor AdvancedDedupService {
    private let store: SyncStore
    private let photos: any PhotosIndexGateway
    private let coordinator: PhotosIndexCoordinator
    private let fingerprinter: any ImageFingerprinting
    private let configuration: DedupConfiguration
    private let executor: ReadExecutor
    private let budget: ImageWorkBudget
    private var paused = false

    public init(store: SyncStore, photos: any PhotosIndexGateway, coordinator: PhotosIndexCoordinator,
                fingerprinter: any ImageFingerprinting,
                configuration: DedupConfiguration, executor: ReadExecutor, budget: ImageWorkBudget) {
        self.store = store; self.photos = photos; self.coordinator = coordinator
        self.fingerprinter = fingerprinter; self.configuration = configuration
        self.executor = executor; self.budget = budget
    }
    /// Stops new admissions; already-started physical reads/inference retain
    /// their leases until completion. The caller also gates actual submission.
    public func setPaused(_ paused: Bool) { self.paused = paused }

    /// Returns a genuine vector admission, or an explicit no-comparison original
    /// import for confirmed readable unsupported comparison content/resource size.
    /// Both require current source/history/stamp/index and synchronous validity.
    /// Unknown/stale evidence, pause, cancellation and temporary read/budget
    /// occupancy return waiting. Source metadata/read, cache/record lookup and
    /// model failures throw into the caller's typed retry/diagnostic path; failed
    /// readiness/snapshot checks remain unknown/waiting. Neither failure route
    /// authorizes conservative import. The caller owns the final atomic admission
    /// transaction and native submit rechecks; this method does not submit Photos.
    public func prepare(fileID: UUID, file: SourceFile) async throws -> AdvancedPreparation {
        do { return try await prepareCurrent(fileID: fileID, file: file) }
        catch is ModelExecutionUnavailable { return .waiting(reason: ModelExecutionUnavailable.summary) }
        catch is ReadExecutorError { return .waiting(reason: "来源读取稍后继续。") }
        catch is ImageWorkBudgetError { return .waiting(reason: "图像资源稍后可用。") }
        catch is CancellationError { return .waiting(reason: "来源准备已暂停。") }
    }

    private func prepareCurrent(fileID: UUID, file: SourceFile) async throws -> AdvancedPreparation {
        let started = ProcessInfo.processInfo.systemUptime
        var timings: [String: Double] = [:]
        guard !paused, file.metadata.kind == .image,
              try await eligibleRecord(fileID: fileID, file: file) != nil, !paused else { return waiting() }
        guard try await !store.hasUnsupportedSuccessfulFingerprint(version: configuration.fingerprint.version), !paused else {
            return .waiting(reason: "历史照片分析记录需要升级确认，同步正在等待。")
        }
        guard let initialToken = await readyToken(), !paused else { return waiting() }
        guard try await stamp(file) == file.stamp, !paused else { return waiting() }
        let size = sourceSize(file)
        let cacheStarted = ProcessInfo.processInfo.systemUptime
        var fingerprint = try await store.fingerprint(fileID: fileID, stamp: file.stamp,
                                                       version: configuration.fingerprint.version)
        timings["cacheLookup"] = (ProcessInfo.processInfo.systemUptime - cacheStarted) * 1000
        guard !paused else { return waiting() }
        var conservativeReason: RepresentationConservativeReason?
        if fingerprint == nil {
            // This owned task retains the lease through actual decode/inference
            // completion, even if the preparing caller is canceled or paused.
            let reader = MetadataReader(sourceID: file.sourceID, executor: executor)
            let model = fingerprinter, configuration = configuration, budget = budget
            let work = Task { () throws -> (Fingerprint?, RepresentationConservativeReason?, [String: Double]) in
                var physicalTimings: [String: Double] = [:]
                let readStarted = ProcessInfo.processInfo.systemUptime
                var loaded: ImageWorkResult<SourceImage>? = try await reader.readForFingerprint(
                    url: file.url, configuration: configuration, budget: budget)
                physicalTimings["sourceReadDecodeWait"] = (ProcessInfo.processInfo.systemUptime - readStarted) * 1000
                let lease = loaded!.lease
                do {
                    let result: (Fingerprint?, RepresentationConservativeReason?)
                    switch loaded!.value.eligibility {
                    case .safeSingleFrame:
                        let fingerprintStarted = ProcessInfo.processInfo.systemUptime
                        result = (try await model.fingerprint(image: loaded!.value.image,
                            orientation: loaded!.value.orientation), nil)
                        physicalTimings["fingerprintPreprocessInference"] = (ProcessInfo.processInfo.systemUptime - fingerprintStarted) * 1000
                    case .conservative(let reason): result = (nil, reason)
                    }
                    loaded = nil; await lease.finishPhysicalWork()
                    return (result.0, result.1, physicalTimings)
                } catch {
                    loaded = nil; await lease.finishPhysicalWork(); throw error
                }
            }
            let physical = try await work.value
            (fingerprint, conservativeReason) = (physical.0, physical.1)
            timings.merge(physical.2) { _, latest in latest }
            guard !paused, !Task.isCancelled, try await stamp(file) == file.stamp, !paused,
                  try await eligibleRecord(fileID: fileID, file: file) != nil, !paused,
                  let current = await readyToken(), samePhotosIndex(initialToken, current), !paused else { return waiting() }
            if let fingerprint {
                guard fingerprint.version == configuration.fingerprint.version else { throw AdvancedDedupError.modelMismatch }
                let writeStarted = ProcessInfo.processInfo.systemUptime
                guard try await store.cacheFingerprint(.init(fileID: fileID, file: file,
                    fingerprint: fingerprint, size: size)), !paused else { return waiting() }
                timings["cacheWrite"] = (ProcessInfo.processInfo.systemUptime - writeStarted) * 1000
            }
        }
        guard let token = await readyToken(), samePhotosIndex(initialToken, token), !paused else { return waiting() }
        let snapshot: PhotosCandidateSnapshot
        do { snapshot = try await photos.candidateSnapshot() } catch { return waiting() }
        guard !paused, snapshot.generation == token.photosGeneration else { return waiting() }
        let matches: [ScoredCandidate], diagnostics: [ScoredCandidate]
        let evaluation: DuplicateEvaluation
        if conservativeReason != nil {
            matches = []; diagnostics = []
            evaluation = .init(content: .notCompared, action: .importFile, reason: .nonComparableSource,
                               matchedKeys: [], coveringKeys: [])
        } else {
            guard let fingerprint else { return waiting() }
            let searchStarted = ProcessInfo.processInfo.systemUptime
            guard let result = try await store.vectorCandidates(for: fileID, query: fingerprint, token: token,
                threshold: configuration.threshold, diagnosticLimit: 10), !paused else { return waiting() }
            timings["sqliteSearch"] = (ProcessInfo.processInfo.systemUptime - searchStarted) * 1000
            matches = result.matches; diagnostics = result.diagnostics
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
        timings["preparation"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let evidence = AdvancedEvidence(eventID: UUID(), fileID: fileID, stamp: file.stamp, token: token,
            policyVersion: configuration.policyVersion, evaluation: boundedEvaluation,
            decisiveCandidates: decisive.map { [$0] } ?? [], diagnostics: diagnostics,
            timingsMS: timings)
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
    private func waiting() -> AdvancedPreparation { .waiting(reason: "来源或图库索引正在等待确认。") }
}
