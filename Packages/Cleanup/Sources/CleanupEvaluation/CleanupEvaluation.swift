import Cleanup
import CleanupMLX
import DictationCore
import Foundation

/// Explicit local synthetic fixtures only. This executable is not linked into the application.
@main
struct CleanupEvaluation {
  static func main() async throws {
    let args = CommandLine.arguments
    guard args.count == 4 else {
      throw EvaluationError.invalid("usage: CleanupEvaluation LOCAL_MODEL FIXTURES_JSONL NEW_OUTPUT_JSONL")
    }
    let output = URL(fileURLWithPath: args[3])
    guard !FileManager.default.fileExists(atPath: output.path) else {
      throw EvaluationError.invalid("output already exists")
    }
    let fixtures = try String(contentsOfFile: args[2], encoding: .utf8)
      .split(separator: "\n").map { try JSONDecoder().decode(Fixture.self, from: Data($0.utf8)) }
    guard !fixtures.isEmpty, Set(fixtures.map(\.id)).count == fixtures.count,
      fixtures.allSatisfy({ !$0.id.isEmpty && !$0.raw.isEmpty && $0.provenance == [
        "kind": "authoredSynthetic", "author": "Playground Labs",
        "license": "CC0-1.0", "source": "repository",
      ] })
    else { throw EvaluationError.invalid("require unique, nonempty, authored synthetic fixtures") }

    let model = try RecordingModel(directory: URL(fileURLWithPath: args[1]))
    try await model.prepare()
    let clock = UptimeClock()
    let engine = CleanupEngine(
      model: model, deadlineWaiter: SystemCleanupDeadlineWaiter(clock: clock),
      configuration: .init(maximumInputTokens: 8_192)
    )
    var data = Data()
    for fixture in fixtures {
      await model.reset()
      let start = clock.now()
      let result = await engine.clean(.init(
        id: DictationID(), rawTranscript: .init(text: fixture.raw),
        targetContext: fixture.context,
        personalVocabulary: .init(entries: fixture.vocabularyTerms ?? []),
        deadline: start.advanced(by: .seconds(30))
      ))
      let elapsed = Double(clock.now().nanoseconds - start.nanoseconds) / 1_000_000
      let captured = await model.snapshot()
      let text: String
      let outcome: String
      let reason: String?
      switch result {
      case .cleaned(let value): (text, outcome, reason) = (value.text, "cleaned", nil)
      case .oversizedDeterministic(let value):
        (text, outcome, reason) = (value.text, "fallback", "oversizedDeterministic")
      case .rawTranscriptFallback(let fallback):
        (text, outcome, reason) = (fixture.raw, "fallback", fallback.rawValue)
      }
      var parser = BoundedEditPlanParser(maximumBytes: 8_192)
      let plan = try? parser.append(captured.generated)
      let row = Prediction(
        id: fixture.id, output: text, outcome: outcome, rejection: reason,
        elapsedMilliseconds: elapsed, editPlan: plan, generated: captured.generated,
        prompt: captured.prompt, inputTokens: captured.inputTokens, releaseQualified: false
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      data.append(try encoder.encode(row))
      data.append(0x0A)
      print("\(fixture.id): \(outcome), \(Int(elapsed)) ms")
    }
    try data.write(to: output, options: .atomic)
    await model.unload()
    print("Swift Cleanup evaluation wrote \(fixtures.count) records; releaseQualified=false")
  }
}

private enum EvaluationError: Error { case invalid(String) }

private struct Fixture: Decodable {
  let id: String
  let raw: String
  let provenance: [String: String]
  let vocabularyTerms: [String]?
  let targetContext: Context?

  var context: TargetContext {
    .init(
      applicationIdentifier: targetContext?.applicationIdentifier ?? "com.example.editor",
      applicationCategory: ApplicationCategory(rawValue: targetContext?.applicationCategory ?? "textEditor") ?? .other,
      textBeforeCursor: targetContext?.textBeforeCursor ?? "",
      textAfterCursor: targetContext?.textAfterCursor ?? "",
      selectedText: targetContext?.selectedText
    )
  }
}

private struct Context: Decodable {
  let applicationIdentifier: String?
  let applicationCategory: String?
  let textBeforeCursor: String?
  let textAfterCursor: String?
  let selectedText: String?

  init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer()
    if let text = try? value.decode(String.self) {
      applicationIdentifier = nil; applicationCategory = nil
      textBeforeCursor = text; textAfterCursor = nil; selectedText = nil
    } else {
      let values = try value.decode([String: String?].self)
      applicationIdentifier = values["applicationIdentifier"] ?? nil
      applicationCategory = values["applicationCategory"] ?? nil
      textBeforeCursor = values["textBeforeCursor"] ?? nil
      textAfterCursor = values["textAfterCursor"] ?? nil
      selectedText = values["selectedText"] ?? nil
    }
  }
}

private struct Prediction: Encodable {
  let id: String
  let output: String
  let outcome: String
  let rejection: String?
  let elapsedMilliseconds: Double
  let editPlan: CleanupEditPlan?
  let generated: String
  let prompt: String
  let inputTokens: Int
  let releaseQualified: Bool
}

private struct UptimeClock: MonotonicClock {
  func now() -> MonotonicInstant {
    .init(nanoseconds: Int64(DispatchTime.now().uptimeNanoseconds))
  }
}

private actor RecordingModel: CleanupModelBoundary {
  private let model: MLXCleanupModel
  private var generation = UUID()
  private var generated = ""
  private var prompt = ""
  private var inputTokens = 0

  init(directory: URL) throws(CleanupModelError) {
    model = try MLXCleanupModel(modelDirectory: directory)
  }
  func prepare() async throws { try await model.prepare() }
  func unload() async { await model.unload() }
  func reset() { generation = UUID(); generated = ""; prompt = ""; inputTokens = 0 }
  func snapshot() -> (generated: String, prompt: String, inputTokens: Int) {
    (generated, prompt, inputTokens)
  }
  func tokenCount(for request: CleanupModelRequest) async throws(CleanupModelError) -> Int {
    prompt = request.prompt
    inputTokens = try await model.tokenCount(for: request)
    return inputTokens
  }
  func generate(_ request: CleanupModelRequest) async throws(CleanupModelError) -> AsyncStream<String> {
    let upstream = try await model.generate(request)
    let current = generation
    return AsyncStream { continuation in
      let task = Task {
        for await chunk in upstream {
          guard !Task.isCancelled else { break }
          if current == generation { generated += chunk }
          continuation.yield(chunk)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
