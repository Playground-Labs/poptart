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
    func testSpeechPastTheDetectorWindowIsNotSilenced() async throws {
        let gate = SpeechGate(detector: WindowBoundSpeechDetector())
        let buffer = try chunkBuffer(marker: 0.9, frames: 4_608)
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<VadManagerChunkSampleCount { samples[index] = 0 }

        var emitted = await gate.gate(.init(buffer: buffer, audioActivity: nil)).buffers
        emitted.append(contentsOf: await gate.flush().buffers)

        XCTAssertEqual(emitted.count, 1)
        XCTAssertTrue(emitted.first === buffer)
        XCTAssertEqual(emitted.first?.floatChannelData?[0][4_096], 0.9)
    }

    func testMisalignedBuffersFormContiguousFullDetectorWindows() async throws {
        let detector = WindowBoundSpeechDetector()
        let gate = SpeechGate(detector: detector)
        let first = try chunkBuffer(marker: 0.9, frames: 4_608)
        let second = try chunkBuffer(marker: 0.4, frames: 3_584)
        var emitted = await gate.gate(.init(buffer: first, audioActivity: nil)).buffers
        let firstWindows = await detector.windows
        XCTAssertEqual(firstWindows.map(\.count), [4_096])
        emitted.append(contentsOf: await gate.gate(.init(buffer: second, audioActivity: nil)).buffers)
        emitted.append(contentsOf: await gate.flush().buffers)

        let windows = await detector.windows
        XCTAssertEqual(windows.map(\.count), [4_096, 4_096])
        XCTAssertEqual(windows.flatMap { $0 }, Array(repeating: Float(0.9), count: 4_608)
            + Array(repeating: Float(0.4), count: 3_584))
        XCTAssertEqual(emitted.count, 2)
        XCTAssertTrue(emitted.first === first)
        XCTAssertTrue(emitted.last === second)
    }

    func testResetDiscardsSuspendedDetectorResults() async throws {
        let detector = SuspendedSpeechDetector()
        let gate = SpeechGate(detector: detector)
        let audio = RecognitionAudioBuffer(buffer: try chunkBuffer(marker: 1, frames: 8_192), audioActivity: nil)
        let task = Task { await gate.gate(audio) }
        await detector.waitUntilSuspended()
        await gate.reset()
        await detector.resume()
        let canceled = await task.value
        XCTAssertTrue(canceled.buffers.isEmpty)

        let fresh = try chunkBuffer(marker: 2)
        let emitted = await gate.gate(.init(buffer: fresh, audioActivity: nil)).buffers
        XCTAssertEqual(emitted.count, 1)
        XCTAssertTrue(emitted.first === fresh)
    }

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
        #if DEBUG
        let initiallyActive = await gate.hasActiveDetector
        XCTAssertTrue(initiallyActive)
        #endif
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
        #if DEBUG
        let stillActive = await gate.hasActiveDetector
        XCTAssertFalse(stillActive)
        let absent = await SpeechGate(detector: nil).hasActiveDetector
        XCTAssertFalse(absent)
        #endif
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

    /// A 16 kHz mono buffer, one detector chunk by default, stamped with a marker
    /// value so the gate's output can be traced back to its input.
    private func chunkBuffer(marker: Float, frames: AVAudioFrameCount = 4_096) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        )
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

/// FluidAudio's detector ignores samples beyond its fixed model input window.
private actor WindowBoundSpeechDetector: SpeechDetecting {
    private(set) var windows: [[Float]] = []
    func speechProbability(for samples: [Float]) async throws -> Float {
        windows.append(samples)
        return samples.prefix(VadManagerChunkSampleCount).max() ?? 0
    }
    func reset() {}
}

private actor SuspendedSpeechDetector: SpeechDetecting {
    private var started = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var suspended: CheckedContinuation<Float, Never>?

    func speechProbability(for samples: [Float]) async throws -> Float {
        guard !started else { return 1 }
        started = true
        waiting?.resume()
        waiting = nil
        return await withCheckedContinuation { suspended = $0 }
    }
    func waitUntilSuspended() async {
        if !started { await withCheckedContinuation { waiting = $0 } }
    }
    func resume() {
        suspended?.resume(returning: 1)
        suspended = nil
    }
    func reset() {}
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
