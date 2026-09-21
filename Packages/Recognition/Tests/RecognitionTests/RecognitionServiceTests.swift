import AVFoundation
import DictationCore
import XCTest
@testable import Recognition

final class RecognitionServiceTests: XCTestCase {
    func testRecordingStreamsAudioPublishesPartialsAndDestroysAudioAfterFinalization() async throws {
        let capture = FakeAudioCapture()
        let recognizer = FakeIncrementalRecognizer(finalization: .final("Hello Poptart."))
        let events = EventRecorder()
        let service = RecognitionService(
            capture: capture,
            recognizer: recognizer,
            onEvent: { await events.append($0) }
        )
        let id = DictationID()
        let vocabulary = PersonalVocabulary(entries: ["Poptart"])

        let start = await service.startRecording(.init(id: id, personalVocabulary: vocabulary))
        if case .failure(let failure) = start {
            XCTFail("Recording failed to start: \(failure)")
        }
        await capture.send(try audioBuffer())

        let result = await service.stopRecordingAndFinalize(.init(
            id: id,
            deadline: .init(nanoseconds: 1_000_000_000)
        ))

        XCTAssertEqual(result, .final(.init(text: "Hello Poptart.")))
        let receivedVocabulary = await recognizer.receivedVocabulary()
        let acceptedAudioCount = await recognizer.acceptedAudioCount()
        let destroyedAudio = await recognizer.didDestroyAudio()
        let recordedEvents = await events.values()
        XCTAssertEqual(receivedVocabulary, vocabulary)
        XCTAssertEqual(acceptedAudioCount, 1)
        XCTAssertTrue(destroyedAudio)
        XCTAssertEqual(
            recordedEvents,
            [
                .audioActivity(id, testLevels),
                .recognitionHypothesis(id, .init(text: "Hello Pop")),
            ]
        )
    }

    func testReplayedAudioReachesTheRecognizerAndFinalizesOnStop() async throws {
        let capture = ReplayAudioCapture(
            samples: [Float](repeating: 0, count: 2_560),
            sampleRate: 16_000,
            frameCount: 1_024,
            sleep: { _ in }
        )
        let recognizer = FakeIncrementalRecognizer(finalization: .final("Replayed words."))
        let service = RecognitionService(
            capture: capture,
            recognizer: recognizer,
            onEvent: { _ in }
        )
        let id = DictationID()

        _ = await service.startRecording(.init(
            id: id,
            personalVocabulary: .init(entries: [])
        ))
        try await service.waitForReplayCompletion()
        let result = await service.stopRecordingAndFinalize(.init(
            id: id,
            deadline: .init(nanoseconds: 1_000_000_000)
        ))

        let acceptedAudioCount = await recognizer.acceptedAudioCount()
        XCTAssertEqual(acceptedAudioCount, 3)
        XCTAssertEqual(result, .final(.init(text: "Replayed words.")))
    }

    func testCancellationStopsCaptureAndDestroysRecognizerAudio() async {
        let capture = FakeAudioCapture()
        let recognizer = FakeIncrementalRecognizer(finalization: .final("unused"))
        let service = RecognitionService(
            capture: capture,
            recognizer: recognizer,
            onEvent: { _ in }
        )
        let id = DictationID()
        _ = await service.startRecording(.init(
            id: id,
            personalVocabulary: .init(entries: [])
        ))

        await service.cancelRecognition(for: id)

        let captureCancelled = await capture.wasCancelled()
        let recognitionCancelled = await recognizer.wasCancelled()
        let destroyedAudio = await recognizer.didDestroyAudio()
        XCTAssertTrue(captureCancelled)
        XCTAssertTrue(recognitionCancelled)
        XCTAssertTrue(destroyedAudio)
    }

    func testFinalTailDeadlinePublishesLatestHypothesisAndReturnsTypedFailure() async {
        let capture = FakeAudioCapture()
        let recognizer = FakeIncrementalRecognizer(
            finalization: .deadlineFallback("Latest usable words")
        )
        let events = EventRecorder()
        let service = RecognitionService(
            capture: capture,
            recognizer: recognizer,
            onEvent: { await events.append($0) }
        )
        let id = DictationID()
        _ = await service.startRecording(.init(
            id: id,
            personalVocabulary: .init(entries: [])
        ))

        let result = await service.stopRecordingAndFinalize(.init(
            id: id,
            deadline: .init(nanoseconds: 1)
        ))

        let recordedEvents = await events.values()
        XCTAssertEqual(result, .failed(.finalizationFailed))
        XCTAssertEqual(
            recordedEvents,
            [.recognitionHypothesis(id, .init(text: "Latest usable words"))]
        )
    }

    func testCapabilitiesReportWhetherStagedCTCAssetsEnablePersonalVocabulary() async {
        let service = RecognitionService(
            capture: FakeAudioCapture(),
            recognizer: FakeIncrementalRecognizer(finalization: .final("unused")),
            onEvent: { _ in }
        )

        let capabilities = await service.capabilities()

        XCTAssertEqual(capabilities, .init(personalVocabularyAvailable: true))
    }

    func testCaptureDeviceLossIsTranslatedWithoutReturningAudioOrText() async {
        let capture = FakeAudioCapture()
        let recognizer = FakeIncrementalRecognizer(finalization: .final("must not escape"))
        let events = EventRecorder()
        let service = RecognitionService(
            capture: capture,
            recognizer: recognizer,
            onEvent: { await events.append($0) }
        )
        let id = DictationID()
        _ = await service.startRecording(.init(
            id: id,
            personalVocabulary: .init(entries: [])
        ))
        await capture.fail(.deviceLost)

        let result = await service.stopRecordingAndFinalize(.init(
            id: id,
            deadline: .init(nanoseconds: 1)
        ))

        let recordedEvents = await events.values()
        let destroyedAudio = await recognizer.didDestroyAudio()
        XCTAssertEqual(result, .failed(.unavailable))
        XCTAssertEqual(recordedEvents, [.recordingFailed(id, .deviceLost)])
        XCTAssertTrue(destroyedAudio)
    }
}

private actor EventRecorder {
    private var events: [DictationEvent] = []
    func append(_ event: DictationEvent) { events.append(event) }
    func values() -> [DictationEvent] { events }
}

private actor FakeAudioCapture: RecognitionAudioCapturing {
    private var continuation: AsyncThrowingStream<RecognitionAudioBuffer, any Error>.Continuation?
    private var cancelled = false

    func start() throws -> AsyncThrowingStream<RecognitionAudioBuffer, any Error> {
        let pair = AsyncThrowingStream<RecognitionAudioBuffer, any Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    func stop() {
        continuation?.finish()
        continuation = nil
    }

    func cancel() {
        cancelled = true
        stop()
    }

    func send(_ buffer: RecognitionAudioBuffer) {
        continuation?.yield(buffer)
    }

    func fail(_ error: RecognitionCaptureError) {
        continuation?.finish(throwing: error)
    }

    func wasCancelled() -> Bool { cancelled }
}

private actor FakeIncrementalRecognizer: IncrementalSpeechRecognizing {
    let capabilities = RecognitionCapabilities(personalVocabularyAvailable: true)
    private let finalization: IncrementalRecognitionFinalization
    private var vocabulary: PersonalVocabulary?
    private var acceptedCount = 0
    private var cancelled = false
    private var destroyed = false
    private var onPartial: (@Sendable (String) async -> Void)?

    init(finalization: IncrementalRecognitionFinalization) {
        self.finalization = finalization
    }

    func prepare() {}

    func begin(
        personalVocabulary: PersonalVocabulary,
        onPartial: @escaping @Sendable (String) async -> Void
    ) async throws {
        vocabulary = personalVocabulary
        destroyed = false
        self.onPartial = onPartial
    }

    func accept(_ buffer: RecognitionAudioBuffer) async throws {
        _ = buffer
        acceptedCount += 1
        await onPartial?("Hello Pop")
    }

    func finish(deadline: MonotonicInstant) async -> IncrementalRecognitionFinalization {
        _ = deadline
        destroyed = true
        return finalization
    }

    func cancel() {
        cancelled = true
        destroyed = true
    }

    func receivedVocabulary() -> PersonalVocabulary? { vocabulary }
    func acceptedAudioCount() -> Int { acceptedCount }
    func wasCancelled() -> Bool { cancelled }
    func didDestroyAudio() -> Bool { destroyed }
}

private let testLevels = AudioLevels(
    bands: (0..<AudioLevels.bandCount).map { Double($0) / Double(AudioLevels.bandCount) },
    overall: 0.25
)

private func audioBuffer() throws -> RecognitionAudioBuffer {
    let format = try XCTUnwrap(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    ))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
    buffer.frameLength = 160
    return .init(buffer: buffer, audioActivity: testLevels)
}
