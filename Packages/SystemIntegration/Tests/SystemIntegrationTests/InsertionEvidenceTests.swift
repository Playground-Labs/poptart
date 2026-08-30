import DictationCore
import Foundation
import Testing

@testable import SystemIntegration

@Suite("Insertion evidence")
struct InsertionEvidenceTests {
  private let inserted = "Poptart ✓ 42"

  private var insertedCount: Int { inserted.utf16.count }

  // MARK: - Read-back evidence

  @Test("a caret insertion that moves the count and the caret exactly is confirmed")
  func caretInsertionConfirmed() {
    let evidence = PasteInsertionConfirmation.evidence(
      before: .init(characterCount: 19, selection: .init(location: 6, length: 0)),
      after: .init(characterCount: 31, selection: .init(location: 18, length: 0)),
      insertedUTF16Count: insertedCount
    )

    #expect(evidence == .confirmed)
  }

  @Test("a selection replacement that lands exactly is confirmed")
  func selectionReplacementConfirmed() {
    let evidence = PasteInsertionConfirmation.evidence(
      before: .init(characterCount: 19, selection: .init(location: 6, length: 5)),
      after: .init(characterCount: 26, selection: .init(location: 18, length: 0)),
      insertedUTF16Count: insertedCount
    )

    #expect(evidence == .confirmed)
  }

  @Test("a target that reads the pasteboard and keeps nothing reports no change")
  func unchangedTargetIsNotAnInsertion() {
    let state = TargetTextState(characterCount: 19, selection: .init(location: 6, length: 5))

    #expect(
      PasteInsertionConfirmation.evidence(
        before: state, after: state, insertedUTF16Count: insertedCount) == .targetUnchanged)
  }

  @Test("a target that normalises the pasted text still counts as an insertion")
  func normalisedInsertion() {
    // NSTokenField turns a pasted string into a single U+FFFC token attachment: the value changes,
    // but not by the number of characters that were pasted.
    let evidence = PasteInsertionConfirmation.evidence(
      before: .init(characterCount: 19, selection: .init(location: 0, length: 0)),
      after: .init(characterCount: 20, selection: .init(location: 1, length: 0)),
      insertedUTF16Count: insertedCount
    )

    #expect(evidence == .normalisedChange)
  }

  @Test("a target exposing neither a count nor a selection is unverifiable, not failed")
  func unreadableTargetIsUnverifiable() {
    let evidence = PasteInsertionConfirmation.evidence(
      before: .init(characterCount: nil, selection: nil),
      after: .init(characterCount: nil, selection: nil),
      insertedUTF16Count: insertedCount
    )

    #expect(evidence == .unverifiable)
  }

  @Test("a count-only target still confirms an insertion that changes the count")
  func countOnlyTarget() {
    let evidence = PasteInsertionConfirmation.evidence(
      before: .init(characterCount: 19, selection: nil),
      after: .init(characterCount: 31, selection: nil),
      insertedUTF16Count: insertedCount
    )

    #expect(evidence == .confirmed)
  }

  @Test("a count-only target cannot judge a same-length replacement and says so")
  func countOnlySameLengthReplacementIsUnverifiable() {
    // Replacing five characters with five characters leaves the count where it was, so a count is
    // no evidence either way. Calling that `targetUnchanged` would be a false failure.
    let evidence = PasteInsertionConfirmation.evidence(
      before: .init(characterCount: 19, selection: nil),
      after: .init(characterCount: 19, selection: nil),
      insertedUTF16Count: 0
    )

    #expect(evidence == .unverifiable)
  }

  @Test("a selection-only target confirms a same-length replacement from the caret alone")
  func selectionOnlySameLengthReplacement() {
    let evidence = PasteInsertionConfirmation.evidence(
      before: .init(characterCount: nil, selection: .init(location: 6, length: 5)),
      after: .init(characterCount: nil, selection: .init(location: 11, length: 0)),
      insertedUTF16Count: 5
    )

    #expect(evidence == .confirmed)
  }

  // MARK: - Receipt plus evidence

  @Test(
    "a pasteboard read alone never reports an insertion",
    arguments: [
      (InsertionEvidence.confirmed, DeliveryResult.inserted(.clipboardPaste)),
      (InsertionEvidence.normalisedChange, DeliveryResult.inserted(.clipboardPaste)),
      (InsertionEvidence.targetUnchanged, DeliveryResult.failed(.accessibilityAndPasteFailed)),
      (InsertionEvidence.unverifiable, DeliveryResult.inserted(.clipboardPaste)),
    ]
  )
  func receiptComposition(evidence: InsertionEvidence, expected: DeliveryResult) {
    #expect(
      PasteInsertionConfirmation.deliveryResult(outcome: .promisedTextWasRead, evidence: evidence)
        == expected)
  }

  @Test("a failed pasteboard transaction keeps its own failure regardless of read-back")
  func failedTransactionKeepsFailure() {
    #expect(
      PasteInsertionConfirmation.deliveryResult(
        outcome: .failed(.clipboardOwnershipChanged), evidence: .confirmed)
        == .failed(.clipboardOwnershipChanged))
    #expect(
      PasteInsertionConfirmation.deliveryResult(outcome: .failed(.pasteTimedOut), evidence: nil)
        == .failed(.pasteTimedOut))
  }

  @Test("an unverifiable insertion claim is published as unverified rather than hidden")
  func unverifiedClaimIsVisible() {
    let ambiguous = DeliveryEvidence(
      dictationID: .init(),
      applicationIdentifier: "com.example.custom",
      directInsertion: nil,
      pasteInsertion: .unverifiable,
      result: .inserted(.clipboardPaste)
    )
    let confirmed = DeliveryEvidence(
      dictationID: .init(),
      applicationIdentifier: "com.apple.TextEdit",
      directInsertion: nil,
      pasteInsertion: .confirmed,
      result: .inserted(.clipboardPaste)
    )

    #expect(ambiguous.insertionIsUnverified)
    #expect(!confirmed.insertionIsUnverified)
  }

  // MARK: - Read-back polling

  @Test("a target that has already applied the paste is confirmed without waiting")
  func confirmationDoesNotWaitOnSuccess() async {
    let clock = EvidenceClock(now: 0)
    let sleeper = CountingSleeper(clock: clock)
    let reader = PasteConfirmationReader(
      clock: clock, sleeper: sleeper,
      policy: .init(budgetNanoseconds: 1000, pollIntervalNanoseconds: 100))

    let evidence = await reader.evidence(
      before: .init(characterCount: 19, selection: .init(location: 6, length: 0)),
      insertedUTF16Count: 12,
      deadline: .init(nanoseconds: 10_000),
      read: { .init(characterCount: 31, selection: .init(location: 18, length: 0)) }
    )

    #expect(evidence == .confirmed)
    #expect(await sleeper.count() == 0)
    #expect(clock.nowNanoseconds() == 0)
  }

  @Test("a target that applies the paste late is still confirmed inside the budget")
  func confirmationWaitsForALateTarget() async {
    let clock = EvidenceClock(now: 0)
    let sleeper = CountingSleeper(clock: clock)
    let reader = PasteConfirmationReader(
      clock: clock, sleeper: sleeper,
      policy: .init(budgetNanoseconds: 1000, pollIntervalNanoseconds: 100))

    let evidence = await reader.evidence(
      before: .init(characterCount: 19, selection: .init(location: 6, length: 0)),
      insertedUTF16Count: 12,
      deadline: .init(nanoseconds: 10_000),
      read: {
        clock.nowNanoseconds() >= 300
          ? .init(characterCount: 31, selection: .init(location: 18, length: 0))
          : .init(characterCount: 19, selection: .init(location: 6, length: 0))
      }
    )

    #expect(evidence == .confirmed)
    #expect(clock.nowNanoseconds() == 300)
  }

  @Test("a target that never moves gives up at the budget, not at the delivery deadline")
  func confirmationStopsAtBudget() async {
    let clock = EvidenceClock(now: 0)
    let sleeper = CountingSleeper(clock: clock)
    let reader = PasteConfirmationReader(
      clock: clock, sleeper: sleeper,
      policy: .init(budgetNanoseconds: 1000, pollIntervalNanoseconds: 100))
    let state = TargetTextState(characterCount: 19, selection: .init(location: 6, length: 0))

    let evidence = await reader.evidence(
      before: state,
      insertedUTF16Count: 12,
      deadline: .init(nanoseconds: 10_000_000),
      read: { state }
    )

    #expect(evidence == .targetUnchanged)
    #expect(clock.nowNanoseconds() == 1000)
  }

  @Test("a read-back cut short by the delivery deadline is unverifiable, not a failure")
  func truncatedReadBackIsUnverifiable() async {
    let clock = EvidenceClock(now: 0)
    let sleeper = CountingSleeper(clock: clock)
    let reader = PasteConfirmationReader(
      clock: clock, sleeper: sleeper,
      policy: .init(budgetNanoseconds: 1_000_000, pollIntervalNanoseconds: 100))
    let state = TargetTextState(characterCount: 19, selection: .init(location: 6, length: 0))

    let evidence = await reader.evidence(
      before: state, insertedUTF16Count: 12, deadline: .init(nanoseconds: 250), read: { state })

    // The deadline stopped the look at 250ns of a 1,000,000ns budget. A target that has not been
    // given time to apply the paste has not refused it, so this must not become a failure verdict.
    #expect(evidence == .unverifiable)
    #expect(clock.nowNanoseconds() == 250)
    #expect(
      PasteInsertionConfirmation.deliveryResult(outcome: .promisedTextWasRead, evidence: evidence)
        == .inserted(.clipboardPaste))
  }

  @Test("a target that never moves within a full budget is a failure, not an ambiguity")
  func fullBudgetUnchangedIsAFailure() async {
    let clock = EvidenceClock(now: 0)
    let sleeper = CountingSleeper(clock: clock)
    let reader = PasteConfirmationReader(
      clock: clock, sleeper: sleeper,
      policy: .init(budgetNanoseconds: 1000, pollIntervalNanoseconds: 100))
    let state = TargetTextState(characterCount: 19, selection: .init(location: 6, length: 0))

    let evidence = await reader.evidence(
      before: state, insertedUTF16Count: 12, deadline: .init(nanoseconds: 1000), read: { state })

    #expect(evidence == .targetUnchanged)
    #expect(
      PasteInsertionConfirmation.deliveryResult(outcome: .promisedTextWasRead, evidence: evidence)
        == .failed(.accessibilityAndPasteFailed))
  }

  @Test("an unreadable target is answered on the first read and costs no waiting")
  func unreadableTargetDoesNotPoll() async {
    let clock = EvidenceClock(now: 0)
    let sleeper = CountingSleeper(clock: clock)
    let reader = PasteConfirmationReader(
      clock: clock, sleeper: sleeper,
      policy: .init(budgetNanoseconds: 1000, pollIntervalNanoseconds: 100))

    let evidence = await reader.evidence(
      before: .init(characterCount: nil, selection: nil),
      insertedUTF16Count: 12,
      deadline: .init(nanoseconds: 10_000),
      read: { .init(characterCount: nil, selection: nil) }
    )

    #expect(evidence == .unverifiable)
    #expect(await sleeper.count() == 0)
  }
}

private final class EvidenceClock: IntegrationNanosecondClock, @unchecked Sendable {
  private let lock = NSLock()
  private var now: Int64

  init(now: Int64) { self.now = now }
  func nowNanoseconds() -> Int64 { lock.withLock { now } }
  func advance(by nanoseconds: Int64) { lock.withLock { now += nanoseconds } }
}

private actor CountingSleeper: IntegrationSleeper {
  private let clock: EvidenceClock
  private var sleeps = 0

  init(clock: EvidenceClock) { self.clock = clock }

  func sleep(nanoseconds: UInt64) async {
    sleeps += 1
    clock.advance(by: Int64(nanoseconds))
  }

  func count() -> Int { sleeps }
}
