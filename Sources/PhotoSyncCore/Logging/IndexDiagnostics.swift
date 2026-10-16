import CryptoKit
import Foundation

/// Best-effort causal facts only. No decisions, durable identity or history coverage
/// are derived from these run-local handles. Sinks run after diagnostic locks unlock.
public final class IndexDiagnostics: @unchecked Sendable {
    public let run = UUID().uuidString
    private let secret = SymmetricKey(size: .bits256)
    private let sink: @Sendable ([String: String]) -> Void
    private let lock = NSLock()
    private var samples = Set<String>()
    private var sequence: UInt64 = 0
    private var issuances: [String: (descriptor: String, issuance: String)] = [:]
    private var readerCounts: [String: Int] = [:]
    private var states: [String: (value: String, suppressed: Int, start: TimeInterval)] = [:]
    private var neutral: [String: (start: TimeInterval, emitted: Int, suppressed: Int, assets: Int, batches: Int)] = [:]
    private let monotonic: @Sendable () -> TimeInterval

    public init(sink: @escaping @Sendable ([String: String]) -> Void,
                monotonic: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.sink = sink; self.monotonic = monotonic
    }
    public func handle(_ category: String, _ value: String) -> String {
        let bytes = Data((category + ":" + value).utf8)
        return category + "-" + HMAC<SHA256>.authenticationCode(for: bytes, using: secret).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    public func tokenHandle(_ value: Data) -> String { handle("range", value.base64EncodedString()) }
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
    fileprivate func sample(_ descriptor: RepresentationDescriptor) -> [String: String]? {
        guard var fields = assetSample(descriptor.key.assetID) else { return nil }
        // Encode the full descriptor, including unknown revision reliability. Never
        // retain a per-library descriptor map just to produce diagnostic handles.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(descriptor)) ?? Data()
        fields["descriptorHandle"] = handle("descriptor", encoded.base64EncodedString())
        fields["representation"] = descriptor.key.kind.rawValue
        let key = fields["assetHandle"]! + ":" + descriptor.key.kind.rawValue
        lock.lock(); let issuance = issuances[key]; lock.unlock()
        if issuance?.descriptor == fields["descriptorHandle"] { fields["issuanceHandle"] = issuance?.issuance }
        return fields
    }
    fileprivate func linkIssuance(_ fields: [String: String]) {
        guard let asset = fields["assetHandle"], let kind = fields["representation"],
              let descriptor = fields["descriptorHandle"], let issuance = fields["issuanceHandle"] else { return }
        lock.lock(); issuances[asset + ":" + kind] = (descriptor, issuance); lock.unlock()
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
        let readyStates = states.filter { force || now - $0.value.start >= 30 }
        let readyNeutral = neutral.filter { force || now - $0.value.start >= 30 }
        for (key, value) in readyStates { states[key] = (value.value, 0, now) }
        for (key, value) in readyNeutral { neutral[key] = (value.start, value.emitted, 0, 0, 0) }
        lock.unlock()
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
            guard let sample = context.sample(descriptor) else {
                lock.lock(); suppressed += 1; lock.unlock(); return
            }
            fields.merge(sample) { _, new in new }
        }
        if let assetID {
            guard let sample = context.assetSample(assetID) else { lock.lock(); suppressed += 1; lock.unlock(); return }
            fields.merge(sample) { _, new in new }
        }
        lock.lock()
        let admitted = emitted < 64
        if admitted { emitted += 1 } else { suppressed += 1 }
        lock.unlock()
        guard admitted else { return }
        if let task, !identityBound {
            fields["issuanceHandle"] = context.handle("issuance", "\(task.indexGeneration):\(task.issuanceRevision):\(fields["descriptorHandle"] ?? "unknown")")
            fields["taskGeneration"] = String(task.indexGeneration)
            if fields["event"] == "attempt" { context.linkIssuance(fields) }
        }
        fields["operation"] = id; context.emit(fields)
    }
    /// Only successful, store-proven neutral batches use this fixed bucket.
    /// Keep operation detail/finish empty so fresh operations do not add a flood.
    public func recordNeutralTransfer(assets: Int, generation: Int64, fromGeneration: Int, throughGeneration: Int) {
        context.observation(["phase": "index-live-transfer-neutral", "source": "live", "operation": id,
            "reason": assets == 0 ? "empty" : "input-unchanged", "assets": String(assets), "batches": "1",
            "readyToPending": "0", "generation": String(generation), "fromGeneration": String(fromGeneration), "throughGeneration": String(throughGeneration)])
    }
    public func finish() {
        lock.lock(); let emitted = emitted, suppressed = suppressed; lock.unlock()
        guard emitted > 0 || suppressed > 0 else { return }
        context.emit(["phase": "index-diagnostic-summary", "operation": id, "detailed": String(emitted), "suppressed": String(suppressed)])
    }
}
