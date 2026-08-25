import Foundation

public actor DictationSessionActor {
    private let clock: any MonotonicClock
    private let policy: DictationPolicy
    private var state: State = .ready

    public init(clock: any MonotonicClock, policy: DictationPolicy = .init()) {
        self.clock = clock
        self.policy = policy
    }

    public func snapshot() -> DictationSessionSnapshot {
        switch state {
        case .ready:
            return .init(phase: .ready, activeID: nil, outcome: nil)
        case .active(let active):
            return .init(phase: active.phase, activeID: active.start.id, outcome: nil)
        case .completed(let id, let outcome):
            return .init(phase: .completed, activeID: id, outcome: outcome)
        }
    }

    public func handle(_ event: DictationEvent) -> [DictationEffect] {
        switch event {
        case .press(let start):
            return begin(start)
        case .release(let id):
            return endRecording(id: id, reason: .released)
        case .audioActivity(let id, let level):
            return receiveAudioActivity(id: id, level: level)
        case .recognitionHypothesis(let id, let hypothesis):
            return receiveHypothesis(id: id, hypothesis: hypothesis)
        case .recordingWarningFired(let id):
            return fireRecordingWarning(id: id)
        case .recordingLimitFired(let id):
            return fireRecordingLimit(id: id)
        case .recordingFailed(let id, let failure):
            return failRecording(id: id, failure: failure)
        case .recognitionCompleted(let id, let result):
            return receiveRecognition(id: id, result: result)
        case .cleanupCompleted(let id, let result):
            return receiveCleanup(id: id, result: result)
        case .targetRevalidated(let id, let validity):
            return receiveTargetValidity(id: id, validity: validity)
        case .deliveryCompleted(let id, let result):
            return receiveDelivery(id: id, result: result)
        case .watchdogFired(let id):
            return fireWatchdog(id: id)
        case .completionDeadlineFired(let id):
            return fireCompletionDeadline(id: id)
        case .cancel(let id):
            return cancel(id: id)
        case .completionPresentationElapsed(let id):
            return returnToReady(id: id)
        }
    }

    private func begin(_ start: DictationStart) -> [DictationEffect] {
        switch state {
        case .active:
            return []
        case .ready, .completed:
            break
        }

        guard case .editable(let target, let targetContext) = start.targetCapture else {
            let outcome = DictationOutcome.secureTargetRejection
            state = .completed(start.id, outcome)
            return [.presentIndicator(.init(
                dictationID: start.id,
                state: .unavailableSecureTarget
            ))]
        }

        let now = clock.now()
        state = .active(.init(
            start: start,
            target: target,
            targetContext: targetContext,
            phase: .recording,
            recordingStartedAt: now
        ))
        return [
            .presentIndicator(.init(dictationID: start.id, state: .recording(audioActivity: nil))),
            .startRecording(.init(id: start.id, personalVocabulary: start.personalVocabulary)),
            .scheduleRecordingWarning(id: start.id, at: now.advanced(by: policy.recordingWarningDelay)),
            .scheduleRecordingLimit(id: start.id, at: now.advanced(by: policy.recordingLimit)),
        ]
    }

    private func endRecording(id: DictationID, reason: RecordingEndReason) -> [DictationEffect] {
        guard case .active(var active) = state,
              active.start.id == id,
              active.phase == .recording
        else { return [] }

        let now = clock.now()
        let effectiveReason: RecordingEndReason = now >= active.recordingStartedAt.advanced(by: policy.recordingLimit)
            ? .fiveMinuteSafetyLimit
            : reason
        active.phase = .finalizing
        active.recordingEnd = effectiveReason
        active.deadlineStartedAt = now
        active.stageStartedAt = now
        state = .active(active)

        let watchdog = now.advanced(by: policy.watchdogDelay)
        let completion = now.advanced(by: policy.completionDeadline)
        return [
            .presentIndicator(.init(dictationID: id, state: .finalizingRecognition)),
            .stopRecordingAndFinalize(.init(id: id, deadline: watchdog)),
            .scheduleWatchdog(id: id, at: watchdog),
            .scheduleCompletionDeadline(id: id, at: completion),
        ]
    }

    private func receiveRecognition(id: DictationID, result: RecognitionResult) -> [DictationEffect] {
        guard case .active(var active) = state,
              active.start.id == id,
              active.phase == .finalizing
        else { return [] }

        let now = clock.now()
        if active.hasReachedWatchdog(at: now, policy: policy) {
            return recognitionTimedOut(active: active, now: now)
        }
        active.recognitionDuration = active.stageStartedAt?.duration(to: now)

        switch result {
        case .final(let rawTranscript):
            guard !rawTranscript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return completeWithoutText(active: active)
            }
            active.rawTranscript = rawTranscript
            active.phase = .cleaning
            active.stageStartedAt = now
            state = .active(active)
            guard let watchdog = active.watchdogDeadline(policy: policy) else { return [] }
            return [
                .presentIndicator(.init(dictationID: id, state: .cleaning)),
                .requestCleanup(.init(
                    id: id,
                    rawTranscript: rawTranscript,
                    targetContext: active.targetContext,
                    personalVocabulary: active.start.personalVocabulary,
                    deadline: watchdog
                )),
            ]
        case .failed:
            return completeWithoutText(active: active)
        }
    }

    private func receiveCleanup(id: DictationID, result: CleanupResult) -> [DictationEffect] {
        guard case .active(var active) = state,
              active.start.id == id,
              active.phase == .cleaning,
              let rawTranscript = active.rawTranscript
        else { return [] }

        let now = clock.now()
        if active.hasReachedWatchdog(at: now, policy: policy) {
            return cleanupTimedOut(active: active, now: now)
        }
        active.cleanupDuration = active.stageStartedAt?.duration(to: now)
        active.phase = .validating

        switch result {
        case .cleaned(let output):
            active.candidate = .init(
                text: output.text,
                kind: .cleaned,
                cleanupChanged: output.metadata.changed
            )
        case .rawTranscriptFallback(let reason):
            active.candidate = .init(
                text: rawTranscript.text,
                kind: .rawTranscriptFallback(reason),
                cleanupChanged: false
            )
        case .oversizedDeterministic(let output):
            active.candidate = .init(
                text: output.text,
                kind: .oversizedDeterministicFallback,
                cleanupChanged: output.metadata.changed
            )
        }

        return beginDelivery(&active, now: now)
    }

    private func beginDelivery(_ active: inout Active, now: MonotonicInstant) -> [DictationEffect] {
        active.phase = .delivering
        active.stageStartedAt = now
        state = .active(active)
        return [
            .presentIndicator(.init(dictationID: active.start.id, state: .delivering)),
            .revalidateTarget(.init(id: active.start.id, originalTarget: active.target)),
        ]
    }

    private func receiveTargetValidity(id: DictationID, validity: TargetValidity) -> [DictationEffect] {
        guard case .active(var active) = state,
              active.start.id == id,
              active.phase == .delivering,
              let candidate = active.candidate,
              active.deliveryRoute == nil,
              let deadlineStartedAt = active.deadlineStartedAt
        else { return [] }

        switch validity {
        case .valid:
            active.deliveryRoute = .target
            state = .active(active)
            return [.deliverToTarget(.init(
                id: id,
                target: active.target,
                text: candidate.text,
                deadline: deadlineStartedAt.advanced(by: policy.completionDeadline)
            ))]
        case .changed:
            active.deliveryRoute = .clipboard
            state = .active(active)
            return [.copyToClipboard(.init(
                id: id,
                text: candidate.text,
                deadline: deadlineStartedAt.advanced(by: policy.completionDeadline)
            ))]
        }
    }

    private func receiveDelivery(id: DictationID, result: DeliveryResult) -> [DictationEffect] {
        guard case .active(var active) = state,
              active.start.id == id,
              active.phase == .delivering,
              let candidate = active.candidate,
              let route = active.deliveryRoute,
              let recordingEnd = active.recordingEnd
        else { return [] }

        let now = clock.now()
        active.deliveryDuration = active.stageStartedAt?.duration(to: now)

        if let deadlineStartedAt = active.deadlineStartedAt,
           now > deadlineStartedAt.advanced(by: policy.completionDeadline)
        {
            let outcome = DictationOutcome.deliveryFailure(
                source: candidate.kind,
                reason: .completionDeadlineExceeded,
                recordingEnd: recordingEnd
            )
            return [.cancelDelivery(id)] + finish(
                active: active,
                outcome: outcome,
                deliveredText: nil,
                indicator: .failure(.delivery),
                now: now,
                writesHistory: true
            )
        }

        let outcome: DictationOutcome
        let deliveredText: String?
        let indicator: IndicatorState
        switch (route, result) {
        case (.target, .inserted(let method)):
            outcome = candidate.kind.insertedOutcome(method: method, recordingEnd: recordingEnd)
            deliveredText = candidate.text
            indicator = candidate.kind.successIndicator
        case (.clipboard, .copiedToClipboard):
            outcome = .targetChangedClipboard(source: candidate.kind, recordingEnd: recordingEnd)
            deliveredText = candidate.text
            indicator = .copiedBecauseTargetChanged
        case (_, .failed(let failure)):
            outcome = .deliveryFailure(
                source: candidate.kind,
                reason: failure,
                recordingEnd: recordingEnd
            )
            deliveredText = nil
            indicator = .failure(.delivery)
        default:
            return []
        }

        return finish(
            active: active,
            outcome: outcome,
            deliveredText: deliveredText,
            indicator: indicator,
            now: now,
            writesHistory: true
        )
    }

    private func completeWithoutText(active: Active) -> [DictationEffect] {
        guard let recordingEnd = active.recordingEnd else { return [] }
        let outcome = DictationOutcome.emptyRecognitionFailure(recordingEnd: recordingEnd)
        return finish(
            active: active,
            outcome: outcome,
            deliveredText: nil,
            indicator: .failure(.noUsableText),
            now: clock.now(),
            writesHistory: true
        )
    }

    private func receiveHypothesis(
        id: DictationID,
        hypothesis: RecognitionHypothesis
    ) -> [DictationEffect] {
        guard hypothesis.isUsable,
              case .active(var active) = state,
              active.start.id == id,
              active.phase == .recording || active.phase == .finalizing
        else { return [] }

        active.latestHypothesis = hypothesis
        state = .active(active)
        return []
    }

    private func receiveAudioActivity(id: DictationID, level: Double) -> [DictationEffect] {
        guard case .active(var active) = state,
              active.start.id == id,
              active.phase == .recording
        else { return [] }

        active.latestAudioActivity = min(max(level, 0), 1)
        state = .active(active)
        let warningAt = active.recordingStartedAt.advanced(by: policy.recordingWarningDelay)
        let indicator: IndicatorState = clock.now() >= warningAt
            ? .approachingRecordingLimit(audioActivity: active.latestAudioActivity)
            : .recording(audioActivity: active.latestAudioActivity)
        return [.presentIndicator(.init(dictationID: id, state: indicator))]
    }

    private func fireRecordingWarning(id: DictationID) -> [DictationEffect] {
        guard case .active(let active) = state,
              active.start.id == id,
              active.phase == .recording,
              clock.now() >= active.recordingStartedAt.advanced(by: policy.recordingWarningDelay)
        else { return [] }

        return [.presentIndicator(.init(
            dictationID: id,
            state: .approachingRecordingLimit(audioActivity: active.latestAudioActivity)
        ))]
    }

    private func fireRecordingLimit(id: DictationID) -> [DictationEffect] {
        guard case .active(let active) = state,
              active.start.id == id,
              active.phase == .recording,
              clock.now() >= active.recordingStartedAt.advanced(by: policy.recordingLimit)
        else { return [] }

        return endRecording(id: id, reason: .fiveMinuteSafetyLimit)
    }

    private func failRecording(id: DictationID, failure: RecordingFailure) -> [DictationEffect] {
        guard case .active(let active) = state,
              active.start.id == id,
              active.phase == .recording || active.phase == .finalizing
        else { return [] }

        state = .completed(id, .recordingFailure(failure))
        return [
            .cancelRecognition(id),
            .presentIndicator(.init(dictationID: id, state: .failure(.recording))),
        ]
    }

    private func fireWatchdog(id: DictationID) -> [DictationEffect] {
        guard case .active(let active) = state,
              active.start.id == id,
              active.hasReachedWatchdog(at: clock.now(), policy: policy)
        else { return [] }

        switch active.phase {
        case .finalizing:
            return recognitionTimedOut(active: active, now: clock.now())
        case .cleaning, .validating:
            return cleanupTimedOut(active: active, now: clock.now())
        case .ready, .recording, .delivering, .completed:
            return []
        }
    }

    private func recognitionTimedOut(active: Active, now: MonotonicInstant) -> [DictationEffect] {
        var active = active
        active.recognitionDuration = active.stageStartedAt?.duration(to: now)
        guard let hypothesis = active.latestHypothesis, hypothesis.isUsable else {
            return [.cancelRecognition(active.start.id)] + completeWithoutText(active: active)
        }

        active.candidate = .init(
            text: hypothesis.text,
            kind: .recognitionHypothesisFallback,
            cleanupChanged: false
        )
        return [.cancelRecognition(active.start.id)] + beginDelivery(&active, now: now)
    }

    private func cleanupTimedOut(active: Active, now: MonotonicInstant) -> [DictationEffect] {
        var active = active
        guard let rawTranscript = active.rawTranscript else { return [] }
        active.cleanupDuration = active.stageStartedAt?.duration(to: now)
        active.candidate = .init(
            text: rawTranscript.text,
            kind: .rawTranscriptFallback(.cleanupTimedOut),
            cleanupChanged: false
        )
        return [.cancelCleanup(active.start.id)] + beginDelivery(&active, now: now)
    }

    private func cancel(id: DictationID) -> [DictationEffect] {
        guard case .active(let active) = state, active.start.id == id else { return [] }

        let cancellation: DictationEffect
        switch active.phase {
        case .recording, .finalizing:
            cancellation = .cancelRecognition(id)
        case .cleaning, .validating:
            cancellation = .cancelCleanup(id)
        case .delivering:
            cancellation = .cancelDelivery(id)
        case .ready, .completed:
            return []
        }

        state = .completed(id, .cancelled)
        return [
            cancellation,
            .presentIndicator(.init(dictationID: id, state: .cancelled)),
        ]
    }

    private func fireCompletionDeadline(id: DictationID) -> [DictationEffect] {
        guard case .active(var active) = state,
              active.start.id == id,
              active.phase == .delivering,
              let candidate = active.candidate,
              let recordingEnd = active.recordingEnd,
              let deadlineStartedAt = active.deadlineStartedAt,
              clock.now() >= deadlineStartedAt.advanced(by: policy.completionDeadline)
        else { return [] }

        let now = clock.now()
        active.deliveryDuration = active.stageStartedAt?.duration(to: now)
        let outcome = DictationOutcome.deliveryFailure(
            source: candidate.kind,
            reason: .completionDeadlineExceeded,
            recordingEnd: recordingEnd
        )
        return [.cancelDelivery(id)] + finish(
            active: active,
            outcome: outcome,
            deliveredText: nil,
            indicator: .failure(.delivery),
            now: now,
            writesHistory: true
        )
    }

    private func returnToReady(id: DictationID) -> [DictationEffect] {
        guard case .completed(let completedID, _) = state, completedID == id else { return [] }
        state = .ready
        return [.presentIndicator(.init(dictationID: nil, state: .ready))]
    }

    private func finish(
        active: Active,
        outcome: DictationOutcome,
        deliveredText: String?,
        indicator: IndicatorState,
        now: MonotonicInstant,
        writesHistory: Bool
    ) -> [DictationEffect] {
        state = .completed(active.start.id, outcome)
        var effects: [DictationEffect] = [
            .presentIndicator(.init(dictationID: active.start.id, state: indicator)),
        ]
        if writesHistory {
            effects.append(.recordHistory(.init(
                id: active.start.id,
                occurredAt: active.start.occurredAt,
                rawTranscript: active.rawTranscript?.text,
                deliveredText: deliveredText,
                cleanupChanged: active.candidate?.cleanupChanged ?? false,
                outcome: outcome,
                timings: .init(
                    finalRecognition: active.recognitionDuration,
                    cleanup: active.cleanupDuration,
                    delivery: active.deliveryDuration,
                    completion: active.deadlineStartedAt?.duration(to: now)
                ),
                destinationApplicationIdentifier: active.target.applicationIdentifier
            )))
        }
        return effects
    }
}

private extension DictationSessionActor {
    enum State {
        case ready
        case active(Active)
        case completed(DictationID, DictationOutcome)
    }

    struct Active {
        let start: DictationStart
        let target: InsertionTarget
        let targetContext: TargetContext
        var phase: DictationPhase
        let recordingStartedAt: MonotonicInstant
        var recordingEnd: RecordingEndReason?
        var deadlineStartedAt: MonotonicInstant?
        var stageStartedAt: MonotonicInstant?
        var latestHypothesis: RecognitionHypothesis?
        var latestAudioActivity: Double?
        var rawTranscript: RawTranscript?
        var candidate: Candidate?
        var deliveryRoute: DeliveryRoute?
        var recognitionDuration: Duration?
        var cleanupDuration: Duration?
        var deliveryDuration: Duration?

        func watchdogDeadline(policy: DictationPolicy) -> MonotonicInstant? {
            deadlineStartedAt?.advanced(by: policy.watchdogDelay)
        }

        func hasReachedWatchdog(at now: MonotonicInstant, policy: DictationPolicy) -> Bool {
            guard let watchdogDeadline = watchdogDeadline(policy: policy) else { return false }
            return now >= watchdogDeadline
        }
    }

    struct Candidate {
        let text: String
        let kind: DeliveredTextKind
        let cleanupChanged: Bool
    }

    enum DeliveryRoute {
        case target
        case clipboard
    }
}

private extension DeliveredTextKind {
    func insertedOutcome(method: DeliveryMethod, recordingEnd: RecordingEndReason) -> DictationOutcome {
        switch self {
        case .cleaned:
            return .cleanedInsertion(method: method, recordingEnd: recordingEnd)
        case .rawTranscriptFallback(let reason):
            return .rawTranscriptFallback(reason: reason, method: method, recordingEnd: recordingEnd)
        case .oversizedDeterministicFallback:
            return .oversizedDeterministicFallback(method: method, recordingEnd: recordingEnd)
        case .recognitionHypothesisFallback:
            return .recognitionHypothesisFallback(method: method, recordingEnd: recordingEnd)
        }
    }

    var successIndicator: IndicatorState {
        switch self {
        case .cleaned:
            return .success
        case .rawTranscriptFallback:
            return .rawTranscriptFallback
        case .oversizedDeterministicFallback:
            return .oversizedFallback
        case .recognitionHypothesisFallback:
            return .recognitionFallback
        }
    }
}
