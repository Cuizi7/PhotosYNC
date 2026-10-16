import Foundation

private struct RepresentationStageFailure: Error {
    let stage: String
    let error: Error
}

/// Owns one bounded work loop and the durable-inventory → derived-index → Photos
/// acknowledgement barrier. SQLite never waits for Photos or model work.
public actor PhotosIndexCoordinator {
    private let wallNow: @Sendable () -> Date
    private let monotonic: @Sendable () -> TimeInterval
    private var taskCursor: RepresentationKey?
    private var readerTimeoutWaiting = false
    private var readerAdmission: PhotosReaderAdmission = .available
    private let store: SyncStore
    private let photos: any PhotosIndexGateway
    private let fingerprinter: any ImageFingerprinting
    private let configuration: DedupConfiguration
    private var observer: Task<Void, Never>?
    private var started = false, paused = false, reconciling = false, processing = false
    private var pendingDelta: PhotosIndexDelta?
    private var pendingReinsertedIDs = Set<String>()
    private var reconciledContext: LibraryContext?
    private var applyingDelta = false
    private var needsReconciliation = true
    private var forceCacheInvalidation = true
    private var changeSerial: UInt64 = 0
    private var reconciledGeneration: Int?
    private var acknowledgedGeneration: Int?
    private var issue: String?
    // A successful catalog does not resolve failed reads. Retain explicit cloud
    // classification only while the same descriptor remains a current failed fact.
    private var modelWaiting: [String: RepresentationDescriptor] = [:]
    private var cloudWaiting: [String: RepresentationDescriptor] = [:]
    private let indexDiagnostics: IndexDiagnostics
    private let diagnostics: @Sendable ([String: String]) -> Void

    public init(store: SyncStore, photos: any PhotosIndexGateway, fingerprinter: any ImageFingerprinting,
                configuration: DedupConfiguration,
                wallNow: @escaping @Sendable () -> Date = { Date() },
                monotonic: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, indexDiagnostics: IndexDiagnostics? = nil,
                diagnostics: @escaping @Sendable ([String: String]) -> Void = { _ in }) {
        self.wallNow = wallNow; self.monotonic = monotonic
        self.store = store; self.photos = photos; self.fingerprinter = fingerprinter
        let context = indexDiagnostics ?? IndexDiagnostics(sink: diagnostics)
        self.configuration = configuration; self.diagnostics = { context.emit($0) }
        self.indexDiagnostics = context
        photos.attachIndexStore(store)
    }

    deinit { observer?.cancel() }

    public func reconcile() async throws {
        guard !paused else { throw CancellationError() }
        guard !reconciling else { throw PhotoKitGatewayError.libraryChanged }
        reconciling = true; acknowledgedGeneration = nil; pendingDelta = nil; pendingReinsertedIDs.removeAll()
        let diagnostic = indexDiagnostics.operation("reconcile")
        let startedAt = ProcessInfo.processInfo.systemUptime
        var counts = IndexMutationCounts()
        var complete = false
        var retainedReady = 0, unverified = 0, readyToPending = 0
        defer {
            reconciling = false
            diagnostic.finish(); indexDiagnostics.flushObservations()
            diagnostics(["phase": "index-reconcile", "unit": "representationRows", "batch": complete ? "completed" : "aborted",
                "added": String(counts.added), "changed": String(counts.changed), "deleted": String(counts.deleted),
                "readyToPending": String(readyToPending), "operation": diagnostic.id,
                "retainedReady": String(retainedReady), "unverified": String(unverified),
                "timingMS.catalogReconciliation": String((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)])
        }
        do {
            if !started {
                started = true
                // Subscribe before replay. Pages, not stream delivery order, own
                // authoritative content invalidation for this reconciliation.
                let events = photos.changes()
                observer = Task { [weak self] in
                    for await event in events {
                        guard !Task.isCancelled else { break }
                        await self?.libraryChanged(event)
                    }
                }
                if let checkpoint = try await store.libraryResumeCheckpoint() {
                    forceCacheInvalidation = try await !photos.resumeContext(checkpoint)
                }
            }
            let previousCheckpoint = try await store.libraryResumeCheckpoint()
            // Capture the proposed upper token before replay. Metadata pages alone
            // cannot prove that an already cached vector was unchanged through it.
            let checkpoint = try await photos.contextCheckpoint()
            if let checkpoint {
                if let previousCheckpoint {
                    let covered = try await photos.coverPersistentHistory(from: previousCheckpoint, through: checkpoint)
                    diagnostic.record(["phase": "index-history-range", "source": "history", "category": "coverage", "fromRange": indexDiagnostics.tokenHandle(previousCheckpoint.archivedChangeToken), "throughRange": indexDiagnostics.tokenHandle(checkpoint.archivedChangeToken), "fromGeneration": previousCheckpoint.photosGeneration.map(String.init) ?? "unknown", "throughGeneration": checkpoint.photosGeneration.map(String.init) ?? "unknown", "result": covered ? "covered" : "unknown"])
                    if !covered { forceCacheInvalidation = true }
                } else { forceCacheInvalidation = true }
            } else if previousCheckpoint != nil { forceCacheInvalidation = true }
            let snapshot = try await photos.candidateSnapshot()
            let session = try await photos.beginCatalogSession(expectedGeneration: snapshot.generation)
            var offset = 0
            var generation: Int64?
            var eligibleAssets = Set<String>(), excludedAssets = Set<String>()
            var seenKeys = Set<RepresentationKey>()
            var context: LibraryContext?
            var allInvalidated = false
            repeat {
                // Pause may arrive while the previous page/transaction was in flight.
                // Preserve that page, but do not start another catalog request.
                guard !paused else { throw CancellationError() }
                let page = try await photos.representationCatalog(session: session, offset: offset,
                    limit: configuration.resources.catalogBatchSize)
                guard page.generation == snapshot.generation, context == nil || context == page.context,
                      checkpoint == nil || checkpoint?.context == page.context else { throw PhotoKitGatewayError.libraryChanged }
                guard page.descriptors.count + page.exclusions.count <= configuration.resources.catalogBatchSize,
                      page.invalidatedAssetIDs.count <= configuration.resources.catalogBatchSize,
                      page.descriptors.allSatisfy({ $0.context == page.context }),
                      page.exclusions.allSatisfy({ $0.descriptor.context == page.context }) else { throw AdvancedDedupError.invalidConfiguration }
                if generation == nil {
                    context = page.context
                    generation = try await store.beginIndexReconciliation(context: page.context,
                        photosGeneration: snapshot.generation, fingerprintVersion: configuration.fingerprint.version)
                }
                let current = generation!
                if (forceCacheInvalidation || page.invalidateAllCachedRepresentations) && !allInvalidated {
                    let changed = try await store.invalidateRepresentations(assetIDs: nil, generation: current)
                    readyToPending += changed
                    diagnostic.record(["phase": "index-invalidation", "source": "catalog", "reason": forceCacheInvalidation ? "continuity-unknown" : "catalog-unknown", "readyToPending": String(changed), "generation": String(current)])
                    try await photos.catalogInvalidationTransferred(session: session)
                    allInvalidated = true
                } else if !allInvalidated && !page.invalidatedAssetIDs.isEmpty {
                    let changed = try await store.invalidateRepresentations(assetIDs: page.invalidatedAssetIDs, generation: current)
                    readyToPending += changed
                    diagnostic.record(["phase": "index-invalidation", "source": "catalog", "reason": "content-obligation", "readyToPending": String(changed), "assets": String(page.invalidatedAssetIDs.count), "generation": String(current)])
                }
                for descriptor in page.descriptors { diagnostic.record(["phase": "index-catalog-sample", "source": "catalog", "generation": String(current)], descriptor: descriptor) }
                let mutations = try await store.upsertRepresentations(page.descriptors, generation: current, inputUnchangedAssetIDs: Set(page.inputUnchangedAssetIDs).subtracting(page.invalidatedAssetIDs))
                counts.added += mutations.added; counts.changed += mutations.changed
                seenKeys.formUnion(page.descriptors.map(\.key))
                eligibleAssets.formUnion(page.descriptors.map { $0.key.assetID })
                excludedAssets.formUnion(page.exclusions.filter { $0.reason != .nonImage }.map { $0.descriptor.key.assetID })
                if let next = page.nextOffset {
                    guard next > offset else { throw AdvancedDedupError.invalidConfiguration }
                    offset = next
                } else { break }
            } while true
            let endpoint = try await photos.catalogCoverage(session: session)
            if endpoint != snapshot.generation {
                var cursor: String?
                repeat {
                    let batch = try await photos.catalogChanges(baselineGeneration: snapshot.generation,
                        throughGeneration: endpoint, afterAssetID: cursor, limit: max(1, configuration.resources.catalogBatchSize / 2))
                    let affected = Set(batch.changedAssetIDs + batch.deletedAssetIDs)
                    let delta = PhotosIndexDelta(context: context!, fromGeneration: snapshot.generation,
                        toGeneration: endpoint, changedAssetIDs: batch.changedAssetIDs, deletedAssetIDs: batch.deletedAssetIDs)
                    if !affected.isEmpty {
                        let page = try await photos.representationCatalogDelta(session: session, delta: delta)
                        let facts = page.descriptors + page.exclusions.map(\.descriptor)
                        guard page.context == context, page.generation == endpoint, page.nextOffset == nil,
                              !page.invalidateAllCachedRepresentations,
                              facts.count <= configuration.resources.catalogBatchSize,
                              facts.allSatisfy({ $0.context == context }),
                              Set(facts.map(\.key)).count == facts.count,
                              Set(facts.map { $0.key.assetID }) == Set(batch.changedAssetIDs),
                              Set(page.invalidatedAssetIDs).isSubset(of: Set(batch.changedAssetIDs)) else { throw PhotoKitGatewayError.libraryChanged }
                        if !allInvalidated && !page.invalidatedAssetIDs.isEmpty {
                            let changed = try await store.invalidateRepresentations(assetIDs: page.invalidatedAssetIDs, generation: generation!)
                            readyToPending += changed
                            diagnostic.record(["phase": "index-invalidation", "source": "live-catalog", "reason": "content-obligation", "readyToPending": String(changed), "generation": String(generation!)])
                        }
                        let mutations = try await store.upsertRepresentations(page.descriptors, generation: generation!, inputUnchangedAssetIDs: Set(page.inputUnchangedAssetIDs).subtracting(page.invalidatedAssetIDs))
                        counts.added += mutations.added; counts.changed += mutations.changed
                        seenKeys = seenKeys.filter { !affected.contains($0.assetID) }
                        seenKeys.formUnion(page.descriptors.map(\.key))
                        eligibleAssets.subtract(affected); excludedAssets.subtract(affected)
                        eligibleAssets.formUnion(page.descriptors.map { $0.key.assetID })
                        excludedAssets.formUnion(page.exclusions.filter { $0.reason != .nonImage }.map { $0.descriptor.key.assetID })
                    }
                    cursor = batch.nextAssetID
                } while cursor != nil
                // Observer coverage and the conservative pre-read persistent token
                // are separate: a newer current token may include unobserved edits.
                try await store.advanceReconciliationEndpoint(generation: generation!, photosGeneration: endpoint)
            }
            guard try await photos.catalogCoverage(session: session) == endpoint else { throw PhotoKitGatewayError.libraryChanged }
            // Commit continuity even when the long initial fingerprint build is
            // unfinished; this checkpoint proves inventory history, never readiness.
            guard let finish = try await store.finishIndexReconciliation(generation: generation!, seenKeys: seenKeys, checkpoint: checkpoint,
                excludedAssetIDs: excludedAssets.subtracting(eligibleAssets)) else { throw PhotoKitGatewayError.libraryChanged }
            counts.deleted += finish.deleted
            try await photos.acknowledgeInventory(expectedGeneration: endpoint)
            complete = true
            let storedProgress = try await store.indexProgress()
            retainedReady = storedProgress.readyRepresentations
            unverified = storedProgress.totalRepresentations - storedProgress.readyRepresentations
            let retainedCloudFailures = try await store.currentFailedRepresentations(Array(cloudWaiting.values),
                fingerprintVersion: configuration.fingerprint.version)
            let retainedModelFailures = try await store.currentFailedRepresentations(Array(modelWaiting.values),
                fingerprintVersion: configuration.fingerprint.version)
            guard !paused else { throw CancellationError() }
            let after = try await photos.candidateSnapshot()
            guard after.generation == endpoint else { throw PhotoKitGatewayError.libraryChanged }
            needsReconciliation = false; forceCacheInvalidation = false
            reconciledGeneration = endpoint; reconciledContext = context; pendingDelta = nil; issue = nil
            cloudWaiting = Dictionary(uniqueKeysWithValues: retainedCloudFailures.map { (Self.waitKey($0), $0) })
            modelWaiting = Dictionary(uniqueKeysWithValues: retainedModelFailures.map { (Self.waitKey($0), $0) })
            try await publishIfComplete()
        } catch {
            needsReconciliation = true; issue = "图库索引正在等待重新核对。"
            try? await store.invalidateIndexPublication()
            throw error
        }
    }

    /// `now` is frozen eligibility for this finite slice. Retry deadlines use
    /// the wall clock at failure; admission limits use monotonic elapsed time.
    public func processDueWork(now: Date) async {
        guard !processing, !paused else { return }
        processing = true
        let diagnostic = indexDiagnostics.operation("work")
        let sliceStarted = monotonic()
        var sliceReason = "empty", attempted = 0
        var completed = 0, failed = 0, readErrors = 0
        defer {
            processing = false
            indexDiagnostics.state("slice", value: sliceReason, fields: ["attempts": String(attempted)])
            diagnostic.finish(); indexDiagnostics.flushObservations()
            if completed > 0 || failed > 0 {
                diagnostics(["phase": "index-work", "unit": "representationTasks", "completed": String(completed),
                             "failed": String(failed), "readErrors": String(readErrors), "waiting": String(failed - readErrors),
                             "batch": paused || needsReconciliation ? "interrupted" : "completed"])
            }
        }
        do {
            readerAdmission = await photos.representationReadAdmission()
            indexDiagnostics.state("reader-admission", value: readerAdmission.rawValue)
            guard !paused else { sliceReason = "paused"; return }
            guard readerAdmission == .available else { sliceReason = readerAdmission.rawValue; return }
            readerTimeoutWaiting = false
            try await updateInventory()
            guard !paused, !needsReconciliation, !reconciling, pendingDelta == nil else { return }
            do {
                // Serial consumer keeps physical image/model concurrency at one,
                // below every configured limit. Polling itself never claims work.
                let tasks = try await store.nextRepresentationTasks(now: now,
                    limit: 16, after: taskCursor)
                guard !tasks.isEmpty else { try await publishIfComplete(); return }
                let batchGeneration = reconciledGeneration
                for task in tasks {
                    guard monotonic() - sliceStarted < 1 else { sliceReason = "time-budget"; break }
                    guard !paused, !needsReconciliation, !reconciling, pendingDelta == nil, reconciledGeneration == batchGeneration else { break }
                    let expected = reconciledGeneration, serial = changeSerial
                    readerAdmission = await photos.representationReadAdmission()
                    indexDiagnostics.state("reader-admission", value: readerAdmission.rawValue)
                    guard !paused, !needsReconciliation, !reconciling, pendingDelta == nil,
                          reconciledGeneration == expected, changeSerial == serial else { break }
                    guard readerAdmission == .available else { sliceReason = readerAdmission.rawValue; break }
                    let snapshot = try await photos.candidateSnapshot()
                    // Snapshot acquisition suspends this actor. Admit no new
                    // physical work if pause or reconciliation changed meanwhile.
                    guard !paused, !needsReconciliation, !reconciling,
                          pendingDelta == nil, changeSerial == serial, reconciledGeneration == expected else { break }
                    guard monotonic() - sliceStarted < 1 else { sliceReason = "time-budget"; break }
                    guard snapshot.generation == expected else {
                        if pendingDelta == nil { needsReconciliation = true }
                        acknowledgedGeneration = nil; break
                    }
                    // An unstructured owned Task does not inherit later caller
                    // cancellation. Pause cannot cancel already-started consumers.
                    attempted += 1; taskCursor = task.descriptor.key
                    sliceReason = attempted == 16 ? "attempt-budget" : "selected-work-complete"
                    diagnostic.record(["phase": "index-task", "event": "attempt", "retryCount": String(task.retryCount)], task: task)
                    let photos = photos, model = fingerprinter
                    let work = Task { () throws -> Fingerprint in
                        var fields = ["phase": "index-representation-timing",
                                      "representation": task.descriptor.key.kind.rawValue]
                        let readStarted = ProcessInfo.processInfo.systemUptime
                        defer {
                            if fields["timingMS.representationReadWait"] == nil {
                                fields["timingMS.representationReadWait"] = String((ProcessInfo.processInfo.systemUptime - readStarted) * 1000)
                            }
                            diagnostic.record(fields, task: task)
                        }
                        var loaded: LoadedRepresentation?
                        do { loaded = try await photos.readRepresentation(task.descriptor) }
                        catch is CancellationError { throw CancellationError() }
                        catch { throw RepresentationStageFailure(stage: "photos-read", error: error) }
                        fields["timingMS.representationReadWait"] = String((ProcessInfo.processInfo.systemUptime - readStarted) * 1000)
                        let lease = loaded!.lease
                        do {
                            guard loaded?.descriptor == task.descriptor,
                                  loaded?.eligibility == .safeSingleFrame else { throw PhotoKitGatewayError.libraryChanged }
                            let fingerprintStarted = ProcessInfo.processInfo.systemUptime
                            let fingerprint: Fingerprint
                            do {
                                defer { fields["timingMS.fingerprintPreprocessInference"] = String((ProcessInfo.processInfo.systemUptime - fingerprintStarted) * 1000) }
                                fingerprint = try await model.fingerprint(image: loaded!.image, orientation: loaded!.orientation)
                            }
                            // Release the last owned bitmap reference before making
                            // its physical budget slot available to another consumer.
                            loaded = nil
                            await lease.finishPhysicalWork()
                            return fingerprint
                        } catch {
                            loaded = nil
                            await lease.finishPhysicalWork()
                            if error is CancellationError { throw error }
                            throw RepresentationStageFailure(stage: "fingerprint", error: error)
                        }
                    }
                    let waitKey = Self.waitKey(task.descriptor)
                    var completionStage = "currentness"
                    do {
                        let fingerprint = try await work.value
                        // Resolve observed changes before deciding whether this *task* is stale.
                        // SQLite issuance/descriptor checks accept unaffected work across generations.
                        if !paused { try await updateInventory() }
                        let latest = try await photos.candidateSnapshot()
                        guard !needsReconciliation, !reconciling, pendingDelta == nil,
                              latest.generation == reconciledGeneration else {
                            diagnostic.record(["phase": "index-task", "event": "rejected", "reason": "inventory-not-current", "stage": "currentness"], task: task)
                            acknowledgedGeneration = nil; continue
                        }
                        completionStage = "sqlite-completion"
                        if try await store.completeRepresentation(task, fingerprint: fingerprint) {
                            diagnostic.record(["phase": "index-task", "event": "accepted"], task: task)
                            completed += 1; cloudWaiting.removeValue(forKey: waitKey); modelWaiting.removeValue(forKey: waitKey)
                        } else { diagnostic.record(["phase": "index-task", "event": "rejected", "reason": "stale-issuance"], task: task) }
                    } catch is CancellationError {
                        // Eligibility revoked before a new model phase is deferred work,
                        // not a damaged image. The owned task has returned and released
                        // its lease; keep its existing durable issuance/deadline unchanged.
                        diagnostic.record(["phase": "index-task", "event": "deferred", "reason": "cancelled", "stage": "owned-work"], task: task)
                        return
                    } catch {
                        let stageFailure = error as? RepresentationStageFailure
                        let underlying = stageFailure?.error ?? error
                        let stage = stageFailure?.stage ?? completionStage
                        if stage == "photos-read", (underlying as? ReadExecutorError == .resourceExhausted ||
                            underlying as? ReadExecutorError == .sourceBusy || underlying as? ImageWorkBudgetError == .exhausted) {
                            readerAdmission = await photos.representationReadAdmission()
                            if readerAdmission == .available { readerAdmission = .busy }
                            indexDiagnostics.state("reader-admission", value: readerAdmission.rawValue)
                            diagnostic.record(["phase": "index-task", "event": "deferred", "reason": "reader-capacity", "stage": stage], task: task)
                            sliceReason = readerAdmission.rawValue
                            return
                        }
                        let failureTime = wallNow()
                        let readFailure = stage == "photos-read" &&
                            (underlying as? PhotosRepresentationError)?.isIsolatableReadFailure == true
                        let latest = try? await photos.candidateSnapshot()
                        if needsReconciliation || reconciling || pendingDelta != nil || latest?.generation != reconciledGeneration {
                            diagnostic.record(["phase": "index-task", "event": "rejected", "reason": "stale-failure", "stage": stage], task: task)
                            if pendingDelta == nil { needsReconciliation = true }; acknowledgedGeneration = nil
                        } else {
                            let delays = configuration.resources.retryDelaysSeconds
                            let delay = underlying is ModelExecutionUnavailable ? 60 : delays[min(task.retryCount, delays.count - 1)]
                            if try await store.failRepresentation(task, nextRetryAt: failureTime.addingTimeInterval(delay),
                                detail: String(describing: underlying), failureKind: readFailure ? .photosRead : nil) {
                                diagnostic.record(["phase": "index-task", "event": "failure", "stage": stage, "failureAt": String(failureTime.timeIntervalSince1970), "deadline": String(failureTime.addingTimeInterval(delay).timeIntervalSince1970)], task: task)
                                failed += 1
                                if readFailure { readErrors += 1 }
                                diagnostics(["phase": "index-representation", "stage": stage,
                                    "result": readFailure ? "read-error" : "waiting",
                                    "representation": task.descriptor.key.kind.rawValue, "error": String(describing: underlying),
                                    "retryCount": String(task.retryCount + 1), "failureAt": String(failureTime.timeIntervalSince1970),
                                    "nextRetryAt": String(failureTime.addingTimeInterval(delay).timeIntervalSince1970)])
                                if underlying is ModelExecutionUnavailable { modelWaiting[waitKey] = task.descriptor }
                                else { modelWaiting.removeValue(forKey: waitKey) }
                                if case .iCloudUnavailable = underlying as? PhotosRepresentationError { cloudWaiting[waitKey] = task.descriptor }
                                else { cloudWaiting.removeValue(forKey: waitKey) }
                            } else {
                                diagnostic.record(["phase": "index-task", "event": "rejected", "reason": "stale-failure-issuance", "stage": stage], task: task)
                            }
                        }
                        if stage == "photos-read", underlying as? ReadExecutorError == .timedOut {
                            readerAdmission = await photos.representationReadAdmission()
                            readerTimeoutWaiting = true
                            sliceReason = "logical-timeout"
                            return
                        }
                    }
                }
            }
            if !needsReconciliation && !reconciling { try await publishIfComplete() }
        } catch {
            acknowledgedGeneration = nil; needsReconciliation = true
            issue = "图库索引正在等待恢复。"
            try? await store.invalidateIndexPublication()
        }
    }

    public func setPaused(_ paused: Bool) async { self.paused = paused }

    public func progress() async -> IndexProgress {
        do {
            let stored = try await store.indexProgress()
            let ready = try await readyToken() != nil
            let representationIssue: String?
            if stored.state != .waiting { representationIssue = nil }
            else if !modelWaiting.isEmpty { representationIssue = ModelExecutionUnavailable.summary }
            else if !cloudWaiting.isEmpty { representationIssue = "正在等待 iCloud 图像，连接恢复后自动继续" }
            else { representationIssue = stored.issue }
            let capacityIssue: String?
            if processing || ready || readerAdmission == .available ||
                stored.readyRepresentations + stored.readErrorRepresentations >= stored.totalRepresentations { capacityIssue = nil }
            else if readerAdmission == .stalled { capacityIssue = "正在等待系统结束图像读取，完成后自动继续。" }
            else { capacityIssue = "正在等待图像读取资源，稍后自动继续。" }
            let specificIssue = !modelWaiting.isEmpty || !cloudWaiting.isEmpty ? representationIssue : nil
            let aggregateIssue = issue ?? specificIssue ?? (readerTimeoutWaiting ? capacityIssue : nil) ?? representationIssue ?? capacityIssue
            let state: IndexState = ready ? .ready : (paused ? .paused :
                (aggregateIssue != nil || stored.state == .waiting ? .waiting : (stored.totalsKnown ? .updating : .preparing)))
            return IndexProgress(state: state, totalsKnown: stored.totalsKnown && !needsReconciliation,
                totalAssets: stored.totalAssets, readyAssets: stored.readyAssets,
                totalRepresentations: stored.totalRepresentations, readyRepresentations: stored.readyRepresentations,
                readErrorRepresentations: stored.readErrorRepresentations,
                excludedAssets: stored.excludedAssets, issue: aggregateIssue)
        } catch {
            return IndexProgress(state: paused ? .paused : .waiting, totalsKnown: false, totalAssets: 0,
                readyAssets: 0, totalRepresentations: 0, readyRepresentations: 0, excludedAssets: 0,
                issue: "图库索引正在等待恢复。")
        }
    }

    public func readyToken() async throws -> IndexToken? {
        guard !needsReconciliation, !reconciling, !applyingDelta, pendingDelta == nil, let acknowledgedGeneration else { return nil }
        guard let publication = try await store.indexReadiness(),
              publication.token.photosGeneration == acknowledgedGeneration,
              try await store.indexIsReady(token: publication.token) else { return nil }
        let snapshot = try await photos.candidateSnapshot()
        if snapshot.generation != acknowledgedGeneration {
            if pendingDelta == nil { needsReconciliation = true }; self.acknowledgedGeneration = nil
            try await store.invalidateIndexPublication()
            return nil
        }
        guard !needsReconciliation, !reconciling, pendingDelta == nil,
              self.acknowledgedGeneration == acknowledgedGeneration else { return nil }
        return publication.token
    }

    private static func waitKey(_ descriptor: RepresentationDescriptor) -> String {
        "\(descriptor.key.assetID.utf8.count):\(descriptor.key.assetID):\(descriptor.key.kind.rawValue)"
    }

    /// Both runtime wakeups and this actor's subscription may deliver the same event.
    /// A fully covered incremental delivery is idempotent; gaps/overlap/overflow are full.
    public func libraryChanged(_ event: PhotosIndexChange) async {
        if case .incremental(let delta) = event, delta.isValid {
            let through = pendingDelta?.toGeneration ?? reconciledGeneration
            if delta.context == reconciledContext, let through, delta.toGeneration <= through { return }
        }
        changeSerial &+= 1; acknowledgedGeneration = nil
        switch event {
        case .incremental(let delta):
            if !needsReconciliation, !reconciling, delta.isValid, delta.context == reconciledContext,
               delta.fromGeneration == (pendingDelta?.toGeneration ?? reconciledGeneration) {
                if pendingDelta == nil {
                    pendingDelta = delta
                    try? await store.invalidateIndexPublication()
                    return
                }
                pendingReinsertedIDs.formUnion(Set(pendingDelta?.deletedAssetIDs ?? []).intersection(delta.changedAssetIDs))
                var changed = Set(pendingDelta?.changedAssetIDs ?? [])
                var deleted = Set(pendingDelta?.deletedAssetIDs ?? [])
                changed.subtract(delta.deletedAssetIDs); deleted.formUnion(delta.deletedAssetIDs)
                deleted.subtract(delta.changedAssetIDs); changed.formUnion(delta.changedAssetIDs)
                if changed.count + deleted.count <= configuration.resources.catalogBatchSize {
                    pendingDelta = .init(context: delta.context, fromGeneration: pendingDelta?.fromGeneration ?? delta.fromGeneration,
                        toGeneration: delta.toGeneration, changedAssetIDs: changed.sorted(), deletedAssetIDs: deleted.sorted())
                } else { pendingDelta = nil; pendingReinsertedIDs.removeAll(); needsReconciliation = true }
            } else { pendingDelta = nil; pendingReinsertedIDs.removeAll(); needsReconciliation = true }
        case .fullReconcileRequired, .contextInvalidated:
            pendingDelta = nil; pendingReinsertedIDs.removeAll(); needsReconciliation = true
        }
        try? await store.invalidateIndexPublication()
    }

    private func updateInventory() async throws {
        guard !paused, !applyingDelta else { return }
        if needsReconciliation { try await reconcile(); return }
        guard let delta = pendingDelta else { return }
        applyingDelta = true
        defer { applyingDelta = false }
        let serial = changeSerial
        let reinserted = pendingReinsertedIDs
        do {
            let checkpoint = try await store.libraryResumeCheckpoint()
            guard !paused, serial == changeSerial else { throw PhotoKitGatewayError.libraryChanged }
            let batchSize = max(1, configuration.resources.catalogBatchSize / 2)
            let ids = delta.changedAssetIDs + delta.deletedAssetIDs
            let offsets = ids.isEmpty ? [0] : Array(stride(from: 0, to: ids.count, by: batchSize))
            for (index, offset) in offsets.enumerated() {
                let slice = PhotosIndexDeltaBatch(interval: delta, offset: offset, count: min(batchSize, ids.count - offset))
                let batch = slice.request
                let page = try await photos.representationDelta(batch)
                guard !paused, serial == changeSerial,
                      page.descriptors.count + page.exclusions.count <= configuration.resources.catalogBatchSize else { throw PhotoKitGatewayError.libraryChanged }
                let effectivePage = RepresentationPage(context: page.context, generation: page.generation, descriptors: page.descriptors,
                    nextOffset: page.nextOffset, exclusions: page.exclusions,
                    invalidatedAssetIDs: Set(page.invalidatedAssetIDs).union(reinserted.intersection(batch.changedAssetIDs)).sorted(),
                    invalidateAllCachedRepresentations: page.invalidateAllCachedRepresentations, inputUnchangedAssetIDs: page.inputUnchangedAssetIDs)
                _ = try await store.applyIndexDeltaBatch(slice, page: effectivePage,
                    fingerprintVersion: configuration.fingerprint.version, checkpoint: index == offsets.count - 1 ? checkpoint : nil,
                    diagnostic: indexDiagnostics.operation("live-delta"))
            }
            guard !paused, serial == changeSerial else { throw PhotoKitGatewayError.libraryChanged }
            let snapshot = try await photos.candidateSnapshot()
            guard !paused, serial == changeSerial, snapshot.generation == delta.toGeneration else { throw PhotoKitGatewayError.libraryChanged }
            let affected = Set(delta.changedAssetIDs + delta.deletedAssetIDs)
            let retainedModels = try await store.currentFailedRepresentations(modelWaiting.values.filter { affected.contains($0.key.assetID) },
                fingerprintVersion: configuration.fingerprint.version)
            let retained = try await store.currentFailedRepresentations(cloudWaiting.values.filter { affected.contains($0.key.assetID) },
                fingerprintVersion: configuration.fingerprint.version)
            guard !paused, serial == changeSerial else { throw PhotoKitGatewayError.libraryChanged }
            modelWaiting = modelWaiting.filter { !affected.contains($0.value.key.assetID) }
            for descriptor in retainedModels { modelWaiting[Self.waitKey(descriptor)] = descriptor }
            cloudWaiting = cloudWaiting.filter { !affected.contains($0.value.key.assetID) }
            for descriptor in retained { cloudWaiting[Self.waitKey(descriptor)] = descriptor }
            try await photos.acknowledgeInventory(expectedGeneration: delta.toGeneration)
            pendingDelta = nil; pendingReinsertedIDs.removeAll(); reconciledGeneration = delta.toGeneration; issue = nil
        } catch {
            pendingDelta = nil; pendingReinsertedIDs.removeAll(); needsReconciliation = true; acknowledgedGeneration = nil
            try? await store.invalidateIndexPublication()
            // Missing IDs, partial pages and racing generations never imply deletion.
            // A bounded full pass is the authoritative recovery, including empty deltas.
            if !paused { try await reconcile() } else { throw error }
        }
    }

    private func publishIfComplete() async throws {
        if try await readyToken() != nil { return }
        guard !needsReconciliation, pendingDelta == nil, let publication = try await store.indexPublication(),
              publication.token.photosGeneration == reconciledGeneration else { return }
        let snapshot = try await photos.candidateSnapshot()
        guard !needsReconciliation, pendingDelta == nil, snapshot.generation == publication.token.photosGeneration else { throw PhotoKitGatewayError.libraryChanged }
        guard !needsReconciliation, pendingDelta == nil, try await store.markIndexPublished(token: publication.token) else { throw PhotoKitGatewayError.libraryChanged }
        try await photos.acknowledgeReconciliation(expectedGeneration: publication.token.photosGeneration)
        let latest = try await photos.candidateSnapshot()
        guard !needsReconciliation, pendingDelta == nil, latest.generation == publication.token.photosGeneration,
              try await store.indexIsReady(token: publication.token) else { throw PhotoKitGatewayError.libraryChanged }
        acknowledgedGeneration = publication.token.photosGeneration; issue = nil; cloudWaiting.removeAll()
    }
}
