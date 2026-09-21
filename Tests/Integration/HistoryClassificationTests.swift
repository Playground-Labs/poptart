import CryptoKit
import DictationCore
import Foundation
import Persistence
import Testing

@testable import PoptartApplication

@Suite("Independent history classifications")
struct HistoryClassificationTests {
    @Test("History and its presentation retain delivery, text source, and the safety stop")
    func combinedOutcomesSurviveHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 2_000_000)
        let store = try HistoryStore(directory: directory, keyProvider: ClassificationKey(), now: { now })
        let boundary = EncryptedHistoryBoundary(store: store)
        let cases: [(DictationCore.DictationOutcome, Persistence.DictationOutcome,
                     DictationRecordingEnd, DictationTextSource?, String)] = [
            (.cleanedInsertion(method: .accessibility, recordingEnd: .fiveMinuteSafetyLimit),
             .cleaned, .fiveMinuteSafetyLimit, .cleaned,
             "Cleanup left the text as heard — Stopped at the five-minute limit"),
            (.recognitionHypothesisFallback(method: .accessibility, recordingEnd: .fiveMinuteSafetyLimit),
             .recognitionHypothesis, .fiveMinuteSafetyLimit, .recognitionHypothesis,
             "Recognition fallback — not fully finalized — Stopped at the five-minute limit"),
            (.targetChangedClipboard(source: .oversizedDeterministicFallback, recordingEnd: .released),
             .copiedTargetChanged, .released, .oversized,
             "Copied because the target changed — Too long for Cleanup — deterministic rules only"),
            (.noTargetClipboard(source: .recognitionHypothesisFallback, recordingEnd: .released),
             .copiedNoTarget, .released, .recognitionHypothesis,
             "Copied because no text field was focused — Recognition fallback — not fully finalized"),
            (.deliveryFailure(source: .rawTranscriptFallback(.cleanupTimedOut),
                              reason: .accessibilityAndPasteFailed, recordingEnd: .fiveMinuteSafetyLimit),
             .deliveryFailure, .fiveMinuteSafetyLimit, .rawTranscript,
             "Delivery failed — Raw Transcript fallback — Cleanup timed out — Stopped at the five-minute limit"),
            (.targetChangedClipboard(source: .cleaned, recordingEnd: .fiveMinuteSafetyLimit),
             .copiedTargetChanged, .fiveMinuteSafetyLimit, .cleaned,
             "Copied because the target changed — Cleanup left the text as heard — Stopped at the five-minute limit"),
            (.emptyRecognitionFailure(recordingEnd: .fiveMinuteSafetyLimit),
             .emptyRecognition, .fiveMinuteSafetyLimit, nil,
             "No usable text — Stopped at the five-minute limit"),
        ]
        for (outcome, expectedOutcome, end, source, classification) in cases {
            let id = DictationID()
            await boundary.record(.init(id: id, occurredAt: now, rawTranscript: nil,
                deliveredText: nil, cleanupChanged: false, outcome: outcome,
                timings: .init(finalRecognition: nil, cleanup: nil, delivery: nil, completion: nil),
                destinationApplicationIdentifier: "com.example.Editor"))
            let record = try #require(try await store.records().first { $0.id == id.rawValue })
            #expect(record.outcome == expectedOutcome)
            #expect(record.recordingEnd == end)
            #expect(record.textSource == source)
            #expect(DictationRecordPresenter.presentation(for: record).classification == classification)
        }
    }
}

private struct ClassificationKey: EncryptionKeyProviding {
    let key = SymmetricKey(size: .bits256)
    func encryptionKey() throws -> SymmetricKey { key }
    func deleteKey() throws {}
}
