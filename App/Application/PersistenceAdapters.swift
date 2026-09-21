import DictationCore
import CryptoKit
import Foundation
import Persistence

public func applicationKeychainService(developmentDirectory: String?) -> String {
    #if DEBUG
    if let developmentDirectory, !developmentDirectory.isEmpty {
        let path = URL(fileURLWithPath: developmentDirectory).standardizedFileURL.path
        let identity = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "labs.playground.Poptart.development.\(identity)"
    }
    #endif
    return "labs.playground.Poptart"
}

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
            fallbackReason: intent.outcome.fallbackReason,
            recordingEnd: intent.outcome.recordingEnd.map {
                $0 == .fiveMinuteSafetyLimit ? .fiveMinuteSafetyLimit : .released
            },
            textSource: intent.outcome.textSource,
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
            return .copiedTargetChanged
        case .noTargetClipboard:
            return .copiedNoTarget
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
    var textSource: Persistence.DictationTextSource? {
        switch self {
        case .cleanedInsertion: return .cleaned
        case .rawTranscriptFallback: return .rawTranscript
        case .oversizedDeterministicFallback: return .oversized
        case .recognitionHypothesisFallback: return .recognitionHypothesis
        case .targetChangedClipboard(let source, _),
             .noTargetClipboard(let source, _),
             .deliveryFailure(let source, _, _):
            switch source {
            case .cleaned: return .cleaned
            case .rawTranscriptFallback: return .rawTranscript
            case .oversizedDeterministicFallback: return .oversized
            case .recognitionHypothesisFallback: return .recognitionHypothesis
            }
        case .emptyRecognitionFailure, .secureTargetRejection, .cancelled, .recordingFailure:
            return nil
        }
    }

    var recordingEnd: RecordingEndReason? {
        switch self {
        case .cleanedInsertion(_, let end),
             .oversizedDeterministicFallback(_, let end),
             .recognitionHypothesisFallback(_, let end),
             .targetChangedClipboard(_, let end),
             .noTargetClipboard(_, let end),
             .emptyRecognitionFailure(let end),
             .deliveryFailure(_, _, let end):
            return end
        case .rawTranscriptFallback(_, _, let end):
            return end
        case .secureTargetRejection, .cancelled, .recordingFailure:
            return nil
        }
    }

    /// The Raw Transcript fallback reason, wherever the outcome carries it: as the outcome itself,
    /// or as the kind of text a copy or a failed delivery was carrying.
    var fallbackReason: Persistence.RawTranscriptFallbackReason? {
        switch self {
        case .rawTranscriptFallback(let reason, _, _):
            return reason.persisted
        case .targetChangedClipboard(let source, _),
             .noTargetClipboard(let source, _),
             .deliveryFailure(let source, _, _):
            switch source {
            case .rawTranscriptFallback(let reason):
                return reason.persisted
            case .cleaned, .oversizedDeterministicFallback, .recognitionHypothesisFallback:
                return nil
            }
        case .cleanedInsertion, .oversizedDeterministicFallback, .recognitionHypothesisFallback,
             .emptyRecognitionFailure, .secureTargetRejection, .cancelled, .recordingFailure:
            return nil
        }
    }
}

private extension DictationCore.RawTranscriptFallbackReason {
    var persisted: Persistence.RawTranscriptFallbackReason {
        switch self {
        case .cleanupTimedOut:
            return .cleanupTimedOut
        case .cleanupFailed:
            return .cleanupFailed
        case .unsafeEditPlan:
            return .unsafeEditPlan
        case .modelUnavailable:
            return .modelUnavailable
        }
    }
}
