import DictationCore
import Foundation
import Testing

@testable import PoptartApplication

@Suite("Application dictation composition")
struct DictationCoordinatorTests {
    @Test("press, release, recognition, cleanup, and insertion form one usable Dictation")
    func cleanedInsertion() async {
        let harness = Harness(
            recognition: .final(.init(text: "hello world")),
            cleanup: .cleaned(.init(
                text: "Hello, world.",
                metadata: .init(changed: true, editCount: 2)
            )),
            validity: .valid
        )

        await harness.coordinator.receive(.pressed)
        await harness.coordinator.receive(.released)
        let record = await harness.history.nextRecord()

        #expect(await harness.speech.startedCount == 1)
        #expect(await harness.delivery.insertedTexts == ["Hello, world."])
        #expect(record.deliveredText == "Hello, world.")
        #expect(record.outcome == .cleanedInsertion(method: .accessibility, recordingEnd: .released))
        #expect(await harness.indicator.states.contains(.cleaning))
        #expect(await harness.indicator.states.last == .success)
    }

    @Test("a changed insertion target copies without pasting into the new target")
    func changedTargetCopies() async {
        let harness = Harness(
            recognition: .final(.init(text: "Keep this")),
            cleanup: .rawTranscriptFallback(.modelUnavailable),
            validity: .changed
        )

        await harness.coordinator.receive(.pressed)
        await harness.coordinator.receive(.released)
        let record = await harness.history.nextRecord()

        #expect(await harness.delivery.insertedTexts.isEmpty)
        #expect(await harness.delivery.copiedTexts == ["Keep this"])
        #expect(record.outcome == .targetChangedClipboard(
            source: .rawTranscriptFallback(.modelUnavailable),
            recordingEnd: .released
        ))
        #expect(await harness.indicator.states.last == .copiedBecauseTargetChanged)
    }

    @Test("a secure target never starts recording or writes history")
    func secureTargetStopsBeforeCapture() async {
        let secure = DictationTargetCapture.secure(
            applicationIdentifier: "com.example.Passwords",
            elementIdentifier: "secure"
        )
        let harness = Harness(targetCapture: secure)

        await harness.coordinator.receive(.pressed)
        await harness.coordinator.receive(.released)

        #expect(await harness.speech.startedCount == 0)
        #expect(await harness.history.records.isEmpty)
        #expect(await harness.indicator.states.last == .unavailableSecureTarget)
    }

    @Test("release during target capture finalizes immediately after recording starts")
    func releaseDuringTargetCapture() async {
        let target = SuspendedTargetBoundary()
        let harness = Harness(targetBoundary: target)

        let pressing = Task { await harness.coordinator.receive(.pressed) }
        await target.waitUntilCaptureRequested()
        await harness.coordinator.receive(.released)
        await target.resolve(with: .success(editableCapture()))
        await pressing.value
        _ = await harness.history.nextRecord()

        #expect(await harness.speech.startedCount == 1)
        #expect(await harness.speech.finalizedCount == 1)
    }
}

private struct Harness {
    let speech: FakeSpeech
    let delivery: FakeDelivery
    let indicator: FakeIndicator
    let history: FakeHistory
    let coordinator: DictationCoordinator

    init(
        targetCapture: DictationTargetCapture = editableCapture(),
        recognition: RecognitionResult = .final(.init(text: "raw")),
        cleanup: CleanupResult = .rawTranscriptFallback(.modelUnavailable),
        validity: TargetValidity = .valid,
        targetBoundary: (any InsertionTargetBoundary)? = nil
    ) {
        let clock = FixedClock(now: .init(nanoseconds: 1_000))
        let target = targetBoundary ?? FakeTarget(capture: targetCapture, validity: validity)
        let speech = FakeSpeech(result: recognition)
        let cleanupBoundary = FakeCleanup(result: cleanup)
        let delivery = FakeDelivery()
        let indicator = FakeIndicator()
        let history = FakeHistory()
        self.speech = speech
        self.delivery = delivery
        self.indicator = indicator
        self.history = history
        self.coordinator = DictationCoordinator(
            session: .init(clock: clock),
            target: target,
            speech: speech,
            cleanup: cleanupBoundary,
            delivery: delivery,
            indicator: indicator,
            history: history,
            deadlines: InertDeadlines(),
            vocabulary: { .init(entries: ["Poptart"]) },
            wallClock: { Date(timeIntervalSince1970: 1_000) }
        )
    }
}

private func editableCapture() -> DictationTargetCapture {
    .editable(
        target: .init(
            applicationIdentifier: "com.example.Editor",
            elementIdentifier: "editor",
            selection: .init(location: 4, length: 0)
        ),
        context: .init(
            applicationIdentifier: "com.example.Editor",
            applicationCategory: .textEditor,
            textBeforeCursor: "Prior sentence.",
            textAfterCursor: "",
            selectedText: nil
        )
    )
}

private struct FixedClock: MonotonicClock {
    let instant: MonotonicInstant
    init(now: MonotonicInstant) { instant = now }
    func now() -> MonotonicInstant { instant }
}

private actor FakeTarget: InsertionTargetBoundary {
    let capture: DictationTargetCapture
    let validity: TargetValidity
    init(capture: DictationTargetCapture, validity: TargetValidity) {
        self.capture = capture
        self.validity = validity
    }
    func captureTarget(for id: DictationID) -> Result<DictationTargetCapture, TargetCaptureFailure> {
        .success(capture)
    }
    func revalidateTarget(_ request: TargetRevalidationRequest) -> TargetValidity { validity }
}

private actor SuspendedTargetBoundary: InsertionTargetBoundary {
    private var captureContinuation: CheckedContinuation<
        Result<DictationTargetCapture, TargetCaptureFailure>, Never
    >?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var requested = false

    func captureTarget(for id: DictationID) async -> Result<DictationTargetCapture, TargetCaptureFailure> {
        requested = true
        requestWaiters.forEach { $0.resume() }
        requestWaiters.removeAll()
        return await withCheckedContinuation { captureContinuation = $0 }
    }
    func revalidateTarget(_ request: TargetRevalidationRequest) -> TargetValidity { .valid }
    func waitUntilCaptureRequested() async {
        if requested { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }
    func resolve(with result: Result<DictationTargetCapture, TargetCaptureFailure>) {
        captureContinuation?.resume(returning: result)
        captureContinuation = nil
    }
}

private actor FakeSpeech: SpeechInputBoundary {
    let result: RecognitionResult
    private(set) var startedCount = 0
    private(set) var finalizedCount = 0
    init(result: RecognitionResult) { self.result = result }
    func startRecording(_ request: RecordingRequest) -> Result<Void, RecordingFailure> {
        startedCount += 1
        return .success(())
    }
    func stopRecordingAndFinalize(_ request: RecognitionFinalizationRequest) -> RecognitionResult {
        finalizedCount += 1
        return result
    }
    func cancelRecognition(for id: DictationID) {}
}

private actor FakeCleanup: CleanupBoundary {
    let result: CleanupResult
    init(result: CleanupResult) { self.result = result }
    func clean(_ request: CleanupRequest) -> CleanupResult { result }
    func cancelCleanup(for id: DictationID) {}
}

private actor FakeDelivery: TextDeliveryBoundary {
    private(set) var insertedTexts: [String] = []
    private(set) var copiedTexts: [String] = []
    func deliver(_ request: DeliveryRequest) -> DeliveryResult {
        insertedTexts.append(request.text)
        return .inserted(.accessibility)
    }
    func copyToClipboard(_ request: ClipboardRequest) -> DeliveryResult {
        copiedTexts.append(request.text)
        return .copiedToClipboard
    }
    func cancelDelivery(for id: DictationID) {}
}

private actor FakeIndicator: IndicatorBoundary {
    private(set) var states: [IndicatorState] = []
    func present(_ snapshot: IndicatorSnapshot) { states.append(snapshot.state) }
}

private actor FakeHistory: HistoryBoundary {
    private(set) var records: [DictationRecordIntent] = []
    private var waiters: [CheckedContinuation<DictationRecordIntent, Never>] = []
    func record(_ intent: DictationRecordIntent) {
        records.append(intent)
        if !waiters.isEmpty { waiters.removeFirst().resume(returning: intent) }
    }
    func nextRecord() async -> DictationRecordIntent {
        if let record = records.last { return record }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

private struct InertDeadlines: DictationDeadlineBoundary {
    func schedule(_ kind: DictationDeadlineKind, for id: DictationID, at instant: MonotonicInstant) {}
}
