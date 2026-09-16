@preconcurrency import AVFoundation
import DictationCore
import Foundation

actor AVAudioEngineCapture: RecognitionAudioCapturing {
    private let engine: AVAudioEngine
    private let tapBufferSize: AVAudioFrameCount
    private let maxQueuedBuffers: Int
    private var continuation: AsyncThrowingStream<RecognitionAudioBuffer, any Error>.Continuation?
    private var configurationObserver: NSObjectProtocol?
    private var hasTap = false

    init(
        engine: AVAudioEngine = AVAudioEngine(),
        tapBufferSize: AVAudioFrameCount = 1_024,
        maxQueuedBuffers: Int = 96
    ) {
        precondition(tapBufferSize > 0)
        precondition(maxQueuedBuffers > 0)
        self.engine = engine
        self.tapBufferSize = tapBufferSize
        self.maxQueuedBuffers = maxQueuedBuffers
    }

    func start() throws -> AsyncThrowingStream<RecognitionAudioBuffer, any Error> {
        guard continuation == nil else { throw RecognitionCaptureError.unavailable }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecognitionCaptureError.unavailable
        }

        let pair = AsyncThrowingStream<RecognitionAudioBuffer, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(maxQueuedBuffers)
        )
        let streamContinuation = pair.continuation
        // The Indicator is fed from here, ahead of the speech gate, because it reports what the
        // microphone hears rather than what the recognizer is given. Gated audio arrives a third of
        // a second late, which a live meter cannot hide.
        let analyzer = SpeechBandAnalyzer(frameCount: Int(tapBufferSize))
        input.installTap(onBus: 0, bufferSize: tapBufferSize, format: nil) { buffer, _ in
            do {
                let immutableCopy = try Self.copy(buffer, analyzer: analyzer)
                switch streamContinuation.yield(immutableCopy) {
                case .enqueued:
                    break
                case .dropped:
                    streamContinuation.finish(
                        throwing: RecognitionCaptureError.bufferLimitExceeded
                    )
                case .terminated:
                    break
                @unknown default:
                    streamContinuation.finish(
                        throwing: RecognitionCaptureError.bufferLimitExceeded
                    )
                }
            } catch {
                streamContinuation.finish(throwing: error)
            }
        }
        hasTap = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            hasTap = false
            streamContinuation.finish(throwing: RecognitionCaptureError.unavailable)
            throw RecognitionCaptureError.unavailable
        }

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.failBecauseDeviceChanged() }
        }
        continuation = streamContinuation
        return pair.stream
    }

    func stop() {
        finishCapture(throwing: nil)
    }

    func cancel() {
        finishCapture(throwing: nil)
    }

    private func failBecauseDeviceChanged() {
        finishCapture(throwing: RecognitionCaptureError.deviceLost)
    }

    private func finishCapture(throwing error: (any Error)?) {
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        engine.stop()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
        continuation = nil
    }

    nonisolated static func copy(
        _ source: AVAudioPCMBuffer,
        analyzer: SpeechBandAnalyzer?
    ) throws -> RecognitionAudioBuffer {
        guard let destination = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else {
            throw RecognitionCaptureError.unavailable
        }
        destination.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else {
            throw RecognitionCaptureError.unavailable
        }
        for index in sourceBuffers.indices {
            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData
            else {
                throw RecognitionCaptureError.unavailable
            }
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }
        return .init(
            buffer: destination,
            audioActivity: audioActivity(in: destination, analyzer: analyzer)
        )
    }

    private nonisolated static func audioActivity(
        in buffer: AVAudioPCMBuffer,
        analyzer: SpeechBandAnalyzer?
    ) -> AudioLevels? {
        guard let analyzer,
              let channels = buffer.floatChannelData,
              buffer.format.channelCount > 0,
              buffer.frameLength > 0
        else { return nil }
        let samples = stride(
            from: 0, to: Int(buffer.frameLength) * buffer.stride, by: buffer.stride
        ).map { channels[0][$0] }
        return analyzer.levels(of: samples, sampleRate: buffer.format.sampleRate)
    }
}
