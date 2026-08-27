@preconcurrency import AVFoundation
@preconcurrency import CoreML
import DictationCore
import FluidAudio
import Foundation

public struct UptimeMonotonicClock: MonotonicClock {
    public init() {}

    public func now() -> MonotonicInstant {
        let uptime = DispatchTime.now().uptimeNanoseconds
        return .init(nanoseconds: Int64(min(uptime, UInt64(Int64.max))))
    }
}

actor FluidAudioIncrementalRecognizer: IncrementalSpeechRecognizing {
    fileprivate enum FinalizationOutcome: Sendable {
        case finished(Result<String, RecognitionFailure>)
        case deadline
    }

    nonisolated let capabilities: RecognitionCapabilities

    private let modelLayout: RecognitionModelLayout
    private let clock: any MonotonicClock
    private let manager: StreamingUnifiedAsrManager
    private let latestHypothesis: LatestHypothesisStore
    private var ctcModels: CtcModels?
    private var ctcTokenizer: CtcTokenizer?
    private var isPrepared = false
    private var pendingRecovery: Task<Void, Never>?
    private var currentFinalization: Task<Result<String, RecognitionFailure>, Never>?

    init(
        modelLayout: RecognitionModelLayout,
        clock: any MonotonicClock,
        latestHypothesis: LatestHypothesisStore = LatestHypothesisStore()
    ) {
        self.modelLayout = modelLayout
        self.clock = clock
        self.latestHypothesis = latestHypothesis
        self.capabilities = .init(
            personalVocabularyAvailable: modelLayout.ctcModelDirectory != nil
        )
        let production = FluidAudioRecognitionConfiguration.mvp
        self.manager = StreamingUnifiedAsrManager(
            config: UnifiedConfig(
                leftFrames: production.leftFrames,
                chunkFrames: production.chunkFrames,
                rightFrames: production.rightFrames
            ),
            encoderPrecision: .int8
        )
    }

    func prepare() async throws {
        if let pendingRecovery {
            await pendingRecovery.value
            self.pendingRecovery = nil
        }
        guard !isPrepared else { return }
        _ = try RecognitionModelValidator.validate(modelLayout)
        try await manager.loadModels(from: modelLayout.unifiedModelDirectory)
        if let ctcDirectory = modelLayout.ctcModelDirectory {
            async let models = CtcModels.loadDirect(from: ctcDirectory)
            async let tokenizer = CtcTokenizer.load(from: ctcDirectory)
            self.ctcModels = try await models
            self.ctcTokenizer = try await tokenizer
        }
        isPrepared = true
    }

    func begin(
        personalVocabulary: PersonalVocabulary,
        onPartial: @escaping @Sendable (String) async -> Void
    ) async throws {
        try await prepare()
        try await manager.reset()
        latestHypothesis.clear()
        let latestHypothesis = latestHypothesis
        await manager.setPartialTranscriptCallback { text in
            latestHypothesis.replace(with: text)
            Task { await onPartial(text) }
        }
        if let ctcModels, let ctcTokenizer {
            let terms = personalVocabulary.entries.compactMap { entry -> CustomVocabularyTerm? in
                let ids = ctcTokenizer.encode(entry)
                guard !ids.isEmpty else { return nil }
                return CustomVocabularyTerm(text: entry, ctcTokenIds: ids)
            }
            try await manager.configureVocabularyBoosting(
                vocabulary: CustomVocabularyContext(terms: terms),
                ctcModels: ctcModels
            )
        }
    }

    func accept(_ audio: RecognitionAudioBuffer) async throws {
        try await manager.appendAudio(audio.buffer)
        try await manager.processBufferedAudio()
    }

    func finish(deadline: MonotonicInstant) async -> IncrementalRecognitionFinalization {
        let race = FirstFinalizationOutcome()
        let manager = manager
        let finishTask = Task<Result<String, RecognitionFailure>, Never> {
            do {
                return .success(try await manager.finish())
            } catch is CancellationError {
                return .failure(.cancelled)
            } catch {
                return .failure(.finalizationFailed)
            }
        }
        currentFinalization = finishTask
        let remaining = max(.zero, clock.now().duration(to: deadline))
        if remaining == .zero {
            finishTask.cancel()
            currentFinalization = nil
            let latest = latestHypothesis.value
            let latestHypothesis = latestHypothesis
            pendingRecovery = Task {
                _ = await finishTask.value
                await manager.setPartialTranscriptCallback { _ in }
                try? await manager.reset()
                latestHypothesis.clear()
            }
            return .deadlineFallback(latest.isEmpty ? nil : latest)
        }
        Task {
            await race.resolve(.finished(await finishTask.value))
        }

        let timeoutTask = Task {
            do {
                try await Task.sleep(for: remaining)
                await race.resolve(.deadline)
            } catch {
                // The final transcript won the race.
            }
        }

        switch await race.value() {
        case .finished(let result):
            timeoutTask.cancel()
            currentFinalization = nil
            await manager.setPartialTranscriptCallback { _ in }
            try? await manager.reset()
            let latest = latestHypothesis.value
            latestHypothesis.clear()
            switch result {
            case .success(let text):
                return .final(text)
            case .failure(.cancelled):
                return .failed(.cancelled)
            case .failure:
                guard !latest.isEmpty else { return .failed(.finalizationFailed) }
                return .deadlineFallback(latest)
            }

        case .deadline:
            finishTask.cancel()
            currentFinalization = nil
            let latest = latestHypothesis.value
            let latestHypothesis = latestHypothesis
            pendingRecovery = Task {
                _ = await finishTask.value
                await manager.setPartialTranscriptCallback { _ in }
                try? await manager.reset()
                latestHypothesis.clear()
            }
            return .deadlineFallback(latest.isEmpty ? nil : latest)
        }
    }

    func cancel() async {
        currentFinalization?.cancel()
        if let currentFinalization {
            _ = await currentFinalization.value
        }
        currentFinalization = nil
        if let pendingRecovery {
            await pendingRecovery.value
            self.pendingRecovery = nil
        }
        await manager.setPartialTranscriptCallback { _ in }
        try? await manager.reset()
        latestHypothesis.clear()
    }
}

final class LatestHypothesisStore: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    var value: String {
        lock.withLock { text }
    }

    func replace(with text: String) {
        lock.withLock { self.text = text }
    }

    func clear() {
        lock.withLock { text = "" }
    }
}

private actor FirstFinalizationOutcome {
    private var outcome: FluidAudioIncrementalRecognizer.FinalizationOutcome?
    private var continuation: CheckedContinuation<
        FluidAudioIncrementalRecognizer.FinalizationOutcome,
        Never
    >?

    func resolve(_ outcome: FluidAudioIncrementalRecognizer.FinalizationOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    func value() async -> FluidAudioIncrementalRecognizer.FinalizationOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}
