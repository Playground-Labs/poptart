import Foundation

public struct DictationID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct TextSelection: Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        precondition(location >= 0)
        precondition(length >= 0)
        self.location = location
        self.length = length
    }
}

public struct InsertionTarget: Equatable, Sendable {
    public let applicationIdentifier: String
    public let elementIdentifier: String
    public let selection: TextSelection?

    public init(
        applicationIdentifier: String,
        elementIdentifier: String,
        selection: TextSelection?
    ) {
        self.applicationIdentifier = applicationIdentifier
        self.elementIdentifier = elementIdentifier
        self.selection = selection
    }
}

public enum ApplicationCategory: String, Equatable, Sendable {
    case textEditor
    case messaging
    case email
    case browser
    case other
}

public struct TargetContext: Equatable, Sendable {
    public let applicationIdentifier: String
    public let applicationCategory: ApplicationCategory
    public let textBeforeCursor: String
    public let textAfterCursor: String
    public let selectedText: String?

    public init(
        applicationIdentifier: String,
        applicationCategory: ApplicationCategory,
        textBeforeCursor: String,
        textAfterCursor: String,
        selectedText: String?
    ) {
        self.applicationIdentifier = applicationIdentifier
        self.applicationCategory = applicationCategory
        self.textBeforeCursor = textBeforeCursor
        self.textAfterCursor = textAfterCursor
        self.selectedText = selectedText
    }
}

public struct PersonalVocabulary: Equatable, Sendable {
    public let entries: [String]

    public init(entries: [String]) {
        self.entries = entries
    }
}

public struct DictationStart: Equatable, Sendable {
    public let id: DictationID
    public let occurredAt: Date
    public let targetCapture: DictationTargetCapture
    public let personalVocabulary: PersonalVocabulary

    public init(
        id: DictationID,
        occurredAt: Date,
        target: InsertionTarget,
        targetContext: TargetContext,
        personalVocabulary: PersonalVocabulary
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.targetCapture = .editable(target: target, context: targetContext)
        self.personalVocabulary = personalVocabulary
    }

    public init(
        noTargetID id: DictationID,
        occurredAt: Date,
        targetContext: TargetContext,
        personalVocabulary: PersonalVocabulary
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.targetCapture = .noTarget(context: targetContext)
        self.personalVocabulary = personalVocabulary
    }

    public init(
        secureTargetID id: DictationID,
        occurredAt: Date,
        applicationIdentifier: String,
        elementIdentifier: String
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.targetCapture = .secure(
            applicationIdentifier: applicationIdentifier,
            elementIdentifier: elementIdentifier
        )
        self.personalVocabulary = .init(entries: [])
    }
}

public enum DictationTargetCapture: Equatable, Sendable {
    case editable(target: InsertionTarget, context: TargetContext)
    case noTarget(context: TargetContext)
    case secure(applicationIdentifier: String, elementIdentifier: String)
}

public struct RawTranscript: Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct RecognitionHypothesis: Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    public var isUsable: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum RecognitionFailure: String, Error, Equatable, Sendable {
    case unavailable
    case finalizationFailed
    case cancelled
}

public enum RecognitionResult: Equatable, Sendable {
    case final(RawTranscript)
    case failed(RecognitionFailure)
}

public struct CleanupMetadata: Equatable, Sendable {
    public let changed: Bool
    public let editCount: Int

    public init(changed: Bool, editCount: Int) {
        precondition(editCount >= 0)
        self.changed = changed
        self.editCount = editCount
    }
}

public struct CleanupOutput: Equatable, Sendable {
    public let text: String
    public let metadata: CleanupMetadata

    public init(text: String, metadata: CleanupMetadata) {
        self.text = text
        self.metadata = metadata
    }
}

public enum RawTranscriptFallbackReason: String, Equatable, Sendable {
    case cleanupTimedOut
    case cleanupFailed
    case unsafeEditPlan
    case modelUnavailable
}

public enum CleanupResult: Equatable, Sendable {
    case cleaned(CleanupOutput)
    case rawTranscriptFallback(RawTranscriptFallbackReason)
    case oversizedDeterministic(CleanupOutput)
}

/// What the microphone hears at one instant: how loud the sound is overall, and how that sound is
/// spread across the speech range. `bands` runs from the lowest band to the highest, each value a
/// normalised 0...1 magnitude, so the Indicator can draw the shape of a voice rather than one
/// number repeated twenty-one times. Ephemeral display data; never persist or log these values.
public struct AudioLevels: Equatable, Sendable {
    public static let bandCount = 21

    public let bands: [Double]
    public let overall: Double

    public init(bands: [Double], overall: Double) {
        precondition(bands.count == Self.bandCount)
        self.bands = bands.map { $0.isFinite ? min(max($0, 0), 1) : 0 }
        self.overall = overall.isFinite ? min(max(overall, 0), 1) : 0
    }

    /// The level of a microphone that is open but hearing nothing.
    public static let silent = AudioLevels(
        bands: Array(repeating: 0, count: bandCount),
        overall: 0
    )
}

public enum RecordingEndReason: String, Equatable, Sendable {
    case released
    case fiveMinuteSafetyLimit
}

public enum DeliveryMethod: String, Equatable, Sendable {
    case accessibility
    case clipboardPaste
}

public enum TargetValidity: Equatable, Sendable {
    case valid
    case changed
}

public enum DeliveryFailure: String, Error, Equatable, Sendable {
    case accessibilityAndPasteFailed
    case pasteTimedOut
    case clipboardOwnershipChanged
    case clipboardWriteFailed
    case completionDeadlineExceeded
    /// The session gave up on this delivery before it reached the clipboard or the target.
    case cancelled
}

public enum DeliveryResult: Equatable, Sendable {
    case inserted(DeliveryMethod)
    case copiedToClipboard
    case copiedAfterTargetChanged
    case failed(DeliveryFailure)
}

public enum RecordingFailure: String, Error, Equatable, Sendable {
    case permissionLost
    case deviceLost
    case captureFailed
}

public enum DeliveredTextKind: Equatable, Sendable {
    case cleaned
    case rawTranscriptFallback(RawTranscriptFallbackReason)
    case oversizedDeterministicFallback
    case recognitionHypothesisFallback
}

public enum DictationOutcome: Equatable, Sendable {
    case cleanedInsertion(method: DeliveryMethod, recordingEnd: RecordingEndReason)
    case rawTranscriptFallback(
        reason: RawTranscriptFallbackReason,
        method: DeliveryMethod,
        recordingEnd: RecordingEndReason
    )
    case oversizedDeterministicFallback(method: DeliveryMethod, recordingEnd: RecordingEndReason)
    case recognitionHypothesisFallback(method: DeliveryMethod, recordingEnd: RecordingEndReason)
    case targetChangedClipboard(source: DeliveredTextKind, recordingEnd: RecordingEndReason)
    case noTargetClipboard(source: DeliveredTextKind, recordingEnd: RecordingEndReason)
    case emptyRecognitionFailure(recordingEnd: RecordingEndReason)
    case secureTargetRejection
    case cancelled
    case recordingFailure(RecordingFailure)
    case deliveryFailure(
        source: DeliveredTextKind,
        reason: DeliveryFailure,
        recordingEnd: RecordingEndReason
    )
}

public struct DictationTimings: Equatable, Sendable {
    public let finalRecognition: Duration?
    public let cleanup: Duration?
    public let delivery: Duration?
    public let completion: Duration?

    public init(
        finalRecognition: Duration?,
        cleanup: Duration?,
        delivery: Duration?,
        completion: Duration?
    ) {
        self.finalRecognition = finalRecognition
        self.cleanup = cleanup
        self.delivery = delivery
        self.completion = completion
    }
}

public struct DictationRecordIntent: Equatable, Sendable {
    public let id: DictationID
    public let occurredAt: Date
    public let rawTranscript: String?
    public let deliveredText: String?
    public let cleanupChanged: Bool
    public let outcome: DictationOutcome
    public let timings: DictationTimings
    public let destinationApplicationIdentifier: String

    public init(
        id: DictationID,
        occurredAt: Date,
        rawTranscript: String?,
        deliveredText: String?,
        cleanupChanged: Bool,
        outcome: DictationOutcome,
        timings: DictationTimings,
        destinationApplicationIdentifier: String
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.rawTranscript = rawTranscript
        self.deliveredText = deliveredText
        self.cleanupChanged = cleanupChanged
        self.outcome = outcome
        self.timings = timings
        self.destinationApplicationIdentifier = destinationApplicationIdentifier
    }
}
