import Cleanup
import Foundation
import Testing
@testable import PoptartCleanupEval

@Test("Cleanup evaluator rejects unknown challengers and challenger probes without loading a model")
func rejectsInvalidChallengerArguments() async {
    for arguments in [["--challenger", "other"], ["--probes-only", "--challenger", "gemma3"]] {
        await #expect(throws: EvaluationError.self) { try await CleanupEvaluation.run(arguments) }
    }
}

private actor FixedEvaluationModel: CleanupModelBoundary {
    let output: String
    init(_ output: String) { self.output = output }
    func tokenCount(for request: CleanupModelRequest) -> Int { 30 }
    func generate(_ request: CleanupModelRequest) -> AsyncStream<String> {
        AsyncStream { $0.yield(output); $0.finish() }
    }
}

@Test("Cleanup evaluation scores real engine output and captures rejected plans")
func cleanupEvaluationUsesEngine() async throws {
    let data = Data(#"{"id":"test","raw":"hello there","provenance":{"kind":"authoredSynthetic","author":"Playground Labs","license":"CC0-1.0","source":"repository"},"targetContext":"untrusted neighboring content"}"#.utf8)
    let fixture = try JSONDecoder().decode(EvaluationFixture.self, from: data)
    let valid = #"{"v":1,"e":[{"s":0,"e":1,"r":"Hello","c":"capitalization"},{"s":2,"e":2,"r":".","c":"punctuation"}]}<END_PLAN>"#
    let row = try await prediction(fixture: fixture, model: ObservedModel(FixedEvaluationModel(valid)), maximumInputTokens: 100)
    #expect(row["output"] as? String == "Hello there.")
    #expect(row["outcome"] as? String == "cleaned")
    #expect(row["editPlan"] != nil)
    #expect(row["rawModelOutput"] as? String == valid)
    let unsafe = #"{"v":1,"e":[{"s":0,"e":1,"r":"Goodbye","c":"capitalization"}]}<END_PLAN>"#
    let rejected = try await prediction(fixture: fixture, model: ObservedModel(FixedEvaluationModel(unsafe)), maximumInputTokens: 100)
    #expect(rejected["outcome"] as? String == "fallback")
    #expect(rejected["output"] as? String == "hello there")
    await #expect(throws: EvaluationError.self) {
        _ = try await prediction(fixture: fixture, model: ObservedModel(FixedEvaluationModel(valid)), maximumInputTokens: 1)
    }
}

@Test("Frozen adversarial probes are rejected by the native validator and engine")
func releaseProbesUseNativeRuntime() async throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { root.deleteLastPathComponent() }
    for path in ["Evals/fixtures/adversarial.jsonl", "Evals/fixtures/release-v2/adversarial.jsonl"] {
        let lines = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8).split(separator: "\n")
        let fixtures = try lines.map { try JSONDecoder().decode(EvaluationFixture.self, from: Data($0.utf8)) }
        let rows = try await probePredictions(fixtures: fixtures)
        #expect(rows.count == fixtures.reduce(0) { $0 + $1.probeEditPlans.count })
        #expect(Set(rows.compactMap { $0["validationError"] as? String }) ==
            ["invalidBounds", "unorderedOrOverlapping", "unsafeUnicode"])
        for row in rows {
            #expect(row["outcome"] as? String == "fallback")
            #expect(row["fallbackReason"] as? String == "unsafeEditPlan")
        }
    }
    let accepted = Data(#"{"id":"accepted","raw":"hello there","provenance":{"kind":"authoredSynthetic","author":"Playground Labs","license":"CC0-1.0","source":"repository"},"probeEditPlans":[{"v":1,"e":[]}]}"#.utf8)
    let fixture = try JSONDecoder().decode(EvaluationFixture.self, from: accepted)
    await #expect(throws: EvaluationError.self) { _ = try await probePredictions(fixtures: [fixture]) }
    await #expect(throws: EvaluationError.self) { _ = try await probePredictions(fixtures: []) }
}
