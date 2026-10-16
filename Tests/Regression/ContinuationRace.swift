import Foundation
import SQLite3
import CoreGraphics
import ImageIO

// This executable is compiled only from a disposable copy of PhotoSyncCore by
// scripts/test-continuation-race.py.  The production module never sees its gate.

private let probeTimeoutNanoseconds: UInt64 = 3_000_000_000

private enum ProbeFailure: Error, CustomStringConvertible {
    case timeout(String)
    case assertion(String, [String: String])
    case invalidArguments(String)
    case database(String)

    var description: String {
        switch self {
        case .timeout(let name): return "Timed out waiting for \(name)."
        case .assertion(let name, let observation): return "Assertion \(name) failed: \(observation)."
        case .invalidArguments(let message), .database(let message): return message
        }
    }

    var assertionName: String? {
        if case .assertion(let name, _) = self { return name }
        return nil
    }

    var observation: [String: String] {
        if case .assertion(_, let observation) = self { return observation }
        return [:]
    }
}

private struct FixtureResult: Codable {
    let status: String
    let failureStage: String?
    let assertion: String?
    let observation: [String: String]
    let temporaryRoot: String

    enum CodingKeys: String, CodingKey {
        case status
        case failureStage = "failure_stage"
        case assertion
        case observation
        case temporaryRoot = "temporary_root"
    }
}

actor ProbeGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = false

    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}

// The disposable source copy receives this one reference immediately after its unique retry
// write.  It deliberately does not exist in the checked-in production engine.
let integrationRetryGate = ProbeGate()

// latestScan belongs to the newer scan while the older drain resumes. Observe all round
// failures synchronously in the disposable module so the older round cannot hide a failure.
final class ProbeRoundFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.lock(); count += 1; lock.unlock() }
    func value() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}
let integrationRoundFailures = ProbeRoundFailures()

private actor ProbeDirectory: DirectoryReading {
    private let markerGate: ProbeGate
    private let root: URL
    private let advancedStamp: FileStamp?
    private var rounds = 0
    private var sameStampCalls = 0
    private var expectsRootProbe = false
    func expectRootProbe() { expectsRootProbe = true }

    init(root: URL, markerGate: ProbeGate, advancedStamp: FileStamp? = nil) {
        self.advancedStamp = advancedStamp
        self.root = root
        self.markerGate = markerGate
    }

    func entries(in directory: URL) async throws -> [DirectoryEntry] {
        // Child failures now verify root availability before retry persistence.
        // That bounded probe is healthy I/O, not another logical scan round.
        if expectsRootProbe {
            expectsRootProbe = false
            return [DirectoryEntry(url: root.appendingPathComponent("same.jpg"), isDirectory: false, stamp: nil)]
        }
        rounds += 1
        guard rounds <= 2 else {
            throw NSError(domain: "ContinuationRace", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "probe requested an unexpected third directory scan"
            ])
        }
        let same = DirectoryEntry(url: root.appendingPathComponent("same.jpg"), isDirectory: false, stamp: nil)
        if rounds == 1 { return [same] }
        let marker = DirectoryEntry(url: root.appendingPathComponent("marker.jpg"), isDirectory: false, stamp: nil)
        return [same, marker]
    }

    func stamp(of file: URL) async throws -> FileStamp {
        switch file.lastPathComponent {
        case "same.jpg":
            sameStampCalls += 1
            if let advancedStamp, sameStampCalls <= 2 { return advancedStamp }
            switch sameStampCalls {
            case 1:
                return FileStamp(size: 1, modifiedNanoseconds: 1)
            case 2:
                expectsRootProbe = true
                throw NSError(domain: "ContinuationRace", code: 15, userInfo: [
                    NSLocalizedDescriptionKey: "probe submission stamp failed"
                ])
            case 3:
                return FileStamp(size: 2, modifiedNanoseconds: 2)
            default:
                throw NSError(domain: "ContinuationRace", code: 11, userInfo: [
                    NSLocalizedDescriptionKey: "probe requested an unexpected same-file stamp"
                ])
            }
        case "marker.jpg":
            // The second scan reaches this only after it persisted sourceChanged and resolved
            // that row's issue.  Hold it so observation happens before the intentional failure.
            await markerGate.wait()
            expectsRootProbe = true
            throw NSError(domain: "ContinuationRace", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "probe marker failure after observation"
            ])
        default:
            throw NSError(domain: "ContinuationRace", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "probe requested an unknown file"
            ])
        }
    }
}

private struct ProbeMetadata: MetadataReading {
    func read(url: URL, filename: String) async throws -> MediaMetadata {
        MediaMetadata(
            filename: filename,
            kind: .image,
            captureSecond: nil,
            rawCaptureTime: nil,
            make: nil,
            model: nil,
            width: nil,
            height: nil,
            duration: nil
        )
    }
}

private actor ProbePhotos: PhotosIndexGateway {
    nonisolated let context = LibraryContext(id: UUID(), epoch: 1)
    nonisolated func changes() -> AsyncStream<PhotosIndexChange> { AsyncStream { _ in } }
    func representationCatalog(offset: Int, limit: Int, expectedGeneration: Int) async throws -> RepresentationPage {
        .init(context: context, generation: 0, descriptors: [], nextOffset: nil)
    }
    func readRepresentation(_ descriptor: RepresentationDescriptor) async throws -> LoadedRepresentation {
        throw PhotoKitGatewayError.libraryUnavailable
    }
    private(set) var createCount = 0

    func loadCandidates() async throws -> [MatchCandidate] { [] }
    func candidateSnapshot() async throws -> PhotosCandidateSnapshot {
        PhotosCandidateSnapshot(generation: 0, candidates: [])
    }
    func reconcile(placeholder: String?) async throws -> ImportEvidence { .unknown }

    func create(
        fileURL: URL,
        kind: MediaKind,
        expectedGeneration: Int,
        onPlaceholder: @escaping @Sendable (String) throws -> Void
    ) async throws -> String {
        createCount += 1
        throw NSError(domain: "ContinuationRace", code: 14, userInfo: [
            NSLocalizedDescriptionKey: "the continuation probe must never submit to Photos"
        ])
    }
}

private actor ThrowingProbeModel: ImageFingerprinting {
    private let directory: ProbeDirectory
    init(directory: ProbeDirectory) { self.directory = directory }
    private(set) var calls = 0
    func fingerprint(image: CGImage, orientation: CGImagePropertyOrientation) async throws -> Fingerprint {
        calls += 1
        await directory.expectRootProbe()
        throw NSError(domain: "ContinuationRace", code: 16, userInfo: [
            NSLocalizedDescriptionKey: "probe advanced preparation failed"
        ])
    }
}

private func writeProbeImage(_ url: URL) throws {
    guard let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
        throw ProbeFailure.invalidArguments("Unable to create synthetic probe image.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw ProbeFailure.invalidArguments("Unable to write synthetic probe image.")
    }
}

private final class NotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sourceEvents: [String] = []
    private var sourceIssueEvents: [String] = []
    private var blockingIssues: [String] = []

    func recordSource(_ sourceID: UUID, recovered: Bool) {
        lock.lock()
        sourceEvents.append("\(sourceID.uuidString):\(recovered)")
        lock.unlock()
    }

    func recordSourceIssue(_ sourceID: UUID, recovered: Bool, issue: SourceIssue?) {
        lock.lock()
        sourceIssueEvents.append("\(sourceID.uuidString):\(recovered):\(issue?.summary ?? "nil")")
        lock.unlock()
    }

    func recordBlocking(_ message: String) {
        lock.lock()
        blockingIssues.append(message)
        lock.unlock()
    }

    func counts() -> (source: Int, sourceIssue: Int, blocking: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (sourceEvents.count, sourceIssueEvents.count, blockingIssues.count)
    }
}

private struct RetryFields {
    let lastError: String?
    let definitelyNotCommitted: Int
    let skipReason: String?
}

private func retryFields(databaseURL: URL, fileID: UUID) throws -> RetryFields {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        throw ProbeFailure.database("Unable to open the probe SQLite database for observation.")
    }
    defer { sqlite3_close(database) }

    let sql = "SELECT last_error, definitely_not_committed, skip_reason FROM file_record WHERE id = '\(fileID.uuidString)'"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        throw ProbeFailure.database("Unable to query the probe file record.")
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw ProbeFailure.database("The probe file record disappeared.")
    }
    let lastError = sqlite3_column_text(statement, 0).map { String(cString: $0) }
    let skipReason = sqlite3_column_text(statement, 2).map { String(cString: $0) }
    return RetryFields(lastError: lastError, definitelyNotCommitted: Int(sqlite3_column_int(statement, 1)), skipReason: skipReason)
}

private func scanFailureCount(databaseURL: URL) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        throw ProbeFailure.database("Unable to open the probe scan database for observation.")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT COALESCE(SUM(failed), 0) FROM scan_run", -1, &statement, nil) == SQLITE_OK else {
        throw ProbeFailure.database("Unable to query probe scan failures.")
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw ProbeFailure.database("Unable to read probe scan failures.")
    }
    return Int(sqlite3_column_int(statement, 0))
}

private func waitFor(_ label: String, condition: @escaping @Sendable () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(Double(probeTimeoutNanoseconds) / 1_000_000_000)
    while !(await condition()) {
        guard Date() < deadline else { throw ProbeFailure.timeout(label) }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

private func require(_ condition: Bool, name: String, observation: [String: String]) throws {
    guard condition else { throw ProbeFailure.assertion(name, observation) }
}

private func readEvidenceDirectory() throws -> URL {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 4, arguments[0] == "--evidence-dir", arguments[2] == "--scenario",
          ["stamp", "advanced-preparation"].contains(arguments[3]) else {
        throw ProbeFailure.invalidArguments("Usage: ContinuationRace --evidence-dir ABSOLUTE_PATH --scenario stamp|advanced-preparation")
    }
    let rawPath = arguments[1]
    guard rawPath.hasPrefix("/") else {
        throw ProbeFailure.invalidArguments("The evidence directory must be absolute.")
    }
    let result = URL(fileURLWithPath: rawPath)
    try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
    return result
}

private func writeResult(_ result: FixtureResult, to directory: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(result).write(to: directory.appendingPathComponent("fixture.json"), options: .atomic)
}

private func runProbe(temporaryRoot: URL) async throws -> [String: String] {
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let databaseURL = temporaryRoot.appendingPathComponent("continuation.sqlite")
    let store = try SyncStore(url: databaseURL)
    let sourceID = try await store.registerSource(url: temporaryRoot)
    let markerGate = ProbeGate()
    let isAdvanced = CommandLine.arguments.last == "advanced-preparation"
    let executor = ReadExecutor(maxConcurrentOperations: 2)
    var advancedStamp: FileStamp?
    if isAdvanced {
        let imageURL = temporaryRoot.appendingPathComponent("same.jpg")
        try writeProbeImage(imageURL)
        advancedStamp = try await DirectoryReader(sourceID: sourceID, executor: executor).stamp(of: imageURL)
    }
    let directory = ProbeDirectory(root: temporaryRoot, markerGate: markerGate, advancedStamp: advancedStamp)
    let photos = ProbePhotos()
    let model = ThrowingProbeModel(directory: directory)
    var coordinator: PhotosIndexCoordinator?
    var service: AdvancedDedupService?
    if isAdvanced {
        let profileURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("integration-profile.json")
        let configuration = try JSONDecoder().decode(DedupConfiguration.self, from: Data(contentsOf: profileURL))
        let current = PhotosIndexCoordinator(store: store, photos: photos, fingerprinter: model, configuration: configuration)
        try await current.reconcile()
        await current.processDueWork(now: Date())
        coordinator = current
        service = AdvancedDedupService(store: store, photos: photos, coordinator: current, fingerprinter: model,
            configuration: configuration, executor: executor, budget: ImageWorkBudget(limits: configuration.resources))
    }
    let notifications = NotificationRecorder()
    let engine = SyncEngine(
        store: store,
        photos: photos,
        directory: { _ in directory },
        metadata: { _ in ProbeMetadata() },
        advancedDedup: service, indexCoordinator: coordinator, requiresAdvancedDedup: isAdvanced,
        notify: { source, recovered in notifications.recordSource(source, recovered: recovered) },
        notifyIssue: { notifications.recordBlocking($0) },
        notifySourceIssue: { source, recovered, issue in
            notifications.recordSourceIssue(source, recovered: recovered, issue: issue)
        }
    )

    let first = Task { await engine.scan(sourceIDs: [sourceID]) }
    var second: Task<Void, Never>?
    do {
        try await waitFor("the persisted retry gate") { await integrationRetryGate.entered }

        if isAdvanced {
            let calls = await model.calls
            try require(calls == 1, name: "advanced_model_failure_reached", observation: ["model_calls": String(calls)])
        }
        second = Task { await engine.scan(sourceIDs: [sourceID]) }
        try await waitFor("the sourceChanged scan marker") { await markerGate.entered }

        let changed = try await store.file(sourceID: sourceID, relativePath: "same.jpg")
        let changedFields = try retryFields(databaseURL: databaseURL, fileID: try changedID(changed))
        let before = await engine.snapshot()
        let beforeNotifications = notifications.counts()
        let beforeCreates = await photos.createCount
        let beforeObservation = observation(
            record: changed,
            retryFields: changedFields,
            snapshot: before,
            notifications: beforeNotifications,
            creates: beforeCreates,
            scanFailures: try scanFailureCount(databaseURL: databaseURL)
        )
        try require(changed?.state == .skipped, name: "source_changed_state_before_marker", observation: beforeObservation)
        try require(changed?.file.stamp == FileStamp(size: 2, modifiedNanoseconds: 2), name: "source_changed_stamp_before_marker", observation: beforeObservation)
        try require(changed?.retryCount == 1 && changed?.nextRetryAt != nil, name: "source_changed_retry_before_marker", observation: beforeObservation)
        try require(changedFields.lastError == (isAdvanced ? "probe advanced preparation failed" : "probe submission stamp failed"), name: "source_changed_last_error_before_marker", observation: beforeObservation)
        try require(changedFields.definitelyNotCommitted == 1 && changedFields.skipReason == SkipReason.sourceChanged.rawValue,
                    name: "source_changed_retry_fields_before_marker", observation: beforeObservation)
        try require(integrationRoundFailures.value() == 0 && before.waitingSources.isEmpty && before.blockingError == nil && before.latestScan.failed == 0 &&
                    before.sourceFileIssueCounts.isEmpty && before.deferredSources.isEmpty && beforeNotifications.source == 0 &&
                    beforeNotifications.sourceIssue == 0 && beforeNotifications.blocking == 0 && beforeCreates == 0 &&
                    (try scanFailureCount(databaseURL: databaseURL)) == 0,
                    name: "pre_marker_clean_observation", observation: beforeObservation)

        await integrationRetryGate.release()
        await first.value

        let after = await engine.snapshot()
        let afterRecord = try await store.file(sourceID: sourceID, relativePath: "same.jpg")
        let afterFields = try retryFields(databaseURL: databaseURL, fileID: try changedID(afterRecord))
        let afterNotifications = notifications.counts()
        let afterCreates = await photos.createCount
        let afterObservation = observation(
            record: afterRecord,
            retryFields: afterFields,
            snapshot: after,
            notifications: afterNotifications,
            creates: afterCreates,
            scanFailures: try scanFailureCount(databaseURL: databaseURL)
        )

        // In the intentionally mutated copy this is the exact old regression: the already
        // sourceChanged/skipped row becomes waiting when the first drain resumes.
        try require(afterRecord?.state == .skipped && afterRecord?.file.stamp == changed?.file.stamp &&
                    afterRecord?.retryCount == changed?.retryCount && afterRecord?.successID == nil &&
                    afterFields.skipReason == SkipReason.sourceChanged.rawValue, name: "post_resume_row_remains_skipped", observation: afterObservation)
        try require(after.waitingSources.isEmpty, name: "post_resume_waiting_sources", observation: afterObservation)
        try require(integrationRoundFailures.value() == 0 && after.blockingError == nil && after.latestScan.failed == 0 && after.sourceFileIssueCounts.isEmpty &&
                    after.deferredSources.isEmpty && afterNotifications.source == 0 && afterNotifications.sourceIssue == 0 &&
                    afterNotifications.blocking == 0 && afterCreates == 0 &&
                    (try scanFailureCount(databaseURL: databaseURL)) == 0,
                    name: "post_resume_no_spurious_failure", observation: afterObservation)

        await markerGate.release()
        if let second { await second.value }
        var finalObservation = afterObservation
        finalObservation["marker_released"] = "true"
        finalObservation["scenario"] = isAdvanced ? "advanced-preparation" : "stamp"
        finalObservation["model_calls"] = String(await model.calls)
        return finalObservation
    } catch {
        await integrationRetryGate.release()
        await markerGate.release()
        await first.value
        if let second { await second.value }
        throw error
    }
}

private func changedID(_ record: StoredFile?) throws -> UUID {
    guard let record else {
        throw ProbeFailure.assertion("source_changed_row_exists", ["row_state": "nil"])
    }
    return record.id
}

private func observation(
    record: StoredFile?,
    retryFields: RetryFields,
    snapshot: EngineSnapshot,
    notifications: (source: Int, sourceIssue: Int, blocking: Int),
    creates: Int,
    scanFailures: Int
) -> [String: String] {
    [
        "row_state": record?.state.rawValue ?? "nil",
        "stamp": record.map { "\($0.file.stamp.size):\($0.file.stamp.modifiedNanoseconds)" } ?? "nil",
        "retry_count": record.map { String($0.retryCount) } ?? "nil",
        "next_retry": record?.nextRetryAt == nil ? "nil" : "set",
        "last_error": retryFields.lastError ?? "nil",
        "definitely_not_committed": String(retryFields.definitelyNotCommitted),
        "skip_reason": retryFields.skipReason ?? "nil",
        "waiting_sources": String(snapshot.waitingSources.count),
        "blocking_error": snapshot.blockingError ?? "nil",
        "round_failed": String(snapshot.latestScan.failed),
        "all_round_failures": String(integrationRoundFailures.value()),
        "file_issues": String(snapshot.sourceFileIssueCounts.count),
        "deferred_sources": String(snapshot.deferredSources.count),
        "source_notifications": String(notifications.source),
        "source_issue_notifications": String(notifications.sourceIssue),
        "blocking_notifications": String(notifications.blocking),
        "photos_creates": String(creates),
        "scan_failures": String(scanFailures)
    ]
}

@main
private struct ContinuationRace {
    static func main() async {
        let temporaryRoot = URL(fileURLWithPath: "/tmp").appendingPathComponent("photosync-continuation-race-\(UUID().uuidString)")
        do {
            let evidenceDirectory = try readEvidenceDirectory()
            let observation = try await runProbe(temporaryRoot: temporaryRoot)
            try writeResult(
                FixtureResult(status: "passed", failureStage: nil, assertion: nil, observation: observation,
                              temporaryRoot: temporaryRoot.path),
                to: evidenceDirectory
            )
            print("CONTINUATION_RACE_PASS \(observation)")
        } catch {
            let evidenceDirectory = (try? readEvidenceDirectory())
            let failure = error as? ProbeFailure
            if let evidenceDirectory {
                try? writeResult(
                    FixtureResult(status: "failed", failureStage: failure?.assertionName == nil ? "runtime" : "assertion",
                                  assertion: failure?.assertionName, observation: failure?.observation ?? [:],
                                  temporaryRoot: temporaryRoot.path),
                    to: evidenceDirectory
                )
            }
            fputs("CONTINUATION_RACE_FAIL \(error)\n", stderr)
            exit(1)
        }
    }
}
