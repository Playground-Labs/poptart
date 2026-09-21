import Cleanup
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// In-process Cleanup inference from an already verified Model Pack directory.
/// This adapter has no model identifier or downloader API, so inference cannot reach a model hub.
public actor MLXCleanupModel: CleanupModelBoundary {
  private let modelDirectory: URL
  private let adapterDirectory: URL?
  private let gemma3Challenger: Bool
  private var container: ModelContainer?
  private var activeGeneration: (id: UUID, task: Task<Void, Never>)?
  private var lifecycleBusy = false
  private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []

  public init(modelDirectory: URL) throws(CleanupModelError) {
    try self.init(modelDirectory: modelDirectory, gemma3Challenger: false)
  }

  /// Evaluation-only access for the SPEC's Gemma comparison; the app initializer stays Qwen-only.
  @_spi(Evaluation) public static func gemma3Challenger(
    modelDirectory: URL
  ) throws(CleanupModelError) -> MLXCleanupModel {
    try MLXCleanupModel(modelDirectory: modelDirectory, gemma3Challenger: true)
  }

  private init(modelDirectory: URL, gemma3Challenger: Bool) throws(CleanupModelError) {
    let root = modelDirectory.standardizedFileURL
    let base = root.appendingPathComponent("base", isDirectory: true)
    let adapters = root.appendingPathComponent("adapters", isDirectory: true)
    let hasAdapterLayout = FileManager.default.fileExists(atPath: base.path)
      || FileManager.default.fileExists(atPath: adapters.path)
    // MLX recursively loads safetensors; keep base and adapter trees separate.
    let directory = hasAdapterLayout ? base : root
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
    let contents =
      (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      )) ?? []
    let configURL = directory.appendingPathComponent("config.json")
    let modelType = (try? Data(contentsOf: configURL))
      .flatMap { try? JSONDecoder().decode(LocalModelConfiguration.self, from: $0) }
      .map(\.modelType)
    guard directory.isFileURL,
      exists,
      isDirectory.boolValue,
      FileManager.default.fileExists(atPath: configURL.path),
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("tokenizer.json").path),
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("tokenizer_config.json").path),
      contents.contains(where: { $0.pathExtension == "safetensors" }),
      (gemma3Challenger ? ["gemma3", "gemma3_text"] : ["qwen3_5", "qwen3_5_text"])
        .contains(modelType ?? "")
    else { throw CleanupModelError.invalidLocalDirectory }
    if hasAdapterLayout {
      guard let configuration = try? JSONDecoder().decode(LoRAConfiguration.self,
        from: Data(contentsOf: adapters.appendingPathComponent("adapter_config.json"))),
        configuration.fineTuneType == .lora, configuration.numLayers > 0,
        configuration.loraParameters.rank > 0,
        configuration.loraParameters.keys?.isEmpty != true,
        configuration.loraParameters.scale.isFinite, configuration.loraParameters.scale > 0,
        let weights = try? adapters.appendingPathComponent("adapters.safetensors")
          .resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
        weights.isRegularFile == true, (weights.fileSize ?? 0) > 0
      else { throw CleanupModelError.invalidLocalDirectory }
      self.adapterDirectory = adapters
    } else {
      self.adapterDirectory = nil
    }
    self.modelDirectory = directory
    self.gemma3Challenger = gemma3Challenger
  }

  /// Loads and retains the verified local weights and tokenizer before the first Dictation.
  public func prepare() async throws(CleanupModelError) {
    await acquireLifecycle()
    defer { releaseLifecycle() }
    guard !Task.isCancelled else { throw .generationFailed }
    _ = try await loadedContainer()
  }

  /// Diagnostics for the development benchmark; reading these does not load a model.
  public var memoryState: (resident: Bool, activeBytes: Int, cacheBytes: Int, peakActiveBytes: Int) {
    (container != nil, Memory.activeMemory, Memory.cacheMemory, Memory.peakMemory)
  }

  /// Cancels generation, releases the resident Cleanup model, and returns MLX cache memory.
  public func unload() async {
    await acquireLifecycle()
    defer { releaseLifecycle() }
    await stopGeneration()
    guard container != nil else { return }
    container = nil
    Memory.clearCache()
  }

  public func tokenCount(
    for request: CleanupModelRequest
  ) async throws(CleanupModelError) -> Int {
    await acquireLifecycle()
    defer { releaseLifecycle() }
    guard !Task.isCancelled else { throw .generationFailed }
    await stopGeneration()
    do {
      let container = try await loadedContainer()
      return try await container.perform { context in
        let input = try await context.processor.prepare(input: self.input(for: request))
        return input.text.tokens.size
      }
    } catch let error as CleanupModelError {
      throw error
    } catch {
      throw .generationFailed
    }
  }

  public func generate(
    _ request: CleanupModelRequest
  ) async throws(CleanupModelError) -> AsyncStream<String> {
    await acquireLifecycle()
    defer { releaseLifecycle() }
    guard !Task.isCancelled else { throw .generationFailed }
    await stopGeneration()
    let upstream: AsyncStream<Generation>
    let generationTask: Task<Void, Never>
    do {
      let container = try await loadedContainer()
      (upstream, generationTask) = try await container.perform { context in
        let input = try await context.processor.prepare(input: self.input(for: request))
        let iterator = try TokenIterator(input: input, model: context.model, parameters: .init(
          maxTokens: request.maximumOutputTokens,
          temperature: 0,
          topP: 1,
          topK: 1
        ))
        return MLXLMCommon.generateTask(promptTokenCount: input.text.tokens.size,
          modelConfiguration: context.configuration, tokenizer: context.tokenizer, iterator: iterator)
      }
    } catch let error as CleanupModelError {
      throw error
    } catch {
      throw .generationFailed
    }

    let stopMarker = request.stopMarker
    let (stream, continuation) = AsyncStream<String>.makeStream()
    let generationID = UUID()
    let task = Task { [weak self] in
      var output = ""
      for await generation in upstream {
        guard !Task.isCancelled else { break }
        guard let chunk = generation.chunk else { continue }
        output += chunk
        if output.range(of: stopMarker) != nil {
          // Forward the entire generated chunk. The strict parser rejects any bytes
          // after the marker instead of letting this adapter sanitize unsafe output.
          continuation.yield(output)
          output = ""
          break
        }
        // Retain enough suffix to recognize a stop marker split across token chunks.
        let safeCount = max(0, output.count - stopMarker.count)
        if safeCount > 0 {
          let split = output.index(output.startIndex, offsetBy: safeCount)
          continuation.yield(String(output[..<split]))
          output = String(output[split...])
        }
      }
      // Ending an AsyncStream does not join MLX computation. Drain it before the next
      // request or process teardown can release the model and compiler caches.
      generationTask.cancel()
      await generationTask.value
      if !output.isEmpty { continuation.yield(output) }
      continuation.finish()
      await self?.generationEnded(generationID)
    }
    activeGeneration = (generationID, task)
    continuation.onTermination = { _ in
      task.cancel()
    }
    return stream
  }

  private func stopGeneration() async {
    guard let active = activeGeneration else { return }
    active.task.cancel()
    await active.task.value
  }

  // Actor reentrancy must not let unload or a second startup overtake registration.
  // Streaming and generationEnded do not acquire this gate, so teardown can join them.
  func acquireLifecycle() async {
    if !lifecycleBusy { lifecycleBusy = true; return }
    await withCheckedContinuation { lifecycleWaiters.append($0) }
  }

  func releaseLifecycle() {
    if lifecycleWaiters.isEmpty { lifecycleBusy = false }
    else { lifecycleWaiters.removeFirst().resume() }
  }

  var queuedLifecycleOperations: Int { lifecycleWaiters.count }

  private func generationEnded(_ id: UUID) {
    if activeGeneration?.id == id {
      activeGeneration = nil
      // Prompt shapes vary between Dictations. Return unused buffers after MLX joins,
      // while retaining the resident weights, instead of accumulating a device-sized cache.
      Memory.clearCache()
    }
  }

  private func loadedContainer() async throws(CleanupModelError) -> ModelContainer {
    if let container { return container }
    do {
      let loaded = try await LLMModelFactory.shared.loadContainer(
        from: modelDirectory,
        using: LocalTokenizerLoader()
      )
      if let adapterDirectory {
        let adapter = try LoRAContainer.from(directory: adapterDirectory)
        try await loaded.perform { context in
          let initialized = try LoRAContainer.from(model: context.model, configuration: adapter.configuration)
          let expected = Dictionary(uniqueKeysWithValues: initialized.parameters.flattened())
          let actual = Dictionary(uniqueKeysWithValues: adapter.parameters.flattened())
          // The upstream loader rejects extra keys but permits missing adapter tensors. Require
          // the complete trained adapter instead of retaining randomly initialized replacements.
          guard !expected.isEmpty, expected.keys.sorted() == actual.keys.sorted(),
            expected.allSatisfy({ actual[$0.key]?.shape == $0.value.shape })
          else { throw CleanupModelError.invalidLocalDirectory }
          try context.model.update(parameters: adapter.parameters, verify: .noUnusedKeys)
          eval(context.model)
        }
      }
      container = loaded
      return loaded
    } catch {
      throw CleanupModelError.unavailable
    }
  }

  nonisolated func input(for request: CleanupModelRequest) -> UserInput {
    UserInput(
      // Gemma 3 has no system role: keep identical instruction/data text in its first user turn.
      chat: gemma3Challenger ? [.user(request.systemInstruction + "\n\n" + request.prompt)] : [
        .system(request.systemInstruction),
        .user(request.prompt),
      ],
      // Qwen 3.5 templates understand this flag. Disabling thinking keeps the edit-plan
      // contract and output budget focused on JSON rather than hidden reasoning tokens.
      additionalContext: ["enable_thinking": request.enableThinking]
    )
  }
}

private struct LocalModelConfiguration: Decodable {
  let modelType: String

  enum CodingKeys: String, CodingKey {
    case modelType = "model_type"
  }
}

private struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
  func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
    let tokenizer = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
    return LocalTokenizer(tokenizer)
  }
}

private struct LocalTokenizer: MLXLMCommon.Tokenizer {
  let upstream: any Tokenizers.Tokenizer

  init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

  func encode(text: String, addSpecialTokens: Bool) -> [Int] {
    upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
  }

  func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
    upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
  }

  func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
  func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
  var bosToken: String? { upstream.bosToken }
  var eosToken: String? { upstream.eosToken }
  var unknownToken: String? { upstream.unknownToken }

  func applyChatTemplate(
    messages: [[String: any Sendable]],
    tools: [[String: any Sendable]]?,
    additionalContext: [String: any Sendable]?
  ) throws -> [Int] {
    do {
      return try upstream.applyChatTemplate(
        messages: messages,
        tools: tools,
        additionalContext: additionalContext
      )
    } catch Tokenizers.TokenizerError.missingChatTemplate {
      throw MLXLMCommon.TokenizerError.missingChatTemplate
    }
  }
}
