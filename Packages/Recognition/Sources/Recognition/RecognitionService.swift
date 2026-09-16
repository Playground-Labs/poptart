import DictationCore
import Foundation

public actor RecognitionService: SpeechInputBoundary {
    public typealias EventHandler = @Sendable (DictationEvent) async -> Void

    private struct ActiveRecording {
        let id: DictationID
        let processing: Task<RecognitionFailure?, Never>
    }

    private let capture: any RecognitionAudioCapturing
    private let recognizer: any IncrementalSpeechRecognizing
    private let onEvent: EventHandler
    private var active: ActiveRecording?
    private var currentID: DictationID?

    init(
        capture: any RecognitionAudioCapturing,
        recognizer: any IncrementalSpeechRecognizing,
        onEvent: @escaping EventHandler
    ) {
        self.capture = capture
        self.recognizer = recognizer
        self.onEvent = onEvent
    }

    public init(
        modelLayout: RecognitionModelLayout,
        clock: any MonotonicClock = UptimeMonotonicClock(),
        onEvent: @escaping EventHandler
    ) throws {
        _ = try RecognitionModelValidator.validate(modelLayout)
        self.capture = AVAudioEngineCapture()
        self.recognizer = FluidAudioIncrementalRecognizer(
            modelLayout: modelLayout,
            clock: clock
        )
        self.onEvent = onEvent
    }

    /// Loads the staged local models before the first Dictation.
    public func prepare() async throws {
        try await recognizer.prepare()
    }

    public func capabilities() async -> RecognitionCapabilities {
        await recognizer.capabilities
    }

    public func startRecording(
        _ request: RecordingRequest
    ) async -> Result<Void, RecordingFailure> {
        guard currentID == nil else { return .failure(.captureFailed) }
        currentID = request.id
        do {
            try await recognizer.begin(
                personalVocabulary: request.personalVocabulary,
                onPartial: { [weak self] text in
                    await self?.publishHypothesis(text, for: request.id)
                }
            )
            guard currentID == request.id else { return .failure(.captureFailed) }
            let stream = try await capture.start()
            guard currentID == request.id else {
                await capture.cancel()
                return .failure(.captureFailed)
            }
            let capture = capture
            let recognizer = recognizer
            let onEvent = onEvent
            let id = request.id
            let processing = Task<RecognitionFailure?, Never> {
                do {
                    for try await audio in stream {
                        try Task.checkCancellation()
                        if let levels = audio.audioActivity {
                            await onEvent(.audioActivity(id, levels))
                        }
                        try await recognizer.accept(audio)
                    }
                    return nil
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    await capture.cancel()
                    await recognizer.cancel()
                    await onEvent(.recordingFailed(id, Self.recordingFailure(for: error)))
                    return .unavailable
                }
            }
            active = .init(id: request.id, processing: processing)
            return .success(())
        } catch {
            if currentID == request.id { currentID = nil }
            await capture.cancel()
            await recognizer.cancel()
            return .failure(Self.recordingFailure(for: error))
        }
    }

    public func stopRecordingAndFinalize(
        _ request: RecognitionFinalizationRequest
    ) async -> RecognitionResult {
        guard let recording = active, recording.id == request.id else {
            return .failed(.unavailable)
        }
        await capture.stop()
        let processingFailure = await recording.processing.value
        if let processingFailure {
            active = nil
            currentID = nil
            return .failed(processingFailure)
        }

        let finalization = await recognizer.finish(deadline: request.deadline)
        guard currentID == request.id else { return .failed(.cancelled) }
        active = nil
        currentID = nil
        switch finalization {
        case .final(let text):
            return .final(.init(text: text))
        case .deadlineFallback(let text):
            if let text {
                await publishHypothesis(text, for: request.id, allowInactive: true)
            }
            return .failed(.finalizationFailed)
        case .failed(let failure):
            return .failed(failure)
        }
    }

    public func cancelRecognition(for id: DictationID) async {
        guard currentID == id else { return }
        currentID = nil
        let recording = active
        active = nil
        recording?.processing.cancel()
        await capture.cancel()
        await recognizer.cancel()
        if let recording { _ = await recording.processing.value }
    }

    private func publishHypothesis(
        _ text: String,
        for id: DictationID,
        allowInactive: Bool = false
    ) async {
        guard allowInactive || currentID == id else { return }
        let hypothesis = RecognitionHypothesis(text: text)
        guard hypothesis.isUsable else { return }
        await onEvent(.recognitionHypothesis(id, hypothesis))
    }

    private static func recordingFailure(for error: any Error) -> RecordingFailure {
        guard let captureError = error as? RecognitionCaptureError else {
            return .captureFailed
        }
        switch captureError {
        case .deviceLost:
            return .deviceLost
        case .unavailable, .bufferLimitExceeded:
            return .captureFailed
        }
    }
}
