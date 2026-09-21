import CryptoKit
import DictationCore
import Foundation
import Persistence
import Testing

@testable import PoptartApplication

@Suite("Application dictation composition")
struct DictationCoordinatorTests {
    @Test("Runtime replacement finishes recording and refuses subsequent presses")
    func finishesBeforeReplacement() async {
        let harness = Harness(recognition: .final(.init(text: "Keep my words")))
        await harness.coordinator.receive(.pressed)
        await harness.coordinator.finishCurrentDictation()
        #expect(await harness.history.records.count == 1)
        #expect(await harness.delivery.insertedTexts == ["Keep my words"])
        await harness.coordinator.receive(.pressed)
        #expect(await harness.speech.startedCount == 1)
    }

    @Test("Runtime replacement preserves a press still capturing its target")
    func finishesDuringCapture() async {
        let target = SuspendedTargetBoundary()
        let harness = Harness(targetBoundary: target)
        let pressing = Task { await harness.coordinator.receive(.pressed) }
        await target.waitUntilCaptureRequested()
        let stopping = Task { await harness.coordinator.finishCurrentDictation() }
        await target.resolve(with: .success(editableCapture()))
        await pressing.value
        await stopping.value
        #expect(await harness.history.records.count == 1)
        #expect(await harness.speech.finalizedCount == 1)
    }

    @Test("Runtime replacement waits for Cleanup, delivery, and history", arguments: ["cleanup", "delivery", "history"])
    func joinsBoundaryWork(_ phase: String) async {
        let gate = ManualPresentationInterval()
        let harness = Harness(cleanupWait: phase == "cleanup" ? gate : nil,
                              deliveryWait: phase == "delivery" ? gate : nil,
                              historyWait: phase == "history" ? gate : nil)
        let finished = Box(false)
        await harness.coordinator.receive(.pressed)
        let stopping = Task {
            await harness.coordinator.finishCurrentDictation()
            finished.mutate { $0 = true }
        }
        await gate.waitUntilRequested()
        #expect(!finished.value)
        await gate.elapse()
        await stopping.value
        #expect(await harness.history.records.count == 1)
        #expect(await harness.delivery.insertedTexts == ["raw"])
    }

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

    @Test("watchdog delivery does not wait for recognition teardown")
    func watchdogDeliveryDoesNotWaitForRecognitionTeardown() async {
        let clock = MutableClock(now: .zero)
        let speech = SuspendedCancellationSpeech()
        let target = FakeTarget(capture: editableCapture(), validity: .valid)
        let delivery = FakeDelivery()
        let history = FakeHistory()
        let coordinator = DictationCoordinator(
            session: .init(clock: clock),
            target: target,
            speech: speech,
            cleanup: FakeCleanup(result: .rawTranscriptFallback(.modelUnavailable)),
            delivery: delivery,
            indicator: FakeIndicator(),
            history: history,
            deadlines: InertDeadlines(),
            vocabulary: { .init(entries: []) }
        )
        await coordinator.receive(.pressed)
        let id = (await coordinator.activeDictationID())!
        await coordinator.receive(.recognitionHypothesis(id, .init(text: "usable partial")))
        await coordinator.receive(.released)
        clock.instant = .zero.advanced(by: .milliseconds(1_400))

        await coordinator.receive(.watchdogFired(id))
        await speech.waitUntilCancellationRequested()
        let record = await history.nextRecord()

        #expect(await delivery.insertedTexts == ["usable partial"])
        #expect(record.outcome == .recognitionHypothesisFallback(
            method: .accessibility, recordingEnd: .released))

        await coordinator.receive(.completionPresentationElapsed(id))
        let nextPress = Task { await coordinator.receive(.pressed) }
        await target.waitForCaptureCount(2)
        try? await Task.sleep(for: .milliseconds(10))
        #expect(await speech.startedCount == 1)

        await speech.finishCancellation()
        try? await Task.sleep(for: .milliseconds(10))
        #expect(await speech.startedCount == 1)
        await speech.finishFinalization()
        await nextPress.value
        #expect(await speech.startedCount == 2)
    }

    @Test("a dictation with no editable target records and copies instead of failing")
    func noTargetCopies() async {
        let harness = Harness(
            targetCapture: noTargetCapture(),
            recognition: .final(.init(text: "Nowhere to type")),
            cleanup: .rawTranscriptFallback(.modelUnavailable)
        )

        await harness.coordinator.receive(.pressed)
        await harness.coordinator.receive(.released)
        let record = await harness.history.nextRecord()

        #expect(await harness.speech.startedCount == 1)
        #expect(await harness.delivery.insertedTexts.isEmpty)
        #expect(await harness.delivery.copiedTexts == ["Nowhere to type"])
        #expect(record.outcome == .noTargetClipboard(
            source: .rawTranscriptFallback(.modelUnavailable),
            recordingEnd: .released
        ))
        #expect(await harness.indicator.states.contains(.failure(.recording)) == false)
        #expect(await harness.indicator.states.last == .copiedBecauseNoTarget)
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

    @Test("a terminal Indicator state returns to ready after the presentation interval")
    func completionPresentationReturnsToReady() async {
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
        await harness.indicator.waitForState(.success)
        await harness.presentation.waitUntilRequested()

        #expect(await harness.presentation.requestedIntervals
            == [DictationCoordinator.completionPresentationInterval])
        #expect(await harness.indicator.states.last == .success)

        await harness.presentation.elapse()
        await harness.indicator.waitForState(.ready)

        #expect(await harness.indicator.states.last == .ready)
    }

    @Test("a stale presentation interval cannot return a newer Dictation to ready")
    func stalePresentationDoesNotClobberNewDictation() async {
        let harness = Harness(
            recognition: .final(.init(text: "hello world")),
            cleanup: .rawTranscriptFallback(.modelUnavailable),
            validity: .valid
        )

        await harness.coordinator.receive(.pressed)
        await harness.coordinator.receive(.released)
        let completed = await harness.history.nextRecord()
        await harness.presentation.waitUntilRequested()

        await harness.coordinator.receive(.pressed)
        #expect(await harness.indicator.states.last == .recording(audioActivity: nil))

        await harness.coordinator.receive(.completionPresentationElapsed(completed.id))

        #expect(await harness.indicator.states.contains(.ready) == false)
        #expect(await harness.indicator.states.last == .recording(audioActivity: nil))
    }

    @Test("a target-capture failure returns the Indicator to ready after the presentation interval")
    func targetCaptureFailureReturnsToReady() async {
        let harness = Harness(targetBoundary: FailingTargetBoundary())

        await harness.coordinator.receive(.pressed)
        await harness.indicator.waitForState(.failure(.recording))
        await harness.presentation.waitUntilRequested()

        #expect(await harness.presentation.requestedIntervals
            == [DictationCoordinator.completionPresentationInterval])
        #expect(await harness.indicator.states.last == .failure(.recording))

        await harness.presentation.elapse()
        await harness.indicator.waitForState(.ready)

        #expect(await harness.indicator.states.last == .ready)
    }

    @Test("a stale target-capture failure interval cannot return a newer Dictation to ready")
    func staleTargetCaptureFailureDoesNotClobberNewDictation() async {
        let target = FailThenSuspendTargetBoundary()
        let harness = Harness(targetBoundary: target)

        await harness.coordinator.receive(.pressed)
        await harness.indicator.waitForState(.failure(.recording))
        await harness.presentation.waitUntilRequested()

        let pressing = Task { await harness.coordinator.receive(.pressed) }
        await target.waitUntilSecondCaptureRequested()
        await harness.presentation.elapse()
        await target.resolveSecondCapture()
        await pressing.value
        await harness.indicator.waitForState(.recording(audioActivity: nil))

        let states: [IndicatorState] = await harness.indicator.states
        #expect(states == [.failure(.recording), .recording(audioActivity: nil)])
    }

    @Test("a secure-target record intent never reaches encrypted history")
    func secureTargetRejectionWritesNoHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try HistoryStore(
            directory: directory,
            keyProvider: InMemoryKeyProvider(),
            now: { Date(timeIntervalSince1970: 1_100) }
        )
        let history = EncryptedHistoryBoundary(store: store)

        await history.record(recordIntent(outcome: .secureTargetRejection))
        #expect(try await store.records().isEmpty)

        await history.record(recordIntent(
            outcome: .cleanedInsertion(method: .accessibility, recordingEnd: .released)
        ))
        #expect(try await store.records().count == 1)
    }

    @Test("history keeps why a Dictation fell back and which copy it was")
    func fallbackReasonAndClipboardResultsReachHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try HistoryStore(
            directory: directory,
            keyProvider: InMemoryKeyProvider(),
            now: { Date(timeIntervalSince1970: 1_100) }
        )
        let history = EncryptedHistoryBoundary(store: store)

        await history.record(recordIntent(outcome: .rawTranscriptFallback(
            reason: .cleanupTimedOut, method: .accessibility, recordingEnd: .released
        )))
        await history.record(recordIntent(outcome: .targetChangedClipboard(
            source: .cleaned, recordingEnd: .released
        )))
        await history.record(recordIntent(outcome: .noTargetClipboard(
            source: .rawTranscriptFallback(.cleanupFailed), recordingEnd: .released
        )))

        let records = try await store.records()
        #expect(
            Set(records.map(\.outcome))
                == [.rawTranscript, .copiedTargetChanged, .copiedNoTarget])
        #expect(records.first { $0.outcome == .rawTranscript }?.fallbackReason == .cleanupTimedOut)
        #expect(records.first { $0.outcome == .copiedTargetChanged }?.fallbackReason == nil)
        #expect(records.first { $0.outcome == .copiedNoTarget }?.fallbackReason == .cleanupFailed)
    }
}

private func recordIntent(outcome: DictationCore.DictationOutcome) -> DictationRecordIntent {
    .init(
        id: .init(),
        occurredAt: Date(timeIntervalSince1970: 1_000),
        rawTranscript: nil,
        deliveredText: nil,
        cleanupChanged: false,
        outcome: outcome,
        timings: .init(finalRecognition: nil, cleanup: nil, delivery: nil, completion: nil),
        destinationApplicationIdentifier: "com.example.Passwords"
    )
}

private struct InMemoryKeyProvider: EncryptionKeyProviding {
    private let key = SymmetricKey(size: .bits256)
    func encryptionKey() throws -> SymmetricKey { key }
    func deleteKey() throws {}
}

private struct Harness {
    let speech: FakeSpeech
    let delivery: FakeDelivery
    let indicator: FakeIndicator
    let history: FakeHistory
    let presentation: ManualPresentationInterval
    let coordinator: DictationCoordinator

    init(
        targetCapture: DictationTargetCapture = editableCapture(),
        recognition: RecognitionResult = .final(.init(text: "raw")),
        cleanup: CleanupResult = .rawTranscriptFallback(.modelUnavailable),
        validity: TargetValidity = .valid,
        targetBoundary: (any InsertionTargetBoundary)? = nil,
        cleanupWait: ManualPresentationInterval? = nil,
        deliveryWait: ManualPresentationInterval? = nil,
        historyWait: ManualPresentationInterval? = nil
    ) {
        let clock = FixedClock(now: .init(nanoseconds: 1_000))
        let target = targetBoundary ?? FakeTarget(capture: targetCapture, validity: validity)
        let speech = FakeSpeech(result: recognition)
        let cleanupBoundary = FakeCleanup(result: cleanup, wait: cleanupWait)
        let delivery = FakeDelivery(wait: deliveryWait)
        let indicator = FakeIndicator()
        let history = FakeHistory(wait: historyWait)
        let presentation = ManualPresentationInterval()
        self.speech = speech
        self.delivery = delivery
        self.indicator = indicator
        self.history = history
        self.presentation = presentation
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
            wallClock: { Date(timeIntervalSince1970: 1_000) },
            awaitCompletionPresentation: { [presentation] interval in
                await presentation.wait(interval)
            }
        )
    }
}

/// Stands in for the presentation interval so tests never wait on wall-clock time.
private actor ManualPresentationInterval {
    private(set) var requestedIntervals: [Duration] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasElapsed = false

    func wait(_ interval: Duration) async {
        requestedIntervals.append(interval)
        requestWaiters.forEach { $0.resume() }
        requestWaiters.removeAll()
        guard !hasElapsed else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilRequested() async {
        if !requestedIntervals.isEmpty { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func elapse() {
        hasElapsed = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
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

private func noTargetCapture() -> DictationTargetCapture {
    .noTarget(context: .init(
        applicationIdentifier: "com.example.Viewer",
        applicationCategory: .other,
        textBeforeCursor: "",
        textAfterCursor: "",
        selectedText: nil
    ))
}

private struct FixedClock: MonotonicClock {
    let instant: MonotonicInstant
    init(now: MonotonicInstant) { instant = now }
    func now() -> MonotonicInstant { instant }
}

private final class MutableClock: MonotonicClock, @unchecked Sendable {
    private let value: Box<MonotonicInstant>
    init(now: MonotonicInstant) { value = Box(now) }
    var instant: MonotonicInstant {
        get { value.value }
        set { value.value = newValue }
    }
    func now() -> MonotonicInstant { instant }
}

private actor FakeTarget: InsertionTargetBoundary {
    let capture: DictationTargetCapture
    let validity: TargetValidity
    private var captureCount = 0
    private var captureWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    init(capture: DictationTargetCapture, validity: TargetValidity) {
        self.capture = capture
        self.validity = validity
    }
    func captureTarget(for id: DictationID) -> Result<DictationTargetCapture, TargetCaptureFailure> {
        captureCount += 1
        captureWaiters.removeAll { waiter in
            guard captureCount >= waiter.0 else { return false }
            waiter.1.resume()
            return true
        }
        return .success(capture)
    }
    func revalidateTarget(_ request: TargetRevalidationRequest) -> TargetValidity { validity }
    func waitForCaptureCount(_ count: Int) async {
        if captureCount >= count { return }
        await withCheckedContinuation { captureWaiters.append((count, $0)) }
    }
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

private actor FailingTargetBoundary: InsertionTargetBoundary {
    func captureTarget(for id: DictationID) -> Result<DictationTargetCapture, TargetCaptureFailure> {
        .failure(.noEditableTarget)
    }
    func revalidateTarget(_ request: TargetRevalidationRequest) -> TargetValidity { .valid }
}

/// Fails the first capture, then suspends the second so a fresh Dictation stays mid-press.
private actor FailThenSuspendTargetBoundary: InsertionTargetBoundary {
    private var captureCount = 0
    private var captureContinuation: CheckedContinuation<
        Result<DictationTargetCapture, TargetCaptureFailure>, Never
    >?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondRequested = false

    func captureTarget(for id: DictationID) async -> Result<DictationTargetCapture, TargetCaptureFailure> {
        captureCount += 1
        guard captureCount > 1 else { return .failure(.noEditableTarget) }
        secondRequested = true
        requestWaiters.forEach { $0.resume() }
        requestWaiters.removeAll()
        return await withCheckedContinuation { captureContinuation = $0 }
    }
    func revalidateTarget(_ request: TargetRevalidationRequest) -> TargetValidity { .valid }
    func waitUntilSecondCaptureRequested() async {
        if secondRequested { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }
    func resolveSecondCapture() {
        captureContinuation?.resume(returning: .success(editableCapture()))
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

private actor SuspendedCancellationSpeech: SpeechInputBoundary {
    private var finalization: CheckedContinuation<Void, Never>?
    private var cancellation: CheckedContinuation<Void, Never>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationRequested = false
    private(set) var startedCount = 0

    func startRecording(_ request: RecordingRequest) -> Result<Void, RecordingFailure> {
        startedCount += 1
        return .success(())
    }
    func stopRecordingAndFinalize(_ request: RecognitionFinalizationRequest) async -> RecognitionResult {
        await withCheckedContinuation { continuation in finalization = continuation }
        return .failed(.cancelled)
    }
    func cancelRecognition(for id: DictationID) async {
        cancellationRequested = true
        requestWaiters.forEach { $0.resume() }
        requestWaiters.removeAll()
        await withCheckedContinuation { continuation in cancellation = continuation }
    }
    func waitUntilCancellationRequested() async {
        if cancellationRequested { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }
    func finishCancellation() {
        cancellation?.resume()
        cancellation = nil
    }
    func finishFinalization() {
        finalization?.resume()
        finalization = nil
    }
}

private actor FakeCleanup: CleanupBoundary {
    let result: CleanupResult
    let wait: ManualPresentationInterval?
    init(result: CleanupResult, wait: ManualPresentationInterval? = nil) { self.result = result; self.wait = wait }
    func clean(_ request: CleanupRequest) async -> CleanupResult {
        await wait?.wait(.zero)
        return result
    }
    func cancelCleanup(for id: DictationID) {}
}

private actor FakeDelivery: TextDeliveryBoundary {
    let wait: ManualPresentationInterval?
    init(wait: ManualPresentationInterval? = nil) { self.wait = wait }
    private(set) var insertedTexts: [String] = []
    private(set) var copiedTexts: [String] = []
    func deliver(_ request: DeliveryRequest) async -> DeliveryResult {
        await wait?.wait(.zero)
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
    private var waiters: [(state: IndicatorState, continuation: CheckedContinuation<Void, Never>)] = []

    func present(_ snapshot: IndicatorSnapshot) {
        states.append(snapshot.state)
        waiters.removeAll { waiter in
            guard waiter.state == snapshot.state else { return false }
            waiter.continuation.resume()
            return true
        }
    }

    func waitForState(_ state: IndicatorState) async {
        if states.contains(state) { return }
        await withCheckedContinuation { waiters.append((state, $0)) }
    }
}

private actor FakeHistory: HistoryBoundary {
    let wait: ManualPresentationInterval?
    init(wait: ManualPresentationInterval? = nil) { self.wait = wait }
    private(set) var records: [DictationRecordIntent] = []
    private var waiters: [CheckedContinuation<DictationRecordIntent, Never>] = []
    func record(_ intent: DictationRecordIntent) async {
        await wait?.wait(.zero)
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
