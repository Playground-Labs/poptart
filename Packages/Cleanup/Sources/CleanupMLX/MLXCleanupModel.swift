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
  private var container: ModelContainer?
  private var activeGeneration: (id: UUID, task: Task<Void, Never>)?

  public init(modelDirectory: URL) throws(CleanupModelError) {
    let directory = modelDirectory.standardizedFileURL
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
      modelType == "qwen3_5" || modelType == "qwen3_5_text"
    else { throw CleanupModelError.invalidLocalDirectory }
    self.modelDirectory = directory
  }

  /// Loads and retains the verified local weights and tokenizer before the first Dictation.
  public func prepare() async throws(CleanupModelError) {
    _ = try await loadedContainer()
  }

  /// Diagnostics for the development benchmark; reading these does not load a model.
  public var memoryState: (resident: Bool, activeBytes: Int) {
    (container != nil, Memory.activeMemory)
  }

  /// Cancels generation, releases the resident Cleanup model, and returns MLX cache memory.
  public func unload() {
    activeGeneration?.task.cancel()
    activeGeneration = nil
    container = nil
    Memory.clearCache()
  }

  public func tokenCount(
    for request: CleanupModelRequest
  ) async throws(CleanupModelError) -> Int {
    do {
      let container = try await loadedContainer()
      return try await container.perform { context in
        let input = try await context.processor.prepare(input: Self.input(for: request))
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
    let upstream: AsyncStream<Generation>
    do {
      let container = try await loadedContainer()
      let input = try await container.prepare(input: Self.input(for: request))
      upstream = try await container.generate(
        input: input,
        parameters: .init(
          maxTokens: request.maximumOutputTokens,
          temperature: 0,
          topP: 1,
          topK: 1
        )
      )
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
      if !output.isEmpty { continuation.yield(output) }
      continuation.finish()
      await self?.generationEnded(generationID)
    }
    activeGeneration?.task.cancel()
    activeGeneration = (generationID, task)
    continuation.onTermination = { [weak self] _ in
      task.cancel()
      Task { await self?.generationEnded(generationID) }
    }
    return stream
  }

  private func generationEnded(_ id: UUID) {
    if activeGeneration?.id == id { activeGeneration = nil }
  }

  private func loadedContainer() async throws(CleanupModelError) -> ModelContainer {
    if let container { return container }
    do {
      let loaded = try await LLMModelFactory.shared.loadContainer(
        from: modelDirectory,
        using: LocalTokenizerLoader()
      )
      container = loaded
      return loaded
    } catch {
      throw CleanupModelError.unavailable
    }
  }

  private nonisolated static func input(for request: CleanupModelRequest) -> UserInput {
    UserInput(
      chat: [
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
