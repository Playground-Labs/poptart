import DictationCore
import Foundation
import Testing
@testable import Cleanup

@Test("Every training and gold label agrees with the native cleanup contract")
func corpusMatchesNativeRuntime() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let paths = ["Training/data/corpus.jsonl", "Evals/fixtures/gold.jsonl", "Evals/fixtures/spoken.jsonl",
                 "Evals/fixtures/release-v1/gold.jsonl", "Evals/fixtures/release-v2/gold.jsonl"]
    let generated = try Dictionary(uniqueKeysWithValues: ["train", "valid", "test"].map { split in
        let file = root.appendingPathComponent("Training/generated/mlx/\(split).jsonl")
        let chats = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(TrainingChat.self, from: Data($0.utf8))
        }
        return (split, chats)
    })
    var offsets: [String: Int] = [:]
    let validator = CleanupEditPlanValidator(configuration: .init(maximumInputTokens: 2_048))
    for path in paths {
        let lines = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8).split(separator: "\n")
        for line in lines {
            let record = try JSONDecoder().decode(CorpusRecord.self, from: Data(line.utf8))
            let transcript = StableTranscript(record.raw)
            let reserved = ExplicitCorrections.edits(in: transcript)
            #expect(reserved == (record.reservedEdits ?? []), "\(record.id): deterministic correction drift")
            if let split = record.split {
                let index = offsets[split, default: 0]
                let chats = try #require(generated[split])
                try #require(chats.indices.contains(index), "Missing generated chat for \(record.id)")
                let chat = chats[index]
                try #require(chat.messages.count == 3)
                offsets[split] = index + 1
                #expect(chat.messages[0].content == CleanupPrompt.cleanupSystemInstruction)
                let prompt = try CleanupPrompt.build(transcript: transcript,
                    targetContext: record.targetContext?.value ?? .init(applicationIdentifier: "com.example.editor",
                        applicationCategory: .textEditor, textBeforeCursor: "", textAfterCursor: "", selectedText: nil),
                    personalVocabulary: .init(entries: record.vocabularyTerms ?? []), reservedEdits: reserved)
                #expect(chat.messages[1].content == prompt, "\(record.id): training prompt differs from inference")
                var parser = BoundedEditPlanParser(maximumBytes: 8_192)
                #expect(try parser.append(chat.messages[2].content) == record.editPlan)
            }
            let edits = try validator.validate(record.editPlan, transcript: transcript, reservedEdits: reserved,
                targetContext: record.targetContext?.value ?? .init(applicationIdentifier: "com.example.editor",
                    applicationCategory: .textEditor, textBeforeCursor: "", textAfterCursor: "", selectedText: nil),
                personalVocabulary: .init(entries: record.vocabularyTerms ?? []))
            #expect(CleanupEditApplier.apply(edits, to: transcript) == (record.clean ?? record.expected),
                    "\(record.id): native output disagrees with label")
        }
    }
    for (split, chats) in generated { #expect(offsets[split] == chats.count) }
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
    let split: String?
    let raw: String
    let clean: String?
    let expected: String?
    let editPlan: CleanupEditPlan
    let reservedEdits: [CleanupEdit]?
    let vocabularyTerms: [String]?
    let targetContext: Context?
}

private struct TrainingChat: Decodable {
    struct Message: Decodable { let content: String }
    let messages: [Message]
}

@Test("Mechanical edits preserve numeric and URL literals in the shared boundary cases")
func literalBoundariesMatchNativeRuntime() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let cases = try JSONDecoder().decode([LiteralBoundaryCase].self,
        from: Data(contentsOf: root.appendingPathComponent("Evals/fixtures/literal-boundaries.json")))
    let validator = CleanupEditPlanValidator(configuration: .init(maximumInputTokens: 2_048))
    let context = TargetContext(applicationIdentifier: "test.synthetic.editor",
        applicationCategory: .textEditor, textBeforeCursor: "", textAfterCursor: "", selectedText: nil)
    for fixture in cases {
        let transcript = StableTranscript(fixture.raw)
        let reserved = ExplicitCorrections.edits(in: transcript)
        #expect(reserved == fixture.reservedEdits, "\(fixture.id): correction reservation differs")
        if fixture.reject {
            #expect(throws: CleanupEditValidationError.unsafeCategory, "\(fixture.id)") {
                try validator.validate(fixture.plan, transcript: transcript, reservedEdits: reserved,
                    targetContext: context, personalVocabulary: .init(entries: []))
            }
        } else {
            let edits = try validator.validate(fixture.plan, transcript: transcript, reservedEdits: reserved,
                targetContext: context, personalVocabulary: .init(entries: []))
            #expect(CleanupEditApplier.apply(edits, to: transcript) == fixture.expected, "\(fixture.id)")
        }
    }
}

private struct LiteralBoundaryCase: Decodable {
    let id: String
    let raw: String
    let plan: CleanupEditPlan
    let reservedEdits: [CleanupEdit]
    let reject: Bool
    let expected: String
}
