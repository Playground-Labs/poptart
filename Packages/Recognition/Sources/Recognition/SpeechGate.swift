@preconcurrency import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Buffers on their way back out of the gate's actor. Unchecked for the same reason
/// `RecognitionAudioBuffer` is: AVFoundation's buffers are not `Sendable`, and the gate never
/// touches one again once it has released it.
struct GatedAudio: @unchecked Sendable {
    let buffers: [AVAudioPCMBuffer]
}

/// The single question the gate asks a voice activity detector.
protocol SpeechDetecting: Actor {
    func speechProbability(for samples: [Float]) async throws -> Float
    func reset()
}

/// Thin adapter over FluidAudio's Silero VAD. It carries the streaming model state so each verdict
/// is informed by the chunks before it.
actor FluidAudioSpeechDetector: SpeechDetecting {
    private let manager: VadManager
    private var state = VadStreamState.initial()

    init(manager: VadManager) {
        self.manager = manager
    }

    func speechProbability(for samples: [Float]) async throws -> Float {
        let result = try await manager.processStreamingChunk(samples, state: state)
        state = result.state
        return result.probability
    }

    func reset() {
        state = .initial()
    }
}

/// Replaces non-speech audio with silence on its way to the recognizer, so fans, keyboards and
/// background noise are not hallucinated into words.
///
/// Failing open is structural rather than incidental: a gate holds a detector or it holds nothing,
/// and a gate holding nothing is a pass-through with no code path that can withhold audio. Any
/// runtime failure discards the detector for the rest of the recording, which turns the gate into
/// exactly that pass-through. A person's dictation is never lost because noise rejection broke
/// (ADR 0005).
actor SpeechGate {
    /// The detector scores a fixed 256 ms window, so captured buffers — which are far shorter —
    /// are batched until the gate holds at least that much audio before it asks for a verdict.
    private static let chunkSampleCount = VadManager.chunkSize

    private let converter = AudioConverter()
    private var detector: (any SpeechDetecting)?
    private var policy = SpeechGatePolicy()
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var pendingSamples: [Float] = []
    private var heldChunks: [[AVAudioPCMBuffer]] = []

    init(detector: (any SpeechDetecting)?) {
        self.detector = detector
    }

    /// Builds a gating gate when the pack ships a voice activity model that loads, and a
    /// pass-through gate in every other case.
    static func make(modelDirectory: URL?) async -> SpeechGate {
        guard let modelDirectory else { return SpeechGate(detector: nil) }
        let bundle = modelDirectory.appendingPathComponent(
            RecognitionModelLayout.vadModelBundleName,
            isDirectory: true
        )
        let configuration = MLModelConfiguration()
        configuration.computeUnits = VadConfig.default.computeUnits
        guard let model = try? MLModel(contentsOf: bundle, configuration: configuration) else {
            return SpeechGate(detector: nil)
        }
        let manager = VadManager(config: .default, vadModel: model)
        return SpeechGate(detector: FluidAudioSpeechDetector(manager: manager))
    }

    func reset() async {
        policy = SpeechGatePolicy()
        pendingBuffers.removeAll()
        pendingSamples.removeAll()
        heldChunks.removeAll()
        await detector?.reset()
    }

    /// Returns the buffers the recognizer should receive for this captured buffer: none while the
    /// gate is still filling a chunk, and one or more chunks' worth once a verdict lands.
    func gate(_ audio: RecognitionAudioBuffer) async -> GatedAudio {
        guard let detector else { return .init(buffers: [audio.buffer]) }
        pendingBuffers.append(audio.buffer)
        guard let samples = try? converter.resampleBuffer(audio.buffer) else { return failOpen() }
        pendingSamples.append(contentsOf: samples)
        guard pendingSamples.count >= Self.chunkSampleCount else { return .init(buffers: []) }

        guard let probability = try? await detector.speechProbability(for: pendingSamples) else {
            return failOpen()
        }
        heldChunks.append(pendingBuffers)
        pendingBuffers.removeAll()
        pendingSamples.removeAll()
        let decision: SpeechGateDecision =
            probability >= VadConfig.default.defaultThreshold ? .speech : .nonSpeech
        return .init(buffers: emit(policy.admit(decision)))
    }

    /// Drains the gate when capture ends.
    func flush() -> GatedAudio {
        guard detector != nil else { return .init(buffers: []) }
        var buffers = emit(policy.flush())
        // The trailing partial chunk was never scored, and it is the end of what the person just
        // said, so it goes through intact rather than being silenced on a guess.
        buffers.append(contentsOf: pendingBuffers)
        pendingBuffers.removeAll()
        pendingSamples.removeAll()
        return .init(buffers: buffers)
    }

    /// Abandons the detector and hands back every buffer the gate was holding. From here the gate
    /// is the pass-through it would have been had the pack shipped no model at all.
    private func failOpen() -> GatedAudio {
        detector = nil
        let released = heldChunks.flatMap { $0 } + pendingBuffers
        heldChunks.removeAll()
        pendingBuffers.removeAll()
        pendingSamples.removeAll()
        return .init(buffers: released)
    }

    private func emit(_ releases: [SpeechGateRelease]) -> [AVAudioPCMBuffer] {
        var buffers: [AVAudioPCMBuffer] = []
        for release in releases {
            let chunk = heldChunks.removeFirst()
            switch release {
            case .pass:
                buffers.append(contentsOf: chunk)
            case .silence:
                buffers.append(contentsOf: chunk.map(Self.silenced))
            }
        }
        return buffers
    }

    /// A same-format, same-length buffer of zeroes, so silenced audio keeps its place on the
    /// timeline and the streaming recognizer's sense of elapsed time is unchanged.
    private static func silenced(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let silence = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else { return buffer }
        silence.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList)
        for index in destination.indices {
            let byteCount = Int(source[index].mDataByteSize)
            destination[index].mDataByteSize = source[index].mDataByteSize
            if let data = destination[index].mData {
                memset(data, 0, byteCount)
            }
        }
        return silence
    }
}
