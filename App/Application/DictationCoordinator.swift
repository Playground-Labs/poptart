import DictationCore
import Foundation

public enum DictationGesture: Equatable, Sendable {
    case pressed
    case released
}

/// Composes the domain-owned state machine with system and inference boundaries.
/// Long-running adapter calls return typed events carrying the originating DictationID.
public actor DictationCoordinator {
    public typealias VocabularyProvider = @Sendable () async -> PersonalVocabulary
    public typealias WallClock = @Sendable () -> Date
    public typealias RecordingPreparation = @Sendable () async -> Void
    /// Waits out the interval a terminal Indicator state stays visible before ready returns.
    public typealias CompletionPresentationWait = @Sendable (Duration) async -> Void

    /// How long a completion, fallback, or failure state remains readable in the Indicator.
    public static let completionPresentationInterval = Duration.milliseconds(1_200)

    private enum GestureState {
        case capturing(id: DictationID, released: Bool)
        case starting(id: DictationID, released: Bool)
        case active(id: DictationID)

        var id: DictationID {
            switch self {
            case .capturing(let id, _), .starting(let id, _), .active(let id): id
            }
        }
    }

    private let session: DictationSessionActor
    private let target: any InsertionTargetBoundary
    private let speech: any SpeechInputBoundary
    private let cleanup: any CleanupBoundary
    private let delivery: any TextDeliveryBoundary
    private let indicator: any IndicatorBoundary
    private let history: any HistoryBoundary
    private let deadlines: any DictationDeadlineBoundary
    private let vocabulary: VocabularyProvider
    private let wallClock: WallClock
    private let prepareForRecording: RecordingPreparation
    private let completionPresentationInterval: Duration
    private let awaitCompletionPresentation: CompletionPresentationWait
    private var gesture: GestureState?
    private var scheduledCompletionPresentationID: DictationID?

    public init(
        session: DictationSessionActor,
        target: any InsertionTargetBoundary,
        speech: any SpeechInputBoundary,
        cleanup: any CleanupBoundary,
        delivery: any TextDeliveryBoundary,
        indicator: any IndicatorBoundary,
        history: any HistoryBoundary,
        deadlines: any DictationDeadlineBoundary,
        vocabulary: @escaping VocabularyProvider,
        wallClock: @escaping WallClock = Date.init,
        prepareForRecording: @escaping RecordingPreparation = {},
        completionPresentationInterval: Duration = DictationCoordinator.completionPresentationInterval,
        awaitCompletionPresentation: @escaping CompletionPresentationWait = { interval in
            try? await Task.sleep(for: interval)
        }
    ) {
        self.session = session
        self.target = target
        self.speech = speech
        self.cleanup = cleanup
        self.delivery = delivery
        self.indicator = indicator
        self.history = history
        self.deadlines = deadlines
        self.vocabulary = vocabulary
        self.wallClock = wallClock
        self.prepareForRecording = prepareForRecording
        self.completionPresentationInterval = completionPresentationInterval
        self.awaitCompletionPresentation = awaitCompletionPresentation
    }

    public func receive(_ signal: DictationGesture) async {
        switch signal {
        case .pressed:
            await beginGesture()
        case .released:
            await releaseGesture()
        }
    }

    public func receive(_ event: DictationEvent) async {
        let effects = await session.handle(event)
        await dispatch(effects)
        await scheduleCompletionPresentation()
    }

    /// Returns the Indicator to ready once a terminal outcome has been visible long enough.
    private func scheduleCompletionPresentation() async {
        let snapshot = await session.snapshot()
        guard snapshot.phase == .completed,
              let id = snapshot.activeID,
              scheduledCompletionPresentationID != id
        else { return }

        scheduledCompletionPresentationID = id
        let awaitCompletionPresentation = awaitCompletionPresentation
        let interval = completionPresentationInterval
        Task { [weak self] in
            await awaitCompletionPresentation(interval)
            await self?.receive(.completionPresentationElapsed(id))
        }
    }

    /// Returns the Indicator to ready after a failure the session never saw.
    ///
    /// Target capture fails before any Dictation reaches the session, so the completion
    /// presentation the session drives never fires for it.
    private func scheduleDirectFailurePresentation(for id: DictationID) {
        scheduledCompletionPresentationID = id
        let awaitCompletionPresentation = awaitCompletionPresentation
        let interval = completionPresentationInterval
        Task { [weak self] in
            await awaitCompletionPresentation(interval)
            await self?.presentReadyAfterDirectFailure(id)
        }
    }

    private func presentReadyAfterDirectFailure(_ id: DictationID) async {
        guard scheduledCompletionPresentationID == id, gesture == nil else { return }
        await indicator.present(.init(dictationID: nil, state: .ready))
    }

    public func activeDictationID() -> DictationID? {
        gesture?.id
    }

    private func beginGesture() async {
        guard gesture == nil else { return }
        let id = DictationID()
        gesture = .capturing(id: id, released: false)
        let capture = await target.captureTarget(for: id)
        guard case .capturing(let currentID, let released) = gesture, currentID == id else {
            return
        }

        switch capture {
        case .failure:
            gesture = nil
            await indicator.present(.init(dictationID: id, state: .failure(.recording)))
            scheduleDirectFailurePresentation(for: id)

        case .success(let targetCapture):
            let start: DictationStart
            switch targetCapture {
            case .editable(let insertionTarget, let context):
                start = .init(
                    id: id,
                    occurredAt: wallClock(),
                    target: insertionTarget,
                    targetContext: context,
                    personalVocabulary: await vocabulary()
                )
            case .secure(let applicationIdentifier, let elementIdentifier):
                start = .init(
                    secureTargetID: id,
                    occurredAt: wallClock(),
                    applicationIdentifier: applicationIdentifier,
                    elementIdentifier: elementIdentifier
                )
            }

            gesture = .starting(id: id, released: released)
            await receive(.press(start))
            let snapshot = await session.snapshot()
            guard snapshot.activeID == id, snapshot.phase == .recording else {
                gesture = nil
                return
            }

            let releaseWasRequested: Bool
            switch gesture {
            case .starting(let currentID, let released) where currentID == id:
                releaseWasRequested = released
            default:
                return
            }
            gesture = .active(id: id)
            if releaseWasRequested { await releaseGesture() }
        }
    }

    private func releaseGesture() async {
        guard let gesture else { return }
        switch gesture {
        case .capturing(let id, _):
            self.gesture = .capturing(id: id, released: true)
        case .starting(let id, _):
            self.gesture = .starting(id: id, released: true)
        case .active(let id):
            self.gesture = nil
            await receive(.release(id))
        }
    }

    private func dispatch(_ effects: [DictationEffect]) async {
        for effect in effects {
            switch effect {
            case .startRecording(let request):
                let prepareForRecording = prepareForRecording
                Task { await prepareForRecording() }
                if case .failure(let failure) = await speech.startRecording(request) {
                    await receive(.recordingFailed(request.id, failure))
                }

            case .scheduleRecordingWarning(let id, let instant):
                await deadlines.schedule(.recordingWarning, for: id, at: instant)

            case .scheduleRecordingLimit(let id, let instant):
                await deadlines.schedule(.recordingLimit, for: id, at: instant)

            case .stopRecordingAndFinalize(let request):
                let speech = speech
                Task { [weak self] in
                    let result = await speech.stopRecordingAndFinalize(request)
                    await self?.receive(.recognitionCompleted(request.id, result))
                }

            case .scheduleWatchdog(let id, let instant):
                await deadlines.schedule(.watchdog, for: id, at: instant)

            case .scheduleCompletionDeadline(let id, let instant):
                await deadlines.schedule(.completion, for: id, at: instant)

            case .requestCleanup(let request):
                let cleanup = cleanup
                Task { [weak self] in
                    let result = await cleanup.clean(request)
                    await self?.receive(.cleanupCompleted(request.id, result))
                }

            case .cancelRecognition(let id):
                await speech.cancelRecognition(for: id)

            case .cancelCleanup(let id):
                await cleanup.cancelCleanup(for: id)

            case .cancelDelivery(let id):
                await delivery.cancelDelivery(for: id)

            case .revalidateTarget(let request):
                let target = target
                Task { [weak self] in
                    let result = await target.revalidateTarget(request)
                    await self?.receive(.targetRevalidated(request.id, result))
                }

            case .deliverToTarget(let request):
                let delivery = delivery
                Task { [weak self] in
                    let result = await delivery.deliver(request)
                    await self?.receive(.deliveryCompleted(request.id, result))
                }

            case .copyToClipboard(let request):
                let delivery = delivery
                Task { [weak self] in
                    let result = await delivery.copyToClipboard(request)
                    await self?.receive(.deliveryCompleted(request.id, result))
                }

            case .presentIndicator(let snapshot):
                await indicator.present(snapshot)

            case .recordHistory(let intent):
                let history = history
                Task { await history.record(intent) }
            }
        }
    }
}
