import Cleanup
import CleanupMLX
import Foundation
import Testing

@Suite("Local MLX Cleanup model")
struct MLXCleanupModelTests {
  @Test("Only a complete local model directory is accepted")
  func rejectsAnythingButLocalArtifacts() throws {
    let remoteURL = try #require(URL(string: "https://example.com/model"))
    #expect(throws: CleanupModelError.invalidLocalDirectory) {
      try MLXCleanupModel(modelDirectory: remoteURL)
    }
    #expect(throws: CleanupModelError.invalidLocalDirectory) {
      try MLXCleanupModel(
        modelDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString)
      )
    }
  }

  @Test("The local artifact must declare the Qwen 3.5 architecture")
  func validatesExpectedArchitecture() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(#"{"model_type":"gemma3"}"#.utf8)
      .write(to: directory.appendingPathComponent("config.json"))
    try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
    try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer_config.json"))
    try Data().write(to: directory.appendingPathComponent("model.safetensors"))

    #expect(throws: CleanupModelError.invalidLocalDirectory) {
      try MLXCleanupModel(modelDirectory: directory)
    }

    try Data(#"{"model_type":"qwen3_5"}"#.utf8)
      .write(to: directory.appendingPathComponent("config.json"))
    let model = try MLXCleanupModel(modelDirectory: directory)
    let prepare: @Sendable () async throws -> Void = { try await model.prepare() }
    let unload: @Sendable () async -> Void = { await model.unload() }
    _ = prepare  // Compile-contract coverage; loading requires a real signed model artifact.
    _ = unload
  }
}
