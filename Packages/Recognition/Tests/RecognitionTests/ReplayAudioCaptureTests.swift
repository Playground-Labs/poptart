import AVFoundation
import DictationCore
import Testing
@testable import Recognition

struct ReplayAudioCaptureTests {
    private let sampleRate = 16_000.0
    private let frameCount: AVAudioFrameCount = 1_024

    @Test func replayArrivesAsTapSizedBuffersEndingWithAShortOne() async throws {
        let samples = (0..<2_560).map { Float($0) / 2_560 }
        let capture = ReplayAudioCapture(
            samples: samples,
            sampleRate: sampleRate,
            frameCount: frameCount,
            sleep: { _ in }
        )

        var buffers: [AVAudioPCMBuffer] = []
        for try await audio in try await capture.start() {
            buffers.append(audio.buffer)
        }

        #expect(buffers.map(\.frameLength) == [1_024, 1_024, 512])
        var replayed: [Float] = []
        for buffer in buffers {
            #expect(buffer.format.sampleRate == sampleRate)
            #expect(buffer.format.channelCount == 1)
            #expect(buffer.format.commonFormat == .pcmFormatFloat32)
            let channel = try #require(buffer.floatChannelData)
            replayed += (0..<Int(buffer.frameLength)).map { channel[0][$0 * buffer.stride] }
        }
        #expect(replayed == samples)
    }

    @Test func eachBufferWaitsForItsOwnDuration() async throws {
        let waits = WaitRecorder()
        let capture = ReplayAudioCapture(
            samples: [Float](repeating: 0, count: 2_560),
            sampleRate: sampleRate,
            frameCount: frameCount,
            sleep: { await waits.append($0) }
        )

        for try await _ in try await capture.start() {}

        // 1_024 frames at 16 kHz is 64 ms of sound, so that is what a device would spend gathering
        // the next buffer.
        let expected = Duration.seconds(1_024.0 / 16_000.0)
        let deadlines = await waits.values()
        #expect(deadlines.count == 3)
        #expect(deadlines[0].duration(to: deadlines[1]) == expected)
        #expect(deadlines[1].duration(to: deadlines[2]) == .seconds(512.0 / 16_000.0))
    }

    @Test func stoppingMidReplayEndsTheStreamWithoutAnotherBuffer() async throws {
        let capture = ReplayAudioCapture(
            samples: [Float](repeating: 0, count: 2_560),
            sampleRate: sampleRate,
            frameCount: frameCount,
            sleep: { _ in try? await Task.sleep(for: .milliseconds(10)) }
        )

        var buffers = try await capture.start().makeAsyncIterator()
        let first = try await buffers.next()
        await capture.stop()
        let afterStop = try await buffers.next()

        #expect(first?.buffer.frameLength == 1_024)
        #expect(afterStop == nil)
    }

    @Test func cancellationBeforeArrivalCompletesWithoutEmittingAudio() async throws {
        let capture = ReplayAudioCapture(samples: [0, 0], sampleRate: sampleRate,
            sleep: { _ in try? await Task.sleep(for: .seconds(30)) })
        var stream = try await capture.start().makeAsyncIterator()
        await capture.cancel()
        await capture.waitForCompletion()
        #expect(try await stream.next() == nil)
    }

    @Test func queueOverflowFailsInsteadOfSilentlyDroppingAudio() async throws {
        let capture = ReplayAudioCapture(samples: [Float](repeating: 0, count: 1024 * 97),
                                         sampleRate: sampleRate, sleep: { _ in })
        let stream = try await capture.start()
        await capture.waitForCompletion()
        await #expect(throws: RecognitionCaptureError.bufferLimitExceeded) {
            for try await _ in stream {}
        }
    }

    @Test func startingASpentReplayIsRefused() async throws {
        let capture = ReplayAudioCapture(
            samples: [Float](repeating: 0, count: 2_560),
            sampleRate: sampleRate,
            frameCount: frameCount,
            sleep: { _ in }
        )
        _ = try await capture.start()

        await #expect(throws: RecognitionCaptureError.unavailable) {
            _ = try await capture.start()
        }

        await capture.cancel()
    }
}

private actor WaitRecorder {
    private var waits: [ContinuousClock.Instant] = []
    func append(_ wait: ContinuousClock.Instant) { waits.append(wait) }
    func values() -> [ContinuousClock.Instant] { waits }
}
