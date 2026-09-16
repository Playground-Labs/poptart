@preconcurrency import AVFoundation
import DictationCore
import Foundation

public struct RecognitionCapabilities: Equatable, Sendable {
    public let personalVocabularyAvailable: Bool

    public init(personalVocabularyAvailable: Bool) {
        self.personalVocabularyAvailable = personalVocabularyAvailable
    }
}

/// An immutable, package-internal copy of an AVFoundation capture buffer.
struct RecognitionAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let audioActivity: AudioLevels?

    init(buffer: AVAudioPCMBuffer, audioActivity: AudioLevels?) {
        self.buffer = buffer
        self.audioActivity = audioActivity
    }
}

enum RecognitionCaptureError: Error, Equatable, Sendable {
    case unavailable
    case bufferLimitExceeded
    case deviceLost
}

protocol RecognitionAudioCapturing: Actor {
    func start() throws -> AsyncThrowingStream<RecognitionAudioBuffer, any Error>
    func stop()
    func cancel()
}

enum IncrementalRecognitionFinalization: Equatable, Sendable {
    case final(String)
    case deadlineFallback(String?)
    case failed(RecognitionFailure)
}

protocol IncrementalSpeechRecognizing: Actor {
    var capabilities: RecognitionCapabilities { get }

    func prepare() async throws
    func begin(
        personalVocabulary: PersonalVocabulary,
        onPartial: @escaping @Sendable (String) async -> Void
    ) async throws
    func accept(_ buffer: RecognitionAudioBuffer) async throws
    func finish(deadline: MonotonicInstant) async -> IncrementalRecognitionFinalization
    func cancel() async
}
