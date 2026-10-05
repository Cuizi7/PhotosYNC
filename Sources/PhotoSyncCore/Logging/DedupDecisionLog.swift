import Foundation

/// Bounded diagnostics of a persisted decision. No image, vector or full metadata is encoded.
public enum DedupDecisionLog {
    public static let maxDiagnosticCandidates = 10

    public static func fields(evidence e: AdvancedEvidence, configuration c: DedupConfiguration) -> [String: String] {
        var fields = ["phase": "advanced-decision", "event": e.eventID.uuidString, "file": e.fileID.uuidString,
            "stamp.size": String(e.stamp.size), "stamp.modifiedNanoseconds": String(e.stamp.modifiedNanoseconds),
            "context": e.token.context.id.uuidString, "contextEpoch": String(e.token.context.epoch),
            "photosGeneration": String(e.token.photosGeneration), "indexGeneration": String(e.token.indexGeneration),
            "localRevision": String(e.token.localRevision), "modelSHA256": c.fingerprint.modelSHA256,
            "fingerprintVersion": e.token.fingerprintVersion, "preprocessVersion": c.fingerprint.version,
            "policyVersion": e.policyVersion, "acceptanceID": c.acceptanceID, "threshold": String(c.threshold),
            "backend": c.backend, "content": e.evaluation.content.rawValue, "action": e.evaluation.action.rawValue,
            "reason": e.evaluation.reason.rawValue, "diagnosticCount": String(min(e.diagnostics.count, maxDiagnosticCandidates)),
            "decisiveCount": String(min(e.decisiveCandidates.count, 1))]
        for (name, candidates) in [("diagnostic", Array(e.diagnostics.prefix(maxDiagnosticCandidates))),
                                    ("decisive", Array(e.decisiveCandidates.prefix(1)))] {
            for (i, candidate) in candidates.enumerated() {
                let prefix = "\(name).\(i)"
                fields["\(prefix).key"] = candidate.key
                fields["\(prefix).origin"] = candidate.origin.rawValue
                fields["\(prefix).score"] = String(candidate.score)
                fields["\(prefix).margin"] = String(candidate.score - c.threshold)
                fields["\(prefix).width"] = candidate.size.map { String($0.width) }
                fields["\(prefix).height"] = candidate.size.map { String($0.height) }
            }
        }
        if e.diagnostics.isEmpty && e.decisiveCandidates.isEmpty {
            fields["candidateAbsence"] = e.evaluation.content == .notCompared ? "notCompared" : "noCandidates"
        }
        for (name, duration) in e.timingsMS { fields["timingMS.\(name)"] = String(duration) }
        return fields
    }

    /// Event IDs and timings change on recomputation; they do not create a new diagnostic fact.
    static func signature(evidence e: AdvancedEvidence, configuration c: DedupConfiguration) -> String {
        [e.fileID.uuidString, String(e.stamp.size), String(e.stamp.modifiedNanoseconds),
         e.token.context.id.uuidString, String(e.token.context.epoch), String(e.token.photosGeneration),
         String(e.token.indexGeneration), String(e.token.localRevision), e.token.fingerprintVersion,
         e.policyVersion, c.acceptanceID, String(c.threshold)].joined(separator: "|")
    }
}
