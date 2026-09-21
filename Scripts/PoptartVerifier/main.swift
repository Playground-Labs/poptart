import Foundation

private let fluidAudioRevision = "61dc8edf915e528a11d81ded84b83d2709746713"
private let fluidAudioRepository = "https://github.com/brandon-nextwork/FluidAudio.git"

enum VerificationError: Error, CustomStringConvertible {
  case failed(String)
  var description: String {
    switch self { case .failed(let message): return message }
  }
}

struct Verifier {
  let root: URL
  let files = FileManager.default
  private(set) var checks = 0

  mutating func run() throws {
    try verifyProductionConfiguration()
    try verifyDependencyPins()
    try verifyCorpusProvenance()
    try verifyModelPackTemplates()
    try verifyPrivacyBoundaries()
  }

  mutating func verifyProductionConfiguration() throws {
    let value = try json("Models/production-config.json")
    let recognition = try dictionary(value, "recognition")
    try expect(recognition["runtimeVersion"] as? String == "0.15.6-poptart.2", "FluidAudio fork version mismatch")
    try expect(recognition["runtimeRevision"] as? String == fluidAudioRevision
      && recognition["runtimeRepository"] as? String == fluidAudioRepository, "FluidAudio fork identity mismatch")
    try expect(recognition["leftFrames"] as? Int == 70 && recognition["chunkFrames"] as? Int == 7 && recognition["rightFrames"] as? Int == 1, "Unified context must be 70/7/1")
    try expect(recognition["encoderPrecision"] as? String == "int8", "Unified encoder must be int8")
    let cleanup = try dictionary(value, "cleanup")
    try expect(cleanup["runtimeVersion"] as? String == "3.31.4", "MLX Swift LM pin mismatch")
    try expect(cleanup["mlxSwiftVersion"] as? String == "0.31.4", "MLX Swift pin mismatch")
    try expect(cleanup["tokenizersVersion"] as? String == "1.3.3", "Tokenizer pin mismatch")
    try expect(cleanup["baseModel"] as? String == "Qwen/Qwen3.5-2B", "Cleanup base model mismatch")
    try expect(cleanup["baseRevision"] as? String == "15852e8c16360a2fea060d615a32b45270f8a8fc", "Cleanup base revision mismatch")
    let quantization = try dictionary(cleanup, "quantization")
    try expect(quantization["bits"] as? Int == 4 && quantization["groupSize"] as? Int == 64 && quantization["mode"] as? String == "affine", "Cleanup quantization mismatch")
    try expect(value["releaseStatus"] as? String == "unreleased", "repository must remain unreleased until evidence is populated")
    try expect(value["artifactHashFormat"] as? String == "sha256-canonical-file-inventory-v1",
      "Model Pack identities must describe runtime files")
    for section in [recognition, cleanup] {
      try expect(section["byteSize"] is NSNull && section["sha256"] is NSNull, "unreleased artifacts must not contain fabricated size or hash")

    }
    try expect(recognition["license"] as? String == "CC-BY-4.0", "Parakeet artifact license mismatch")
    try expect(recognition["modelRevision"] as? String == "4252711f6f060f9a2f91e5f081a806d7f45eebd8", "Parakeet artifact revision mismatch")
    let vad = try dictionary(recognition, "vad")
    try expect(vad["model"] as? String == "FluidInference/silero-vad-coreml"
      && vad["modelRevision"] as? String == "b419383c55c110e2c9271fa6ee0ea83d03c70d96"
      && vad["bundle"] as? String == "silero-vad-unified-256ms-v6.2.1.mlmodelc"
      && vad["license"] as? String == "MIT", "Silero VAD identity or license mismatch")
    try expect(cleanup["license"] as? String == "Apache-2.0", "Qwen artifact license mismatch")
    let measurements = try dictionary(value, "releaseMeasurements")
    try expect(measurements.values.allSatisfy { $0 is NSNull }, "unmeasured release evidence must remain null")
    let performanceClaims = try dictionary(value, "performanceClaims")
    try expect(performanceClaims["eightGBAppleM1"] as? String == "unverified",
      "8 GB M1 performance must remain unverified until measured")
  }

  mutating func verifyDependencyPins() throws {
    for path in ["Package.resolved", "Packages/Recognition/Package.resolved"] {
      let entries = try json(path)["pins"] as? [[String: Any]] ?? []
      let pin = entries.first { $0["identity"] as? String == "fluidaudio" }
      let state = pin?["state"] as? [String: Any]
      try expect(pin?["location"] as? String == fluidAudioRepository
        && state?["revision"] as? String == fluidAudioRevision && state?["version"] == nil,
        "FluidAudio resolved fork pin mismatch: \(path)")
    }
    let cleanup = try pins("Packages/Cleanup/Package.resolved")
    try expect(cleanup["mlx-swift-lm"] == "3.31.4", "mlx-swift-lm resolved pin mismatch")
    try expect(cleanup["mlx-swift"] == "0.31.4", "mlx-swift resolved pin mismatch")
    try expect(cleanup["swift-transformers"] == "1.3.3", "swift-transformers resolved pin mismatch")
  }

  mutating func verifyCorpusProvenance() throws {
    let roots = ["Training/data", "Evals/fixtures"]
    var identifiers = Set<String>()
    var count = 0
    for relativeRoot in roots {
      for file in try recursiveFiles(relativeRoot).filter({ $0.pathExtension == "jsonl" }) {
        for (lineNumber, line) in try String(contentsOf: file, encoding: .utf8).split(separator: "\n").enumerated() {
          guard let data = String(line).data(using: .utf8), let record = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VerificationError.failed("invalid JSONL at \(file.path):\(lineNumber + 1)") }
          let id = record["id"] as? String ?? ""
          try expect(!id.isEmpty && identifiers.insert(id).inserted, "missing or duplicate corpus id: \(id)")
          let provenance = try dictionary(record, "provenance")
          try expect(provenance["kind"] as? String == "authoredSynthetic" && provenance["license"] as? String == "CC0-1.0" && provenance["source"] as? String == "repository", "non-redistributable corpus provenance: \(id)")
          let forbidden = ["userDictation", "personalVocabulary", "applicationContent", "recordedAudio", "clipboard", "historyRecord"]
          try expect(forbidden.allSatisfy { record[$0] == nil }, "private-data field in corpus: \(id)")
          count += 1
        }
      }
    }
    try expect(count >= 20, "training and evaluation corpus is unexpectedly incomplete")
  }

  mutating func verifyModelPackTemplates() throws {
    let schema = try json("Models/model-pack.schema.json")
    try expect(schema["$schema"] as? String == "https://json-schema.org/draft/2020-12/schema", "model-pack schema version mismatch")
    let example = try json("Models/model-pack.example.json")
    try expect(example["exampleOnly"] as? Bool == true && example["cleanupTokenCeiling"] is NSNull, "model-pack example must be visibly non-installable")
    let artifacts = example["artifacts"] as? [[String: Any]] ?? []
    try expect(Set(artifacts.compactMap { $0["role"] as? String }) == ["recognition", "cleanup"], "model-pack example roles mismatch")
    try expect(artifacts.allSatisfy { $0["sha256"] is NSNull && $0["byteSize"] is NSNull }, "model-pack example contains fabricated evidence")
    let schemaProperties = try dictionary(schema, "properties")
    let exampleOnlyRule = schemaProperties["exampleOnly"] as? [String: Any]
    try expect(exampleOnlyRule?["const"] as? Bool == true, "exampleOnly must be pinned to true in the schema")
    let installable = try dictionary(try dictionary(schema, "else"), "properties")
    let installableCeiling = try dictionary(installable, "cleanupTokenCeiling")
    try expect(installableCeiling["type"] as? String == "integer" && installableCeiling["minimum"] as? Int == 1, "installable manifests must require a positive Cleanup token ceiling")
  }

  mutating func verifyPrivacyBoundaries() throws {
    let production = try recursiveFiles("App") + recursiveFiles("Packages")
    let swiftFiles = production.filter { $0.pathExtension == "swift" && !$0.path.contains("/.build/") && !$0.path.contains("/Tests/") }
    for file in swiftFiles {
      let source = try String(contentsOf: file, encoding: .utf8)
      let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
      if source.contains("URLSession") && relative != "Packages/ModelRuntime/Sources/ModelRuntime/URLSessionResumableDownloader.swift" { throw VerificationError.failed("network API outside explicit downloader: \(relative)") }
      for token in ["Sentry", "Crashlytics", "TelemetryClient", "AnalyticsClient", "NWConnection", "AVAudioFile", "write(from:"] where source.contains(token) { throw VerificationError.failed("privacy-forbidden production API \(token) in \(relative)") }
      if relative.hasPrefix("Packages/Recognition/") || relative.hasPrefix("Packages/Cleanup/") {
        for token in ["downloadAndLoad", "ModelHub", "loadModels(to:", "loadModels()"] where source.contains(token) { throw VerificationError.failed("inference network helper \(token) in \(relative)") }
      }
    }
    try expect(true, "privacy scan")
  }

  mutating func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw VerificationError.failed(message) }
    checks += 1
  }

  func json(_ relative: String) throws -> [String: Any] {
    let data = try Data(contentsOf: root.appendingPathComponent(relative))
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VerificationError.failed("expected JSON object: \(relative)") }
    return value
  }

  func dictionary(_ value: [String: Any], _ key: String) throws -> [String: Any] {
    guard let result = value[key] as? [String: Any] else { throw VerificationError.failed("missing object: \(key)") }
    return result
  }

  func pins(_ relative: String) throws -> [String: String] {
    let value = try json(relative)
    let pins = value["pins"] as? [[String: Any]] ?? []
    return Dictionary(uniqueKeysWithValues: pins.compactMap { pin in
      guard let identity = pin["identity"] as? String, let state = pin["state"] as? [String: Any], let version = state["version"] as? String else { return nil }
      return (identity, version)
    })
  }

  func recursiveFiles(_ relative: String) throws -> [URL] {
    let directory = root.appendingPathComponent(relative, isDirectory: true)
    guard let enumerator = files.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { throw VerificationError.failed("missing directory: \(relative)") }
    return enumerator.compactMap { item in
      guard let url = item as? URL, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
      return url
    }
  }
}

let arguments = CommandLine.arguments
let root: URL
if let index = arguments.firstIndex(of: "--root"), arguments.indices.contains(index + 1) {
  root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL
} else {
  root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).standardizedFileURL
}

do {
  var verifier = Verifier(root: root)
  try verifier.run()
  let result: [String: Any] = ["schemaVersion": 1, "status": "passed", "checks": verifier.checks]
  let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
  print(String(decoding: data, as: UTF8.self))
  print("Poptart repository verification passed")
} catch {
  FileHandle.standardError.write(Data("Poptart verification failed: \(error)\n".utf8))
  exit(1)
}
