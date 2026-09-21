import Cleanup
@_spi(Evaluation) @testable import CleanupMLX
import Foundation
import Testing

@Suite("Local MLX Cleanup model")
struct MLXCleanupModelTests {
  @Test("Cancelled queued startup releases teardown without loading weights")
  func queuedStartupAndUnload() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for name in ["tokenizer.json", "tokenizer_config.json", "model.safetensors"] {
      try Data().write(to: directory.appendingPathComponent(name))
    }
    try Data(#"{"model_type":"qwen3_5"}"#.utf8).write(to: directory.appendingPathComponent("config.json"))
    let model = try MLXCleanupModel(modelDirectory: directory)
    await model.acquireLifecycle()  // Simulate an earlier startup suspended before registration.
    let request = CleanupModelRequest(systemInstruction: "test", prompt: "test", enableThinking: false,
      maximumOutputTokens: 128, stopMarker: CleanupPrompt.stopMarker)
    let generation = Task { try await model.generate(request) }
    for _ in 0..<10_000 {
      if await model.queuedLifecycleOperations == 1 { break }
      await Task.yield()
    }
    #expect(await model.queuedLifecycleOperations == 1)
    generation.cancel()
    let unload = Task { await model.unload() }
    for _ in 0..<10_000 {
      if await model.queuedLifecycleOperations == 2 { break }
      await Task.yield()
    }
    #expect(await model.queuedLifecycleOperations == 2)
    await model.releaseLifecycle()
    await #expect(throws: CleanupModelError.generationFailed) { _ = try await generation.value }
    await unload.value
    await model.acquireLifecycle()
    #expect(await model.queuedLifecycleOperations == 0)
    await model.releaseLifecycle()
  }

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
    let challenger = try MLXCleanupModel.gemma3Challenger(modelDirectory: directory)
    let request = CleanupModelRequest(systemInstruction: "system", prompt: "untrusted data", enableThinking: false,
      maximumOutputTokens: 128, stopMarker: CleanupPrompt.stopMarker)
    guard case .chat(let messages) = challenger.input(for: request).prompt else {
      Issue.record("Expected Gemma chat input"); return
    }
    #expect(messages.count == 1)
    #expect(messages.first?.role == .user)
    #expect(messages.first?.content == "system\n\nuntrusted data")

    try Data(#"{"model_type":"qwen3_5"}"#.utf8)
      .write(to: directory.appendingPathComponent("config.json"))
    let model = try MLXCleanupModel(modelDirectory: directory)
    #expect(throws: CleanupModelError.invalidLocalDirectory) {
      try MLXCleanupModel.gemma3Challenger(modelDirectory: directory)
    }
    guard case .chat(let productionMessages) = model.input(for: request).prompt else {
      Issue.record("Expected Qwen chat input"); return
    }
    #expect(productionMessages.map(\.role) == [.system, .user])
    #expect(productionMessages.map(\.content) == ["system", "untrusted data"])
    let prepare: @Sendable () async throws -> Void = { try await model.prepare() }
    let unload: @Sendable () async -> Void = { await model.unload() }
    _ = prepare  // Compile-contract coverage; loading requires a real signed model artifact.
    _ = unload

    let adapters = directory.appendingPathComponent("adapters", isDirectory: true)
    try FileManager.default.createDirectory(at: adapters, withIntermediateDirectories: true)
    #expect(throws: CleanupModelError.invalidLocalDirectory) {
      try MLXCleanupModel(modelDirectory: directory)
    }
    let base = directory.appendingPathComponent("base", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    for name in ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"] {
      try FileManager.default.moveItem(at: directory.appendingPathComponent(name), to: base.appendingPathComponent(name))
    }
    let configuration = adapters.appendingPathComponent("adapter_config.json")
    try Data(#"{"fine_tune_type":"lora","num_layers":16,"lora_parameters":{"rank":8,"scale":20}}"#.utf8)
      .write(to: configuration)
    try Data().write(to: adapters.appendingPathComponent("adapters.safetensors"))
    #expect(throws: CleanupModelError.invalidLocalDirectory) {
      try MLXCleanupModel(modelDirectory: directory)
    }
    try Data("weights are decoded during prepare".utf8)
      .write(to: adapters.appendingPathComponent("adapters.safetensors"))
    _ = try MLXCleanupModel(modelDirectory: directory)
    for invalid in [
      #"{"fine_tune_type":"lora","num_layers":16,"lora_parameters":{"rank":0,"scale":20}}"#,
      #"{"fine_tune_type":"lora","num_layers":16,"lora_parameters":{"rank":8,"scale":20,"keys":[]}}"#,
    ] {
      try Data(invalid.utf8).write(to: configuration)
      #expect(throws: CleanupModelError.invalidLocalDirectory) {
        try MLXCleanupModel(modelDirectory: directory)
      }
    }
  }
}
