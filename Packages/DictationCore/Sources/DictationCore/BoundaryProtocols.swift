import Foundation

/// Captures only the bounded, ephemeral information required to begin a Dictation.
public protocol InsertionTargetBoundary: Sendable {
    func captureTarget(for id: DictationID) async -> Result<DictationTargetCapture, TargetCaptureFailure>
    func revalidateTarget(_ request: TargetRevalidationRequest) async -> TargetValidity
}

public enum TargetCaptureFailure: String, Error, Equatable, Sendable {
    case noEditableTarget
    case permissionDenied
    case unavailable
}

public protocol SpeechInputBoundary: Sendable {
    func startRecording(_ request: RecordingRequest) async -> Result<Void, RecordingFailure>
    func stopRecordingAndFinalize(_ request: RecognitionFinalizationRequest) async -> RecognitionResult
    func cancelRecognition(for id: DictationID) async
}

public protocol CleanupBoundary: Sendable {
    func clean(_ request: CleanupRequest) async -> CleanupResult
    func cancelCleanup(for id: DictationID) async
}

public protocol TextDeliveryBoundary: Sendable {
    func deliver(_ request: DeliveryRequest) async -> DeliveryResult
    func copyToClipboard(_ request: ClipboardRequest) async -> DeliveryResult
    func cancelDelivery(for id: DictationID) async
}

public protocol IndicatorBoundary: Sendable {
    func present(_ snapshot: IndicatorSnapshot) async
}

public protocol HistoryBoundary: Sendable {
    func record(_ intent: DictationRecordIntent) async
}

public enum DictationDeadlineKind: String, Equatable, Sendable {
    case recordingWarning
    case recordingLimit
    case watchdog
    case completion
}

/// Schedules a transcript-free timer signal against monotonic time.
public protocol DictationDeadlineBoundary: Sendable {
    func schedule(
        _ kind: DictationDeadlineKind,
        for id: DictationID,
        at instant: MonotonicInstant
    ) async
}
