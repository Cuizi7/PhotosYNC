import CoreGraphics
import CoreML
import CryptoKit
import Darwin
import Foundation
import ImageIO

struct ProbeError: Error, CustomStringConvertible {
    let description: String
}

struct ApprovedProtocolBinding: Decodable {
    let bindingVersion: Int
    let protocolSHA256: String
    let maxDecodedBytes: Int64
    let maxAbsError: Double
    let minCosine: Double
}

func parseArguments() throws -> (command: String, values: [String: String]) {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first,
          ["fingerprint", "compare-tensors", "score-batch", "search-benchmark",
           "combined-benchmark", "validate-profile"].contains(command) else {
        throw ProbeError(description: "unknown probe command")
    }
    let required: [String]
    switch command {
    case "fingerprint": required = ["--profile", "--model", "--output-dir", "--input-list"]
    case "compare-tensors": required = ["--profile", "--model", "--output-dir", "--tensor-list"]
    case "score-batch": required = ["--profile", "--input", "--output-dir"]
    case "combined-benchmark": required = ["--profile", "--model", "--vectors", "--input-list",
                                            "--asset-count", "--edited-fraction", "--output-dir"]
    case "validate-profile": required = ["--profile", "--output-dir"]
    default: required = ["--profile", "--vectors", "--asset-count", "--edited-fraction", "--output-dir"]
    }
    let allowed = Set(required + ["--approved-protocol-json"])
    guard (args.count - 1).isMultiple(of: 2) else {
        throw ProbeError(description: "unpaired probe option")
    }
    var values = [String: String]()
    for index in stride(from: 1, to: args.count, by: 2) {
        let flag = args[index]
        guard allowed.contains(flag), values[flag] == nil else {
            throw ProbeError(description: "unknown or duplicate probe option \(flag)")
        }
        values[flag] = args[index + 1]
    }
    guard (required + ["--approved-protocol-json"])
        .allSatisfy({ values[$0] != nil }) else {
        throw ProbeError(description: "missing required probe option")
    }
    return (command, values)
}

func sha256(_ url: URL) throws -> String {
    let stream = InputStream(url: url)!
    stream.open(); defer { stream.close() }
    var hash = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? ProbeError(description: "input read failed") }
        if count == 0 { break }
        hash.update(data: Data(buffer.prefix(count)))
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

func run() async throws {
    let parsed = try parseArguments()
    let args = parsed.values
    let profile = URL(fileURLWithPath: args["--profile"]!)
    let output = URL(fileURLWithPath: args["--output-dir"]!)
    let approved = try JSONDecoder().decode(ApprovedProtocolBinding.self,
                                            from: Data(args["--approved-protocol-json"]!.utf8))
    let protocolSHA = approved.protocolSHA256
    let maxDecodedBytes = approved.maxDecodedBytes
    guard approved.bindingVersion == 1,
          protocolSHA.count == 64, protocolSHA.allSatisfy(\.isHexDigit),
          maxDecodedBytes > 0, approved.maxAbsError.isFinite, approved.maxAbsError > 0,
          approved.minCosine.isFinite, approved.minCosine > 0, approved.minCosine <= 1 else {
        throw ProbeError(description: "invalid approved protocol binding")
    }
    guard !FileManager.default.fileExists(atPath: output.path) else {
        throw ProbeError(description: "output directory already exists")
    }
    let profileData = try Data(contentsOf: profile)
    let raw = try JSONSerialization.jsonObject(with: profileData) as? [String: Any]
    guard let raw = raw else { throw ProbeError(description: "invalid profile") }
    if let resources = raw["resources"] as? [String: Any] {
        guard (resources["inferenceConcurrency"] as? Int) == 1,
              (resources["batchSize"] as? Int) == 1,
              (resources["decodeConcurrency"] as? Int) == 1,
              (resources["maxDecodedBytes"] as? Int64) == maxDecodedBytes else {
            throw ProbeError(description: "profile resource limits conflict with approved protocol")
        }
    }
    if ["score-batch", "search-benchmark", "combined-benchmark", "validate-profile"].contains(parsed.command) {
        let configuration = try JSONDecoder().decode(DedupConfiguration.self, from: profileData)
        guard configuration.backend == "exact-f32-v1",
              (parsed.command == "validate-profile" || configuration.acceptanceID == "research:\(protocolSHA)"),
              configuration.resources.maxDecodedBytes == maxDecodedBytes else {
            throw ProbeError(description: "research profile binding or backend mismatch")
        }
        if parsed.command == "validate-profile" {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            try writeJSON(["profileSHA256": try sha256(profile),
                           "acceptanceID": configuration.acceptanceID],
                          at: output.appendingPathComponent("validated-profile.json"))
            return
        }
        if parsed.command == "score-batch" {
            try runScoreBatch(input: URL(fileURLWithPath: args["--input"]!), output: output,
                              profile: profile, configuration: configuration, protocolSHA: protocolSHA)
        } else {
            try await runSearchBenchmark(vectors: URL(fileURLWithPath: args["--vectors"]!),
                assetCount: args["--asset-count"]!, editedFraction: args["--edited-fraction"]!,
                output: output, configuration: configuration, protocolSHA: protocolSHA,
                model: args["--model"].map { URL(fileURLWithPath: $0) },
                inputList: args["--input-list"].map { URL(fileURLWithPath: $0) },
                maxDecodedBytes: maxDecodedBytes, profileSHA: try sha256(profile))
        }
        return
    }
    let model = URL(fileURLWithPath: args["--model"]!)
    let selected = (raw["fingerprint"] as? [String: Any]) ?? raw
    let configuration = try JSONDecoder().decode(FingerprintConfiguration.self,
                                                   from: JSONSerialization.data(withJSONObject: selected))
    let fingerprinter = try CoreMLFingerprinter(modelURL: model, configuration: configuration)
    if parsed.command == "compare-tensors" {
        let maxError = approved.maxAbsError
        let minCosine = approved.minCosine
        let entries = try JSONDecoder().decode([TensorPair].self,
                                                from: Data(contentsOf: URL(fileURLWithPath: args["--tensor-list"]!)))
        guard !entries.isEmpty else { throw ProbeError(description: "empty tensor list") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        var comparisons = [[String: Any]]()
        for entry in entries {
            let input = URL(fileURLWithPath: entry.input)
            let reference = URL(fileURLWithPath: entry.reference)
            let bytes = try Data(contentsOf: input)
            let side = configuration.inputSide
            guard bytes.count == side * side * 3 * 4 else { throw ProbeError(description: "invalid tensor bytes") }
            let tensor = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
            _ = bytes.withUnsafeBytes { pointer in memcpy(tensor.dataPointer, pointer.baseAddress!, bytes.count) }
            let predicted = try await fingerprinter.fingerprintPrepared(tensor)
            let goldBytes = try Data(contentsOf: reference)
            guard goldBytes.count == 1024 * 4 else { throw ProbeError(description: "invalid reference bytes") }
            let goldValues: [Float] = goldBytes.withUnsafeBytes { pointer in
                Array(pointer.bindMemory(to: Float.self))
            }
            let gold = try Fingerprint(version: configuration.version, values: goldValues)
            let dot = zip(predicted.values, gold.values).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
            let difference = zip(predicted.values, gold.values)
                .map { abs(Double($0.0) - Double($0.1)) }.max()!
            let passed = dot >= minCosine && difference <= maxError
            comparisons.append(["inputSHA256": try sha256(input), "referenceSHA256": try sha256(reference),
                                "cosine": dot, "maxAbsError": difference, "pass": passed])
        }
        let pass = comparisons.allSatisfy { $0["pass"] as? Bool == true }
        let report: [String: Any] = ["protocolSHA256": protocolSHA,
                                      "modelSHA256": configuration.modelSHA256,
                                      "computeUnits": "cpuOnly",
                                      "resourcePolicy": "approved-protocol",
                                      "fingerprintVersion": configuration.version,
                                      "maxAbsErrorLimit": maxError, "minCosineLimit": minCosine,
                                      "comparisons": comparisons, "pass": pass]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("conversion-comparison.json"), options: .atomic)
        guard pass else { throw ProbeError(description: "conversion comparison failed") }
        print("conversion comparison passed for \(comparisons.count) tensor(s)")
        return
    }
    let list = URL(fileURLWithPath: args["--input-list"]!)
    let paths = try JSONDecoder().decode([String].self, from: Data(contentsOf: list))
    guard !paths.isEmpty else { throw ProbeError(description: "empty input list") }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    var records = [[String: Any]]()
    for path in paths {
        do {
            let url = URL(fileURLWithPath: path)
            let inputHash = try sha256(url)
            let start = CFAbsoluteTimeGetCurrent()
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0 else { throw ProbeError(description: "image decode failed: \(path)") }
            let long = max(width, height)
            let short = min(width, height)
            let decodedSide = Int(sqrt(Double(maxDecodedBytes) / (4 * Double(short) / Double(long))))
            let bounded = min(4096, long, decodedSide)
            guard bounded >= 1 else { throw ProbeError(description: "decode budget too small") }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: bounded,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceShouldCacheImmediately: false,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw ProbeError(description: "image decode failed: \(path)")
            }
            let decoded = CFAbsoluteTimeGetCurrent()
            let orientationRaw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
            guard let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) else {
                throw ProbeError(description: "invalid EXIF orientation: \(path)")
            }
            let tensor = try ImagePreprocessor.prepare(image: image, orientation: orientation,
                                                       configuration: configuration)
            let prepared = CFAbsoluteTimeGetCurrent()
            let fingerprint = try await fingerprinter.fingerprintPrepared(tensor)
            let inferred = CFAbsoluteTimeGetCurrent()
            let vectorFile = output.appendingPathComponent("\(inputHash).f32")
            if !FileManager.default.fileExists(atPath: vectorFile.path) {
                try fingerprint.littleEndianFloat32.write(to: vectorFile, options: .atomic)
            }
            records.append([
                "inputSHA256": inputHash, "fingerprintVersion": fingerprint.version,
                "vectorFile": vectorFile.lastPathComponent,
                "decodeMS": (decoded - start) * 1000,
                "preprocessMS": (prepared - decoded) * 1000,
                "inferenceMS": (inferred - prepared) * 1000,
            ])
        }
    }
    let report: [String: Any] = ["protocolSHA256": protocolSHA, "modelSHA256": configuration.modelSHA256,
                                  "computeUnits": "cpuOnly",
                                  "resourcePolicy": "approved-protocol",
                                  "fingerprintVersion": configuration.version, "records": records]
    let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try bytes.write(to: output.appendingPathComponent("fingerprints.json"), options: .atomic)
    print("fingerprinted \(records.count) explicit input(s)")
}

struct TensorPair: Decodable {
    let input: String
    let reference: String
}

private struct BatchInput: Decodable {
    let queries: [BatchQuery]
}

private struct BatchQuery: Decodable {
    let id: String
    let vector: String
    let vectorSHA256: String
    let size: PixelSize?
    let candidates: [BatchCandidate]
}

private struct BatchCandidate: Decodable {
    let key: String
    let origin: CandidateOrigin
    let vector: String
    let vectorSHA256: String
    let size: PixelSize?
}

private func readVector(path: String, expectedSHA: String, version: String) throws -> Fingerprint {
    let url = URL(fileURLWithPath: path)
    guard try sha256(url) == expectedSHA else { throw ProbeError(description: "vector SHA256 mismatch: \(path)") }
    let bytes = try Data(contentsOf: url)
    guard bytes.count == 4096 else { throw ProbeError(description: "invalid Float32 vector length") }
    let values: [Float] = bytes.withUnsafeBytes { raw in
        let source = raw.bindMemory(to: UInt8.self)
        return (0..<1024).map { index in
            let offset = index * 4
            let bits = UInt32(source[offset]) | UInt32(source[offset + 1]) << 8 |
                       UInt32(source[offset + 2]) << 16 | UInt32(source[offset + 3]) << 24
            return Float(bitPattern: bits)
        }
    }
    return try Fingerprint(version: version, values: values)
}

private func writeJSON(_ report: [String: Any], at url: URL) throws {
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: url, options: .atomic)
}

private func runScoreBatch(input: URL, output: URL, profile: URL, configuration: DedupConfiguration,
                           protocolSHA: String) throws {
    let batch = try JSONDecoder().decode(BatchInput.self, from: Data(contentsOf: input))
    guard !batch.queries.isEmpty, Set(batch.queries.map(\.id)).count == batch.queries.count else {
        throw ProbeError(description: "empty or duplicate query IDs")
    }
    var reports = [[String: Any]]()
    for query in batch.queries {
        let fingerprint = try readVector(path: query.vector, expectedSHA: query.vectorSHA256,
                                         version: configuration.fingerprint.version)
        let entries = try query.candidates.map { candidate in
            VectorEntry(key: candidate.key, origin: candidate.origin,
                fingerprint: try readVector(path: candidate.vector,
                    expectedSHA: candidate.vectorSHA256, version: configuration.fingerprint.version),
                size: candidate.size)
        }
        // Score the whole declared gallery, including below-threshold candidates for diagnostics.
        let allScores = try ExactVectorIndex.score(query: fingerprint, entries: entries,
                                                    minimumScore: -1)
        let candidateHashes = Dictionary(uniqueKeysWithValues:
            query.candidates.map { ($0.key, $0.vectorSHA256) })
        let evaluation = try AdvancedDuplicatePolicy.evaluate(sourceSize: query.size,
            candidates: allScores, configuration: configuration)
        reports.append([
            "id": query.id,
            "queryVectorSHA256": query.vectorSHA256,
            "candidates": allScores.map { item in
                ["key": item.key, "origin": item.origin.rawValue, "score": item.score,
                 "vectorSHA256": candidateHashes[item.key]!] as [String: Any]
            },
            "content": evaluation.content.rawValue,
            "action": evaluation.action.rawValue,
            "reason": evaluation.reason.rawValue,
            "matchedKeys": evaluation.matchedKeys,
            "coveringKeys": evaluation.coveringKeys,
        ])
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    try writeJSON(["protocolSHA256": protocolSHA,
                   "profileSHA256": try sha256(profile),
                   "fingerprintVersion": configuration.fingerprint.version,
                   "policyVersion": configuration.policyVersion,
                   "threshold": configuration.threshold,
                   "backend": configuration.backend,
                   "batchSHA256": try sha256(input), "queries": reports],
                  at: output.appendingPathComponent("query-results.json"))
    print("scored \(reports.count) complete query gallery views")
}

private struct FingerprintManifest: Decodable {
    let protocolSHA256: String
    let modelSHA256: String
    let fingerprintVersion: String
    let records: [FingerprintRecord]
}

private struct FingerprintRecord: Decodable {
    let vectorFile: String
}

private func percentile(_ samples: [Double], _ percentile: Double) -> Double {
    let sorted = samples.sorted()
    return sorted[max(0, Int(ceil(Double(sorted.count) * percentile)) - 1)]
}

private func fingerprintLocalImage(_ url: URL, fingerprinter: CoreMLFingerprinter,
                                   configuration: FingerprintConfiguration,
                                   maxDecodedBytes: Int64) async throws -> (Fingerprint, [String: Double]) {
    let start = CFAbsoluteTimeGetCurrent()
    guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0 else {
        throw ProbeError(description: "benchmark image decode failed")
    }
    let long = max(width, height), short = min(width, height)
    let bound = Int(sqrt(Double(maxDecodedBytes) / (4 * Double(short) / Double(long))))
    guard bound > 0,
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: min(4096, long, bound),
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: false,
          ] as CFDictionary) else {
        throw ProbeError(description: "benchmark image decode budget failed")
    }
    let decoded = CFAbsoluteTimeGetCurrent()
    let orientationRaw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
    guard let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) else {
        throw ProbeError(description: "benchmark orientation invalid")
    }
    let tensor = try ImagePreprocessor.prepare(image: image, orientation: orientation,
                                               configuration: configuration)
    let prepared = CFAbsoluteTimeGetCurrent()
    let fingerprint = try await fingerprinter.fingerprintPrepared(tensor)
    let inferred = CFAbsoluteTimeGetCurrent()
    return (fingerprint, ["decodeMS": (decoded - start) * 1000,
                          "preprocessMS": (prepared - decoded) * 1000,
                          "inferenceMS": (inferred - prepared) * 1000,
                          "fingerprintMS": (inferred - start) * 1000])
}

private func runSearchBenchmark(vectors: URL, assetCount: String, editedFraction: String,
                                output: URL, configuration: DedupConfiguration,
                                protocolSHA: String, model: URL?, inputList: URL?,
                                maxDecodedBytes: Int64, profileSHA: String) async throws {
    guard let count = Int(assetCount), count == 100000,
          let fraction = Double(editedFraction), [0.0, 0.5, 1.0].contains(fraction) else {
        throw ProbeError(description: "benchmark requires 100000 assets and edited fraction 0, 0.5, or 1")
    }
    let manifestURL = vectors.appendingPathComponent("fingerprints.json")
    let manifest = try JSONDecoder().decode(FingerprintManifest.self, from: Data(contentsOf: manifestURL))
    guard manifest.protocolSHA256 == protocolSHA,
          manifest.modelSHA256 == configuration.fingerprint.modelSHA256,
          manifest.fingerprintVersion == configuration.fingerprint.version,
          let record = manifest.records.first else {
        throw ProbeError(description: "benchmark vector manifest binding mismatch")
    }
    let seedURL = vectors.appendingPathComponent(record.vectorFile)
    let seedSHA = try sha256(seedURL)
    let seed = try readVector(path: seedURL.path, expectedSHA: seedSHA,
                              version: configuration.fingerprint.version)
    var state: UInt64 = UInt64(seedSHA.prefix(16), radix: 16)! ^ 0x9e3779b97f4a7c15
    var entries = [VectorEntry]()
    let total = count + Int(Double(count) * fraction)
    entries.reserveCapacity(total + 1000)
    for index in 0..<(total + 1000) {
        let vector: Fingerprint
        if index.isMultiple(of: 10000) {
            vector = seed
        } else {
            var values = [Float]()
            values.reserveCapacity(1024)
            for _ in 0..<1024 {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                values.append(Float(Int(state & 0xffff) - 32768) / 32768)
            }
            vector = try Fingerprint(version: configuration.fingerprint.version, values: values)
        }
        entries.append(VectorEntry(key: String(index), origin: .photosCurrent,
                                   fingerprint: vector, size: nil))
    }
    let index = ExactVectorIndex(version: configuration.fingerprint.version)
    let buildStart = CFAbsoluteTimeGetCurrent()
    try await index.replace(entries: Array(entries.prefix(total)), generation: 1)
    let buildMS = (CFAbsoluteTimeGetCurrent() - buildStart) * 1000
    var hot = [Double]()
    var hits = 0
    for _ in 0..<20 {
        let start = CFAbsoluteTimeGetCurrent()
        let found = try await index.search(query: seed, minimumScore: configuration.threshold,
                                           generation: 1)
        hot.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        hits = found.count
    }
    let incrementalStart = CFAbsoluteTimeGetCurrent()
    try await index.replace(entries: entries, generation: 2)
    let incrementalMS = (CFAbsoluteTimeGetCurrent() - incrementalStart) * 1000
    var combined: [String: Any]?
    if let model, let inputList {
        let imagePaths = try JSONDecoder().decode([String].self, from: Data(contentsOf: inputList))
        guard !imagePaths.isEmpty else { throw ProbeError(description: "empty benchmark image list") }
        let coldStart = CFAbsoluteTimeGetCurrent()
        let fingerprinter = try CoreMLFingerprinter(modelURL: model,
                                                    configuration: configuration.fingerprint)
        let first = try await fingerprintLocalImage(URL(fileURLWithPath: imagePaths[0]),
            fingerprinter: fingerprinter, configuration: configuration.fingerprint,
            maxDecodedBytes: maxDecodedBytes)
        let coldFingerprintMS = (CFAbsoluteTimeGetCurrent() - coldStart) * 1000
        var hotCombined = [Double](), incrementalCombined = [Double]()
        var components = [[String: Double]]()
        for iteration in 0..<20 {
            let url = URL(fileURLWithPath: imagePaths[iteration % imagePaths.count])
            let queryStart = CFAbsoluteTimeGetCurrent()
            let (fingerprint, parts) = try await fingerprintLocalImage(url,
                fingerprinter: fingerprinter, configuration: configuration.fingerprint,
                maxDecodedBytes: maxDecodedBytes)
            let scored = try await index.search(query: fingerprint,
                minimumScore: configuration.threshold, generation: Int64(iteration + 2))
            let _ = try AdvancedDuplicatePolicy.evaluate(sourceSize: nil,
                candidates: scored, configuration: configuration)
            hotCombined.append((CFAbsoluteTimeGetCurrent() - queryStart) * 1000)
            components.append(parts)
            let updateStart = CFAbsoluteTimeGetCurrent()
            let (updated, _) = try await fingerprintLocalImage(url,
                fingerprinter: fingerprinter, configuration: configuration.fingerprint,
                maxDecodedBytes: maxDecodedBytes)
            var replacement = Array(entries.prefix(total))
            replacement.append(VectorEntry(key: "updated", origin: .photosCurrent,
                                           fingerprint: updated, size: nil))
            try await index.replace(entries: replacement, generation: Int64(iteration + 3))
            incrementalCombined.append((CFAbsoluteTimeGetCurrent() - updateStart) * 1000)
        }
        combined = ["provenance": "real local fixture query over synthetic deterministic index; performance only",
                    "computeUnits": "cpuOnly",
                    "modelSHA256": configuration.fingerprint.modelSHA256,
                    "fingerprintVersion": configuration.fingerprint.version,
                    "profileSHA256": profileSHA,
                    "backend": configuration.backend,
                    "seedVectorSHA256": seedSHA,
                    "vectorManifestSHA256": try sha256(manifestURL),
                    "inputListSHA256": try sha256(inputList),
                    "inputImageSHA256": try imagePaths.map {
                        try sha256(URL(fileURLWithPath: $0)) },
                    "coldModelLoadAndFingerprintMS": coldFingerprintMS,
                    "coldFirstFingerprintComponents": first.1,
                    "percentileMethod": "nearest-rank empirical; sorted sample at ceil(p*n)-1",
                    "hotQueryCount": hotCombined.count,
                    "hotQuerySamplesMS": hotCombined,
                    "hotQueryP50MS": percentile(hotCombined, 0.50),
                    "hotQueryP95MS": percentile(hotCombined, 0.95),
                    "hotQueryP99MS": percentile(hotCombined, 0.99),
                    "incrementalCount": incrementalCombined.count,
                    "incrementalSamplesMS": incrementalCombined,
                    "incrementalP50MS": percentile(incrementalCombined, 0.50),
                    "incrementalP95MS": percentile(incrementalCombined, 0.95),
                    "incrementalP99MS": percentile(incrementalCombined, 0.99),
                    "incrementalMethod": "local decode/preprocess/inference plus full N+1 replacement",
                    "components": components]
    }
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    try writeJSON(["protocolSHA256": protocolSHA,
                   "vectorManifestSHA256": try sha256(manifestURL),
                   "seedVectorSHA256": seedSHA,
                   "syntheticGenerator": "xorshift64 seeded from first 64 bits of seedVectorSHA256 xor 0x9e3779b97f4a7c15; 1024 independent generated components in [-1,1), normalized Float32; one seed-vector hit every 10000 rows",
                   "profileVersion": configuration.policyVersion,
                   "assetCount": count, "editedFraction": fraction,
                   "representationCount": total,
                   "provenance": "synthetic deterministic Float32 vectors seeded by local R2 vector identity; performance only, no image accuracy evidence",
                   "hitCount": hits, "hitDensity": Double(hits) / Double(total),
                   "indexBuildMS": buildMS,
                   "incremental1000FullReplaceMS": incrementalMS,
                   "incrementalMethod": "replace complete N+1000 view; no in-place append API",
                   "hotQueryP50MS": percentile(hot, 0.50),
                   "hotQueryP95MS": percentile(hot, 0.95),
                   "hotQueryP99MS": percentile(hot, 0.99),
                  "peakRSSBytes": usage.ru_maxrss],
                  at: output.appendingPathComponent("search-benchmark.json"))
    if var combined {
        combined["protocolSHA256"] = protocolSHA
        combined["profileVersion"] = configuration.policyVersion
        combined["assetCount"] = count
        combined["editedFraction"] = fraction
        combined["representationCount"] = total
        combined["peakRSSBytes"] = usage.ru_maxrss
        try writeJSON(combined, at: output.appendingPathComponent("combined-benchmark.json"))
    }
    print("benchmarked \(total) synthetic representations")
}

Task {
    do { try await run(); exit(EXIT_SUCCESS) }
    catch { fputs("probe: \(error)\n", stderr); exit(EXIT_FAILURE) }
}
dispatchMain()
