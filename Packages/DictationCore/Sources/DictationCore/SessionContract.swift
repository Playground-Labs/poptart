import Foundation

public struct RecordingRequest: Equatable, Sendable {
    public let id: DictationID
    public let personalVocabulary: PersonalVocabulary

    public init(id: DictationID, personalVocabulary: PersonalVocabulary) {
        self.id = id
        self.personalVocabulary = personalVocabulary
    }
}

public struct RecognitionFinalizationRequest: Equatable, Sendable {
    public let id: DictationID
    public let deadline: MonotonicInstant

    public init(id: DictationID, deadline: MonotonicInstant) {
        self.id = id
        self.deadline = deadline
    }
}

public struct CleanupRequest: Equatable, Sendable {
    public let id: DictationID
    public let rawTranscript: RawTranscript
    public let targetContext: TargetContext
    public let personalVocabulary: PersonalVocabulary
    public let deadline: MonotonicInstant

    public init(
        id: DictationID,
        rawTranscript: RawTranscript,
        targetContext: TargetContext,
        personalVocabulary: PersonalVocabulary,
        deadline: MonotonicInstant
    ) {
        self.id = id
        self.rawTranscript = rawTranscript
        self.targetContext = targetContext
        self.personalVocabulary = personalVocabulary
        self.deadline = deadline
    }
}

public struct TargetRevalidationRequest: Equatable, Sendable {
    public let id: DictationID
    public let originalTarget: InsertionTarget

    public init(id: DictationID, originalTarget: InsertionTarget) {
        self.id = id
        self.originalTarget = originalTarget
    }
}

public struct DeliveryRequest: Equatable, Sendable {
    public let id: DictationID
    public let target: InsertionTarget
    public let text: String
    public let deadline: MonotonicInstant

    public init(id: DictationID, target: InsertionTarget, text: String, deadline: MonotonicInstant) {
        self.id = id
        self.target = target
        self.text = text
        self.deadline = deadline
    }
}

public struct ClipboardRequest: Equatable, Sendable {
    public let id: DictationID
    public let text: String
    public let deadline: MonotonicInstant

    public init(id: DictationID, text: String, deadline: MonotonicInstant) {
        self.id = id
        self.text = text
        self.deadline = deadline
    }
}

public enum IndicatorFailure: String, Equatable, Sendable {
    case noUsableText
    case recording
    case delivery
}

public enum IndicatorState: Equatable, Sendable {
    case ready
    case unavailableSecureTarget
    case recording(audioActivity: Double?)
    case approachingRecordingLimit(audioActivity: Double?)
    case finalizingRecognition
    case cleaning
    case delivering
    case success
    case rawTranscriptFallback
    case oversizedFallback
    case recognitionFallback
    case copiedBecauseTargetChanged
    case copiedBecauseNoTarget
    case failure(IndicatorFailure)
    case cancelled
}

public struct IndicatorSnapshot: Equatable, Sendable {
    public let dictationID: DictationID?
    public let state: IndicatorState

    public init(dictationID: DictationID?, state: IndicatorState) {
        self.dictationID = dictationID
        self.state = state
    }
}

public enum DictationEffect: Equatable, Sendable {
    case startRecording(RecordingRequest)
    case scheduleRecordingWarning(id: DictationID, at: MonotonicInstant)
    case scheduleRecordingLimit(id: DictationID, at: MonotonicInstant)
    case stopRecordingAndFinalize(RecognitionFinalizationRequest)
    case scheduleWatchdog(id: DictationID, at: MonotonicInstant)
    case scheduleCompletionDeadline(id: DictationID, at: MonotonicInstant)
    case requestCleanup(CleanupRequest)
    case cancelRecognition(DictationID)
    case cancelCleanup(DictationID)
    case cancelDelivery(DictationID)
    case revalidateTarget(TargetRevalidationRequest)
    case deliverToTarget(DeliveryRequest)
    case copyToClipboard(ClipboardRequest)
    case presentIndicator(IndicatorSnapshot)
    case recordHistory(DictationRecordIntent)
}

public enum DictationEvent: Equatable, Sendable {
    case press(DictationStart)
    case release(DictationID)
    case audioActivity(DictationID, Double)
    case recognitionHypothesis(DictationID, RecognitionHypothesis)
    case recordingWarningFired(DictationID)
    case recordingLimitFired(DictationID)
    case recordingFailed(DictationID, RecordingFailure)
    case recognitionCompleted(DictationID, RecognitionResult)
    case cleanupCompleted(DictationID, CleanupResult)
    case targetRevalidated(DictationID, TargetValidity)
    case deliveryCompleted(DictationID, DeliveryResult)
    case watchdogFired(DictationID)
    case completionDeadlineFired(DictationID)
    case cancel(DictationID)
    case completionPresentationElapsed(DictationID)
}

public enum DictationPhase: String, Equatable, Sendable {
    case ready
    case recording
    case finalizing
    case cleaning
    case validating
    case delivering
    case completed
}

public struct DictationSessionSnapshot: Equatable, Sendable {
    public let phase: DictationPhase
    public let activeID: DictationID?
    public let outcome: DictationOutcome?

    public init(phase: DictationPhase, activeID: DictationID?, outcome: DictationOutcome?) {
        self.phase = phase
        self.activeID = activeID
        self.outcome = outcome
    }
}
