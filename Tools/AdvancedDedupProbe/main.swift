import CoreGraphics
import CoreML
import CryptoKit
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
    guard let command = args.first, command == "fingerprint" || command == "compare-tensors" else {
        throw ProbeError(description: "expected fingerprint or compare-tensors command")
    }
    let listFlag = command == "fingerprint" ? "--input-list" : "--tensor-list"
    let allowed = Set(["--profile", "--model", "--output-dir", listFlag, "--approved-protocol-json"])
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
    guard ["--profile", "--model", "--output-dir", listFlag, "--approved-protocol-json"]
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
    let model = URL(fileURLWithPath: args["--model"]!)
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

Task {
    do { try await run(); exit(EXIT_SUCCESS) }
    catch { fputs("probe: \(error)\n", stderr); exit(EXIT_FAILURE) }
}
dispatchMain()
