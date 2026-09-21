import Cleanup
@_spi(Evaluation) import CleanupMLX
import CryptoKit
import Darwin
import DictationCore
import Foundation

struct EvaluationError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct EvaluationClock: MonotonicClock {
    func now() -> MonotonicInstant { .init(nanoseconds: Int64(DispatchTime.now().uptimeNanoseconds)) }
}

actor ObservedModel: CleanupModelBoundary {
    let model: any CleanupModelBoundary
    private(set) var response = ""
    private(set) var request: CleanupModelRequest?
    private(set) var inputTokens = 0

    init(_ model: any CleanupModelBoundary) { self.model = model }
    func reset() { response = ""; request = nil; inputTokens = 0 }
    func tokenCount(for request: CleanupModelRequest) async throws(CleanupModelError) -> Int {
        self.request = request
        inputTokens = try await model.tokenCount(for: request)
        return inputTokens
    }
    func generate(_ request: CleanupModelRequest) async throws(CleanupModelError) -> AsyncStream<String> {
        let source = try await model.generate(request)
        let pair = AsyncStream<String>.makeStream()
        let task = Task {
            for await chunk in source {
                if Task.isCancelled { break }
                response += chunk
                pair.continuation.yield(chunk)
            }
            pair.continuation.finish()
        }
        pair.continuation.onTermination = { _ in task.cancel() }
        return pair.stream
    }
}

struct EvaluationFixture: Decodable {
    struct Context: Decodable {
        let applicationIdentifier: String
        let applicationCategory: String
        let textBeforeCursor: String
        let textAfterCursor: String
        let selectedText: String?
    }
    let id: String
    let raw: String
    let vocabularyTerms: [String]
    let context: TargetContext
    let probeEditPlans: [CleanupEditPlan]
    let reservedEdits: [CleanupEdit]

    enum CodingKeys: String, CodingKey { case id, raw, vocabularyTerms, targetContext, provenance, probeEditPlans, reservedEdits }
    init(from decoder: any Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        id = try data.decode(String.self, forKey: .id)
        raw = try data.decode(String.self, forKey: .raw)
        let provenance = try data.decode([String: String].self, forKey: .provenance)
        guard !id.isEmpty, !raw.isEmpty, provenance == ["kind": "authoredSynthetic", "author": "Playground Labs",
                "license": "CC0-1.0", "source": "repository"] else { throw EvaluationError("Invalid authored fixture: \(id)") }
        vocabularyTerms = try data.decodeIfPresent([String].self, forKey: .vocabularyTerms) ?? []
        probeEditPlans = try data.decodeIfPresent([CleanupEditPlan].self, forKey: .probeEditPlans) ?? []
        reservedEdits = try data.decodeIfPresent([CleanupEdit].self, forKey: .reservedEdits) ?? []
        if let text = try? data.decode(String.self, forKey: .targetContext) {
            context = .init(applicationIdentifier: "com.example.editor", applicationCategory: .textEditor,
                            textBeforeCursor: text, textAfterCursor: "", selectedText: nil)
        } else if let value = try data.decodeIfPresent(Context.self, forKey: .targetContext) {
            guard let category = ApplicationCategory(rawValue: value.applicationCategory) else {
                throw EvaluationError("Invalid application category: \(id)")
            }
            context = .init(applicationIdentifier: value.applicationIdentifier, applicationCategory: category,
                textBeforeCursor: value.textBeforeCursor, textAfterCursor: value.textAfterCursor, selectedText: value.selectedText)
        } else {
            context = .init(applicationIdentifier: "com.example.editor", applicationCategory: .textEditor,
                            textBeforeCursor: "", textAfterCursor: "", selectedText: nil)
        }
    }
}

func prediction(fixture: EvaluationFixture, model: ObservedModel, maximumInputTokens: Int) async throws -> [String: Any] {
    await model.reset()
    let clock = EvaluationClock()
    let engine = CleanupEngine(model: model, deadlineWaiter: SystemCleanupDeadlineWaiter(clock: clock),
                               configuration: .init(maximumInputTokens: maximumInputTokens))
    let start = clock.now()
    let result = await engine.clean(.init(id: .init(), rawTranscript: .init(text: fixture.raw),
        targetContext: fixture.context, personalVocabulary: .init(entries: fixture.vocabularyTerms),
        deadline: start.advanced(by: .seconds(60))))
    let duration = start.duration(to: clock.now()).components
    var row: [String: Any] = ["id": fixture.id, "elapsedMilliseconds": Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15,
        "inputTokens": await model.inputTokens, "maximumInputTokens": maximumInputTokens, "deadlineMilliseconds": 60_000,
        "evaluationOnly": true, "rawModelOutput": await model.response]
    switch result {
    case .cleaned(let value): row["outcome"] = "cleaned"; row["output"] = value.text
    case .rawTranscriptFallback(let reason):
        guard reason == .unsafeEditPlan else { throw EvaluationError("\(fixture.id): inference failed: \(reason)") }
        row["outcome"] = "fallback"; row["output"] = fixture.raw; row["fallbackReason"] = reason.rawValue
    case .oversizedDeterministic:
        throw EvaluationError("\(fixture.id): exceeds evaluation token ceiling; increase --max-input-tokens")
    }
    guard let request = await model.request else { throw EvaluationError("No model request for \(fixture.id)") }
    row["modelPrompt"] = request.prompt
    row["promptSHA256"] = SHA256.hash(data: Data((request.systemInstruction + "\n" + request.prompt).utf8)).map { String(format: "%02x", $0) }.joined()
    var parser = BoundedEditPlanParser(maximumBytes: 8192)
    if let plan = try? parser.append(await model.response) {
        row["editPlan"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan))
    }
    return row
}

// Controlled model output exercises the production parser, validator, and raw fallback.
// These results are boundary evidence, never evidence that an LLM resisted an attack.
private struct ProbeModel: CleanupModelBoundary {
    let output: String
    func tokenCount(for request: CleanupModelRequest) -> Int { 1 }
    func generate(_ request: CleanupModelRequest) -> AsyncStream<String> {
        AsyncStream { $0.yield(output); $0.finish() }
    }
}

func probePredictions(fixtures: [EvaluationFixture]) async throws -> [[String: Any]] {
    let validator = CleanupEditPlanValidator(configuration: .init(maximumInputTokens: 2_048))
    var rows: [[String: Any]] = []
    for fixture in fixtures {
        let transcript = StableTranscript(fixture.raw)
        for (index, plan) in fixture.probeEditPlans.enumerated() {
            let validationError: CleanupEditValidationError
            do {
                _ = try validator.validate(plan, transcript: transcript,
                    reservedEdits: fixture.reservedEdits, targetContext: fixture.context,
                    personalVocabulary: .init(entries: fixture.vocabularyTerms))
                throw EvaluationError("\(fixture.id): rejection probe was accepted")
            } catch let error as CleanupEditValidationError { validationError = error }
            let output = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self) + CleanupPrompt.stopMarker
            let result = try await prediction(fixture: fixture, model: ObservedModel(ProbeModel(output: output)),
                                              maximumInputTokens: 2_048)
            guard result["outcome"] as? String == "fallback", result["output"] as? String == fixture.raw else {
                throw EvaluationError("\(fixture.id): engine did not preserve rejected probe text")
            }
            rows.append(["id": "\(fixture.id)#probe-\(index)", "validationError": String(describing: validationError),
                "outcome": "fallback", "output": fixture.raw, "fallbackReason": "unsafeEditPlan",
                "elapsedMilliseconds": result["elapsedMilliseconds"]!])
        }
    }
    guard !rows.isEmpty else { throw EvaluationError("No native rejection probes in fixtures") }
    return rows
}

@main enum CleanupEvaluation {
    static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch { FileHandle.standardError.write(Data("Cleanup evaluation: \(error)\n".utf8)); exit(1) }
    }
    static func run(_ arguments: [String]) async throws {
        var args = arguments
        let probesOnly = args.contains("--probes-only")
        guard args.filter({ $0 == "--probes-only" }).count <= 1 else { throw EvaluationError("Duplicate --probes-only") }
        args.removeAll { $0 == "--probes-only" }
        var values: [String: String] = [:]
        while !args.isEmpty {
            let key = args.removeFirst()
            guard ["--model", "--gold", "--adversarial", "--output", "--max-input-tokens", "--challenger"].contains(key),
                  values[key] == nil, !args.isEmpty, !args[0].hasPrefix("--") else {
                throw EvaluationError("Usage: PoptartCleanupEval (--model DIR | --probes-only) --output FILE [--gold PATH] [--adversarial PATH] [--max-input-tokens N] [--challenger gemma3]")
            }
            values[key] = args.removeFirst()
        }
        if let challenger = values["--challenger"], challenger != "gemma3" || probesOnly {
            throw EvaluationError("--challenger accepts only gemma3 and requires model inference")
        }
        guard let output = values["--output"], probesOnly || values["--model"] != nil,
              let ceiling = Int(values["--max-input-tokens"] ?? "2048"), ceiling > 0 else {
            throw EvaluationError("--output and a positive token ceiling are required; supply local --model or --probes-only")
        }
        let adversarial = values["--adversarial"] ?? "Evals/fixtures/adversarial.jsonl"
        let paths = probesOnly ? [adversarial] : [values["--gold"] ?? "Evals/fixtures/gold.jsonl", adversarial]
        let fixtures = try paths.flatMap { path in
            try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map {
                try JSONDecoder().decode(EvaluationFixture.self, from: Data($0.utf8))
            }
        }
        guard !fixtures.isEmpty, Set(fixtures.map(\.id)).count == fixtures.count else {
            throw EvaluationError("Empty or duplicate fixtures")
        }
        if probesOnly {
            var outputData = Data()
            for row in try await probePredictions(fixtures: fixtures) {
                outputData.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
                outputData.append(10)
            }
            try outputData.write(to: URL(fileURLWithPath: output), options: .atomic)
            return
        }
        let modelPath = values["--model"]!
        let modelDirectory = URL(fileURLWithPath: modelPath, isDirectory: true)
        let model = try values["--challenger"] == "gemma3"
          ? MLXCleanupModel.gemma3Challenger(modelDirectory: modelDirectory)
          : MLXCleanupModel(modelDirectory: modelDirectory)
        try await model.prepare()
        let observer = ObservedModel(model)
        var predictions = Data()
        do {
            for fixture in fixtures {
                var row = try await prediction(fixture: fixture, model: observer, maximumInputTokens: ceiling)
                let memory = await model.memoryState
                row["modelResident"] = memory.resident
                row["mlxActiveBytes"] = memory.activeBytes
                row["mlxCacheBytes"] = memory.cacheBytes
                row["mlxPeakActiveBytes"] = memory.peakActiveBytes
                predictions.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
                predictions.append(10)
                FileHandle.standardError.write(Data("\(fixture.id): \(row["outcome"]!)\n".utf8))
            }
        } catch {
            await model.unload()
            throw error
        }
        await model.unload()
        try predictions.write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
