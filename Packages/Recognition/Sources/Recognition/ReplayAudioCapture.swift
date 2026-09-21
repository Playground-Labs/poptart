@preconcurrency import AVFoundation
import DictationCore
import Foundation

/// Replays already-decoded samples in place of a microphone, one tap-sized chunk at a time and at
/// the pace a device would deliver them, so a benchmark measures the pipeline a Dictation runs
/// rather than how fast the recognizer can swallow a whole recording at once.
///
/// Delivery ends when the samples run out, the way a microphone that has gone quiet simply stops
/// carrying speech. Ending the recording stays the service's job, as it is with a device.
actor ReplayAudioCapture: RecognitionAudioCapturing {
    private let samples: [Float]
    private let sampleRate: Double
    private let frameCount: AVAudioFrameCount
    private let sleep: @Sendable (ContinuousClock.Instant) async -> Void
    private var continuation: AsyncThrowingStream<RecognitionAudioBuffer, any Error>.Continuation?
    private var delivery: Task<Void, Never>?
    private var hasStarted = false

    init(
        samples: [Float],
        sampleRate: Double,
        frameCount: AVAudioFrameCount = 1_024,
        sleep: @escaping @Sendable (ContinuousClock.Instant) async -> Void = {
            try? await ContinuousClock().sleep(until: $0)
        }
    ) {
        precondition(sampleRate > 0)
        precondition(frameCount > 0)
        self.samples = samples
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.sleep = sleep
    }

    /// A replay is spent once it has been started, so a second start is refused the way a second
    /// tap on one input would be.
    func start() throws -> AsyncThrowingStream<RecognitionAudioBuffer, any Error> {
        guard !hasStarted else { throw RecognitionCaptureError.unavailable }
        hasStarted = true

        // Match the live capture queue: overload must fail rather than silently buffering more audio.
        let pair = AsyncThrowingStream<RecognitionAudioBuffer, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(96)
        )
        let streamContinuation = pair.continuation
        continuation = streamContinuation
        let samples = samples
        let sampleRate = sampleRate
        let chunkSize = Int(frameCount)
        let sleep = sleep
        delivery = Task.detached {
            // Every way out of the walk ends the stream, including the ones stop() already ended;
            // a second finish is ignored, an unfinished stream would hang the recording.
            defer { streamContinuation.finish() }
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                streamContinuation.finish(throwing: RecognitionCaptureError.unavailable)
                return
            }
            let analyzer = SpeechBandAnalyzer(frameCount: chunkSize)
            let began = ContinuousClock.now
            var index = 0
            while index < samples.count {
                if Task.isCancelled { return }
                let end = min(index + chunkSize, samples.count)
                do {
                    let buffer = try Self.buffer(
                        from: samples[index..<end],
                        format: format,
                        analyzer: analyzer
                    )
                    await sleep(began.advanced(by: .seconds(Double(end) / sampleRate)))
                    try Task.checkCancellation()
                    switch streamContinuation.yield(buffer) {
                    case .enqueued: break
                    case .terminated: return
                    case .dropped:
                        throw RecognitionCaptureError.bufferLimitExceeded
                    @unknown default:
                        throw RecognitionCaptureError.bufferLimitExceeded
                    }
                } catch {
                    streamContinuation.finish(throwing: error)
                    return
                }
                index = end
            }
        }
        return pair.stream
    }

    func waitForCompletion() async {
        await delivery?.value
    }

    func stop() {
        finishReplay()
    }

    func cancel() {
        finishReplay()
    }

    private func finishReplay() {
        delivery?.cancel()
        delivery = nil
        continuation?.finish()
        continuation = nil
    }

    /// Shapes one slice of the replay the way a capture tap shapes a frame of live audio: a mono
    /// float buffer at the replay's rate, whose trailing chunk is as short as the samples left.
    private nonisolated static func buffer(
        from samples: ArraySlice<Float>,
        format: AVAudioFormat,
        analyzer: SpeechBandAnalyzer?
    ) throws -> RecognitionAudioBuffer {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData
        else { throw RecognitionCaptureError.unavailable }
        buffer.frameLength = buffer.frameCapacity
        _ = UnsafeMutableBufferPointer(start: channel[0], count: samples.count)
            .update(fromContentsOf: samples)
        // Handing it through the tap's own copy step meters the Indicator from a replay exactly as
        // it is metered from a device, instead of keeping a second opinion of the same math here.
        return try AVAudioEngineCapture.copy(buffer, analyzer: analyzer)
    }
}
