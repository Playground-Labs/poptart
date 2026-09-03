import DictationCore
import Foundation

/// The bounded Accessibility state Poptart is willing to read in order to tell whether text
/// actually landed in a target: how many characters the target holds and where its selection is.
///
/// Both fields are optional on purpose. Plenty of real controls expose one, the other, or neither,
/// and "the target told us nothing" is a distinct answer from "the target told us it did not move".
public struct TargetTextState: Equatable, Sendable {
  public let characterCount: Int?
  public let selection: TextSelection?

  public init(characterCount: Int?, selection: TextSelection?) {
    self.characterCount = characterCount
    self.selection = selection
  }

  /// Whether the target exposes anything at all that an insertion could be measured against.
  public var isReadable: Bool { characterCount != nil || selection != nil }
}

/// What an Accessibility read-back proves about an attempted insertion.
///
/// SPEC's promise is that Poptart never claims a delivery that did not happen, so the two
/// "something moved" cases and the two "nothing moved" cases must never be collapsed together.
public enum InsertionEvidence: String, Equatable, Sendable {
  /// The target moved exactly the way inserting this text moves a target.
  case confirmed
  /// The target changed, but not into the exact shape expected. Targets legitimately normalise
  /// what they are given — `NSTokenField` turns a pasted string into a single token attachment,
  /// rich-text targets re-wrap, some fields strip newlines — so a change that is not the expected
  /// change is still evidence that the text landed.
  case normalisedChange
  /// The target exposes a character count or a selection, and neither moved. Nothing landed.
  case targetUnchanged
  /// The target exposes neither a readable character count nor a readable selection, so the
  /// insertion can be neither confirmed nor denied. The claim that follows rests on the pasteboard
  /// receipt alone and is explicitly ambiguous.
  case unverifiable
}

/// Turns a pasteboard receipt plus an Accessibility read-back into a delivery verdict.
///
/// The pasteboard receipt on its own is *necessary but not sufficient*: it only says that some
/// process pulled the promised data, and every clipboard manager on macOS (Raycast, Alfred, Maccy,
/// Paste) reads the pasteboard continuously. The compatibility harness measured that read firing
/// for `disabledTextField` — which has no first responder at all — and for `readOnlyTextView`.
/// Treating it as proof of insertion is how a user silently loses a dictation that history then
/// records as delivered.
public enum PasteInsertionConfirmation {
  /// Compares the target's text state before and after an attempted insertion.
  ///
  /// A dimension only counts when an insertion would actually have moved it: replacing a five
  /// character selection with five characters leaves the character count where it was, so on such
  /// a delivery the count carries no information and only the selection can decide.
  public static func evidence(
    before: TargetTextState,
    after: TargetTextState,
    insertedUTF16Count: Int
  ) -> InsertionEvidence {
    let countComparable = before.characterCount != nil && after.characterCount != nil
    let selectionComparable = before.selection != nil && after.selection != nil
    guard countComparable || selectionComparable else { return .unverifiable }

    let expectedCount = before.characterCount.map { count in
      max(0, count - (before.selection?.length ?? 0)) + insertedUTF16Count
    }
    let expectedSelection = before.selection.map { selection in
      TextSelection(location: selection.location + insertedUTF16Count, length: 0)
    }
    let countIsInformative = countComparable && expectedCount != before.characterCount
    let selectionIsInformative = selectionComparable && expectedSelection != before.selection
    guard countIsInformative || selectionIsInformative else { return .unverifiable }

    let countMoved = countComparable && after.characterCount != before.characterCount
    let selectionMoved = selectionComparable && after.selection != before.selection
    guard countMoved || selectionMoved else { return .targetUnchanged }

    let countIsExact = !countComparable || after.characterCount == expectedCount
    let selectionIsExact = !selectionComparable || after.selection == expectedSelection
    return countIsExact && selectionIsExact ? .confirmed : .normalisedChange
  }

  /// Composes the pasteboard receipt with the read-back.
  ///
  /// `evidence` is `nil` when no read-back was performed because the pasteboard transaction itself
  /// failed; it is then irrelevant, since there is no insertion to confirm.
  public static func deliveryResult(
    outcome: ClipboardPasteOutcome,
    evidence: InsertionEvidence?
  ) -> DeliveryResult {
    switch outcome {
    case .failed(let failure):
      return .failed(failure)
    case .promisedTextWasRead:
      switch evidence {
      case .confirmed, .normalisedChange:
        return .inserted(.clipboardPaste)
      case .targetUnchanged:
        // The target read our promised text and kept nothing. Claiming an insertion here is the
        // exact lie SPEC forbids.
        return .failed(.accessibilityAndPasteFailed)
      case .unverifiable, .none:
        // Genuinely unverifiable. Turning a paste that probably worked into a reported failure
        // would be the opposite lie, so the receipt verdict stands and the ambiguity is published
        // through `DeliveryEvidence.insertionIsUnverified` rather than hidden.
        return .inserted(.clipboardPaste)
      }
    }
  }
}

/// Reads the target back after a paste, briefly and within the delivery deadline.
///
/// A synthesised Cmd-V is asynchronous: the receipt closes when the promised data is pulled, which
/// can be a few milliseconds before the target has finished applying the paste. Polling only while
/// the answer is still "nothing moved" keeps the successful path at a single Accessibility read
/// and confines the extra latency to deliveries that are heading for a failure verdict anyway.
public struct PasteConfirmationPolicy: Equatable, Sendable {
  public let budgetNanoseconds: Int64
  public let pollIntervalNanoseconds: Int64

  public init(
    budgetNanoseconds: Int64 = 250_000_000,
    pollIntervalNanoseconds: Int64 = 10_000_000
  ) {
    precondition(budgetNanoseconds >= 0)
    precondition(pollIntervalNanoseconds > 0)
    self.budgetNanoseconds = budgetNanoseconds
    self.pollIntervalNanoseconds = pollIntervalNanoseconds
  }
}

public struct PasteConfirmationReader: Sendable {
  private let clock: any IntegrationNanosecondClock
  private let sleeper: any IntegrationSleeper
  private let policy: PasteConfirmationPolicy

  public init(
    clock: any IntegrationNanosecondClock = SystemIntegrationClock(),
    sleeper: any IntegrationSleeper = SystemIntegrationSleeper(),
    policy: PasteConfirmationPolicy = .init()
  ) {
    self.clock = clock
    self.sleeper = sleeper
    self.policy = policy
  }

  /// - Parameter read: reads the target's current text state. Called at least once.
  @MainActor
  public func evidence(
    before: TargetTextState,
    insertedUTF16Count: Int,
    deadline: MonotonicInstant,
    read: () -> TargetTextState
  ) async -> InsertionEvidence {
    let start = clock.nowNanoseconds()
    // The delivery deadline always wins, so a late paste can leave less than the full budget. A
    // truncated look is not a fair look: concluding "the target never moved" from it would turn a
    // paste that simply had not been applied yet into a reported failure.
    let hadFullBudget = deadline.nanoseconds >= start + policy.budgetNanoseconds
    let budgetEnd = min(start + policy.budgetNanoseconds, deadline.nanoseconds)
    while true {
      let evidence = PasteInsertionConfirmation.evidence(
        before: before, after: read(), insertedUTF16Count: insertedUTF16Count)
      // Only "the target has not moved yet" is worth waiting on; every other answer is final.
      guard evidence == .targetUnchanged else { return evidence }
      let now = clock.nowNanoseconds()
      guard now < budgetEnd else {
        return hadFullBudget ? .targetUnchanged : .unverifiable
      }
      await sleeper.sleep(
        nanoseconds: UInt64(max(1, min(policy.pollIntervalNanoseconds, budgetEnd - now))))
    }
  }
}

/// Everything the delivery path learned about one attempt, published for observation.
///
/// `DeliveryResult` lives in DictationCore and cannot express "inserted, probably" — so the
/// ambiguity of an unverifiable claim is carried here instead of being silently discarded.
public struct DeliveryEvidence: Equatable, Sendable {
  public let dictationID: DictationID
  public let applicationIdentifier: String
  /// Present when the target was classified `.direct` and the Accessibility write was attempted.
  public let directInsertion: DirectInsertionOutcome?
  /// Present when the clipboard paste ran and its promised text was read.
  public let pasteInsertion: InsertionEvidence?
  public let result: DeliveryResult

  public init(
    dictationID: DictationID,
    applicationIdentifier: String,
    directInsertion: DirectInsertionOutcome?,
    pasteInsertion: InsertionEvidence?,
    result: DeliveryResult
  ) {
    self.dictationID = dictationID
    self.applicationIdentifier = applicationIdentifier
    self.directInsertion = directInsertion
    self.pasteInsertion = pasteInsertion
    self.result = result
  }

  /// True when an insertion was reported on the pasteboard receipt alone, because the target
  /// exposed nothing to read back.
  public var insertionIsUnverified: Bool {
    result == .inserted(.clipboardPaste) && pasteInsertion != .confirmed
      && pasteInsertion != .normalisedChange
  }
}

/// Invoked synchronously as each delivery returns, so an implementation must be cheap and must
/// not block: it sits inside the dictation's completion deadline.
public typealias DeliveryEvidenceObserver = @Sendable (DeliveryEvidence) -> Void
