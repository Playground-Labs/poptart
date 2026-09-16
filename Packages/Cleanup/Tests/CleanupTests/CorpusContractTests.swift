import DictationCore
import Foundation
import Testing
@testable import Cleanup

@Test("Every training and gold label agrees with the native cleanup contract")
func corpusMatchesNativeRuntime() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let paths = ["Training/data/corpus.jsonl", "Evals/fixtures/gold.jsonl", "Evals/fixtures/spoken.jsonl"]
    let validator = CleanupEditPlanValidator(configuration: .init(maximumInputTokens: 2_048))
    for path in paths {
        let lines = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8).split(separator: "\n")
        for line in lines {
            let record = try JSONDecoder().decode(CorpusRecord.self, from: Data(line.utf8))
            let transcript = StableTranscript(record.raw)
            let reserved = ExplicitCorrections.edits(in: transcript)
            #expect(reserved == (record.reservedEdits ?? []), "\(record.id): deterministic correction drift")
            let edits = try validator.validate(record.editPlan, transcript: transcript, reservedEdits: reserved,
                targetContext: record.targetContext?.value ?? .init(applicationIdentifier: "com.example.editor",
                    applicationCategory: .textEditor, textBeforeCursor: "", textAfterCursor: "", selectedText: nil),
                personalVocabulary: .init(entries: record.vocabularyTerms ?? []))
            #expect(CleanupEditApplier.apply(edits, to: transcript) == (record.clean ?? record.expected),
                    "\(record.id): native output disagrees with label")
        }
    }
}

private struct CorpusRecord: Decodable {
    struct Context: Decodable {
        let applicationIdentifier: String
        let applicationCategory: String
        let textBeforeCursor: String
        let textAfterCursor: String
        let selectedText: String?
        var value: TargetContext {
            .init(applicationIdentifier: applicationIdentifier,
                  applicationCategory: ApplicationCategory(rawValue: applicationCategory) ?? .other,
                  textBeforeCursor: textBeforeCursor, textAfterCursor: textAfterCursor, selectedText: selectedText)
        }
    }
    let id: String
    let raw: String
    let clean: String?
    let expected: String?
    let editPlan: CleanupEditPlan
    let reservedEdits: [CleanupEdit]?
    let vocabularyTerms: [String]?
    let targetContext: Context?
}
