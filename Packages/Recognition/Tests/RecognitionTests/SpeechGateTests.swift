import AVFoundation
import XCTest
@testable import Recognition

final class SpeechGatePolicyTests: XCTestCase {
    func testSpeechAfterSilenceReleasesTheHeldPreRollChunk() {
        var policy = SpeechGatePolicy()

        XCTAssertEqual(policy.admit(.nonSpeech), [])
        XCTAssertEqual(policy.admit(.nonSpeech), [.silence])
        // The chunk immediately before the detected speech is released intact alongside it, so
        // the onset the detector was too slow to score is not lost.
        XCTAssertEqual(policy.admit(.speech), [.pass, .pass])
    }

    func testSustainedSilenceEmitsSilence() {
        var policy = SpeechGatePolicy()

        XCTAssertEqual(policy.admit(.nonSpeech), [])
        for _ in 0..<8 {
            XCTAssertEqual(policy.admit(.nonSpeech), [.silence])
        }
        XCTAssertEqual(policy.flush(), [.silence])
    }

    func testSustainedSpeechPassesThrough() {
        var policy = SpeechGatePolicy()

        XCTAssertEqual(policy.admit(.speech), [.pass])
        for _ in 0..<8 {
            XCTAssertEqual(policy.admit(.speech), [.pass])
        }
        XCTAssertEqual(policy.flush(), [])
    }

    func testALoneNonSpeechChunkBetweenSpeechDoesNotTruncateTheUtterance() {
        var policy = SpeechGatePolicy()

        XCTAssertEqual(policy.admit(.speech), [.pass])
        XCTAssertEqual(policy.admit(.nonSpeech), [.pass])
        XCTAssertEqual(policy.admit(.speech), [.pass])
    }

    func testNoAudioIsStrandedWhenCaptureEndsInsideAnUtterance() {
        var policy = SpeechGatePolicy()

        XCTAssertEqual(policy.admit(.speech), [.pass])
        XCTAssertEqual(policy.admit(.nonSpeech), [.pass])
        // Speech and hangover both release as they go, so the gate is holding nothing.
        XCTAssertEqual(policy.flush(), [])
    }
}

final class SpeechGateTests: XCTestCase {
    func testTheFirstChunkOfSpeechIsNotClipped() async throws {
        let detector = ScriptedSpeechDetector([0, 0, 0.99, 0.99])
        let gate = SpeechGate(detector: detector)
        let chunks = try (1...4).map { try chunkBuffer(marker: Float($0)) }
        let captured = chunks.map { RecognitionAudioBuffer(buffer: $0, audioActivity: nil) }

        var emitted: [AVAudioPCMBuffer] = []
        for chunk in captured {
            emitted.append(contentsOf: await gate.gate(chunk).buffers)
        }
        emitted.append(contentsOf: await gate.flush().buffers)

        // Chunk 2 is the pre-roll: the detector only scored speech on chunk 3, but chunk 2 holds
        // the onset of the first word and must reach the recognizer untouched.
        XCTAssertEqual(markers(of: emitted), [0, 2, 3, 4])
    }

    func testAGateWithoutAModelPassesAudioThroughByteIdentically() async throws {
        let gate = SpeechGate(detector: nil)
        let chunks = try (1...4).map { try chunkBuffer(marker: Float($0)) }
        let captured = chunks.map { RecognitionAudioBuffer(buffer: $0, audioActivity: nil) }

        var emitted: [AVAudioPCMBuffer] = []
        for chunk in captured {
            emitted.append(contentsOf: await gate.gate(chunk).buffers)
        }
        emitted.append(contentsOf: await gate.flush().buffers)

        XCTAssertEqual(emitted.count, chunks.count)
        for (produced, original) in zip(emitted, chunks) {
            XCTAssertTrue(produced === original)
        }
        XCTAssertEqual(markers(of: emitted), [1, 2, 3, 4])
    }

    func testAGateWhoseDetectorThrowsPassesAudioThroughByteIdentically() async throws {
        let gate = SpeechGate(detector: ThrowingSpeechDetector())
        let chunks = try (1...4).map { try chunkBuffer(marker: Float($0)) }
        let captured = chunks.map { RecognitionAudioBuffer(buffer: $0, audioActivity: nil) }

        var emitted: [AVAudioPCMBuffer] = []
        for chunk in captured {
            emitted.append(contentsOf: await gate.gate(chunk).buffers)
        }
        emitted.append(contentsOf: await gate.flush().buffers)

        XCTAssertEqual(emitted.count, chunks.count)
        for (produced, original) in zip(emitted, chunks) {
            XCTAssertTrue(produced === original)
        }
        XCTAssertEqual(markers(of: emitted), [1, 2, 3, 4])
    }

    func testSustainedNoiseReachesTheRecognizerAsSilence() async throws {
        let detector = ScriptedSpeechDetector([0, 0, 0, 0])
        let gate = SpeechGate(detector: detector)
        let chunks = try (1...4).map { try chunkBuffer(marker: Float($0)) }
        let captured = chunks.map { RecognitionAudioBuffer(buffer: $0, audioActivity: nil) }

        var emitted: [AVAudioPCMBuffer] = []
        for chunk in captured {
            emitted.append(contentsOf: await gate.gate(chunk).buffers)
        }
        emitted.append(contentsOf: await gate.flush().buffers)

        // Every chunk still arrives — zeroed, never dropped, so the timeline stays intact.
        XCTAssertEqual(emitted.count, chunks.count)
        XCTAssertEqual(markers(of: emitted), [0, 0, 0, 0])
    }

    /// One buffer holding exactly one detector chunk of 16 kHz mono audio, stamped with a marker
    /// value so the gate's output can be traced back to its input.
    private func chunkBuffer(marker: Float) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        )
        let frames = AVAudioFrameCount(VadManagerChunkSampleCount)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        )
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<Int(frames) {
            samples[index] = marker
        }
        return buffer
    }

    private func markers(of buffers: [AVAudioPCMBuffer]) -> [Float] {
        buffers.map { $0.floatChannelData?[0][0] ?? .nan }
    }
}

/// Mirrors `VadManager.chunkSize` without importing FluidAudio into the test target.
private let VadManagerChunkSampleCount = 4_096

private actor ScriptedSpeechDetector: SpeechDetecting {
    private var probabilities: [Float]

    init(_ probabilities: [Float]) {
        self.probabilities = probabilities
    }

    func speechProbability(for samples: [Float]) async throws -> Float {
        probabilities.isEmpty ? 0 : probabilities.removeFirst()
    }

    func reset() {}
}

private actor ThrowingSpeechDetector: SpeechDetecting {
    private struct Failure: Error {}

    func speechProbability(for samples: [Float]) async throws -> Float {
        throw Failure()
    }

    func reset() {}
}
