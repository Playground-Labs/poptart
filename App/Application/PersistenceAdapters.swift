import DictationCore
import Foundation
import Persistence

public actor EncryptedHistoryBoundary: HistoryBoundary {
    private let store: HistoryStore

    public init(store: HistoryStore) {
        self.store = store
    }

    public func record(_ intent: DictationRecordIntent) async {
        guard let outcome = persistenceOutcome(for: intent.outcome) else { return }
        let record = Persistence.DictationRecord(
            id: intent.id.rawValue,
            createdAt: intent.occurredAt,
            rawTranscript: intent.rawTranscript ?? "",
            deliveredText: intent.deliveredText ?? "",
            destinationApplication: intent.destinationApplicationIdentifier,
            cleanupChangedText: intent.cleanupChanged,
            outcome: outcome,
            timings: .init(
                recognitionMilliseconds: milliseconds(intent.timings.finalRecognition),
                cleanupMilliseconds: milliseconds(intent.timings.cleanup),
                deliveryMilliseconds: milliseconds(intent.timings.delivery)
            )
        )
        try? await store.save(record)
    }

    /// Returns nil for outcomes that must never reach local history.
    private func persistenceOutcome(
        for outcome: DictationCore.DictationOutcome
    ) -> Persistence.DictationOutcome? {
        if outcome.recordingEnd == .fiveMinuteSafetyLimit { return .safetyStop }
        switch outcome {
        case .cleanedInsertion:
            return .cleaned
        case .rawTranscriptFallback:
            return .rawTranscript
        case .oversizedDeterministicFallback:
            return .oversized
        case .recognitionHypothesisFallback:
            return .recognitionHypothesis
        case .targetChangedClipboard:
            return .copiedToClipboard
        case .emptyRecognitionFailure:
            return .emptyRecognition
        case .cancelled:
            return .cancelled
        case .recordingFailure:
            return .recordingFailure
        case .deliveryFailure:
            return .deliveryFailure
        case .secureTargetRejection:
            return nil
        }
    }

    private func milliseconds(_ duration: Duration?) -> Int {
        guard let duration else { return 0 }
        let components = duration.components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000)
        guard !seconds.overflow else { return Int.max }
        let milliseconds = components.attoseconds / 1_000_000_000_000_000
        return Int(clamping: seconds.partialValue + milliseconds)
    }
}

private extension DictationCore.DictationOutcome {
    var recordingEnd: RecordingEndReason? {
        switch self {
        case .cleanedInsertion(_, let end),
             .oversizedDeterministicFallback(_, let end),
             .recognitionHypothesisFallback(_, let end),
             .targetChangedClipboard(_, let end),
             .emptyRecognitionFailure(let end),
             .deliveryFailure(_, _, let end):
            return end
        case .rawTranscriptFallback(_, _, let end):
            return end
        case .secureTargetRejection, .cancelled, .recordingFailure:
            return nil
        }
    }
}
