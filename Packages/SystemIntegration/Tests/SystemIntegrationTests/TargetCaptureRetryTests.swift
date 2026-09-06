import DictationCore
import Foundation
import Testing

@testable import SystemIntegration

@Suite("Target capture retry")
struct TargetCaptureRetryTests {
  @Test("an editable target is captured on the first attempt and costs no waiting")
  @MainActor
  func editableTargetIsCapturedImmediately() async {
    let clock = CaptureClock(now: 0)
    let sleeper = CaptureSleeper(clock: clock)
    let attempts = ScriptedCapture([.success(editable(in: "com.apple.TextEdit"))])

    let result = await retry(clock: clock, sleeper: sleeper).capture(attempt: attempts.next)

    #expect(result == .success(editable(in: "com.apple.TextEdit")))
    #expect(attempts.count == 1)
    #expect(await sleeper.count() == 0)
    #expect(clock.nowNanoseconds() == 0)
  }

  @Test("a text field that focuses a moment after its window is still captured as editable")
  @MainActor
  func focusArrivingLateIsStillCaptured() async {
    let clock = CaptureClock(now: 0)
    let sleeper = CaptureSleeper(clock: clock)
    let attempts = ScriptedCapture([
      .success(noTarget(in: "com.apple.TextEdit")),
      .success(noTarget(in: "com.apple.TextEdit")),
      .success(editable(in: "com.apple.TextEdit")),
    ])

    let result = await retry(clock: clock, sleeper: sleeper).capture(attempt: attempts.next)

    #expect(result == .success(editable(in: "com.apple.TextEdit")))
    #expect(attempts.count == 3)
  }

  @Test("a context with no field at all gives up at the budget and reports the freshest read")
  @MainActor
  func fieldlessContextGivesUpAtTheBudget() async {
    let clock = CaptureClock(now: 0)
    let sleeper = CaptureSleeper(clock: clock)
    let attempts = ScriptedCapture(
      [.success(noTarget(in: "com.apple.Finder"))],
      thereafter: .success(noTarget(in: "com.apple.Safari")))

    let result = await retry(clock: clock, sleeper: sleeper).capture(attempt: attempts.next)

    // The application identity read on the last attempt is where the user actually is by the time
    // the clipboard dictation begins.
    #expect(result == .success(noTarget(in: "com.apple.Safari")))
    #expect(clock.nowNanoseconds() == 1000)
  }

  @Test("a secure field is answered on the first attempt and never retried")
  @MainActor
  func secureFieldIsNeverRetried() async {
    let clock = CaptureClock(now: 0)
    let sleeper = CaptureSleeper(clock: clock)
    let attempts = ScriptedCapture(
      [.success(.secure(applicationIdentifier: "com.apple.Safari", elementIdentifier: "token"))],
      thereafter: .success(editable(in: "com.apple.Safari")))

    let result = await retry(clock: clock, sleeper: sleeper).capture(attempt: attempts.next)

    #expect(
      result
        == .success(
          .secure(applicationIdentifier: "com.apple.Safari", elementIdentifier: "token")))
    #expect(attempts.count == 1)
    #expect(await sleeper.count() == 0)
  }

  @Test("a denied permission is answered on the first attempt and never retried")
  @MainActor
  func permissionDeniedIsNeverRetried() async {
    let clock = CaptureClock(now: 0)
    let sleeper = CaptureSleeper(clock: clock)
    let attempts = ScriptedCapture(
      [.failure(.permissionDenied)],
      thereafter: .success(editable(in: "com.apple.TextEdit")))

    let result = await retry(clock: clock, sleeper: sleeper).capture(attempt: attempts.next)

    #expect(result == .failure(.permissionDenied))
    #expect(attempts.count == 1)
    #expect(await sleeper.count() == 0)
  }

  @Test("waiting for a target never outlasts the budget")
  @MainActor
  func waitingNeverOutlastsTheBudget() async {
    let clock = CaptureClock(now: 0)
    let sleeper = CaptureSleeper(clock: clock)
    let attempts = ScriptedCapture(
      [], thereafter: .success(noTarget(in: "com.apple.Finder")))
    let retry = TargetCaptureRetry(
      clock: clock, sleeper: sleeper,
      policy: .init(budgetNanoseconds: 1000, pollIntervalNanoseconds: 300))

    _ = await retry.capture(attempt: attempts.next)

    #expect(await sleeper.slept() == 1000)
  }

  private func retry(clock: CaptureClock, sleeper: CaptureSleeper) -> TargetCaptureRetry {
    .init(
      clock: clock, sleeper: sleeper,
      policy: .init(budgetNanoseconds: 1000, pollIntervalNanoseconds: 100))
  }

  private func editable(in applicationIdentifier: String) -> DictationTargetCapture {
    .editable(
      target: .init(
        applicationIdentifier: applicationIdentifier,
        elementIdentifier: "token",
        selection: .init(location: 0, length: 0)
      ),
      context: context(in: applicationIdentifier)
    )
  }

  private func noTarget(in applicationIdentifier: String) -> DictationTargetCapture {
    .noTarget(context: context(in: applicationIdentifier))
  }

  private func context(in applicationIdentifier: String) -> TargetContext {
    .init(
      applicationIdentifier: applicationIdentifier,
      applicationCategory: .other,
      textBeforeCursor: "",
      textAfterCursor: "",
      selectedText: nil
    )
  }
}

private final class ScriptedCapture: @unchecked Sendable {
  private let lock = NSLock()
  private let scripted: [Result<DictationTargetCapture, TargetCaptureFailure>]
  private let thereafter: Result<DictationTargetCapture, TargetCaptureFailure>
  private var calls = 0

  init(
    _ scripted: [Result<DictationTargetCapture, TargetCaptureFailure>],
    thereafter: Result<DictationTargetCapture, TargetCaptureFailure> = .failure(.unavailable)
  ) {
    self.scripted = scripted
    self.thereafter = thereafter
  }

  var count: Int { lock.withLock { calls } }

  func next() -> Result<DictationTargetCapture, TargetCaptureFailure> {
    lock.withLock {
      defer { calls += 1 }
      return calls < scripted.count ? scripted[calls] : thereafter
    }
  }
}

private final class CaptureClock: IntegrationNanosecondClock, @unchecked Sendable {
  private let lock = NSLock()
  private var now: Int64

  init(now: Int64) { self.now = now }
  func nowNanoseconds() -> Int64 { lock.withLock { now } }
  func advance(by nanoseconds: Int64) { lock.withLock { now += nanoseconds } }
}

private actor CaptureSleeper: IntegrationSleeper {
  private let clock: CaptureClock
  private var sleeps = 0
  private var total: Int64 = 0

  init(clock: CaptureClock) { self.clock = clock }

  func sleep(nanoseconds: UInt64) async {
    sleeps += 1
    total += Int64(nanoseconds)
    clock.advance(by: Int64(nanoseconds))
  }

  func count() -> Int { sleeps }
  func slept() -> Int64 { total }
}
