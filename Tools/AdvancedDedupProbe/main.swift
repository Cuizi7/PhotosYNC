import CoreGraphics
import CoreML
import CryptoKit
import Foundation
import ImageIO

struct ProbeError: Error, CustomStringConvertible {
    let description: String
}

func value(after flag: String, in args: [String]) throws -> String {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else {
        throw ProbeError(description: "missing \(flag)")
    }
    return args[i + 1]
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
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.first == "fingerprint" || args.first == "compare-tensors" else {
        throw ProbeError(description: "expected fingerprint or compare-tensors command")
    }
    let profile = URL(fileURLWithPath: try value(after: "--profile", in: args))
    let model = URL(fileURLWithPath: try value(after: "--model", in: args))
    let output = URL(fileURLWithPath: try value(after: "--output-dir", in: args))
    let protocolSHA = try value(after: "--protocol-sha256", in: args)
    guard protocolSHA.count == 64, protocolSHA.allSatisfy(\.isHexDigit),
          let maxDecodedBytes = Int64(try value(after: "--max-decoded-bytes", in: args)),
          maxDecodedBytes > 0 else { throw ProbeError(description: "invalid approved protocol binding") }
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
    if args.first == "compare-tensors" {
        let maxError = try Double(value(after: "--max-abs-error", in: args))
        let minCosine = try Double(value(after: "--min-cosine", in: args))
        guard let maxError = maxError, let minCosine = minCosine,
              maxError.isFinite, minCosine.isFinite else {
            throw ProbeError(description: "invalid conversion tolerance")
        }
        let entries = try JSONDecoder().decode([TensorPair].self,
                                                from: Data(contentsOf: URL(fileURLWithPath: try value(after: "--tensor-list", in: args))))
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
    let list = URL(fileURLWithPath: try value(after: "--input-list", in: args))
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
