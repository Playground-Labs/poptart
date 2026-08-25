import Foundation

public struct ClipboardPasteReceipt: Equatable, Sendable {
  public let changeCount: Int
  public let pasteDispatchedAtNanoseconds: Int64
  public let lastReadAtNanoseconds: Int64?

  public init(
    changeCount: Int,
    pasteDispatchedAtNanoseconds: Int64,
    lastReadAtNanoseconds: Int64?
  ) {
    self.changeCount = changeCount
    self.pasteDispatchedAtNanoseconds = pasteDispatchedAtNanoseconds
    self.lastReadAtNanoseconds = lastReadAtNanoseconds
  }
}

public enum ClipboardRestorationDecision: Equatable, Sendable {
  case wait
  case restore
  case ownershipChanged
}

public struct ClipboardRestorationPolicy: Equatable, Sendable {
  public let quietPeriodNanoseconds: Int64
  public let pollIntervalNanoseconds: Int64

  public init(
    quietPeriodNanoseconds: Int64 = 75_000_000,
    pollIntervalNanoseconds: Int64 = 5_000_000
  ) {
    precondition(quietPeriodNanoseconds >= 0)
    precondition(pollIntervalNanoseconds > 0)
    self.quietPeriodNanoseconds = quietPeriodNanoseconds
    self.pollIntervalNanoseconds = pollIntervalNanoseconds
  }

  public func decision(
    receipt: ClipboardPasteReceipt,
    nowNanoseconds: Int64,
    currentChangeCount: Int
  ) -> ClipboardRestorationDecision {
    guard currentChangeCount == receipt.changeCount else { return .ownershipChanged }
    guard let lastRead = receipt.lastReadAtNanoseconds,
      lastRead >= receipt.pasteDispatchedAtNanoseconds
    else { return .wait }
    return nowNanoseconds - lastRead >= quietPeriodNanoseconds ? .restore : .wait
  }
}

/// Thread-safe because NSPasteboard may request promised data on a framework callback thread.
public final class ClipboardReadTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var dispatchedAt: Int64?
  private var lastReadAt: Int64?

  public init() {}

  public func markPasteDispatched(at nanoseconds: Int64) {
    lock.withLock {
      dispatchedAt = nanoseconds
      lastReadAt = nil
    }
  }

  public func recordProviderRead(at nanoseconds: Int64) {
    lock.withLock {
      guard let dispatchedAt, nanoseconds >= dispatchedAt else { return }
      lastReadAt = max(lastReadAt ?? nanoseconds, nanoseconds)
    }
  }

  public func receipt(changeCount: Int) -> ClipboardPasteReceipt? {
    lock.withLock {
      guard let dispatchedAt else { return nil }
      return .init(
        changeCount: changeCount,
        pasteDispatchedAtNanoseconds: dispatchedAt,
        lastReadAtNanoseconds: lastReadAt
      )
    }
  }
}
