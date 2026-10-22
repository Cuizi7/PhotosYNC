import CryptoKit
import Foundation

public enum LivePhotoDiagnosticStage: String, Sendable {
    case admission = "read-admission", rawRead = "raw-read", classification
    case metadata, descriptorValidation = "descriptor-validation", observationCommit = "observation-commit", completion
}

private struct DiagnosticCauseEvent {
    let sequence: UInt64
    let generation: Int?
    let fields: [String: String]
}
private struct DiagnosticCauseWindow {
    let context: LibraryContext
    var events: [DiagnosticCauseEvent] = []
    var omittedThrough: UInt64 = 0
}
private struct BoundDiagnosticCause {
    let context: LibraryContext
    let indexGeneration: Int64
    let revision: String
    let fields: [String: String]
}

private struct DiagnosticElapsed {
    var count = 0
    var sum: TimeInterval = 0
    var max: TimeInterval = 0
    mutating func add(_ seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { return }
        count += 1; sum += seconds; max = Swift.max(max, seconds)
    }
    func fields(_ stage: String) -> [String: String] {
        ["timing.\(stage).count": String(count), "timing.\(stage).sumMS": String(sum * 1000),
         "timing.\(stage).maxMS": String(max * 1000)]
    }
}

/// Best-effort causal facts only. No decisions, durable identity or history coverage
/// are derived from these run-local handles. Sinks run after diagnostic locks unlock.
public final class IndexDiagnostics: @unchecked Sendable {
    public let run = UUID().uuidString
    private let secret = SymmetricKey(size: .bits256)
    private let sink: @Sendable ([String: String]) -> Void
    private let lock = NSLock()
    private var samples = Set<String>()
    private var sequence: UInt64 = 0
    private var issuances: [String: (descriptor: String, issuance: String, causes: [String: String])] = [:]
    // Four obligation observations per sampled asset; neutral observations do not replace
    // pending provenance. Bindings/accepted watermarks/attempt snapshots have at most 16 keys.
    private var causes: [String: DiagnosticCauseWindow] = [:]
    private var boundCauses: [String: BoundDiagnosticCause] = [:]
    private var acceptedCauseSequences: [String: UInt64] = [:]
    private var causeCounts: [String: Int] = [:]
    private var causeDetails = 0
    private var windowTimings: [String: DiagnosticElapsed] = [:]
    private var livePhotoTimings: [String: DiagnosticElapsed] = [:]
    private var livePhotoCounts: [String: Int64] = [:]
    private var livePhotoDetails: [LivePhotoDiagnosticStage: Int] = [:]
    private var livePhotoReasons: [LivePhotoDiagnosticStage: String] = [:]
    private var windowStarted: TimeInterval
    private var readerCounts: [String: Int] = [:]
    private var states: [String: (value: String, suppressed: Int, start: TimeInterval)] = [:]
    private var neutral: [String: (start: TimeInterval, emitted: Int, suppressed: Int, assets: Int, batches: Int)] = [:]
    private let monotonic: @Sendable () -> TimeInterval

    public init(sink: @escaping @Sendable ([String: String]) -> Void,
                monotonic: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.sink = sink; self.monotonic = monotonic; self.windowStarted = monotonic()
    }
    public func handle(_ category: String, _ value: String) -> String {
        let bytes = Data((category + ":" + value).utf8)
        return category + "-" + HMAC<SHA256>.authenticationCode(for: bytes, using: secret).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    public func tokenHandle(_ value: Data) -> String { handle("range", value.base64EncodedString()) }
    public func measureLivePhoto<Value>(_ stage: LivePhotoDiagnosticStage, assetID: String? = nil, event: Int? = nil,
                                       bytes: (Value) -> Int64 = { _ in 0 },
                                       _ operation: () async throws -> Value) async throws -> Value {
        let started = monotonic()
        do {
            let value = try await operation()
            let outcome: String
            if stage == .completion, let advanced = value as? Bool { outcome = advanced ? "advanced" : "no-progress" }
            else { outcome = "completed" }
            recordLivePhoto(stage, assetID: assetID, event: event, seconds: monotonic() - started, bytes: bytes(value), error: nil, outcome: outcome)
            return value
        } catch {
            recordLivePhoto(stage, assetID: assetID, event: event, seconds: monotonic() - started, bytes: 0, error: error)
            throw error
        }
    }
    private func recordLivePhoto(_ stage: LivePhotoDiagnosticStage, assetID: String?, event: Int?, seconds: TimeInterval, bytes: Int64, error: Error?, outcome: String = "completed") {
        let reason: String
        if let error {
            switch error {
            case is CancellationError: reason = "cancelled"
            case let deferred as LivePhotoReadDeferred: reason = deferred == .classificationPending ? "classification-pending" : "resource-changed"
            case let failure as PhotoKitGatewayError: reason = failure == .libraryChanged ? "library-changed" : "photos-failure"
            case let failure as LivePhotoResourceReadError:
                switch failure {
                case .resourceLimit, .workingSetLimit: reason = "resource-limit"
                case .budgetBusy: reason = "admission-deferred"
                case .requestTimedOut: reason = "read-timeout"
                }
            case is ReadExecutorError, is PhotosAdmissionDeferred: reason = "admission-deferred"
            default: reason = "failed"
            }
        } else { reason = outcome }
        let now = monotonic()
        lock.lock()
        livePhotoTimings[stage.rawValue, default: DiagnosticElapsed()].add(seconds)
        livePhotoCounts[stage.rawValue + "." + reason, default: 0] += 1
        livePhotoCounts[stage.rawValue + ".bytes", default: 0] += max(0, bytes)
        let changed = livePhotoReasons[stage] != reason
        let detailed = livePhotoDetails[stage, default: 0] < 2 || changed
        livePhotoReasons[stage] = reason
        if detailed { livePhotoDetails[stage, default: 0] += 1 }
        let flush = now - windowStarted >= 30
        lock.unlock()
        if detailed {
            var fields = ["phase": "live-photo-stage", "stage": stage.rawValue, "result": reason,
                          "elapsedMS": String(max(0, seconds) * 1000), "resourceBytes": String(bytes)]
            if let assetID { fields["assetHandle"] = handle("asset", assetID) }
            if let event { fields["eventGeneration"] = String(event) }
            emit(fields)
        }
        if flush { flushObservations() }
    }
    public func operation(_ category: String, descriptor: RepresentationDescriptor? = nil) -> IndexDiagnosticOperation {
        lock.lock(); sequence &+= 1; let id = "\(category)-\(sequence)"; lock.unlock()
        return IndexDiagnosticOperation(context: self, id: id, identityBound: descriptor != nil,
            identity: descriptor.flatMap { sample($0) })
    }
    fileprivate func assetSample(_ assetID: String) -> [String: String]? {
        let asset = handle("asset", assetID)
        lock.lock()
        if samples.count < 8 { samples.insert(asset) }
        let selected = samples.contains(asset); lock.unlock()
        return selected ? ["assetHandle": asset] : nil
    }
    fileprivate func sample(_ descriptor: RepresentationDescriptor, includeIssuance: Bool = true,
                            task: RepresentationTask? = nil, generation: Int64? = nil) -> [String: String]? {
        guard var fields = assetSample(descriptor.key.assetID) else { return nil }
        // Encode the full descriptor, including unknown revision reliability. Never
        // retain a per-library descriptor map just to produce diagnostic handles.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(descriptor)) ?? Data()
        fields["descriptorHandle"] = handle("descriptor", encoded.base64EncodedString())
        fields["representation"] = descriptor.key.kind.rawValue
        fields.merge(scope(descriptor.context)) { _, new in new }
        let asset = fields["assetHandle"]!
        let key = asset + ":" + descriptor.key.kind.rawValue
        lock.lock(); let issuance = issuances[key], cause = boundCauses[key]; lock.unlock()
        let matchingRevision = cause?.revision == descriptor.revision || (task != nil && cause?.revision == task?.issuanceRevision)
        let matchingGeneration = (task?.indexGeneration ?? generation).map { $0 == cause?.indexGeneration } ?? true
        if cause?.context == descriptor.context, matchingRevision, matchingGeneration {
            fields.merge(cause!.fields) { _, new in new }
        } else if task != nil {
            fields.merge(["causeSource": "unknown", "causeRelation": "unattributed", "cause.content": "unknown"]) { _, new in new }
        }
        if includeIssuance, issuance?.descriptor == fields["descriptorHandle"], let issuance {
            fields = fields.filter { !Self.isProvenance($0.key) }
            fields.merge(issuance.causes) { _, new in new }
            fields["issuanceHandle"] = issuance.issuance
        }
        return fields
    }
    fileprivate func linkIssuance(_ fields: [String: String]) {
        guard let asset = fields["assetHandle"], let kind = fields["representation"],
              let descriptor = fields["descriptorHandle"], let issuance = fields["issuanceHandle"] else { return }
        lock.lock(); issuances[asset + ":" + kind] = (descriptor, issuance, fields.filter { Self.isProvenance($0.key) }); lock.unlock()
    }
    private static func isProvenance(_ key: String) -> Bool { key.hasPrefix("cause") || key.hasPrefix("invalidation") }
    fileprivate func bindInvalidation(_ descriptor: RepresentationDescriptor, indexGeneration: Int64,
                                      photosGeneration: Int, operation: String, unknownScope: Bool, reason: String) {
        guard let sample = assetSample(descriptor.key.assetID), let asset = sample["assetHandle"] else { return }
        let key = asset + ":" + descriptor.key.kind.rawValue
        lock.lock()
        let watermark = acceptedCauseSequences[key, default: 0]
        let window = causes[asset]
        let events = window?.context == descriptor.context ? (window?.events.filter {
            $0.sequence > watermark && ($0.generation.map { $0 <= photosGeneration } ?? false)
        } ?? []) : []
        let omitted = window?.context == descriptor.context && (window?.omittedThrough ?? 0) > watermark
        var fields: [String: String]
        if !unknownScope, events.count == 1, !omitted {
            fields = events[0].fields
        } else {
            sequence &+= 1
            fields = ["causeHandle": "cause-\(sequence)", "causeSequence": String(sequence),
                "causeSource": unknownScope || events.isEmpty ? "unknown" : "mixed", "cause.content": "unknown",
                "causeGeneration": String(photosGeneration), "cause.category": reason]
            if !unknownScope, !events.isEmpty { fields["causeHandles"] = events.compactMap { $0.fields["causeHandle"] }.joined(separator: ",") }
            if !unknownScope, omitted { fields["causeOmitted"] = "true" }
        }
        fields["causeRelation"] = "bound-invalidation"
        fields["invalidationOperation"] = operation; fields["invalidationIndexGeneration"] = String(indexGeneration)
        fields["invalidationPhotosGeneration"] = String(photosGeneration)
        fields["invalidationScope"] = unknownScope ? "all" : "asset"
        boundCauses[key] = BoundDiagnosticCause(context: descriptor.context, indexGeneration: indexGeneration,
            revision: descriptor.revision, fields: fields)
        lock.unlock()
    }
    fileprivate func accepted(_ task: RepresentationTask) {
        let asset = handle("asset", task.descriptor.key.assetID), key = asset + ":" + task.descriptor.key.kind.rawValue
        lock.lock()
        if let bound = boundCauses[key], bound.context == task.descriptor.context,
           bound.indexGeneration == task.indexGeneration, let sequence = UInt64(bound.fields["causeSequence"] ?? "") {
            acceptedCauseSequences[key] = max(acceptedCauseSequences[key, default: 0], sequence)
        }
        lock.unlock()
    }
    public func scope(_ context: LibraryContext) -> [String: String] {
        ["contextHandle": handle("context", context.id.uuidString), "contextEpoch": String(context.epoch)]
    }
    /// Facts name public fields, never their values. History identifiers remain unknown
    /// content evidence. Correlation is bounded, run-local and best effort across restarts.
    public func recordCause(context: LibraryContext, assetID: String, source: String, generation: Int?,
                            facts: [String: String], operation: String? = nil, inputObligation: Bool = true) {
        let source = ["history", "live", "catalog"].contains(source) ? source : "unknown"
        lock.lock(); causeCounts[source, default: 0] += 1; lock.unlock()
        guard let sample = assetSample(assetID), let asset = sample["assetHandle"] else { return }
        let allowed = Set(["category", "content", "assetContentChanged", "visibleInputFields", "metadataFields"])
        let facts = facts.filter { allowed.contains($0.key) }
        var chain = facts.reduce(into: [String: String]()) { $0["cause." + $1.key] = $1.value }
        lock.lock()
        sequence &+= 1
        chain["causeHandle"] = "cause-\(sequence)"; chain["causeSequence"] = String(sequence)
        chain["causeSource"] = source; chain["causeGeneration"] = generation.map(String.init) ?? "unknown"
        if let operation { chain["causeOperation"] = operation }
        if inputObligation {
            var window = causes[asset].flatMap { $0.context == context ? $0 : nil } ?? DiagnosticCauseWindow(context: context)
            if window.events.count == 4 { window.omittedThrough = window.events.removeFirst().sequence }
            window.events.append(DiagnosticCauseEvent(sequence: sequence, generation: generation, fields: chain))
            causes[asset] = window
        }
        let admitted = causeDetails < 64
        if admitted { causeDetails += 1 }
        lock.unlock()
        if admitted {
            var row = facts
            row.merge(chain) { _, new in new }; row.merge(scope(context)) { _, new in new }
            row["phase"] = "index-cause"; row["source"] = source; row["assetHandle"] = asset
            row["inputObligation"] = String(inputObligation)
            emit(row)
        }
    }
    /// Fixed runtime stage names; the overflow bucket keeps accidental new names bounded.
    public func recordTiming(stage: String, seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { return }
        let now = monotonic()
        lock.lock()
        let key = windowTimings[stage] != nil || windowTimings.count < 32 ? stage : "other"
        windowTimings[key, default: DiagnosticElapsed()].add(seconds)
        let flush = now - windowStarted >= 30
        lock.unlock()
        if flush { flushObservations() }
    }
    public func emit(_ fields: [String: String]) {
        var fields = fields; fields["run"] = run; sink(fields)
    }
    /// Coalesce only high-frequency neutral observations. Unknown scope, content
    /// changes, errors and state transitions always retain their existing facts.
    public func observation(_ fields: [String: String], assetID: String? = nil) {
        let phase = fields["phase"] ?? ""
        let isNeutral = phase == "photos-notification" || phase == "photos-live-neutral" || phase == "index-live-transfer-neutral" ||
            (phase == "photos-fetch-details" && fields["fallback"] == nil) ||
            (phase == "photos-change-classification" && fields["contentScope"] == "known" &&
             fields["contentChanged"] == "0" && fields["inserted"] == "0" && fields["deleted"] == "0")
        guard isNeutral else { emit(fields); return }
        let now = monotonic()
        var summary: [String: String]?
        lock.lock()
        var bucket = neutral[phase] ?? (now, 0, 0, 0, 0)
        if now - bucket.start >= 30 {
            if bucket.suppressed > 0 { summary = ["phase": "index-observation-summary", "category": phase, "suppressed": String(bucket.suppressed), "assetObservations": String(bucket.assets)] }
            if bucket.batches > 0 { summary?["batchObservations"] = String(bucket.batches) }
            bucket = (now, 0, 0, 0, 0)
        }
        bucket.assets += Int(fields["assets"] ?? "0") ?? 0
        bucket.batches += Int(fields["batches"] ?? "0") ?? 0
        let admitted = bucket.emitted < 2
        if admitted { bucket.emitted += 1 } else { bucket.suppressed += 1 }
        neutral[phase] = bucket; lock.unlock()
        if let summary { emit(summary) }
        if admitted {
            var fields = fields
            if let assetID, let sample = assetSample(assetID) { fields.merge(sample) { _, new in new } }
            emit(fields)
        }
    }
    /// Fixed small set of runtime states, used by periodic admission polling.
    /// Repeated waits accumulate; the next transition/flush reports their count.
    public func state(_ category: String, value: String, fields: [String: String] = [:]) {
        let now = monotonic()
        lock.lock()
        let previous = states[category]
        if previous?.value == value {
            states[category] = (value, (previous?.suppressed ?? 0) + 1, previous?.start ?? now); lock.unlock(); return
        }
        if states.count < 8 || previous != nil { states[category] = (value, 0, now) }
        lock.unlock()
        var fields = fields; fields["phase"] = "index-state"; fields["category"] = category; fields["state"] = value
        fields["suppressed"] = String(previous?.suppressed ?? 0)
        emit(fields)
    }
    fileprivate func countReader(_ fields: [String: String]) {
        guard fields["phase"] == "photos-reader", let event = fields["event"],
              ["admission", "request", "timeout", "cancel", "terminal", "drain", "lease-returned", "lease-released"].contains(event) else { return }
        lock.lock(); readerCounts[event, default: 0] += 1; lock.unlock()
    }
    public func flushObservations(force: Bool = false) {
        let now = monotonic()
        lock.lock()
        let readers = readerCounts; readerCounts.removeAll()
        let flushWindow = force || now - windowStarted >= 30
        let timings = flushWindow ? windowTimings : [:]
        let causal = flushWindow ? causeCounts : [:]
        let lpTimings = flushWindow ? livePhotoTimings : [:], lpCounts = flushWindow ? livePhotoCounts : [:]
        if flushWindow { livePhotoTimings.removeAll(); livePhotoCounts.removeAll(); livePhotoDetails.removeAll() }
        if flushWindow { windowTimings.removeAll(); causeCounts.removeAll(); causeDetails = 0; windowStarted = now }
        let readyStates = states.filter { force || now - $0.value.start >= 30 }
        let readyNeutral = neutral.filter { force || now - $0.value.start >= 30 }
        for (key, value) in readyStates { states[key] = (value.value, 0, now) }
        for (key, value) in readyNeutral { neutral[key] = (value.start, value.emitted, 0, 0, 0) }
        lock.unlock()
        if !lpCounts.isEmpty {
            var fields = lpCounts.mapValues(String.init)
            fields["phase"] = "live-photo-summary"; fields["measurement"] = "monotonic-elapsed-wall"
            for (stage, timing) in lpTimings { fields.merge(timing.fields(stage)) { _, new in new } }
            emit(fields)
        }
        if !timings.isEmpty || !causal.isEmpty {
            var fields = ["phase": "index-window-summary", "measurement": "monotonic-elapsed-wall", "scope": "run-window"]
            for (stage, timing) in timings { fields.merge(timing.fields(stage)) { _, new in new } }
            for (source, count) in causal { fields["cause." + source] = String(count) }
            emit(fields)
        }
        if !readers.isEmpty {
            var fields = readers.mapValues(String.init); fields["phase"] = "index-reader-summary"; emit(fields)
        }
        for (category, state) in readyStates where state.suppressed > 0 {
            emit(["phase": "index-state-summary", "category": category, "state": state.value, "suppressed": String(state.suppressed)])
        }
        for (category, bucket) in readyNeutral where bucket.suppressed > 0 {
            var fields = ["phase": "index-observation-summary", "category": category, "suppressed": String(bucket.suppressed), "assetObservations": String(bucket.assets)]
            if bucket.batches > 0 { fields["batchObservations"] = String(bucket.batches) }
            emit(fields)
        }
    }
}

public final class IndexDiagnosticOperation: @unchecked Sendable {
    public let id: String
    private let context: IndexDiagnostics
    private let lock = NSLock()
    private var emitted = 0, suppressed = 0
    private var scopeFields: [String: String] = [:]
    private var comparisons: [InputDigestComparison: Int] = [:]
    private var timings: [String: DiagnosticElapsed] = [:]
    private let identityBound: Bool
    private let identity: [String: String]?
    /// A physical request owns the identity captured before admission. Its late
    /// terminal/drain/lease events never consult the shared latest-task cache.
    fileprivate init(context: IndexDiagnostics, id: String, identityBound: Bool, identity: [String: String]?) {
        self.context = context; self.id = id; self.identityBound = identityBound; self.identity = identity
    }
    public func record(_ fields: [String: String], descriptor: RepresentationDescriptor? = nil, task: RepresentationTask? = nil, assetID: String? = nil) {
        context.countReader(fields)
        var fields = fields
        if identityBound {
            guard let identity else { lock.lock(); suppressed += 1; lock.unlock(); return }
            fields.merge(identity) { _, new in new }
        } else if let descriptor = task?.descriptor ?? descriptor {
            guard let sample = context.sample(descriptor, includeIssuance: task != nil && fields["event"] != "attempt", task: task, generation: fields["generation"].flatMap(Int64.init)) else {
                lock.lock(); suppressed += 1; lock.unlock(); return
            }
            fields.merge(sample) { _, new in new }
        }
        if let assetID {
            guard let sample = context.assetSample(assetID) else { lock.lock(); suppressed += 1; lock.unlock(); return }
            fields.merge(sample) { _, new in new }
        }
        if let task, !identityBound {
            fields["issuanceHandle"] = context.handle("issuance", "\(task.indexGeneration):\(task.issuanceRevision):\(fields["descriptorHandle"] ?? "unknown")")
            fields["taskGeneration"] = String(task.indexGeneration)
            if fields["event"] == "attempt" { context.linkIssuance(fields) }
        }
        lock.lock()
        let admitted = emitted < 64
        if admitted { emitted += 1 } else { suppressed += 1 }
        lock.unlock()
        guard admitted else { return }
        fields["operation"] = id; context.emit(fields)
    }
    /// Only successful, store-proven neutral batches use this fixed bucket.
    /// Keep operation detail/finish empty so fresh operations do not add a flood.
    public func recordNeutralTransfer(assets: Int, generation: Int64, fromGeneration: Int, throughGeneration: Int) {
        context.observation(["phase": "index-live-transfer-neutral", "source": "live", "operation": id,
            "reason": assets == 0 ? "empty" : "input-unchanged", "assets": String(assets), "batches": "1",
            "readyToPending": "0", "generation": String(generation), "fromGeneration": String(fromGeneration), "throughGeneration": String(throughGeneration)])
    }
    public func bindInvalidation(_ descriptor: RepresentationDescriptor, indexGeneration: Int64,
                                 photosGeneration: Int, unknownScope: Bool = false, reason: String = "content-obligation") {
        context.bindInvalidation(descriptor, indexGeneration: indexGeneration, photosGeneration: photosGeneration,
            operation: id, unknownScope: unknownScope, reason: reason)
    }
    /// Bind the operation's inventory boundary, independently of detail sampling.
    public func bindScope(context library: LibraryContext, photosGeneration: Int, indexGeneration: Int64? = nil) {
        var fields = context.scope(library)
        fields["photosGeneration"] = String(photosGeneration)
        if let indexGeneration { fields["indexGeneration"] = String(indexGeneration) }
        lock.lock(); scopeFields = fields; lock.unlock()
    }
    /// Accepted results count before sampling. A disabled sink does not alter totals.
    public func recordComparison(_ comparison: InputDigestComparison, task: RepresentationTask) {
        lock.lock(); comparisons[comparison, default: 0] += 1; lock.unlock()
        record(["phase": "index-task", "event": "accepted", "comparison": comparison.rawValue], task: task)
        context.accepted(task)
    }
    public func measure(stage: String, seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { return }
        lock.lock()
        let key = timings[stage] != nil || timings.count < 32 ? stage : "other"
        timings[key, default: DiagnosticElapsed()].add(seconds)
        lock.unlock()
    }
    @discardableResult public func finish() -> [String: String] {
        lock.lock(); let emitted = emitted, suppressed = suppressed, comparisons = comparisons, timings = timings, scope = scopeFields; lock.unlock()
        var fields = ["phase": "index-diagnostic-summary", "operation": id, "detailed": String(emitted), "suppressed": String(suppressed)]
        fields.merge(scope) { _, new in new }
        if !comparisons.isEmpty {
            for outcome in [InputDigestComparison.sameInput, .differentInput, .missingBaseline, .incomparable, .missingInput] {
                fields["comparison." + outcome.rawValue] = String(comparisons[outcome, default: 0])
            }
        }
        if !timings.isEmpty {
            fields["measurement"] = "monotonic-elapsed-wall"
            for (stage, timing) in timings { fields.merge(timing.fields(stage)) { _, new in new } }
        }
        if emitted > 0 || suppressed > 0 || !comparisons.isEmpty || !timings.isEmpty { context.emit(fields) }
        return fields
    }
}
