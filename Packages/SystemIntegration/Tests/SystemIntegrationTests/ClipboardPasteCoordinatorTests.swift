import DictationCore
import Foundation
import Testing

@testable import SystemIntegration

@Suite("Clipboard-preserving paste")
struct ClipboardPasteCoordinatorTests {
  @Test("a closed receipt reports only that the promised text was read, never an insertion")
  func receiptIsNotAnInsertionClaim() async {
    let original = snapshot("previous")
    let clock = FakeIntegrationClock(now: 0)
    let pasteboard = FakePasteboard(snapshot: original, changeCount: 3)
    let coordinator = makeCoordinator(
      clock: clock, pasteboard: pasteboard, readTimes: [20],
      deadlinePolicy: .init(quietPeriodNanoseconds: 75, pollIntervalNanoseconds: 10))

    let outcome = await coordinator.pastePreservingClipboard(
      text: "dictated", deadline: .init(nanoseconds: 200))

    // The pasteboard cannot tell an insertion from a clipboard manager reading the promise, so the
    // coordinator is not allowed to express one.
    #expect(outcome == .promisedTextWasRead)
    #expect(
      PasteInsertionConfirmation.deliveryResult(outcome: outcome, evidence: .targetUnchanged)
        == .failed(.accessibilityAndPasteFailed))
  }

  @Test("successful paste restores every previous pasteboard representation")
  func restoresSnapshot() async {
    let original = PasteboardSnapshot(items: [
      .init(valuesByType: ["public.utf8-plain-text": Data("previous".utf8)]),
      .init(valuesByType: ["public.url": Data("https://example.com".utf8)]),
    ])
    let clock = FakeIntegrationClock(now: 0)
    let pasteboard = FakePasteboard(snapshot: original, changeCount: 3)
    let coordinator = makeCoordinator(
      clock: clock, pasteboard: pasteboard, readTimes: [20],
      deadlinePolicy: .init(quietPeriodNanoseconds: 75, pollIntervalNanoseconds: 10))

    let result = await coordinator.pastePreservingClipboard(
      text: "dictated", deadline: .init(nanoseconds: 200))

    #expect(result == .promisedTextWasRead)
    #expect(clock.nowNanoseconds() == 95)
    #expect(await pasteboard.restoredSnapshot() == original)
  }

  @Test("no target-app read times out instead of treating elapsed time as consumption")
  func noReadTimesOut() async {
    let original = snapshot("previous")
    let clock = FakeIntegrationClock(now: 0)
    let pasteboard = FakePasteboard(snapshot: original, changeCount: 3)
    let coordinator = makeCoordinator(
      clock: clock, pasteboard: pasteboard, readTimes: [],
      deadlinePolicy: .init(quietPeriodNanoseconds: 75, pollIntervalNanoseconds: 10))

    let result = await coordinator.pastePreservingClipboard(
      text: "dictated", deadline: .init(nanoseconds: 100))

    #expect(result == .failed(.pasteTimedOut))
    #expect(await pasteboard.restoredSnapshot() == original)
  }

  @Test("multiple reads restart the quiet period from the last genuine read")
  func multipleReadsRestartQuietPeriod() async {
    let original = snapshot("previous")
    let clock = FakeIntegrationClock(now: 0)
    let pasteboard = FakePasteboard(snapshot: original, changeCount: 3)
    let coordinator = makeCoordinator(
      clock: clock, pasteboard: pasteboard, readTimes: [10, 50],
      deadlinePolicy: .init(quietPeriodNanoseconds: 75, pollIntervalNanoseconds: 10))

    #expect(
      await coordinator.pastePreservingClipboard(
        text: "dictated", deadline: .init(nanoseconds: 200)) == .promisedTextWasRead)
    #expect(clock.nowNanoseconds() == 125)
    #expect(await pasteboard.restoredSnapshot() == original)
  }

  @Test("eager provider reads before Cmd-V do not satisfy the receipt")
  func eagerReadIgnored() async {
    let clock = FakeIntegrationClock(now: 0)
    let pasteboard = FakePasteboard(snapshot: snapshot("previous"), changeCount: 3, eagerRead: true)
    let coordinator = makeCoordinator(
      clock: clock, pasteboard: pasteboard, readTimes: [20],
      deadlinePolicy: .init(quietPeriodNanoseconds: 75, pollIntervalNanoseconds: 10))

    #expect(
      await coordinator.pastePreservingClipboard(
        text: "dictated", deadline: .init(nanoseconds: 150)) == .promisedTextWasRead)
    #expect(clock.nowNanoseconds() == 95)
  }

  @Test("a provider read before the synthesizer returns is pre-dispatch and times out")
  func readDuringSynthesisIgnored() async {
    let original = snapshot("previous")
    let clock = FakeIntegrationClock(now: 0)
    let pasteboard = FakePasteboard(snapshot: original, changeCount: 3)
    let coordinator = ClipboardPasteCoordinator(
      pasteboard: pasteboard,
      synthesizer: ReadingPasteSynthesizer(pasteboard: pasteboard),
      clock: clock,
      sleeper: ScriptedReadSleeper(clock: clock, pasteboard: pasteboard, readTimes: []),
      policy: .init(quietPeriodNanoseconds: 75, pollIntervalNanoseconds: 10)
    )

    #expect(
      await coordinator.pastePreservingClipboard(
        text: "dictated", deadline: .init(nanoseconds: 100)) == .failed(.pasteTimedOut))
    #expect(await pasteboard.restoredSnapshot() == original)
  }

  @Test("a read without enough remaining quiet time restores on owned timeout")
  func readThenDeadlineRestores() async {
    let original = snapshot("previous")
    let clock = FakeIntegrationClock(now: 0)
    let pasteboard = FakePasteboard(snapshot: original, changeCount: 3)
    let coordinator = makeCoordinator(
      clock: clock, pasteboard: pasteboard, readTimes: [50],
      deadlinePolicy: .init(quietPeriodNanoseconds: 75, pollIntervalNanoseconds: 10))

    #expect(
      await coordinator.pastePreservingClipboard(
        text: "dictated", deadline: .init(nanoseconds: 100)) == .failed(.pasteTimedOut))
    #expect(await pasteboard.restoredSnapshot() == original)
  }

  @Test("a new clipboard owner keeps its data and prevents restoration")
  func preservesForeignOwnership() async {
    let original = snapshot("previous")
    let clock = FakeIntegrationClock(now: 0)
    let pasteboard = FakePasteboard(snapshot: original, changeCount: 3)
    let coordinator = ClipboardPasteCoordinator(
      pasteboard: pasteboard,
      synthesizer: SuccessfulPasteSynthesizer(),
      clock: clock,
      sleeper: OwnershipChangingSleeper(clock: clock, pasteboard: pasteboard),
      policy: .init(quietPeriodNanoseconds: 75, pollIntervalNanoseconds: 10)
    )

    let result = await coordinator.pastePreservingClipboard(
      text: "dictated", deadline: .init(nanoseconds: 200))

    #expect(result == .failed(.clipboardOwnershipChanged))
    #expect(await pasteboard.restoredSnapshot() == nil)
  }

  @Test("synthesizer failure releases promised data after ownership loss")
  func failedSynthesisReleasesPromise() async {
    let clock = FakeIntegrationClock(now: 0)
    let pasteboard = FakePasteboard(snapshot: snapshot("previous"), changeCount: 3)
    let coordinator = ClipboardPasteCoordinator(
      pasteboard: pasteboard,
      synthesizer: FailingOwnershipChangingSynthesizer(pasteboard: pasteboard),
      clock: clock,
      sleeper: ScriptedReadSleeper(clock: clock, pasteboard: pasteboard, readTimes: []),
      policy: .init(quietPeriodNanoseconds: 75, pollIntervalNanoseconds: 10)
    )

    #expect(
      await coordinator.pastePreservingClipboard(
        text: "dictated", deadline: .init(nanoseconds: 100))
        == .failed(.accessibilityAndPasteFailed))
    #expect(await pasteboard.promisedReleaseCount() == 1)
    #expect(await pasteboard.restoredSnapshot() == nil)
  }

  @Test("insufficient deadline leaves the clipboard untouched")
  func deadlineBeforeWrite() async {
    let clock = FakeIntegrationClock(now: 100)
    let pasteboard = FakePasteboard(snapshot: snapshot("previous"), changeCount: 3)
    let coordinator = makeCoordinator(
      clock: clock, pasteboard: pasteboard, readTimes: [],
      deadlinePolicy: .init(quietPeriodNanoseconds: 75, pollIntervalNanoseconds: 10))

    let result = await coordinator.pastePreservingClipboard(
      text: "dictated", deadline: .init(nanoseconds: 174))

    #expect(result == .failed(.pasteTimedOut))
    #expect(await pasteboard.writtenTexts() == [])
  }

  @Test("withdrawn permission after the promised write prevents Cmd-V and restores the clipboard")
  func withdrawnPermissionPreventsPaste() async {
    let original = snapshot("previous")
    let pasteboard = FakePasteboard(snapshot: original, changeCount: 3)
    let synthesizer = await MainActor.run { RecordingPasteSynthesizer() }
    let coordinator = ClipboardPasteCoordinator(
      pasteboard: pasteboard,
      synthesizer: synthesizer,
      clock: FakeIntegrationClock(now: 0),
      sleeper: SystemIntegrationSleeper()
    )

    let result = await coordinator.pastePreservingClipboard(
      text: "dictated",
      deadline: .init(nanoseconds: 1_000_000_000),
      shouldPaste: { false }
    )

    #expect(result == .pasteSuppressed)
    #expect(await synthesizer.pasteCount() == 0)
    #expect(await pasteboard.restoredSnapshot() == original)
  }

  @Test("target-change copy intentionally replaces the clipboard without restoration")
  func targetChangeCopy() async {
    let pasteboard = FakePasteboard(snapshot: snapshot("previous"), changeCount: 3)
    let coordinator = ClipboardPasteCoordinator(
      pasteboard: pasteboard,
      synthesizer: SuccessfulPasteSynthesizer(),
      clock: FakeIntegrationClock(now: 0),
      sleeper: SystemIntegrationSleeper()
    )

    #expect(await coordinator.replaceClipboard(text: "dictated") == .copiedToClipboard)
    #expect(await pasteboard.writtenTexts() == ["dictated"])
    #expect(await pasteboard.restoredSnapshot() == nil)
  }

  private func makeCoordinator(
    clock: FakeIntegrationClock,
    pasteboard: FakePasteboard,
    readTimes: [Int64],
    deadlinePolicy: ClipboardRestorationPolicy
  ) -> ClipboardPasteCoordinator {
    ClipboardPasteCoordinator(
      pasteboard: pasteboard,
      synthesizer: SuccessfulPasteSynthesizer(),
      clock: clock,
      sleeper: ScriptedReadSleeper(clock: clock, pasteboard: pasteboard, readTimes: readTimes),
      policy: deadlinePolicy
    )
  }

  private func snapshot(_ text: String) -> PasteboardSnapshot {
    .init(items: [.init(valuesByType: ["text": Data(text.utf8)])])
  }
}

private final class FakeIntegrationClock: IntegrationNanosecondClock, @unchecked Sendable {
  private let lock = NSLock()
  private var now: Int64

  init(now: Int64) { self.now = now }
  func nowNanoseconds() -> Int64 { lock.withLock { now } }
  func advance(to instant: Int64) { lock.withLock { now = max(now, instant) } }
}

private final class FakePasteboard: PasteboardClient, @unchecked Sendable {
  private let lock = NSLock()
  private let initialSnapshot: PasteboardSnapshot
  private var count: Int
  private var texts: [String] = []
  private var restored: PasteboardSnapshot?
  private var promisedRead: (@Sendable () -> Void)?
  private let eagerRead: Bool
  private var releaseCount = 0

  init(snapshot: PasteboardSnapshot, changeCount: Int, eagerRead: Bool = false) {
    initialSnapshot = snapshot
    count = changeCount
    self.eagerRead = eagerRead
  }

  func snapshot() async -> PasteboardSnapshot { initialSnapshot }
  @MainActor
  func writeText(
    _ text: String,
    unlessRefusedBy refusal: @MainActor @Sendable () -> DeliveryFailure?
  ) -> ClipboardWriteOutcome {
    if let failure = refusal() { return .suppressed(failure) }
    return lock.withLock {
      texts.append(text)
      count += 1
      return .written(changeCount: count)
    }
  }
  func writePromisedText(_ text: String, onRead: @escaping @Sendable () -> Void) async -> Int? {
    let result = lock.withLock { () -> Int in
      texts.append(text)
      promisedRead = onRead
      count += 1
      return count
    }
    if eagerRead { onRead() }
    return result
  }
  func changeCount() async -> Int { lock.withLock { count } }
  func restore(_ snapshot: PasteboardSnapshot) async -> Bool {
    lock.withLock {
      restored = snapshot
      count += 1
      promisedRead = nil
    }
    return true
  }
  func releasePromisedData() async {
    lock.withLock {
      promisedRead = nil
      releaseCount += 1
    }
  }
  func foreignWrite() { lock.withLock { count += 1 } }
  func readPromisedText() { lock.withLock { promisedRead }?() }
  func restoredSnapshot() async -> PasteboardSnapshot? { lock.withLock { restored } }
  func writtenTexts() async -> [String] { lock.withLock { texts } }
  func promisedReleaseCount() async -> Int { lock.withLock { releaseCount } }
}

private struct SuccessfulPasteSynthesizer: PasteCommandSynthesizer {
  @MainActor
  func paste(ifAllowedBy authorization: @MainActor @Sendable () -> Bool) -> PasteCommandOutcome {
    authorization() ? .dispatched : .suppressed
  }
}

@MainActor
private final class RecordingPasteSynthesizer: PasteCommandSynthesizer, @unchecked Sendable {
  private var count = 0
  func paste(ifAllowedBy authorization: @MainActor @Sendable () -> Bool) -> PasteCommandOutcome {
    guard authorization() else { return .suppressed }
    count += 1
    return .dispatched
  }
  func pasteCount() -> Int { count }
}

private struct ReadingPasteSynthesizer: PasteCommandSynthesizer {
  let pasteboard: FakePasteboard
  @MainActor
  func paste(ifAllowedBy authorization: @MainActor @Sendable () -> Bool) -> PasteCommandOutcome {
    guard authorization() else { return .suppressed }
    pasteboard.readPromisedText()
    return .dispatched
  }
}

private struct FailingOwnershipChangingSynthesizer: PasteCommandSynthesizer {
  let pasteboard: FakePasteboard
  @MainActor
  func paste(ifAllowedBy authorization: @MainActor @Sendable () -> Bool) -> PasteCommandOutcome {
    guard authorization() else { return .suppressed }
    pasteboard.foreignWrite()
    return .failed
  }
}

private actor ScriptedReadSleeper: IntegrationSleeper {
  let clock: FakeIntegrationClock
  let pasteboard: FakePasteboard
  var readTimes: [Int64]

  init(clock: FakeIntegrationClock, pasteboard: FakePasteboard, readTimes: [Int64]) {
    self.clock = clock
    self.pasteboard = pasteboard
    self.readTimes = readTimes
  }

  func sleep(nanoseconds: UInt64) async {
    let destination = clock.nowNanoseconds() + Int64(nanoseconds)
    while let readTime = readTimes.first, readTime <= destination {
      clock.advance(to: readTime)
      readTimes.removeFirst()
      pasteboard.readPromisedText()
    }
    clock.advance(to: destination)
  }
}

private struct OwnershipChangingSleeper: IntegrationSleeper {
  let clock: FakeIntegrationClock
  let pasteboard: FakePasteboard
  func sleep(nanoseconds: UInt64) async {
    clock.advance(to: clock.nowNanoseconds() + Int64(nanoseconds))
    pasteboard.foreignWrite()
  }
}
